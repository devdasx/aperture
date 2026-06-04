import SwiftUI

/// Beat 5 — A 24-word phrase is the only key.
///
/// Renders Apple's `list.number` SF Symbol — a real Apple-designed glyph
/// that reads immediately as "a numbered list of items". Honest: the
/// recovery phrase *is* a numbered list. The glyph says what it is.
///
/// One native `.symbolEffect(.bounce)` when this beat becomes active.
struct RecoveryPhraseIllustration: View {
    let isActive: Bool

    var body: some View {
        Image(systemName: "list.number")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .frame(width: 116, height: 116)
            .foregroundStyle(UniColors.Brand.mark)
            .symbolEffect(.bounce, options: .nonRepeating, value: isActive)
    }
}
