import SwiftUI

/// Nav-bar title for a per-coin Send / Receive screen: the verb, the
/// cached coin mark, and the coin's FULL name — e.g. "Send 🟣 Solana to",
/// "Receive 🔵 USD Coin". The full name + the token's contract (for the
/// mark) are resolved from `AssetCatalog` by (symbol, chain), so callers
/// pass only the chain + symbol they already hold. Used by both flows so
/// the title reads identically.
///
/// Drop into a nav bar via `.toolbar { ToolbarItem(placement: .principal)
/// { CoinTitleBar(...) } }`. The mark goes through `CoinMark` (Trust
/// Wallet only, cached) per the icon policy.
struct CoinTitleBar: View {
    let chain: SupportedChain
    /// nil = native coin (the chain's own coin).
    let tokenSymbol: String?
    /// Leading verb — "Send" / "Receive".
    let verb: LocalizedStringKey
    /// Optional trailing word — "to" on the Send recipient step.
    var trailing: LocalizedStringKey? = nil

    private var catalogEntry: CatalogAsset? {
        guard let symbol = tokenSymbol else { return nil }
        return AssetCatalog.allAssets.first { $0.symbol == symbol && $0.chain == chain }
            ?? AssetCatalog.allAssets.first { $0.symbol == symbol }
    }

    /// The full coin name: the chain's display name for a native coin,
    /// else the catalog's full token name (falling back to the ticker).
    private var fullName: String {
        guard let symbol = tokenSymbol else { return chain.displayName }
        return catalogEntry?.name ?? symbol
    }

    private var iconSymbol: String { tokenSymbol ?? chain.ticker }
    private var contract: String? { catalogEntry?.contract }

    var body: some View {
        HStack(spacing: UniSpacing.xs) {
            Text(verb)
                .font(UniTypography.bodyEmphasized)
                .foregroundStyle(UniColors.Text.primary)
            CoinMark(chain: chain, tokenSymbol: iconSymbol, contract: contract)
                .frame(width: 22, height: 22)
            Text(verbatim: fullName)
                .font(UniTypography.bodyEmphasized)
                .foregroundStyle(UniColors.Text.primary)
                .lineLimit(1)
            if let trailing {
                Text(trailing)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
