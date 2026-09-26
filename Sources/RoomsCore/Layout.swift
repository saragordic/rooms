import CoreGraphics

/// How a room arranges its windows.
public enum LayoutKind: String, Codable, CaseIterable, Sendable {
    /// Fits the screen: Focus or Grid when every window gets a comfortable size,
    /// Stack when it wouldn't (a laptop with several windows).
    case auto
    /// The first window large on the left, the rest stacked on the right.
    case focus
    /// The first window large on the left; the rest share the right column as a stack
    /// of cards, their title bars peeking out so any of them is one click away.
    case stack
    /// Side-by-side columns.
    case columns
    /// An even grid.
    case grid
    /// Your own combination, snapped to a 12-column grid with even gaps.
    case mine
    /// Exactly where the windows were when the room was saved.
    case saved

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .focus: "Focus"
        case .columns: "Columns"
        case .grid: "Grid"
        case .stack: "Stack"
        case .mine: "My Layout"
        case .saved: "As Saved"
        }
    }

    public var next: LayoutKind {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    public var previous: LayoutKind {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + all.count - 1) % all.count]
    }
}

/// Computes tidy window frames with even gaps. Pure geometry in AX space (y down).
public enum Tiler {
    /// Space between windows and around the edge of the screen (8-pt grid).
    public static let gap: CGFloat = 16

    /// `mins`: each window's smallest allowed size (apps like Figma refuse to go
    /// smaller). The layout gives those windows the room they need and shares
    /// what's left among the others. Pass none, or one per window.
    public static func frames(count n: Int, kind: LayoutKind, in area: CGRect, gap: CGFloat = gap, mins: [CGSize] = []) -> [CGRect] {
        guard n > 0 else { return [] }
        let mins = mins.count == n ? mins : Array(repeating: .zero, count: n)
        let a = area.insetBy(dx: gap, dy: gap)
        if kind == .saved || kind == .mine { return Array(repeating: a, count: n) } // callers use the room's own frames or cells
        if kind == .auto { return frames(count: n, kind: autoKind(count: n, in: area, gap: gap, mins: mins), in: area, gap: gap, mins: mins) }
        if kind == .stack { return stack(n, in: a, gap: gap, mins: mins).map { clamp($0, into: a) } }

        // Try arrangements in order of preference; take the first where every window
        // fits on screen at its minimum size. If none does, take the one that spills
        // least, then pull every window back onto the screen (overlap beats off-screen).
        let candidates = arrangements(n, kind: kind, in: a, gap: gap, mins: mins)
        let best = candidates.first { works($0, in: a) }
            ?? candidates.min { overflow($0, in: a) < overflow($1, in: a) }
            ?? []
        return best.map { clamp($0, into: a) }
    }

    private static func arrangements(_ n: Int, kind: LayoutKind, in a: CGRect, gap: CGFloat, mins given: [CGSize]) -> [[CGRect]] {
        // Every window gets at least `usable`, known minimum or not, so the others
        // share what's left instead of squeezing one to nothing.
        let mins = given.map { CGSize(width: max($0.width, usable.width), height: max($0.height, usable.height)) }
        switch kind {
        case .focus:
            guard n > 1 else { return [[a]] }
            let side = Array(1..<n)
            let preferredColumns = side.count > 3 ? 2 : 1
            // The side windows in your order, and with the widest moved last, where a
            // short final row stretches to the full column width.
            var orders = [side]
            if let widest = side.max(by: { mins[$0].width < mins[$1].width }), widest != side.last, mins[widest].width > 0 {
                orders.append(side.filter { $0 != widest } + [widest])
            }
            var options: [(rects: [CGRect], heroWidth: CGFloat, preferred: Bool, reordered: Bool)] = []
            for share in [0.6, 0.5] as [CGFloat] {
                for columns in 1...min(3, side.count) {
                    for (o, order) in orders.enumerated() {
                        let sideMinWidth = rowMinWidth(order, columns: columns, mins: mins, gap: gap)
                        let widths = distribute(a.width, gap: gap, mins: [mins[0].width, sideMinWidth], weights: [share, 1 - share])
                        let hero = CGRect(x: a.minX, y: a.minY, width: widths[0], height: a.height)
                        let sideRect = CGRect(x: hero.maxX + gap, y: a.minY, width: widths[1], height: a.height)
                        let sideRects = grid(order.count, columns: columns, in: sideRect, gap: gap, mins: order.map { mins[$0] })
                        var rects = Array(repeating: CGRect.zero, count: n)
                        rects[0] = hero
                        for (k, index) in order.enumerated() { rects[index] = sideRects[k] }
                        options.append((rects, widths[0], columns == preferredColumns && share == 0.6 && o == 0, o > 0))
                    }
                }
            }
            // Your usual layout first; after that, whatever keeps the main window largest.
            return options.sorted { x, y in
                if x.preferred != y.preferred { return x.preferred }
                if abs(x.heroWidth - y.heroWidth) > 1 { return x.heroWidth > y.heroWidth }
                return !x.reordered && y.reordered
            }.map(\.rects)
        case .columns:
            let preferred = min(n, 4)
            return ([preferred] + (1..<preferred).reversed()).map { grid(n, columns: $0, in: a, gap: gap, mins: mins) }
        default: // grid
            let preferred = Int(Double(n).squareRoot().rounded(.up))
            return [preferred, preferred + 1, max(1, preferred - 1)].filter { $0 <= n }
                .map { grid(n, columns: $0, in: a, gap: gap, mins: mins) }
        }
    }

