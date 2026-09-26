import Foundation
import CoreGraphics
import Testing
@testable import RoomsCore

// A 1728×1080 usable area starting under a 37-pt menu bar.
private let area = CGRect(x: 0, y: 37, width: 1728, height: 1080)
private let g = Tiler.gap

private func noOverlaps(_ frames: [CGRect]) -> Bool {
    for i in frames.indices { for j in frames.indices where i < j {
        if frames[i].intersects(frames[j]) && !frames[i].intersection(frames[j]).isEmpty { return false }
    } }
    return true
}

private func inside(_ frames: [CGRect]) -> Bool {
    frames.allSatisfy { area.insetBy(dx: g - 1, dy: g - 1).contains($0) }
}

@Test func oneWindowFillsWithMargins() {
    #expect(Tiler.frames(count: 1, kind: .auto, in: area) == [area.insetBy(dx: g, dy: g)])
}

@Test func focusHeroIsLargeAndLeft() {
    let f = Tiler.frames(count: 3, kind: .focus, in: area)
    #expect(f.count == 3)
    #expect(f[0].minX == g && f[0].height == area.height - 2 * g)
    #expect(f[0].width > f[1].width)
    // The two side windows share the right column, stacked with one gap between them.
    #expect(f[1].minX == f[2].minX)
    #expect(f[2].minY - f[1].maxY == g)
    #expect(f[1].minX - f[0].maxX == g)
    #expect(noOverlaps(f) && inside(f))
}

@Test func evenGapsEverywhere() {
    for kind in [LayoutKind.focus, .columns, .grid] {
        for n in 1...8 {
            let f = Tiler.frames(count: n, kind: kind, in: area)
            #expect(f.count == n)
            #expect(noOverlaps(f), "\(kind) \(n) overlaps")
            #expect(inside(f), "\(kind) \(n) leaves the screen")
        }
    }
}

@Test func gridStretchesTheLastRow() {
    let f = Tiler.frames(count: 3, kind: .grid, in: area) // 2 columns: 2 on top, 1 full-width below
    #expect(f[2].width > f[0].width)
    #expect(f[2].minX == f[0].minX)
}

@Test func autoFitsTheScreen() {
    let monitor = CGRect(x: 0, y: 25, width: 2560, height: 1390)
    #expect(Tiler.frames(count: 3, kind: .auto, in: area) == Tiler.frames(count: 3, kind: .focus, in: area))
    #expect(Tiler.frames(count: 4, kind: .auto, in: area) == Tiler.frames(count: 4, kind: .grid, in: area))   // laptop: a 2 × 2 grid, not a stack
    #expect(Tiler.frames(count: 4, kind: .auto, in: monitor) == Tiler.frames(count: 4, kind: .focus, in: monitor))
    #expect(Tiler.frames(count: 6, kind: .auto, in: monitor) == Tiler.frames(count: 6, kind: .grid, in: monitor))
}

@Test func layoutCycles() {
    #expect(LayoutKind.auto.next == .focus)
    #expect(LayoutKind.saved.next == .auto)
    #expect(LayoutKind.grid.next == .mine)
    #expect(LayoutKind.focus.next == .stack)
    #expect(LayoutKind.auto.previous == .saved)
}

@Test func oldRoomsGetAutoLayout() throws {
    let json = #"{"version":1,"rooms":[{"name":"Research"}]}"#
    let file = try JSONDecoder().decode(RoomsFile.self, from: Data(json.utf8))
    #expect(file.rooms[0].layout == .auto)
}

@Test func pinnedWindowReservesItsRectangle() {
    let pinned = CGRect(x: area.maxX - area.width / 2, y: area.maxY - area.height / 2, width: area.width / 2, height: area.height / 2)
    let rest = PinnedLayout.frames(count: 3, around: pinned, in: area)!
    #expect(rest.count == 3)
    #expect(rest.allSatisfy { area.contains($0) && $0.intersection(pinned).isNull })
}

