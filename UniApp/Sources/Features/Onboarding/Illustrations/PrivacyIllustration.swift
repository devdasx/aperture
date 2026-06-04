import SwiftUI

/// Beat 9 — Aperture can't see your funds.
///
/// Renders Apple's `eye.slash.fill` SF Symbol — the most direct visual
/// representation of "we cannot see". Per Rule #7 Part B, when an Apple
/// glyph carries the meaning precisely, that glyph is the visual.
///
/// One native `.symbolEffect(.bounce)` when this beat becomes active.
struct PrivacyIllustration: View {
    let isActive: Bool

    var body: some View {
        Image(systemName: "eye.slash.fill")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .frame(width: 116, height: 116)
            .foregroundStyle(UniColors.Brand.mark)
            .symbolEffect(.bounce, options: .nonRepeating, value: isActive)
    }
}
