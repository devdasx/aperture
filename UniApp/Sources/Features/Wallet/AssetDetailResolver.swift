import Foundation

// MARK: - AssetNetworkRow

/// One network breakdown row inside `AssetDetailView`'s Networks
/// section. Carries the network identity plus the per-network
/// balance + fiat, the on-chain contract (for tokens, so the row
/// can route deeper if needed), and the user's wallet address on
/// that network (`nil` when the user has no address derived — e.g.,
/// a watch-only wallet imported as one chain only). The `isHeld`
/// flag drives the sort (held networks first) and the empty-state
/// branch.
///
/// Why a struct, not a tuple. Identifiable + Hashable for SwiftUI
/// `ForEach` identity + Codable for NavigationPath round-tripping.
struct AssetNetworkRow: Identifiable, Hashable, Sendable {

    /// Stable id for ForEach. `<chainRaw>|<contract or empty>`.
    var id: String { "\(chain.rawValue)|\(contract ?? "")" }

    let chain: SupportedChain
    /// On-chain contract / mint / jetton master / SS58 asset id /
    /// XRPL `currency.issuer`. Empty for native coins. Empty (not
    /// `nil`) when the asset doesn't have a registry contract on
    /// this chain.
    let contract: String?

    /// Native amount the user holds on this network (display units —
    /// already divided by `10^decimals`). `.zero` when supported but
    /// not held.
    let amount: Decimal
    /// Cached fiat value at last refresh. `nil` when the row carries
    /// no balance OR when prices aren't available.
    let fiatValue: Decimal?
    /// Currency code under which `fiatValue` was computed. Falls
    /// back to the active wallet's display currency when the row
    /// has no balance.
    let fiatCurrencyCode: String

    /// `true` when the user holds a non-zero amount on this network.
    var isHeld: Bool { amount > 0 }
}

// MARK: - AssetResolution

/// One snapshot of everything the asset-detail screen needs to render
/// for a given `AssetIdentity` + active wallet. Computed by
/// `AssetDetailResolver.resolve(...)` once per body evaluation, then
/// read by the view in O(1) for each section.
///
/// Performance: the resolution does ONE pass over the active
/// wallet's held rows + ONE pass over the registries; per-section
/// reads downstream are O(1). The wallet-home performance
/// hardening discipline applies (M-007-class linear-scan-in-body
/// risk avoided up front).
struct AssetResolution: Sendable {

    /// The aggregated network rows. For native coins this contains
    /// exactly one entry (the chain in the identity). For tokens
    /// this contains one entry per network the symbol exists on —
    /// held first (fiat desc), then supported-but-not-held in
    /// canonical chain order.
    let networks: [AssetNetworkRow]

    /// Σ across `networks.amount`. The honest "what do I own of
    /// this asset" number, summed across networks.
    ///
    /// Note: this is summed in native units across networks. For a
    /// token like USDC where 1 USDC on Ethereum == 1 USDC on Polygon,
    /// the sum is meaningful. For a native like ETH (where the
    /// identity is per-chain), `networks.count == 1` so the sum is
    /// the single network's amount.
    let totalAmount: Decimal

    /// Σ across `networks.fiatValue`. `nil` only when no network has
    /// a fiat value (every network's price is unavailable). Mixed
    /// rows (some with fiat, some without) sum the ones with fiat.
    let totalFiat: Decimal?

    /// Currency code of `totalFiat`. The most-common currency code
    /// across held network rows; falls back to the user's display
    /// currency when nothing is held.
    let fiatCurrencyCode: String

    /// `true` when at least one network row has a non-zero balance.
    /// Drives the `BalanceHistoryChart`'s zero-baseline branch.
    var hasAnyBalance: Bool { totalAmount > 0 }

    /// Number of networks this asset exists on. For natives = 1; for
    /// tokens = the registry's network count for the symbol.
    var supportedNetworkCount: Int { networks.count }

    /// Number of networks the user holds the asset on (non-zero
    /// balance). Always `<= supportedNetworkCount`.
    var heldNetworkCount: Int { networks.filter { $0.isHeld }.count }
}

