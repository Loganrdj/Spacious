import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SpaciousCore

extension ZoneColor {
    var color: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .gray: .gray
        }
    }
}

/// Finding apps and their icons for the zone app picker.
@MainActor
enum AppCatalog {
    private static var iconCache: [String: NSImage] = [:]

    /// Regular (Dock-visible) running apps, alphabetized.
    static func runningApps() -> [AppRef] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AppRef? in
                guard let id = app.bundleIdentifier, id != own, seen.insert(id).inserted else { return nil }
                return AppRef(bundleID: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A small icon for an app, cached.
    static func icon(for bundleID: String, size: CGFloat = 16) -> NSImage {
        let key = "\(bundleID)@\(size)"
        if let cached = iconCache[key] { return cached }
        let base: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            base = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            base = NSWorkspace.shared.icon(for: .application)
        }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            base.draw(in: rect)
            return true
        }
        iconCache[key] = image
        return image
    }

    /// Lets the user pick any app from /Applications.
    static func chooseApp() -> AppRef? {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.prompt = "Assign"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return AppRef(bundleID: id, name: name)
    }
}

/// A rounded app icon.
struct AppIcon: View {
    let bundleID: String
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: AppCatalog.icon(for: bundleID, size: size))
            .resizable()
            .frame(width: size, height: size)
    }
}

/// Section header used in the popover.
struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
