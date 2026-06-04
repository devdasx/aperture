import SwiftUI

/// Beat 6 — Receive on every chain.
///
/// Apple's `arrow.down.to.line` SF Symbol paired with a real USDC mark from
/// `Assets.xcassets/Crypto/`. The arrow is the verb (incoming), the coin
/// anchors the metaphor in a real chain. Both visuals are authored — the
/// arrow by Apple, the USDC mark by Trust Wallet (MIT).
///
/// One native `.symbolEffect(.bounce)` on the SF Symbol when this beat
/// becomes active. The USDC PNG is a static brand mark — no
/// `.symbolEffect` because it's not an SF Symbol.
struct ReceiveIllustration: View {
    let isActive: Bool

    var body: some View {
        VStack(spacing: UniSpacing.m) {
            Image(systemName: "arrow.down.to.line")
                .resizable()
                .scaledToFit()
                .symbolRenderingMode(.hierarchical)
                .frame(width: 88, height: 88)
                .foregroundStyle(UniColors.Brand.mark)
                .symbolEffect(.bounce, options: .nonRepeating, value: isActive)

            Image("usdc")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
        }
    }
}
