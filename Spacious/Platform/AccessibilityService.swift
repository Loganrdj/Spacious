import AppKit
import ApplicationServices

/// Thin wrapper over the macOS Accessibility (AX) API used to read and move
/// other apps' windows. All rects are in AX global coordinates (top-left
/// origin of the primary display, y down).
enum AccessibilityService {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Caps how long any AX call may block on an unresponsive app (the
    /// system default is ~6s, which would freeze drag handling).
    static func configureTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)
    }

    /// Shows the system "allow accessibility" prompt if not yet trusted.
    @discardableResult
    static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Finding windows

    /// The focused window of the frontmost app (ignoring Spacious itself).
    static func focusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let window: AXUIElement = attribute(appElement, kAXFocusedWindowAttribute) { return window }
        return attribute(appElement, kAXMainWindowAttribute)
    }

    /// Standard, non-minimized windows of a process, front-most first.
    /// Full-screen windows can't be moved, so they're left out unless
    /// `includeFullScreen` (see `exitFullScreen`).
    static func windows(of pid: pid_t, includeFullScreen: Bool = false) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        let all: [AXUIElement] = attribute(appElement, kAXWindowsAttribute) ?? []
        return all.filter { window in
            let subrole: String? = attribute(window, kAXSubroleAttribute)
            let minimized: Bool = attribute(window, kAXMinimizedAttribute) ?? false
            guard !minimized, includeFullScreen || !isFullScreen(window) else { return false }
            if subrole == kAXStandardWindowSubrole { return true }
            // Some real windows report no subrole, or "dialog" (e.g. TextEdit
            // documents on recent macOS). Finder's desktop and genuine alerts
            // look the same but can't be resized, so require that.
            return (subrole == nil || subrole == kAXDialogSubrole) && isResizable(window)
        }
    }

    static func isFullScreen(_ window: AXUIElement) -> Bool {
        attribute(window, "AXFullScreen") ?? false
    }

    /// Takes a window out of full screen and waits for the animation, so it
    /// can be arranged. No-op for windows that aren't full screen.
    @MainActor
    static func exitFullScreen(_ window: AXUIElement) async {
        guard isFullScreen(window) else { return }
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
        for _ in 0..<20 where isFullScreen(window) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(400)) // let the exit animation settle
    }

    static func title(of window: AXUIElement) -> String {
        attribute(window, kAXTitleAttribute) ?? ""
    }

    /// Presses an app's menu item by its title (e.g. Chrome's "Move Tab to
    /// New Window"). Works while the app is in the background. Returns false
    /// if the item doesn't exist or is disabled.
    @discardableResult
    static func pressMenuItem(titled title: String, in pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let menuBar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return false }
        func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            if self.title(of: element) == title { return element }
            guard depth < 4 else { return nil }
            let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
            for child in children {
                if let found = find(child, depth: depth + 1) { return found }
            }
            return nil
        }
        guard let item = find(menuBar, depth: 0), attribute(item, kAXEnabledAttribute) ?? false else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// The top-level window under an AX-space point, e.g. under the cursor.
    static func window(at point: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        if role(of: element) == kAXWindowRole { return element }
        if let window: AXUIElement = attribute(element, kAXWindowAttribute) { return window }
        // Walk up the hierarchy as a fallback.
        var current: AXUIElement? = element
        while let node = current {
            if role(of: node) == kAXWindowRole { return node }
            current = attribute(node, kAXParentAttribute)
        }
        return nil
    }

    static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    // MARK: Frames

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let posValue: AXValue = attribute(window, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// Moves and resizes a window. Size is set between two position writes so
    /// moves across monitors of different sizes are not clamped by the old
    /// screen. The app may still refuse sizes below its own minimum.
    static func setFrame(_ rect: CGRect, of window: AXUIElement) {
        withEnhancedUIDisabled(for: window) {
            writePosition(rect.origin, of: window)
            writeSize(rect.size, of: window)
            writePosition(rect.origin, of: window)
        }
    }

    /// Moves a window without resizing it.
    static func setPosition(_ origin: CGPoint, of window: AXUIElement) {
        withEnhancedUIDisabled(for: window) { writePosition(origin, of: window) }
    }

    static func isResizable(_ window: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    /// Measures the smallest size a window allows. macOS has no API to read
    /// another app's minimum window size, so this briefly asks the window to
    /// shrink to 1×1, reads back where the app stopped it, and restores the
    /// original frame. Returns nil for windows that can't be resized, since
    /// they reveal nothing about the app's real limits.
    static func measureMinimumSize(of window: AXUIElement) -> CGSize? {
        guard isResizable(window), let original = frame(of: window) else { return nil }
        return withEnhancedUIDisabled(for: window) {
            writeSize(CGSize(width: 1, height: 1), of: window)
            let measured = frame(of: window)?.size
            writeSize(original.size, of: window)
            writePosition(original.origin, of: window)
            return measured
        }
    }

    /// One animation frame: size then position, without the enhanced-UI
    /// toggling `setFrame` does (the animator handles that once per app).
    static func setFrameForAnimation(_ rect: CGRect, of window: AXUIElement) {
        writeSize(rect.size, of: window)
        writePosition(rect.origin, of: window)
    }

    /// Turns an app's "enhanced UI" off and returns whether it was on, so it
    /// can be restored with `restoreEnhancedUI`.
    static func disableEnhancedUI(for pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let enabled: Bool = attribute(app, "AXEnhancedUserInterface"), enabled else { return false }
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        return true
    }

    static func restoreEnhancedUI(for pid: pid_t) {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Apps using "enhanced UI" (Chrome, Electron) animate AX changes, which
    /// breaks rapid writes, so the flag is switched off around `body`.
    private static func withEnhancedUIDisabled<T>(for window: AXUIElement, _ body: () -> T) -> T {
        let appElement = pid(of: window).map(AXUIElementCreateApplication)
        let enhancedUI = "AXEnhancedUserInterface" as CFString
        var hadEnhancedUI = false
        if let appElement, let enabled: Bool = attribute(appElement, enhancedUI as String), enabled {
            hadEnhancedUI = true
            AXUIElementSetAttributeValue(appElement, enhancedUI, kCFBooleanFalse)
        }
        defer {
            if hadEnhancedUI, let appElement {
                AXUIElementSetAttributeValue(appElement, enhancedUI, kCFBooleanTrue)
            }
        }
        return body()
    }

    private static func writePosition(_ origin: CGPoint, of window: AXUIElement) {
        var origin = origin
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private static func writeSize(_ size: CGSize, of window: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    /// Brings a window (and its app) to the front.
    static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if let pid = pid(of: window) {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
    }

    // MARK: Helpers

    private static func role(of element: AXUIElement) -> String? {
        attribute(element, kAXRoleAttribute)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        // CF types can't be conditionally cast with `as?`; check the type ID instead.
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        if T.self == AXValue.self {
            return CFGetTypeID(value) == AXValueGetTypeID() ? (value as! T) : nil
        }
        return value as? T
    }
}
