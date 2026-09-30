import AppKit
import SpaciousCore

/// Moves every assigned app's windows into their zones.
///
/// If an app is assigned to several zones, its windows are spread across them
/// in order (window 1 → first zone, window 2 → second, …); any extra windows
/// stack in the last zone.
@MainActor
enum LayoutApplier {
    /// Where one of an app's windows should go.
    struct Target {
        let cells: CellRect
        let grid: MonitorGrid
        let display: DisplayInfo
    }

    struct Result {
        var movedWindows = 0
        var notRunning: [String] = []
        var launching: [String] = []
        /// Apps whose windows refused to shrink to their zone.
        var tooBig: [String] = []
        var disconnectedMonitors = 0

        var summary: String {
            var parts: [String] = []
            if movedWindows == 0 && launching.isEmpty && notRunning.isEmpty {
                parts.append("No apps assigned yet. Select a zone and add an app.")
            } else {
                parts.append("Arranged \(movedWindows) window\(movedWindows == 1 ? "" : "s")")
            }
            if !launching.isEmpty { parts.append("opening \(list(launching))") }
            if !notRunning.isEmpty { parts.append("\(list(notRunning)) not running") }
            if !tooBig.isEmpty { parts.append("\(list(tooBig)) can't shrink to fit (see ⚠︎ zones)") }
            if disconnectedMonitors > 0 {
                parts.append("\(disconnectedMonitors) monitor\(disconnectedMonitors == 1 ? "" : "s") not connected")
            }
            return parts.joined(separator: " · ")
        }

        private func list(_ names: [String]) -> String {
            names.count <= 2 ? names.joined(separator: " & ") : "\(names[0]) + \(names.count - 1) more"
        }
    }

    static func apply(_ layout: Layout, model: AppModel) -> Result {
        var result = Result()
        var targetsByApp: [String: [Target]] = [:]
        var appOrder: [AppRef] = []

        for grid in layout.monitors {
            guard let display = model.display(id: grid.displayID) else {
                if grid.zones.contains(where: { !$0.apps.isEmpty }) { result.disconnectedMonitors += 1 }
                continue
            }
            for zone in grid.zones {
                for app in zone.apps {
                    if targetsByApp[app.bundleID] == nil { appOrder.append(app) }
                    targetsByApp[app.bundleID, default: []].append(Target(cells: zone.cells, grid: grid, display: display))
                }
            }
        }

        for app in appOrder {
            let targets = targetsByApp[app.bundleID] ?? []
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            if running.isEmpty {
                if layout.launchMissingApps, launch(app.bundleID, into: targets, model: model) {
                    result.launching.append(app.name)
                } else {
                    result.notRunning.append(app.name)
                }
                continue
            }
            let (moved, allFit) = place(running.map(\.processIdentifier), into: targets, model: model)
            result.movedWindows += moved
            if !allFit { result.tooBig.append(app.name) }
        }
        return result
    }

    /// Returns how many windows moved and whether they all fit their zones.
    @discardableResult
    private static func place(_ pids: [pid_t], into targets: [Target], model: AppModel) -> (Int, Bool) {
        guard !targets.isEmpty else { return (0, true) }
        let windows = pids.flatMap(AccessibilityService.windows(of:))
        var allFit = true
        // Walk back-to-front so the first window ends up on top.
        for (i, window) in windows.enumerated().reversed() {
            let target = targets[min(i, targets.count - 1)]
            if !model.place(window, cells: target.cells, in: target.grid, on: target.display) { allFit = false }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        return (windows.count, allFit)
    }

    /// Opens an app in the background and places its windows once they appear.
    private static func launch(_ bundleID: String, into targets: [Target], model: AppModel) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
            guard let pid = app?.processIdentifier else { return }
            Task { @MainActor in
                // Poll for up to ~15s; apps can take a while to show their first window.
                for _ in 0..<60 {
                    try? await Task.sleep(for: .milliseconds(250))
                    if !AccessibilityService.windows(of: pid).isEmpty {
                        try? await Task.sleep(for: .milliseconds(300)) // let the window finish its own setup
                        place([pid], into: targets, model: model)
                        return
                    }
                }
            }
        }
        return true
    }
}
