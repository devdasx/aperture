import Foundation

/// A `Sendable` snapshot of the active wallet's holdings, used by the
/// Receive & Send asset / network pickers to (a) show real balances and
/// (b) drive the real sort — balance high→low, then transaction-count
/// high→low. Built once per balance change from the SwiftData graph
/// (`WalletAddressRecord` → `TokenBalanceRecord` + `TransactionRecord`),
/// then read cheaply by the rows so scrolling never touches the store.
///
/// Fiat uses `TokenBalanceRecord.fiatValueCached`, which the sync layer
/// maintains in the active currency — the same value the wallet-home
/// `AssetRow` sorts and shows by. Tx counts are derived (there is no
/// stored per-asset count): one pass over the wallet's transactions,
/// bucketed by `(chain, SYMBOL)`.
struct AssetPickerHoldings: Sendable, Equatable {

    /// One held balance, flattened out of the SwiftData graph.
    struct Held: Sendable, Equatable {
        let chain: SupportedChain
        let symbolUpper: String
        let isNative: Bool
        let native: Decimal
        let fiat: Decimal
    }

    let held: [Held]
    /// Tx count keyed `"chainRaw|SYMBOLUPPER"`.
    let txCountByChainSymbol: [String: Int]
    /// Cheap change-detector for `.task(id:)` memoization in the lists.
    let fingerprint: String

    static let empty = AssetPickerHoldings(held: [], txCountByChainSymbol: [:], fingerprint: "empty")

    private static func key(_ chain: SupportedChain, _ symbolUpper: String) -> String {
        "\(chain.rawValue)|\(symbolUpper)"
    }

    // MARK: - Totals

    struct Totals: Sendable, Equatable {
        var native: Decimal = 0
        var fiat: Decimal = 0
        var txCount: Int = 0
        /// Whether the wallet actually holds a positive amount.
        var hasBalance: Bool { native > 0 }
    }

    /// A token aggregated across EVERY network it's held on (token picker).
    func aggregate(symbol: String) -> Totals {
        let s = symbol.uppercased()
        var t = Totals()
        for h in held where h.symbolUpper == s && !h.isNative {
            t.native += h.native
            t.fiat += h.fiat
            t.txCount += txCountByChainSymbol[Self.key(h.chain, s)] ?? 0
        }
        return t
    }

    /// A native coin on its single chain (token picker, native rows).
    func nativeTotals(chain: SupportedChain) -> Totals {
        let s = chain.ticker.uppercased()
        var t = Totals()
        for h in held where h.chain == chain && h.symbolUpper == s && h.isNative {
            t.native += h.native
            t.fiat += h.fiat
        }
        t.txCount = txCountByChainSymbol[Self.key(chain, s)] ?? 0
        return t
    }

    /// A token (or native) on ONE specific network (network picker).
    func perNetwork(symbol: String, chain: SupportedChain) -> Totals {
        let s = symbol.uppercased()
        var t = Totals()
        for h in held where h.chain == chain && h.symbolUpper == s {
            t.native += h.native
            t.fiat += h.fiat
        }
        t.txCount = txCountByChainSymbol[Self.key(chain, s)] ?? 0
        return t
    }
}

extension AssetPickerHoldings {
    /// Build the snapshot from the active wallet. Runs on the main actor
    /// (SwiftData models are main-context bound); the caller invokes it
    /// from a `.task(id:)` so it's off the synchronous render path
    /// (Rule #28), keyed on a fingerprint so it only rebuilds when
    /// balances actually change.
    @MainActor
    init(wallet: WalletRecord?) {
        guard let wallet else { self = .empty; return }
        var held: [Held] = []
        var tx: [String: Int] = [:]
        var fiatSum = Decimal(0)

        for address in wallet.addresses {
            guard let chain = SupportedChain(rawValue: address.chainRaw) else { continue }
            for bal in address.balances {
                let amount = WalletFormatting.decimalAmount(rawBalance: bal.rawBalance, decimals: bal.decimals)
                let fiat = max(bal.fiatValueCached, 0)
                fiatSum += fiat
                held.append(Held(
                    chain: chain,
                    symbolUpper: bal.tokenSymbol.uppercased(),
                    isNative: bal.tokenContract == nil,
                    native: amount,
                    fiat: fiat
                ))
            }
            for t in address.transactions {
                tx["\(chain.rawValue)|\(t.tokenSymbol.uppercased())", default: 0] += 1
            }
        }

        let txTotal = tx.values.reduce(0, +)
        self.held = held
        self.txCountByChainSymbol = tx
        self.fingerprint = "\(wallet.id.uuidString)|\(held.count)|\(txTotal)|\(fiatSum)"
    }
}

