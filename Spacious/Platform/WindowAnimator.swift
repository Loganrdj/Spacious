import AppKit
import QuartzCore

/// Glides other apps' windows to new frames.
///
/// macOS has no API to animate another app's window, so this sets the frame
/// in small steps (~60 per second) with ease-in-out timing. The animation is
/// time-based: a slow app that can't keep up skips frames instead of
/// stretching the animation.
@MainActor
enum WindowAnimator {
    /// Animations in flight per app, so "enhanced UI" is switched off once
    /// and restored only when the app's last window lands.
    private static var activeAnimations: [pid_t: Int] = [:]
    private static var restoreEnhancedUI: Set<pid_t> = []

    static func animate(_ window: AXUIElement, to target: CGRect, duration: TimeInterval) async {
        guard duration > 0, let from = AccessibilityService.frame(of: window), from != target else { return }
        let pid = AccessibilityService.pid(of: window)
        if let pid { begin(pid) }
        defer { if let pid { end(pid) } }

        let start = CACurrentMediaTime()
        while true {
            let t = min(1, (CACurrentMediaTime() - start) / duration)
            AccessibilityService.setFrameForAnimation(interpolate(from, target, easeOut(t)), of: window)
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    private static func begin(_ pid: pid_t) {
        let count = activeAnimations[pid, default: 0]
        // Enhanced UI (Chrome, Electron) makes each AX write animate on its own.
        if count == 0, AccessibilityService.disableEnhancedUI(for: pid) { restoreEnhancedUI.insert(pid) }
        activeAnimations[pid] = count + 1
    }

    private static func end(_ pid: pid_t) {
        let count = activeAnimations[pid, default: 1] - 1
        activeAnimations[pid] = count > 0 ? count : nil
        if count <= 0, restoreEnhancedUI.remove(pid) != nil {
            AccessibilityService.restoreEnhancedUI(for: pid)
        }
    }

    /// Cubic ease-out: a quick start that settles gently into place, which
    /// reads as "snappy" when windows cascade one after another.
    private static func easeOut(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }

    private static func interpolate(_ a: CGRect, _ b: CGRect, _ p: Double) -> CGRect {
        let p = CGFloat(p)
        return CGRect(
            x: a.minX + (b.minX - a.minX) * p,
            y: a.minY + (b.minY - a.minY) * p,
            width: a.width + (b.width - a.width) * p,
            height: a.height + (b.height - a.height) * p
        ).integral
    }
}

/// Starts window animations one after another, a short beat apart, so a
/// layout cascades into place instead of everything jumping at once.
/// Windows can be added at any time (e.g. as slow apps finish launching).
@MainActor
final class Waterfall {
    /// Delay between the starts of consecutive windows.
    static let stagger: TimeInterval = 0.07

    private let model: AppModel
    private var nextStart = CACurrentMediaTime()
    private var tasks: [(label: String, task: Task<Bool, Never>)] = []

    init(model: AppModel) {
        self.model = model
    }

    func add(_ move: WindowMove, label: String) {
        let startAt = max(CACurrentMediaTime(), nextStart)
        nextStart = startAt + Self.stagger
        let model = model
        tasks.append((label, Task { @MainActor in
            let wait = startAt - CACurrentMediaTime()
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            return await model.arrange(move)
        }))
    }

    /// Waits for every window to land; returns labels of windows that
    /// couldn't shrink to fit their zone.
    func finish() async -> [String] {
        var tooBig: [String] = []
        for (label, task) in tasks where !(await task.value) {
            tooBig.append(label)
        }
        return tooBig
    }
}
