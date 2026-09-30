import AppKit
import SpaciousCore

/// A connected monitor, as Spacious sees it.
struct DisplayInfo: Identifiable, Equatable {
    /// Stable UUID string that survives reboots and re-plugging.
    let id: String
    let cgID: CGDirectDisplayID
    let name: String
    /// Full frame in Cocoa global coordinates.
    let frame: CGRect
    /// Usable frame (excludes menu bar and Dock) in Cocoa global coordinates.
    let visibleFrame: CGRect
    let isMain: Bool

    var sizeDescription: String { "\(Int(frame.width))×\(Int(frame.height))" }
}

/// Enumerates monitors and publishes changes when they are plugged,
/// unplugged, rearranged, or change resolution.
@MainActor
final class DisplayManager {
    private(set) var displays: [DisplayInfo] = []
    var onChange: (([DisplayInfo]) -> Void)?

    private var observer: NSObjectProtocol?

    init() {
        displays = Self.currentDisplays()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let latest = Self.currentDisplays()
        guard latest != displays else { return }
        displays = latest
        onChange?(latest)
    }

    /// Height of the primary display (the one at the Cocoa origin). Needed to
    /// convert between Cocoa and Accessibility coordinates.
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func currentDisplays() -> [DisplayInfo] {
        let mainID = NSScreen.main.flatMap(displayID(of:))
        return NSScreen.screens.compactMap { screen in
            guard let cgID = displayID(of: screen) else { return nil }
            return DisplayInfo(
                id: uuidString(for: cgID),
                cgID: cgID,
                name: screen.localizedName,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                isMain: cgID == mainID
            )
        }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func uuidString(for cgID: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(cgID)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid) as String? else {
            return "display-\(cgID)"
        }
        return string
    }

    /// The display containing a Cocoa-space point, if any.
    func display(containingCocoaPoint point: CGPoint) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) }
    }

    /// The display a window (in AX coordinates) mostly sits on.
    func display(forAXRect rect: CGRect) -> DisplayInfo? {
        let cocoa = Coordinates.flip(rect, primaryScreenHeight: Self.primaryScreenHeight)
        return displays.max { a, b in
            a.frame.intersection(cocoa).area < b.frame.intersection(cocoa).area
        }
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
