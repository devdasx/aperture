import SwiftUI

/// Amount label that cross-fades between a visible value and privacy dots
/// with the same snappy motion as the wallet-home balance hero.
///
/// Pass `isHidden` from the caller (not only environment) so `.equatable()`
/// rows can still update when privacy toggles if `isHidden` is part of `==`.
struct PrivacySensitiveAmount: View {
    let text: String
    var hiddenText: String = WalletFormatting.hiddenAmount
    let font: Font
    let color: Color
    let isHidden: Bool
    var alignment: Alignment = .trailing

    var body: some View {
        ZStack(alignment: alignment) {
            Text(verbatim: text)
                .opacity(isHidden ? 0 : 1)
                .scaleEffect(isHidden ? 0.96 : 1)
                .blur(radius: isHidden ? 3 : 0)
                .accessibilityHidden(isHidden)

            Text(verbatim: hiddenText)
                .opacity(isHidden ? 1 : 0)
                .scaleEffect(isHidden ? 1 : 0.96)
                .blur(radius: isHidden ? 0 : 3)
                .accessibilityHidden(!isHidden)
        }
        .font(font)
        .foregroundStyle(color)
        .monospacedDigit()
        .lineLimit(1)
        .animation(.snappy(duration: 0.35), value: isHidden)
    }
}
