import CoreGraphics
import Foundation
import Testing
@testable import RoomsCore

// MARK: Geometry

@Test func fractionsRoundTrip() {
    let screen = CGRect(x: 0, y: 25, width: 1728, height: 1092)
    let window = CGRect(x: 100, y: 125, width: 864, height: 546)
    let f = Geometry.fraction(of: window, in: screen)
    #expect(f == FractionalFrame(x: 0.0579, y: 0.0916, w: 0.5, h: 0.5))
    let back = Geometry.resolve(f, in: screen)
    #expect(abs(back.minX - window.minX) <= 1 && abs(back.minY - window.minY) <= 1)
    #expect(back.size == window.size)
}

@Test func fractionsMoveToAnotherScreen() {
    let f = FractionalFrame(x: 0, y: 0, w: 0.5, h: 1)
    let external = CGRect(x: 1728, y: -200, width: 2560, height: 1415)
    #expect(Geometry.resolve(f, in: external) == CGRect(x: 1728, y: -200, width: 1280, height: 1415))
}

@Test func cocoaToAX() {
    // A 1117-pt-tall primary screen; a Cocoa rect 100 pt above the bottom.
    let ax = Geometry.axRect(fromCocoa: CGRect(x: 10, y: 100, width: 200, height: 300), primaryHeight: 1117)
    #expect(ax == CGRect(x: 10, y: 717, width: 200, height: 300))
}

@Test func parksBottomRightWhenFree() {
    let screen = CGRect(x: 0, y: 25, width: 1728, height: 1092)
    let p = Geometry.parkingOrigin(windowSize: CGSize(width: 800, height: 600), screen: screen, otherScreens: [])
    #expect(p == CGPoint(x: 1727, y: 1116))
}

@Test func parksBottomLeftWhenADisplaySitsToTheRight() {
    let screen = CGRect(x: 0, y: 25, width: 1728, height: 1092)
    let right = CGRect(x: 1728, y: 0, width: 2560, height: 1440)
    let p = Geometry.parkingOrigin(windowSize: CGSize(width: 800, height: 600), screen: screen, otherScreens: [right])
    #expect(p == CGPoint(x: -799, y: 1116))
}

@Test func bestScreenByOverlap() {
    let a = CGRect(x: 0, y: 0, width: 1000, height: 800), b = CGRect(x: 1000, y: 0, width: 1000, height: 800)
    #expect(Geometry.bestScreen(for: CGRect(x: 900, y: 10, width: 400, height: 300), among: [a, b]) == 1)
    #expect(Geometry.bestScreen(for: CGRect(x: 5000, y: 5000, width: 10, height: 10), among: [a, b]) == nil)
}

// MARK: Slot matching

private let frame = FractionalFrame(x: 0, y: 0, w: 1, h: 1)

@Test func matchesByWindowIDFirst() {
    let slots = [WindowSlot(bundleID: "chrome", title: "Old title", windowID: 42, frame: frame)]
    let wins = [WindowInfo(bundleID: "chrome", title: "Old title", windowID: 7),
                WindowInfo(bundleID: "chrome", title: "Something else", windowID: 42)]
    #expect(SlotMatcher.assign(slots: slots, windows: wins) == [0: 1])
}

@Test func matchesByTitleAfterRelaunch() {
    let slots = [WindowSlot(bundleID: "figma", title: "Design — Flows v3", windowID: 1, frame: frame),
                 WindowSlot(bundleID: "figma", title: "Portfolio — Case studies", windowID: 2, frame: frame)]
    let wins = [WindowInfo(bundleID: "figma", title: "Portfolio — Case studies", windowID: 90),
                WindowInfo(bundleID: "figma", title: "Design — Flows v4", windowID: 91)]
    #expect(SlotMatcher.assign(slots: slots, windows: wins) == [0: 1, 1: 0])
}

@Test func aClosedSlotStaysUnmatchedWhenAnotherWindowRelaunches() {
    let slots = [WindowSlot(bundleID: "ghostty", title: "Project terminal", windowID: 1, frame: frame),
                 WindowSlot(bundleID: "ghostty", title: "Build terminal", windowID: 2, frame: frame)]
    // The first terminal relaunched (new window ID); the second is genuinely closed.
    let wins = [WindowInfo(bundleID: "ghostty", title: "Project terminal", windowID: 90)]
    #expect(SlotMatcher.assign(slots: slots, windows: wins) == [0: 0])
}

@Test func neverUsesAWindowTwice() {
    let slots = [WindowSlot(bundleID: "chrome", title: "A", frame: frame),
                 WindowSlot(bundleID: "chrome", title: "B", frame: frame),
                 WindowSlot(bundleID: "chrome", title: "C", frame: frame)]
    let wins = [WindowInfo(bundleID: "chrome", title: "Z", windowID: 1),
                WindowInfo(bundleID: "chrome", title: "B", windowID: 2)]
    let result = SlotMatcher.assign(slots: slots, windows: wins)
    #expect(result[1] == 1)
    #expect(Set(result.values).count == result.count)
    #expect(result.count == 2)
}

@Test func ignoresOtherApps() {
    let slots = [WindowSlot(bundleID: "teams", title: "Chat", frame: frame)]
    let wins = [WindowInfo(bundleID: "chrome", title: "Chat", windowID: 1)]
    #expect(SlotMatcher.assign(slots: slots, windows: wins).isEmpty)
}

// MARK: Storage

@Test func roomsWithWindowsRoundTrip() throws {
    let room = Room(name: "Design", apps: [AppRef("com.figma.Desktop")],
                    windows: [WindowSlot(bundleID: "com.figma.Desktop", app: "Figma", title: "Flows", windowID: 12, display: "ABC", frame: frame)])
    let url = FileManager.default.temporaryDirectory.appending(path: "rooms-w-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try RoomStore.save([room], to: url)
    #expect(try RoomStore.load(from: url) == [room])
}

@Test func ledgerRoundTrips() throws {
    var ledger = RestLedger()
    ledger.entries[5] = RestEntry(windowID: 5, bundleID: "chrome", title: "X", savedFrame: CGRect(x: 1, y: 2, width: 3, height: 4))
    let url = FileManager.default.temporaryDirectory.appending(path: "ledger-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try ledger.save(to: url)
    #expect(RestLedger.load(from: url).entries == ledger.entries)
}