    /// The narrowest a column of rows can be: its widest row of minimum widths.
    static func rowMinWidth(_ order: [Int], columns: Int, mins: [CGSize], gap: CGFloat) -> CGFloat {
        stride(from: 0, to: order.count, by: columns).map { start in
            let row = order[start..<min(order.count, start + columns)]
            return row.map { mins[$0].width }.reduce(0, +) + gap * CGFloat(row.count - 1)
        }.max() ?? 0
    }

    /// How far (in points) windows spill outside the area, summed.
    static func overflow(_ rects: [CGRect], in a: CGRect) -> CGFloat {
        rects.reduce(0) { sum, r in
            sum + max(0, a.minX - r.minX) + max(0, r.maxX - a.maxX) + max(0, a.minY - r.minY) + max(0, r.maxY - a.maxY)
        }
    }

    /// True when every rectangle is inside the area and none overlap: a layout that
    /// can be used as it is.
    public static func isClean(_ rects: [CGRect], in area: CGRect) -> Bool {
        guard overflow(rects, in: area) < 1 else { return false }
        for i in rects.indices { for j in rects.indices where i < j {
            let x = rects[i].intersection(rects[j])
            if !x.isNull, x.width > 1, x.height > 1 { return false }
        } }
        return true
    }

    /// Moves a rectangle back inside the area (it keeps its size).
    public static func clamp(_ r: CGRect, into a: CGRect) -> CGRect {
        var r = r
        if r.maxX > a.maxX { r.origin.x = max(a.minX, a.maxX - r.width) }
        if r.maxY > a.maxY { r.origin.y = max(a.minY, a.maxY - r.height) }
        r.origin.x = max(a.minX, r.origin.x)
        r.origin.y = max(a.minY, r.origin.y)
        return r
    }

    /// Below this, a tiled window stops being pleasant to work in.
    public static let comfortable = CGSize(width: 480, height: 360)
    /// The least any window gets in a tidy layout. An app whose minimum isn't known yet
    /// counts as 0, and without this floor a layout could "fit" by squeezing it to
    /// nothing (a 0-wide Granola beside WhatsApp on a laptop).
    public static let usable = CGSize(width: 320, height: 240)

    /// A tidy arrangement that can be used: on screen, every window at least `usable`.
    static func works(_ rects: [CGRect], in a: CGRect) -> Bool {
        overflow(rects, in: a) < 1 && rects.allSatisfy { $0.width >= usable.width - 1 && $0.height >= usable.height - 1 }
    }
    /// How much of each stacked window's title bar shows.
    public static let peek: CGFloat = 32

    /// What Auto means on this screen: tile when every window gets a comfortable size,
    /// otherwise stack (a laptop with four windows). Grid for many windows on big screens.
    public static func autoKind(count n: Int, in area: CGRect, gap: CGFloat = gap, mins: [CGSize] = []) -> LayoutKind {
        guard n > 1 else { return .focus }
        let mins = mins.count == n ? mins : Array(repeating: .zero, count: n)
        let a = area.insetBy(dx: gap, dy: gap)
        // Every tidy layout gets a turn (one big window with the rest beside it first,
        // a grid first for many windows). Stack, where windows overlap, is the last resort.
        let order: [LayoutKind] = n <= 4 ? [.focus, .columns, .grid] : [.grid, .columns, .focus]
        for kind in order {
            // Judge the arrangement before `frames` pulls spilling windows back on
            // screen, where they would overlap instead.
            // For Auto, Columns means one row: wrapping into uneven rows is what Grid is for.
            let options = arrangements(n, kind: kind, in: a, gap: gap, mins: mins)
                .filter { kind != .columns || Set($0.map(\.minY)).count == 1 }
            guard let fit = options.first(where: { works($0, in: a) }) else { continue }
            let roomy = fit.dropFirst().allSatisfy { $0.width >= comfortable.width - 1 && $0.height >= comfortable.height - 1 }
            if roomy { return kind }
        }
        return .stack
    }

