import SwiftUI

/// The 1inch-style **Actions** bottom sheet (2026-06-23 user direction) — the
/// home's Send / Receive circles moved here, as a grid of label-+-corner-icon
/// cells separated by hairlines. Below the grid sits the **Templates** section
/// (saved Send blueprints — the real feature lands in a later phase; for now
/// it shows the empty state).
///
/// The sheet owns no flows: each tile calls back to `WalletHomeView`, which
/// dismisses this sheet and presents the matching Send / Receive surface
/// (the dismiss-then-present hand-off).
struct WalletActionsSheet: View {
    let canSend: Bool
    let onSend: () -> Void
    let onReceive: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Actions")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(UniColors.Text.primary)
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.l)
                .padding(.bottom, UniSpacing.m)

            grid

            templatesSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UniColors.Background.primary)
    }

    // MARK: Action grid

    private var grid: some View {
        VStack(spacing: 0) {
            UniDivider()
            HStack(spacing: 0) {
                cell("Receive", systemImage: "arrow.down.left", enabled: true, action: onReceive)
                vHair
                cell("Send", systemImage: "arrow.up.right", enabled: canSend, action: onSend)
            }
            UniDivider()
        }
    }

    private var vHair: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(width: 0.5)
    }

    private func cell(
        _ title: LocalizedStringKey,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(UniColors.Text.primary)
                }
                Spacer(minLength: UniSpacing.l)
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(UniColors.Text.primary)
            }
            .padding(UniSpacing.l)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    // MARK: Templates (empty state — full feature is a later phase)

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            Text("Templates")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(UniColors.Text.secondary)
                .padding(.top, UniSpacing.l)

            Text("Save a Send to reuse its recipient, token, and amount in one tap. Your saved templates will appear here.")
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(UniColors.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, UniSpacing.l)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, UniSpacing.l)
    }
}
