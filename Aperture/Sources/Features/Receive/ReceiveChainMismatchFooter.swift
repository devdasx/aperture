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
                .foregroundStyle(UniColors.Feedback.Warning.foreground)
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
            .buttonStyle(.uniTactile)
            .accessibilityLabel(Text("What's a receive address?"))
        }
        .padding(UniSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Feedback.Warning.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .stroke(UniColors.Feedback.Warning.stroke, lineWidth: 0.5)
        )
    }

    /// Localized via catalog key `"Only send %@ on the %@ network…"` and
    /// the in-app language bundle. Runtime asset/chain names are injected
    /// with `String(format:)` — never Swift string interpolation into
    /// `String(localized:)`, which builds one-off untranslated keys and
    /// also ignores Aperture's selected language.
    private var warningText: String {
        let format = String.apertureLocalized(
            "Only send %@ on the %@ network to this address. Sending any other token, or using a different network, may result in permanent loss."
        )
        let asset = tokenSymbol ?? chain.displayName
        return String(
            format: format,
            locale: ApertureLocalization.currentLocale,
            asset,
            chain.displayName
        )
    }
}
