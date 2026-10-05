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
    /// True while a layout is being applied (browser tabs take a moment).
    private(set) var isApplying = false

    @ObservationIgnored let displayManager = DisplayManager()
    @ObservationIgnored private(set) lazy var overlay = SnapOverlayController(model: self)
    @ObservationIgnored private lazy var dragMonitor = DragSnapMonitor(model: self)
    @ObservationIgnored private let windowPicker = WindowPicker()
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
        runStartupAction()
    }

    /// Arranges or launches everything when Spacious starts, e.g. at login.
    private func runStartupAction() {
        let action = document.settings.startupAction
        guard action != .nothing, isAccessibilityTrusted else { return }
        Task {
            // Give the system (and other login items) a moment to settle.
            try? await Task.sleep(for: .seconds(3))
            applyActiveLayout(launchMissing: action == .launchAll)
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
        let local = GridMath.frame(for: cells, columns: grid.columns, rows: grid.rows, in: visible.size)
        return Coordinates.axRect(fromLocal: local, in: visible, primaryScreenHeight: DisplayManager.primaryScreenHeight)
    }

    // MARK: Window placement & minimum sizes

    /// Moves a window into `cells`. Apps can refuse to shrink below their own
    /// minimum size; when that happens the size it actually took is learned
    /// and the window is centered on the zone, kept fully on its monitor.
    /// Returns false if the window didn't fit the zone.
    @discardableResult
    func place(_ window: AXUIElement, cells: CellRect, in grid: MonitorGrid, on display: DisplayInfo) -> Bool {
        let target = axFrame(for: cells, in: grid, on: display)
        AccessibilityService.setFrame(target, of: window)
        guard let actual = AccessibilityService.frame(of: window) else { return true }

        if let bundleID = bundleID(of: window), AccessibilityService.isResizable(window) {
            learnMinimumSize(bundleID, requested: target.size, actual: actual.size)
        }

        let placed = ZoneFitting.place(windowSize: actual.size, in: target, bounds: axBounds(of: display))
        if abs(placed.minX - actual.minX) > 1 || abs(placed.minY - actual.minY) > 1 {
            AccessibilityService.setPosition(placed.origin, of: window)
        }
        return actual.width <= target.width + ZoneFitting.tolerance && actual.height <= target.height + ZoneFitting.tolerance
    }

    /// Moves a window into its zone, gliding it there when animation is on.
    /// Returns whether the window fit its zone.
    @discardableResult
    func arrange(_ move: WindowMove) async -> Bool {
        AXUIElementPerformAction(move.window, kAXRaiseAction as CFString)
        await WindowAnimator.animate(move.window, to: predictedFrame(for: move), duration: document.settings.animationDuration)
        // Final, exact placement (also learns minimum sizes).
        return place(move.window, cells: move.cells, in: move.grid, on: move.display)
    }

    /// Where a window will really end up: its zone, or, if the app is known
    /// to need more room, centered on the zone at its minimum size. Aiming
    /// the animation there avoids a jump at the end.
    private func predictedFrame(for move: WindowMove) -> CGRect {
        let target = axFrame(for: move.cells, in: move.grid, on: move.display)
        guard let bundleID = bundleID(of: move.window), let minimum = minimumSize(of: bundleID) else { return target }
        let size = CGSize(width: max(target.width, minimum.width), height: max(target.height, minimum.height))
        guard size != target.size else { return target }
        return ZoneFitting.place(windowSize: size, in: target, bounds: axBounds(of: move.display))
    }

    /// A display's usable area in AX coordinates.
    private func axBounds(of display: DisplayInfo) -> CGRect {
        Coordinates.flip(display.visibleFrame, primaryScreenHeight: DisplayManager.primaryScreenHeight)
    }

    private func bundleID(of window: AXUIElement) -> String? {
        AccessibilityService.pid(of: window).flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    }

    private func learnMinimumSize(_ bundleID: String, requested: CGSize, actual: CGSize) {
        let previous = document.appMinimumSizes[bundleID]
        let learned = ZoneFitting.learnedMinimum(previous: previous, requested: requested, actual: actual)
        if learned != previous { document.appMinimumSizes[bundleID] = learned }
    }

    /// Measures a running app's minimum window size (used right after the app
    /// is assigned to a zone, so warnings show before the first Apply).
    func measureMinimumSize(of bundleID: String) {
        guard isAccessibilityTrusted,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              let window = AccessibilityService.windows(of: app.processIdentifier).first(where: AccessibilityService.isResizable),
              let size = AccessibilityService.measureMinimumSize(of: window) else { return }
        document.appMinimumSizes[bundleID] = Size2D(width: size.width, height: size.height)
    }

    func minimumSize(of bundleID: String) -> Size2D? {
        document.appMinimumSizes[bundleID]
    }

    /// The problem, if any, with fitting `app` into `cells` on a display.
    func fitIssue(for app: AppRef, cells: CellRect, in grid: MonitorGrid, on display: DisplayInfo) -> ZoneFitIssue? {
        guard let minimum = minimumSize(of: app.bundleID) else { return nil }
        return ZoneFitting.check(cells, columns: grid.columns, rows: grid.rows, in: display.visibleFrame.size, gap: 0, minimum: minimum)
    }

    /// True if any app assigned to the zone can't shrink to fit it.
    func zoneIsTooSmall(_ zone: Zone, in grid: MonitorGrid, on display: DisplayInfo) -> Bool {
        zone.apps.contains { fitIssue(for: $0, cells: zone.cells, in: grid, on: display) != nil }
    }

    // MARK: Actions

    /// Opens every assigned app and website that isn't open, then arranges.
    func launchAll() {
        applyActiveLayout(launchMissing: true)
    }

    /// Arranges the active layout. `launchMissing` defaults to the layout's
    /// "open assigned apps that aren't running" setting.
    func applyActiveLayout(launchMissing: Bool? = nil) {
        guard isAccessibilityTrusted else {
            statusMessage = "Allow Accessibility access first."
            return
        }
        guard !isApplying else { return }
        isApplying = true
        let layout = activeLayout
        let launch = launchMissing ?? layout.launchMissingApps
        statusMessage = launch ? "Opening apps and websites…" : "Arranging…"
        Task {
            let result = await LayoutApplier.apply(layout, model: self, launchMissing: launch)
            statusMessage = result.summary
            isApplying = false
        }
    }

    /// Starts the inspector-style picker: the next window clicked is added
    /// to the zone and glides into it.
    func pickWindow(forZone zoneID: UUID, on displayID: String) {
        guard isAccessibilityTrusted else { return requestAccessibility() }
        windowPicker.start { [weak self] picked in
            self?.assignPicked(picked, toZone: zoneID, on: displayID)
        }
    }

    private func assignPicked(_ picked: PickedWindow, toZone zoneID: UUID, on displayID: String) {
        guard let app = NSRunningApplication(processIdentifier: picked.pid), let bundleID = app.bundleIdentifier,
              let display = display(id: displayID), let grid = grid(for: displayID),
              let zone = grid.zones.first(where: { $0.id == zoneID }) else { return }
        let name = app.localizedName ?? bundleID

        // Browsers: a window's title changes with every tab switch, so the
        // website showing in it is a better thing to remember.
        var ref = AppRef(bundleID: bundleID, name: name)
        if !picked.wholeApp {
            if let browser = BrowserBridge.browser(for: bundleID),
               let url = try? BrowserBridge.activeTabURL(in: browser, windowFrame: picked.frame) {
                ref = AppRef(bundleID: bundleID, name: name, url: TargetMatching.suggestedPattern(for: url))
            } else {
                let title = AccessibilityService.title(of: picked.window)
                if !title.isEmpty { ref = AppRef(bundleID: bundleID, name: name, windowTitle: title) }
            }
        }

        updateZone(displayID, zoneID) { zone in
            if !zone.apps.contains(where: { $0.id == ref.id }) { zone.apps.append(ref) }
        }
        selectedDisplayID = displayID
        selectedZoneID = zoneID
        measureMinimumSize(of: bundleID)
        statusMessage = "Added \(ref.label) to \(zone.name.isEmpty ? "the zone" : "“\(zone.name)”")"
        Task {
            await arrange(WindowMove(window: picked.window, cells: zone.cells, grid: grid, display: display))
        }
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

    /// Space drawn between zones in previews so neighbours stay distinct.
    /// Real windows tile edge to edge.
    static let previewGap: CGFloat = 4

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

/// A window and the zone it should move into.
struct WindowMove {
    let window: AXUIElement
    let cells: CellRect
    let grid: MonitorGrid
    let display: DisplayInfo
}
