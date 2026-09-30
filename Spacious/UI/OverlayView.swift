import SwiftUI
import SpaciousCore

/// Full-screen overlay for one monitor: its grid and zones, drawn at real size.
struct OverlayView: View {
    let model: AppModel
    let state: OverlayState
    let displayID: String
    let onPick: (CellRect) -> Void
    let onCancel: () -> Void

    @State private var dragStart: GridCell?

    var body: some View {
        if let display = model.display(id: displayID), let grid = model.grid(for: displayID) {
            let visible = display.visibleFrame
            ZStack(alignment: .topLeading) {
                Color.black.opacity(state.interactive ? 0.3 : 0.12)
                    .ignoresSafeArea()
                    .onTapGesture { if state.interactive { onCancel() } }

                gridArea(grid: grid, size: visible.size)
                    .frame(width: visible.width, height: visible.height)
                    .offset(x: visible.minX - display.frame.minX, y: display.frame.maxY - visible.maxY)
            }
            .frame(width: display.frame.width, height: display.frame.height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func gridArea(grid: MonitorGrid, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if state.interactive {
                GridLines(columns: grid.columns, rows: grid.rows)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            }

            ForEach(grid.zones) { zone in
                let rect = GridMath.frame(for: zone.cells, columns: grid.columns, rows: grid.rows, in: size, gap: model.gap)
                ZoneTile(zone: zone, highlighted: zone.id == state.highlightedZoneID, large: true,
                         tooSmall: model.display(id: displayID).map { model.zoneIsTooSmall(zone, in: grid, on: $0) } ?? false)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }

            if let selection = state.selection, selection.displayID == displayID {
                let rect = GridMath.frame(for: selection.cells, columns: grid.columns, rows: grid.rows, in: size, gap: model.gap)
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white, style: StrokeStyle(lineWidth: 3, dash: [10, 6])))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }

            if state.interactive && state.targetDisplayID == displayID {
                Text("Click a zone, or drag across cells  ·  Esc to cancel")
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .frame(width: size.width)
                    .offset(y: 24)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(pickGesture(grid: grid, size: size), including: state.interactive ? .all : .none)
        .onContinuousHover { phase in
            guard state.interactive, state.selection == nil else { return }
            if case .active(let point) = phase,
               let cell = GridMath.cellIfInside(point, columns: grid.columns, rows: grid.rows, in: size) {
                state.highlightedZoneID = grid.zone(at: cell)?.id
            } else {
                state.highlightedZoneID = nil
            }
        }
    }

    private func pickGesture(grid: MonitorGrid, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let start = dragStart ?? GridMath.cell(at: value.startLocation, columns: grid.columns, rows: grid.rows, in: size),
                      let current = GridMath.cell(at: value.location, columns: grid.columns, rows: grid.rows, in: size) else { return }
                dragStart = start
                if start != current {
                    state.highlightedZoneID = nil
                    state.selection = (displayID, CellRect(from: start, to: current))
                }
            }
            .onEnded { value in
                defer { dragStart = nil }
                guard let start = dragStart ?? GridMath.cell(at: value.startLocation, columns: grid.columns, rows: grid.rows, in: size),
                      let end = GridMath.cell(at: value.location, columns: grid.columns, rows: grid.rows, in: size) else { return }
                if start == end, let zone = grid.zone(at: start) {
                    onPick(zone.cells)
                } else {
                    onPick(CellRect(from: start, to: end))
                }
            }
    }
}

/// Evenly spaced grid lines.
struct GridLines: Shape {
    let columns: Int
    let rows: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard columns > 0, rows > 0 else { return path }
        for c in 1..<max(columns, 1) {
            let x = rect.minX + rect.width * CGFloat(c) / CGFloat(columns)
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        for r in 1..<max(rows, 1) {
            let y = rect.minY + rect.height * CGFloat(r) / CGFloat(rows)
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

/// A zone drawn as a tinted rounded rect with its apps and name.
struct ZoneTile: View {
    let zone: Zone
    var highlighted = false
    var selected = false
    var large = false
    /// An assigned app can't shrink to this zone's size.
    var tooSmall = false

    var body: some View {
        let tint = zone.color.color
        let radius: CGFloat = large ? 12 : 4
        RoundedRectangle(cornerRadius: radius)
            .fill(tint.opacity(highlighted ? 0.6 : (large ? 0.28 : 0.35)))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(selected ? Color.primary : tint.opacity(highlighted ? 1 : 0.8), lineWidth: selected || highlighted ? (large ? 4 : 2) : 1)
            )
            .overlay(label.padding(large ? 12 : 2))
            .overlay(alignment: .topTrailing) {
                if tooSmall {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: large ? 22 : 10))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .yellow)
                        .padding(large ? 10 : 3)
                        .help("Too small for an assigned app's minimum window size")
                }
            }
    }

    @ViewBuilder
    private var label: some View {
        if large {
            VStack(spacing: 10) {
                if !zone.apps.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(zone.apps.prefix(4)) { AppIcon(bundleID: $0.bundleID, size: 48) }
                    }
                }
                Text(zone.displayName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        } else {
            ViewThatFits(in: .vertical) {
                VStack(spacing: 2) {
                    appIcons
                    Text(zone.displayName).font(.system(size: 9, weight: .medium)).lineLimit(1)
                }
                appIcons
                Color.clear
            }
        }
    }

    @ViewBuilder
    private var appIcons: some View {
        if !zone.apps.isEmpty {
            HStack(spacing: 2) {
                ForEach(zone.apps.prefix(3)) { AppIcon(bundleID: $0.bundleID, size: 14) }
            }
        }
    }
}
