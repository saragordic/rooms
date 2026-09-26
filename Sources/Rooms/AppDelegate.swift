import AppKit
import RoomsCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let palette = PaletteController()
    private let engine = WindowEngine()
    private let preview = LayoutPreview()
    private let toast = Toast()
    private let picker = RoomPicker()
    private let welcome = Welcome()
    private var lastScreens: [CGRect] = []
    private var displayWork: DispatchWorkItem?
    private var registeredRoomKeys: [Int] = []
    /// The last deleted room and where it was in the list, for Undo.
    private var lastDeleted: (room: Room, index: Int)?
    private var paletteSnapshot: WindowEngine.Snapshot?
    /// The window work running now. Switching, saving, laying out after a display
    /// change and Show Everything run one at a time, in the order asked: two at once
    /// would interleave their moves, each hiding what the other just showed.
    private var windowWork: Task<Void, Never>?
    /// Parked windows from a previous run have been looked for (needs Accessibility).
    private var recovered = false
    private var iconCache: [String: NSImage] = [:]
    private let defaults = UserDefaults.standard
    private var rooms: [Room] = []
    private var loadError: String?

    /// Which room is out on which display, and the one you walked into last.
    private var desk: Desk {
        get { Desk(rooms: defaults.dictionary(forKey: "roomByDisplay") as? [String: String] ?? [:], current: defaults.string(forKey: "currentRoom")) }
        set {
            defaults.set(newValue.rooms, forKey: "roomByDisplay")
            defaults.set(newValue.current, forKey: "currentRoom")
        }
    }

    private var currentRoomID: String? { desk.current }

    /// The room out on the display you're on (or, before any room has a display, the
    /// room you're in), and the rooms out on the others.
    private func roomsHere() -> (here: String?, elsewhere: Set<String>) {
        let desk = desk
        guard !desk.rooms.isEmpty else { return (desk.current, []) }
        let display = engine.activeScreenUUID()
        let connected = ScreenInfo.all().map(\.uuid)
        return (desk.rooms[display], Set(desk.others(than: display, connected: connected).values))
    }

    private var recency: [String: Date] {
        get { (defaults.dictionary(forKey: "roomRecency") as? [String: Double] ?? [:]).mapValues(Date.init(timeIntervalSince1970:)) }
        set { defaults.set(newValue.mapValues(\.timeIntervalSince1970), forKey: "roomRecency") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        reloadRooms()
        setUpStatusItem()

        palette.rooms = { [unowned self] in rooms }
        palette.loadError = { [unowned self] in loadError }
        palette.recency = { [unowned self] in recency }
        palette.currentRoomID = { [unowned self] in roomsHere().here }
        palette.elsewhere = { [unowned self] in roomsHere().elsewhere }
        palette.willShow = { [unowned self] in
            reloadRooms()
            recoverIfNeeded()
            paletteSnapshot = nil
            // Read the desk right after the panel appears, so opening it never waits on AX.
            DispatchQueue.main.async { [unowned self] in
                guard AX.isTrusted, palette.isVisible else { return }
                paletteSnapshot = engine.snapshot()
                palette.refreshPreview()
            }
        }
        palette.onChoose = { [unowned self] room in inTurn { await self.walk(into: room) } }
        palette.onSave = { [unowned self] name in openPicker(name: name) }
        picker.onDone = { [unowned self] choice in
            inTurn {
                // Behind the picker, find how small each app lets its window get, so the
                // room fits this screen on the first try.
                await self.engine.measureMinimums(of: choice.windows)
                self.picker.finishSaving(choice.session)
                await self.saveRoom(named: choice.name, renaming: choice.originalName, about: choice.about, windows: choice.windows)
            }
        }
        engine.claimedWindows = { [unowned self] room in
            Set(rooms.filter { $0.id != room.id }.flatMap { $0.windows.compactMap(\.windowID) })
        }
        picker.onNameSettled = { [unowned self] name in
            guard !name.isEmpty, rooms.allSatisfy({ Matcher.fold($0.name) != Matcher.fold(name) }),
                  let template = RoomTemplate.matching(name) else { return }
            picker.suggestAbout(template.about)
        }
        palette.onPreview = { [unowned self] room in showPreview(for: room) }
        palette.onLayoutChange = { [unowned self] room, kind in setLayout(kind, for: room) }
        palette.layoutFor = { [unowned self] room in room.layout(on: engine.activeScreenUUID()) }
        palette.nextLayout = { [unowned self] room, forward in
            // Step through exactly the layouts that fit here and look different; a
            // saved layout that's no longer among them counts as Auto.
            let current = room.layout(on: engine.activeScreenUUID())
            let choices = engine.layoutChoices(for: room, in: paletteSnapshot ?? engine.snapshot())
            guard choices.count > 1 else { return nil }
            let i = choices.firstIndex(of: current) ?? 0
            return choices[(i + (forward ? 1 : choices.count - 1)) % choices.count]
        }
        palette.onCancel = { [unowned self] in
            preview.hide()
            paletteSnapshot = nil
        }

        palette.shortcutFor = { [unowned self] room in Room.withShortcuts(rooms).first { $0.value.id == room.id }?.key }
        palette.onAssignShortcut = { [unowned self] room, n in assignShortcut(n, to: room) }
        palette.onDelete = { [unowned self] room in deleteRoom(room) }
        palette.onUndoDelete = { [unowned self] in
            guard lastDeleted != nil else { return false }
            undoDelete()
            return true
        }
        picker.onDelete = { [unowned self] name in
            if let room = rooms.first(where: { Matcher.fold($0.name) == Matcher.fold(name) }) { deleteRoom(room) }
        }
        palette.onRemember = { [unowned self] room in
            palette.hide()
            rememberArrangement(of: room)
        }

        HotkeyCenter.shared.onPress = { [unowned self] in palette.toggle() }
        HotkeyCenter.shared.onRoomKey = { [unowned self] n in
            guard let room = Room.withShortcuts(rooms)[n] else { return }
            palette.hide()
            inTurn { await self.walk(into: room) }
        }
        registerRoomKeys()

        HotkeyCenter.shared.onSnapKey = { [unowned self] i in perform(SnapBinding.all[i].command) }
        registerSnapKeys()

        // Plugging in (or unplugging) a monitor re-lays out the room you're in.
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        lastScreens = NSScreen.screens.map(\.frame)
        let shortcut = Shortcut.named(defaults.string(forKey: "shortcut"))
        if !HotkeyCenter.shared.register(shortcut) { warnShortcutTaken(shortcut) }

        // If Rooms quit unexpectedly with windows parked, bring them back now.
        recoverIfNeeded()
        // Until the first room exists, opening Rooms explains how to start.
        if rooms.isEmpty || !defaults.bool(forKey: "welcomed") {
            defaults.set(true, forKey: "welcomed")
            showWelcome()
        }
        Log.app.info("Rooms started with \(self.rooms.count) rooms")
    }

    /// A menu bar app has no menu of its own, and without one ⌘V, ⌘C, ⌘A and ⌘Z do
    /// nothing in its text fields. This menu is never shown; it only routes the keys.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Rooms", action: nil, keyEquivalent: ""))
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    /// Opening Rooms again while it runs (double-clicking it in Finder): show how to
    /// start if there are no rooms yet, otherwise the palette.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reloadRooms()
        if rooms.isEmpty { showWelcome() } else { palette.show() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave a window off-screen after Rooms is gone.
        if AX.isTrusted { engine.restoreEverything(showApps: false) }
    }

    /// Runs `work` after whatever window work is already under way.
    private func inTurn(_ work: @escaping @MainActor () async -> Void) {
        let previous = windowWork
        windowWork = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Brings back windows a crash left parked, as soon as Accessibility allows it
    /// (at launch, or later once the user has allowed it).
    private func recoverIfNeeded() {
        guard !recovered, AX.isTrusted else { return }
        recovered = true
        inTurn { [unowned self] in engine.recoverFromLastSession() }
    }

    // MARK: Rooms

    private func reloadRooms() {
        do {
            rooms = try RoomStore.loadOrSeed(at: RoomStore.defaultURL, seed: { [] })
            loadError = nil
            registerRoomKeys()   // rooms.json may have been edited by hand
        } catch {
            loadError = RoomStore.describe(error)
            Log.app.error("rooms.json: \(self.loadError ?? "", privacy: .public)")
        }
    }

    private func walk(into room: Room) async {
        // A room with nothing in it yet (the starter rooms) would hide every app and
        // show nothing: choose its windows instead.
        if room.windows.isEmpty, room.apps.isEmpty {
            preview.hide()
            openPicker(name: room.name)
            return
        }
        if !room.windows.isEmpty, !AX.isTrusted {
            askForAccessibility(reason: "to put \(room.name)'s windows back in place. Until then, Rooms switches whole apps.")
        }
        let (display, others) = placeForWalk(into: room)
        let report = await Switcher.walk(into: room, on: display, keeping: others, engine: engine)
        if let arranged = report.arranged, !room.windows.isEmpty {
            let placed = arranged.placed == 1 ? "1 window" : "\(arranged.placed) windows"
            let missing = Array(Set(arranged.missing)).sorted()
            toast.show("\(room.name) · \(placed)",
                       detail: missing.isEmpty ? nil : "\(missing.joined(separator: ", "))\(missing.count == 1 ? "'s window isn't" : " windows aren't") open. Open \(missing.count == 1 ? "it" : "them") and save the room again.")
        }
        paletteSnapshot = nil
        // The windows have moved under the preview; let it fade away.
        preview.hide(animated: true, delay: 0.05)
        markCurrent(room, on: display)
    }

    /// A room comes to the display you're on, and the rooms out on the other displays
    /// stay there.
    private func placeForWalk(into room: Room) -> (display: String, others: [Room]) {
        let display = engine.activeScreenUUID()
        let out = desk.others(than: display, connected: ScreenInfo.all().map(\.uuid))
        return (display, rooms.filter { $0.id != room.id && out.values.contains($0.id) })
    }

    // MARK: Snapping

    private var snapKeysOn: Bool {
        get { defaults.object(forKey: "snapKeys") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "snapKeys") }
    }

    private func registerSnapKeys() {
        let refused = HotkeyCenter.shared.registerSnapKeys(snapKeysOn ? SnapBinding.all.map(\.shortcut) : [])
        if !refused.isEmpty { Log.file("Snap keys refused: " + refused.joined(separator: ", ")) }
    }

    private func perform(_ command: SnapCommand) {
        guard AX.isTrusted else {
            askForAccessibility(reason: "to move and resize windows.")
            return
        }
        switch command {
        case .snap(let action): engine.snap(action)
        case .restore: engine.restoreFocused()
        case .display(let d): engine.moveFocusedToDisplay(d)
        }
    }

    @objc private func snapFromMenu(_ sender: NSMenuItem) {
        guard let i = sender.representedObject as? Int else { return }
        perform(SnapBinding.all[i].command)
    }

    @objc private func toggleSnapKeys() {
        snapKeysOn.toggle()
        registerSnapKeys()
        toast.show(snapKeysOn ? "Snapping keys on" : "Snapping keys off", detail: snapKeysOn ? "⌃⌥← → ↑ ↓ and friends" : "The Snap Window menu still works")
    }

    // MARK: Direct keys and displays

    private func registerRoomKeys() {
        let digits = Room.withShortcuts(rooms).keys.sorted()
        guard digits != registeredRoomKeys else { return }
        registeredRoomKeys = digits
        let refused = HotkeyCenter.shared.registerRoomKeys(digits)
        if !refused.isEmpty { Log.file("Room keys refused: " + refused.map { "⌃⌥\($0)" }.joined(separator: ", ")) }
    }

    /// ⌘n in the palette: this room gets ⌃⌥n (and whichever room had it gives it up).
    private func assignShortcut(_ n: Int, to room: Room) {
        var all = rooms
        // The first time, make the automatic numbering explicit so nothing else moves.
        if !all.contains(where: { $0.shortcut != nil }) {
            for (key, r) in Room.withShortcuts(all) { if let i = all.firstIndex(where: { $0.id == r.id }) { all[i].shortcut = key } }
        }
        for i in all.indices where all[i].shortcut == n { all[i].shortcut = nil }
        guard let i = all.firstIndex(where: { $0.id == room.id }) else { return }
        all[i].shortcut = n
        do {
            try RoomStore.save(all, to: RoomStore.defaultURL)
            rooms = all
            registerRoomKeys()
            toast.show("\(room.name) is on ⌃⌥\(n)")
        } catch {
            alert("Couldn't save the shortcut", error.localizedDescription)
        }
    }

    @objc private func screensChanged(_ note: Notification) { displaysChanged() }

    /// A display came or went. Wait until macOS settles, then lay out the rooms that
    /// are out again: each stays on its display if it's still there, and the room you're
    /// in goes to the biggest screen when its own is gone (or it's the only room out).
    private func displaysChanged() {
        let screens = NSScreen.screens.map(\.frame)
        guard screens != lastScreens else { return }
        let added = screens.count > lastScreens.count
        lastScreens = screens
        displayWork?.cancel()
        let work = DispatchWorkItem { [unowned self] in
            inTurn {
                // Read the desk now, in turn: a switch queued before this may have changed it.
                let screens = ScreenInfo.all()
                guard !screens.isEmpty else { return }
                var desk = self.desk
                desk.settle(connected: screens.map(\.uuid), largest: screens[self.engine.largestScreenIndex(in: screens)].uuid)
                self.desk = desk
                self.updateStatusTitle()
                guard AX.isTrusted else { return }
                for (display, id) in desk.rooms {
                    guard let room = self.rooms.first(where: { $0.id == id }), !room.windows.isEmpty else { continue }
                    let result = await self.engine.relayout(room, on: display)
                    guard room.id == desk.current, result.placed > 0 else { continue }
                    self.toast.show("\(room.name) · laid out for \(result.screen)",
                               detail: added ? "A display was connected" : "A display was disconnected")
                }
            }
        }
        displayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // MARK: Layout preview

    private func showPreview(for room: Room?) {
        guard let room, !room.windows.isEmpty, let snap = paletteSnapshot else {
            preview.hide()
            return
        }
        let placements = engine.plan(room, in: snap).placements
        guard !placements.isEmpty else {
            preview.hide()
            return
        }
        // Drawn back to front: the room's first windows end up on top, as they will for real.
        preview.show(placements.reversed().map { p in
            LayoutPreview.Card(
                id: p.window.windowID.map { String($0) } ?? "\(p.window.bundleID)|\(p.window.title)",
                rect: p.rect,
                icon: icon(for: p.window.bundleID),
                title: p.window.app.localizedName ?? p.slot.app ?? "",
                subtitle: p.window.title
            )
        }, avoiding: palette.frame)
    }

    private func setLayout(_ kind: LayoutKind, for room: Room) {
        guard let i = rooms.firstIndex(where: { $0.id == room.id }) else { return }
        var all = rooms
        // Remembered for the display you're on (Moom-style): Stack on the laptop can
        // coexist with Focus on the monitor.
        all[i].layoutByDisplay[engine.activeScreenUUID()] = kind
        do {
            try RoomStore.save(all, to: RoomStore.defaultURL)
            rooms = all
        } catch {
            Log.app.error("Could not save layout: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func icon(for bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 48, height: 48)
        iconCache[bundleID] = image
        return image
    }

    private func markCurrent(_ room: Room, on display: String) {
        var d = desk
        d.enter(room.id, on: display)
        desk = d
        var r = recency
        r[room.id] = Date()
        recency = r
        updateStatusTitle()
    }

    /// Opens the window picker. An existing room's windows start selected (in its
    /// order); for a new room, the windows you can see start selected.
    private func openPicker(name: String = "") {
        guard AX.isTrusted else {
            askForAccessibility(reason: "to see which windows are open and where they are.")
            return
        }
        palette.hide()
        preview.hide()
        let windows = engine.windowsForPicking()
        let existing = rooms.first { Matcher.fold($0.name) == Matcher.fold(name) && !name.isEmpty }
        var preselected: [Int] = []
        if let existing, !existing.windows.isEmpty {
            let assignment = SlotMatcher.assign(slots: existing.windows, windows: windows.map(\.info), claimed: engine.claimedWindows(existing))
            preselected = existing.windows.indices.compactMap { assignment[$0] }
        } else {
            preselected = windows.indices.filter { i in
                let w = windows[i]
                return !w.app.isHidden && !w.isMinimized && !(w.windowID.map { engine.ledger.entries[$0] != nil } ?? false)
            }
        }
        // "morning", "deep work", "evening"… start from a template that already fills in
        // what the room is about.
        let template = existing == nil ? RoomTemplate.matching(name) : nil
        picker.show(windows: windows, name: existing?.name ?? template?.name ?? name,
                    about: existing?.about ?? template?.about ?? "", preselected: preselected, editing: existing != nil)
    }

    /// Saves chosen windows as a room, new or existing (matched by name). `renaming` is
    /// the room's previous name when you edited it; the room keeps its id, so its
    /// shortcut and layouts come along.
    private func saveRoom(named name: String, renaming original: String = "", about: String = "", windows chosen: [LiveWindow]) async {
        var all = rooms
        // Only an edit (the picker opened on a room) changes an existing room; a new
        // room with a taken name is refused rather than overwriting it.
        let existing = original.isEmpty ? nil : all.firstIndex { Matcher.fold($0.name) == Matcher.fold(original) }
        if let clash = all.firstIndex(where: { Matcher.fold($0.name) == Matcher.fold(name) }), clash != existing {
            alert("There's already a room called “\(all[clash].name)”", "Choose another name, or edit that room instead.")
            return
        }
        var base: Room
        if let i = existing {
            base = all[i]
            if base.name != name, let old = RoomTemplate.matching(base.name), base.aliases == old.aliases {
                // Renamed away from a template ("Morning"): its aliases and label no longer fit.
                let new = RoomTemplate.matching(name)
                base.aliases = new?.aliases ?? []
                if base.kind == old.kind { base.kind = new?.kind }
            }
            base.name = name
        } else {
            let template = RoomTemplate.matching(name)
            var new = Room(name: name, aliases: template?.aliases ?? [], kind: template?.kind)
            // A renamed room keeps its old id, so a new room can't just take the slug.
            var n = 2
            while all.contains(where: { $0.id == new.id }) { new.id = Room.slug(name) + "-\(n)"; n += 1 }
            new.about = about.isEmpty ? template?.about : about
            base = new
        }
        // The picker's numbers set the order; how the windows sit on screen sets the layout.
        var (room, reading) = engine.learn(base, windows: chosen, keepOrder: true)
        // Editing: what you wrote replaces the description, including clearing it.
        if existing != nil { room.about = about.isEmpty ? nil : about } else if !about.isEmpty { room.about = about }
        if let i = all.firstIndex(where: { $0.id == room.id }) { all[i] = room } else { all.append(room) }
        do {
            try RoomStore.save(all, to: RoomStore.defaultURL)
            rooms = all
            updateStatusTitle()
            registerRoomKeys()
            Log.file("Saved \(room.name): " + room.windows.map { "\($0.app ?? $0.bundleID) “\($0.title)”" }.joined(separator: ", "))
            let count = room.windows.count == 1 ? "1 window" : "\(room.windows.count) windows"
            let key = HotkeyCenter.shared.current?.label ?? "⌥ Space"
            // You walk into the room you just made: its windows come to this display
            // and lay out, and everything else steps back, as on any switch.
            let (display, others) = placeForWalk(into: room)
            markCurrent(room, on: display)
            _ = await Switcher.walk(into: room, on: display, keeping: others, engine: engine)
            toast.show("Saved \(room.name) · \(count)",
                       detail: layoutPhrase(reading) + " · To change the layout: \(key), then Tab")
        } catch {
            alert("Couldn't save the room", error.localizedDescription)
        }
    }

    /// Remembers how the room's windows are arranged right now (⌘S in the palette, or
    /// the menu): the closest layout, tidied, or your own arrangement exactly.
    private func rememberArrangement(of room: Room) {
        guard AX.isTrusted else { askForAccessibility(reason: "to see how your windows are arranged."); return }
        let windows = engine.openWindows(of: room)
        guard !windows.isEmpty else {
            toast.show("None of \(room.name)'s windows are open", detail: "Open them, arrange them, then remember again")
            return
        }
        let (updated, reading) = engine.learn(room, windows: windows, keepOrder: false)
        var all = rooms
        guard let i = all.firstIndex(where: { $0.id == room.id }) else { return }
        all[i] = updated
        do {
            try RoomStore.save(all, to: RoomStore.defaultURL)
            rooms = all
            toast.show("\(room.name) · arrangement remembered", detail: layoutPhrase(reading) + " on this display")
        } catch {
            alert("Couldn't save the arrangement", error.localizedDescription)
        }
    }

    /// Removes a room. Its windows stay exactly where they are; Undo brings it back.
    private func deleteRoom(_ room: Room) {
        var all = rooms
        guard let i = all.firstIndex(where: { $0.id == room.id }) else { return }
        all.remove(at: i)
        do {
            try RoomStore.save(all, to: RoomStore.defaultURL)
            rooms = all
            lastDeleted = (room, i)
            var d = desk
            d.remove(room.id)
            desk = d
            updateStatusTitle()
            registerRoomKeys()
            Log.file("Deleted room \(room.name)")
            toast.show("Deleted “\(room.name)”", detail: "Its windows stay open. Undo: ⌘Z in \(HotkeyCenter.shared.current?.label ?? "⌥ Space"), or the menu bar menu.")
        } catch {
            alert("Couldn't delete the room", error.localizedDescription)
        }
    }

    @objc private func undoDelete() {
        guard let (room, index) = lastDeleted else { return }
        var all = rooms
        all.insert(room, at: min(index, all.count))
        do {
            try RoomStore.save(all, to: RoomStore.defaultURL)
            rooms = all
            lastDeleted = nil
            registerRoomKeys()
            toast.show("“\(room.name)” is back")
        } catch {
            alert("Couldn't restore the room", error.localizedDescription)
        }
    }

    private func layoutPhrase(_ r: Arrangement.Reading) -> String {
        switch r.kind {
        case .mine: "My Layout: your combination, snapped to a grid with even gaps"
        case .saved: "Your own arrangement, kept exactly"
        case .auto: "Laid out to fit the screen"
        default: "Closest to \(r.kind.title), tidied with even gaps"
        }
    }

    private func askForAccessibility(reason: String) {
        let a = NSAlert()
        a.messageText = "Allow Rooms to arrange windows"
        a.informativeText = "Rooms needs Accessibility access \(reason)\n\nTurn on Rooms in System Settings › Privacy & Security › Accessibility. Nothing leaves your Mac."
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Not Now")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn {
            AX.requestTrust()
            AX.openAccessibilitySettings()
        }
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        NSApp.activate()
        a.runModal()
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.doorway()
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        let name = rooms.first { $0.id == currentRoomID }?.name
        statusItem.button?.title = name.map { " \($0)" } ?? ""
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        reloadRooms()
        recoverIfNeeded()
        menu.removeAllItems()

        if !AX.isTrusted {
            menu.addItem(item("Allow Rooms to Arrange Windows…", #selector(allowAccessibility)))
        }
        if UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") == true {
            let warning = NSMenuItem(title: "Stage Manager is on. Rooms works best with it off.", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }
        if rooms.isEmpty, loadError == nil {
            menu.addItem(item("Getting Started…", #selector(showWelcome)))
            menu.addItem(.separator())
        }
        menu.addItem(item("Go to a Room…", #selector(openPalette)))
        menu.addItem(item("New Room…", #selector(newRoom), key: "n"))
        if let deleted = lastDeleted {
            menu.addItem(item("Undo Delete “\(deleted.room.name)”", #selector(undoDelete), key: "z"))
        }
        if let current = rooms.first(where: { $0.id == currentRoomID }) {
            menu.addItem(item("Edit “\(current.name)” Windows…", #selector(editCurrent)))
            if !current.windows.isEmpty {
                menu.addItem(item("Remember “\(current.name)” Arrangement", #selector(rememberCurrent)))
            }
        }
        menu.addItem(.separator())

        if let loadError {
            let problem = NSMenuItem(title: "rooms.json has a problem", action: nil, keyEquivalent: "")
            problem.isEnabled = false
            menu.addItem(problem)
            let detail = NSMenuItem(title: loadError, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
        } else {
            let keys = Room.withShortcuts(rooms)
            let out = Set(desk.rooms.values)
            for room in rooms {
                let n = keys.first { $0.value.id == room.id }?.key
                let entry = item(room.name, #selector(chooseRoom(_:)), key: n.map(String.init) ?? "")
                entry.keyEquivalentModifierMask = [.control, .option]
                entry.representedObject = room.id
                entry.state = room.id == currentRoomID || out.contains(room.id) ? .on : .off
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Show Everything", #selector(showAll)))

        let snapMenu = NSMenu()
        for (i, b) in SnapBinding.all.enumerated() {
            if [4, 8, 13, 15, 16].contains(i) { snapMenu.addItem(.separator()) }
            let entry = item(b.command.title, #selector(snapFromMenu(_:)), key: b.menuKey)
            entry.keyEquivalentModifierMask = b.menuModifiers
            entry.representedObject = i
            snapMenu.addItem(entry)
        }
        snapMenu.addItem(.separator())
        let keysToggle = item("Snapping Keys", #selector(toggleSnapKeys))
        keysToggle.state = snapKeysOn ? .on : .off
        snapMenu.addItem(keysToggle)
        let snapItem = NSMenuItem(title: "Snap Window", action: nil, keyEquivalent: "")
        snapItem.submenu = snapMenu
        menu.addItem(snapItem)

        menu.addItem(item("Edit Rooms…", #selector(editRooms), key: ","))

        let shortcuts = NSMenu()
        for s in Shortcut.all {
            let entry = item(s.label, #selector(chooseShortcut(_:)))
            entry.representedObject = s.id
            entry.state = HotkeyCenter.shared.current == s ? .on : .off
            shortcuts.addItem(entry)
        }
        let shortcutItem = NSMenuItem(title: "Keyboard Shortcut", action: nil, keyEquivalent: "")
        shortcutItem.submenu = shortcuts
        menu.addItem(shortcutItem)

        if !rooms.isEmpty { menu.addItem(item("Getting Started", #selector(showWelcome))) }   // otherwise it leads the menu
        menu.addItem(.separator())
        menu.addItem(item("Quit Rooms", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = target ?? self
        return entry
    }

    @objc private func openPalette() { palette.show() }

    @objc private func showWelcome() {
        welcome.show(shortcut: HotkeyCenter.shared.current?.label ?? Shortcut.optionSpace.label, needsAccess: !AX.isTrusted) {
            AX.requestTrust()
            AX.openAccessibilitySettings()
        }
    }

    @objc private func chooseRoom(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let room = rooms.first(where: { $0.id == id }) else { return }
        inTurn { await self.walk(into: room) }
    }

    @objc private func showAll() {
        // In turn, so a switch queued before it can't mark its room current afterwards.
        inTurn { [unowned self] in
            engine.restoreEverything()
            var d = desk
            d.clear()
            desk = d
            updateStatusTitle()
        }
    }

    @objc private func newRoom() { openPicker() }

    @objc private func rememberCurrent() {
        guard let current = rooms.first(where: { $0.id == currentRoomID }) else { return }
        rememberArrangement(of: current)
    }

    @objc private func editCurrent() {
        guard let current = rooms.first(where: { $0.id == currentRoomID }) else { return }
        openPicker(name: current.name)
    }

    @objc private func allowAccessibility() {
        AX.requestTrust()
        AX.openAccessibilitySettings()
    }

    @objc private func editRooms() {
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([RoomStore.defaultURL], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func chooseShortcut(_ sender: NSMenuItem) {
        let shortcut = Shortcut.named(sender.representedObject as? String)
        if HotkeyCenter.shared.register(shortcut) {
            defaults.set(shortcut.id, forKey: "shortcut")
        } else {
            warnShortcutTaken(shortcut)
            HotkeyCenter.shared.register(Shortcut.named(defaults.string(forKey: "shortcut")))
        }
    }

    private func warnShortcutTaken(_ shortcut: Shortcut) {
        let alert = NSAlert()
        alert.messageText = "\(shortcut.label) is already in use"
        alert.informativeText = "Another app has claimed this shortcut. Choose a different one from Keyboard Shortcut in the Rooms menu."
        NSApp.activate()
        alert.runModal()
    }
}