@Test func aPinnedLeftColumnKeepsDonsFourWindowMyLayout() {
    let cells = [
        GridCell(col: 0, cols: 2, row: 0, rows: 12),  // pinned sidebar, left column
        GridCell(col: 2, cols: 6, row: 0, rows: 12),  // chat, centre
        GridCell(col: 8, cols: 4, row: 0, rows: 6),   // editor, top-right
        GridCell(col: 8, cols: 4, row: 6, rows: 6),   // browser, bottom-right
    ]
    let saved = MineLayout.frames(cells: cells.map(Optional.some), in: area)!
    let pin = saved[0]
    let kept = PinnedLayout.keepingMyLayout(saved, pinAt: 0, pin: pin, in: area)
    #expect(kept == saved)
}

@Test func aPinThatRunsIntoMyLayoutStillFallsBack() {
    let cells = [
        GridCell(col: 0, cols: 2, row: 0, rows: 12),
        GridCell(col: 2, cols: 6, row: 0, rows: 12),
        GridCell(col: 8, cols: 4, row: 0, rows: 6),
        GridCell(col: 8, cols: 4, row: 6, rows: 6),
    ]
    let saved = MineLayout.frames(cells: cells.map(Optional.some), in: area)!
    let conflicting = CGRect(x: saved[0].minX, y: saved[0].minY,
                             width: saved[1].minX - saved[0].minX + g, height: saved[0].height)
    #expect(PinnedLayout.keepingMyLayout(saved, pinAt: 0, pin: conflicting, in: area) == nil)
}

@Test func aFullScreenPinHasNoRoomForAnotherWindow() {
    #expect(PinnedLayout.frames(count: 1, around: area, in: area) == nil)
}

@Test func pinnedLayoutUsesTheRequestedLayoutInTheLargestFreeRegion() {
    let pinned = CGRect(x: area.maxX - area.width / 2, y: area.maxY - area.height / 2, width: area.width / 2, height: area.height / 2)
    let free = PinnedLayout.largestFreeRegion(around: pinned, in: area)!
    #expect(PinnedLayout.frames(count: 2, kind: .columns, around: pinned, in: area) == Tiler.frames(count: 2, kind: .columns, in: free))
}

// MARK: Minimum sizes (Figma won't go below 900×600, Outlook 1142×684…)

@Test func distributeKeepsMinimums() {
    let sizes = Tiler.distribute(1000, gap: 16, mins: [0, 600], weights: [0.6, 0.4])
    #expect(sizes[1] == 600)
    #expect(sizes[0] == CGFloat(384), "\(sizes[0].bitPattern)")
}

@Test func distributeWithoutMinimumsFollowsWeights() {
    #expect(Tiler.distribute(1016, gap: 16, mins: [0, 0], weights: [0.6, 0.4]) == [600, 400])
}

@Test func focusMakesRoomForAWideSideWindow() {
    // Claude (hero), Notes, Figma (needs 900 wide) on a 1728-wide screen.
    let mins = [CGSize.zero, .zero, CGSize(width: 900, height: 600)]
    let f = Tiler.frames(count: 3, kind: .focus, in: area, mins: mins)
    #expect(f[2].width >= 900)
    #expect(f[1].width >= 900)               // the side column is shared
    #expect(f[0].maxX + g == f[1].minX)      // hero shrank to make space, same gap
    #expect(noOverlaps(f) && inside(f))
}

@Test func stackRespectsMinimumHeights() {
    let mins = [CGSize.zero, CGSize(width: 0, height: 684), .zero]
    let f = Tiler.frames(count: 3, kind: .focus, in: area, mins: mins)
    #expect(f[1].height >= 684)
    #expect(f[2].minY - f[1].maxY == g)
    #expect(noOverlaps(f) && inside(f))
}

@Test func columnsRespectMinimumWidths() {
    let mins = [CGSize(width: 900, height: 0), .zero, .zero]
    let f = Tiler.frames(count: 3, kind: .columns, in: area, mins: mins)
    #expect(f[0].width >= 900)
    #expect(abs(f[1].width - f[2].width) <= 1)
    #expect(noOverlaps(f) && inside(f))
}

@Test func noMinimumsMatchesPlainLayout() {
    for kind in [LayoutKind.focus, .columns, .grid] {
        #expect(Tiler.frames(count: 5, kind: kind, in: area) == Tiler.frames(count: 5, kind: kind, in: area, mins: Array(repeating: .zero, count: 5)))
    }
}

// MARK: When minimums don't fit in the preferred arrangement

