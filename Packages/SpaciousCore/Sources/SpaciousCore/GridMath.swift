import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Geometry for grids. All rects here are in a *local, top-left origin*
/// space: (0, 0) is the top-left corner of the monitor's usable area and y
/// grows downward. `Coordinates` converts to and from OS screen spaces.
public enum GridMath {
    /// The frame of `cells` inside a container of `size`.
    ///
    /// - `gap`: space between neighbouring zones. Zone edges on the outside of
    ///   the grid get none, so windows sit flush with the screen edges.
    /// - `margin`: optional space around the whole grid (screen edges).
    public static func frame(for cells: CellRect, columns: Int, rows: Int, in size: CGSize, gap: CGFloat = 0, margin: CGFloat = 0) -> CGRect {
        let container = CGRect(origin: .zero, size: size).insetBy(dx: max(margin, 0), dy: max(margin, 0))
        let cellW = container.width / CGFloat(max(columns, 1))
        let cellH = container.height / CGFloat(max(rows, 1))
        let raw = CGRect(
            x: container.minX + CGFloat(cells.col) * cellW,
            y: container.minY + CGFloat(cells.row) * cellH,
            width: CGFloat(cells.width) * cellW,
            height: CGFloat(cells.height) * cellH
        )
        // Half the gap on each side that faces another cell.
        let half = max(gap, 0) / 2
        let left = cells.col > 0 ? half : 0
        let top = cells.row > 0 ? half : 0
        let right = cells.col + cells.width < columns ? half : 0
        let bottom = cells.row + cells.height < rows ? half : 0
        return CGRect(
            x: raw.minX + left,
            y: raw.minY + top,
            width: raw.width - left - right,
            height: raw.height - top - bottom
        ).integral
    }

    /// The cell under a local point, clamped to the grid so drags that leave
    /// the grid still resolve to an edge cell. Returns nil for empty sizes.
    public static func cell(at point: CGPoint, columns: Int, rows: Int, in size: CGSize) -> GridCell? {
        guard size.width > 0, size.height > 0, columns > 0, rows > 0 else { return nil }
        let col = Int((point.x / size.width * CGFloat(columns)).rounded(.down))
        let row = Int((point.y / size.height * CGFloat(rows)).rounded(.down))
        return GridCell(col: min(max(col, 0), columns - 1), row: min(max(row, 0), rows - 1))
    }

    /// Like `cell(at:)` but nil when the point is outside the container.
    public static func cellIfInside(_ point: CGPoint, columns: Int, rows: Int, in size: CGSize) -> GridCell? {
        guard CGRect(origin: .zero, size: size).contains(point) else { return nil }
        return cell(at: point, columns: columns, rows: rows, in: size)
    }
}

/// Conversions between coordinate spaces.
///
/// - *Cocoa* global space (NSScreen): origin at the bottom-left of the primary
///   display, y grows upward.
/// - *AX/CG* global space (Accessibility, CGWindow): origin at the top-left of
///   the primary display, y grows downward.
/// - *Local* space: top-left of a given screen rect, y grows downward.
public enum Coordinates {
    /// Converts a rect between Cocoa and AX global spaces. The transform is
    /// its own inverse, so this works in both directions.
    public static func flip(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Converts a point between Cocoa and AX global spaces (self-inverse).
    public static func flip(_ point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// A local (top-left origin) rect inside `screenRect` (Cocoa space) → Cocoa global rect.
    public static func cocoaRect(fromLocal local: CGRect, in screenRect: CGRect) -> CGRect {
        CGRect(x: screenRect.minX + local.minX, y: screenRect.maxY - local.maxY, width: local.width, height: local.height)
    }

    /// A Cocoa global point → local point inside `screenRect` (Cocoa space).
    public static func localPoint(fromCocoa point: CGPoint, in screenRect: CGRect) -> CGPoint {
        CGPoint(x: point.x - screenRect.minX, y: screenRect.maxY - point.y)
    }

    /// A local rect inside `screenRect` (Cocoa space) → AX global rect, ready
    /// to hand to the Accessibility API.
    public static func axRect(fromLocal local: CGRect, in screenRect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        flip(cocoaRect(fromLocal: local, in: screenRect), primaryScreenHeight: primaryScreenHeight)
    }
}
