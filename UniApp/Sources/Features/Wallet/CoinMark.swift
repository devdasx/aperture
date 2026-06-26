import SwiftUI
import ImageIO

/// Resolves a `(chain, tokenSymbol, contract)` triple to a coin
/// mark and renders it at the caller's frame.
///
/// **Trust Wallet ONLY (2026-06-15 user direction).**
/// > *"we'll use only trust wallet icons, we'll never use any other
/// > icons for coins & tokens."*
/// Every coin and token mark resolves from Trust Wallet's production
/// asset CDN (`assets-cdn.trustwallet.com`, built from the MIT
/// `trustwallet/assets` repo — Rule #7 §B priority 1) via
/// `CoinMarkCache.shared` — native coins from
/// `…/blockchains/<slug>/info/logo.png`, tokens from
/// `…/blockchains/<slug>/assets/<contract>/logo.png`. There is
/// no bundled-asset path anymore (the old tiers 1+2 — `chain.logoAssetName`
/// and the bundled USDC/USDT marks — were removed so the source is a
/// single, consistent one). Marks are cached to disk on first download;
/// every subsequent render reads from cache with no network call, so the
/// network is hit at most ONCE per mark across the device's lifetime.
///
/// **Honest fallback.** When Trust Wallet hosts nothing for the
/// triple (a contract-less long-tail token, or a chain/contract the
/// repo doesn't carry), the view shows a neutral initials chip —
/// Rule #2 §A.7 "don't lie about a missing asset." Never a different
/// icon source.
///
/// **Layout.** Sizes itself to the caller's `.frame(...)`
/// modifier. Internally circle-clipped so brand-rectangular
/// assets render as disks alongside SF Symbols.
struct CoinMark: View {
    let chain: SupportedChain
    let tokenSymbol: String
    /// Optional contract address — when present, used to resolve
    /// the Trust Wallet mark via `CoinMarkCache.trustWalletURL`.
    /// Callers that know the contract (every `TokenSupportedRow` in
    /// `AllSupportedAssetsView`, every `TokenHoldingRow`) pass it
    /// through; callers that don't (most `ActivityRow` consumers,
    /// where the tx record may not carry the contract) pass nil and
    /// the view falls back to tier 4.
    var contract: String? = nil

    /// Optional override URL for the token mark. Set when the row
    /// is a **custom token** (`CustomTokenRecord.iconURL`) whose
    /// add-time Trust Wallet probe found a real asset. When non-nil,
    /// takes priority over the contract-derived Trust Wallet URL —
    /// the custom-token row may have come from a chain Trust Wallet
    /// doesn't host an asset for, in which case the URL string is
    /// nil and the view falls back to the same network path as
    /// registry tokens.
    var customIconURL: String? = nil

    // **2026-06-09 perf.** Store the pre-decoded `UIImage` instead
    // of raw `Data`. `UIImage(data:)` is lazy — the actual pixel
    // decode happens during render, on the main thread, during
    // scroll. With ~400 token rows that can be 400 main-thread
    // decodes per scroll session. Decoding off-main + caching the
    // already-decoded UIImage gives `Image(uiImage:)` a free render.
    @State private var prepared: PreparedMark?

    var body: some View {
        // A native coin's logo is BUNDLED in the asset catalog
        // (`coin-<slug>`, fetched from Trust Wallet at build time) — render
        // it instantly, with no network, no first-launch flash, and no risk
        // of cache eviction blanking it (user direction 2026-06-17). Tokens
        // (which are open-ended) keep the network + persistent-disk path.
        if let bundled = bundledNativeAssetName {
            Image(bundled)
                .resizable()
                // `.fill`, not `.fit` (2026-06-19, learned from the Stabro
                // build) — Trust Wallet marks ship with transparent padding
                // (e.g. the Base blue square sits small in its canvas).
                // `.fit` left that padding so the mark floated tiny inside
                // the circle; `.fill` scales it to cover, so the logo fills
                // the disc exactly as Trust Wallet's app renders it. The
                // `.clipShape(Circle())` crops the overflow.
                .scaledToFill()
                .clipShape(Circle())
        } else {
            networkMark
        }
    }

