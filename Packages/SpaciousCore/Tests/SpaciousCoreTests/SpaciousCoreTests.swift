import XCTest
import CoreGraphics
@testable import SpaciousCore

final class GridMathTests: XCTestCase {
    let size = CGSize(width: 2000, height: 1000)

    func testLeftHalfWithoutGap() {
        let frame = GridMath.frame(for: CellRect(col: 0, row: 0, width: 10, height: 10), columns: 20, rows: 10, in: size)
        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 1000, height: 1000))
    }

    func testGapAppliesToOuterEdgesAndBetweenZones() {
        let gap: CGFloat = 10
        let left = GridMath.frame(for: CellRect(col: 0, row: 0, width: 1, height: 1), columns: 2, rows: 1, in: size, gap: gap)
        let right = GridMath.frame(for: CellRect(col: 1, row: 0, width: 1, height: 1), columns: 2, rows: 1, in: size, gap: gap)
        XCTAssertEqual(left.minX, 10)
        XCTAssertEqual(left.minY, 10)
        XCTAssertEqual(right.maxX, 1990)
        XCTAssertEqual(right.maxY, 990)
        XCTAssertEqual(right.minX - left.maxX, 10)
    }

    func testCellHitTestingClampsToGrid() {
        XCTAssertEqual(GridMath.cell(at: CGPoint(x: 150, y: 250), columns: 20, rows: 10, in: size), GridCell(col: 1, row: 2))
        XCTAssertEqual(GridMath.cell(at: CGPoint(x: -50, y: 5000), columns: 20, rows: 10, in: size), GridCell(col: 0, row: 9))
        XCTAssertNil(GridMath.cellIfInside(CGPoint(x: -1, y: 5), columns: 20, rows: 10, in: size))
    }

    func testCellRectFromDragIsNormalized() {
        let rect = CellRect(from: GridCell(col: 5, row: 4), to: GridCell(col: 2, row: 1))
        XCTAssertEqual(rect, CellRect(col: 2, row: 1, width: 4, height: 4))
    }
}

final class ModelTests: XCTestCase {
    func testResizeKeepsZoneProportions() {
        var grid = MonitorGrid(displayID: "A", displayName: "A", lastKnownSize: .zero, columns: 2, rows: 1,
                               zones: [Zone(name: "Left", color: .blue, cells: CellRect(col: 0, row: 0, width: 1, height: 1))])
        grid.resize(columns: 20, rows: 10)
        XCTAssertEqual(grid.zones[0].cells, CellRect(col: 0, row: 0, width: 10, height: 10))
        grid.resize(columns: 3, rows: 1)
        XCTAssertEqual(grid.zones[0].cells.col, 0)
        XCTAssertGreaterThanOrEqual(grid.zones[0].cells.width, 1)
        XCTAssertLessThanOrEqual(grid.zones[0].cells.col + grid.zones[0].cells.width, 3)
    }

    func testResizeClampsDimensions() {
        var grid = MonitorGrid(displayID: "A", displayName: "A", lastKnownSize: .zero)
        grid.resize(columns: 500, rows: 0)
        XCTAssertEqual(grid.columns, MonitorGrid.maxDimension)
        XCTAssertEqual(grid.rows, 1)
    }

    func testSmallestOverlappingZoneWins() {
        let big = Zone(name: "Big", color: .blue, cells: CellRect(col: 0, row: 0, width: 4, height: 4))
        let small = Zone(name: "Small", color: .pink, cells: CellRect(col: 1, row: 1, width: 1, height: 1))
        let grid = MonitorGrid(displayID: "A", displayName: "A", lastKnownSize: .zero, columns: 4, rows: 4, zones: [big, small])
        XCTAssertEqual(grid.zone(at: GridCell(col: 1, row: 1))?.name, "Small")
        XCTAssertEqual(grid.zone(at: GridCell(col: 3, row: 3))?.name, "Big")
    }

    func testDuplicateLayoutGetsFreshIDs() {
        let zone = Zone(name: "Z", color: .blue, cells: CellRect(col: 0, row: 0, width: 1, height: 1))
        let layout = Layout(name: "Coding", monitors: [MonitorGrid(displayID: "A", displayName: "A", lastKnownSize: .zero, zones: [zone])])
        let copy = layout.duplicated(name: "Coding copy")
        XCTAssertNotEqual(copy.id, layout.id)
        XCTAssertNotEqual(copy.monitors[0].zones[0].id, zone.id)
        XCTAssertEqual(copy.monitors[0].zones[0].cells, zone.cells)
    }
}

final class CoordinateTests: XCTestCase {
    // Primary laptop 1512×982 at origin; a widescreen above it; a vertical monitor to the right.
    let primaryHeight: CGFloat = 982
    let widescreen = CGRect(x: -500, y: 982, width: 3440, height: 1440)   // Cocoa: above primary
    let vertical = CGRect(x: 1512, y: -600, width: 1080, height: 1920)    // Cocoa: right, extends below

