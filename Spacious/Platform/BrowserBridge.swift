import AppKit
import SpaciousCore

/// An open tab in a supported browser.
struct BrowserTab: Identifiable, Hashable {
    let browserBundleID: String
    let browserName: String
    /// AppleScript window index (1 = front-most window of that browser).
    let windowIndex: Int
    let tabIndex: Int
    /// Number of tabs in the tab's window.
    let tabCount: Int
    let url: String
    let title: String

    var id: String { "\(browserBundleID)|\(windowIndex)|\(tabIndex)" }
}

enum BrowserError: LocalizedError {
    /// The user hasn't allowed Spacious to control this browser (Automation).
    case notAllowed(browser: String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAllowed(let browser):
            "Spacious isn't allowed to control \(browser). Turn it on in System Settings → Privacy & Security → Automation."
        case .failed(let message):
            message
        }
    }
}

/// Reads and rearranges browser tabs so a single website can get its own zone.
///
/// macOS can only arrange windows, so a tab is first moved into a window of
/// its own. Tabs are found through the browser's AppleScript dictionary, but
/// the move uses the browser's own "Move Tab to New Window" menu command:
/// Chrome's scripted `move` loses the page, the menu command keeps it intact.
@MainActor
enum BrowserBridge {
    enum Flavor { case chromium, safari }

    struct Browser: Hashable, Identifiable {
        let bundleID: String
        let name: String
        let flavor: Flavor
        var id: String { bundleID }
    }

