import Foundation
import SwiftData
import Testing
@testable import Aperture

@Suite("Sui balance + history probe")
struct SuiBalanceHistoryProbeTests {
    private static let richAddress = "0x935029ca5219502a47ac9b69f556ccf6e2198b5e7815cf50f68846f723739cbd"

    @Test("Sui native balance, supported coin balance, and history live read")
    func suiBalanceHistoryLiveRead() async throws {
        let client = SuiBalanceHistoryClient()
        let start = ContinuousClock.now

        async let snapshotTask = client.accountSnapshot(
            address: Self.richAddress,
            supportedTokens: SuiTokenRegistry.tokens
        )
        async let eventsTask = client.recentEvents(
            address: Self.richAddress,
            supportedTokens: SuiTokenRegistry.tokens
        )

        let snapshot = try await snapshotTask
        let events = try await eventsTask
        let elapsed = start.duration(to: ContinuousClock.now)

        #expect(Decimal(string: snapshot.rawSUI) ?? 0 > 0, "known Sui account should hold native SUI")
        let usdc = try #require(snapshot.tokenBalances.first { $0.entry.symbol == "USDC" })
        #expect(Decimal(string: usdc.rawBalance) ?? 0 > 0, "known Sui account should hold native Circle USDC")
        #expect(events.contains { $0.tokenSymbol == SupportedChain.sui.ticker }, "history should include native SUI balance changes")
        #expect(events.contains { $0.tokenSymbol == "USDC" }, "history should include supported Sui USDC balance changes")
        #expect(events.allSatisfy { !$0.txHash.isEmpty && !$0.amount.isEmpty }, "history rows should be persisted-ready")
        #expect(elapsed < .seconds(20), "Sui balance/history probe should stay responsive; elapsed \(elapsed)")

        print("""
        [SuiProbe] account=\(Self.richAddress) elapsed=\(elapsed)
        [SuiProbe] rawSUI=\(snapshot.rawSUI)
        [SuiProbe] tokenBalances=\(snapshot.tokenBalances.map { "\($0.entry.symbol)=\($0.rawBalance)" }.joined(separator: ","))
        [SuiProbe] events=\(events.count) native=\(events.filter { $0.tokenContract == nil }.count) tokens=\(events.filter { $0.tokenContract != nil }.count)
        """)
    }

    @Test("Production Sui scanner persists native and supported coin rows")
    func productionSuiScannerPersistsBalancesAndHistory() async throws {
        let container = try TestModelContainerFactory.makeContainer(name: "sui-production-scan")
        let context = ModelContext(container)
        let wallet = WalletRecord(
            name: "Sui Probe",
            kind: .watchOnly,
            mnemonicWordCount: nil,
            hasPassphrase: false,
            colorTag: "default",
            sortOrder: 0,
            requiresBackup: false
        )
        let address = WalletAddressRecord(chainRaw: SupportedChain.sui.rawValue, address: Self.richAddress)
        address.wallet = wallet
        context.insert(wallet)
        context.insert(address)
        try context.save()

        let scanner = SuiBalanceHistoryScanner()
        let start = ContinuousClock.now
        try await scanner.scanAndPersist(
            walletId: wallet.id,
            address: WalletRepository.AddressSnapshot(
                id: address.id,
                chain: .sui,
                address: Self.richAddress
            ),
            currencyCode: "USD",
            modelContainer: container
        )
        let elapsed = start.duration(to: ContinuousClock.now)

        let addressId = address.id
        let balances = try context.fetch(FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        let txs = try context.fetch(FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))

        let native = try #require(balances.first { $0.tokenSymbol == SupportedChain.sui.ticker && $0.tokenContract == nil })
        let usdc = try #require(balances.first { $0.tokenSymbol == "USDC" && $0.tokenContract == SuiTokenRegistry.tokens.first?.coinType })
        #expect(native.decimals == SupportedChain.sui.nativeDecimals)
        #expect(usdc.decimals == 6)
        #expect(Decimal(string: native.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdc.rawBalance) ?? 0 > 0)
        #expect(!txs.isEmpty)
        #expect(txs.contains { $0.tokenSymbol == "USDC" })
        #expect(elapsed < .seconds(25), "Sui production scanner should stay responsive; elapsed \(elapsed)")

        print("[SuiProbe] production persisted balances=\(balances.count) txs=\(txs.count) elapsed=\(elapsed)")
    }
}
