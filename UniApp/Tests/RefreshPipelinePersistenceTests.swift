import Testing
import Foundation
import SwiftData
@testable import Aperture

/// **SwiftData persistence tests for the storage layer.**
///
/// The data-fetching layer (connectors, scanners, refresh coordinator) was
/// removed on 2026-06-25, so this suite no longer drives a live refresh. What
/// remains exercises the storage seams a green build cannot, all against an
/// isolated temporary SQLite `ModelContainer`:
///   - UTXO snapshot persistence (`ChainStateRepository.replaceUTXOs` —
///     snapshot semantics, spent outputs dropped on replace).
///   - Targeted `ChainStateRepository.rebuild` isolation + cross-`@ModelActor`
///     fiat-staleness read-back through the wallet UI's `@Query` surface.
///   - `ChainKeyVault` round-trip + the encrypted key-blob storage path.
@Suite(.serialized)
struct RefreshPipelinePersistenceTests {

    // Permanently-funded, high-history PUBLIC addresses (watch-only — no
    // seed material; the pipeline only ever reads).
    static let suiAddress = "0x935029ca5219502a47ac9b69f556ccf6e2198b5e7815cf50f68846f723739cbd"
    static let ethAddress = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
    static let btcAddress = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"

    // MARK: - Fixture

    private func makeContainer() throws -> ModelContainer {
        try TestModelContainerFactory.makeContainer()
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

    // MARK: - UTXO persistence (deterministic — the genesis address can't)

    @Test("UTXO persistence: replaceUTXOs stores a snapshot and drops spent outputs")
    func utxoPersistenceStoresSnapshot() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .bitcoin, address: Self.btcAddress)
        let repo = ChainStateRepository(modelContainer: container)

        let utxos = [
            SelectedUTXO(txid: "aa00", vout: 0, valueSats: 100_000, scriptHex: nil, confirmed: true),
            SelectedUTXO(txid: "bb11", vout: 1, valueSats: 250_000, scriptHex: "76a914", confirmed: true),
        ]
        let written = try await repo.replaceUTXOs(
            walletId: walletId, chain: .bitcoin, address: Self.btcAddress, utxos: utxos
        )
        #expect(written.count == 2)
        #expect(written.totalSats == 350_000)

        let context = ModelContext(container)
        var descriptor = FetchDescriptor<ChainUTXORecord>(
            predicate: #Predicate { $0.walletId == walletId && $0.chainRaw == "bitcoin" }
        )
        #expect(try context.fetch(descriptor).count == 2)

