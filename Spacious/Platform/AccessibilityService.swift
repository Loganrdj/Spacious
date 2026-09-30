import AppKit
import ApplicationServices

/// Thin wrapper over the macOS Accessibility (AX) API used to read and move
/// other apps' windows. All rects are in AX global coordinates (top-left
/// origin of the primary display, y down).
enum AccessibilityService {
    static var isTrusted: Bool { AXIsProcessTrusted() }

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
    static func windows(of pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        let all: [AXUIElement] = attribute(appElement, kAXWindowsAttribute) ?? []
        return all.filter { window in
            let subrole: String? = attribute(window, kAXSubroleAttribute)
            let minimized: Bool = attribute(window, kAXMinimizedAttribute) ?? false
            return (subrole == nil || subrole == kAXStandardWindowSubrole) && !minimized
        }
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
    /// screen. Apps using "enhanced UI" (Chrome, Electron) animate AX changes,
    /// which breaks rapid writes, so that flag is disabled temporarily.
    static func setFrame(_ rect: CGRect, of window: AXUIElement) {
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

        var origin = rect.origin
        var size = rect.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
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
