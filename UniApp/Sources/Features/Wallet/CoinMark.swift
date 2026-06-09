import SwiftUI

/// Resolves a `(chain, tokenSymbol, contract)` triple to a coin
/// mark and renders it at the caller's frame.
///
/// **Resolution order (honest, fast, offline-first).**
/// 1. **Native sends** — `tokenSymbol` matches the chain's own
///    ticker → use `chain.logoAssetName` (bundled mark, instant).
/// 2. **Bundled stablecoins** — USDC and USDT have bundled marks
///    in `Assets.xcassets/Crypto/`. Most-seen tokens; bundling
///    keeps the first frame instant.
/// 3. **Trust Wallet** — for tokens the registry knows but
///    Aperture doesn't bundle, fetch the mark from
///    `trustwallet/assets` (MIT, Rule #7 §B priority 1) via
///    `CoinMarkCache.shared`. Cached to disk on first download;
///    second-launch + every subsequent render reads from cache
///    with no network call. Shows the initials chip during
///    fetch (graceful degradation).
/// 4. **Initials chip** — final honest fallback when no bundled
///    asset exists AND Trust Wallet's repo returns nothing
///    reachable. The user sees a neutral chip — Rule #2 §A.7
///    "don't lie about a missing asset."
///
/// **Why this 4-tier ordering** (M-019 corrects M-020-class drift).
/// The user's 2026-06-09 direction:
/// > *"why some tokens has no icon? we need to fix this by use
/// > trust wallet icons, and also it should be cached and saved
/// > on device once user download the icons and always icons
/// > should be cached, fix this and add it as a mistake."*
/// Prior to 2026-06-09 this view shipped only tiers 1+2+4 — most
/// tokens fell through to the initials chip. Adding tier 3 via
/// the `CoinMarkCache` actor brings the home Tokens list and the
/// `AllSupportedAssetsView` to the same brand fidelity as the
/// bundled assets, with persistent caching so the network is
/// only ever hit ONCE per token across the device's lifetime.
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

    @State private var fetched: Data?

    var body: some View {
        Group {
            if let assetName = bundledAssetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .clipShape(Circle())
            } else if let data = fetched, let image = uiImage(from: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(Circle())
            } else {
                initialsChip
            }
        }
        .task(id: trustWalletURLString) {
            await loadFromCache()
        }
    }

    // MARK: - Tier 1 + 2: bundled assets

    private var bundledAssetName: String? {
        if tokenSymbol.uppercased() == chain.ticker.uppercased() {
            return chain.logoAssetName
        }
        switch tokenSymbol.uppercased() {
        case "USDC": return "Crypto/usdc"
        case "USDT": return "Crypto/usdt"
        default:     return nil
        }
    }

    // MARK: - Tier 3: Trust Wallet via CoinMarkCache

    /// String form of the resolved Trust Wallet URL, used as the
    /// `.task(id:)` rebuild key so the view re-fetches when the
    /// (chain, contract) inputs change.
    private var trustWalletURLString: String? {
        CoinMarkCache.trustWalletURL(chain: chain, contract: contract)?.absoluteString
    }

    private func loadFromCache() async {
        // Skip the network path entirely when a bundled asset
        // already wins — no point fetching what we'd ignore.
        if bundledAssetName != nil { return }
        guard let url = CoinMarkCache.trustWalletURL(chain: chain, contract: contract) else { return }
        let data = await CoinMarkCache.shared.data(for: url)
        await MainActor.run { self.fetched = data }
    }

    private func uiImage(from data: Data) -> UIImage? {
        UIImage(data: data)
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
