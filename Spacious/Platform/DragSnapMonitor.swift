import AppKit
import SpaciousCore

/// Watches global mouse events so that holding Shift while dragging any
/// window shows the zones, and releasing the mouse over a zone snaps the
/// window into it.
@MainActor
final class DragSnapMonitor {
    private unowned let model: AppModel
    private var monitor: Any?

    private var candidate: AXUIElement?
    private var candidateOrigin: CGPoint?
    private var isMovingWindow = false
    private var target: (display: DisplayInfo, grid: MonitorGrid, zone: Zone)?

    init(model: AppModel) {
        self.model = model
    }

    /// (Re)installs the global event monitor. Safe to call repeatedly.
    func start() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            reset()
            guard model.document.settings.shiftDragEnabled, model.isAccessibilityTrusted else { return }
            let point = Coordinates.flip(NSEvent.mouseLocation, primaryScreenHeight: DisplayManager.primaryScreenHeight)
            candidate = AccessibilityService.window(at: point)
            candidateOrigin = candidate.flatMap(AccessibilityService.frame(of:))?.origin

        case .leftMouseDragged, .flagsChanged:
            guard let candidate else { return }
            // Only react once the window itself is moving (not text selection etc.).
            if !isMovingWindow {
                guard let origin = candidateOrigin, let frame = AccessibilityService.frame(of: candidate),
                      frame.origin != origin else { return }
                isMovingWindow = true
            }
            if NSEvent.modifierFlags.contains(.shift) {
                model.overlay.showDragOverlay()
                target = model.overlay.updateDragHighlight(at: NSEvent.mouseLocation)
            } else if model.overlay.isVisible && !model.overlay.state.interactive {
                model.overlay.hide()
                target = nil
            }

        case .leftMouseUp:
            if isMovingWindow, let window = candidate, let target, NSEvent.modifierFlags.contains(.shift) {
                // Give the system a moment to finish its own drag before resizing.
                Task { @MainActor [model] in
                    try? await Task.sleep(for: .milliseconds(60))
                    model.place(window, cells: target.zone.cells, in: target.grid, on: target.display)
                }
            }
            if model.overlay.isVisible && !model.overlay.state.interactive { model.overlay.hide() }
            reset()

        default:
            break
        }
    }

    private func reset() {
        candidate = nil
        candidateOrigin = nil
        isMovingWindow = false
        target = nil
    }
}
