import SwiftUI

/// Beat 4 — Locked by Face ID.
///
/// Renders Apple's `faceid` SF Symbol — this **is** Apple's authentic Face ID
/// glyph. Per Rule #7 Part B, when an authentic Apple glyph exists for an
/// Apple platform feature, that glyph is the visual. No corner ticks, no
/// inner face drawn from primitives — the real symbol carries the meaning.
///
/// One native `.symbolEffect(.bounce)` when this beat becomes active.
struct FaceIDIllustration: View {
    let isActive: Bool

    var body: some View {
        Image(systemName: "faceid")
            .resizable()
            .scaledToFit()
            .frame(width: 120, height: 120)
            .foregroundStyle(UniColors.Brand.mark)
            .symbolEffect(.bounce, options: .nonRepeating, value: isActive)
    }
}
