import AppKit
import Observation
import ServiceManagement
import SpaciousCore

/// Central app state: the saved document, connected displays, UI selection,
/// and the actions the menu, hotkeys, and overlays trigger.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var document: SpaciousDocument {
        didSet { if document != oldValue { scheduleSave() } }
    }
    private(set) var displays: [DisplayInfo] = []
    var selectedDisplayID: String?
    var selectedZoneID: UUID?
    private(set) var isAccessibilityTrusted = AccessibilityService.isTrusted
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Short status line shown in the menu after applying a layout.
    var statusMessage: String?

    @ObservationIgnored let displayManager = DisplayManager()
    @ObservationIgnored private(set) lazy var overlay = SnapOverlayController(model: self)
    @ObservationIgnored private lazy var dragMonitor = DragSnapMonitor(model: self)
    @ObservationIgnored private let store: LayoutStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var trustTimer: Timer?

    private init() {
        let store = LayoutStore(fileURL: LayoutStore.defaultFileURL)
        self.store = store
        self.document = store.load()
        self.displays = displayManager.displays
        ensureGridsForConnectedDisplays()
        selectedDisplayID = displays.first(where: \.isMain)?.id ?? displays.first?.id
        displayManager.onChange = { [weak self] in self?.displaysChanged($0) }
    }

    /// Called once at launch.
    func start() {
        AccessibilityService.configureTimeout()
        Hotkeys.register(model: self)
        dragMonitor.start()
        if !isAccessibilityTrusted {
            let key = "didPromptForAccessibility"
            if !UserDefaults.standard.bool(forKey: key) {
                UserDefaults.standard.set(true, forKey: key)
                AccessibilityService.requestTrust()
            }
            startTrustPolling()
        }
    }

    // MARK: Accessibility

    func requestAccessibility() {
        AccessibilityService.requestTrust()
        AccessibilityService.openAccessibilitySettings()
        startTrustPolling()
    }

    private func startTrustPolling() {
        guard trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if AccessibilityService.isTrusted {
                    self.isAccessibilityTrusted = true
                    timer.invalidate()
                    self.trustTimer = nil
                    // Global event monitors installed before trust was granted may be inert.
                    self.dragMonitor.start()
                }
            }
        }
    }

    // MARK: Displays

    private func displaysChanged(_ latest: [DisplayInfo]) {
        displays = latest
        ensureGridsForConnectedDisplays()
        if !latest.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = latest.first(where: \.isMain)?.id ?? latest.first?.id
            selectedZoneID = nil
        }
    }

    func display(id: String) -> DisplayInfo? {
        displays.first { $0.id == id }
    }

    /// Makes sure every connected monitor has a grid in the active layout and
    /// refreshes stored names/sizes.
    private func ensureGridsForConnectedDisplays() {
        var layout = activeLayout
        for display in displays {
            let size = Size2D(width: display.frame.width, height: display.frame.height)
            if let i = layout.monitors.firstIndex(where: { $0.displayID == display.id }) {
                layout.monitors[i].displayName = display.name
                layout.monitors[i].lastKnownSize = size
            } else {
                layout.monitors.append(Self.defaultGrid(for: display))
            }
        }
        if layout != activeLayout { activeLayout = layout }
    }

    private static func defaultGrid(for display: DisplayInfo) -> MonitorGrid {
        let portrait = display.frame.height > display.frame.width
        return MonitorGrid(
            displayID: display.id,
            displayName: display.name,
            lastKnownSize: Size2D(width: display.frame.width, height: display.frame.height),
            columns: portrait ? 1 : 4,
            rows: portrait ? 3 : 2
        )
    }

    /// Grids saved for monitors that aren't plugged in right now.
    var disconnectedGrids: [MonitorGrid] {
        activeLayout.monitors.filter { grid in !displays.contains { $0.id == grid.displayID } }
    }

    func forgetMonitor(_ displayID: String) {
        activeLayout.monitors.removeAll { $0.displayID == displayID }
    }

    // MARK: Layouts

    var activeLayout: Layout {
        get { document.layouts[document.activeLayoutIndex] }
        set { document.layouts[document.activeLayoutIndex] = newValue }
    }

    func selectLayout(_ id: UUID) {
        document.activeLayoutID = id
        selectedZoneID = nil
        ensureGridsForConnectedDisplays()
    }

    func selectNextLayout() {
        guard document.layouts.count > 1 else { return }
        let next = (document.activeLayoutIndex + 1) % document.layouts.count
        selectLayout(document.layouts[next].id)
        statusMessage = "Switched to “\(activeLayout.name)”"
    }

    func newLayout() {
        let layout = Layout(name: uniqueLayoutName("Layout"))
        document.layouts.append(layout)
        selectLayout(layout.id)
    }

    func duplicateActiveLayout() {
        let copy = activeLayout.duplicated(name: uniqueLayoutName("\(activeLayout.name) copy"))
        document.layouts.append(copy)
        selectLayout(copy.id)
    }

    func renameActiveLayout(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activeLayout.name = trimmed
    }

    func deleteActiveLayout() {
        guard document.layouts.count > 1 else { return }
        let index = document.activeLayoutIndex
        document.layouts.remove(at: index)
        selectLayout(document.layouts[max(0, index - 1)].id)
    }

    private func uniqueLayoutName(_ base: String) -> String {
        let names = Set(document.layouts.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Grids & zones

    func grid(for displayID: String) -> MonitorGrid? {
        activeLayout.grid(for: displayID)
    }

    func updateGrid(_ displayID: String, _ change: (inout MonitorGrid) -> Void) {
        guard let i = activeLayout.monitors.firstIndex(where: { $0.displayID == displayID }) else { return }
        change(&activeLayout.monitors[i])
    }

    func updateZone(_ displayID: String, _ zoneID: UUID, _ change: (inout Zone) -> Void) {
        updateGrid(displayID) { grid in
            guard let z = grid.zones.firstIndex(where: { $0.id == zoneID }) else { return }
            change(&grid.zones[z])
        }
    }

    func addZone(_ displayID: String, cells: CellRect) {
        var newID: UUID?
        updateGrid(displayID) { grid in
            let zone = Zone(name: "", color: grid.nextZoneColor, cells: cells)
            grid.zones.append(zone)
            newID = zone.id
        }
        selectedZoneID = newID
    }

    func deleteZone(_ displayID: String, _ zoneID: UUID) {
        updateGrid(displayID) { $0.zones.removeAll { $0.id == zoneID } }
        if selectedZoneID == zoneID { selectedZoneID = nil }
    }

    /// Sets the grid size and replaces zones with one zone per cell.
    func applyQuickLayout(_ displayID: String, columns: Int, rows: Int) {
        updateGrid(displayID) { grid in
            grid.zones = []
            grid.resize(columns: columns, rows: rows)
            for r in 0..<grid.rows {
                for c in 0..<grid.columns {
                    grid.zones.append(Zone(name: "", color: grid.nextZoneColor, cells: CellRect(col: c, row: r, width: 1, height: 1)))
                }
            }
        }
        selectedZoneID = nil
    }

    /// The Accessibility-space frame a zone covers on a connected display.
    func axFrame(for cells: CellRect, in grid: MonitorGrid, on display: DisplayInfo) -> CGRect {
        let visible = display.visibleFrame
        let local = GridMath.frame(for: cells, columns: grid.columns, rows: grid.rows, in: visible.size, gap: gap)
        return Coordinates.axRect(fromLocal: local, in: visible, primaryScreenHeight: DisplayManager.primaryScreenHeight)
    }

    // MARK: Actions

    func applyActiveLayout() {
        guard isAccessibilityTrusted else {
            statusMessage = "Allow Accessibility access first."
            return
        }
        let result = LayoutApplier.apply(activeLayout, model: self)
        statusMessage = result.summary
    }

    func snapFocusedWindow() {
        guard isAccessibilityTrusted else { return requestAccessibility() }
        guard let window = AccessibilityService.focusedWindow() else {
            NSSound.beep()
            return
        }
        overlay.showPicker(for: window)
    }

    // MARK: Settings

    var gap: CGFloat { CGFloat(document.settings.gap) }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            statusMessage = "Couldn't change login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = document
        let store = store
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? store.save(snapshot)
        }
    }

    func saveNow() {
        saveTask?.cancel()
        try? store.save(document)
    }
}
