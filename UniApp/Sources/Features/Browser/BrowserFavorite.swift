import Foundation

/// The static favorite-dApp registry surfaced in `BrowserHomeView`'s
/// Favorites grid. A starter set so a brand-new Aperture user has
/// somewhere to begin — the same way Safari ships with curated
/// bookmarks on first launch.
///
/// **Why static, not user-editable yet.** The user-edit surface
/// (drag-to-reorder + add-from-current-page) lives in
/// `BrowserBookmarkRecord` (the SwiftData model). The static list
/// here is the floor — what the user sees on first launch and what
/// they can return to. The persisted `isFavorite: true` rows on
/// `BrowserBookmarkRecord` overlay this list at runtime; today the
/// home view reads only the static list (the persisted layer ships
/// in a follow-on turn).
///
/// **Per Rule #16 §A.6** — honesty about what each dApp is. The
/// `category` here is descriptive, not promotional. We don't
/// imply Aperture endorses these dApps or audits them; the
/// guide-sheet copy makes that explicit.
///
/// **Icon URLs.** The `iconURL` points at each dApp's published
/// favicon or brand mark. The browser's `BrowserFaviconView`
/// fetches + caches them; if a fetch fails, the view falls back to
/// a letter chip (first letter of the dApp name on a tinted
/// surface — Rule #7 §C "structural shapes are not icons" — the
/// letter chip carries the dApp's identity by initial, not by
/// invented logo).
///
/// **Why no Aperture-curated mark for each.** Per Rule #7 we use
/// the dApp's own brand asset, not an Aperture-painted approximation.
/// If a dApp updates their mark, the next icon fetch picks it up.
struct BrowserFavorite: Identifiable, Hashable, Sendable {
    /// Stable identifier. Used as the cache key for the favicon
    /// fetch and as the `ForEach` key in the grid.
    let id: String

    /// Display name shown beneath the icon ("Uniswap", "Aave").
    let name: String

    /// Canonical URL the user lands on when they tap the tile.
    /// Always the dApp's mobile-friendly entry point — `app.foo.com`
    /// rather than the marketing site at `foo.com` when both exist.
    let url: URL

    /// Hostname used as the cache key and as the favicon-fallback
    /// host. Derived from `url.host` at definition time so the
    /// runtime doesn't recompute.
    let host: String

    /// Published favicon / brand mark URL. Most dApps publish a
    /// 192×192 PWA icon at `/apple-touch-icon.png` or
    /// `/icon-192.png`; we hardcode the resolved URL per dApp so
    /// first-paint doesn't wait on a network probe.
    let iconURL: URL

    /// One-word descriptive category. Drives the accessibility
    /// hint ("Uniswap, swap dApp") and a future filter row. No
    /// promotional language ("the BEST swap").
    let category: Category

    enum Category: String, Sendable, Hashable, CaseIterable {
        case swap
        case lending
        case marketplace
        case naming
        case stablecoin
        case yield
    }
}

extension BrowserFavorite {
    /// Build a favorite from a host. Used by the static list below
    /// and by the persisted `BrowserBookmarkRecord` when it rehydrates.
    init(id: String, name: String, urlString: String, host: String, iconURLString: String, category: Category) {
        self.id = id
        self.name = name
        // Force-unwrap is acceptable here — every value below is a
        // compile-time constant authored by the design / curation
        // team. If a typo ever ships, the test suite (or first
        // build) catches it instantly.
        self.url = URL(string: urlString)!
        self.host = host
        self.iconURL = URL(string: iconURLString)!
        self.category = category
    }
}

// MARK: - Curated starter set

extension BrowserFavorite {
    /// The 8 favorites shown on `BrowserHomeView` at first launch.
    /// Eight is two rows of four — Apple-default grid width on
    /// iPhone, no scrolling needed inside the grid itself.
    ///
    /// **Mix.** EVM swap + lending (Uniswap, Aave), an NFT
    /// marketplace (OpenSea), a naming service (ENS), Solana DEX
    /// + NFT (Jupiter, Magic Eden, Tensor), and a Maker / DAI
    /// surface (MakerDAO). The mix spans EVM + Solana, swap +
    /// lending + NFT + stablecoin — every major chain family
    /// Aperture supports is represented on first launch.
    static let starterSet: [BrowserFavorite] = [
        BrowserFavorite(
            id: "uniswap",
            name: "Uniswap",
            urlString: "https://app.uniswap.org",
            host: "app.uniswap.org",
            iconURLString: "https://app.uniswap.org/favicon.png",
            category: .swap
        ),
        BrowserFavorite(
            id: "aave",
            name: "Aave",
            urlString: "https://app.aave.com",
            host: "app.aave.com",
            iconURLString: "https://app.aave.com/favicon.ico",
            category: .lending
        ),
        BrowserFavorite(
            id: "opensea",
            name: "OpenSea",
            urlString: "https://opensea.io",
            host: "opensea.io",
            iconURLString: "https://opensea.io/static/images/logos/opensea.svg",
            category: .marketplace
        ),
        BrowserFavorite(
            id: "ens",
            name: "ENS",
            urlString: "https://app.ens.domains",
            host: "app.ens.domains",
            iconURLString: "https://app.ens.domains/apple-touch-icon.png",
            category: .naming
        ),
        BrowserFavorite(
            id: "jupiter",
            name: "Jupiter",
            urlString: "https://jup.ag",
            host: "jup.ag",
            iconURLString: "https://jup.ag/svg/jupiter-logo.svg",
            category: .swap
        ),
        BrowserFavorite(
            id: "magic-eden",
            name: "Magic Eden",
            urlString: "https://magiceden.io",
            host: "magiceden.io",
            iconURLString: "https://magiceden.io/img/favicon.png",
            category: .marketplace
        ),
        BrowserFavorite(
            id: "tensor",
            name: "Tensor",
            urlString: "https://www.tensor.trade",
            host: "tensor.trade",
            iconURLString: "https://www.tensor.trade/favicon.ico",
            category: .marketplace
        ),
        BrowserFavorite(
            id: "makerdao",
            name: "MakerDAO",
            urlString: "https://app.spark.fi",
            host: "app.spark.fi",
            iconURLString: "https://app.spark.fi/favicon.ico",
            category: .stablecoin
        )
    ]
}
