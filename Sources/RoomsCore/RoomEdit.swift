import CoreGraphics

/// Editing a room's windows (adding or removing some in the picker) without
/// forgetting how you arranged the ones that stay.
public enum RoomEdit {
    /// The room's windows after an edit, in the order you chose. A window the room
    /// already had keeps its saved place (frame, display and My Layout cell); only its
    /// title and window number are refreshed so it's found again. New windows come in
    /// as they are, without a cell.
    /// `previous[i]`: the index of the existing slot chosen window `i` matches, or nil.
    public static func merge(existing: [WindowSlot], chosen: [WindowSlot], previous: [Int?]) -> [WindowSlot] {
        chosen.enumerated().map { i, fresh in
            guard i < previous.count, let p = previous[i], existing.indices.contains(p) else { return fresh }
            var slot = existing[p]
            slot.title = fresh.title
            slot.windowID = fresh.windowID
            slot.app = fresh.app ?? slot.app
            return slot
        }
    }

    /// The biggest empty part of the My Layout grid, if it's at least `minimum` units
    /// each way: where a new window can go without moving any other.
    public static func freeCell(around cells: [GridCell], minimum: Int = 3) -> GridCell? {
        let n = GridLayout.units
        var taken = Array(repeating: Array(repeating: false, count: n), count: n)
        for c in cells where GridLayout.valid([c]) {
            for row in c.row..<(c.row + c.rows) { for col in c.col..<(c.col + c.cols) { taken[row][col] = true } }
        }
        var best: GridCell?
        for row in 0..<n { for col in 0..<n where !taken[row][col] {
            // Widest free run on each row downwards, narrowing as it goes.
            var width = n - col
            for r in row..<n {
                var w = 0
                while w < width, !taken[r][col + w] { w += 1 }
                width = w
                guard width > 0 else { break }
                let rows = r - row + 1
                guard width >= minimum, rows >= minimum else { continue }
                if width * rows > (best.map { $0.cols * $0.rows } ?? 0) {
                    best = GridCell(col: col, cols: width, row: row, rows: rows)
                }
            }
        } }
        return best
    }

    /// Where a window with no place in the layout floats: where it is when that's
    /// fully on this display, otherwise in the middle of it (shrunk to fit if needed).
    public static func floatingFrame(_ rect: CGRect, in visible: CGRect) -> CGRect {
        if visible.contains(rect) { return rect }
        let size = CGSize(width: min(rect.width, visible.width), height: min(rect.height, visible.height))
        return CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// Which open windows float on top of My Layout instead of being laid out: those
    /// without a saved cell, as long as at least one window has one. With none, there
    /// is no My Layout to keep and the caller falls back to Auto as before.
    public static func floating(cells: [GridCell?]) -> [Int] {
        guard cells.contains(where: { $0 != nil }) else { return [] }
        return cells.indices.filter { cells[$0] == nil }
    }
}
