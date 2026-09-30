import SwiftUI

/// Shown in the menu until Accessibility access is granted. Moving other
/// apps' windows is impossible without it, so this explains why it's needed
/// and gets the user to the right switch in one click.
struct PermissionBanner: View {
    let model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("One quick step").font(.headline)
                Text("Spacious needs **Accessibility** access to move your windows. Turn on Spacious in System Settings → Privacy & Security → Accessibility.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open System Settings") { model.requestAccessibility() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
