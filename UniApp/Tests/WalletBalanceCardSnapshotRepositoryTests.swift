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
}
