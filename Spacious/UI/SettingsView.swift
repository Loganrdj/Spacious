import KeyboardShortcuts
import SwiftUI
import SpaciousCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("Snapping") {
                HStack {
                    Text("Gap between windows")
                    Spacer()
                    Text("\(Int(model.document.settings.gap)) pt").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $model.document.settings.gap, in: 0...32, step: 2)
                Toggle("Hold Shift while dragging a window to snap it into a zone", isOn: $model.document.settings.shiftDragEnabled)
            }

            group("Layout “\(model.activeLayout.name)”") {
                Toggle("Open assigned apps that aren't running when applying", isOn: $model.activeLayout.launchMissingApps)
            }

            group("Keyboard shortcuts") {
                shortcutRow("Snap focused window", .snapFocusedWindow)
                shortcutRow("Apply layout", .applyLayout)
                shortcutRow("Next layout", .nextLayout)
            }

            group("General") {
                Toggle("Open Spacious at login", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                HStack {
                    Image(systemName: model.isAccessibilityTrusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.isAccessibilityTrusted ? .green : .orange)
                    Text(model.isAccessibilityTrusted ? "Accessibility access granted" : "Accessibility access needed")
                    Spacer()
                    if !model.isAccessibilityTrusted {
                        Button("Grant…") { model.requestAccessibility() }
                    }
                }
            }

            HStack {
                Text("Spacious \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Quit Spacious") {
                    model.saveNow()
                    NSApp.terminate(nil)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private func shortcutRow(_ title: String, _ name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(title)
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: title)
            content()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