    /// The network/cache-backed mark — Trust Wallet fetch, decoded off-main,
    /// cached to durable disk, initials chip until it lands.
    private var networkMark: some View {
        // Resolve the Trust Wallet / custom URL ONCE per body pass —
        // it doubles as the `.task(id:)` rebuild key AND the fetch
        // target, so the derivation never runs twice for one render.
        let url = resolvedURL
        // Synchronous decoded-image cache hit → paint immediately with NO
        // `.task`, no actor hop, no re-decode. `prepared` covers the in-flight
        // first load on THIS instance; the shared cache covers every later
        // render of the same mark this session (so scrolling re-uses pixels
        // instead of re-rendering each time).
        let preparedImage = prepared?.url == url ? prepared?.image : nil
        let cached = url.flatMap { CoinMarkImageCache.shared.image(for: $0) }
        return Group {
            if let image = preparedImage ?? cached {
                Image(uiImage: image)
                    .resizable()
                    // `.fill` so padded Trust Wallet marks cover the disc
                    // (see the bundled-native branch above) — matches the
                    // Trust Wallet app's rendering. Circle-clipped to crop.
                    .scaledToFill()
                    .clipShape(Circle())
            } else {
                initialsChip
            }
        }
        .task(id: url) {
            // Already decoded this session → nothing to do; the cache paints it.
            if let url, let image = CoinMarkImageCache.shared.image(for: url) {
                prepared = PreparedMark(url: url, image: image)
                return
            }
            await loadFromCache(url: url)
        }
    }

    /// Bundled native-coin asset name (`coin-<slug>`) when one exists in the
    /// catalog for this chain's Trust Wallet slug; `nil` for tokens or any
    /// chain whose logo wasn't bundled.
    private var bundledNativeAssetName: String? {
        guard isNativeCoin, let slug = CoinMarkCache.trustWalletChainSlug(for: chain) else { return nil }
        let name = "coin-\(slug)"
        return UIImage(named: name) != nil ? name : nil
    }

    // MARK: - Trust Wallet mark URL

    /// Whether this triple is a native coin (its own ticker, no
    /// contract) — resolved from Trust Wallet's `info/logo.png`.
    private var isNativeCoin: Bool {
        contract == nil && tokenSymbol.uppercased() == chain.ticker.uppercased()
    }

    /// Resolved mark URL — computed once in `body` and reused as both
    /// the `.task(id:)` rebuild key and the fetch target. Trust Wallet
    /// only: `customIconURL` (custom-token rows, itself a Trust Wallet
    /// probe result) → native `info/logo.png` → token
    /// `assets/<contract>/logo.png`. A token with no contract has no
    /// addressable Trust Wallet mark, so the view shows the initials
    /// chip rather than mis-resolving to the chain's native logo.
    private var resolvedURL: URL? {
        if let custom = customIconURL, !custom.isEmpty {
            return URL(string: custom)
        }
        if isNativeCoin {
            return CoinMarkCache.trustWalletURL(chain: chain, contract: nil)
        }
        if let contract, !contract.isEmpty {
            return CoinMarkCache.trustWalletURL(chain: chain, contract: contract)
        }
        return nil
    }

    /// Symbol-level canonical fallback mark (2026-06-17). Trust Wallet
    /// hosts a logo for many fungible tokens only on their canonical
    /// chain (almost always Ethereum) — e.g. FRAX, EURC, and FDUSD live
    /// on BNB / Polygon / Avalanche / Solana in our registries, but the
    /// `trustwallet/assets` repo only carries the Ethereum asset for
    /// them. When the exact `(chain, contract)` mark 404s, the same
    /// token's Ethereum logo is the honest brand mark to show — it IS
    /// that token, just on another network. Native coins and custom-icon
    /// rows (which already carry their own resolved URL) are exempt.
    private var fallbackURL: URL? {
        guard !isNativeCoin, (customIconURL ?? "").isEmpty else { return nil }
        return CoinMarkCache.symbolFallbackURL(symbol: tokenSymbol, excluding: chain)
    }

    /// Two-stage load: the exact Trust Wallet mark first, then — only if
    /// that's missing or undecodable — the symbol's canonical
    /// (`fallbackURL`) mark. The fallback is computed lazily here, so the
    /// ~99% of rows whose primary mark resolves never pay for it.
    private func loadFromCache(url: URL?) async {
        if let image = await preparedImage(for: url) {
            if let url { CoinMarkImageCache.shared.store(image, for: url) }
            await MainActor.run {
                if let url {
                    self.prepared = PreparedMark(url: url, image: image)
                }
            }
            return
        }
        let fallback = fallbackURL
        guard let fallback, fallback != url,
              let image = await preparedImage(for: fallback) else { return }
        // Cache under BOTH the fallback AND the primary url, so a later render
        // keyed on the primary url still hits the synchronous cache.
        CoinMarkImageCache.shared.store(image, for: fallback)
        if let url { CoinMarkImageCache.shared.store(image, for: url) }
        await MainActor.run {
            self.prepared = PreparedMark(url: url ?? fallback, image: image)
        }
    }

