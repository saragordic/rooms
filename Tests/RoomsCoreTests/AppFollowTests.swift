import Foundation
import Testing
@testable import RoomsCore

private func slot(_ bundleID: String) -> WindowSlot {
    WindowSlot(bundleID: bundleID, title: "", frame: FractionalFrame(x: 0, y: 0, w: 1, h: 1))
}

private let design = Room(name: "Design", windows: [slot("app.figma"), slot("app.chat")])
private let build = Room(name: "Build", windows: [slot("app.code"), slot("app.chat")])
private let reading = Room(name: "Reading", apps: [AppRef("app.books")])
private let rooms = [design, build, reading]

@Test func followsAnAppThatBelongsToOneOtherRoom() {
    #expect(AppFollow.room(for: "app.code", in: rooms, current: design.id)?.id == build.id)
}

@Test func followsIntoAppOnlyRooms() {
    #expect(AppFollow.room(for: "app.books", in: rooms, current: design.id)?.id == reading.id)
}

@Test func staysPutForAnAppInTheCurrentRoom() {
    #expect(AppFollow.room(for: "app.figma", in: rooms, current: design.id) == nil)
}

@Test func staysPutForASharedAppInRoomsNeverVisited() {
    let third = Room(name: "Write", windows: [slot("app.chat")])
    #expect(AppFollow.room(for: "app.chat", in: rooms + [third], current: reading.id) == nil)
}

@Test func followsASharedAppIntoTheMostRecentRoomHoldingIt() {
    let recency = [design.id: Date(timeIntervalSince1970: 100),
                   build.id: Date(timeIntervalSince1970: 200),
                   reading.id: Date(timeIntervalSince1970: 300)]
    #expect(AppFollow.room(for: "app.chat", in: rooms, current: reading.id, recency: recency)?.id == build.id)
}

@Test func followsASharedAppIntoTheOnlyVisitedRoomHoldingIt() {
    let recency = [design.id: Date(timeIntervalSince1970: 100)]
    #expect(AppFollow.room(for: "app.chat", in: rooms, current: reading.id, recency: recency)?.id == design.id)
}

@Test func staysPutForASharedAppThatIsAlsoInTheCurrentRoom() {
    #expect(AppFollow.room(for: "app.chat", in: rooms, current: design.id) == nil)
}

@Test func staysPutForAnAppInNoRoom() {
    #expect(AppFollow.room(for: "app.mail", in: rooms, current: design.id) == nil)
}

@Test func followsFromOutsideAnyRoom() {
    #expect(AppFollow.room(for: "app.code", in: rooms, current: nil)?.id == build.id)
}
