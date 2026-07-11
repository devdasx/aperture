import SwiftUI

/// The **Reset Aperture** section — the app's nuclear hatch. Renders the
/// destructive row + its honest footer. The full-screen `ResetApertureFlow`
/// (`design_handoff_reset`) is presented at the APP ROOT (via `ResetFlowGate`),
/// not from this Settings tab — so its erasing→factory-fresh morph survives the
/// wipe (which empties the wallets and would otherwise tear MainTabView, and
/// this screen, down mid-animation).
///
/// A self-contained `View` whose body IS a `Section`, so `SettingsView` embeds
/// it inside its `List` with one line.
struct ResetApertureSection: View {
    var body: some View {
        Section {
            Button {
                ResetFlowGate.shared.isPresenting = true
            } label: {
                HStack(spacing: UniSpacing.s) {
                    SettingsIconTile(
                        systemImage: "trash.fill",
                        tint: .red,
                        compactTint: UniColors.Feedback.Error.foreground
                    )
                    Text("Reset Aperture")
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Feedback.Error.foreground)
                    Spacer()
                }
                .padding(.vertical, UniSpacing.xxs)
                .uniListRowHitTarget()
            }
            .buttonStyle(.uniListRow)
            .listRowBackground(UniColors.List.rowBackground)
        } footer: {
            Text("Deletes every wallet, every encrypted seed, every cached balance, every preference. This cannot be undone — back up any recovery phrases first.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