// MARK: - AssetDetailResolver

/// **Pure-function resolver for the asset-detail screen.**
///
/// Walks the active wallet's held rows once + the registries once
/// to produce a single `AssetResolution` snapshot. The view body
/// reads it and renders.
///
/// Why a pure function (not an `@Observable`). The wallet home's
/// performance hardening proved that `@AppStorage` + `@Query`
/// invalidations re-evaluate the body frequently — anything not
/// memoized in `@State` runs every render. A small pure helper is
/// cheaper than an observable wrapper and easier to test.
///
/// Why the resolver, not the view, knows about registries. The
/// view body should read "show this list of network rows" without
/// having to enumerate nine registries. The resolver does the
/// enumeration once and hands the view a flat array.
enum AssetDetailResolver {

    /// Resolve a snapshot for one asset identity.
    ///
    /// - `identity`: which asset (symbol + kind)
    /// - `heldRows`: the active wallet's held balance rows. Same
    ///   shape `WalletHomeView`'s `allHeldRows` produces.
    /// - `fallbackCurrencyCode`: currency to attribute to network
    ///   rows that don't carry their own fiat code (supported-but-
    ///   not-held rows).
    static func resolve(
        identity: AssetIdentity,
        heldRows: [(chain: SupportedChain, balance: TokenBalanceRecord)],
        fallbackCurrencyCode: String
    ) -> AssetResolution {
        switch identity.kind {
        case .nativeCoin(let chain):
            return resolveNative(
                identity: identity,
                chain: chain,
                heldRows: heldRows,
                fallbackCurrencyCode: fallbackCurrencyCode
            )
        case .token:
            return resolveToken(
                identity: identity,
                heldRows: heldRows,
                fallbackCurrencyCode: fallbackCurrencyCode
            )
        }
    }

    // MARK: - Native resolution (single network)

    /// Native-coin identity carries the chain. Exactly one network
    /// row — that chain — even when the user holds zero. The hero
    /// reads "BTC on Bitcoin" regardless of whether the wallet has
    /// a balance.
    private static func resolveNative(
        identity: AssetIdentity,
        chain: SupportedChain,
        heldRows: [(chain: SupportedChain, balance: TokenBalanceRecord)],
        fallbackCurrencyCode: String
    ) -> AssetResolution {
        // Look up the held native balance for this chain (if any).
        let nativeBalance = heldRows.first { entry in
            entry.chain == chain
                && entry.balance.tokenContract == nil
                && entry.balance.tokenSymbol == chain.ticker
        }?.balance

        let amount: Decimal
        let fiat: Decimal?
        let fiatCode: String
        if let record = nativeBalance {
            amount = WalletFormatting.decimalAmount(
                rawBalance: record.rawBalance,
                decimals: record.decimals
            )
            fiat = record.fiatValueCached > 0 ? record.fiatValueCached : nil
            fiatCode = record.fiatCurrencyCode
        } else {
            amount = .zero
            fiat = nil
            fiatCode = fallbackCurrencyCode
        }

        let row = AssetNetworkRow(
            chain: chain,
            contract: nil,
            amount: amount,
            fiatValue: fiat,
            fiatCurrencyCode: fiatCode
        )
        return AssetResolution(
            networks: [row],
            totalAmount: amount,
            totalFiat: fiat,
            fiatCurrencyCode: fiatCode
        )
    }

    // MARK: - Token resolution (multi-network)

