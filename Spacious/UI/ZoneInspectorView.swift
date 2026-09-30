import SwiftUI
import SpaciousCore

/// Edit a zone's name, color, and assigned apps.
struct ZoneInspectorView: View {
    let model: AppModel
    let displayID: String
    let zone: Zone

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(zone.apps.isEmpty ? "Zone name" : zone.displayName, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitName)
                    .onChange(of: name) { commitName() }
                Button(role: .destructive) {
                    model.deleteZone(displayID, zone.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete zone")
                Button {
                    model.selectedZoneID = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Done")
            }

            HStack(spacing: 6) {
                ForEach(ZoneColor.allCases, id: \.self) { color in
                    Circle()
                        .fill(color.color)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: color == zone.color ? 2 : 0))
                        .onTapGesture { model.updateZone(displayID, zone.id) { $0.color = color } }
                }
                Spacer()
                Text("\(zone.cells.width)×\(zone.cells.height) cells")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(zone.apps) { app in
                    HStack {
                        AppIcon(bundleID: app.bundleID, size: 18)
                        Text(app.name)
                        Spacer()
                        Button {
                            model.updateZone(displayID, zone.id) { $0.apps.removeAll { $0.bundleID == app.bundleID } }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(app.name) from this zone")
                    }
                }
                addAppMenu
            }
        }
        .padding(10)
        .background(zone.color.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(zone.color.color.opacity(0.4)))
        .onAppear { name = zone.name }
        .onChange(of: zone.id) { name = zone.name }
    }

    private var addAppMenu: some View {
        Menu {
            Section("Running apps") {
                ForEach(AppCatalog.runningApps().filter { app in !zone.apps.contains { $0.bundleID == app.bundleID } }) { app in
                    Button {
                        add(app)
                    } label: {
                        Label { Text(app.name) } icon: { Image(nsImage: AppCatalog.icon(for: app.bundleID)) }
                    }
                }
            }
            Divider()
            Button("Choose from Applications…") {
                if let app = AppCatalog.chooseApp() { add(app) }
            }
        } label: {
            Label("Assign an app", systemImage: "plus.app")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func add(_ app: AppRef) {
        model.updateZone(displayID, zone.id) { zone in
            if !zone.apps.contains(where: { $0.bundleID == app.bundleID }) { zone.apps.append(app) }
        }
    }

    private func commitName() {
        guard name != zone.name else { return }
        model.updateZone(displayID, zone.id) { $0.name = name }
    }
}
