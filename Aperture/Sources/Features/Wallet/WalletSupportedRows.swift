import Foundation

/// Display shape for one Coins row across both consumers
/// (`WalletHomeView`'s home `coinsSection` AND
/// `AllSupportedAssetsView`'s "all supported" listing). Carries the
/// chain plus the current native amount + fiat value — `.zero`
/// amount + `nil` fiat is the honest representation for a coin the
/// user doesn't yet hold (per Rule #16: zero is "0", never `—`).
struct WalletCoinSupportedRow {
    let chain: SupportedChain
    let amount: Decimal
    let fiatValue: Decimal?
    let fiatCurrencyCode: String

    /// `true` if the user currently holds a non-zero balance of this
    /// coin. Used by the home screen to sort held coins ahead of
    /// not-held coins; the "all supported" screen ignores it (every
    /// row renders regardless).
    var isHeld: Bool { amount > 0 }
}

/// Display shape for one Tokens row across both consumers. Same
/// rationale as `WalletCoinSupportedRow`: the home screen and the
/// "all supported" screen share the row shape so the components and
/// builders are reusable.
struct WalletTokenSupportedDisplayRow: Identifiable, Equatable {
    let id: String
    let chain: SupportedChain
    let symbol: String
    let name: String
    /// On-chain identifier (EVM contract / SPL mint / XRPL
    /// `currency.issuer` / TON master contract / etc.). Used by
    /// `CoinMark` to resolve and cache a token logo. Encoded as
    /// `String` because the source format differs per chain.
    let contract: String
    let amount: Decimal
    let fiatValue: Decimal?
    let fiatCurrencyCode: String

    /// `true` if the user currently holds a non-zero balance of this
    /// token. Sort key for home-screen held-first ordering.
    var isHeld: Bool { amount > 0 }
}

/// Pure-function builders that enumerate every supported coin /
/// token in Aperture's registries and pair each with the active
/// wallet's current balance (zero placeholder when not held). Used
/// by both `WalletHomeView` (capped at 10, held-first) and
/// `AllSupportedAssetsView` (uncapped, in canonical order).
///
/// **Honesty.** A registry entry that the user doesn't hold renders
/// as `amount: 0, fiatValue: nil`. The UI shows it as `0 / Price
/// unavailable` — never hidden, never "Coming soon" (we already
/// support it). The user opens the home screen and sees what
/// Aperture supports, with their actual balances mixed in.
enum WalletSupportedRowBuilders {

    /// All Coins rows — one per `SupportedChain.allCases`. The
    /// `heldRows` argument is the active wallet's held balances (the
    /// same source the existing `balances` computed in
    /// `WalletHomeView` consumes); we look up each chain's native
    /// balance from it.
    static func coinRows(
        heldRows: [(chain: SupportedChain, balance: TokenBalanceRecord)],
        currencyCode: String,
        chains: [CatalogChain] = AssetCatalog.allChains
    ) -> [WalletCoinSupportedRow] {
        // **2026-06-09 perf.** Index native balances by chain ONCE.
        // Previously each chain ran `heldRows.first { ... }` — 26
        // chains × 50 heldRows = 1300 comparisons per body render.
        // Now: one O(N) pass to build, then 26 O(1) lookups.
        //
        // **2026-06-13 — local-first (Rule #27 §D).** The chain universe
        // now comes from `chains` (the DB-seeded `ChainRecord` set,
        // mapped to `CatalogChain` by the caller) and defaults to the
        // static `AssetCatalog` so non-DB call sites keep working
        // unchanged. The two sources are provably identical
        // (`AssetCatalogTests`), so the rendered list is the same.
        // Sum natives across every address on the chain (e.g. Solana Phantom
        // + Trust paths each hold their own token_balances row).
        var nativeAmount: [SupportedChain: Decimal] = [:]
        var nativeFiat: [SupportedChain: Decimal] = [:]
        var nativeCurrency: [SupportedChain: String] = [:]
        nativeAmount.reserveCapacity(chains.count)
        for entry in heldRows where entry.balance.tokenContract == nil
            && entry.balance.tokenSymbol == entry.chain.ticker {
            let amount = WalletFormatting.decimalAmount(
                rawBalance: entry.balance.rawBalance,
                decimals: entry.balance.decimals
            )
            nativeAmount[entry.chain, default: .zero] += amount
            if entry.balance.fiatValueCached > 0 {
                nativeFiat[entry.chain, default: .zero] += entry.balance.fiatValueCached
            }
            if nativeCurrency[entry.chain] == nil {
                nativeCurrency[entry.chain] = entry.balance.fiatCurrencyCode
            }
        }
        return chains.map { $0.chain }.map { chain in
            let amount = nativeAmount[chain] ?? .zero
            let fiat = nativeFiat[chain]
            return WalletCoinSupportedRow(
                chain: chain,
                amount: amount,
                fiatValue: (fiat ?? 0) > 0 ? fiat : nil,
                fiatCurrencyCode: nativeCurrency[chain] ?? currencyCode
            )
        }
    }

