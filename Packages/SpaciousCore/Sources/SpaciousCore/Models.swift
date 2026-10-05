import Foundation

// Platform-neutral data model. Everything here is plain Codable data so the
// same `layouts.json` format can be reused by a future Windows port.

/// A single cell coordinate in a grid. Row 0 is the top row.
public struct GridCell: Hashable, Sendable {
    public var col: Int
    public var row: Int

    public init(col: Int, row: Int) {
        self.col = col
        self.row = row
    }
}

/// A rectangular block of grid cells, measured in cell units (not pixels) so
/// zones survive resolution changes.
public struct CellRect: Codable, Hashable, Sendable {
    public var col: Int
    public var row: Int
    public var width: Int
    public var height: Int

    public init(col: Int, row: Int, width: Int, height: Int) {
        self.col = col
        self.row = row
        self.width = max(1, width)
        self.height = max(1, height)
    }

    /// The smallest rect containing both cells, regardless of drag direction.
    public init(from a: GridCell, to b: GridCell) {
        let minCol = min(a.col, b.col), maxCol = max(a.col, b.col)
        let minRow = min(a.row, b.row), maxRow = max(a.row, b.row)
        self.init(col: minCol, row: minRow, width: maxCol - minCol + 1, height: maxRow - minRow + 1)
    }

    public var area: Int { width * height }

    public func contains(_ cell: GridCell) -> Bool {
        cell.col >= col && cell.col < col + width && cell.row >= row && cell.row < row + height
    }

    /// Proportionally rescales this rect from one grid size to another,
    /// e.g. the left half of a 2×1 grid stays the left half of a 20×10 grid.
    public func scaled(fromColumns oldCols: Int, rows oldRows: Int, toColumns newCols: Int, rows newRows: Int) -> CellRect {
        func scale(_ start: Int, _ length: Int, _ old: Int, _ new: Int) -> (Int, Int) {
            guard old > 0, new > 0 else { return (0, 1) }
            let factor = Double(new) / Double(old)
            var lo = Int((Double(start) * factor).rounded())
            var hi = Int((Double(start + length) * factor).rounded())
            lo = min(max(lo, 0), new - 1)
            hi = min(max(hi, lo + 1), new)
            return (lo, hi - lo)
        }
        let (c, w) = scale(col, width, oldCols, newCols)
        let (r, h) = scale(row, height, oldRows, newRows)
        return CellRect(col: c, row: r, width: w, height: h)
    }
}

/// A plain width/height pair (CGSize is not Hashable).
public struct Size2D: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = Size2D(width: 0, height: 0)
}

/// Something assigned to a zone: a whole app, one of its windows (matched by
/// title), or a browser tab (matched by URL). `bundleID` is always the app
/// that owns the window — for websites, the browser.
public struct AppRef: Codable, Hashable, Identifiable, Sendable {
    public var bundleID: String
    public var name: String
    /// When set, only a window whose title contains this text.
    public var windowTitle: String?
    /// When set, a browser tab whose URL starts with this (see `TargetMatching`).
    public var url: String?

    public init(bundleID: String, name: String, windowTitle: String? = nil, url: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.windowTitle = windowTitle
        self.url = url
    }

    public enum Kind: Equatable, Sendable {
        case app
        case window(title: String)
        case website(url: String)
    }

    public var kind: Kind {
        if let url { return .website(url: url) }
        if let windowTitle { return .window(title: windowTitle) }
        return .app
    }

    public var id: String { "\(bundleID)|\(windowTitle ?? "")|\(url ?? "")" }

    /// Short label for zone tiles and summaries.
    public var label: String {
        switch kind {
        case .app: name
        case .window(let title): "\(name): “\(title)”"
        case .website(let url): url
        }
    }
}

public enum ZoneColor: String, Codable, CaseIterable, Sendable {
    case blue, purple, pink, orange, yellow, green, teal, gray
}

/// A named region of a monitor's grid that apps can be assigned to.
public struct Zone: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var color: ZoneColor
    public var cells: CellRect
    public var apps: [AppRef]

    public init(id: UUID = UUID(), name: String, color: ZoneColor, cells: CellRect, apps: [AppRef] = []) {
        self.id = id
        self.name = name
        self.color = color
        self.cells = cells
        self.apps = apps
    }

    /// A human label: the zone name, or the assigned apps when unnamed.
    public var displayName: String {
        if !name.isEmpty { return name }
        if !apps.isEmpty { return apps.map(\.label).joined(separator: ", ") }
        return "Untitled zone"
    }
}

