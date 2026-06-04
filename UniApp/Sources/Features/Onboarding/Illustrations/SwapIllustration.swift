import SwiftUI

/// Beat 8 — Swap across chains in one flow.
///
/// Apple's `arrow.left.arrow.right` SF Symbol flanked by two real coin marks
/// (ETH ↔ USDC). The arrows carry the verb; the marks anchor the metaphor
/// in real chains. All three visuals are authored — by Apple, and by
/// Trust Wallet (MIT) for the two coin marks.
///
/// One native `.symbolEffect(.bounce)` on the arrows when this beat becomes
/// active. The ETH / USDC PNGs are static brand marks (no `.symbolEffect`
/// because they're not SF Symbols).
struct SwapIllustration: View {
    let isActive: Bool

    var body: some View {
        HStack(spacing: UniSpacing.m) {
            Image("eth")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)

            Image(systemName: "arrow.left.arrow.right")
                .resizable()
                .scaledToFit()
                .symbolRenderingMode(.hierarchical)
                .frame(width: 56, height: 56)
                .foregroundStyle(UniColors.Brand.mark)
                .symbolEffect(.bounce, options: .nonRepeating, value: isActive)

            Image("usdc")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
        }
    }
}
