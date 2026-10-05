import KeyboardShortcuts
import SwiftUI
import SpaciousCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("Snapping") {
                Toggle("Hold Shift while dragging a window to snap it into a zone", isOn: $model.document.settings.shiftDragEnabled)
                HStack {
                    Text("Window animation")
                    Spacer()
                    Picker("Window animation", selection: $model.document.settings.animationDuration) {
                        Text("Off").tag(0.0)
                        Text("Quick").tag(0.2)
                        Text("Smooth").tag(0.35)
                        Text("Relaxed").tag(0.6)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            group("When Spacious opens") {
                Picker("When Spacious opens", selection: $model.document.settings.startupAction) {
                    Text("Do nothing").tag(StartupAction.nothing)
                    Text("Arrange open windows").tag(StartupAction.arrange)
                    Text("Launch all apps & websites, then arrange").tag(StartupAction.launchAll)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if model.document.settings.startupAction != .nothing && !model.launchAtLogin {
                    HStack {
                        Text("Also open Spacious at login to set up your Mac automatically after a restart.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Turn On") { model.setLaunchAtLogin(true) }
                    }
                }
            }

            group("Layout “\(model.activeLayout.name)”") {
                Toggle("Arrange also opens apps and websites that aren't open", isOn: $model.activeLayout.launchMissingApps)
            }

            group("Keyboard shortcuts") {
                shortcutRow("Snap focused window", .snapFocusedWindow)
                shortcutRow("Arrange", .applyLayout)
                shortcutRow("Launch all", .launchAll)
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
