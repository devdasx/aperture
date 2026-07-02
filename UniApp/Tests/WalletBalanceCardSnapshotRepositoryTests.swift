import Testing
import Foundation
import SwiftData
@testable import Aperture

@Suite struct WalletBalanceCardSnapshotRepositoryTests {
    @Test("balance-card total uses persisted token rows, not stale chain aggregates")
    func totalUsesTokenBalanceRows() async throws {
        let container = try TestModelContainerFactory.makeContainer(name: "balance-card-token-source")
        let context = ModelContext(container)
        let wallet = WalletRecord(
            name: "Source Truth",
            kind: .watchOnly,
            mnemonicWordCount: nil,
            hasPassphrase: false,
            colorTag: "default",
            sortOrder: 0,
            requiresBackup: false
        )
        context.insert(wallet)

        let ethereum = WalletAddressRecord(chainRaw: "ethereum", address: "0xabc")
        ethereum.wallet = wallet
        ethereum.walletId = wallet.id
        context.insert(ethereum)

        let bitcoin = WalletAddressRecord(chainRaw: "bitcoin", address: "bc1qabc")
        bitcoin.wallet = wallet
        bitcoin.walletId = wallet.id
        context.insert(bitcoin)

        for (address, symbol, fiat) in [
            (ethereum, "ETH", Decimal(100)),
            (ethereum, "USDC", Decimal(50)),
            (bitcoin, "BTC", Decimal(15))
        ] {
            let balance = TokenBalanceRecord(
                tokenSymbol: symbol,
                decimals: 8,
                rawBalance: "1",
                fiatValueCached: fiat,
                fiatCurrencyCode: "USD"
            )
            balance.address = address
            balance.addressId = address.id
            context.insert(balance)
        }

        context.insert(ChainStateRecord(
            walletId: wallet.id,
            chainRaw: "bitcoin",
            address: "bc1qabc",
            totalFiat: 38,
            fiatCurrencyCode: "USD"
        ))
        context.insert(ChainStateRecord(
            walletId: wallet.id,
            chainRaw: "ethereum",
            address: "0xabc",
            totalFiat: 0,
            fiatCurrencyCode: "USD"
        ))
        try context.save()

        let snapshot = try await WalletBalanceCardSnapshotRepository(modelContainer: container)
            .rebuild(
                walletId: wallet.id,
                currencyCode: "USD",
                selectedRangeRaw: BalanceHistoryRange.all.rawValue,
                isBalanceHidden: false,
                now: Date()
            )

        #expect(snapshot.totalFiat == 165, "100 + 50 + 15 from TokenBalanceRecord rows")
    }

    @Test("balance-card total backfills legacy relation-only token rows")
    func totalUsesLegacyRelationOnlyTokenRows() async throws {
        let container = try TestModelContainerFactory.makeContainer(name: "balance-card-legacy-token-source")
        let context = ModelContext(container)
        let wallet = WalletRecord(
            name: "Legacy Source Truth",
            kind: .watchOnly,
            mnemonicWordCount: nil,
            hasPassphrase: false,
            colorTag: "default",
            sortOrder: 0,
            requiresBackup: false
        )
        context.insert(wallet)

        let ethereum = WalletAddressRecord(chainRaw: "ethereum", address: "0xlegacy")
        ethereum.wallet = wallet
        ethereum.walletId = wallet.id
        context.insert(ethereum)

        let balance = TokenBalanceRecord(
            tokenSymbol: "ETH",
            decimals: 18,
            rawBalance: "1000000000000000000",
            fiatValueCached: 123,
            fiatCurrencyCode: "USD"
        )
        balance.address = ethereum
        // Simulates rows written before the scalar addressId column was
        // populated. The wallet list resolves address?.id; the balance card
        // snapshot must do the same and backfill the scalar id.
        balance.addressId = nil
        context.insert(balance)
        try context.save()

        let snapshot = try await WalletBalanceCardSnapshotRepository(modelContainer: container)
            .rebuild(
                walletId: wallet.id,
                currencyCode: "USD",
                selectedRangeRaw: BalanceHistoryRange.all.rawValue,
                isBalanceHidden: false,
                now: Date()
            )

        #expect(snapshot.totalFiat == 123)

        let stored = try #require(try context.fetch(FetchDescriptor<TokenBalanceRecord>()).first)
        #expect(stored.addressId == ethereum.id)
    }

    @Test("balance-card total backfills legacy relation-only wallet addresses")
    func totalUsesLegacyRelationOnlyWalletAddresses() async throws {
        let container = try TestModelContainerFactory.makeContainer(name: "balance-card-legacy-wallet-address")
        let context = ModelContext(container)
        let wallet = WalletRecord(
            name: "Legacy Address Owner",
            kind: .watchOnly,
            mnemonicWordCount: nil,
            hasPassphrase: false,
            colorTag: "default",
            sortOrder: 0,
            requiresBackup: false
        )
        context.insert(wallet)

        let ethereum = WalletAddressRecord(chainRaw: "ethereum", address: "0xowner")
        ethereum.wallet = wallet
        ethereum.walletId = nil
        context.insert(ethereum)

        let balance = TokenBalanceRecord(
            tokenSymbol: "ETH",
            decimals: 18,
            rawBalance: "1000000000000000000",
            fiatValueCached: 234,
            fiatCurrencyCode: "USD"
        )
        balance.address = ethereum
        balance.addressId = ethereum.id
        context.insert(balance)
        try context.save()

        let snapshot = try await WalletBalanceCardSnapshotRepository(modelContainer: container)
            .rebuild(
                walletId: wallet.id,
                currencyCode: "USD",
                selectedRangeRaw: BalanceHistoryRange.all.rawValue,
                isBalanceHidden: false,
                now: Date()
            )

        #expect(snapshot.totalFiat == 234)

        let storedAddress = try #require(try context.fetch(FetchDescriptor<WalletAddressRecord>()).first)
        #expect(storedAddress.walletId == wallet.id)
    }

    @Test("balance-card total reprices stale fiat rows from cached prices")
    func totalRepricesStaleFiatRowsFromCachedPrices() async throws {
        let container = try TestModelContainerFactory.makeContainer(name: "balance-card-stale-fiat-reprice")
        let context = ModelContext(container)
        let wallet = WalletRecord(
            name: "Stale Fiat",
            kind: .watchOnly,
            mnemonicWordCount: nil,
            hasPassphrase: false,
            colorTag: "default",
            sortOrder: 0,
            requiresBackup: false
        )
        context.insert(wallet)

        let ethereum = WalletAddressRecord(chainRaw: "ethereum", address: "0xstale")
        ethereum.wallet = wallet
        ethereum.walletId = wallet.id
        context.insert(ethereum)

        let balance = TokenBalanceRecord(
            tokenSymbol: "ETH",
            decimals: 18,
            rawBalance: "1000000000000000000",
            fiatValueCached: 700,
            fiatCurrencyCode: "JOD"
        )
        balance.address = ethereum
        balance.addressId = ethereum.id
        context.insert(balance)
        context.insert(CachedPriceRecord(symbol: "ETH", fiat: "USD", price: 2_000, source: "test"))
        try context.save()

        let snapshot = try await WalletBalanceCardSnapshotRepository(modelContainer: container)
            .rebuild(
                walletId: wallet.id,
                currencyCode: "USD",
                selectedRangeRaw: BalanceHistoryRange.all.rawValue,
                isBalanceHidden: false,
                now: Date()
            )

        #expect(snapshot.totalFiat == 2_000)
    }
}
