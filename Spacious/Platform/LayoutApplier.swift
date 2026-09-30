import AppKit
import SpaciousCore

/// Moves every assigned app's windows into their zones.
///
/// If an app is assigned to several zones, its windows are spread across them
/// in order (window 1 → first zone, window 2 → second, …); any extra windows
/// stack in the last zone.
@MainActor
enum LayoutApplier {
    struct Result {
        var movedWindows = 0
        var notRunning: [String] = []
        var launching: [String] = []
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
        var framesByApp: [String: [CGRect]] = [:]
        var appOrder: [AppRef] = []

        for grid in layout.monitors {
            guard let display = model.display(id: grid.displayID) else {
                if grid.zones.contains(where: { !$0.apps.isEmpty }) { result.disconnectedMonitors += 1 }
                continue
            }
            for zone in grid.zones {
                let frame = model.axFrame(for: zone.cells, in: grid, on: display)
                for app in zone.apps {
                    if framesByApp[app.bundleID] == nil { appOrder.append(app) }
                    framesByApp[app.bundleID, default: []].append(frame)
                }
            }
        }

        for app in appOrder {
            let frames = framesByApp[app.bundleID] ?? []
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            if running.isEmpty {
                if layout.launchMissingApps, launch(app.bundleID, into: frames) {
                    result.launching.append(app.name)
                } else {
                    result.notRunning.append(app.name)
                }
                continue
            }
            result.movedWindows += place(running.map(\.processIdentifier), into: frames)
        }
        return result
    }

    @discardableResult
    private static func place(_ pids: [pid_t], into frames: [CGRect]) -> Int {
        guard !frames.isEmpty else { return 0 }
        let windows = pids.flatMap(AccessibilityService.windows(of:))
        // Walk back-to-front so the first window ends up on top.
        for (i, window) in windows.enumerated().reversed() {
            AccessibilityService.setFrame(frames[min(i, frames.count - 1)], of: window)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        return windows.count
    }

    /// Opens an app in the background and places its windows once they appear.
    private static func launch(_ bundleID: String, into frames: [CGRect]) -> Bool {
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
                        place([pid], into: frames)
                        return
                    }
                }
            }
        }
        return true
    }
}
