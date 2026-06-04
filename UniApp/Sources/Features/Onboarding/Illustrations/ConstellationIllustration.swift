import SwiftUI

/// Beat 2 — One wallet, twenty-four networks.
///
/// Renders Apple's `point.3.connected.trianglepath.dotted` SF Symbol — a
/// real Apple-designed glyph that reads unambiguously as "a network of
/// connected nodes". Per Rule #7 Part B, SF Symbols are first-choice
/// when they cover the need, and this one covers "network" cleanly.
///
/// Earlier passes composed twelve real Trust Wallet PNG marks on two
/// orbital rings around a center disc. The composition was real-assets-
/// only (Rule #7-compliant), but at the slide's render size the marks
/// shrank past the legibility threshold and the result read as a single
/// blue dot. Three nodes connected by dotted lines is the honest visual
/// for "many connected networks" at any size — restraint over abundance
/// (Rule #2 §A.6).
///
/// The Trust Wallet PNGs remain in `Assets.xcassets/Crypto/` for the
/// upcoming wallet/portfolio view that lists per-chain balances; this
/// illustration no longer references them.
///
/// One native `.symbolEffect(.bounce)` when this beat becomes active —
/// matching every other SF-Symbol slide (vault, faceID, swap, …).
struct ConstellationIllustration: View {
    let isActive: Bool

    var body: some View {
        Image(systemName: "point.3.connected.trianglepath.dotted")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.hierarchical)
            .frame(width: 112, height: 112)
            .foregroundStyle(UniColors.Brand.mark)
            .symbolEffect(.bounce, options: .nonRepeating, value: isActive)
    }
}