        // Snapshot semantics: replacing with a smaller set (one spent) must
        // drop the stale output, not accumulate.
        _ = try await repo.replaceUTXOs(
            walletId: walletId, chain: .bitcoin, address: Self.btcAddress, utxos: [utxos[0]]
        )
        let freshContext = ModelContext(container)
        descriptor = FetchDescriptor<ChainUTXORecord>(
            predicate: #Predicate { $0.walletId == walletId && $0.chainRaw == "bitcoin" }
        )
        let after = try freshContext.fetch(descriptor)
        #expect(after.count == 1, "replaceUTXOs must drop spent outputs (snapshot semantics)")
        #expect(after.first?.valueSats == 100_000)
    }

    // MARK: - Live per-chain commit (targeted rebuild)

    /// The per-chain live-refresh path commits a single chain at a time via
    /// `rebuild(onlyChains:)`. This proves a targeted rebuild touches ONLY
    /// the requested chain's aggregate row and leaves siblings untouched —
    /// so Ethereum's balance landing can't disturb Bitcoin's row, and a
    /// chain whose data hasn't landed yet doesn't get a premature row.
    @Test("rebuild(onlyChains:) updates only the targeted chain's row")
    func targetedRebuildTouchesOnlyRequestedChain() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let wallet = WalletRecord(
            name: "Targeted", kind: .watchOnly, mnemonicWordCount: nil,
            hasPassphrase: false, colorTag: "default", sortOrder: 0, requiresBackup: false
        )
        context.insert(wallet)
        let suiAddr = WalletAddressRecord(chainRaw: SupportedChain.sui.rawValue, address: "0xsui")
        suiAddr.wallet = wallet
        context.insert(suiAddr)
        let nearAddr = WalletAddressRecord(chainRaw: SupportedChain.near.rawValue, address: "near")
        nearAddr.wallet = wallet
        context.insert(nearAddr)
        try context.save()
        let walletId = wallet.id

        // Stage a native SUI balance row.
        let txRepo = TransactionRepository(modelContainer: container)
        try await txRepo.upsertBalance(
            addressId: suiAddr.id, tokenSymbol: SupportedChain.sui.ticker,
            tokenContract: nil, decimals: 0, rawBalance: "1.5",
            fiatValueCached: 3000, fiatCurrencyCode: "USD"
        )

        let repo = ChainStateRepository(modelContainer: container)
        // Rebuild ONLY Sui.
        try await repo.rebuild(walletId: walletId, fiatCurrencyCode: "USD", onlyChains: [.sui])
        let sui = try await repo.chainState(walletId: walletId, chain: .sui)
        let near = try await repo.chainState(walletId: walletId, chain: .near)
        #expect(sui != nil, "sui row should exist after a targeted sui rebuild")
        #expect((sui.map { Decimal(string: $0.nativeBalanceRaw) ?? 0 } ?? 0) > 0,
                "sui row should carry the staged balance")
        #expect(near == nil, "near row must NOT be created by a sui-only rebuild")

        // Rebuild ONLY Near → its row appears now.
        try await repo.rebuild(walletId: walletId, fiatCurrencyCode: "USD", onlyChains: [.near])
        let near2 = try await repo.chainState(walletId: walletId, chain: .near)
        #expect(near2 != nil, "near row should exist after a targeted near rebuild")
    }

    // MARK: - Balance-$0 regression (cross-@ModelActor fiat staleness)

    /// Reproduces the "balance shows $0" bug: `ChainStateRepository` (one
    /// `@ModelActor`) must read the fiat that `TransactionRepository` (a
    /// DIFFERENT `@ModelActor`) committed. The pre-fix code cached the balance
    /// row at fiat=0 during the first rebuild and never saw the later priced
    /// write, so `ChainStateRecord.totalFiat` stayed 0 even though the price
    /// had landed. Deterministic — no network/pricing dependency.
    @Test("rebuild re-reads fiat a sibling context committed (balance-​$0 regression)")
    func rebuildReadsSiblingContextFiat() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .sui, address: Self.suiAddress)

        let context = ModelContext(container)
        var descriptor = FetchDescriptor<WalletRecord>(predicate: #Predicate { $0.id == walletId })
        descriptor.fetchLimit = 1
        let addressId = try #require(try context.fetch(descriptor).first?.addresses.first?.id)

        let txRepo = TransactionRepository(modelContainer: container)
        let chainRepo = ChainStateRepository(modelContainer: container)
        let chain = SupportedChain.sui

        // 1) The nil-fiat phase: a balance row exists at fiat 0.
        try await txRepo.upsertBalance(
            addressId: addressId, tokenSymbol: chain.ticker, tokenContract: nil,
            decimals: 0, rawBalance: "2.0", fiatValueCached: 0, fiatCurrencyCode: "USD"
        )
        // 2) First rebuild — chainRepo's context caches the row at fiat 0.
        try await chainRepo.rebuild(walletId: walletId, fiatCurrencyCode: "USD")
        let before = try await chainRepo.chainState(walletId: walletId, chain: chain)
        #expect(before?.totalFiat == 0, "sanity: fiat not priced yet")

        // 3) The priced re-yield: txRepo (sibling context) updates the SAME row.
        try await txRepo.upsertBalance(
            addressId: addressId, tokenSymbol: chain.ticker, tokenContract: nil,
            decimals: 0, rawBalance: "2.0", fiatValueCached: 5000, fiatCurrencyCode: "USD"
        )
        // 4) Second rebuild MUST see the new fiat (the bug: it read a stale 0).
        try await chainRepo.rebuild(walletId: walletId, fiatCurrencyCode: "USD")
        let after = try #require(try await chainRepo.chainState(walletId: walletId, chain: chain))
        #expect(after.totalFiat == 5000, "rebuild must re-read sibling-committed fiat — got \(after.totalFiat)")
        #expect(after.nativeFiat == 5000)
    }

    // MARK: - Encryption (the user-chosen "encrypted key blob in DB" path)

    @Test("ChainKeyVault seals and opens a private key losslessly")
    func chainKeyVaultRoundTrips() throws {
        let rawKey = Data(repeating: 0xAB, count: 32)
        let sealed = try ChainKeyVault.seal(rawKey)
        #expect(sealed != rawKey, "ciphertext must differ from plaintext")
        let opened = try ChainKeyVault.open(sealed)
        #expect(opened == rawKey, "AES-GCM round-trip must return the original key")
    }

    @Test("ChainStateRepository stores an encrypted key blob into the chain row")
    func encryptedKeyBlobStoredAndFlagged() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .ethereum, address: Self.ethAddress)
        let blob = try ChainKeyVault.seal(Data(repeating: 0xCD, count: 32))

        let repo = ChainStateRepository(modelContainer: container)
        try await repo.storeEncryptedKeys(walletId: walletId, blobs: [.ethereum: blob])

        let state = try await repo.chainState(walletId: walletId, chain: .ethereum)
        #expect(state?.hasEncryptedKey == true, "encrypted key blob did not persist into the chain row")

        // The chain is no longer reported as missing a key.
        let missing = try await repo.chainsMissingKey(walletId: walletId, candidates: [.ethereum])
        #expect(!missing.contains(.ethereum), "chain still reported as missing a key after store")
    }
}
