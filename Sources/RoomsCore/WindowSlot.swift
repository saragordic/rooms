import CoreGraphics
import Foundation

/// One window that belongs to a room, and where it goes.
public struct WindowSlot: Codable, Hashable, Sendable {
    public var bundleID: String
    /// App name, for people reading rooms.json.
    public var app: String?
    /// The window's title when the room was saved. Used to find it again.
    public var title: String
    /// The window's identity while it stays open. Survives until the window closes.
    public var windowID: UInt32?
    /// Which display it was on (a display UUID).
    public var display: String?
    public var frame: FractionalFrame
    /// Its place in "My Layout", if the room has one.
    public var cell: GridCell?

    public init(bundleID: String, app: String? = nil, title: String, windowID: UInt32? = nil, display: String? = nil, frame: FractionalFrame) {
        self.bundleID = bundleID
        self.app = app
        self.title = title
        self.windowID = windowID
        self.display = display
        self.frame = frame
    }
}

/// A window kept in the same relative place whenever it appears in a room.
/// Window IDs identify an open window exactly; its title lets the pin survive a
/// relaunch, provided the new window still has the same title.
public struct WindowPin: Codable, Hashable, Sendable {
    public var bundleID: String
    public var title: String
    public var windowID: UInt32?
    public var frame: FractionalFrame

    public init(bundleID: String, title: String, windowID: UInt32?, frame: FractionalFrame) {
        self.bundleID = bundleID
        self.title = title
        self.windowID = windowID
        self.frame = frame
    }

    public func matches(_ window: WindowInfo) -> Bool {
        guard bundleID == window.bundleID else { return false }
        if let windowID, window.windowID == windowID { return true }
        if title.isEmpty { return true }
        return !title.isEmpty && title == window.title
    }
}

/// A live window, reduced to what matching needs.
public struct WindowInfo: Sendable, Equatable {
    public var bundleID: String
    public var title: String
    public var windowID: UInt32?

    public init(bundleID: String, title: String, windowID: UInt32?) {
        self.bundleID = bundleID
        self.title = title
        self.windowID = windowID
    }
}

/// Decides which live window fills which slot. Each window is used at most once.
public enum SlotMatcher {
    /// Returns slot index → window index. `claimed`: windows that belong to other rooms;
    /// the last, any-window-of-the-app pass takes one of those only when the app has
    /// no other window to offer.
    public static func assign(slots: [WindowSlot], windows: [WindowInfo], claimed: Set<UInt32> = []) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var used = Set<Int>()

        func pass(_ accepts: (WindowSlot, WindowInfo) -> Bool) {
            for (s, slot) in slots.enumerated() where result[s] == nil {
                if let w = windows.indices.first(where: { !used.contains($0) && windows[$0].bundleID == slot.bundleID && accepts(slot, windows[$0]) }) {
                    result[s] = w
                    used.insert(w)
                }
            }
        }

        // Strongest evidence first.
        pass { slot, win in slot.windowID != nil && slot.windowID == win.windowID }
        pass { slot, win in !slot.title.isEmpty && slot.title == win.title }
        // A title that only looks alike ("Project A", "Project B") never takes another room's window.
        pass { slot, win in similar(slot.title, win.title) && !(win.windowID.map(claimed.contains) ?? false) }
        // Browsers change their title with every tab (and window numbers change when they
        // restart), so finally accept any window of the app: a free one first.
        pass { _, win in win.windowID.map { !claimed.contains($0) } ?? true }
        pass { _, _ in true }
        return result
    }

    /// Titles that share a meaningful part: "Report — draft 3" vs "Report — draft 4".
    static func similar(_ a: String, _ b: String) -> Bool {
        let fa = Matcher.fold(a), fb = Matcher.fold(b)
        guard fa.count >= 4, fb.count >= 4 else { return false }
        if fa.contains(fb) || fb.contains(fa) { return true }
        let common = zip(fa, fb).prefix { $0 == $1 }.count
        return common >= min(12, min(fa.count, fb.count) * 2 / 3)
    }
}

/// Windows Rooms has parked off-screen, with the frame to put them back at.
/// Written to disk before anything moves, so nothing is ever lost.
public struct RestEntry: Codable, Hashable, Sendable {
    public var windowID: UInt32
    public var bundleID: String
    public var title: String
    public var savedFrame: CGRect

    public init(windowID: UInt32, bundleID: String, title: String, savedFrame: CGRect) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.title = title
        self.savedFrame = savedFrame
    }
}

public struct RestLedger: Codable, Sendable {
    public var entries: [UInt32: RestEntry] = [:]

    public init() {}

    public static var defaultURL: URL {
        RoomStore.defaultURL.deletingLastPathComponent().appending(path: "resting.json")
    }

    /// An unreadable file isn't silently dropped: it's moved aside as
    /// resting.unreadable-<time>.json (the only record of where parked windows
    /// belong; each one kept) and Rooms starts a new one.
    public static func load(from url: URL = defaultURL) -> RestLedger {
        guard let data = try? Data(contentsOf: url) else { return RestLedger() }
        if let ledger = try? JSONDecoder().decode(RestLedger.self, from: data) { return ledger }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingLastPathComponent().appending(path: "resting.unreadable-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        return RestLedger()
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
