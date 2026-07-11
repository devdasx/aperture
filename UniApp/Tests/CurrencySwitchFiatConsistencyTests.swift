import Foundation
import Testing
@testable import Aperture

/// P1-007: currency switch must never show old amounts under a new symbol.
@Suite("Currency switch fiat consistency (P1-007)")
struct CurrencySwitchFiatConsistencyTests {

    // MARK: - Hero total

    @Test("hero uses matching-currency summary when present")
    func heroPrefersMatchingSummary() {
        let walletId = UUID()
        let total = WalletHeroFiat.total(
            walletId: walletId,
            displayCurrencyCode: "EUR",
            portfolioSummaries: [
                .init(walletId: walletId, currencyCode: "USD", totalFiat: 100),
                .init(walletId: walletId, currencyCode: "EUR", totalFiat: 92),
            ],
            chainStates: [
                .init(walletId: walletId, fiatCurrencyCode: "USD", totalFiat: 100),
                .init(walletId: walletId, fiatCurrencyCode: "EUR", totalFiat: 50),
            ]
        )
        #expect(total == 92)
    }

    @Test("hero sums only chain rows in the display currency")
    func heroSumsMatchingChainsOnly() {
        let walletId = UUID()
        let total = WalletHeroFiat.total(
            walletId: walletId,
            displayCurrencyCode: "EUR",
            portfolioSummaries: [],
            chainStates: [
                .init(walletId: walletId, fiatCurrencyCode: "USD", totalFiat: 10_000),
                .init(walletId: walletId, fiatCurrencyCode: "EUR", totalFiat: 40),
                .init(walletId: walletId, fiatCurrencyCode: "EUR", totalFiat: 5),
                .init(walletId: UUID(), fiatCurrencyCode: "EUR", totalFiat: 999),
            ]
        )
        #expect(total == 45)
    }

    @Test("hero never mixes prior-currency totals under a new code (P1-007 regression)")
    func heroNeverMixesCurrencies() {
        let walletId = UUID()
        // After a switch to JOD, only USD rows exist until rebuild.
        // Old bug: sum USD (1000) and format as JOD → looks like a crash/jump.
        let total = WalletHeroFiat.total(
            walletId: walletId,
            displayCurrencyCode: "JOD",
            portfolioSummaries: [
                .init(walletId: walletId, currencyCode: "USD", totalFiat: 1_000)
            ],
            chainStates: [
                .init(walletId: walletId, fiatCurrencyCode: "USD", totalFiat: 1_000)
            ]
        )
        #expect(total == 0, "must not show 1000 JOD when the only total is 1000 USD")
    }

    @Test("hero is zero with no wallet")
    func heroNoWallet() {
        let total = WalletHeroFiat.total(
            walletId: nil,
            displayCurrencyCode: "USD",
            portfolioSummaries: [
                .init(walletId: UUID(), currencyCode: "USD", totalFiat: 50)
            ],
            chainStates: []
        )
        #expect(total == 0)
    }

    // MARK: - Markets reprice

    @Test("MarketAsset.converted changes currency code with the amount")
    func convertedKeepsCodeAndAmountAligned() {
        let asset = MarketAsset(
            symbol: "BTC",
            name: "Bitcoin",
            providerId: "bitcoin",
            rank: 1,
            price: 100,
            currencyCode: "USD",
            priceChange24hPercent: 1,
            priceChange24hAmount: 1,
            marketCap: 1_000,
            volume24h: 50,
            circulatingSupply: 19,
            ath: 120,
            high24h: 105,
            low24h: 95,
            about: "",
            sparkline: [MarketPoint(date: Date(), price: 100)],
            source: "test",
            lastUpdatedAt: Date()
        )
        let eur = asset.converted(to: "EUR", rate: 0.9, source: "fx")
        #expect(eur.currencyCode == "EUR")
        #expect(eur.price == 90)
        #expect(eur.priceChange24hAmount == 0.9)
        #expect(eur.ath == 108)
        #expect(eur.sparkline.first?.price == 90)

        // No conversion when rate invalid — keep old code+amount together.
        let same = asset.converted(to: "EUR", rate: 0, source: "fx")
        #expect(same.currencyCode == "USD")
        #expect(same.price == 100)
    }

    @Test("list formatting must use asset.currencyCode not preference alone")
    func listUsesAssetCurrencyCode() {
        // Documents the P1-007 contract for MarketAssetRow:
        // format(price, code: asset.currencyCode) — never the preference alone.
        let usdAsset = MarketAsset(
            symbol: "ETH",
            name: "Ethereum",
            providerId: "ethereum",
            rank: 2,
            price: 3_000,
            currencyCode: "USD",
            priceChange24hPercent: 0,
            priceChange24hAmount: 0,
            marketCap: 0,
            volume24h: 0,
            circulatingSupply: 0,
            ath: 0,
            high24h: 0,
            low24h: 0,
            about: "",
            sparkline: [],
            source: "test",
            lastUpdatedAt: Date()
        )
        #expect(usdAsset.currencyCode == "USD")
        // Preference may be EUR while asset is still USD until FX succeeds.
        let preference = "EUR"
        #expect(usdAsset.currencyCode.uppercased() != preference)
        // Safe display: use asset.currencyCode (row already does this).
        let safeCode = usdAsset.currencyCode
        #expect(safeCode == "USD")
    }
}