@Test func tallMinimumsChooseAnotherArrangementOnALaptop() {
    // A room on a laptop: a notes app + a chat app (≥360 tall), Chrome (≥454), Claude (≥400).
    // Stacked in one column they need 1246 pt; the screen gives 968.
    let laptop = CGRect(x: 0, y: 33, width: 1728, height: 1000)
    let mins = [CGSize.zero, CGSize(width: 0, height: 360), CGSize(width: 0, height: 454), CGSize(width: 0, height: 400)]
    let f = Tiler.frames(count: 4, kind: .focus, in: laptop, mins: mins)
    let a = laptop.insetBy(dx: g, dy: g)
    #expect(f.allSatisfy { a.insetBy(dx: -1, dy: -1).contains($0) }, "every window stays on screen")
    #expect(f[1].height >= 360 && f[2].height >= 454 && f[3].height >= 400)
    #expect(noOverlapsIn(f))
}

@Test func impossibleMinimumsStillStayOnScreen() {
    let small = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let mins = Array(repeating: CGSize(width: 800, height: 500), count: 4)
    for kind in [LayoutKind.focus, .columns, .grid] {
        let f = Tiler.frames(count: 4, kind: kind, in: small, mins: mins)
        #expect(f.allSatisfy { $0.minX >= small.minX && $0.minY >= small.minY && $0.maxX <= small.maxX && $0.maxY <= small.maxY },
                "\(kind): overlap is acceptable, off-screen is not")
    }
}

private func noOverlapsIn(_ frames: [CGRect]) -> Bool {
    for i in frames.indices { for j in frames.indices where i < j {
        let x = frames[i].intersection(frames[j])
        if !x.isNull && x.width > 0 && x.height > 0 { return false }
    } }
    return true
}

@Test func wideAndTallMinimumsOnALaptop() {
    // The same room once Rooms knows the widths too: Teams ≥360×360, Chrome ≥606×454, Claude ≥?×400.
    let laptop = CGRect(x: 0, y: 33, width: 1728, height: 1000)
    let mins = [CGSize.zero, CGSize(width: 360, height: 360), CGSize(width: 606, height: 454), CGSize(width: 0, height: 400)]
    let f = Tiler.frames(count: 4, kind: .focus, in: laptop, mins: mins)
    let a = laptop.insetBy(dx: g, dy: g)
    #expect(f.allSatisfy { a.insetBy(dx: -1, dy: -1).contains($0) }, "all on screen")
    #expect(noOverlapsIn(f))
    #expect(f[1].width >= 360 && f[2].width >= 606 && f[2].height >= 454 && f[3].height >= 400)
    // The main window keeps most of the width (Claude's unknown width still gets a
    // usable 320 pt beside Teams): the wide Chrome window takes the full-width row.
    #expect(f[0].width >= (a.width - g) * 0.55)
    #expect(f[2].width > f[1].width)
}

// MARK: Stack and a screen-aware Auto

private let laptopArea = CGRect(x: 0, y: 33, width: 1728, height: 1000)
private let monitorArea = CGRect(x: 0, y: 25, width: 2560, height: 1390)
private let typicalMins = [CGSize.zero, CGSize(width: 360, height: 360), CGSize(width: 606, height: 454), CGSize(width: 600, height: 400)]

@Test func autoTilesWheneverSomethingTidyFits() {
    #expect(Tiler.autoKind(count: 4, in: laptopArea, mins: typicalMins) == .grid)
    #expect(Tiler.autoKind(count: 4, in: monitorArea, mins: typicalMins) == .focus)
    #expect(Tiler.autoKind(count: 2, in: laptopArea) == .focus)
}

@Test func threeAppsOnTheLaptopGoSideBySide() {
    // Claude, ChatGPT (won't go below 721 tall) and Teams: they can't share a side
    // column, but three columns fit, so no overlapping stack.
    let mins = [CGSize(width: 600, height: 400), CGSize(width: 480, height: 721), CGSize(width: 360, height: 360)]
    #expect(Tiler.autoKind(count: 3, in: laptopArea, mins: mins) == .columns)
}

@Test func autoStacksOnlyWhenNothingElseFits() {
    let figma = CGSize(width: 900, height: 600)
    #expect(Tiler.autoKind(count: 3, in: laptopArea, mins: [figma, figma, figma]) == .stack)
}

