import SwiftUI
import SpaciousCore

/// Inline chooser for what goes in a zone: a whole app, one specific window,
/// or a website (a browser tab that gets its own window).
struct AssignPicker: View {
    let existing: [AppRef]
    let onAdd: (AppRef) -> Void
    let onClose: () -> Void

    enum Kind: String, CaseIterable, Identifiable {
        case app = "App", window = "Window", website = "Website"
        var id: String { rawValue }

        var hint: String {
            switch self {
            case .app: "All of the app's windows go in this zone."
            case .window: "Just one window, matched by its title."
            case .website: "A browser tab, moved into its own window."
            }
        }
    }

    @State private var kind: Kind = .app
    @State private var search = ""
    @State private var windows: [AppCatalog.WindowChoice] = []
    @State private var tabs: [BrowserTab] = []
    @State private var blockedBrowsers: [String] = []
    @State private var typedAddress = ""
    @State private var typedBrowserID = BrowserBridge.installed.first?.bundleID ?? "com.apple.Safari"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Assign", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Cancel")
            }
            Text(kind.hint).font(.caption).foregroundStyle(.secondary)

            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    switch kind {
                    case .app: appRows
                    case .window: windowRows
                    case .website: websiteRows
                    }
                }
            }
            .frame(height: 170)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            switch kind {
            case .app:
                Button("Choose from Applications…") {
                    if let app = AppCatalog.chooseApp() { onAdd(app) }
                }
                .buttonStyle(.borderless)
            case .website:
                typedAddressRow
            case .window:
                EmptyView()
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .task(id: kind) { load() }
    }

    // MARK: Rows

    @ViewBuilder
    private var appRows: some View {
        let apps = AppCatalog.runningApps().filter { app in
            matchesSearch(app.name) && !existing.contains(app)
        }
        if apps.isEmpty { emptyRow("No matching apps are running.") }
        ForEach(apps) { app in
            PickerRow(bundleID: app.bundleID, title: app.name) { onAdd(app) }
        }
    }

    @ViewBuilder
    private var windowRows: some View {
        let choices = windows.filter { matchesSearch($0.title) || matchesSearch($0.appName) }
        if choices.isEmpty { emptyRow("No matching windows are open.") }
        ForEach(choices) { choice in
            PickerRow(bundleID: choice.bundleID, title: choice.title, subtitle: choice.appName) {
                onAdd(AppRef(bundleID: choice.bundleID, name: choice.appName, windowTitle: choice.title))
            }
        }
    }

    @ViewBuilder
    private var websiteRows: some View {
        ForEach(blockedBrowsers, id: \.self) { name in
            VStack(alignment: .leading, spacing: 4) {
                Text("Allow Spacious to control \(name) to see its tabs.")
                    .font(.caption)
                Button("Open Automation Settings") { BrowserBridge.openAutomationSettings() }
                    .controlSize(.small)
            }
            .padding(6)
        }
        let matching = tabs.filter { matchesSearch($0.title) || matchesSearch($0.url) }
        if matching.isEmpty && blockedBrowsers.isEmpty {
            emptyRow(BrowserBridge.installed.isEmpty
                     ? "No supported browser found (Chrome, Safari, Edge, Brave, Vivaldi)."
                     : "No matching tabs are open. Type an address below.")
        }
        ForEach(matching) { tab in
            let pattern = TargetMatching.suggestedPattern(for: tab.url)
            PickerRow(bundleID: tab.browserBundleID, title: tab.title, subtitle: pattern) {
                onAdd(AppRef(bundleID: tab.browserBundleID, name: tab.browserName, url: pattern))
            }
        }
    }

    private var typedAddressRow: some View {
        HStack(spacing: 6) {
            TextField("or type an address, e.g. mail.google.com", text: $typedAddress)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addTypedAddress)
            Picker("Browser", selection: $typedBrowserID) {
                ForEach(BrowserBridge.installed) { browser in
                    Text(browser.name).tag(browser.bundleID)
                }
            }
            .labelsHidden()
            .fixedSize()
            Button("Add", action: addTypedAddress)
                .disabled(TargetMatching.normalize(typedAddress).isEmpty)
        }
    }

    private func addTypedAddress() {
        let pattern = TargetMatching.normalize(typedAddress)
        guard !pattern.isEmpty, let browser = BrowserBridge.browser(for: typedBrowserID) else { return }
        onAdd(AppRef(bundleID: browser.bundleID, name: browser.name, url: pattern))
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(8)
    }

    private func matchesSearch(_ text: String) -> Bool {
        search.isEmpty || text.localizedCaseInsensitiveContains(search)
    }

    // MARK: Loading

    private func load() {
        switch kind {
        case .app:
            break
        case .window:
            windows = AppCatalog.openWindows()
        case .website:
            var found: [BrowserTab] = []
            var blocked: [String] = []
            for browser in BrowserBridge.installed where BrowserBridge.pid(of: browser) != nil {
                do {
                    found += try BrowserBridge.tabs(in: browser)
                } catch BrowserError.notAllowed {
                    blocked.append(browser.name)
                } catch {
                    continue
                }
            }
            // One row per URL; the same page open twice is one choice.
            var seen = Set<String>()
            tabs = found.filter { seen.insert($0.url).inserted }
            blockedBrowsers = blocked
            if let running = BrowserBridge.installed.first(where: { BrowserBridge.pid(of: $0) != nil }) {
                typedBrowserID = running.bundleID
            }
        }
    }
}

/// A clickable list row with an app icon, a title, and an optional subtitle.
private struct PickerRow: View {
    let bundleID: String
    let title: String
    var subtitle: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                AppIcon(bundleID: bundleID, size: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(hovering ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
