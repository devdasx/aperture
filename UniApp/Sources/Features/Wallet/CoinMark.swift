import SwiftUI
import ImageIO

/// Resolves a `(chain, tokenSymbol, contract)` triple to a coin
/// mark and renders it at the caller's frame.
///
/// **Trust Wallet ONLY (2026-06-15 user direction).**
/// > *"we'll use only trust wallet icons, we'll never use any other
/// > icons for coins & tokens."*
/// Every coin and token mark resolves from the `trustwallet/assets`
/// repo (MIT, Rule #7 §B priority 1) via `CoinMarkCache.shared` —
/// native coins from `…/blockchains/<slug>/info/logo.png`, tokens
/// from `…/blockchains/<slug>/assets/<contract>/logo.png`. There is
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
    @State private var prepared: UIImage?

    var body: some View {
        // A native coin's logo is BUNDLED in the asset catalog
        // (`coin-<slug>`, fetched from Trust Wallet at build time) — render
        // it instantly, with no network, no first-launch flash, and no risk
        // of cache eviction blanking it (user direction 2026-06-17). Tokens
        // (which are open-ended) keep the network + persistent-disk path.
        if let bundled = bundledNativeAssetName {
            Image(bundled)
                .resizable()
                .scaledToFit()
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
        return Group {
            if let image = prepared {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(Circle())
            } else {
                initialsChip
            }
        }
        .task(id: url) {
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
            await MainActor.run { self.prepared = image }
            return
        }
        let fallback = fallbackURL
        guard let fallback, fallback != url,
              let image = await preparedImage(for: fallback) else { return }
        await MainActor.run { self.prepared = image }
    }

    /// Fetch + decode a single mark URL off-main, or `nil` when the URL
    /// is absent, the download 404s, or the bytes don't decode.
    private func preparedImage(for url: URL?) async -> UIImage? {
        guard let url else { return nil }
        guard let data = await CoinMarkCache.shared.data(for: url) else { return nil }
        // **2026-06-09 perf.** Decode + pre-prepare the image off
        // the main thread. `preparingForDisplay()` returns a
        // bitmap with the pixel format the GPU expects — without
        // it, SwiftUI defers the decode to the first render frame,
        // which is exactly the wrong moment (scroll). Detached task
        // so the decode doesn't run on the actor that owns the
        // cache. Cooperative cancellation when the view goes away.
        let image: UIImage? = await Task.detached(priority: .userInitiated) {
            // **2026-06-16 — validate the container BEFORE decoding pixels.**
            // The "-17102 decompressing image — possibly corrupt" log is
            // emitted by ImageIO DURING a pixel decode of truncated/corrupt
            // bytes — so the only way to avoid it is to never hand bad bytes
            // to the decoder. `CGImageSourceGetStatus` reports whether the
            // container is COMPLETE from the header/structure WITHOUT
            // running the decompressor; a truncated download (the common
            // cause) reports `.statusIncomplete`/`.statusInvalidData` and is
            // rejected here, before any decode. Only a complete, decodable
            // container proceeds to `preparingForDisplay()`.
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceGetCount(source) > 0,
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return nil
            }
            let decoded = UIImage(cgImage: cgImage)
            return decoded.preparingForDisplay() ?? decoded
        }.value
        guard let image else {
            // Undecodable bytes (-17102). Drop the bad local copy AND
            // negative-cache the URL: the corruption is upstream, so a
            // bare re-download would fetch the same bad bytes and
            // re-throw -17102 on the next row reappearance — an endless
            // log loop. `markUndecodable` stops the retry for hours; the
            // initials chip shows meanwhile (`prepared` stays nil).
            await CoinMarkCache.shared.markUndecodable(url: url)
            return nil
        }
        return image
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
}
