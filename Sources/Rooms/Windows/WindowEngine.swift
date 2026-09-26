import AppKit
import ApplicationServices
import RoomsCore

/// A window on screen right now.
@MainActor
struct LiveWindow {
    let element: AXUIElement
    let app: NSRunningApplication
    let bundleID: String
    let windowID: CGWindowID?
    let title: String
    let frame: CGRect
    let isMinimized: Bool

    var info: WindowInfo { WindowInfo(bundleID: bundleID, title: title, windowID: windowID) }
}

/// Moves real windows: finds them, arranges a room, parks the rest off-screen, and
/// always knows how to bring every parked window back.
@MainActor
final class WindowEngine {
    struct Report {
        var placed = 0
        var parked = 0
        var hiddenApps = 0
        var missing: [String] = []
        var milliseconds = 0
    }

    private(set) var ledger = RestLedger.load()

    /// Windows that belong to rooms other than this one (set by the app), so a room
    /// missing its browser window takes a free one before another project's.
    var claimedWindows: (Room) -> Set<UInt32> = { _ in [] }
    /// Globally pinned windows, supplied by the app's local preferences.
    var pins: () -> [WindowPin] = { [] }

    private func assign(_ room: Room, to windows: [LiveWindow]) -> [Int: Int] {
        SlotMatcher.assign(slots: room.windows, windows: windows.map(\.info), claimed: claimedWindows(room))
    }

    /// Chromium re-enables web accessibility when this is switched back on, costing
    /// seconds on page loads; leave it off for them (Rectangle's list).
    /// Apps whose windows are parked rather than the app hidden. Finder is always
    /// running and macOS brings it back whenever another app hides or the desktop is
    /// clicked, so hiding it never holds.
    private let parkInstead: Set<String> = ["com.apple.finder"]

