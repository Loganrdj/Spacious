import SwiftUI
import SpaciousCore

/// Edit a zone's name, color, and assigned apps.
struct ZoneInspectorView: View {
    let model: AppModel
    let display: DisplayInfo
    let grid: MonitorGrid
    let zone: Zone

    @State private var name = ""
    @State private var showingPicker = false
    @Environment(\.dismiss) private var dismiss

    private var displayID: String { display.id }

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
                Text("\(zone.cells.width)×\(zone.cells.height) cells · \(sizeText(zoneSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(zone.apps.enumerated()), id: \.offset) { index, app in
                    appRow(app, index: index)
                }
                if showingPicker {
                    AssignPicker(existing: zone.apps, onAdd: add, onClose: { showingPicker = false })
                } else {
                    HStack(spacing: 14) {
                        Button {
                            showingPicker = true
                        } label: {
                            Label(zone.apps.isEmpty ? "Assign…" : "Assign another…", systemImage: "plus.app")
                        }
                        Button {
                            // Close the menu so it doesn't cover the windows, then pick.
                            dismiss()
                            model.pickWindow(forZone: zone.id, on: displayID)
                        } label: {
                            Label("Pick a window", systemImage: "scope")
                        }
                        .help("Point at any window and click it to put it in this zone")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(10)
        .background(zone.color.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(zone.color.color.opacity(0.4)))
        .onAppear { name = zone.name }
        .onChange(of: zone.id) {
            name = zone.name
            showingPicker = false
        }
    }

    @ViewBuilder
    private func appRow(_ app: AppRef, index: Int) -> some View {
        let issue = model.fitIssue(for: app, cells: zone.cells, in: grid, on: display)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                AppIcon(bundleID: app.bundleID, size: 18)
                targetLabel(app, index: index)
                if issue != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .yellow)
                }
                Spacer()
                Button {
                    model.updateZone(displayID, zone.id) { zone in
                        if zone.apps.indices.contains(index) { zone.apps.remove(at: index) }
                    }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove \(app.label) from this zone")
            }
            if let issue {
                fitWarning(app: app, issue: issue)
            }
        }
    }

    @ViewBuilder
    private func targetLabel(_ app: AppRef, index: Int) -> some View {
        switch app.kind {
        case .app:
            Text(app.name)
        case .window:
            VStack(alignment: .leading, spacing: 1) {
                Text("\(app.name) window titled…").font(.caption).foregroundStyle(.secondary)
                TextField("Title contains", text: patternBinding(index, \.windowTitle))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
        case .website:
            VStack(alignment: .leading, spacing: 1) {
                Text("Website in \(app.name)").font(.caption).foregroundStyle(.secondary)
                TextField("example.com", text: patternBinding(index, \.url))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
        }
    }

    /// Edits a window title or URL pattern in place. Empty text is kept as ""
    /// (not nil) so the target doesn't silently turn into a whole-app target.
    private func patternBinding(_ index: Int, _ keyPath: WritableKeyPath<AppRef, String?>) -> Binding<String> {
        Binding(
            get: { zone.apps.indices.contains(index) ? zone.apps[index][keyPath: keyPath] ?? "" : "" },
            set: { text in
                model.updateZone(displayID, zone.id) { zone in
                    if zone.apps.indices.contains(index) { zone.apps[index][keyPath: keyPath] = text }
                }
            }
        )
    }

    private func fitWarning(app: AppRef, issue: ZoneFitIssue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(app.name) can't get smaller than \(sizeText(issue.minimum)).")
                Text(issue.fitsOnMonitor
                     ? "This zone is \(sizeText(issue.zoneSize)), so the window will overlap nearby zones."
                     : "It doesn't fit on \(display.name) even at full size. Try another monitor.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let suggested = issue.suggestedCells {
                Button("Grow zone to fit") {
                    model.updateZone(displayID, zone.id) { $0.cells = suggested }
                }
                .controlSize(.small)
                .help("Resize to \(suggested.width)×\(suggested.height) cells")
            }
        }
        .padding(8)
        .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    private var zoneSize: CGSize {
        GridMath.frame(for: zone.cells, columns: grid.columns, rows: grid.rows, in: display.visibleFrame.size).size
    }

    private func sizeText(_ size: CGSize) -> String { "\(Int(size.width))×\(Int(size.height))" }

    private func sizeText(_ size: Size2D) -> String {
        // A 0 dimension means only the other dimension is known to be limited.
        switch (size.width > 0, size.height > 0) {
        case (true, true): "\(Int(size.width))×\(Int(size.height))"
        case (true, false): "\(Int(size.width)) pt wide"
        default: "\(Int(size.height)) pt tall"
        }
    }

    private func add(_ app: AppRef) {
        model.updateZone(displayID, zone.id) { zone in
            if !zone.apps.contains(where: { $0.id == app.id }) { zone.apps.append(app) }
        }
        showingPicker = false
        // Measure right away (running apps only) so a too-small zone is
        // flagged now rather than after the first Apply.
        model.measureMinimumSize(of: app.bundleID)
    }

    private func commitName() {
        guard name != zone.name else { return }
        model.updateZone(displayID, zone.id) { $0.name = name }
    }
}
