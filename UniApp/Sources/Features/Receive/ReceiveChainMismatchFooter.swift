import SwiftUI

/// The footer paragraph that names the chain explicitly and warns
/// against cross-network sends. The most consequential safety
/// affordance on the screen, designed per Rule #16 §B as a calm,
/// factual surface — `Status.warningForeground` on the lock icon,
/// secondary text on the body, no alarming red, no exclamation marks.
///
/// The user hears the truth once, plainly: "Only send <CHAIN> on the
/// <CHAIN> network to this address. Sending anything else may result
/// in permanent loss." Rule #2 §A.7 + Rule #16 §A.6.
struct ReceiveChainMismatchFooter: View {
    let chain: SupportedChain
    /// `nil` for a native-receive footer; non-nil names the token
    /// being received so the warning reads "Only send USDC on the
    /// Base network…" instead of "Only send Base on the Base
    /// network…".
    var tokenSymbol: String? = nil
    let onInfoTapped: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(UniColors.Status.warningForeground)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xs) {
                Text(warningText)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                onInfoTapped()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(UniColors.Text.link)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("What's a receive address?"))
        }
        .padding(UniSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Status.warningBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .stroke(UniColors.Status.warningStroke, lineWidth: 0.5)
        )
    }

    /// Interpolated runtime string — kept as `Text(verbatim:)` so the
    /// chain name (which is itself English-only in this app) isn't
    /// re-translated mid-sentence. The boilerplate around it stays in
    /// the catalog via `String(localized:)` so the i18n loop
    /// (Rule #20) closes the 50 languages.
    private var warningText: String {
        if let tokenSymbol {
            return String(
                localized: "Only send \(tokenSymbol) on the \(chain.displayName) network to this address. Sending any other token, or using a different network, may result in permanent loss."
            )
        }
        return String(
            localized: "Only send \(chain.displayName) on the \(chain.displayName) network to this address. Sending any other token, or using a different network, may result in permanent loss."
        )
    }
}