    private let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "company.thebrowser.dia", "com.vivaldi.Vivaldi",
        "com.openai.codex", "com.openai.atlas",
    ]

    // MARK: Inventory

    /// Every normal window of every regular app, including minimized ones and those
    /// of hidden apps (which report the AXDialog subrole while hidden).
    func inventory() -> [LiveWindow] {
        var result: [LiveWindow] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app != .current {
            guard let bundleID = app.bundleIdentifier else { continue }
            let appElement = AX.app(app.processIdentifier)
            var elements = AX.elements(appElement, kAXWindowsAttribute)
            if elements.isEmpty, !app.isHidden {
                // A web-based (Electron) app sometimes lists no windows until its
                // accessibility mode is on. That mode also makes it draw blue focus
                // outlines, so switch it on only for this read and straight back off.
                AX.setBool(appElement, "AXManualAccessibility", true)
                elements = AX.elements(appElement, kAXWindowsAttribute)
                AX.setBool(appElement, "AXManualAccessibility", false)
            }
            for el in elements {
                let subrole: String? = AX.attribute(el, kAXSubroleAttribute)
                let minimized: Bool = AX.attribute(el, kAXMinimizedAttribute) ?? false
                // Windows of hidden, minimized or just-unhidden apps report AXDialog for a
                // while. A real document window still has a minimize button; dialogs don't.
                let hasMinimizeButton = (AX.attribute(el, kAXMinimizeButtonAttribute) as AXUIElement?) != nil
                let isStandard = subrole == kAXStandardWindowSubrole as String
                    || (subrole == kAXDialogSubrole as String && (app.isHidden || minimized || hasMinimizeButton))
                guard isStandard, let frame = AX.frame(el), frame.width >= 100, frame.height >= 60 else { continue }
                result.append(LiveWindow(
                    element: el, app: app, bundleID: bundleID, windowID: AX.windowID(el),
                    title: AX.attribute(el, kAXTitleAttribute) ?? "", frame: frame, isMinimized: minimized
                ))
            }
        }
        return result
    }

    // MARK: Save as

    /// Slots for chosen windows, in the order given (the first is the main window).
    func slots(for chosen: [LiveWindow]) -> [WindowSlot] {
        let screens = ScreenInfo.all()
        guard !screens.isEmpty else { return [] }
        return chosen.map { win in
            let i = Geometry.bestScreen(for: win.frame, among: screens.map(\.frame)) ?? 0
            return WindowSlot(
                bundleID: win.bundleID, app: win.app.localizedName, title: win.title,
                windowID: win.windowID, display: screens[i].uuid,
                frame: Geometry.fraction(of: win.frame, in: screens[i].visible)
            )
        }
    }

    func pin(for window: LiveWindow) -> WindowPin? {
        let screens = ScreenInfo.all()
        guard let index = Geometry.bestScreen(for: window.frame, among: screens.map(\.frame)) else { return nil }
        return WindowPin(bundleID: window.bundleID, title: window.title, windowID: window.windowID,
                         frame: Geometry.fraction(of: window.frame, in: screens[index].visible))
    }

    /// Learns the arrangement you made: which layout it's closest to (or your own, kept
    /// exactly), remembered for the display it's on. With `keepOrder`, the order you
    /// chose (the picker's numbers) wins; otherwise whoever sits in the main spot is 1.
    func learn(_ room: Room, windows wins: [LiveWindow], keepOrder: Bool) -> (room: Room, reading: Arrangement.Reading) {
        let screens = ScreenInfo.all()
        guard !screens.isEmpty else { return (room, Arrangement.Reading(kind: .auto, order: Array(wins.indices), distance: .infinity)) }
        let indices = wins.compactMap { Geometry.bestScreen(for: $0.frame, among: screens.map(\.frame)) }
        let s = Dictionary(grouping: indices, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? activeScreenIndex(in: screens)
        var reading = Arrangement.read(wins.map(\.frame), in: screens[s].visible, mins: wins.map { minimumSize(for: $0.bundleID) })
        // Windows picked from several displays have no arrangement to read: the room
        // comes together on one display, so let Auto lay it out.
        if Set(indices).count > 1 {
            reading = Arrangement.Reading(kind: .auto, order: Array(wins.indices), distance: .infinity)
        }
        // Picking windows (keepOrder) says which windows, not where: loose windows get
        // tiled by Auto. Only Remember (⌘S) keeps an untidy arrangement exactly.
        if keepOrder, reading.kind == .saved {
            reading = Arrangement.Reading(kind: .auto, order: reading.order, distance: reading.distance)
        }
        let ordered = keepOrder ? wins : reading.order.map { wins[$0] }
        var updated = room
        // Match by the same title/window-ID rules used everywhere else. Comparing only
        // live window IDs would mistake a relaunched window for a closed one, while a
        // genuinely closed slot remains here with its saved My Layout cell intact.
        let matchedSlots = Set(assign(room, to: wins).keys)
        let kept = keepOrder ? [] : room.windows.enumerated().compactMap { index, slot in
            matchedSlots.contains(index) ? nil : slot
        }
        var learned = slots(for: ordered)
        if reading.kind == .mine, let cells = reading.cells, cells.count == learned.count {
            for i in learned.indices { learned[i].cell = cells[i] }   // `order` is unchanged for .mine
        }
        updated.windows = learned + kept
        var apps: [AppRef] = []
        for slot in updated.windows where !apps.contains(where: { $0.bundleID == slot.bundleID }) { apps.append(AppRef(slot.bundleID, name: slot.app)) }
        updated.apps = apps
        updated.layoutByDisplay[screens[s].uuid] = reading.kind
        // `distance` is infinite when there was no arrangement to read (windows on
        // several displays); Int(.infinity) would crash.
        let off = reading.distance.isFinite ? "off by \(Int(reading.distance)) pt" : "not read"
        Log.file("Learned \(room.name): \(reading.kind.rawValue) (\(off)), order \(ordered.map { $0.app.localizedName ?? "" })")
        return (updated, reading)
    }

    /// The room's windows as they are on screen right now.
    func openWindows(of room: Room) -> [LiveWindow] {
        let windows = inventory()
        let assignment = assign(room, to: windows)
        return room.windows.indices.compactMap { assignment[$0].map { windows[$0] } }.filter { !$0.isMinimized && !$0.app.isHidden }
    }

    /// Every window, the ones you can see first (front to back), then those of hidden
    /// apps and minimized ones. Parked windows count as part of their room.
    func windowsForPicking() -> [LiveWindow] {
        let order = frontToBackOrder()
        let visibleRank = { (w: LiveWindow) -> Int in
            if w.app.isHidden || w.isMinimized { return 2 }
            if let id = w.windowID, self.ledger.entries[id] != nil { return 1 }
            return 0
        }
        return inventory().sorted { a, b in
            let ra = visibleRank(a), rb = visibleRank(b)
            if ra != rb { return ra < rb }
            return (order[a.windowID ?? 0] ?? .max) < (order[b.windowID ?? 0] ?? .max)
        }
    }

    /// z-order from the window server (front first). Window numbers need no permission.
    func frontToBackOrder() -> [CGWindowID: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var order: [CGWindowID: Int] = [:]
        for (i, info) in list.enumerated() {
            if let n = info[kCGWindowNumber as String] as? CGWindowID { order[n] = i }
        }
        return order
    }

    // MARK: Planning

    /// The desk at one moment: taken when the palette opens, reused for previews.
    struct Snapshot {
        let screens: [ScreenInfo]
        let windows: [LiveWindow]
    }

    /// Where one of the room's windows will go.
    struct Placement {
        let slot: WindowSlot
        let rect: CGRect
        let window: LiveWindow
    }

    private struct LayoutFrames {
        let rects: [CGRect]
        let effective: LayoutKind
        let fallbackReason: String?
    }

    struct Plan {
        let placements: [Placement]
        let missing: [WindowSlot]
        let effectiveLayout: LayoutKind
        let layoutFallbackReason: String?
        let pin: WindowPin?
        let ignoredPins: Int
    }

    func snapshot() -> Snapshot { Snapshot(screens: ScreenInfo.all(), windows: inventory()) }

    /// Matches the room's windows to open ones and lays out those that are open.
    /// A room comes to you: all of its windows, on one display (the one you're working
    /// on, unless `preferredScreen` says otherwise), wherever they were before.
    func plan(_ room: Room, in snap: Snapshot, on preferredScreen: Int? = nil) -> Plan {
        let assignment = assign(room, to: snap.windows)
        guard !snap.screens.isEmpty else { return Plan(placements: [], missing: room.windows, effectiveLayout: .auto, layoutFallbackReason: "no display is available", pin: nil, ignoredPins: 0) }
        let here = min(preferredScreen ?? activeScreenIndex(in: snap.screens), snap.screens.count - 1)
        let found = room.windows.indices.filter { assignment[$0] != nil }
        var rects: [Int: CGRect] = [:]
        var layout = LayoutFrames(rects: [], effective: room.layout(on: snap.screens[here].uuid), fallbackReason: nil)
        var appliedPin: WindowPin?
        var ignoredPins = 0
        if !found.isEmpty {
            let visible = snap.screens[here].visible
            let matchingPins = found.compactMap({ slot -> (Int, WindowPin)? in
                guard let live = assignment[slot], let pin = pins().first(where: { $0.matches(snap.windows[live].info) }) else { return nil }
                return (slot, pin)
            })
            if let pinned = matchingPins.first {
                ignoredPins = max(0, matchingPins.count - 1)
                let pinFrame = Tiler.clamp(Geometry.resolve(pinned.1.frame, in: visible), into: visible)
                let requested = room.layout(on: snap.screens[here].uuid)
                if requested == .mine,
                   let pinnedIndex = found.firstIndex(of: pinned.0) {
                    let mineMins = found.map { minimumSize(for: room.windows[$0].bundleID) }
                    let mine = frames(for: room, slots: found, kind: .mine, in: visible, mins: mineMins)
                    if mine.effective == .mine,
                       let mineRects = PinnedLayout.keepingMyLayout(mine.rects, pinAt: pinnedIndex, pin: pinFrame, in: visible) {
                        for (slot, frame) in zip(found, mineRects) { rects[slot] = frame }
                        layout = LayoutFrames(rects: [], effective: .mine, fallbackReason: nil)
                        appliedPin = pinned.1
                    }
                }
                if rects.isEmpty {
                    let others = found.filter { $0 != pinned.0 }
                    let mins = others.map { minimumSize(for: room.windows[$0].bundleID) }
                    let kind: LayoutKind = [.mine, .saved].contains(requested) ? .auto : requested
                    if let otherFrames = PinnedLayout.frames(count: others.count, kind: kind, around: pinFrame, in: visible, mins: mins) {
                        rects[pinned.0] = pinFrame
                        for (slot, frame) in zip(others, otherFrames) { rects[slot] = frame }
                        let reason = kind == requested ? nil : "\(requested.rawValue) does not match the pinned window"
                        layout = LayoutFrames(rects: [], effective: kind, fallbackReason: reason)
                        appliedPin = pinned.1
                    } else {
                        layout = LayoutFrames(rects: [], effective: .auto, fallbackReason: "pinned window leaves no safe space")
                    }
                }
            }
            if rects.isEmpty {
                let mins = found.map { minimumSize(for: room.windows[$0].bundleID) }
                layout = frames(for: room, slots: found, kind: room.layout(on: snap.screens[here].uuid), in: visible, mins: mins)
                for (k, r) in layout.rects.enumerated() { rects[found[k]] = r }
            }
        }
        let placements = room.windows.indices.compactMap { i -> Placement? in
            guard let w = assignment[i], let rect = rects[i] else { return nil }
            return Placement(slot: room.windows[i], rect: rect, window: snap.windows[w])
        }
        let missing = room.windows.indices.filter { assignment[$0] == nil }.map { room.windows[$0] }
        return Plan(placements: placements, missing: missing, effectiveLayout: layout.effective, layoutFallbackReason: layout.fallbackReason, pin: appliedPin, ignoredPins: ignoredPins)
    }

    /// Where a room's open windows go with `kind`. A layout chosen on another screen,
    /// or before an app's minimum size was known, is checked here every time: if it
    /// no longer fits cleanly, Auto lays the room out instead of pushing windows off
    /// screen or on top of each other.
    private func frames(for room: Room, slots: [Int], kind: LayoutKind, in visible: CGRect, mins: [CGSize]) -> LayoutFrames {
        let n = slots.count
        let auto = { LayoutFrames(rects: Tiler.frames(count: n, kind: .auto, in: visible, mins: mins), effective: .auto, fallbackReason: nil) }
        let fallback = { (reason: String) in
            LayoutFrames(rects: Tiler.frames(count: n, kind: .auto, in: visible, mins: mins), effective: .auto, fallbackReason: reason)
        }
        switch kind {
        case .saved:
            // Exactly where they were saved, but always on this screen.
            let rects = slots.map { Tiler.clamp(Geometry.keptOnScreen(Geometry.resolve(room.windows[$0].frame, in: visible), screens: [visible]), into: visible) }
            return rects.allSatisfy(visible.contains)
                ? LayoutFrames(rects: rects, effective: .saved, fallbackReason: nil)
                : fallback("saved frames do not fit this display")
        case .mine:
            // Your own combination, drawn on the grid with even gaps on any screen,
            // widening the columns of apps that refuse to shrink (Figma, Outlook…).
            // Closed windows leave their saved cells alone, so the ones that are open
            // stay in their own places. An open window with no cell has no safe place
            // in the layout, so Auto takes over for all open windows.
            let cells = slots.map { room.windows[$0].cell }
            guard cells.allSatisfy({ $0 != nil }) else {
                return fallback("an open window has no saved My Layout cell")
            }
            guard let rects = MineLayout.frames(cells: cells, in: visible, mins: mins) else {
                return fallback("saved My Layout cells do not fit cleanly")
            }
            return LayoutFrames(rects: rects, effective: .mine, fallbackReason: nil)
        case .focus, .columns, .grid:
            return Tiler.fits(count: n, kind: kind, in: visible, mins: mins)
                ? LayoutFrames(rects: Tiler.frames(count: n, kind: kind, in: visible, mins: mins), effective: kind, fallbackReason: nil)
                : fallback("\(kind.rawValue) does not fit cleanly")
        case .auto, .stack:
            return kind == .auto
                ? auto()
                : LayoutFrames(rects: Tiler.frames(count: n, kind: kind, in: visible, mins: mins), effective: .stack, fallbackReason: nil)
        }
    }

    /// The layouts Tab offers for a room on the display you're on: those that fit its
    /// open windows without overlapping, each looking different from the others.
    func layoutChoices(for room: Room, in snap: Snapshot) -> [LayoutKind] {
        guard !snap.screens.isEmpty else { return [.auto] }
        let screen = snap.screens[activeScreenIndex(in: snap.screens)]
        let assignment = assign(room, to: snap.windows)
        let present = room.windows.indices.filter { assignment[$0] != nil }
        if let slot = present.first(where: { index in
            assignment[index].flatMap { live in pins().contains { $0.matches(snap.windows[live].info) } } ?? false
        }), let live = assignment[slot], let pin = pins().first(where: { $0.matches(snap.windows[live].info) }) {
            let pinFrame = Tiler.clamp(Geometry.resolve(pin.frame, in: screen.visible), into: screen.visible)
            let others = present.filter { $0 != slot }
            let mins = others.map { minimumSize(for: room.windows[$0].bundleID) }
            let allMins = present.map { minimumSize(for: room.windows[$0].bundleID) }
            let mine = frames(for: room, slots: present, kind: .mine, in: screen.visible, mins: allMins)
            let pinAt = present.firstIndex(of: slot)!
            let keepsMine = mine.effective == .mine
                && PinnedLayout.keepingMyLayout(mine.rects, pinAt: pinAt, pin: pinFrame, in: screen.visible) != nil
            guard let free = PinnedLayout.largestFreeRegion(around: pinFrame, in: screen.visible) else { return keepsMine ? [.auto, .mine] : [.auto] }
            return LayoutKind.allCases.filter { kind in
                if kind == .mine { return keepsMine }
                guard kind != .saved else { return false }
                return kind == .auto || kind == .stack || Tiler.fits(count: others.count, kind: kind, in: free, mins: mins)
            }
        }
        let n = present.count
        let current = room.layout(on: screen.uuid)
        let mins = present.map { minimumSize(for: room.windows[$0].bundleID) }
        if n <= 1 {
            guard current != .auto else { return [.auto] }
            return frames(for: room, slots: present, kind: current, in: screen.visible, mins: mins).effective == current
                ? [.auto, current] : [.auto]
        }
        var seen: [[CGRect]] = []
        var choices: [LayoutKind] = []
        for kind in LayoutKind.allCases {
            switch kind {
            case .mine:
                // Offered only where it draws cleanly (see `frames(for:)`).
                let layout = frames(for: room, slots: present, kind: .mine, in: screen.visible, mins: mins)
                if layout.effective == .mine,
                   layout.rects != Tiler.frames(count: n, kind: .auto, in: screen.visible, mins: mins) {
                    choices.append(kind)
                }
            case .saved:
                if current == .saved { choices.append(kind) }   // only ⌘S makes one
            default:
                guard Tiler.fits(count: n, kind: kind, in: screen.visible, mins: mins) else { continue }
                let rects = Tiler.frames(count: n, kind: kind, in: screen.visible, mins: mins)
                if kind != .auto, seen.contains(rects) { continue }
                seen.append(rects)
                choices.append(kind)
            }
        }
        // Stack's overlapping cards only when nothing tidier fits.
        if choices.contains(where: { [.focus, .columns, .grid].contains($0) }), current != .stack {
            choices.removeAll { $0 == .stack }
        }
        return choices
    }

    /// The display you're working on (under the mouse), by UUID.
    func activeScreenUUID() -> String {
        let screens = ScreenInfo.all()
        return screens.isEmpty ? "" : screens[activeScreenIndex(in: screens)].uuid
    }

    /// The display under the mouse, which is where the palette opens.
    private func activeScreenIndex(in screens: [ScreenInfo]) -> Int {
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ax = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
        return screens.firstIndex { $0.frame.contains(ax) } ?? 0
    }

    /// Puts the room's windows in front-to-back order across apps. Raising a window only
    /// reorders it within its own app, so each app is brought forward in turn, back to
    /// front, the way you'd click them. Matters for Stack, where windows overlap.
    private func stackFrontToBack(_ placements: [Placement]) async {
        for p in placements.reversed() {
            AX.setBool(AX.app(p.window.app.processIdentifier), kAXFrontmostAttribute, true)
            AX.raise(p.window.element)
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    /// The biggest connected display: where a room goes when a monitor is plugged in.
    func largestScreenIndex(in screens: [ScreenInfo]) -> Int {
        screens.indices.max { screens[$0].visible.width * screens[$0].visible.height < screens[$1].visible.width * screens[$1].visible.height } ?? 0
    }

    /// Lays the current room out again, for example after a display was connected or
    /// disconnected (on the largest display), or right after saving it (`onLargest`
    /// false: the display you're on). Only the room's own windows move; nothing is
    /// hidden or parked.
    func relayout(_ room: Room, onLargest: Bool = true) async -> (placed: Int, screen: String) {
        var snap = snapshot()
        let pick = { (s: Snapshot) in onLargest ? self.largestScreenIndex(in: s.screens) : self.activeScreenIndex(in: s.screens) }
        var planned = plan(room, in: snap, on: pick(snap))
        var placements = planned.placements
        for p in placements { move(p.window, to: p.rect) }
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(120))
            guard await learnMinimums(from: placements) else { break }
            snap = snapshot()
            planned = plan(room, in: snap, on: pick(snap))
            placements = planned.placements
            for p in placements { move(p.window, to: p.rect) }
        }
        await stackFrontToBack(placements)
        let name = NSScreen.screens.count > 1 && onLargest ? "the larger display" : "this display"
        Log.file("Re-laid out \(room.name) for \(name) (\(snap.screens.count) displays): \(placements.count) windows")
        return (placements.count, name)
    }

    // MARK: Walk into a room

    /// `launched`: apps just opened for this room; their windows can take a few
    /// seconds to appear, so wait for them before laying out.
    func arrange(_ room: Room, launched: Set<String> = []) async -> Report {
        let start = Date()
        var report = Report()
        let roomBundles = Set(room.windows.map(\.bundleID)).union(room.apps.map(\.bundleID))

        // 1. Bring the room's apps forward, and wait until they really are: a hidden
        //    app ignores (or half-applies) moves sent while it is still unhiding.
        let hidden = NSWorkspace.shared.runningApplications.filter { roomBundles.contains($0.bundleIdentifier ?? "") && $0.isHidden }
        hidden.forEach(show)
        for _ in 0..<30 where hidden.contains(where: \.isHidden) { try? await Task.sleep(for: .milliseconds(20)) }

        var snap = snapshot()
        var planned = plan(room, in: snap)
        var placements = planned.placements
        var missing = planned.missing
        // Just-unhidden apps can take a moment to report their windows again.
        let waitingForLaunch = { missing.contains { launched.contains($0.bundleID) } }
        for _ in 0..<(launched.isEmpty ? 5 : 40) where !missing.isEmpty && (!hidden.isEmpty || waitingForLaunch()) {
            try? await Task.sleep(for: .milliseconds(launched.isEmpty ? 80 : 100))
            snap = snapshot()
            planned = plan(room, in: snap)
            placements = planned.placements
            missing = planned.missing
        }
        Log.file("Walk into \(room.name): \(snap.windows.count) windows on the desk, \(placements.count) of \(room.windows.count) room windows found; unhid [\(hidden.compactMap(\.localizedName).joined(separator: ", "))]")
        report.missing = missing.map { $0.app ?? $0.bundleID }

        // 2. Place the room's windows (the room's own windows first: less flicker).
        for p in placements {
            if p.window.isMinimized { AX.setBool(p.window.element, kAXMinimizedAttribute, false) }
            move(p.window, to: p.rect)
        }
        report.placed = placements.count

        // 3. Check what each app actually did. Apps like Figma or Outlook refuse to go
        //    below a minimum size; learn it and lay the room out again around it.
        //    A new arrangement can reveal another minimum (a narrower slot), so repeat
        //    until nothing new is learned. Known minimums make this a no-op next time.
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(120))
            guard await learnMinimums(from: placements) else { break }
            snap = snapshot()
            planned = plan(room, in: snap)
            placements = planned.placements
            for p in placements { move(p.window, to: p.rect) }
            Log.file("  re-laid out around minimum sizes: " + placements.map { "\($0.window.app.localizedName ?? "") \(Int($0.rect.width))×\(Int($0.rect.height))" }.joined(separator: ", "))
        }

        let screens = snap.screens, windows = snap.windows
        let chosenIDs = Set(placements.compactMap(\.window.windowID))
        let chosenElements = placements.map(\.window.element)
        let isChosen = { (w: LiveWindow) in
            w.windowID.map(chosenIDs.contains) ?? chosenElements.contains { CFEqual($0, w.element) }
        }
        let appsWithRoomWindows = Set(placements.map(\.window.bundleID))

        // 3. Rest everything else. Apps with nothing in the room are hidden whole
        //    (native, instant); other windows of room apps are parked off-screen.
        for win in windows where !isChosen(win) {
            if appsWithRoomWindows.contains(win.bundleID) || parkInstead.contains(win.bundleID) {
                if !win.isMinimized, park(win, screens: screens) { report.parked += 1 }
            } else {
                // Apps that get hidden, and app-only room members, never keep windows off-screen.
                unpark(win)
            }
        }
        // 4. Stack the room's windows so the first one ends on top, and make its app
        //    the active one *before* hiding others (the active app can't be hidden).
        await stackFrontToBack(placements)
        if let first = placements.first {
            AX.setBool(first.window.element, kAXMainAttribute, true)
            if let url = first.window.app.bundleURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
            AX.setBool(AX.app(first.window.app.processIdentifier), kAXFrontmostAttribute, true)
        }

        // 5. Hide the apps with nothing in the room. The standard call is sometimes
        //    refused; Accessibility's own "hidden" attribute is the reliable fallback.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular
            && app != .current && !app.isHidden && !roomBundles.contains(app.bundleIdentifier ?? "")
            && !parkInstead.contains(app.bundleIdentifier ?? "") {
            var how = "ok"
            if !app.hide() {
                AX.setBool(AX.app(app.processIdentifier), kAXHiddenAttribute, true)
                how = "via Accessibility"
            }
            report.hiddenApps += 1
            Log.file("  hide \(app.localizedName ?? "?"): \(how)")
        }

        saveLedger()

        // 6. Electron apps sometimes apply a frame late or snap back once: verify and
        //    re-apply anything that isn't where it should be.
        try? await Task.sleep(for: .milliseconds(250))
        var off: [String] = []
        for p in placements {
            guard let actual = AX.frame(p.window.element) else { continue }
            if !fits(actual, p.rect, bundleID: p.window.bundleID) {
                move(p.window, to: p.rect)
                off.append(p.window.app.localizedName ?? p.window.bundleID)
            }
        }
        // A room window that was parked before is forgotten only now that it's
        // confirmed back in the room (mostly inside its place); otherwise its way
        // back stays on disk.
        var cameBack = false
        for p in placements {
            guard let id = p.window.windowID, ledger.entries[id] != nil, let actual = AX.frame(p.window.element) else { continue }
            let overlap = actual.intersection(p.rect)
            if !overlap.isNull, overlap.width * overlap.height >= p.rect.width * p.rect.height / 2 {
                ledger.entries[id] = nil
                cameBack = true
            }
        }
        if cameBack { saveLedger() }
        report.milliseconds = Int(Date().timeIntervalSince(start) * 1000)
        let fallback = planned.layoutFallbackReason.map { "; fallback: \($0)" } ?? ""
        let layoutName = planned.pin == nil ? planned.effectiveLayout.rawValue : "pinned + \(planned.effectiveLayout.rawValue)"
        let ignored = planned.ignoredPins > 0 ? "; ignored \(planned.ignoredPins) additional pin(s)" : ""
        Log.file("Arranged \(room.name) (\(layoutName)): \(report.placed) placed, \(report.parked) parked, \(report.hiddenApps) apps hidden, re-applied [\(off.joined(separator: ", "))], missing [\(report.missing.joined(separator: ", "))]\(fallback)\(ignored) in \(report.milliseconds) ms")
        for p in placements {
            let a = AX.frame(p.window.element) ?? .zero
            Log.file("  \(p.window.app.localizedName ?? ""): wanted \(Int(p.rect.width))×\(Int(p.rect.height)) @\(Int(p.rect.minX)),\(Int(p.rect.minY))  got \(Int(a.width))×\(Int(a.height)) @\(Int(a.minX)),\(Int(a.minY))")
        }
        return report
    }

    // MARK: Minimum sizes

    /// Smallest sizes apps have refused to go below, learned by trying. Kept across
    /// launches so layouts and previews account for them from the start.
    private var minimums: [String: CGSize] = {
        let raw = UserDefaults.standard.dictionary(forKey: "minimumWindowSizes") as? [String: [Double]] ?? [:]
        return raw.compactMapValues { $0.count == 2 ? CGSize(width: $0[0], height: $0[1]) : nil }
    }()

    func minimumSize(for bundleID: String) -> CGSize { minimums[bundleID] ?? .zero }

    /// Apps whose minimum was measured (see `measureMinimums`). Learning by trial
    /// doesn't override those: an app still animating a resize looks like it refuses.
    private var measured = Set(UserDefaults.standard.stringArray(forKey: "measuredMinimums") ?? [])

    /// Finds how small each window's app lets it get: asks for a tiny window, reads
    /// back what the app allowed, and puts the window back. Run while the picker covers
    /// the screen, so layouts fit on the first try instead of learning by failing.
    func measureMinimums(of wins: [LiveWindow]) async {
        // A hidden app's windows can't be resized: show it (behind the picker; the room
        // is about to show it anyway). Minimized windows are left alone.
        let hidden = Set(wins.filter { $0.app.isHidden }.map(\.app))
        hidden.forEach(show)
        for _ in 0..<30 where hidden.contains(where: \.isHidden) { try? await Task.sleep(for: .milliseconds(20)) }
        if !hidden.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
        // Fullscreen windows can't be resized; leave them (and minimized ones) alone.
        // Every other window is tried, even if macOS still reports its app as hidden
        // a moment after showing it: a window that doesn't shrink is skipped below.
        let probe = wins.filter { !$0.isMinimized && !((AX.attribute($0.element, "AXFullScreen") as Bool?) ?? false) }
        guard !probe.isEmpty else { Log.file("Measured minimum sizes: nothing to measure"); return }
        for w in probe { move(w, to: CGRect(origin: w.frame.origin, size: CGSize(width: 1, height: 1))) }
        // Some apps animate the resize (Chrome, Teams): read until the sizes settle.
        var sizes: [CGSize?] = []
        for _ in 0..<5 {
            try? await Task.sleep(for: .milliseconds(100))
            let now = probe.map { AX.frame($0.element)?.size }
            if now == sizes { break }
            sizes = now
        }
        for w in probe { move(w, to: w.frame) }

        var sizesFound: [String: CGSize] = [:]
        for (w, size) in zip(probe, sizes) {
            // A window that didn't get any smaller ignored the request: its size says
            // nothing about a minimum, so it stays unknown (and is learned later).
            guard let size, size.width < w.frame.width - 1 || size.height < w.frame.height - 1 else { continue }
            let m = sizesFound[w.bundleID] ?? .zero
            sizesFound[w.bundleID] = CGSize(width: max(m.width, size.width), height: max(m.height, size.height))
        }
        for (bundleID, size) in sizesFound { minimums[bundleID] = size }
        self.measured.formUnion(sizesFound.keys)
        UserDefaults.standard.set(Array(self.measured).sorted(), forKey: "measuredMinimums")
        saveMinimums()
        Log.file("Measured minimum sizes: " + sizesFound.map { "\($0.key) \(Int($0.value.width))×\(Int($0.value.height))" }.sorted().joined(separator: ", "))
    }

    private func saveMinimums() {
        UserDefaults.standard.set(minimums.mapValues { [Double($0.width), Double($0.height)] }, forKey: "minimumWindowSizes")
    }

    /// Compares where windows ended up with where they were sent. Returns true when
    /// a new minimum was learned (the room should be laid out again).
    private func learnMinimums(from placements: [Placement]) async -> Bool {
        // Apps that animate their resize (Chrome, Teams) can still be mid-way on the first
        // read. Ask the stragglers once more, and only believe what they still refuse.
        let tooBig = placements.filter { p in
            guard !measured.contains(p.window.bundleID), let a = AX.frame(p.window.element) else { return false }
            return a.width > p.rect.width + 4 || a.height > p.rect.height + 4
        }
        guard !tooBig.isEmpty else { return false }
        for p in tooBig { AX.setSize(p.window.element, p.rect.size) }
        try? await Task.sleep(for: .milliseconds(200))

        var learned = false
        for p in tooBig {
            guard let actual = AX.frame(p.window.element) else { continue }
            var m = minimums[p.window.bundleID] ?? .zero
            if actual.width > p.rect.width + 4, actual.width > m.width { m.width = actual.width; learned = true }
            if actual.height > p.rect.height + 4, actual.height > m.height { m.height = actual.height; learned = true }
            minimums[p.window.bundleID] = m
            Log.file("  \(p.window.app.localizedName ?? ""): won't go below \(Int(actual.width))×\(Int(actual.height)) (asked \(Int(p.rect.width))×\(Int(p.rect.height)))")
        }
        if learned { saveMinimums() }
        return learned
    }

    /// Close enough: within a few points (Terminal resizes in character steps), or
    /// larger only because of a known minimum.
    private func fits(_ actual: CGRect, _ wanted: CGRect, bundleID: String) -> Bool {
        let m = minimumSize(for: bundleID)
        let wOK = abs(actual.width - wanted.width) <= 16 || actual.width <= max(wanted.width, m.width) + 4
        let hOK = abs(actual.height - wanted.height) <= 16 || actual.height <= max(wanted.height, m.height) + 4
        return wOK && hOK && abs(actual.minX - wanted.minX) <= 4 && abs(actual.minY - wanted.minY) <= 4
    }

    // MARK: Snapping one window

    private var restoreFrames: [CGWindowID: CGRect] = [:]
    private var lastSnap: (id: CGWindowID?, action: SnapAction, step: Int, rect: CGRect, at: Date)?

    /// The window you're typing in.
    func focusedWindow() -> LiveWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication, app != .current, let bundleID = app.bundleIdentifier else { return nil }
        let appElement = AX.app(app.processIdentifier)
        guard let el: AXUIElement = AX.attribute(appElement, kAXFocusedWindowAttribute), let frame = AX.frame(el) else { return nil }
        return LiveWindow(element: el, app: app, bundleID: bundleID, windowID: AX.windowID(el),
                          title: AX.attribute(el, kAXTitleAttribute) ?? "", frame: frame, isMinimized: false)
    }

    /// Snaps the focused window. Repeating Left/Right Half within two seconds cycles
    /// ½ → ⅔ → ⅓. The frame before the first snap is kept for Restore.
    func snap(_ action: SnapAction) {
        guard let win = focusedWindow() else { return }
        let screens = ScreenInfo.all()
        guard !screens.isEmpty else { return }
        let i = Geometry.bestScreen(for: win.frame, among: screens.map(\.frame)) ?? 0
        let continuing = lastSnap.map { $0.id == win.windowID && close($0.rect, win.frame) } ?? false
        var step = 0
        if continuing, let last = lastSnap, last.action == action, action.cycles, Date().timeIntervalSince(last.at) < 2 {
            step = last.step + 1
        }
        if let id = win.windowID, !continuing { restoreFrames[id] = win.frame }
        let target = action.rect(in: screens[i].visible, window: win.frame.size, step: step)
        place(win, at: target, within: screens[i].visible)
        lastSnap = (win.windowID, action, step, AX.frame(win.element) ?? target, Date())
        Log.file("Snap \(win.app.localizedName ?? ""): \(action.title)\(step > 0 ? " (step \(step + 1))" : "")")
    }

    /// Puts the focused window back where it was before it was snapped.
    func restoreFocused() {
        guard let win = focusedWindow(), let id = win.windowID, let frame = restoreFrames[id] else { NSSound.beep(); return }
        move(win, to: frame)
        restoreFrames[id] = nil
        lastSnap = nil
    }

    /// Moves the focused window to the next display (left to right), keeping its
    /// place and proportions there.
    func moveFocusedToDisplay(_ offset: Int) {
        guard let win = focusedWindow() else { return }
        let screens = ScreenInfo.all().sorted { $0.frame.minX < $1.frame.minX }
        guard screens.count > 1, let i = Geometry.bestScreen(for: win.frame, among: screens.map(\.frame)) else { NSSound.beep(); return }
        let target = screens[(i + offset + screens.count) % screens.count]
        let fraction = Geometry.fraction(of: win.frame, in: screens[i].visible)
        place(win, at: Geometry.resolve(fraction, in: target.visible), within: target.visible)
    }

    /// Moves a window; if the app won't shrink that far, keeps it on screen anyway.
    private func place(_ win: LiveWindow, at rect: CGRect, within visible: CGRect) {
        move(win, to: rect)
        if let actual = AX.frame(win.element), actual.size != rect.size {
            let kept = Tiler.clamp(CGRect(origin: rect.origin, size: actual.size), into: visible.insetBy(dx: Tiler.gap, dy: Tiler.gap))
            if kept.origin != actual.origin { AX.setPosition(win.element, kept.origin) }
        }
    }

    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 4 && abs(a.minY - b.minY) <= 4 && abs(a.width - b.width) <= 4 && abs(a.height - b.height) <= 4
    }

    // MARK: Resting

    @discardableResult
    private func park(_ win: LiveWindow, screens: [ScreenInfo]) -> Bool {
        guard let id = win.windowID else { return false }
        if ledger.entries[id] == nil {
            // Write the way back before moving anything.
            ledger.entries[id] = RestEntry(windowID: id, bundleID: win.bundleID, title: win.title, savedFrame: win.frame)
        }
        // Do not move a window unless its way back is safely on disk.
        guard saveLedger(), !screens.isEmpty else { return false }
        let i = Geometry.bestScreen(for: win.frame, among: screens.map(\.frame)) ?? 0
        let others = screens.enumerated().filter { $0.offset != i }.map(\.element.frame)
        AX.setPosition(win.element, Geometry.parkingOrigin(windowSize: win.frame.size, screen: screens[i].visible, otherScreens: others))
        return true
    }

    /// Puts a parked window back. Its entry is only forgotten once the window is
    /// really there: an app that's busy for a moment keeps its way back for next time.
    private func unpark(_ win: LiveWindow) {
        guard let id = win.windowID, let entry = ledger.entries[id], entry.bundleID == win.bundleID else { return }
        // The display it was parked from may be gone: come back to one that's connected.
        let target = Geometry.keptOnScreen(entry.savedFrame, screens: ScreenInfo.all().map(\.frame))
        move(win, to: target)
        if let now = AX.frame(win.element), abs(now.minX - target.minX) <= 16, abs(now.minY - target.minY) <= 16 {
            ledger.entries[id] = nil
        }
    }

    /// Brings every parked window back. Entries for windows that are gone (their app
    /// quit) are dropped; any window that didn't come back stays recorded for next time.
    private func unparkAll() {
        guard !ledger.entries.isEmpty else { return }
        for win in inventory() { unpark(win) }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        ledger.entries = ledger.entries.filter { running.contains($0.value.bundleID) }
        saveLedger()
    }

    /// Puts every parked window back where it was, and optionally shows every app.
    func restoreEverything(showApps: Bool = true) {
        // Show apps first: a hidden app's windows move more reliably once it's visible.
        if showApps {
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.isHidden {
                show(app)
            }
        }
        unparkAll()
    }

    /// After a crash or restart (or once Accessibility is allowed): bring back parked
    /// windows that still exist.
    func recoverFromLastSession() {
        guard !ledger.entries.isEmpty else { return }
        unparkAll()
        Log.file("Recovered parked windows; \(ledger.entries.count) still waiting")
    }

    /// Unhides an app, falling back to Accessibility when the standard call is refused.
    private func show(_ app: NSRunningApplication) {
        if !app.unhide() { AX.setBool(AX.app(app.processIdentifier), kAXHiddenAttribute, false) }
    }

    // MARK: Moving

    private func move(_ win: LiveWindow, to rect: CGRect) {
        let appElement = AX.app(win.app.processIdentifier)
        let enhanced: Bool = AX.attribute(appElement, "AXEnhancedUserInterface") ?? false
        if enhanced { AX.setBool(appElement, "AXEnhancedUserInterface", false) }
        AX.setFrame(win.element, rect)
        if enhanced && !chromium.contains(win.bundleID) { AX.setBool(appElement, "AXEnhancedUserInterface", true) }
    }

    @discardableResult
    private func saveLedger() -> Bool {
        do {
            try ledger.save()
            return true
        } catch {
            Log.switcher.error("Could not save resting ledger: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
