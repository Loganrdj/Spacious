import SwiftUI
import SpaciousCore

/// Grid size controls and a drag-to-create zone canvas for one monitor.
struct GridEditorView: View {
    let model: AppModel
    let display: DisplayInfo
    let grid: MonitorGrid

    @State private var pendingQuickLayout: QuickLayout?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(display.name).font(.headline)
                    Text(display.sizeDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                quickLayoutMenu
            }

            HStack(spacing: 14) {
                DimensionStepper(label: "Columns", value: grid.columns) { cols in
                    model.updateGrid(display.id) { $0.resize(columns: cols, rows: $0.rows) }
                }
                DimensionStepper(label: "Rows", value: grid.rows) { rows in
                    model.updateGrid(display.id) { $0.resize(columns: $0.columns, rows: rows) }
                }
                Spacer()
                if !grid.zones.isEmpty {
                    Button {
                        model.updateGrid(display.id) { $0.zones.removeAll() }
                        model.selectedZoneID = nil
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove all zones on this monitor")
                }
            }

            GridCanvas(model: model, display: display, grid: grid)

            Text(grid.zones.isEmpty
                 ? "Click a cell or drag across cells to make a zone."
                 : "Click a zone to edit it · drag to make another")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .confirmationDialog(
            "Replace the zones on \(display.name)?",
            isPresented: Binding(get: { pendingQuickLayout != nil }, set: { if !$0 { pendingQuickLayout = nil } }),
            presenting: pendingQuickLayout
        ) { layout in
            Button("Replace with \(layout.title)", role: .destructive) { apply(layout) }
        } message: { _ in
            Text("Existing zones and their app assignments on this monitor will be removed.")
        }
    }

    private var quickLayoutMenu: some View {
        Menu {
            Section("Quick layouts") {
                ForEach(QuickLayout.all(portrait: display.frame.height > display.frame.width)) { layout in
                    Button(layout.title) {
                        if grid.zones.contains(where: { !$0.apps.isEmpty }) {
                            pendingQuickLayout = layout
                        } else {
                            apply(layout)
                        }
                    }
                }
            }
        } label: {
            Label("Quick layout", systemImage: "square.grid.2x2")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func apply(_ layout: QuickLayout) {
        if layout.zonesPerCell {
            model.applyQuickLayout(display.id, columns: layout.columns, rows: layout.rows)
        } else {
            model.updateGrid(display.id) { $0.zones.removeAll(); $0.resize(columns: layout.columns, rows: layout.rows) }
            model.selectedZoneID = nil
        }
    }
}

struct QuickLayout: Identifiable, Hashable {
    let title: String
    let columns: Int
    let rows: Int
    /// Create one zone per cell (vs. an empty fine grid).
    var zonesPerCell = true
    var id: String { title }

    static func all(portrait: Bool) -> [QuickLayout] {
        let common = [
            QuickLayout(title: "Halves (2×1)", columns: 2, rows: 1),
            QuickLayout(title: "Thirds (3×1)", columns: 3, rows: 1),
            QuickLayout(title: "Quarters (2×2)", columns: 2, rows: 2),
            QuickLayout(title: "Sixths (3×2)", columns: 3, rows: 2),
        ]
        let stacked = [
            QuickLayout(title: "Stacked halves (1×2)", columns: 1, rows: 2),
            QuickLayout(title: "Stacked thirds (1×3)", columns: 1, rows: 3),
        ]
        let fine = [
            QuickLayout(title: "Fine 20×10 grid (draw your own)", columns: 20, rows: 10, zonesPerCell: false),
            QuickLayout(title: "Fine 10×20 grid (draw your own)", columns: 10, rows: 20, zonesPerCell: false),
        ]
        return portrait ? stacked + common + [fine[1]] : common + stacked + [fine[0]]
    }
}

private struct DimensionStepper: View {
    let label: String
    let value: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Stepper(value: Binding(get: { value }, set: onChange), in: 1...MonitorGrid.maxDimension) {
                Text("\(value)").monospacedDigit().frame(minWidth: 18, alignment: .trailing)
            }
        }
        .font(.callout)
    }
}

/// The interactive miniature of a monitor. Drag across cells to create a
/// zone; click a zone to select it.
private struct GridCanvas: View {
    let model: AppModel
    let display: DisplayInfo
    let grid: MonitorGrid

    @State private var dragSelection: CellRect?
    @State private var dragStart: GridCell?

    private let maxSize = CGSize(width: 368, height: 230)

    var body: some View {
        let visible = display.visibleFrame.size
        let scale = min(maxSize.width / visible.width, maxSize.height / visible.height)
        let size = CGSize(width: (visible.width * scale).rounded(), height: (visible.height * scale).rounded())
        let gap = max(2, model.gap * scale)

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))
            GridLines(columns: grid.columns, rows: grid.rows)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)

            ForEach(grid.zones) { zone in
                let r = GridMath.frame(for: zone.cells, columns: grid.columns, rows: grid.rows, in: size, gap: gap)
                ZoneTile(zone: zone, selected: zone.id == model.selectedZoneID)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
            }

            if let dragSelection {
                let r = GridMath.frame(for: dragSelection, columns: grid.columns, rows: grid.rows, in: size, gap: gap)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.3))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                Text("\(dragSelection.width)×\(dragSelection.height)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 4)
                    .background(.thinMaterial, in: Capsule())
                    .offset(x: r.minX + 4, y: r.minY + 4)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard let start = dragStart ?? cell(value.startLocation, size), let current = cell(value.location, size) else { return }
                    dragStart = start
                    if start != current || grid.zone(at: start) == nil {
                        dragSelection = CellRect(from: start, to: current)
                    }
                }
                .onEnded { value in
                    defer { dragStart = nil; dragSelection = nil }
                    guard let start = dragStart ?? cell(value.startLocation, size), let end = cell(value.location, size) else { return }
                    if start == end, let zone = grid.zone(at: start) {
                        model.selectedZoneID = zone.id
                    } else {
                        model.addZone(display.id, cells: CellRect(from: start, to: end))
                    }
                }
        )
        .frame(maxWidth: .infinity)
    }

    private func cell(_ point: CGPoint, _ size: CGSize) -> GridCell? {
        GridMath.cell(at: point, columns: grid.columns, rows: grid.rows, in: size)
    }
}