    /// Token identity is matched by symbol across every registry.
    /// Resolution walks each registry once, collecting every
    /// `(chain, contract)` pair whose `symbol` matches the
    /// identity's symbol (case-insensitive). For each pair we look
    /// up the held balance (if any) and emit one network row.
    ///
    /// **Performance.** The held-rows lookup goes through
    /// `HeldRowIndex` — an O(1) dict keyed by `(chain, contract)`
    /// (same primitive `WalletSupportedRowBuilders.tokenRows`
    /// uses). For a wallet with 50 held rows × 9 registries ×
    /// ~400 total registry entries, the resolver does ~400 dict
    /// lookups, not 20k linear scans.
    private static func resolveToken(
        identity: AssetIdentity,
        heldRows: [(chain: SupportedChain, balance: TokenBalanceRecord)],
        fallbackCurrencyCode: String
    ) -> AssetResolution {
        let index = HeldRowIndex(heldRows)
        let target = identity.symbol.uppercased()

        var rows: [AssetNetworkRow] = []
        rows.reserveCapacity(16)

        // EVM tokens — one entry per (chain, contract) whose
        // symbol matches. The same symbol on different EVM chains
        // emits multiple rows (USDC on Ethereum + USDC on Polygon
        // + USDC on Base + ...).
        for chain in SupportedChain.allCases where chain.family == .evm {
            for entry in EVMTokenRegistry.tokens(for: chain) where entry.symbol.uppercased() == target {
                rows.append(makeRow(
                    chain: chain,
                    contract: entry.contract,
                    balance: index.lookup(chain: chain, contract: entry.contract),
                    fallbackCurrencyCode: fallbackCurrencyCode
                ))
            }
        }

        // Solana SPL mints.
        for (mint, entry) in SolanaTokenRegistry.mints where entry.symbol.uppercased() == target {
            rows.append(makeRow(
                chain: .solana,
                contract: mint,
                balance: index.lookup(chain: .solana, contract: mint),
                fallbackCurrencyCode: fallbackCurrencyCode
            ))
        }

        // TRON (TRC-20).
        for entry in TronTokenRegistry.tokens where entry.symbol.uppercased() == target {
            rows.append(makeRow(
                chain: .tron,
                contract: entry.contract,
                balance: index.lookup(chain: .tron, contract: entry.contract),
                fallbackCurrencyCode: fallbackCurrencyCode
            ))
        }

        // NEAR (NEP-141).
        for entry in NearTokenRegistry.tokens where entry.symbol.uppercased() == target {
            rows.append(makeRow(
                chain: .near,
                contract: entry.tokenAccount,
                balance: index.lookup(chain: .near, contract: entry.tokenAccount),
                fallbackCurrencyCode: fallbackCurrencyCode
            ))
        }

        // Aptos.
        for entry in AptosTokenRegistry.tokens where entry.symbol.uppercased() == target {
            rows.append(makeRow(
                chain: .aptos,
                contract: entry.contract,
                balance: index.lookup(chain: .aptos, contract: entry.contract),
                fallbackCurrencyCode: fallbackCurrencyCode
            ))
        }

        // Polkadot Asset Hub.
        for entry in PolkadotAssetRegistry.tokens where entry.symbol.uppercased() == target {
            let contract = String(entry.assetId)
            rows.append(makeRow(
                chain: .polkadot,
                contract: contract,
                balance: index.lookup(chain: .polkadot, contract: contract),
                fallbackCurrencyCode: fallbackCurrencyCode
            ))
        }

        // XRPL IOUs.
        for entry in XRPLTokenRegistry.tokens where entry.symbol.uppercased() == target {
            let contract = "\(entry.currency).\(entry.issuer)"
            rows.append(makeRow(
                chain: .ripple,
                contract: contract,
                balance: index.lookup(chain: .ripple, contract: contract),
                fallbackCurrencyCode: fallbackCurrencyCode
            ))
        }

        // TON Jettons.
        for entry in TONJettonRegistry.tokens where entry.symbol.uppercased() == target {
            rows.append(makeRow(
                chain: .ton,
                contract: entry.masterContract,
                balance: index.lookup(chain: .ton, contract: entry.masterContract),
                fallbackCurrencyCode: fallbackCurrencyCode
            ))
        }

        // Kava (Cosmos IBC).
        for entry in KavaCosmosTokenRegistry.tokens where entry.symbol.uppercased() == target {
            rows.append(makeRow(
                chain: .kava,
                contract: entry.denom,
                balance: index.lookup(chain: .kava, contract: entry.denom),
                fallbackCurrencyCode: fallbackCurrencyCode
            ))
        }

        // **Held custom rows (registry-absent).** A user may have
        // added a custom token whose `tokenSymbol` matches our
        // identity but whose contract isn't in any registry. Surface
        // each such held row too — honest about what the user
        // actually owns, even if it's outside our curated registry.
        // Filter against keys we already emitted so we don't double-
        // count registry-matched rows.
        var emittedKeys = Set(rows.map { "\($0.chain.rawValue)|\($0.contract?.lowercased() ?? "")" })
        for entry in heldRows where entry.balance.tokenSymbol.uppercased() == target {
            // Skip natives — those collapse to a separate identity
            // path (handled by `resolveNative`).
            guard let contract = entry.balance.tokenContract else { continue }
            let key = "\(entry.chain.rawValue)|\(contract.lowercased())"
            guard !emittedKeys.contains(key) else { continue }
            emittedKeys.insert(key)
            rows.append(makeRow(
                chain: entry.chain,
                contract: contract,
                balance: entry.balance,
                fallbackCurrencyCode: fallbackCurrencyCode
            ))
        }

        // Sort: held first (fiat desc among held), then supported-
        // but-not-held in canonical chain order. Same convention as
        // the wallet-home's tokens sort so the user gets a familiar
        // ordering when they drill into a single asset.
        rows.sort { a, b in
            if a.isHeld != b.isHeld { return a.isHeld }
            if a.isHeld {
                let aFiat = a.fiatValue ?? .zero
                let bFiat = b.fiatValue ?? .zero
                if aFiat != bFiat { return aFiat > bFiat }
            }
            return WalletHomeFilterApply.canonicalIndex(a.chain)
                < WalletHomeFilterApply.canonicalIndex(b.chain)
        }

        // Aggregate totals across the held rows. Sum native amounts;
        // sum fiat across rows that carry a price.
        let totalAmount = rows.reduce(Decimal.zero) { $0 + $1.amount }
        let fiatRows = rows.compactMap { $0.fiatValue }
        let totalFiat: Decimal? = fiatRows.isEmpty
            ? nil
            : fiatRows.reduce(Decimal.zero) { $0 + $1 }

        // Pick the fiat currency code from the first held row that
        // carries a fiat value — that's the code the cached fiat
        // values are denominated in. Fall back to caller's preference.
        let fiatCode = rows.first(where: { $0.fiatValue != nil })?.fiatCurrencyCode
            ?? fallbackCurrencyCode

        return AssetResolution(
            networks: rows,
            totalAmount: totalAmount,
            totalFiat: totalFiat,
            fiatCurrencyCode: fiatCode
        )
    }

