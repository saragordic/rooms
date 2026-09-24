import CoreGraphics
import Foundation
import Testing
@testable import RoomsCore

private func everything(_: String) -> Bool { true }

@Test func meetingsPutsZoomOnTopAndNotesBesideSafari() throws {
    let room = try #require(RoomPreset.meetings.room(existing: [], isInstalled: everything))
    #expect(room.name == "Meetings")
    #expect(room.layout == .mine)
    #expect(room.windows.map(\.bundleID) == ["us.zoom.xos", "com.apple.Notes", "com.apple.Safari"])
    #expect(room.windows.allSatisfy { $0.title.isEmpty && $0.windowID == nil })

    let rects = GridLayout.frames(room.windows.compactMap(\.cell), in: CGRect(x: 0, y: 0, width: 1512, height: 945))
    #expect(rects[0].width > rects[1].width + rects[2].width)
    #expect(rects[0].maxY < rects[1].minY)
    #expect(rects[1].minY == rects[2].minY)
    #expect(rects[1].maxX < rects[2].minX)
}

@Test func meetingsFallsBackToTeamsWithoutZoom() throws {
    let room = try #require(RoomPreset.meetings.room(existing: []) { $0 != "us.zoom.xos" })
    #expect(room.windows.first?.bundleID == "com.microsoft.teams2")
}

@Test func missingCallAppLeavesNotesAndSafariSideBySide() throws {
    let room = try #require(RoomPreset.meetings.room(existing: []) { $0.hasPrefix("com.apple") })
    #expect(room.windows.count == 2)
    let cells = GridLayout.fillingHoles(room.windows.compactMap(\.cell))
    #expect(cells.allSatisfy { $0.row == 0 && $0.rows == 12 })
}

@Test func presetIsNotAddedTwice() {
    #expect(RoomPreset.meetings.room(existing: [Room(name: "meetings")], isInstalled: everything) == nil)
    #expect(RoomPreset.meetings.isAdded(to: [Room(name: "Meetings")]))
}

@Test func presetTakesAFreeID() throws {
    var renamed = Room(name: "Calls")
    renamed.id = "meetings"
    let room = try #require(RoomPreset.meetings.room(existing: [renamed], isInstalled: everything))
    #expect(room.id == "meetings-2")
}

@Test func presetRoomsRoundTripThroughRoomsJSON() throws {
    let room = try #require(RoomPreset.meetings.room(existing: [], isInstalled: everything))
    let data = try JSONEncoder().encode(RoomsFile(rooms: [room]))
    #expect(try JSONDecoder().decode(RoomsFile.self, from: data).rooms == [room])
}

@Test func findsPresetByIDOrName() {
    #expect(RoomPreset.named("meetings") == .meetings)
    #expect(RoomPreset.named("Meetings") == .meetings)
    #expect(RoomPreset.named("standup") == nil)
}

@Test func catalogListsPresetsWithTheirInstalledApps() throws {
    let catalog = PresetCatalog { $0 != "us.zoom.xos" }
    let meetings = try #require(catalog.presets.first)
    #expect(meetings.id == "meetings")
    #expect(meetings.windows.map(\.bundleID) == ["com.microsoft.teams2", "com.apple.Notes", "com.apple.Safari"])
    #expect(meetings.windows.allSatisfy { $0.cell != nil })
}

@Test func catalogSkipsPresetsWithNothingInstalled() {
    #expect(PresetCatalog { _ in false }.presets.isEmpty)
}

@Test func catalogRoundTrips() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "presets-\(UUID().uuidString).json")
    let catalog = PresetCatalog { _ in true }
    try catalog.save(to: url)
    #expect(try JSONDecoder().decode(PresetCatalog.self, from: Data(contentsOf: url)) == catalog)
}