    /// All Tokens rows — every entry across the curated registries
    /// (`EVMTokenRegistry`, `SolanaTokenRegistry`, `TronTokenRegistry`,
    /// `NearTokenRegistry`, `AptosTokenRegistry`, `SuiTokenRegistry`,
    /// `PolkadotTokenRegistry`, `XRPLTokenRegistry`,
    /// `TonTokenRegistry`). Each entry pairs with the active wallet's
    /// current balance (or zero placeholder).
    static func tokenRows(
        heldRows: [(chain: SupportedChain, balance: TokenBalanceRecord)],
        currencyCode: String,
        assets: [CatalogAsset] = AssetCatalog.allAssets,
        customTokens: [CustomTokenSnapshot] = []
    ) -> [WalletTokenSupportedDisplayRow] {
        // **2026-06-09 perf.** Build the (chain, contract) → balance
        // index ONCE up front, then every per-asset lookup below is
        // O(1) instead of O(N).
        //
        // **2026-06-13 — local-first (Rule #27 §D).** The token universe
        // now comes from `assets` (the DB-seeded `AssetRecord` set,
        // mapped to `CatalogAsset` by the caller) and defaults to the
        // static `AssetCatalog` so non-DB call sites keep working
        // unchanged. The per-registry enumeration that used to live here
        // moved verbatim into `AssetCatalog.allAssets` (one source for
        // the seeder + this fallback), so the rendered list is identical
        // whether sourced from the store or the static catalog
        // (`AssetCatalogTests` pins the equivalence).
        let index = HeldRowIndex(heldRows)
        var rows: [WalletTokenSupportedDisplayRow] = []
        rows.reserveCapacity(assets.count + customTokens.count)
        var seen = Set<String>()
        for asset in assets {
            let balance = index.lookup(chain: asset.chain, contract: asset.contract)
            rows.append(WalletTokenSupportedDisplayRow(
                id: asset.id,
                chain: asset.chain,
                symbol: asset.symbol,
                name: asset.name,
                contract: asset.contract,
                amount: balance?.amount ?? .zero,
                fiatValue: balance.flatMap { $0.hasPositiveFiat ? $0.fiat : nil },
                fiatCurrencyCode: balance?.currencyCode ?? currencyCode
            ))
            seen.insert("\(asset.chain.rawValue)|\(asset.contract.lowercased())")
        }
        // **User-added custom tokens (2026-06-19).** A token the user
        // pasted into "Add custom token" lives in `CustomTokenRecord`, NOT
        // the curated catalog — so it never appeared in this list, even
        // when held + scanned (the scanner DOES fetch its balance; it's in
        // `customTokensByChain`). Append one row per custom token that the
        // catalog doesn't already cover (dedup by chain+contract), matched
        // to the held balance the same way — so it shows everywhere the
        // catalog tokens do, with its real balance or a 0 placeholder.
        for token in customTokens {
            let key = "\(token.chain.rawValue)|\(token.contract.lowercased())"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let balance = index.lookup(chain: token.chain, contract: token.contract)
            rows.append(WalletTokenSupportedDisplayRow(
                id: "custom:\(key)",
                chain: token.chain,
                symbol: token.symbol,
                name: token.name,
                contract: token.contract,
                amount: balance?.amount ?? .zero,
                fiatValue: balance.flatMap { $0.hasPositiveFiat ? $0.fiat : nil },
                fiatCurrencyCode: balance?.currencyCode ?? currencyCode
            ))
        }
        return rows
    }

