import SwiftUI

/// Resolves a `(chain, tokenSymbol)` pair to a bundled coin mark and
/// renders it at the caller's frame.
///
/// **Resolution order (honest, fast, offline).**
/// 1. **Native sends** — `tokenSymbol` matches the chain's own ticker
///    → use `chain.logoAssetName`. ETH on Ethereum renders the ETH
///    mark; SOL on Solana renders the SOL mark; etc.
/// 2. **Bundled stablecoins** — USDC and USDT have bundled marks in
///    `Assets.xcassets/Crypto/`. These are by far the most-seen
///    tokens on the home screen; bundling them keeps the first frame
///    instant.
/// 3. **Everything else** — falls back to an *honest* initials chip
///    on `Material.card` (Rule #7). A user who sees "DAI" on a
///    neutral chip knows we don't ship a logo for it; a user who
///    saw a fabricated yellow circle with a "D" inside would be lied to.
///
/// **Why not `AsyncImage` from Trust Wallet here.** The wallet home
/// is the most-touched surface in the app. Hitting the network on
/// first render of every row produces a visible flash and consumes
/// data on every refresh. The Asset Detail screen — when it lands —
/// is where the full-color token logo belongs. Until then, the
/// 2-tier bundled fallback is the honest answer.
///
/// **Layout.** Sizes itself to the caller's `.frame(...)` modifier.
/// Internally circle-clipped so brand-rectangular assets read as
/// disks alongside SF Symbols.
///
/// **History.** Originally `private` to `ActivityRow.swift` (shipped
/// 2026-06-08 with the activity-row redesign). Promoted to internal
/// 2026-06-08 (same day) when the Coins / Tokens split needed the
/// same resolution for `TokenHoldingRow` — see `WalletHomeView`'s
/// "Coins (native) + Tokens (registry)" SHIPPED entry.
struct CoinMark: View {
    let chain: SupportedChain
    let tokenSymbol: String

    var body: some View {
        if let assetName = resolvedAssetName {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .clipShape(Circle())
        } else {
            initialsChip
        }
    }

    /// The bundled asset name for this `(chain, symbol)` pair, or nil
    /// if the symbol is a token we don't ship a mark for.
    private var resolvedAssetName: String? {
        // Native sends: the symbol matches the chain's native ticker.
        // Compare uppercased to match the chain.ticker convention.
        if tokenSymbol.uppercased() == chain.ticker.uppercased() {
            return chain.logoAssetName
        }
        // Token transfers — only stablecoins we explicitly ship.
        switch tokenSymbol.uppercased() {
        case "USDC": return "Crypto/usdc"
        case "USDT": return "Crypto/usdt"
        default:     return nil
        }
    }

    /// Up-to-3-letter initials chip. Renders the ticker on a neutral
    /// `Material.card` disk — the same disk color as the surrounding
    /// row chrome, so the chip reads as restrained, not loud.
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
        // Cap at 3 chars; longer tickers (e.g. wstETH) compress to the
        // first three letters which still read as the asset's family.
        return String(trimmed.prefix(3)).uppercased()
    }
}
