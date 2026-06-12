import SwiftUI

/// Visual primitive that renders a dApp's favicon when one is
/// reachable and a calm letter-chip fallback when it isn't. Used by
/// the Favorites grid, the Recent rows, the Connected rows, the URL
/// bar's leading slot, and the confirmation-sheet hero.
///
/// **Why one primitive.** Every surface that names a dApp answers
/// the same question: "show me their published mark, fall back to
/// their initials if the network is unreachable." Centralising
/// avoids three different fallback shapes drifting across the app.
///
/// **Why a letter chip, not a fabricated logo.** Per Rule #7 §C
/// we never invent a brand mark. A `Capsule` / `RoundedRectangle`
/// containing a single uppercased letter on a tinted system surface
/// is a *structural primitive* (Rule #7 exception): the chip carries
/// the dApp's identity by its first letter, not by an invented logo.
/// This is the same fallback Safari and Chrome use when a favicon
/// 404s.
///
/// **Caching.** SwiftUI's `AsyncImage` caches network responses in
/// `URLCache.shared`. Aperture's default URLSession config installs
/// a 10MB in-memory + 50MB on-disk cache (the iOS default) — first
/// fetch hits the network, second fetch is local. Per Rule #16 §A.5
/// the user's browsing history doesn't get uploaded; favicon
/// fetches are direct GETs to the dApp's host, equivalent to mobile
/// Safari's behavior.
///
/// **Sizes.** Three preset sizes match the call sites:
///   - `.tile` (52pt) — Favorites grid + Connected list row hero.
///   - `.row` (40pt) — Recent list row leading slot.
///   - `.hero` (64pt) — Confirmation-sheet identity hero.
struct BrowserFaviconView: View {
    /// Mark URL to fetch. `nil` means "no source — render the
    /// letter chip immediately."
    let url: URL?

    /// Letter to draw when the favicon fetch fails or no URL was
    /// provided. Caller passes the first letter of the dApp name.
    let fallbackLetter: String

    /// Render size. Drives the SwiftUI frame AND the rounded-corner
    /// curvature so the chip's geometry stays concentric.
    let size: Size

    enum Size {
        case row
        case tile
        case hero

        var dimension: CGFloat {
            switch self {
            case .row:  return 40
            case .tile: return 52
            case .hero: return 64
            }
        }

        /// Rounded-corner radius. Authored against the size: a small
        /// chip uses `UniRadius.control`, the tile uses
        /// `UniRadius.card`, the hero uses `UniRadius.hero`. Apple's
        /// own marketing site uses ~22% of the chip's edge radius;
        /// these tokens land in that neighborhood.
        var cornerRadius: CGFloat {
            switch self {
            case .row:  return UniRadius.s
            case .tile: return UniRadius.m
            case .hero: return UniRadius.l
            }
        }

        /// Letter font for the chip fallback. Scaled so the chip
        /// reads as identity, not as text.
        var letterFont: Font {
            switch self {
            case .row:  return .system(size: 18, weight: .semibold, design: .rounded)
            case .tile: return .system(size: 24, weight: .semibold, design: .rounded)
            case .hero: return .system(size: 30, weight: .semibold, design: .rounded)
            }
        }
    }

    var body: some View {
        ZStack {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        // First-frame placeholder — letter chip
                        // while the network is in flight. Reads as
                        // a calm wait, not as "broken".
                        letterChip
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size.dimension, height: size.dimension)
                            .clipShape(RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous))
                    case .failure:
                        // 404 / DNS / TLS — the chip stays.
                        letterChip
                    @unknown default:
                        letterChip
                    }
                }
            } else {
                letterChip
            }
        }
        .frame(width: size.dimension, height: size.dimension)
        .background(
            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                .fill(UniColors.Background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                .strokeBorder(UniColors.Separator.regular, lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }

    /// Letter chip fallback — a single uppercased letter on the
    /// secondary background surface, tinted with the primary text
    /// role so it reads as identity (not as decoration).
    private var letterChip: some View {
        Text(verbatim: fallbackLetter.first.map { String($0).uppercased() } ?? "?")
            .font(size.letterFont)
            .foregroundStyle(UniColors.Text.primary)
            .frame(width: size.dimension, height: size.dimension)
    }
}
