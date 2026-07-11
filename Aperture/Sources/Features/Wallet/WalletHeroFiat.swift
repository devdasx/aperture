import Foundation

/// P1-007: pure hero-total selection for the wallet balance card.
///
/// Amounts and currency codes must always match. Summing prior-currency
/// `chain_states` / portfolio totals and formatting them with the **new**
/// display currency makes the portfolio look like it jumped or crashed
/// when the user only changed the currency label.
enum WalletHeroFiat {
    struct Summary: Sendable, Hashable {
        let walletId: UUID
        let currencyCode: String
        let totalFiat: Decimal
    }

    struct ChainTotal: Sendable, Hashable {
        let walletId: UUID
        let fiatCurrencyCode: String
        let totalFiat: Decimal
    }

    /// Total fiat for `walletId` in `displayCurrencyCode` only.
    /// Returns 0 when no matching-currency rows exist yet (rebuild/projection
    /// in flight) — never mixes currencies under one symbol.
    static func total(
        walletId: UUID?,
        displayCurrencyCode: String,
        portfolioSummaries: [Summary],
        chainStates: [ChainTotal]
    ) -> Decimal {
        guard let walletId else { return 0 }
        let target = displayCurrencyCode.uppercased()

        if let summary = portfolioSummaries.first(where: {
            $0.walletId == walletId
            && $0.currencyCode.uppercased() == target
        }) {
            return summary.totalFiat
        }

        return chainStates
            .filter {
                $0.walletId == walletId
                && $0.fiatCurrencyCode.uppercased() == target
            }
            .reduce(Decimal.zero) { $0 + $1.totalFiat }
    }
}