    func testFlipIsSelfInverse() {
        let rect = CGRect(x: 10, y: 20, width: 300, height: 400)
        XCTAssertEqual(Coordinates.flip(Coordinates.flip(rect, primaryScreenHeight: primaryHeight), primaryScreenHeight: primaryHeight), rect)
    }

    func testMonitorAboveHasNegativeAXOrigin() {
        let local = CGRect(x: 0, y: 0, width: 1720, height: 1440) // left half, full height
        let ax = Coordinates.axRect(fromLocal: local, in: widescreen, primaryScreenHeight: primaryHeight)
        XCTAssertEqual(ax, CGRect(x: -500, y: -1440, width: 1720, height: 1440))
    }

    func testVerticalMonitorToTheRight() {
        let local = CGRect(x: 0, y: 960, width: 1080, height: 960) // bottom half
        let ax = Coordinates.axRect(fromLocal: local, in: vertical, primaryScreenHeight: primaryHeight)
        // Cocoa bottom of vertical is y = -600 → AX y of its bottom edge is 982 + 600 = 1582.
        XCTAssertEqual(ax.maxY, 1582)
        XCTAssertEqual(ax.minX, 1512)
        XCTAssertEqual(ax.height, 960)
    }

    func testLocalPointRoundTrip() {
        let local = CGPoint(x: 100, y: 200)
        let cocoa = CGPoint(x: widescreen.minX + 100, y: widescreen.maxY - 200)
        XCTAssertEqual(Coordinates.localPoint(fromCocoa: cocoa, in: widescreen), local)
    }
}

final class LayoutStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("layouts.json")
        let store = LayoutStore(fileURL: url)
        let zone = Zone(name: "Chrome", color: .orange, cells: CellRect(col: 0, row: 0, width: 10, height: 10),
                        apps: [AppRef(bundleID: "com.google.Chrome", name: "Google Chrome")])
        let grid = MonitorGrid(displayID: "UUID-1", displayName: "Wide", lastKnownSize: Size2D(width: 3440, height: 1440),
                               columns: 20, rows: 10, zones: [zone])
        let doc = SpaciousDocument(layouts: [Layout(name: "Work", monitors: [grid])], settings: AppSettings(gap: 12, shiftDragEnabled: false))
        try store.save(doc)
        XCTAssertEqual(store.load(), doc)
    }

    func testMissingFileGivesDefaultDocument() {
        let store = LayoutStore(fileURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).json"))
        let doc = store.load()
        XCTAssertEqual(doc.layouts.count, 1)
        XCTAssertEqual(doc.activeLayoutID, doc.layouts[0].id)
    }

    func testCorruptFileIsMovedAside() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("layouts.json")
        try Data("not json".utf8).write(to: url)
        _ = LayoutStore(fileURL: url).load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1)
    }
}

final class ZoneFittingTests: XCTestCase {
    // A 1000×500 monitor with a 10×5 grid and no gap: each cell is 100×100.
    let size = CGSize(width: 1000, height: 500)
    let spotify = Size2D(width: 800, height: 600)

    func testZoneLargeEnoughHasNoIssue() {
        let issue = ZoneFitting.check(CellRect(col: 0, row: 0, width: 8, height: 6), columns: 10, rows: 10, in: CGSize(width: 1000, height: 1000), gap: 0, minimum: spotify)
        XCTAssertNil(issue)
    }

    func testSmallZoneSuggestsGrowingRightAndDown() {
        let issue = ZoneFitting.check(CellRect(col: 1, row: 1, width: 3, height: 3), columns: 10, rows: 10, in: CGSize(width: 1000, height: 1000), gap: 0, minimum: spotify)
        XCTAssertEqual(issue?.zoneSize, CGSize(width: 300, height: 300))
        XCTAssertEqual(issue?.suggestedCells, CellRect(col: 1, row: 1, width: 8, height: 6))
    }

    func testGrowShiftsLeftAtGridEdge() {
        let grown = ZoneFitting.grow(CellRect(col: 8, row: 0, width: 2, height: 2), columns: 10, rows: 10, in: CGSize(width: 1000, height: 1000), gap: 0, toFit: spotify)
        XCTAssertEqual(grown, CellRect(col: 2, row: 0, width: 8, height: 6))
    }

    func testAppTallerThanMonitorCannotFit() {
        let issue = ZoneFitting.check(CellRect(col: 0, row: 0, width: 2, height: 2), columns: 10, rows: 5, in: size, gap: 0, minimum: spotify)
        XCTAssertNotNil(issue)
        XCTAssertFalse(issue!.fitsOnMonitor)
    }

    func testGapIsAccountedFor() {
        // 8 cells of 100pt minus a 10pt gap is 790pt: not enough for 800pt.
        let grown = ZoneFitting.grow(CellRect(col: 0, row: 0, width: 1, height: 1), columns: 10, rows: 10, in: CGSize(width: 1000, height: 1000), gap: 10, toFit: spotify)
        XCTAssertEqual(grown?.width, 9)
    }

