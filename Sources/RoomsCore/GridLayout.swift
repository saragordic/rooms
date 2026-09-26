import CoreGraphics

/// Where a window sits on a 12 × 12 grid: your own combinations (three thirds on top,
/// ⅔ + ⅓ below) kept as proportions and drawn with the same even gaps as every layout.
public struct GridCell: Codable, Hashable, Sendable {
    public var col: Int, cols: Int, row: Int, rows: Int
    public init(col: Int, cols: Int, row: Int, rows: Int) {
        self.col = col; self.cols = cols; self.row = row; self.rows = rows
    }
}

public enum GridLayout {
    public static let units = 12

    /// Snaps windows to the grid. Nil when they overlap (a cascade or a stack isn't a
    /// grid) or a window is too small to place.
    public static func cells(for frames: [CGRect], in area: CGRect, gap: CGFloat = Tiler.gap) -> [GridCell]? {
        let a = area.insetBy(dx: gap, dy: gap)
        guard a.width.isFinite, a.height.isFinite, a.minX.isFinite, a.minY.isFinite,
              a.width > 0, a.height > 0 else { return nil }
        func snap(_ v: CGFloat, _ origin: CGFloat, _ length: CGFloat) -> Int {
            Int(max(0, min(CGFloat(units), ((v - origin) / length * CGFloat(units)).rounded())))
        }
        var cells: [GridCell] = []
        for f in frames {
            guard !f.isInfinite, f.minX.isFinite, f.maxX.isFinite, f.minY.isFinite, f.maxY.isFinite else { return nil }
            let c0 = snap(f.minX, a.minX, a.width), c1 = snap(f.maxX, a.minX, a.width)
            let r0 = snap(f.minY, a.minY, a.height), r1 = snap(f.maxY, a.minY, a.height)
            guard c1 > c0, r1 > r0 else { return nil }
            cells.append(GridCell(col: c0, cols: c1 - c0, row: r0, rows: r1 - r0))
        }
        for i in cells.indices { for j in cells.indices where i < j {
            let x = cells[i].col < cells[j].col + cells[j].cols && cells[j].col < cells[i].col + cells[i].cols
            let y = cells[i].row < cells[j].row + cells[j].rows && cells[j].row < cells[i].row + cells[i].rows
            if x && y { return nil }
        } }
        return fillingHoles(cells)
    }

    /// Grows windows into empty grid space beside them, so a layout never keeps a gap
    /// that was only there because the windows weren't quite touching.
    public static func fillingHoles(_ cells: [GridCell]) -> [GridCell] {
        guard valid(cells) else { return cells }
        var cells = cells
        func free(_ col: Int, _ row: Int, except i: Int) -> Bool {
            guard (0..<units).contains(col), (0..<units).contains(row) else { return false }
            return !cells.indices.contains { j in
                j != i && col >= cells[j].col && col < cells[j].col + cells[j].cols && row >= cells[j].row && row < cells[j].row + cells[j].rows
            }
        }
        var grew = true
        while grew {
            grew = false
            for i in cells.indices {
                let c = cells[i]
                let rows = c.row..<(c.row + c.rows)
                if rows.allSatisfy({ free(c.col - 1, $0, except: i) }) { cells[i].col -= 1; cells[i].cols += 1; grew = true }
                if rows.allSatisfy({ free(c.col + c.cols, $0, except: i) }) { cells[i].cols += 1; grew = true }
                // Include newly grown columns when checking the corners.
                let cols = cells[i].col..<(cells[i].col + cells[i].cols)
                if cols.allSatisfy({ free($0, c.row - 1, except: i) }) { cells[i].row -= 1; cells[i].rows += 1; grew = true }
                if cols.allSatisfy({ free($0, c.row + c.rows, except: i) }) { cells[i].rows += 1; grew = true }
            }
        }
        return cells
    }

    static func valid(_ cells: [GridCell]) -> Bool {
        cells.allSatisfy { c in
            (0..<units).contains(c.col) && (0..<units).contains(c.row)
                && c.cols > 0 && c.cols <= units - c.col
                && c.rows > 0 && c.rows <= units - c.row
        }
    }

    /// Draws cells with exactly one `gap` between neighbours and around the edge.
    /// `mins`: each window's smallest size. Columns and rows holding a window that
    /// won't shrink are widened, and the others give up the space, so nothing overlaps.
    public static func frames(_ cells: [GridCell], in area: CGRect, gap: CGFloat = Tiler.gap, mins: [CGSize] = [], fillHoles: Bool = true) -> [CGRect] {
        guard valid(cells) else {
            return Tiler.frames(count: cells.count, kind: .auto, in: area, gap: gap, mins: mins)
        }
        let a = area.insetBy(dx: gap, dy: gap)
        let mins = mins.count == cells.count ? mins : Array(repeating: .zero, count: cells.count)
        let cells = fillHoles ? fillingHoles(cells) : cells

        // What each column and row must be at least, spreading a window's minimum
        // across the columns (or rows) it spans.
        var colMin = [CGFloat](repeating: 0, count: units), rowMin = colMin
        for (c, m) in zip(cells, mins) {
            let perCol = (m.width - gap * CGFloat(c.cols - 1)) / CGFloat(c.cols)
            for i in c.col..<min(units, c.col + c.cols) { colMin[i] = max(colMin[i], perCol) }
            let perRow = (m.height - gap * CGFloat(c.rows - 1)) / CGFloat(c.rows)
            for i in c.row..<min(units, c.row + c.rows) { rowMin[i] = max(rowMin[i], perRow) }
        }
        let widths = Tiler.distribute(a.width, gap: gap, mins: colMin, weights: Array(repeating: 1, count: units))
        let heights = Tiler.distribute(a.height, gap: gap, mins: rowMin, weights: Array(repeating: 1, count: units))
        func edge(_ sizes: [CGFloat], _ start: CGFloat, _ index: Int) -> CGFloat {
            start + sizes.prefix(index).reduce(0, +) + gap * CGFloat(index)
        }
        return cells.map { c in
            let x0 = edge(widths, a.minX, c.col), x1 = edge(widths, a.minX, c.col + c.cols) - gap
            let y0 = edge(heights, a.minY, c.row), y1 = edge(heights, a.minY, c.row + c.rows) - gap
            // Round edges, not sizes, so gaps stay exact.
            return CGRect(x: x0.rounded(), y: y0.rounded(), width: x1.rounded() - x0.rounded(), height: y1.rounded() - y0.rounded())
        }
    }
}

/// Draws the cells saved for My Layout. A subset keeps its own cells exactly: a
/// closed window leaves a hole instead of causing an open neighbour to grow into it.
public enum MineLayout {
    /// Nil means an open window has no saved cell, or the saved cells cannot be
    /// placed safely. The caller can then use Auto for every open window.
    public static func frames(cells: [GridCell?], in area: CGRect, mins: [CGSize] = []) -> [CGRect]? {
        guard !cells.contains(where: { $0 == nil }) else { return nil }
        let saved = cells.compactMap { $0 }
        guard GridLayout.valid(saved) else { return nil }
        let rects = GridLayout.frames(saved, in: area, mins: mins, fillHoles: false)
        let safeArea = area.insetBy(dx: Tiler.gap - 1, dy: Tiler.gap - 1)
        return Tiler.isClean(rects, in: safeArea) ? rects : nil
    }
}
