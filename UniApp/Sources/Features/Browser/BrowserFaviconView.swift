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
/// **Caching — the SAME path coins/tokens use (2026-06-18).** Favicons
/// resolve through `CoinMarkImageCache.resolveImage(for:)`, the one
/// fetch→cache→persist→decode path that `CoinMark` uses for token/coin
/// marks. So a dApp logo caches and persists exactly the way a token icon
/// does: downloaded once, written to the durable Application Support disk
/// cache (`CoinMarkCache`, never evicted under disk pressure — unlike the
/// old `AsyncImage`/`URLCache.shared` path), decoded off-main, and held as
/// a ready bitmap in the session image cache so re-appearing rows (Favorites
/// grid, Recent/Connected lists) paint synchronously with no re-download and
/// no re-decode. Misses are negative-cached so scrolling a list never
/// re-fires a request per missing favicon on every row reappearance.
///
/// **Privacy is unchanged.** This view fetches whatever URL the call site
/// hands it — and the call sites already encode Aperture's stance: the
/// user's own browsing history / connected sessions use the site's *own*
/// `https://<host>/favicon.ico`, never a third-party favicon service that
/// would learn every host the user visits; only the curated public dApp
/// directory uses a shared favicon endpoint. Routing those same URLs
/// through the durable cache changes only WHERE bytes are stored, not WHO
/// they're requested from. Per Rule #16 §A.5 the user's browsing history is
/// never uploaded.
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

    /// Bundled asset name (`dapp-<id>`) to prefer over the network favicon
    /// (2026-06-17). The curated Favorites ship their logos in the asset
    /// catalog, so they're ALWAYS visible — instant, offline, and immune to
    /// the SVG/`.ico` decode failures that `AsyncImage` hits on some dApp
    /// favicons. `nil` (recents, connected, arbitrary dApps) → network favicon.
    var assetName: String? = nil

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

    /// Decoded, display-ready favicon resolved for `url`. Stays `nil`
    /// until the durable cache / network produces an image; the letter
    /// chip shows meanwhile. Mirrors `CoinMark`'s `prepared` field.
    @State private var resolved: UIImage?

    var body: some View {
        // Synchronous session-cache hit → paint immediately with no `.task`
        // work and no re-decode, exactly like `CoinMark.networkMark`. A
        // re-appearing list row whose favicon was decoded earlier this
        // session repaints instantly here.
        let cached = url.flatMap { CoinMarkImageCache.shared.image(for: $0) }
        return ZStack {
            if let assetName, UIImage(named: assetName) != nil {
                // Bundled curated logo — always present, no network, no
                // SVG/.ico decode risk.
                Image(assetName)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.dimension, height: size.dimension)
                    .clipShape(RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous))
            } else if let image = resolved ?? cached {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.dimension, height: size.dimension)
                    .clipShape(RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous))
            } else {
                // No source, fetch in flight, 404 / DNS / TLS, or
                // undecodable bytes (e.g. an SVG favicon) — the chip stays.
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
        .task(id: url) {
            // Drop any image resolved for a previous `url` so a recycled
            // list row never shows the prior dApp's logo.
            resolved = nil
            // Bundled curated logo wins — no network needed.
            if let assetName, UIImage(named: assetName) != nil { return }
            guard let url else { return }
            // Already decoded this session → the synchronous `cached` read
            // above paints it; nothing to do.
            if CoinMarkImageCache.shared.image(for: url) != nil { return }
            resolved = await CoinMarkImageCache.shared.resolveImage(for: url)
        }
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
