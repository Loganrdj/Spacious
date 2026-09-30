import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Many apps (Spotify, Xcode, …) refuse to shrink below a minimum window
/// size, and the OS offers no way to read that limit up front. Spacious learns
/// it by measurement and uses the helpers here to warn about zones that are
/// too small and to place oversized windows sensibly.

/// A zone that is smaller than an app's minimum window size.
public struct ZoneFitIssue: Equatable, Sendable {
    /// The zone's size in points on its monitor (after gaps).
    public var zoneSize: CGSize
    public var minimum: Size2D
    /// The smallest enlargement of the zone that fits, or nil if the app
    /// can't fit on this monitor at all.
    public var suggestedCells: CellRect?

    public var fitsOnMonitor: Bool { suggestedCells != nil }
}

public enum ZoneFitting {
    /// Sizes within this many points are treated as fitting (window sizes are
    /// often rounded, e.g. terminals snap to character cells).
    public static let tolerance: CGFloat = 2

    /// Returns an issue if a window with `minimum` size can't shrink to `cells`.
    public static func check(_ cells: CellRect, columns: Int, rows: Int, in size: CGSize, gap: CGFloat, minimum: Size2D) -> ZoneFitIssue? {
        let zone = GridMath.frame(for: cells, columns: columns, rows: rows, in: size, gap: gap)
        guard CGFloat(minimum.width) > zone.width + tolerance || CGFloat(minimum.height) > zone.height + tolerance else {
            return nil
        }
        return ZoneFitIssue(
            zoneSize: zone.size,
            minimum: minimum,
            suggestedCells: grow(cells, columns: columns, rows: rows, in: size, gap: gap, toFit: minimum)
        )
    }

    /// The smallest rect containing `cells` that is large enough for
    /// `minimum`, grown right/down and shifted left/up at the grid edges.
    public static func grow(_ cells: CellRect, columns: Int, rows: Int, in size: CGSize, gap: CGFloat, toFit minimum: Size2D) -> CellRect? {
        func span(current: Int, total: Int, needed: Double, length: (Int) -> CGFloat) -> Int? {
            (current...max(current, total)).first { length($0) + tolerance >= CGFloat(needed) }
        }
        let width = span(current: cells.width, total: columns, needed: minimum.width) { n in
            GridMath.frame(for: CellRect(col: 0, row: 0, width: n, height: 1), columns: columns, rows: rows, in: size, gap: gap).width
        }
        let height = span(current: cells.height, total: rows, needed: minimum.height) { n in
            GridMath.frame(for: CellRect(col: 0, row: 0, width: 1, height: n), columns: columns, rows: rows, in: size, gap: gap).height
        }
        guard let width, let height else { return nil }
        return CellRect(
            col: min(cells.col, columns - width),
            row: min(cells.row, rows - height),
            width: width,
            height: height
        )
    }

    /// Where to put a window that should fill `zone` but ended up `windowSize`
    /// (because of a minimum or maximum size). It is centered on the zone,
    /// then pushed back inside `bounds` so it never hangs off the monitor.
    /// Works in any coordinate space as long as all rects share it.
    public static func place(windowSize: CGSize, in zone: CGRect, bounds: CGRect) -> CGRect {
        var rect = CGRect(
            x: zone.midX - windowSize.width / 2,
            y: zone.midY - windowSize.height / 2,
            width: windowSize.width,
            height: windowSize.height
        )
        rect.origin.x = rect.width >= bounds.width ? bounds.minX : min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
        rect.origin.y = rect.height >= bounds.height ? bounds.minY : min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
        return rect.integral
    }

    /// Updates what we know about an app's minimum size after asking a window
    /// for `requested` and getting `actual`.
    ///
    /// - A dimension that came out larger than requested *is* the minimum.
    /// - A dimension that fit proves the minimum is at most the requested size,
    ///   so a stale, larger stored value is lowered.
    public static func learnedMinimum(previous: Size2D?, requested: CGSize, actual: CGSize) -> Size2D? {
        func dimension(_ previous: Double?, _ requested: CGFloat, _ actual: CGFloat) -> Double? {
            if actual > requested + tolerance { return Double(actual) }
            return previous.map { min($0, Double(requested)) }
        }
        let width = dimension(previous?.width, requested.width, actual.width)
        let height = dimension(previous?.height, requested.height, actual.height)
        if width == nil && height == nil { return previous }
        return Size2D(width: width ?? 0, height: height ?? 0)
    }
}
