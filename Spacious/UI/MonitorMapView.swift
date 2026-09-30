import SwiftUI
import SpaciousCore

/// All connected monitors drawn in their real physical arrangement. Click a
/// monitor to edit its grid.
struct MonitorMapView: View {
    let model: AppModel
    var maxSize = CGSize(width: 368, height: 130)

    var body: some View {
        let displays = model.displays
        let bounds = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        if bounds.isNull || displays.isEmpty {
            Text("No displays found").foregroundStyle(.secondary)
        } else {
            let scale = min(maxSize.width / bounds.width, maxSize.height / bounds.height)
            ZStack(alignment: .topLeading) {
                ForEach(displays) { display in
                    let rect = CGRect(
                        x: (display.frame.minX - bounds.minX) * scale,
                        y: (bounds.maxY - display.frame.maxY) * scale, // Cocoa y-up → view y-down
                        width: display.frame.width * scale,
                        height: display.frame.height * scale
                    ).insetBy(dx: 2, dy: 2)
                    MonitorThumbnail(
                        display: display,
                        grid: model.grid(for: display.id),
                        selected: display.id == model.selectedDisplayID
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .onTapGesture {
                        model.selectedDisplayID = display.id
                        model.selectedZoneID = nil
                    }
                    .help("\(display.name) · \(display.sizeDescription)")
                }
            }
            .frame(width: bounds.width * scale, height: bounds.height * scale, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct MonitorThumbnail: View {
    let display: DisplayInfo
    let grid: MonitorGrid?
    let selected: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                if let grid {
                    ForEach(grid.zones) { zone in
                        let r = GridMath.frame(for: zone.cells, columns: grid.columns, rows: grid.rows, in: geo.size, gap: 3)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(zone.color.color.opacity(0.55))
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                    }
                }
                Text(display.name)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.thinMaterial, in: Capsule())
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: selected ? 2.5 : 1)
        )
        .contentShape(Rectangle())
    }
}