    /// Whether `kind` can place `n` windows on this screen without any overlapping,
    /// given the apps' minimum sizes. Stack overlaps on purpose, so it always fits.
    public static func fits(count n: Int, kind: LayoutKind, in area: CGRect, gap: CGFloat = gap, mins: [CGSize] = []) -> Bool {
        guard n > 0 else { return false }
        switch kind {
        case .auto, .stack, .saved, .mine: return true
        default:
            let mins = mins.count == n ? mins : Array(repeating: .zero, count: n)
            let a = area.insetBy(dx: gap, dy: gap)
            return arrangements(n, kind: kind, in: a, gap: gap, mins: mins).contains { works($0, in: a) }
        }
    }

    /// Hero on the left; the side windows share one column, offset so the title bars
    /// of the ones behind stay visible. The second window is frontmost and lowest.
    static func stack(_ n: Int, in a: CGRect, gap: CGFloat, mins: [CGSize]) -> [CGRect] {
        guard n > 1 else { return [a] }
        let side = Array(mins.dropFirst())
        let sideMin = CGSize(width: side.map(\.width).max() ?? 0, height: side.map(\.height).max() ?? 0)
        let widths = distribute(a.width, gap: gap, mins: [mins[0].width, sideMin.width], weights: [0.6, 0.4])
        let hero = CGRect(x: a.minX, y: a.minY, width: widths[0], height: a.height)
        let m = side.count
        let peek = min(Tiler.peek, max(0, (a.height - sideMin.height) / CGFloat(max(1, m - 1))))
        let height = a.height - peek * CGFloat(m - 1)
        let x = hero.maxX + gap
        return [hero] + (0..<m).map { k in
            CGRect(x: x, y: a.minY + peek * CGFloat(m - 1 - k), width: widths[1], height: height)
        }
    }

    /// Rows of `columns`; a short last row stretches to fill the width.
    static func grid(_ n: Int, columns: Int, in r: CGRect, gap: CGFloat, mins: [CGSize]) -> [CGRect] {
        let rows = Int((Double(n) / Double(columns)).rounded(.up))
        let rowItems = (0..<rows).map { row in Array(row * columns ..< min(n, (row + 1) * columns)) }
        let heights = distribute(r.height, gap: gap,
                                 mins: rowItems.map { $0.map { mins[$0].height }.max() ?? 0 },
                                 weights: Array(repeating: 1, count: rows))
        var out: [CGRect] = []
        var y = r.minY
        for (row, items) in rowItems.enumerated() {
            let widths = distribute(r.width, gap: gap, mins: items.map { mins[$0].width }, weights: Array(repeating: 1, count: items.count))
            var x = r.minX
            for w in widths {
                out.append(CGRect(x: x.rounded(), y: y.rounded(), width: w, height: heights[row]))
                x += w + gap
            }
            y += heights[row] + gap
        }
        return out
    }

    /// Splits `total` (minus gaps) by `weights`, but never below `mins`. Anything
    /// taken by a minimum comes out of the flexible items. If even the minimums
    /// don't fit, they are kept and the row overflows (apps won't shrink further).
    public static func distribute(_ total: CGFloat, gap: CGFloat, mins: [CGFloat], weights: [CGFloat]) -> [CGFloat] {
        let n = mins.count
        guard n > 0 else { return [] }
        let available = total - gap * CGFloat(n - 1)
        var fixed = Array(repeating: false, count: n)
        var sizes = Array(repeating: CGFloat(0), count: n)
        while true {
            let flexibleWeight = (0..<n).filter { !fixed[$0] }.map { weights[$0] }.reduce(0, +)
            let fixedSpace = (0..<n).filter { fixed[$0] }.map { sizes[$0] }.reduce(0, +)
            guard flexibleWeight > 0 else { break }
            var changed = false
            for i in 0..<n where !fixed[i] {
                sizes[i] = max(0, available - fixedSpace) * weights[i] / flexibleWeight
            }
            for i in 0..<n where !fixed[i] && sizes[i] < mins[i] {
                sizes[i] = mins[i]
                fixed[i] = true
                changed = true
            }
            if !changed { break }
        }
        // Round so the pieces still add up to the space (rounding each on its own can
        // make a row a point or two too wide, and the last window then overlaps).
        var rounded = sizes.map { $0.rounded(.down) }
        var spare = Int((available - rounded.reduce(0, +)).rounded(.down))
        for i in sizes.indices.sorted(by: { sizes[$0] - rounded[$0] > sizes[$1] - rounded[$1] }) where spare > 0 {
            rounded[i] += 1
            spare -= 1
        }
        return rounded
    }
}

