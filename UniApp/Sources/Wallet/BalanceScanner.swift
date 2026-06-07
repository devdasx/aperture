import Foundation

/// One per-chain balance snapshot. `nativeBalance` is in the chain's
/// base unit (e.g. BTC, ETH, SOL — not satoshis/wei/lamports).
///
/// `fiatBalance` is **optional** so the UI can honestly distinguish
/// "zero balance × known price = $0.00" from "I couldn't get the
/// price — `nil`" (Rule #2 §A.7). A `0` fiat is real $0.00; only
/// `nil` triggers the "Price unavailable" row.
struct ChainBalance: Hashable, Sendable {
    let chain: SupportedChain
    let address: String
    let nativeBalance: Decimal
    let fiatBalance: Decimal?         // nil = price genuinely unavailable
    let fiatCurrencyCode: String      // "USD", "EUR", …
    let isUsed: Bool                  // address has > 0 transactions on-chain
    let lastUpdated: Date
}

/// Lifecycle state for a per-screen scan pass.
enum ScanState: Hashable, Sendable {
    case idle
    case scanning
    case completed
    case failed(reason: String)
}

/// Reads balance + transaction-history presence from a chain. Phase-1
/// ships with `StubBalanceScanner` (deterministic mock data); the real
/// per-family implementations land as T-037 through T-040, each one
/// using `URLSession` + JSON-RPC / REST against public endpoints (per
/// Rule #3 — no third-party SDK).
///
/// **Honesty (Rule #16).** Real implementations hit public RPC
/// providers (mempool.space, Ankr, Solana mainnet-beta, etc.). The
/// review screen's footer names this explicitly so the user knows
/// Aperture itself sends nothing, but the public providers may log
/// the read request.
protocol BalanceScanner: Sendable {
    func scan(
        addresses: [SupportedChain: String],
        currency: SupportedCurrency
    ) async throws -> [ChainBalance]
}

/// Phase-1 stub. Deterministic per-address mock data — same input
/// always produces the same output so the UI behaves like the real
/// thing without any network call. Replaced incrementally by
/// per-family implementations as T-037..T-040 land.
///
/// `isUsed` is deterministic via `hashValue % 3 != 0` so roughly 2/3
/// of stub addresses display the "used" dot — visually obvious that
/// the indicator works, without being misleading (the per-row footer
/// in the review screen names that real on-chain data is pending the
/// audit).
struct StubBalanceScanner: BalanceScanner {
    func scan(
        addresses: [SupportedChain: String],
        currency: SupportedCurrency
    ) async throws -> [ChainBalance] {
        // Simulate a short scan window so the UI's loading state is
        // briefly visible — long enough to feel real, short enough to
        // not delay the user (~280ms).
        try await Task.sleep(for: .milliseconds(280))

        let now = Date()
        return addresses.map { chain, address in
            let h = abs(address.hashValue)
            // Native balance: 0.0 – 0.01 in the chain's base unit.
            let native = Decimal(h % 1_000) / Decimal(100_000)
            // Fiat balance: rough multiplier so the visual feels
            // plausible. Real per-chain pricing arrives in T-037..T-040.
            let fiat = native * Decimal(50_000)
            return ChainBalance(
                chain: chain,
                address: address,
                nativeBalance: native,
                fiatBalance: fiat,
                fiatCurrencyCode: currency.code,
                isUsed: h % 3 != 0,
                lastUpdated: now
            )
        }
    }
}