/// The grid configuration for one physical monitor.
public struct MonitorGrid: Codable, Hashable, Identifiable, Sendable {
    public static let maxDimension = 48

    /// Stable display UUID (CGDisplayCreateUUIDFromDisplayID on macOS).
    public var displayID: String
    public var displayName: String
    public var lastKnownSize: Size2D
    public private(set) var columns: Int
    public private(set) var rows: Int
    public var zones: [Zone]

    public var id: String { displayID }

    public init(displayID: String, displayName: String, lastKnownSize: Size2D, columns: Int = 4, rows: Int = 2, zones: [Zone] = []) {
        self.displayID = displayID
        self.displayName = displayName
        self.lastKnownSize = lastKnownSize
        self.columns = Self.clampDimension(columns)
        self.rows = Self.clampDimension(rows)
        self.zones = zones
    }

    public static func clampDimension(_ value: Int) -> Int {
        min(max(value, 1), maxDimension)
    }

    /// Changes the grid size, rescaling existing zones proportionally.
    public mutating func resize(columns newCols: Int, rows newRows: Int) {
        let c = Self.clampDimension(newCols), r = Self.clampDimension(newRows)
        guard c != columns || r != rows else { return }
        for i in zones.indices {
            zones[i].cells = zones[i].cells.scaled(fromColumns: columns, rows: rows, toColumns: c, rows: r)
        }
        columns = c
        rows = r
    }

    /// The zone at a cell. When zones overlap, the smallest one wins so
    /// nested zones stay reachable.
    public func zone(at cell: GridCell) -> Zone? {
        zones.filter { $0.cells.contains(cell) }.min { $0.cells.area < $1.cells.area }
    }

    /// The next color not yet used on this monitor (cycling when all are used).
    public var nextZoneColor: ZoneColor {
        let used = Set(zones.map(\.color))
        return ZoneColor.allCases.first { !used.contains($0) }
            ?? ZoneColor.allCases[zones.count % ZoneColor.allCases.count]
    }
}

/// A named set of monitor grids, e.g. "Coding" or "Meeting".
public struct Layout: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var monitors: [MonitorGrid]
    /// When applying, launch assigned apps that are not running.
    public var launchMissingApps: Bool

    public init(id: UUID = UUID(), name: String, monitors: [MonitorGrid] = [], launchMissingApps: Bool = false) {
        self.id = id
        self.name = name
        self.monitors = monitors
        self.launchMissingApps = launchMissingApps
    }

    public func grid(for displayID: String) -> MonitorGrid? {
        monitors.first { $0.displayID == displayID }
    }

    /// Returns a copy with fresh IDs, for "Duplicate layout".
    public func duplicated(name: String) -> Layout {
        var copy = self
        copy.id = UUID()
        copy.name = name
        for m in copy.monitors.indices {
            for z in copy.monitors[m].zones.indices {
                copy.monitors[m].zones[z].id = UUID()
            }
        }
        return copy
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    /// Space in points between zones and around screen edges.
    public var gap: Double
    public var shiftDragEnabled: Bool

    public init(gap: Double = 8, shiftDragEnabled: Bool = true) {
        self.gap = gap
        self.shiftDragEnabled = shiftDragEnabled
    }
}

/// Everything Spacious persists, stored as one JSON file.
public struct SpaciousDocument: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var layouts: [Layout]
    public var activeLayoutID: UUID?
    public var settings: AppSettings
    /// Learned minimum window sizes in points, keyed by bundle ID. Apps don't
    /// publish these, so Spacious measures them (see `ZoneFitting`).
    public var appMinimumSizes: [String: Size2D]

    public init(layouts: [Layout] = [Layout(name: "Default")], activeLayoutID: UUID? = nil, settings: AppSettings = AppSettings(),
                appMinimumSizes: [String: Size2D] = [:]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.layouts = layouts.isEmpty ? [Layout(name: "Default")] : layouts
        self.activeLayoutID = activeLayoutID ?? self.layouts.first?.id
        self.settings = settings
        self.appMinimumSizes = appMinimumSizes
    }

    // Custom decoding so files saved before a field existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        let layouts = try c.decode([Layout].self, forKey: .layouts)
        self.layouts = layouts.isEmpty ? [Layout(name: "Default")] : layouts
        activeLayoutID = try c.decodeIfPresent(UUID.self, forKey: .activeLayoutID) ?? self.layouts.first?.id
        settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        appMinimumSizes = try c.decodeIfPresent([String: Size2D].self, forKey: .appMinimumSizes) ?? [:]
    }

    public var activeLayoutIndex: Int {
        layouts.firstIndex { $0.id == activeLayoutID } ?? 0
    }
}