    /// Collapse per-`(chain, contract)` token rows into ONE row per symbol,
    /// so the user sees each token (e.g. USDT) a single time — its total
    /// across every network — instead of one line per network. Tapping the
    /// row opens the asset detail, which lists the per-network breakdown and
    /// lets the user choose where to send/receive (user direction 2026-06-18).
    ///
    /// Amount + fiat are summed across the symbol's networks — `1 USDT == 1
    /// USDT` on any chain, the exact symbol-aggregation `AssetIdentity` /
    /// `AssetDetailView` already use. Fiat sums only the networks that carry a
    /// value and is `nil` when none do (honest — Rule #16). The representative
    /// `chain`/`contract` (for the coin mark) is the largest holding, falling
    /// back to the first registry entry, so the logo + its symbol-level
    /// fallback resolve. First-seen symbol order is preserved; the caller
    /// applies its own sort afterward. The collapsed row's `id` is the symbol,
    /// so `ForEach` identity is stable and unique.
    static func collapseBySymbol(
        _ rows: [WalletTokenSupportedDisplayRow],
        currencyCode: String
    ) -> [WalletTokenSupportedDisplayRow] {
        var order: [String] = []
        var groups: [String: [WalletTokenSupportedDisplayRow]] = [:]
        for row in rows {
            let key = row.symbol.uppercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(row)
        }
        return order.compactMap { key -> WalletTokenSupportedDisplayRow? in
            guard let members = groups[key], !members.isEmpty else { return nil }
            let totalAmount = members.reduce(Decimal.zero) { $0 + $1.amount }
            let priced = members.compactMap { $0.fiatValue }
            let totalFiat: Decimal? = priced.isEmpty ? nil : priced.reduce(Decimal.zero, +)
            // Representative for the mark: largest fiat, then largest amount.
            let representative = members.max { lhs, rhs in
                let lf = lhs.fiatValue ?? .zero
                let rf = rhs.fiatValue ?? .zero
                if lf != rf { return lf < rf }
                return lhs.amount < rhs.amount
            } ?? members[0]
            return WalletTokenSupportedDisplayRow(
                id: key,
                chain: representative.chain,
                symbol: representative.symbol,
                name: representative.name,
                contract: representative.contract,
                amount: totalAmount,
                fiatValue: totalFiat,
                fiatCurrencyCode: currencyCode
            )
        }
    }

    /// **2026-06-09 perf fix.** O(1) index keyed by `(chain, contract)`
    /// for token-balance lookup. Previously `tokenRows(...)` ran a
    /// linear `heldRows.first { ... }` scan for EVERY one of ~400
    /// registry tokens × ~50 held rows = ~20k operations per body
    /// re-render. The main screen body re-renders on every
    /// `@GRDBStorage` write (the filter sheet writes ~12 keys) and on
    /// every GRDB observation snapshot; the linear scan was the dominant
    /// per-frame cost. Index build is O(N) once; lookup is O(1).
    fileprivate struct HeldRowIndex {
        // Key: "{chain.rawValue}|{contract.lowercased()}" (lowercased
        // matches EIP-55 mixed-case for EVM; harmless for
        // case-sensitive families since their contracts arrive
        // verbatim from on-chain so case is already canonical).
        // Amounts are summed when multiple address paths hold the same mint
        // (Solana Phantom + Trust).
        fileprivate struct Aggregate {
            var amount: Decimal = .zero
            var fiat: Decimal = .zero
            var currencyCode: String
            var hasPositiveFiat: Bool = false
        }

        private let storage: [String: Aggregate]

        init(_ heldRows: [(chain: SupportedChain, balance: TokenBalanceRecord)]) {
            var dict: [String: Aggregate] = [:]
            dict.reserveCapacity(heldRows.count)
            for entry in heldRows {
                guard let contract = entry.balance.tokenContract else { continue }
                let key = "\(entry.chain.rawValue)|\(contract.lowercased())"
                let amount = WalletFormatting.decimalAmount(
                    rawBalance: entry.balance.rawBalance,
                    decimals: entry.balance.decimals
                )
                var agg = dict[key] ?? Aggregate(currencyCode: entry.balance.fiatCurrencyCode)
                agg.amount += amount
                if entry.balance.fiatValueCached > 0 {
                    agg.fiat += entry.balance.fiatValueCached
                    agg.hasPositiveFiat = true
                }
                dict[key] = agg
            }
            self.storage = dict
        }

        fileprivate func lookup(chain: SupportedChain, contract: String) -> Aggregate? {
            storage["\(chain.rawValue)|\(contract.lowercased())"]
        }
    }
}
