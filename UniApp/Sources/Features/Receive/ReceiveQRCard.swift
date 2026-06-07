import SwiftUI

/// The QR card. White-on-white opaque surface (the QR's contrast needs
/// the brightest possible background — Liquid Glass over content layer
/// would refract and dim the modules). The Trust Wallet bundled chain
/// logo overlays the QR's centre at ~14% of the QR size — well inside
/// the H-correction-level recovery budget so the QR remains scannable.
///
/// **Rule #16 honesty.** The card carries the chain name + ticker
/// caption so the user can verify *while scanning* that the QR they're
/// presenting matches the chain they intended.
struct ReceiveQRCard: View {
    let chain: SupportedChain
    /// `nil` for native receives ("Ethereum · ETH" caption). Non-nil
    /// when the user reached this card via the network picker for a
    /// token — "USDC on Base" caption so they can verify *while
    /// scanning* that the QR matches both the token and the network.
    var tokenSymbol: String? = nil
    let address: String

    private var captionText: String {
        if let tokenSymbol {
            return "\(tokenSymbol) on \(chain.displayName)"
        }
        return "\(chain.displayName) · \(chain.ticker)"
    }

    var body: some View {
        VStack(spacing: UniSpacing.m) {
            HStack(spacing: UniSpacing.xs) {
                chainLogo
                    .frame(width: 22, height: 22)
                Text(verbatim: captionText)
                    .font(UniTypography.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(UniColors.Text.primary)
            }

            qrImage
                .overlay(alignment: .center) {
                    centreOverlay
                }
                .frame(maxWidth: 280, maxHeight: 280)
                .accessibilityLabel(Text(accessibilityLabelText))
        }
        .padding(UniSpacing.l)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.hero, style: .continuous)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UniRadius.hero, style: .continuous)
                .stroke(UniColors.Separator.regular, lineWidth: 0.5)
        )
    }

    private var accessibilityLabelText: String {
        if let tokenSymbol {
            return "QR code for \(tokenSymbol) address on \(chain.displayName)"
        }
        return "QR code for \(chain.displayName) address"
    }

    @ViewBuilder
    private var qrImage: some View {
        if let image = QRCodeGenerator.shared.image(for: address) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none) // crisp modules — no smoothing
                .aspectRatio(1, contentMode: .fit)
        } else {
            // Defensive fallback — only reached if the payload string
            // somehow defeats CIFilter (extremely unlikely for a
            // standard address). We never want a blank square here.
            RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                .fill(UniColors.Background.secondary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    UniFootnote(
                        text: "QR unavailable",
                        alignment: .center,
                        color: UniColors.Text.secondary
                    )
                }
        }
    }

    @ViewBuilder
    private var centreOverlay: some View {
        let overlaySize: CGFloat = 56
        ZStack {
            RoundedRectangle(cornerRadius: UniRadius.s, style: .continuous)
                .fill(Color.white)
                .frame(width: overlaySize, height: overlaySize)
            chainLogo
                .frame(width: overlaySize - 14, height: overlaySize - 14)
                .clipShape(RoundedRectangle(cornerRadius: UniRadius.xs, style: .continuous))
        }
    }

    @ViewBuilder
    private var chainLogo: some View {
        if let assetName = chain.logoAssetName {
            Image(assetName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(Circle())
        } else {
            Image(systemName: "circle.dashed")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(UniColors.Icon.tertiary)
        }
    }
}
