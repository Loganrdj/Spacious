import AppKit
import SpaciousCore

/// Moves everything assigned in a layout into its zone.
///
/// Targets are resolved most-specific first so each window is used once:
/// 1. websites (a browser tab, moved into its own window),
/// 2. specific windows (matched by title),
/// 3. whole apps, which get the app's remaining windows. If an app is
///    assigned to several zones, its windows are spread across them in order
///    and any extras stack in the last zone.
@MainActor
enum LayoutApplier {
    /// Where an assigned target should go.
    struct Target {
        let cells: CellRect
        let grid: MonitorGrid
        let display: DisplayInfo
    }

    struct Result {
        var movedWindows = 0
        var notRunning: [String] = []
        var launching: [String] = []
        /// Window/website targets that couldn't be found.
        var notFound: [String] = []
        /// Apps whose windows refused to shrink to their zone.
        var tooBig: [String] = []
        /// Browsers that Spacious isn't allowed to control yet.
        var needsPermission: [String] = []
        var errors: [String] = []
        var disconnectedMonitors = 0

        var summary: String {
            var parts: [String] = []
            if movedWindows == 0 && launching.isEmpty && notRunning.isEmpty && notFound.isEmpty && needsPermission.isEmpty && errors.isEmpty {
                parts.append("Nothing assigned yet. Select a zone and assign an app, window, or website.")
            } else {
                parts.append("Arranged \(movedWindows) window\(movedWindows == 1 ? "" : "s")")
            }
            if !launching.isEmpty { parts.append("opening \(list(launching))") }
            if !notRunning.isEmpty { parts.append("\(list(notRunning)) not running") }
            if !notFound.isEmpty { parts.append("couldn't find \(list(notFound))") }
            if !tooBig.isEmpty { parts.append("\(list(tooBig)) can't shrink to fit (see ⚠︎ zones)") }
            if !needsPermission.isEmpty {
                parts.append("allow Spacious to control \(list(needsPermission)) in System Settings → Privacy & Security → Automation")
            }
            parts += errors
            if disconnectedMonitors > 0 {
                parts.append("\(disconnectedMonitors) monitor\(disconnectedMonitors == 1 ? "" : "s") not connected")
            }
            return parts.joined(separator: " · ")
        }

        private func list(_ names: [String]) -> String {
            let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            return unique.count <= 2 ? unique.joined(separator: " & ") : "\(unique[0]) + \(unique.count - 1) more"
        }
    }

    private typealias Assignment = (ref: AppRef, target: Target)

    static func apply(_ layout: Layout, model: AppModel) async -> Result {
        var result = Result()
        var assignments: [Assignment] = []
        for grid in layout.monitors {
            guard let display = model.display(id: grid.displayID) else {
                if grid.zones.contains(where: { !$0.apps.isEmpty }) { result.disconnectedMonitors += 1 }
                continue
            }
            for zone in grid.zones {
                for ref in zone.apps {
                    assignments.append((ref, Target(cells: zone.cells, grid: grid, display: display)))
                }
            }
        }

        var claimed: [AXUIElement] = []
        func isClaimed(_ window: AXUIElement) -> Bool { claimed.contains { CFEqual($0, window) } }

        func place(_ window: AXUIElement, _ assignment: Assignment) async {
            await AccessibilityService.exitFullScreen(window)
            let target = assignment.target
            if !model.place(window, cells: target.cells, in: target.grid, on: target.display) {
                result.tooBig.append(assignment.ref.name)
            }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            claimed.append(window)
            result.movedWindows += 1
        }

        // 1. Websites.
        var usedURLs = Set<String>()
        var blockedBrowsers = Set<String>()
        for assignment in assignments {
            guard case .website(let pattern) = assignment.ref.kind else { continue }
            guard let browser = BrowserBridge.browser(for: assignment.ref.bundleID) else {
                result.errors.append("\(assignment.ref.name) can't open websites")
                continue
            }
            guard !blockedBrowsers.contains(browser.bundleID) else { continue }
            if BrowserBridge.pid(of: browser) == nil {
                guard layout.launchMissingApps else {
                    result.notRunning.append(browser.name)
                    continue
                }
                guard await launch(browser: browser, opening: pattern) else {
                    result.notRunning.append(browser.name)
                    continue
                }
            }
            do {
                if let found = try await BrowserBridge.isolatedWindow(for: pattern, in: browser, skipping: usedURLs) {
                    usedURLs.insert(found.url)
                    await place(found.window, assignment)
                } else {
                    result.notFound.append(pattern)
                }
            } catch BrowserError.notAllowed {
                blockedBrowsers.insert(browser.bundleID)
                result.needsPermission.append(browser.name)
            } catch {
                result.errors.append(error.localizedDescription)
            }
        }

        // 2. Specific windows, by title.
        for assignment in assignments {
            guard case .window(let title) = assignment.ref.kind else { continue }
            let pids = NSRunningApplication.runningApplications(withBundleIdentifier: assignment.ref.bundleID).map(\.processIdentifier)
            if pids.isEmpty {
                result.notRunning.append(assignment.ref.name)
                continue
            }
            let window = pids
                .flatMap { AccessibilityService.windows(of: $0, includeFullScreen: true) }
                .first { !isClaimed($0) && TargetMatching.title(AccessibilityService.title(of: $0), matches: title) }
            if let window {
                await place(window, assignment)
            } else {
                result.notFound.append("the “\(title)” window")
            }
        }

        // 3. Whole apps get their remaining windows.
        var appOrder: [AppRef] = []
        var targetsByApp: [String: [Assignment]] = [:]
        for assignment in assignments where assignment.ref.kind == .app {
            if targetsByApp[assignment.ref.bundleID] == nil { appOrder.append(assignment.ref) }
            targetsByApp[assignment.ref.bundleID, default: []].append(assignment)
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
            let windows = running
                .flatMap { AccessibilityService.windows(of: $0.processIdentifier, includeFullScreen: true) }
                .filter { !isClaimed($0) }
            // Walk back-to-front so the first window ends up on top.
            for (i, window) in windows.enumerated().reversed() {
                await place(window, targets[min(i, targets.count - 1)])
            }
        }
        return result
    }

    /// Launches a browser on a URL and waits for its first window.
    private static func launch(browser: BrowserBridge.Browser, opening pattern: String) async -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID),
              let url = TargetMatching.openableURL(for: pattern) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try? await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(250))
            if let pid = BrowserBridge.pid(of: browser), !AccessibilityService.windows(of: pid).isEmpty { return true }
        }
        return false
    }

    /// Opens an app in the background and places its windows once they appear.
    private static func launch(_ bundleID: String, into targets: [Assignment], model: AppModel) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
            guard let pid = app?.processIdentifier else { return }
            Task { @MainActor in
                // Poll for up to ~15s; apps can take a while to show their first window.
                for _ in 0..<60 {
                    try? await Task.sleep(for: .milliseconds(250))
                    let windows = AccessibilityService.windows(of: pid)
                    guard !windows.isEmpty else { continue }
                    try? await Task.sleep(for: .milliseconds(300)) // let the window finish its own setup
                    for (i, window) in windows.enumerated().reversed() {
                        let target = targets[min(i, targets.count - 1)].target
                        model.place(window, cells: target.cells, in: target.grid, on: target.display)
                    }
                    return
                }
            }
        }
        return true
    }
}
