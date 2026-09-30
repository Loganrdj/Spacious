import AppKit
import Observation
import SwiftUI
import SpaciousCore

/// Shared state the overlay views render.
@MainActor
@Observable
final class OverlayState {
    /// true: the user picks a zone/cells with the mouse (hotkey mode).
    /// false: display-only highlight while shift-dragging a window.
    var interactive = false
    var highlightedZoneID: UUID?
    var highlightedDisplayID: String?
    /// Live drag-selection in the picker, per display.
    var selection: (displayID: String, cells: CellRect)?
    /// Display holding the window being snapped (gets the hint label).
    var targetDisplayID: String?
}

/// Shows a full-screen panel on every monitor that draws that monitor's grid
/// and zones. Used by the snap hotkey (interactive) and shift-drag (passive).
@MainActor
final class SnapOverlayController {
    let state = OverlayState()
    private unowned let model: AppModel
    private var panels: [String: OverlayPanel] = [:]
    private var targetWindow: AXUIElement?
    private var keyMonitor: Any?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { !panels.isEmpty }

    // MARK: Hotkey picker

    func showPicker(for window: AXUIElement) {
        hide()
        targetWindow = window
        state.interactive = true
        state.targetDisplayID = AccessibilityService.frame(of: window).flatMap { model.displayManager.display(forAXRect: $0) }?.id
            ?? model.displays.first(where: \.isMain)?.id
        showPanels(interactive: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.hide()
                return nil
            }
            return event
        }
        if let id = state.targetDisplayID, let panel = panels[id] {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    fileprivate func pick(displayID: String, cells: CellRect) {
        guard let window = targetWindow, let display = model.display(id: displayID), let grid = model.grid(for: displayID) else {
            return hide()
        }
        hide()
        AccessibilityService.setFrame(model.axFrame(for: cells, in: grid, on: display), of: window)
        AccessibilityService.raise(window)
    }

    // MARK: Shift-drag

    func showDragOverlay() {
        guard !isVisible || state.interactive == true else { return }
        if state.interactive { hide() }
        state.interactive = false
        state.targetDisplayID = nil
        showPanels(interactive: false)
    }

    /// Updates the highlighted zone under a Cocoa-space point and returns it.
    @discardableResult
    func updateDragHighlight(at point: CGPoint) -> (display: DisplayInfo, grid: MonitorGrid, zone: Zone)? {
        guard let display = model.displayManager.display(containingCocoaPoint: point),
              let grid = model.grid(for: display.id) else {
            state.highlightedZoneID = nil
            state.highlightedDisplayID = nil
            return nil
        }
        let visible = display.visibleFrame
        let local = Coordinates.localPoint(fromCocoa: point, in: visible)
        let zone = GridMath.cellIfInside(local, columns: grid.columns, rows: grid.rows, in: visible.size)
            .flatMap(grid.zone(at:))
        state.highlightedZoneID = zone?.id
        state.highlightedDisplayID = zone == nil ? nil : display.id
        return zone.map { (display, grid, $0) }
    }

    // MARK: Panels

    private func showPanels(interactive: Bool) {
        for display in model.displays {
            let panel = OverlayPanel(frame: display.frame)
            panel.ignoresMouseEvents = !interactive
            let view = OverlayView(
                model: model,
                state: state,
                displayID: display.id,
                onPick: { [weak self] cells in self?.pick(displayID: display.id, cells: cells) },
                onCancel: { [weak self] in self?.hide() }
            )
            let host = FirstMouseHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: display.frame.size)
            panel.contentView = host
            panel.setFrame(display.frame, display: true)
            panel.orderFrontRegardless()
            panels[display.id] = panel
        }
    }

    func hide() {
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        targetWindow = nil
        state.interactive = false
        state.highlightedZoneID = nil
        state.highlightedDisplayID = nil
        state.selection = nil
    }
}

/// Borderless, transparent panel that floats above normal windows on every
/// Space without activating Spacious (so the target app keeps focus).
final class OverlayPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
}

/// Lets the first click on a non-key overlay register immediately.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
