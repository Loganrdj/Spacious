import AppKit
import SwiftUI
import SpaciousCore

/// A window chosen with the picker.
struct PickedWindow {
    let window: AXUIElement
    let pid: pid_t
    /// AX coordinates.
    let frame: CGRect
    /// ⌥-click: assign the whole app rather than this one window.
    let wholeApp: Bool
}

/// An "inspector"-style picker: hover to highlight any window on any
/// screen, click to choose it, Esc to cancel.
///
/// Transparent panels cover every screen to catch the clicks (so the click
/// doesn't also land in the window underneath). Because those panels sit on
/// top, the window under the pointer is found with the system window list
/// (front-to-back, positions only, no extra permission needed) and then
/// matched to its Accessibility element by frame.
@MainActor
final class WindowPicker {
    private var catchers: [NSPanel] = []
    private let highlight = HighlightPanel()
    private var monitors: [Any] = []
    private var hovered: (window: AXUIElement, pid: pid_t, frame: CGRect)?
    private var onPick: ((PickedWindow) -> Void)?

    var isActive: Bool { !catchers.isEmpty }

    func start(onPick: @escaping (PickedWindow) -> Void) {
        stop()
        self.onPick = onPick
        for screen in NSScreen.screens {
            let panel = OverlayPanel(frame: screen.frame)
            panel.level = .popUpMenu
            // Fully clear windows don't receive clicks; this is invisible.
            panel.backgroundColor = NSColor.black.withAlphaComponent(0.001)
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
            panel.contentView = CrosshairView(frame: CGRect(origin: .zero, size: screen.frame.size))
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            catchers.append(panel)
        }
        catchers.first?.makeKey()

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateHover()
            return event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.choose(wholeApp: event.modifierFlags.contains(.option))
            return nil
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.stop() } // Esc
            return nil
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.highlight.wholeApp = event.modifierFlags.contains(.option)
            return event
        } as Any)
        updateHover()
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        catchers.forEach { $0.orderOut(nil) }
        catchers.removeAll()
        highlight.orderOut(nil)
        hovered = nil
        onPick = nil
    }

    private func choose(wholeApp: Bool) {
        guard let hovered, let onPick else { return }
        stop()
        onPick(PickedWindow(window: hovered.window, pid: hovered.pid, frame: hovered.frame, wholeApp: wholeApp))
    }

    private func updateHover() {
        let point = Coordinates.flipPoint(NSEvent.mouseLocation)
        guard let found = Self.window(at: point) else {
            hovered = nil
            highlight.orderOut(nil)
            return
        }
        if let hovered, CFEqual(hovered.window, found.window), hovered.frame == found.frame { return }
        hovered = found
        let app = NSRunningApplication(processIdentifier: found.pid)
        highlight.show(
            frame: found.frame,
            appName: app?.localizedName ?? "App",
            bundleID: app?.bundleIdentifier,
            title: AccessibilityService.title(of: found.window)
        )
    }

    /// The front-most arrangeable window under an AX-space point.
    static func window(at point: CGPoint) -> (window: AXUIElement, pid: pid_t, frame: CGRect)? {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list { // front to back
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(point) else { continue }
            // Match the on-screen window to its Accessibility element: exactly
            // by window number (maximized windows often share a frame), else
            // by frame.
            let candidates = AccessibilityService.windows(of: pid, includeFullScreen: true)
            let number = info[kCGWindowNumber as String] as? CGWindowID
            let match = candidates.first { number != nil && AccessibilityService.windowNumber(of: $0) == number }
                ?? candidates.first { window in
                    guard let f = AccessibilityService.frame(of: window) else { return false }
                    return abs(f.minX - bounds.minX) <= 2 && abs(f.minY - bounds.minY) <= 2
                        && abs(f.width - bounds.width) <= 2 && abs(f.height - bounds.height) <= 2
                }
            if let match { return (match, pid, bounds) }
            // The front-most window here isn't arrangeable (e.g. a panel); stop
            // rather than highlighting something hidden behind it.
            return nil
        }
        return nil
    }
}

/// Shows a crosshair cursor over the picker's catcher panels.
private final class CrosshairView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The outline + label drawn over the hovered window.
private final class HighlightPanel: NSPanel {
    private let model = HighlightModel()

    var wholeApp: Bool {
        get { model.wholeApp }
        set { model.wholeApp = newValue }
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: HighlightView(model: model))
    }

    func show(frame: CGRect, appName: String, bundleID: String?, title: String) {
        model.appName = appName
        model.bundleID = bundleID
        model.title = title
        model.size = frame.size
        setFrame(Coordinates.flip(frame, primaryScreenHeight: DisplayManager.primaryScreenHeight), display: true)
        orderFrontRegardless()
    }
}

@MainActor
@Observable
private final class HighlightModel {
    var appName = ""
    var bundleID: String?
    var title = ""
    var size: CGSize = .zero
    var wholeApp = false
}

private struct HighlightView: View {
    let model: HighlightModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.18))
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor, lineWidth: 3)
            HStack(spacing: 6) {
                if let bundleID = model.bundleID { AppIcon(bundleID: bundleID, size: 16) }
                Text(model.wholeApp ? "All \(model.appName) windows" : label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text("\(Int(model.size.width))×\(Int(model.size.height))")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .padding(8)

            Text("Click to put it in the zone  ·  ⌥-click for the whole app  ·  Esc to cancel")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(10)
        }
    }

    private var label: String {
        model.title.isEmpty ? model.appName : "\(model.appName): \(model.title)"
    }
}

extension Coordinates {
    /// A Cocoa global point → AX global point.
    @MainActor
    static func flipPoint(_ point: CGPoint) -> CGPoint {
        flip(point, primaryScreenHeight: DisplayManager.primaryScreenHeight)
    }
}