    // MARK: - Helpers

    /// Build one network row from a `(chain, contract)` pair and an
    /// optional held balance. The shape is constant across registries.
    private static func makeRow(
        chain: SupportedChain,
        contract: String?,
        balance: TokenBalanceRecord?,
        fallbackCurrencyCode: String
    ) -> AssetNetworkRow {
        let amount: Decimal
        let fiat: Decimal?
        let fiatCode: String
        if let record = balance {
            amount = WalletFormatting.decimalAmount(
                rawBalance: record.rawBalance,
                decimals: record.decimals
            )
            fiat = record.fiatValueCached > 0 ? record.fiatValueCached : nil
            fiatCode = record.fiatCurrencyCode
        } else {
            amount = .zero
            fiat = nil
            fiatCode = fallbackCurrencyCode
        }
        return AssetNetworkRow(
            chain: chain,
            contract: contract,
            amount: amount,
            fiatValue: fiat,
            fiatCurrencyCode: fiatCode
        )
    }

    /// O(1) (chain, contract) → balance index. Mirrors
    /// `WalletSupportedRowBuilders.HeldRowIndex` but lives at file
    /// scope here because the resolver needs the same lookup shape
    /// independently of the row-builder caller.
    fileprivate struct HeldRowIndex {
        private let storage: [String: TokenBalanceRecord]

        init(_ heldRows: [(chain: SupportedChain, balance: TokenBalanceRecord)]) {
            var dict: [String: TokenBalanceRecord] = [:]
            dict.reserveCapacity(heldRows.count)
            for entry in heldRows {
                guard let contract = entry.balance.tokenContract else { continue }
                dict["\(entry.chain.rawValue)|\(contract.lowercased())"] = entry.balance
            }
            self.storage = dict
        }

        func lookup(chain: SupportedChain, contract: String) -> TokenBalanceRecord? {
            storage["\(chain.rawValue)|\(contract.lowercased())"]
        }
    }
}

