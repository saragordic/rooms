import CoreGraphics
import Testing
@testable import RoomsCore

private func slot(_ bundleID: String, _ title: String, id: UInt32?, cell: GridCell? = nil, x: Double = 0) -> WindowSlot {
    var s = WindowSlot(bundleID: bundleID, app: bundleID, title: title, windowID: id, display: "D", frame: FractionalFrame(x: x, y: 0, w: 0.5, h: 1))
    s.cell = cell
    return s
}

private let left = GridCell(col: 0, cols: 6, row: 0, rows: 12)
private let right = GridCell(col: 6, cols: 6, row: 0, rows: 12)

@Test func editKeepsEachWindowsPlaceAndAddsNewOnesWithoutACell() {
    let existing = [slot("a", "A", id: 1, cell: left, x: 0), slot("b", "B", id: 2, cell: right, x: 0.5)]
    // The picker hands back fresh slots (frames where the windows happen to be now).
    let chosen = [slot("b", "B renamed", id: 22, x: 0.3), slot("c", "C", id: 3, x: 0.7), slot("a", "A", id: 1, x: 0.1)]
    let merged = RoomEdit.merge(existing: existing, chosen: chosen, previous: [1, nil, 0])
    #expect(merged.map(\.bundleID) == ["b", "c", "a"])
    #expect(merged[0].cell == right && merged[0].frame.x == 0.5)
    #expect(merged[0].title == "B renamed" && merged[0].windowID == 22)
    #expect(merged[2].cell == left && merged[2].frame.x == 0)
    #expect(merged[1].cell == nil && merged[1].frame.x == 0.7)
}

@Test func aFullGridHasNoFreeCell() {
    #expect(RoomEdit.freeCell(around: [left, right]) == nil)
}

@Test func theFreedSpaceOfARemovedWindowIsOffered() {
    let topRight = GridCell(col: 6, cols: 6, row: 0, rows: 6)
    #expect(RoomEdit.freeCell(around: [left, topRight]) == GridCell(col: 6, cols: 6, row: 6, rows: 6))
}

@Test func theBiggestFreeRectangleWins() {
    // Left third taken, plus a small top-right corner: the big middle-and-below area wins.
    let third = GridCell(col: 0, cols: 4, row: 0, rows: 12)
    let corner = GridCell(col: 10, cols: 2, row: 0, rows: 2)
    let free = RoomEdit.freeCell(around: [third, corner])
    #expect(free == GridCell(col: 4, cols: 8, row: 2, rows: 10))
}

@Test func slithersOfSpaceAreTooSmall() {
    let most = GridCell(col: 0, cols: 10, row: 0, rows: 12)
    #expect(RoomEdit.freeCell(around: [most]) == nil)
    #expect(RoomEdit.freeCell(around: [most], minimum: 2) == GridCell(col: 10, cols: 2, row: 0, rows: 12))
}

@Test func onlyCelllessWindowsFloatAndOnlyBesideAMyLayout() {
    #expect(RoomEdit.floating(cells: [left, nil, right, nil]) == [1, 3])
    #expect(RoomEdit.floating(cells: [nil, nil]) == [])
    #expect(RoomEdit.floating(cells: [left, right]) == [])
}

@Test func aFloatingWindowStaysPutOnScreenOrComesToTheMiddle() {
    let visible = CGRect(x: 0, y: 37, width: 1728, height: 1080)
    let onScreen = CGRect(x: 200, y: 300, width: 600, height: 400)
    #expect(RoomEdit.floatingFrame(onScreen, in: visible) == onScreen)
    // Parked off-screen (a 1-pt sliver showing), or on another display.
    let parked = CGRect(x: 1727, y: 1116, width: 600, height: 400)
    #expect(RoomEdit.floatingFrame(parked, in: visible) == CGRect(x: 564, y: 377, width: 600, height: 400))
    let huge = CGRect(x: -3000, y: 0, width: 2500, height: 1400)
    #expect(RoomEdit.floatingFrame(huge, in: visible) == visible)
}

// MARK: Space left empty on purpose

@Test func aHalfLeftEmptyOnPurposeStaysEmpty() {
    // Don's 3d room: X as a narrow column, Bambu Studio beside it, the right half free.
    let area = CGRect(x: 0, y: 37, width: 3840, height: 1590)
    let x = CGRect(x: 16, y: 53, width: 622, height: 1558)
    let bambu = CGRect(x: 654, y: 53, width: 1579, height: 1558)
    let cells = GridLayout.cells(for: [x, bambu], in: area)!
    #expect(cells[1].col + cells[1].cols <= 7)
    // So a window added later takes the free half instead of floating over a stretched Bambu.
    let free = RoomEdit.freeCell(around: cells)!
    #expect(free.col == cells[1].col + cells[1].cols && free.col + free.cols == 12 && free.rows == 12)
}

@Test func slightlyLooseWindowsStillCloseTheirSlivers() {
    let area = CGRect(x: 0, y: 37, width: 1728, height: 1080)
    // Left window a little short of the middle, right window a little short of the edge.
    let cells = GridLayout.cells(for: [CGRect(x: 16, y: 53, width: 760, height: 1048),
                                       CGRect(x: 900, y: 53, width: 700, height: 1048)], in: area)!
    #expect(cells.map { $0.cols * $0.rows }.reduce(0, +) == 144)
}
