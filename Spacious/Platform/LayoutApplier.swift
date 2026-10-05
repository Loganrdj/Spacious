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
///
/// Windows cascade into place one after another (`Waterfall`). With
/// "Launch All", apps that aren't running are opened together and each one
/// joins the cascade as soon as its first window appears, so fast apps
/// don't wait for slow ones (and websites don't wait for pages to load).
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
        var launched: [String] = []
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
            if movedWindows == 0 && launched.isEmpty && notRunning.isEmpty && notFound.isEmpty && needsPermission.isEmpty && errors.isEmpty {
                parts.append("Nothing assigned yet. Select a zone and assign an app, window, or website.")
            } else {
                parts.append("Arranged \(movedWindows) window\(movedWindows == 1 ? "" : "s")")
            }
            if !launched.isEmpty { parts.append("opened \(list(launched))") }
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

    typealias Assignment = (ref: AppRef, target: Target)

    /// - Parameter launchMissing: open assigned apps and browsers that aren't
    ///   running (the "Launch All" button and start-up action).
    static func apply(_ layout: Layout, model: AppModel, launchMissing: Bool) async -> Result {
        let run = Run(model: model)
        var assignments: [Assignment] = []
        for grid in layout.monitors {
            guard let display = model.display(id: grid.displayID) else {
                if grid.zones.contains(where: { !$0.apps.isEmpty }) { run.result.disconnectedMonitors += 1 }
                continue
            }
            for zone in grid.zones {
                for ref in zone.apps {
                    assignments.append((ref, Target(cells: zone.cells, grid: grid, display: display)))
                }
            }
        }

        // Split into apps that are running now and apps to launch.
        var pending: [String: [Assignment]] = [:]
        var pendingOrder: [String] = []
        var ready: [Assignment] = []
        for assignment in assignments {
            let id = assignment.ref.bundleID
            if launchMissing && !isRunning(id) {
                if pending[id] == nil { pendingOrder.append(id) }
                pending[id, default: []].append(assignment)
            } else {
                ready.append(assignment)
            }
        }
        for id in pendingOrder where launch(id) {
            run.result.launched.append(pending[id]?.first?.ref.name ?? id)
        }

        // Everything already open cascades in right away…
        await run.process(ready)

        // …and each launched app joins as soon as it has a window.
        let deadline = Date().addingTimeInterval(25)
        while !pending.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            for id in pendingOrder where pending[id] != nil && hasWindow(id) {
                // Apps often restore more windows right after the first one.
                try? await Task.sleep(for: .milliseconds(400))
                if let batch = pending.removeValue(forKey: id) { await run.process(batch) }
            }
        }
        for assignments in pending.values {
            if let name = assignments.first?.ref.name { run.result.notFound.append("a window for \(name)") }
        }

        run.result.tooBig += await run.waterfall.finish()
        return run.result
    }

    // MARK: Launching

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func hasWindow(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains {
            !AccessibilityService.windows(of: $0.processIdentifier, includeFullScreen: true).isEmpty
        }
    }

    /// Opens an app in the background without waiting for it.
    private static func launch(_ bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config)
        return true
    }

    // MARK: Resolving windows

    /// State shared by every batch of one apply: which windows and tabs are
    /// already taken, the running cascade, and the result.
    @MainActor
    private final class Run {
        let model: AppModel
        let waterfall: Waterfall
        var result = Result()
        private var claimed: [AXUIElement] = []
        private var usedURLs = Set<String>()
        private var blockedBrowsers = Set<String>()

        init(model: AppModel) {
            self.model = model
            self.waterfall = Waterfall(model: model)
        }

        private func isClaimed(_ window: AXUIElement) -> Bool {
            claimed.contains { CFEqual($0, window) }
        }

        /// Adds a window to the cascade the moment it's found.
        private func send(_ window: AXUIElement, _ assignment: Assignment) async {
            claimed.append(window)
            await AccessibilityService.exitFullScreen(window)
            let target = assignment.target
            waterfall.add(WindowMove(window: window, cells: target.cells, grid: target.grid, display: target.display),
                          label: assignment.ref.name)
            result.movedWindows += 1
        }

        func process(_ assignments: [Assignment]) async {
            // 1. Websites.
            for assignment in assignments {
                guard case .website(let pattern) = assignment.ref.kind else { continue }
                guard let browser = BrowserBridge.browser(for: assignment.ref.bundleID) else {
                    result.errors.append("\(assignment.ref.name) can't open websites")
                    continue
                }
                guard !blockedBrowsers.contains(browser.bundleID) else { continue }
                guard BrowserBridge.pid(of: browser) != nil else {
                    result.notRunning.append(browser.name)
                    continue
                }
                do {
                    if let found = try await BrowserBridge.isolatedWindow(for: pattern, in: browser, skipping: usedURLs, claimed: claimed) {
                        usedURLs.insert(found.url)
                        await send(found.window, assignment)
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
                    await send(window, assignment)
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
                    result.notRunning.append(app.name)
                    continue
                }
                let windows = running
                    .flatMap { AccessibilityService.windows(of: $0.processIdentifier, includeFullScreen: true) }
                    .filter { !isClaimed($0) }
                // Back-to-front, so the app's front window lands last (on top).
                for (i, window) in windows.enumerated().reversed() {
                    await send(window, targets[min(i, targets.count - 1)])
                }
            }
        }
    }
}
