import SwiftUI

/// Beat 7 — Send with the real fee shown.
///
/// Apple's `paperplane.fill` SF Symbol paired with a real ETH mark and a
/// typographic fee ticket. The plane is the verb (outgoing). The number
/// (`fee 0.0001`) is the message — typography is design, and a typeset
/// numeric label is not an icon (Rule #7 Part C).
///
/// One native `.symbolEffect(.bounce)` on the paperplane when this beat
/// becomes active. The ETH PNG is a static brand mark; the fee capsule
/// is a structural surface — both render without animation.
struct SendIllustration: View {
    let isActive: Bool

    var body: some View {
        VStack(spacing: UniSpacing.m) {
            HStack(spacing: UniSpacing.m) {
                Image(systemName: "paperplane.fill")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 80, height: 80)
                    .foregroundStyle(UniColors.Brand.mark)
                    .symbolEffect(.bounce, options: .nonRepeating, value: isActive)

                Image("eth")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
            }

            // Typographic fee ticket — type is design, not iconography.
            Capsule(style: .continuous)
                .fill(UniColors.Illustration.surfaceDeep)
                .frame(width: 96, height: 26)
                .overlay(
                    Text("fee 0.0001")
                        .font(.system(.footnote, design: .monospaced, weight: .medium))
                        .foregroundStyle(UniColors.Text.secondary)
                )
        }
    }
}