    func testOversizedWindowIsCenteredThenKeptOnScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let middle = ZoneFitting.place(windowSize: CGSize(width: 400, height: 200), in: CGRect(x: 400, y: 100, width: 200, height: 100), bounds: bounds)
        XCTAssertEqual(middle, CGRect(x: 300, y: 50, width: 400, height: 200))
        let corner = ZoneFitting.place(windowSize: CGSize(width: 400, height: 200), in: CGRect(x: 0, y: 0, width: 200, height: 100), bounds: bounds)
        XCTAssertEqual(corner.origin, .zero)
        let huge = ZoneFitting.place(windowSize: CGSize(width: 1200, height: 200), in: CGRect(x: 800, y: 0, width: 200, height: 100), bounds: bounds)
        XCTAssertEqual(huge.minX, 0)
    }

    func testLearningMinimumSizes() {
        // Width refused to shrink; height fit.
        let first = ZoneFitting.learnedMinimum(previous: nil, requested: CGSize(width: 500, height: 900), actual: CGSize(width: 800, height: 900))
        XCTAssertEqual(first, Size2D(width: 800, height: 0))
        // Everything fit and nothing was known: still unknown.
        XCTAssertNil(ZoneFitting.learnedMinimum(previous: nil, requested: CGSize(width: 500, height: 500), actual: CGSize(width: 500, height: 500)))
        // A fit at 700 proves a stale 800 minimum is now at most 700.
        let lowered = ZoneFitting.learnedMinimum(previous: Size2D(width: 800, height: 600), requested: CGSize(width: 700, height: 650), actual: CGSize(width: 700, height: 650))
        XCTAssertEqual(lowered, Size2D(width: 700, height: 600))
    }

    func testOldDocumentsWithoutMinimumSizesStillLoad() throws {
        let legacy = #"{"schemaVersion":1,"layouts":[{"id":"D46A611F-BA70-489A-93C7-64F8F98518F3","name":"Default","monitors":[],"launchMissingApps":false}],"activeLayoutID":"D46A611F-BA70-489A-93C7-64F8F98518F3","settings":{"gap":8,"shiftDragEnabled":true}}"#
        let doc = try JSONDecoder().decode(SpaciousDocument.self, from: Data(legacy.utf8))
        XCTAssertEqual(doc.appMinimumSizes, [:])
        XCTAssertEqual(doc.layouts.first?.name, "Default")
    }
}

final class TargetMatchingTests: XCTestCase {
    func testURLMatchingIgnoresSchemeWWWAndTrailingSlash() {
        XCTAssertTrue(TargetMatching.url("https://mail.google.com/mail/u/0/#inbox", matches: "mail.google.com"))
        XCTAssertTrue(TargetMatching.url("https://www.github.com/", matches: "https://GitHub.com"))
        XCTAssertTrue(TargetMatching.url("https://www.youtube.com/watch?v=abc", matches: "youtube.com/watch"))
    }

    func testURLMatchingRespectsBoundaries() {
        XCTAssertFalse(TargetMatching.url("https://github.community/t/1", matches: "github.com"))
        XCTAssertFalse(TargetMatching.url("https://docs.google.com/document/d/1", matches: "docs.google.com/spreadsheets"))
        XCTAssertFalse(TargetMatching.url("https://example.com", matches: ""))
    }

    func testSuggestedPatternDropsQueryAndFragment() {
        XCTAssertEqual(TargetMatching.suggestedPattern(for: "https://www.youtube.com/watch?v=abc#t=10"), "youtube.com/watch")
        XCTAssertEqual(TargetMatching.suggestedPattern(for: "https://mail.google.com/mail/u/0/#inbox"), "mail.google.com/mail/u/0")
    }

    func testOpenableURLAddsScheme() {
        XCTAssertEqual(TargetMatching.openableURL(for: "mail.google.com")?.absoluteString, "https://mail.google.com")
        XCTAssertEqual(TargetMatching.openableURL(for: "http://localhost:3000")?.absoluteString, "http://localhost:3000")
    }

    func testTitleMatchingIsCaseInsensitiveContains() {
        XCTAssertTrue(TargetMatching.title("Project Board – Notion", matches: "project board"))
        XCTAssertFalse(TargetMatching.title("Project Board", matches: "  "))
    }

    func testTargetKindsAndLegacyDecoding() throws {
        let legacy = try JSONDecoder().decode(AppRef.self, from: Data(#"{"bundleID":"com.google.Chrome","name":"Google Chrome"}"#.utf8))
        XCTAssertEqual(legacy.kind, .app)
        let site = AppRef(bundleID: "com.google.Chrome", name: "Google Chrome", url: "mail.google.com")
        XCTAssertEqual(site.kind, .website(url: "mail.google.com"))
        XCTAssertNotEqual(site.id, legacy.id)
        XCTAssertEqual(AppRef(bundleID: "a", name: "Notes", windowTitle: "Groceries").label, "Notes: “Groceries”")
    }
}
