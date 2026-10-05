import KeyboardShortcuts
import SwiftUI
import SpaciousCore

/// The window shown when clicking the Spacious menu bar icon.
struct MenuPopoverView: View {
    @Bindable var model: AppModel

    @State private var showingSettings = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var confirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if showingSettings {
                    SettingsView(model: model)
                } else {
                    if !model.isAccessibilityTrusted {
                        PermissionBanner(model: model)
                    }
                    editor
                }
            }
            .padding(14)

            Divider()
            footer
                .padding(14)
        }
        .frame(width: 400)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.3x3")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            if isRenaming {
                TextField("Layout name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(finishRename)
                Button("Done", action: finishRename)
            } else {
                layoutMenu
            }
            Spacer()
            Button {
                showingSettings.toggle()
            } label: {
                Image(systemName: showingSettings ? "xmark" : "gearshape")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help(showingSettings ? "Back to layout" : "Settings")
        }
        .confirmationDialog("Delete “\(model.activeLayout.name)”?", isPresented: $confirmingDelete) {
            Button("Delete Layout", role: .destructive) { model.deleteActiveLayout() }
        }
    }

    private var layoutMenu: some View {
        Menu {
            Section("Layouts") {
                ForEach(model.document.layouts) { layout in
                    Button {
                        model.selectLayout(layout.id)
                    } label: {
                        if layout.id == model.activeLayout.id {
                            Label(layout.name, systemImage: "checkmark")
                        } else {
                            Text(layout.name)
                        }
                    }
                }
            }
            Divider()
            Button("New Layout") { model.newLayout() }
            Button("Duplicate “\(model.activeLayout.name)”") { model.duplicateActiveLayout() }
            Button("Rename…") {
                renameText = model.activeLayout.name
                isRenaming = true
            }
            Button("Delete…", role: .destructive) { confirmingDelete = true }
                .disabled(model.document.layouts.count < 2)
        } label: {
            Text(model.activeLayout.name).font(.headline)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func finishRename() {
        model.renameActiveLayout(renameText)
        isRenaming = false
    }

    // MARK: Editor

    @ViewBuilder
    private var editor: some View {
        SectionLabel(title: "Your monitors")
        MonitorMapView(model: model)

        if let id = model.selectedDisplayID, let display = model.display(id: id), let grid = model.grid(for: id) {
            Divider()
            GridEditorView(model: model, display: display, grid: grid)
            if let zoneID = model.selectedZoneID, let zone = grid.zones.first(where: { $0.id == zoneID }) {
                ZoneInspectorView(model: model, display: display, grid: grid, zone: zone)
            }
        }

        let disconnected = model.disconnectedGrids
        if !disconnected.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(disconnected) { grid in
                    HStack {
                        Image(systemName: "display.trianglebadge.exclamationmark")
                            .foregroundStyle(.secondary)
                        Text("\(grid.displayName) not connected. Its grid is saved.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Forget") { model.forgetMonitor(grid.displayID) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    model.applyActiveLayout()
                } label: {
                    HStack {
                        Image(systemName: "rectangle.3.group")
                        Text("Arrange")
                        if let shortcut = KeyboardShortcuts.getShortcut(for: .applyLayout) {
                            Text(shortcut.description).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .help("Move open windows into “\(model.activeLayout.name)”")

                Button {
                    model.launchAll()
                } label: {
                    HStack {
                        Image(systemName: "power")
                        Text("Launch All")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Open every app and website in “\(model.activeLayout.name)”, then arrange them")
            }
            .controlSize(.large)
            .disabled(!model.isAccessibilityTrusted || model.isApplying)

            if let message = model.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let snap = KeyboardShortcuts.getShortcut(for: .snapFocusedWindow) {
                Text("Snap any window: \(snap.description)  ·  or Shift-drag it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