@Test func stackShowsEveryTitleBar() {
    let f = Tiler.frames(count: 4, kind: .stack, in: laptopArea, mins: typicalMins)
    let a = laptopArea.insetBy(dx: g, dy: g)
    #expect(f.allSatisfy { a.insetBy(dx: -1, dy: -1).contains($0) })
    #expect(f[0].width >= (a.width - g) * 0.6 - 1)                 // the main window keeps its share
    let side = Array(f.dropFirst())
    #expect(Set(side.map(\.size.width)).count == 1 && Set(side.map(\.size.height)).count == 1)
    // The second window sits lowest (frontmost); the others peek out above it.
    #expect(side[0].minY > side[1].minY && side[1].minY > side[2].minY)
    #expect(side[0].minY - side[1].minY == Tiler.peek)
    #expect(side.allSatisfy { $0.height >= 454 })                  // Chrome's minimum still fits
}

@Test func roomShortcutsDefaultToTheFirstNine() {
    let rooms = (1...11).map { Room(name: "Room \($0)") }
    let map = Room.withShortcuts(rooms)
    #expect(map.count == 9 && map[1]?.name == "Room 1" && map[9]?.name == "Room 9")
    var chosen = rooms
    chosen[5].shortcut = 1
    #expect(Room.withShortcuts(chosen) == [1: chosen[5]])
}

// MARK: Nothing overlaps (real screens, real apps' minimum sizes)

private let screens = [CGRect(x: 0, y: 33, width: 1728, height: 1084), CGRect(x: 0, y: 25, width: 3360, height: 1385)]
private let appMins = [CGSize(width: 900, height: 600), CGSize(width: 606, height: 454), CGSize(width: 600, height: 400),
                       CGSize(width: 360, height: 360), .zero]

/// Every mix of apps for 1…6 windows (sampled), on a laptop and an ultrawide.
private func everyRoom(_ check: (CGRect, [CGSize]) -> Void) {
    for area in screens {
        for n in 1...6 {
            for seed in 0..<60 {
                var r = UInt64(seed * 7919 + n)
                let mins = (0..<n).map { _ -> CGSize in
                    r = r &* 6364136223846793005 &+ 1442695040888963407
                    return appMins[Int((r >> 33) % UInt64(appMins.count))]
                }
                check(area, mins)
            }
        }
    }
}

private func overlap(_ f: [CGRect]) -> CGFloat {
    var worst: CGFloat = 0
    for i in f.indices { for j in f.indices where i < j {
        let x = f[i].intersection(f[j])
        if !x.isNull { worst = max(worst, min(x.width, x.height)) }
    } }
    return worst
}

@Test func aLayoutThatFitsNeverOverlaps() {
    everyRoom { area, mins in
        for kind in [LayoutKind.focus, .columns, .grid] where Tiler.fits(count: mins.count, kind: kind, in: area, mins: mins) {
            let f = Tiler.frames(count: mins.count, kind: kind, in: area, mins: mins)
            #expect(overlap(f) == 0, "\(kind) \(mins) on \(area.width)")
            #expect(f.allSatisfy { area.insetBy(dx: Tiler.gap, dy: Tiler.gap).contains($0) }, "\(kind) \(mins) off screen")
        }
    }
}

@Test func autoOnlyOverlapsWhenItStacks() {
    everyRoom { area, mins in
        guard Tiler.autoKind(count: mins.count, in: area, mins: mins) != .stack else { return }
        #expect(overlap(Tiler.frames(count: mins.count, kind: .auto, in: area, mins: mins)) == 0, "\(mins) on \(area.width)")
    }
}

@Test func twoFigmasDontFitSideBySideOnALaptop() {
    let figma = CGSize(width: 900, height: 600)
    #expect(!Tiler.fits(count: 2, kind: .columns, in: laptopArea, mins: [figma, figma]))
    #expect(Tiler.autoKind(count: 2, in: laptopArea, mins: [figma, figma]) == .stack)
}

@Test func piecesAddUpExactly() {
    let w = Tiler.distribute(1000, gap: 16, mins: [0, 0, 0], weights: [1, 1, 1])
    #expect(w.reduce(CGFloat(0), +) == CGFloat(968))
}
