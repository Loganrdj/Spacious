import AppKit
import SwiftUI

/// Detects Spacious running from somewhere other than an Applications
/// folder (the DMG, Downloads, or a quarantine "translocated" copy) and
/// moves it into /Applications.
///
/// This matters for permissions: macOS ties Accessibility access to the
/// app's location and signature, so a copy run from the DMG or a random
/// translocated path can appear allowed in System Settings yet never be
/// trusted.
@MainActor
enum InstallLocation {
    static var needsMove: Bool {
        #if DEBUG
        return false // development builds run from DerivedData
        #else
        let path = Bundle.main.bundlePath
        let applicationFolders = ["/Applications/", NSHomeDirectory() + "/Applications/"]
        return !applicationFolders.contains { path.hasPrefix($0) }
        #endif
    }

    enum MoveError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    /// Copies the running app to /Applications (replacing an older copy),
    /// clears the quarantine flag, opens the new copy, and quits this one.
    static func moveToApplications() throws {
        let source = URL(fileURLWithPath: Bundle.main.bundlePath)
        let destination = URL(fileURLWithPath: "/Applications/Spacious.app")
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                // Quit any other running copy first so it can be replaced.
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                where app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    app.terminate()
                }
                try fm.trashItem(at: destination, resultingItemURL: nil)
            }
            try fm.copyItem(at: source, to: destination)
        } catch {
            throw MoveError.failed("Couldn't move Spacious to Applications: \(error.localizedDescription) Drag it there from the disk image instead.")
        }

        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", destination.path]
        try? xattr.run()
        xattr.waitUntilExit()

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Shown at the top of the menu while Spacious runs outside Applications.
struct MoveToApplicationsBanner: View {
    @State private var error: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.app.fill")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 6) {
                Text("Move Spacious to Applications").font(.headline)
                Text("It's running from \(Bundle.main.bundlePath.contains("/Volumes/") ? "the disk image" : "outside Applications"), which can stop macOS from granting it access to move windows.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                Button("Move to Applications") {
                    do { try InstallLocation.moveToApplications() } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