    static let all: [Browser] = [
        Browser(bundleID: "com.google.Chrome", name: "Google Chrome", flavor: .chromium),
        Browser(bundleID: "com.apple.Safari", name: "Safari", flavor: .safari),
        Browser(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", flavor: .chromium),
        Browser(bundleID: "com.brave.Browser", name: "Brave", flavor: .chromium),
        Browser(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", flavor: .chromium),
        Browser(bundleID: "org.chromium.Chromium", name: "Chromium", flavor: .chromium),
        Browser(bundleID: "com.google.Chrome.beta", name: "Chrome Beta", flavor: .chromium),
        Browser(bundleID: "com.google.Chrome.canary", name: "Chrome Canary", flavor: .chromium),
    ]

    static func browser(for bundleID: String) -> Browser? {
        all.first { $0.bundleID == bundleID }
    }

    static var installed: [Browser] {
        all.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    static func pid(of browser: Browser) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first?.processIdentifier
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Reading tabs

    /// All tabs of a running browser. Never launches the browser.
    static func tabs(in browser: Browser) throws -> [BrowserTab] {
        guard pid(of: browser) != nil else { return [] }
        let titleProperty = browser.flavor == .safari ? "name" : "title"
        let output = try run("""
            tell application id "\(browser.bundleID)"
                set RS to character id 30
                set US to character id 31
                set out to ""
                set wi to 0
                repeat with w in windows
                    set wi to wi + 1
                    try
                        set n to count of tabs of w
                        set ti to 0
                        repeat with t in tabs of w
                            set ti to ti + 1
                            set u to ""
                            set tt to ""
                            try
                                set u to URL of t
                                set tt to \(titleProperty) of t
                            end try
                            set out to out & wi & US & ti & US & n & US & u & US & tt & RS
                        end repeat
                    end try
                end repeat
                return out
            end tell
            """, browser: browser)

        return output.split(separator: "\u{1E}").compactMap { record in
            let f = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let w = Int(f[0]), let t = Int(f[1]), let n = Int(f[2]), !f[3].isEmpty else { return nil }
            return BrowserTab(browserBundleID: browser.bundleID, browserName: browser.name, windowIndex: w,
                              tabIndex: t, tabCount: n, url: f[3], title: f[4].isEmpty ? f[3] : f[4])
        }
    }

    /// The URL of the tab showing in the browser window at `frame` (AX
    /// coordinates), e.g. a window picked with the window picker.
    static func activeTabURL(in browser: Browser, windowFrame frame: CGRect) throws -> String? {
        guard pid(of: browser) != nil else { return nil }
        let activeTab = browser.flavor == .safari ? "current tab" : "active tab"
        let output = try run("""
            tell application id "\(browser.bundleID)"
                set RS to character id 30
                set US to character id 31
                set out to ""
                repeat with w in windows
                    try
                        set b to bounds of w
                        set out to out & (item 1 of b as text) & US & (item 2 of b as text) & US & (item 3 of b as text) & US & (item 4 of b as text) & US & (URL of \(activeTab) of w) & RS
                    end try
                end repeat
                return out
            end tell
            """, browser: browser)
        for record in output.split(separator: "\u{1E}") {
            let f = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let l = Double(f[0]), let t = Double(f[1]), let r = Double(f[2]), let b = Double(f[3]) else { continue }
            if abs(l - frame.minX) <= 2, abs(t - frame.minY) <= 2, abs((r - l) - frame.width) <= 2, abs((b - t) - frame.height) <= 2 {
                return f[4].isEmpty ? nil : f[4]
            }
        }
        return nil
    }

    // MARK: Giving a website its own window

    /// Finds the tab matching `pattern` (or opens it), makes sure it is alone
    /// in its window, and returns that window. Tabs whose URL is in `used`
    /// are skipped, so two zones can each get their own copy of a site, and
    /// windows in `claimed` (already placed) are never returned.
    static func isolatedWindow(for pattern: String, in browser: Browser, skipping used: Set<String>,
                               claimed: [AXUIElement]) async throws -> (window: AXUIElement, url: String)? {
        guard let pid = pid(of: browser) else { return nil }
        let matches = try tabs(in: browser).filter { TargetMatching.url($0.url, matches: pattern) && !used.contains($0.url) }
        // Prefer a tab that already has a window to itself: nothing to move.
        let match = matches.first { $0.tabCount == 1 } ?? matches.first
        let url: String
        var expectedTitle = match?.title

        if let match {
            url = match.url
            if match.tabCount == 1 {
                try run("tell application id \"\(browser.bundleID)\" to set index of window \(match.windowIndex) to 1", browser: browser)
            } else {
                try run(selectTabScript(match, browser), browser: browser)
                try? await Task.sleep(for: .milliseconds(150))
                if !AccessibilityService.pressMenuItem(titled: "Move Tab to New Window", in: pid) {
                    // Menu not found (e.g. a non-English system): reopen the
                    // page in a new window instead. This reloads it.
                    try run(reopenScript(match, browser), browser: browser)
                }
            }
        } else {
            guard let openURL = TargetMatching.openableURL(for: pattern) else { return nil }
            url = openURL.absoluteString
            try run(openScript(url, browser), browser: browser)
        }

        // The tab's window is now the browser's front window. Wait until it
        // really is (moving a tab is asynchronous), then find its AX twin by frame.
        var lastFrame: CGRect?
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            guard let front = try? frontWindow(of: browser) else { continue }
            lastFrame = front.frame
            if expectedTitle == nil || expectedTitle?.isEmpty == true { expectedTitle = front.title }
            if front.tabCount == 1, TargetMatching.url(front.url, matches: pattern) || front.url == url,
               let window = axWindow(of: pid, frame: front.frame, title: expectedTitle, claimed: claimed) {
                return (window, url)
            }
        }
        if let lastFrame, let window = axWindow(of: pid, frame: lastFrame, title: expectedTitle, claimed: claimed) {
            return (window, url)
        }
        return nil
    }

    // MARK: Scripts

    private static func selectTabScript(_ tab: BrowserTab, _ browser: Browser) -> String {
        let select = browser.flavor == .safari
            ? "set current tab of w to tab \(tab.tabIndex) of w"
            : "set active tab index of w to \(tab.tabIndex)"
        return """
            tell application id "\(browser.bundleID)"
                set w to window \(tab.windowIndex)
                \(select)
                set index of w to 1
            end tell
            """
    }

    private static func reopenScript(_ tab: BrowserTab, _ browser: Browser) -> String {
        let open = browser.flavor == .safari
            ? "make new document with properties {URL:u}"
            : "set nw to make new window\n    set URL of active tab of nw to u"
        return """
            tell application id "\(browser.bundleID)"
                set u to URL of tab \(tab.tabIndex) of window \(tab.windowIndex)
                close tab \(tab.tabIndex) of window \(tab.windowIndex)
                \(open)
            end tell
            """
    }

    private static func openScript(_ url: String, _ browser: Browser) -> String {
        let literal = appleScriptString(url)
        let open = browser.flavor == .safari
            ? "make new document with properties {URL:\(literal)}"
            : "set nw to make new window\n    set URL of active tab of nw to \(literal)"
        return """
            tell application id "\(browser.bundleID)"
                \(open)
            end tell
            """
    }

    private struct FrontWindow {
        let frame: CGRect
        let tabCount: Int
        let url: String
        let title: String
    }

    /// Frame (AX coordinates), tab count, and active URL of the front window.
    private static func frontWindow(of browser: Browser) throws -> FrontWindow? {
        let activeTab = browser.flavor == .safari ? "current tab" : "active tab"
        let titleProperty = browser.flavor == .safari ? "name" : "title"
        let output = try run("""
            tell application id "\(browser.bundleID)"
                set US to character id 31
                set w to window 1
                set b to bounds of w
                set u to ""
                set tt to ""
                try
                    set u to URL of \(activeTab) of w
                    set tt to \(titleProperty) of \(activeTab) of w
                end try
                return (item 1 of b as text) & US & (item 2 of b as text) & US & (item 3 of b as text) & US & (item 4 of b as text) & US & (count of tabs of w) & US & u & US & tt
            end tell
            """, browser: browser)
        let f = output.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 6, let l = Double(f[0]), let t = Double(f[1]), let r = Double(f[2]), let b = Double(f[3]),
              let n = Int(f[4]) else { return nil }
        return FrontWindow(frame: CGRect(x: l, y: t, width: r - l, height: b - t), tabCount: n, url: f[5],
                           title: f.count > 6 ? f[6] : "")
    }

    /// The AX window that is the browser's front window. A tab moved into a
    /// new window usually opens at the *same* frame as the window it came
    /// from, so the frame alone is ambiguous. In order of preference:
    /// the app's main window, a window titled like the tab, any other window
    /// with that frame. Windows already placed are never returned.
    private static func axWindow(of pid: pid_t, frame: CGRect, title: String?, claimed: [AXUIElement]) -> AXUIElement? {
        func isClaimed(_ w: AXUIElement) -> Bool { claimed.contains { CFEqual($0, w) } }
        func sameFrame(_ w: AXUIElement) -> Bool {
            guard let f = AccessibilityService.frame(of: w) else { return false }
            return abs(f.minX - frame.minX) <= 2 && abs(f.minY - frame.minY) <= 2
                && abs(f.width - frame.width) <= 2 && abs(f.height - frame.height) <= 2
        }
        let candidates = AccessibilityService.windows(of: pid, includeFullScreen: true).filter { !isClaimed($0) && sameFrame($0) }
        if let main = AccessibilityService.mainWindow(of: pid), candidates.contains(where: { CFEqual($0, main) }) {
            return main
        }
        if let title, !title.isEmpty,
           let titled = candidates.first(where: { AccessibilityService.title(of: $0).localizedCaseInsensitiveContains(title) }) {
            return titled
        }
        return candidates.first
    }

    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    @discardableResult
    private static func run(_ source: String, browser: Browser) throws -> String {
        guard let script = NSAppleScript(source: source) else { throw BrowserError.failed("Couldn't build script for \(browser.name).") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            // -1743: not authorized; -1744: user would be prompted but can't be now.
            if code == -1743 || code == -1744 { throw BrowserError.notAllowed(browser: browser.name) }
            throw BrowserError.failed("\(browser.name): \(error[NSAppleScript.errorMessage] as? String ?? "script error \(code)")")
        }
        return result.stringValue ?? ""
    }
}
