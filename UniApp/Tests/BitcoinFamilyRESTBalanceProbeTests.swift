import Foundation
import SwiftData
import Testing
@testable import Aperture

@Suite("Litecoin and Dogecoin REST balance + history probes")
struct BitcoinFamilyRESTBalanceProbeTests {
    private let litecoinAddress = "LfdYLbP9F9CpmCX6atZnHZb8KkS8T6x4DK"
    private let dogecoinAddress = "DQRbHnaudLZcphCQZAD8sKRVw53mNcbg6t"

    @Test("Litecoin provider returns balance and activity")
    func litecoinLiveRead() async throws {
        let scanner = BitcoinFamilyRESTBalanceScanner()
        let start = ContinuousClock.now

        async let snapshotTask = scanner.accountSnapshot(address: litecoinAddress, chain: .litecoin)
        async let eventsTask = scanner.recentEvents(address: litecoinAddress, chain: .litecoin)

        let snapshot = try await snapshotTask
        let events = try await eventsTask
        let elapsed = start.duration(to: .now)

        #expect(Decimal(string: snapshot.rawBalance) ?? 0 > 0)
        #expect(snapshot.isUsed)
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { !$0.txHash.isEmpty && Decimal(string: $0.amount) != nil })
        #expect(elapsed < .seconds(20), "Litecoin probe should stay responsive; elapsed \(elapsed)")

        print("[LTCProbe] address=\(litecoinAddress) raw=\(snapshot.rawBalance) events=\(events.count) elapsed=\(elapsed)")
    }

    @Test("Dogecoin provider returns balance and activity")
    func dogecoinLiveRead() async throws {
        let scanner = BitcoinFamilyRESTBalanceScanner()
        let start = ContinuousClock.now

        async let snapshotTask = scanner.accountSnapshot(address: dogecoinAddress, chain: .dogecoin)
        async let eventsTask = scanner.recentEvents(address: dogecoinAddress, chain: .dogecoin)

        let snapshot = try await snapshotTask
        let events = try await eventsTask
        let elapsed = start.duration(to: .now)

        #expect(Decimal(string: snapshot.rawBalance) ?? 0 > 0)
        #expect(snapshot.isUsed)
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { !$0.txHash.isEmpty && Decimal(string: $0.amount) != nil })
        #expect(elapsed < .seconds(20), "Dogecoin probe should stay responsive; elapsed \(elapsed)")

        print("[DOGEProbe] address=\(dogecoinAddress) raw=\(snapshot.rawBalance) events=\(events.count) elapsed=\(elapsed)")
    }

    @Test("Production REST scanner persists Litecoin and Dogecoin rows")
    func productionScannerPersistsBalancesAndHistory() async throws {
        let container = try TestModelContainerFactory.makeContainer(name: "bitcoin-family-rest-production")
        let context = ModelContext(container)
        let wallet = WalletRecord(
            name: "REST Probe",
            kind: .watchOnly,
            mnemonicWordCount: nil,
            hasPassphrase: false,
            colorTag: "default",
            sortOrder: 0,
            requiresBackup: false
        )
        let ltc = WalletAddressRecord(chainRaw: SupportedChain.litecoin.rawValue, address: litecoinAddress)
        let doge = WalletAddressRecord(chainRaw: SupportedChain.dogecoin.rawValue, address: dogecoinAddress)
        ltc.wallet = wallet
        doge.wallet = wallet
        context.insert(wallet)
        context.insert(ltc)
        context.insert(doge)
        try context.save()

        let scanner = BitcoinFamilyRESTBalanceScanner()
        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await scanner.scanAndPersist(
                    walletId: wallet.id,
                    address: WalletRepository.AddressSnapshot(
                        id: ltc.id,
                        chain: .litecoin,
                        address: self.litecoinAddress
                    ),
                    currencyCode: "USD",
                    modelContainer: container
                )
            }
            group.addTask {
                try await scanner.scanAndPersist(
                    walletId: wallet.id,
                    address: WalletRepository.AddressSnapshot(
                        id: doge.id,
                        chain: .dogecoin,
                        address: self.dogecoinAddress
                    ),
                    currencyCode: "USD",
                    modelContainer: container
                )
            }
            try await group.waitForAll()
        }
        let elapsed = start.duration(to: .now)

        let ltcId = ltc.id
        let dogeId = doge.id
        let balances = try context.fetch(FetchDescriptor<TokenBalanceRecord>())
        let txs = try context.fetch(FetchDescriptor<TransactionRecord>())
        let ltcBalance = try #require(balances.first { $0.addressId == ltcId && $0.tokenSymbol == "LTC" })
        let dogeBalance = try #require(balances.first { $0.addressId == dogeId && $0.tokenSymbol == "DOGE" })

        #expect(Decimal(string: ltcBalance.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: dogeBalance.rawBalance) ?? 0 > 0)
        #expect(txs.contains { $0.addressId == ltcId })
        #expect(txs.contains { $0.addressId == dogeId })
        #expect(elapsed < .seconds(25), "Production REST scan should stay responsive; elapsed \(elapsed)")

        print("[RESTProbe] balances=\(balances.count) txs=\(txs.count) elapsed=\(elapsed)")
    }
}
