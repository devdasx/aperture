import SwiftUI

/// Rule #18 guide sheet — "What's a receive address?". Presented from
/// the info button on the chain-mismatch footer (and from the toolbar
/// `info.circle` of `ReceiveView`). Mirrors `RecoveryPhraseGuideSheet`
/// in shape: hero SF Symbol, the four canonical paragraphs
/// (what it is, what it looks like, how you use it, what Aperture
/// does with it), single `UniButton(.primary)` "Got it".
struct ReceiveGuideSheet: View {
    let chain: SupportedChain
    /// `nil` for a native-receive guide; non-nil when the user is
    /// receiving a token and the body should name the token/network
    /// distinction explicitly.
    var tokenSymbol: String? = nil
    let onDismiss: () -> Void

    var body: some View {
        UniSheet(title: "What's a receive address?") {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero
                explainerBody
                exampleBlock
                howToUse
                apertureRole
            }
        } actions: {
            UniButton(title: "Got it", variant: .primary) {
                onDismiss()
            }
        }
    }

    private var hero: some View {
        HStack {
            Spacer()
            Image(systemName: "qrcode")
                .font(.system(size: 44, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Brand.mark)
                .symbolEffect(.bounce, options: .nonRepeating)
                .accessibilityHidden(true)
            Spacer()
        }
    }

    private var explainerBody: some View {
        UniBody(
            text: "A receive address is a string that identifies one of your accounts on one specific chain. Sharing it lets someone send funds to that account.",
            color: UniColors.Text.primary
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var exampleBlock: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            UniCaption(
                text: "Example only — never send funds to this.",
                color: UniColors.Text.tertiary
            )
            .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: chain.exampleAddressPreview)
                .font(UniTypography.subheadline.monospaced())
                .foregroundStyle(UniColors.Text.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(UniSpacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                        .fill(UniColors.Background.secondary)
                )
        }
    }

    @ViewBuilder
    private var howToUse: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            UniBody(
                text: "Share the address as text, or let the sender scan the QR code. They look different but they carry the same information.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
            if tokenSymbol != nil {
                UniBody(
                    text: "On EVM and Solana, the address is the same whether you're receiving the native asset or a token — the network you pick determines what's accepted. The sender must use the same network.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)
            } else {
                UniBody(
                    text: "Addresses are chain-specific. An address for one chain cannot receive funds from another — sending across chains is the most common way people lose money.",
                    color: UniColors.Text.secondary
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var apertureRole: some View {
        UniBody(
            text: "Aperture derives this address from your wallet on this iPhone. Nothing is uploaded — the same address would appear if you were offline.",
            color: UniColors.Text.secondary
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}