/// Places a room's unpinned windows in the rectangular space around one fixed
/// window. Each edge region is independent, so no unpinned window can overlap the
/// reserved rectangle.
public enum PinnedLayout {
    public static func largestFreeRegion(around pinned: CGRect, in area: CGRect) -> CGRect? {
        guard !pinned.isNull, area.contains(pinned) else { return nil }
        return [
            CGRect(x: area.minX, y: area.minY, width: area.width, height: pinned.minY - area.minY),
            CGRect(x: area.minX, y: pinned.maxY, width: area.width, height: area.maxY - pinned.maxY),
            CGRect(x: area.minX, y: pinned.minY, width: pinned.minX - area.minX, height: pinned.height),
            CGRect(x: pinned.maxX, y: pinned.minY, width: area.maxX - pinned.maxX, height: pinned.height),
        ].filter { $0.width >= Tiler.usable.width && $0.height >= Tiler.usable.height }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    /// Replaces a hand-saved window with its pin when every other frame leaves a
    /// normal layout gap around it. Nil keeps the caller on the safe tiled fallback.
    public static func keepingMyLayout(_ frames: [CGRect], pinAt index: Int, pin: CGRect, in area: CGRect, gap: CGFloat = Tiler.gap) -> [CGRect]? {
        guard frames.indices.contains(index), !pin.isNull, pin.width > 0, pin.height > 0,
              area.contains(pin) else { return nil }
        var kept = frames
        kept[index] = pin
        // A one-point tolerance avoids rejecting the rounding that occurs when a
        // fractional pin is resolved on a display, while retaining a visible gap.
        let reserved = pin.insetBy(dx: -(gap - 1), dy: -(gap - 1))
        guard kept.indices.allSatisfy({ $0 == index || !kept[$0].intersects(reserved) }) else { return nil }
        let safeArea = area.insetBy(dx: Tiler.gap - 1, dy: Tiler.gap - 1)
        return Tiler.isClean(kept, in: safeArea) ? kept : nil
    }

    public static func frames(count n: Int, kind: LayoutKind, around pinned: CGRect, in area: CGRect, mins: [CGSize] = []) -> [CGRect]? {
        guard let free = largestFreeRegion(around: pinned, in: area) else { return nil }
        return Tiler.frames(count: n, kind: kind, in: free, mins: mins).allSatisfy(free.contains)
            ? Tiler.frames(count: n, kind: kind, in: free, mins: mins) : nil
    }

    public static func frames(count n: Int, around pinned: CGRect, in area: CGRect, mins: [CGSize] = []) -> [CGRect]? {
        guard n >= 0, !pinned.isNull, area.contains(pinned) else { return nil }
        guard n > 0 else { return [] }
        let mins = mins.count == n ? mins : Array(repeating: .zero, count: n)
        let regions = [
            CGRect(x: area.minX, y: area.minY, width: area.width, height: pinned.minY - area.minY),
            CGRect(x: area.minX, y: pinned.maxY, width: area.width, height: area.maxY - pinned.maxY),
            CGRect(x: area.minX, y: pinned.minY, width: pinned.minX - area.minX, height: pinned.height),
            CGRect(x: pinned.maxX, y: pinned.minY, width: area.maxX - pinned.maxX, height: pinned.height),
        ].filter { $0.width >= Tiler.usable.width && $0.height >= Tiler.usable.height }
        guard !regions.isEmpty else { return nil }

        var assignments = Array(repeating: [Int](), count: regions.count)
        for index in 0..<n {
            // Spread windows by available area so a large side of the pin takes more
            // of the room, while small strips are not overfilled first.
            let target = assignments.indices.max { left, right in
                let leftSpace = regions[left].width * regions[left].height / CGFloat(assignments[left].count + 1)
                let rightSpace = regions[right].width * regions[right].height / CGFloat(assignments[right].count + 1)
                return leftSpace < rightSpace
            }!
            assignments[target].append(index)
        }

        var result = Array(repeating: CGRect.zero, count: n)
        for (region, indexes) in zip(regions, assignments) where !indexes.isEmpty {
            let frames = Tiler.frames(count: indexes.count, kind: .auto, in: region, mins: indexes.map { mins[$0] })
            guard frames.allSatisfy(region.contains) else { return nil }
            for (index, frame) in zip(indexes, frames) { result[index] = frame }
        }
        return result
    }
}
