import Testing
@testable import RoomsCore

private let laptop = "LAPTOP", monitor = "MONITOR", tv = "TV"

@Test func twoRoomsOnTwoDisplays() {
    var desk = Desk()
    desk.enter("a", on: monitor)
    desk.enter("b", on: laptop)
    #expect(desk.rooms == [monitor: "a", laptop: "b"])
    #expect(desk.current == "b")
    // Walking into b on the laptop leaves a alone on the monitor.
    #expect(desk.others(than: laptop, connected: [laptop, monitor]) == [monitor: "a"])
}

@Test func aRoomReplacesTheOneOnItsDisplay() {
    var desk = Desk()
    desk.enter("a", on: monitor)
    desk.enter("b", on: laptop)
    desk.enter("c", on: laptop)
    #expect(desk.rooms == [monitor: "a", laptop: "c"])
}

@Test func aRoomIsOutOnOneDisplayOnly() {
    var desk = Desk()
    desk.enter("a", on: monitor)
    desk.enter("b", on: laptop)
    desk.enter("a", on: laptop)
    #expect(desk.rooms == [laptop: "a"])
    #expect(desk.display(of: "a") == laptop)
    #expect(desk.display(of: "b") == nil)
}

@Test func roomsOnDisconnectedDisplaysAreLeftToBeHidden() {
    var desk = Desk(rooms: [monitor: "a", tv: "b"], current: "a")
    #expect(desk.others(than: laptop, connected: [laptop, monitor]) == [monitor: "a"])
}

@Test func deletingOrShowingEverythingEmptiesTheDesk() {
    var desk = Desk(rooms: [monitor: "a", laptop: "b"], current: "b")
    desk.remove("b")
    #expect(desk == Desk(rooms: [monitor: "a"], current: nil))
    desk.clear()
    #expect(desk == Desk())
}

@Test func pluggingInAMonitorBringsTheOnlyRoomThere() {
    var desk = Desk(rooms: [laptop: "a"], current: "a")
    desk.settle(connected: [laptop, monitor], largest: monitor)
    #expect(desk.rooms == [monitor: "a"])
}

@Test func unpluggingBringsTheRoomYoureInToWhatsLeft() {
    var desk = Desk(rooms: [laptop: "a", monitor: "b"], current: "b")
    desk.settle(connected: [laptop], largest: laptop)
    #expect(desk.rooms == [laptop: "b"])
    #expect(desk.current == "b")
}

@Test func unpluggingAnotherRoomsDisplayKeepsYoursInPlace() {
    var desk = Desk(rooms: [laptop: "a", monitor: "b"], current: "a")
    desk.settle(connected: [laptop], largest: laptop)
    #expect(desk.rooms == [laptop: "a"])
}

@Test func aThirdDisplayLeavesTwoRoomsWhereTheyAre() {
    var desk = Desk(rooms: [laptop: "a", monitor: "b"], current: "a")
    desk.settle(connected: [laptop, monitor, tv], largest: tv)
    #expect(desk.rooms == [laptop: "a", monitor: "b"])
}

@Test func aRoomFromBeforeDisplaysFollowsTheMonitor() {
    var desk = Desk(current: "a")
    desk.settle(connected: [laptop, monitor], largest: monitor)
    #expect(desk.rooms == [monitor: "a"])
}

@Test func nothingOutStaysNothingOut() {
    var desk = Desk()
    desk.settle(connected: [laptop, monitor], largest: monitor)
    #expect(desk == Desk())
}