// MARK: - Sort (balance high→low, then tx-count high→low)

/// A token row that can be sorted by the canonical picker order. Both
/// `SendAsset` and `ReceiveAsset` conform so the two flows sort 1:1.
protocol PickerAssetSortable {
    /// The token symbol used to look up aggregated holdings.
    var sortSymbol: String { get }
    /// Tiebreaker: number of networks the token ships on (desc).
    var sortChainCount: Int { get }
}

/// The canonical picker sort: balance (fiat) high→low, then transaction
/// count high→low, then a stable tiebreaker. Used by both Receive and
/// Send pickers so the order is identical (Rule: "same everywhere").
enum AssetPickerSort {
    /// Native coins, sorted by held value → tx count → canonical order.
    static func natives(_ chains: [SupportedChain], holdings: AssetPickerHoldings) -> [SupportedChain] {
        let order = Dictionary(
            uniqueKeysWithValues: SupportedChain.allCases.enumerated().map { ($0.element, $0.offset) }
        )
        return chains.sorted { a, b in
            let ta = holdings.nativeTotals(chain: a)
            let tb = holdings.nativeTotals(chain: b)
            if ta.fiat != tb.fiat { return ta.fiat > tb.fiat }
            if ta.txCount != tb.txCount { return ta.txCount > tb.txCount }
            return (order[a] ?? 0) < (order[b] ?? 0)
        }
    }

    /// Tokens, sorted by aggregated value → tx count → network count →
    /// symbol.
    static func tokens<T: PickerAssetSortable>(_ tokens: [T], holdings: AssetPickerHoldings) -> [T] {
        tokens.sorted { a, b in
            let ta = holdings.aggregate(symbol: a.sortSymbol)
            let tb = holdings.aggregate(symbol: b.sortSymbol)
            if ta.fiat != tb.fiat { return ta.fiat > tb.fiat }
            if ta.txCount != tb.txCount { return ta.txCount > tb.txCount }
            if a.sortChainCount != b.sortChainCount { return a.sortChainCount > b.sortChainCount }
            return a.sortSymbol < b.sortSymbol
        }
    }

    /// Networks for a token, sorted by per-network value → tx count →
    /// canonical order.
    static func networks(_ chains: [SupportedChain], symbol: String, holdings: AssetPickerHoldings) -> [SupportedChain] {
        let order = Dictionary(
            uniqueKeysWithValues: SupportedChain.allCases.enumerated().map { ($0.element, $0.offset) }
        )
        return chains.sorted { a, b in
            let ta = holdings.perNetwork(symbol: symbol, chain: a)
            let tb = holdings.perNetwork(symbol: symbol, chain: b)
            if ta.fiat != tb.fiat { return ta.fiat > tb.fiat }
            if ta.txCount != tb.txCount { return ta.txCount > tb.txCount }
            return (order[a] ?? 0) < (order[b] ?? 0)
        }
    }
}

extension SendAsset: PickerAssetSortable {
    var sortSymbol: String {
        switch self {
        case let .token(symbol, _, _): return symbol
        case let .native(chain):       return chain.ticker
        }
    }
    var sortChainCount: Int {
        if case let .token(_, _, chains) = self { return chains.count }
        return 1
    }
}

extension ReceiveAsset: PickerAssetSortable {
    var sortSymbol: String {
        switch self {
        case let .token(symbol, _, _): return symbol
        case let .native(chain):       return chain.ticker
        }
    }
    var sortChainCount: Int {
        if case let .token(_, _, chains) = self { return chains.count }
        return 1
    }
}