// MARK: - Wallet data fingerprint

/// **Cheap change-token over a wallet's balance + transaction
/// records.** The asset-detail surfaces memoize their resolver +
/// filter output in `@State` via `.task(id:)`; this string is the
/// data half of that key. One O(records) pass per body evaluation
/// (a handful of integer/date reads) replaces the full 9-registry
/// resolve — the resolve re-runs only when the records actually
/// change (refresh writes bump `TokenBalanceRecord.updatedAt`;
/// transaction inserts move the count; pending→confirmed flips move
/// the unconfirmed tally).
enum WalletDataFingerprint {
    static func make(for wallet: WalletRecord?) -> String {
        guard let wallet else { return "no-wallet" }
        var balanceCount = 0
        var latestBalanceUpdate: TimeInterval = 0
        var txCount = 0
        var latestTx: TimeInterval = 0
        var unconfirmed = 0
        for address in wallet.addresses {
            balanceCount += address.balances.count
            for balance in address.balances {
                latestBalanceUpdate = max(
                    latestBalanceUpdate,
                    balance.updatedAt.timeIntervalSinceReferenceDate
                )
            }
            txCount += address.transactions.count
            for tx in address.transactions {
                latestTx = max(latestTx, tx.occurredAt.timeIntervalSinceReferenceDate)
                if tx.statusRaw != TransactionStatus.confirmed.rawValue {
                    unconfirmed += 1
                }
            }
        }
        return "\(wallet.id.uuidString)|\(balanceCount)|\(latestBalanceUpdate)|\(txCount)|\(latestTx)|\(unconfirmed)"
    }
}

// MARK: - Asset display name lookup

/// Resolve the human-readable name for an asset (e.g. `"USD Coin"` for
/// the USDC symbol). Walks the registries until it finds a match. Used
/// by `AssetDetailView`'s hero so the screen leads with "USD Coin"
/// above "USDC" rather than just `"USDC"`.
enum AssetNameLookup {

    /// Returns the registry's `name` for the symbol if found across
    /// any registry; falls back to the symbol itself when no
    /// registry knows it (e.g. a held custom token).
    ///
    /// For native coins we return the chain's display name +
    /// ticker (e.g. `"Ethereum (ETH)"` ⇒ caller can split). Native
    /// coin callers usually call `chain.displayName` directly; this
    /// helper exists for the multi-network token case.
    static func name(forTokenSymbol symbol: String) -> String? {
        let target = symbol.uppercased()
        for chain in SupportedChain.allCases where chain.family == .evm {
            if let entry = EVMTokenRegistry.tokens(for: chain).first(where: { $0.symbol.uppercased() == target }) {
                return entry.name
            }
        }
        if let entry = SolanaTokenRegistry.mints.first(where: { $0.value.symbol.uppercased() == target })?.value {
            return entry.name
        }
        if let entry = TronTokenRegistry.tokens.first(where: { $0.symbol.uppercased() == target }) {
            return entry.name
        }
        if let entry = NearTokenRegistry.tokens.first(where: { $0.symbol.uppercased() == target }) {
            return entry.name
        }
        if let entry = AptosTokenRegistry.tokens.first(where: { $0.symbol.uppercased() == target }) {
            return entry.name
        }
        if let entry = PolkadotAssetRegistry.tokens.first(where: { $0.symbol.uppercased() == target }) {
            return entry.name
        }
        if let entry = XRPLTokenRegistry.tokens.first(where: { $0.symbol.uppercased() == target }) {
            return entry.name
        }
        if let entry = TONJettonRegistry.tokens.first(where: { $0.symbol.uppercased() == target }) {
            return entry.name
        }
        if let entry = KavaCosmosTokenRegistry.tokens.first(where: { $0.symbol.uppercased() == target }) {
            return entry.name
        }
        return nil
    }
}
