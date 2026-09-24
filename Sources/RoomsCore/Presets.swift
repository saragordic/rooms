import Foundation

public struct RoomPreset: Sendable, Equatable, Identifiable {
    public struct Slot: Sendable, Equatable {
        public let candidates: [AppRef]
        public let cell: GridCell

        public init(_ candidates: [AppRef], cell: GridCell) {
            self.candidates = candidates
            self.cell = cell
        }
    }

    public let id: String
    public let name: String
    public let aliases: [String]
    public let kind: String
    public let about: String
    public let summary: String
    public let slots: [Slot]

    public static let meetings = RoomPreset(
        id: "meetings",
        name: "Meetings",
        aliases: ["call", "calls", "meet"],
        kind: "Work",
        about: "Calls: the meeting across the top, notes and the agenda in Safari below.",
        summary: "Zoom across the top, Notes and Safari below",
        slots: [
            Slot([AppRef("us.zoom.xos", name: "Zoom"), AppRef("com.microsoft.teams2", name: "Microsoft Teams")],
                 cell: GridCell(col: 0, cols: 12, row: 0, rows: 6)),
            Slot([AppRef("com.apple.Notes", name: "Notes")], cell: GridCell(col: 0, cols: 6, row: 6, rows: 6)),
            Slot([AppRef("com.apple.Safari", name: "Safari")], cell: GridCell(col: 6, cols: 6, row: 6, rows: 6)),
        ]
    )

    public static let all: [RoomPreset] = [.meetings]

    public static func named(_ id: String) -> RoomPreset? {
        all.first { $0.id == id } ?? all.first { Matcher.fold($0.name) == Matcher.fold(id) }
    }

    public func isAdded(to rooms: [Room]) -> Bool {
        rooms.contains { Matcher.fold($0.name) == Matcher.fold(name) }
    }

    public func room(existing rooms: [Room], isInstalled: (String) -> Bool) -> Room? {
        guard !isAdded(to: rooms) else { return nil }
        let windows = slots.compactMap { slot -> WindowSlot? in
            guard let app = slot.candidates.first(where: { isInstalled($0.bundleID) }) else { return nil }
            let u = Double(GridLayout.units)
            var window = WindowSlot(bundleID: app.bundleID, app: app.name, title: "",
                                    frame: FractionalFrame(x: Double(slot.cell.col) / u, y: Double(slot.cell.row) / u,
                                                           w: Double(slot.cell.cols) / u, h: Double(slot.cell.rows) / u))
            window.cell = slot.cell
            return window
        }
        guard !windows.isEmpty else { return nil }
        var room = Room(name: name, aliases: aliases, kind: kind, windows: windows, layout: .mine)
        room.about = about
        var n = 2
        while rooms.contains(where: { $0.id == room.id }) { room.id = Room.slug(name) + "-\(n)"; n += 1 }
        return room
    }
}

public struct PresetCatalog: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var summary: String
        public var about: String
        public var windows: [WindowSlot]
    }

    public var version: Int
    public var presets: [Entry]

    public init(presets: [RoomPreset] = RoomPreset.all, isInstalled: (String) -> Bool) {
        version = 1
        self.presets = presets.compactMap { preset in
            preset.room(existing: [], isInstalled: isInstalled).map {
                Entry(id: preset.id, name: preset.name, summary: preset.summary, about: preset.about, windows: $0.windows)
            }
        }
    }

    public static var defaultURL: URL {
        RoomStore.defaultURL.deletingLastPathComponent().appending(path: "presets.json")
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        if (try? Data(contentsOf: url)) == data { return }
        try data.write(to: url, options: .atomic)
    }
}
