import Foundation
import Testing
@testable import RoomsCore

private func command(_ s: String) -> RoomsCommand? { URL(string: s).flatMap(RoomsCommand.init(url:)) }

@Test func walksIntoRoomByID() { #expect(command("rooms://room/deep-work") == .walk(room: "deep-work", layout: nil)) }
@Test func walksWithLayout() { #expect(command("rooms://room/deep-work?layout=grid") == .walk(room: "deep-work", layout: .grid)) }
@Test func decodesRoomKey() { #expect(command("rooms://room/Deep%20Work") == .walk(room: "Deep Work", layout: nil)) }
@Test func refusesUnknownLayout() { #expect(command("rooms://room/deep-work?layout=spiral") == nil) }
@Test func refusesMissingRoom() { #expect(command("rooms://room") == nil) }
@Test func refusesNestedPath() { #expect(command("rooms://room/a/b") == nil) }
@Test func showsEverything() { #expect(command("rooms://show-everything") == .showEverything) }
@Test func opensPalette() { #expect(command("ROOMS://palette") == .palette) }
@Test func refusesOtherSchemes() { #expect(command("https://room/deep-work") == nil) }
@Test func refusesUnknownCommand() { #expect(command("rooms://delete/deep-work") == nil) }

@Test func findsRoomByIDThenName() {
    let rooms = [Room(name: "Deep Work"), Room(id: "x", name: "Café")]
    #expect(Room.find("deep-work", in: rooms)?.name == "Deep Work")
    #expect(Room.find("cafe", in: rooms)?.id == "x")
    #expect(Room.find("nope", in: rooms) == nil)
}

@Test func opensPickerForNewRoom() { #expect(command("rooms://new?name=%20Design%20") == .newRoom(name: "Design")) }
@Test func opensPickerWithoutName() { #expect(command("rooms://new") == .newRoom(name: "")) }
@Test func addsPreset() { #expect(command("rooms://preset/meetings") == .addPreset(id: "meetings")) }
@Test func refusesPresetWithoutID() { #expect(command("rooms://preset") == nil) }