    /// Fetch + decode a single mark URL off-main, or `nil` when the URL
    /// is absent, the download 404s, or the bytes don't decode. Delegates
    /// to `CoinMarkImageCache.resolveImage(for:)` — the one shared
    /// fetch→cache→persist→decode path used by coin/token marks.
    private func preparedImage(for url: URL?) async -> UIImage? {
        guard let url else { return nil }
        return await CoinMarkImageCache.shared.resolveImage(for: url)
    }

    // MARK: - Tier 4: initials chip

    private var initialsChip: some View {
        Circle()
            .fill(UniColors.Material.card)
            .overlay {
                Text(initials)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 2)
            }
    }

    private var initials: String {
        let trimmed = tokenSymbol.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "—" }
        return String(trimmed.prefix(3)).uppercased()
    }

    private struct PreparedMark {
        let url: URL
        let image: UIImage
    }
}

// MARK: - Decoded-image cache (native, session-wide)

/// Process-wide cache of DECODED, display-ready coin marks keyed by source
/// URL.
///
/// **Why (2026-06-18, user direction "cache icons once, no re-render each
/// time").** The on-disk `CoinMarkCache` already persists the PNG *bytes*
/// across launches (download-once). But SwiftUI re-creates each `CoinMark`'s
/// `.task` on every lazy row reappearance, so scrolling a list re-ran the
/// actor hop + image decode for marks it had already shown. This caches the
/// DECODED `UIImage` (the expensive, display-ready bitmap) for the whole
/// session: once a mark is decoded off-main, every later render — fast scroll
/// included — reads it synchronously here and paints with zero per-row work.
///
/// `NSCache` is the native choice: thread-safe and memory-pressure-aware, so
/// iOS evicts it automatically under pressure rather than risking a memory
/// warning. `@unchecked Sendable` is sound — all access goes through
/// `NSCache`, which is internally synchronized.
final class CoinMarkImageCache: @unchecked Sendable {
    static let shared = CoinMarkImageCache()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        // Generous ceiling — a wallet with every supported token visible at
        // once stays well under this; eviction is the system's job.
        cache.countLimit = 500
        return cache
    }()

    private init() {}

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url.absoluteString as NSString)
    }

    /// Resolve a display-ready, decoded image for `url` using the ONE
    /// fetch→cache→persist path coin/token marks use (2026-06-18, user
    /// direction: "get the icons for tokens and coins in same way … cache
    /// and persist them in same way").
    ///
    /// The path, in order:
    ///   1. **This session's decoded cache** (synchronous, zero work) — a
    ///      hit returns the ready bitmap with no actor hop and no re-decode,
    ///      so scrolling re-uses pixels instead of re-rendering each row.
    ///   2. **`CoinMarkCache` durable bytes** — memory → Application Support
    ///      disk (never evicted) → network. Download-once: the network is
    ///      hit at most ONCE per URL across the device's lifetime; misses
    ///      are negative-cached so a list scroll doesn't re-fire a request
    ///      per missing logo on every row reappearance.
    ///   3. **Off-main decode** — `CGImageSource` validates the container is
    ///      COMPLETE before `preparingForDisplay()` runs the decompressor,
    ///      so truncated/corrupt bytes never hit ImageIO's "-17102" path and
    ///      the decode never lands on the main thread during scroll.
    ///
    /// The decoded result is stored back into the session cache (step 1) so
    /// later renders paint synchronously. Returns `nil` when the URL 404s or
    /// serves undecodable bytes (caller shows its own fallback — initials
    /// chip / letter chip); undecodable bytes are negative-cached upstream
    /// via `markUndecodable` so they don't refetch-and-re-throw in a loop.
    func resolveImage(for url: URL) async -> UIImage? {
        if let cached = image(for: url) { return cached }
        guard let data = await CoinMarkCache.shared.data(for: url) else { return nil }
        let decoded: UIImage? = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceGetCount(source) > 0,
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return nil
            }
            let image = UIImage(cgImage: cgImage)
            return image.preparingForDisplay() ?? image
        }.value
        guard let decoded else {
            await CoinMarkCache.shared.markUndecodable(url: url)
            return nil
        }
        store(decoded, for: url)
        return decoded
    }
}
