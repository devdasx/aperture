import Testing
import Foundation
import SwiftData
@testable import Aperture

/// **End-to-end PERSISTENCE test for the per-chain connector split.**
///
/// The 24 `*ConnectorTests` prove each chain's connector FETCHES real
/// on-chain balance + history. This suite proves the second half the
/// user asked for — that fetched data flows through the REAL refresh
/// pipeline and actually LANDS in SwiftData, then reads back through the
/// exact query surface the wallet UI's `@Query` uses.
///
/// The path under test is the full production sink:
///
///   ChainConnector (per-chain)
///     → RealRPCBalanceScanner.streamScan / RealRPCTransactionScanner.scan
///       → WalletRefreshCoordinator.refreshWallet
///         → TransactionRepository.upsertBalance / upsertTransaction
///           → SwiftData
///             → TransactionRepository.transactions(walletId:) + address.balances
///
/// It seeds an in-memory `ModelContainer` with a watch-only wallet
/// pointing at a permanently-funded public address, drives the real
/// `refreshWallet`, and asserts the rows persisted. This exercises the
/// connector→coordinator→DB seam a green build cannot: a connector that
/// emitted a `TransactionEvent` / `TokenBalance` shape the upsert dedup
/// rejected would compile fine yet fail here.
///
/// `.serialized` so the two real-network refreshes don't contend on the
/// shared `RPCClient.shared` rate limiter / circuit breakers.
@Suite(.serialized)
struct RefreshPipelinePersistenceTests {

    // Permanently-funded, high-history PUBLIC addresses (watch-only — no
    // seed material; the pipeline only ever reads).
    //
    // vitalik.eth — large, always-positive ETH balance + many ERC-20s.
    static let ethAddress = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
    // Bitcoin genesis (Satoshi) — non-zero balance, thousands of inbound txs.
    static let btcAddress = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"

    // MARK: - Fixture (proven in-memory idiom — SyncStatusRepositoryTests)

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(ApertureSchemaV1.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Seed one watch-only wallet with a single address on `chain`, save,
    /// and return the wallet id the coordinator refreshes by.
    private func seedWallet(
        _ container: ModelContainer,
        chain: SupportedChain,
        address: String
    ) throws -> UUID {
        let context = ModelContext(container)
        let wallet = WalletRecord(
            name: "Persistence Test",
            kind: .watchOnly,
            mnemonicWordCount: nil,
            hasPassphrase: false,
            colorTag: "default",
            sortOrder: 0,
            requiresBackup: false
        )
        context.insert(wallet)
        let addr = WalletAddressRecord(chainRaw: chain.rawValue, address: address)
        addr.wallet = wallet
        context.insert(addr)
        try context.save()
        return wallet.id
    }

    /// All persisted balance rows for the wallet, read from a FRESH
    /// context — the same way the UI's `@Query` sees committed rows.
    private func balanceRows(_ container: ModelContainer, walletId: UUID) -> [TokenBalanceRecord] {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        descriptor.fetchLimit = 1
        guard let wallet = try? context.fetch(descriptor).first else { return [] }
        return wallet.addresses.flatMap { $0.balances }
    }

    // MARK: - EVM family (native + token persistence + EVM contract seam)

    @Test("Ethereum: real refresh persists native ETH balance into SwiftData")
    func ethereumRefreshPersistsBalance() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .ethereum, address: Self.ethAddress)

        await WalletRefreshCoordinator(container: container)
            .refreshWallet(walletId: walletId, fiatCode: "USD", userInitiated: true)

        let rows = balanceRows(container, walletId: walletId)
        let native = rows.first {
            $0.tokenContract == nil && $0.tokenSymbol == SupportedChain.ethereum.ticker
        }
        let nativeRow = try #require(native, "no native ETH balance row persisted after refresh")
        let amount = Decimal(string: nativeRow.rawBalance) ?? 0
        #expect(amount > 0, "vitalik.eth native balance persisted as \"\(nativeRow.rawBalance)\" (expected > 0)")
    }

    // MARK: - UTXO family (native + transaction-history persistence seam)

    @Test("Bitcoin: real refresh persists native BTC balance + transaction history into SwiftData")
    func bitcoinRefreshPersistsBalanceAndHistory() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .bitcoin, address: Self.btcAddress)

        await WalletRefreshCoordinator(container: container)
            .refreshWallet(walletId: walletId, fiatCode: "USD", userInitiated: true)

        // Native BTC balance row persisted, positive.
        let rows = balanceRows(container, walletId: walletId)
        let native = rows.first {
            $0.tokenContract == nil && $0.tokenSymbol == SupportedChain.bitcoin.ticker
        }
        let nativeRow = try #require(native, "no native BTC balance row persisted after refresh")
        #expect((Decimal(string: nativeRow.rawBalance) ?? 0) > 0,
                "BTC genesis balance persisted as \"\(nativeRow.rawBalance)\" (expected > 0)")

        // Transaction history persisted AND readable through the exact
        // query surface the wallet UI drives (`transactions(walletId:)`).
        let txRepo = TransactionRepository(modelContainer: container)
        let txs = try await txRepo.transactions(walletId: walletId)
        #expect(!txs.isEmpty, "BTC genesis transaction history did not persist / read back")
    }
}
