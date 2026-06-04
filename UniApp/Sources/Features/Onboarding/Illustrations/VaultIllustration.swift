import SwiftUI

/// Beat 3 — Self-custody. Your keys never leave your iPhone.
///
/// Renders Apple's `key.fill` SF Symbol — a real Apple-designed glyph that
/// reads unambiguously as "key". Per Rule #7 Part B, SF Symbols are
/// first-choice when they cover the need.
///
/// One native `.symbolEffect(.bounce)` when this beat becomes active.
struct VaultIllustration: View {
    let isActive: Bool

    var body: some View {
        Image(systemName: "key.fill")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .frame(width: 112, height: 112)
            .foregroundStyle(UniColors.Brand.mark)
            .symbolEffect(.bounce, options: .nonRepeating, value: isActive)
    }
}
