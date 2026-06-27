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
    static let stellarAddress = "GB3FQB7JYQ37PVYL3DE7ZWYMQCDXZFQBLA23HHJOYA3MIOHCSLT3BCYY"

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

    @Test("Ethereum refresh persists ETH plus supported ERC-20 balances from PublicNode")
    func ethereumPublicNodeRefreshPersistsBalances() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .ethereum, address: "0x742d35Cc6634C0532925a3b844Bc454e4438f44e")

        await WalletDataRefreshCoordinator.shared.refresh(
            walletId: walletId,
            currencyCode: "USD",
            modelContainer: container,
            userInitiated: true
        )

        let context = ModelContext(container)
        var walletDescriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        walletDescriptor.fetchLimit = 1
        let addressId = try #require(try context.fetch(walletDescriptor).first?.addresses.first?.id)

        let balances = try context.fetch(FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        let bySymbol = Dictionary(grouping: balances, by: { $0.tokenSymbol.uppercased() })
        let expectedCount = EVMTokenRegistry.tokens(for: .ethereum).count + 1
        #expect(balances.count == expectedCount, "expected ETH plus every supported Ethereum ERC-20 row")

        let eth = try #require(bySymbol["ETH"]?.first)
        let usdc = try #require(bySymbol["USDC"]?.first)
        let usdt = try #require(bySymbol["USDT"]?.first)
        #expect(eth.tokenContract == nil)
        #expect(eth.decimals == SupportedChain.ethereum.nativeDecimals)
        #expect(Decimal(string: eth.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdc.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdt.rawBalance) ?? 0 > 0)

        let chainRepo = ChainStateRepository(modelContainer: container)
        let state = try #require(try await chainRepo.chainState(walletId: walletId, chain: .ethereum))
        #expect(state.syncStateRaw == ChainSyncState.synced.rawValue)
        #expect(state.tokenCount > 0)
        #expect(Decimal(string: state.nativeBalanceRaw) ?? 0 > 0)
    }

    @Test("Stellar refresh persists XLM balance and payment history from Horizon")
    func stellarHorizonRefreshPersistsBalanceAndHistory() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .stellar, address: Self.stellarAddress)

        await WalletDataRefreshCoordinator.shared.refresh(
            walletId: walletId,
            currencyCode: "USD",
            modelContainer: container,
            userInitiated: true
        )

        let context = ModelContext(container)
        var walletDescriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        walletDescriptor.fetchLimit = 1
        let addressId = try #require(try context.fetch(walletDescriptor).first?.addresses.first?.id)

        let balances = try context.fetch(FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        let xlm = try #require(balances.first { $0.tokenSymbol.uppercased() == "XLM" })
        #expect(xlm.tokenContract == nil)
        #expect(xlm.decimals == SupportedChain.stellar.nativeDecimals)
        #expect(Decimal(string: xlm.rawBalance) ?? 0 > 0)

        let transactions = try context.fetch(FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        #expect(!transactions.isEmpty, "expected recent native Stellar payment rows")
        #expect(transactions.contains { $0.tokenSymbol.uppercased() == "XLM" })
        #expect(transactions.contains { $0.statusRaw == TransactionStatus.confirmed.rawValue })

        let chainRepo = ChainStateRepository(modelContainer: container)
        let state = try #require(try await chainRepo.chainState(walletId: walletId, chain: .stellar))
        #expect(state.syncStateRaw == ChainSyncState.synced.rawValue)
        #expect(Decimal(string: state.nativeBalanceRaw) ?? 0 > 0)
    }

    @Test("Arbitrum refresh persists ETH plus supported ERC-20 balances from PublicNode")
    func arbitrumPublicNodeRefreshPersistsBalances() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .arbitrum, address: "0xF977814e90dA44bFA03b6295A0616a897441aceC")

        await WalletDataRefreshCoordinator.shared.refresh(
            walletId: walletId,
            currencyCode: "USD",
            modelContainer: container,
            userInitiated: true
        )

        let context = ModelContext(container)
        var walletDescriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        walletDescriptor.fetchLimit = 1
        let addressId = try #require(try context.fetch(walletDescriptor).first?.addresses.first?.id)

        let balances = try context.fetch(FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        let bySymbol = Dictionary(grouping: balances, by: { $0.tokenSymbol.uppercased() })
        let expectedCount = EVMTokenRegistry.tokens(for: .arbitrum).count + 1
        #expect(balances.count == expectedCount, "expected ETH plus every supported Arbitrum ERC-20 row")

        let eth = try #require(bySymbol["ETH"]?.first)
        let usdc = try #require(bySymbol["USDC"]?.first)
        let usdt = try #require(bySymbol["USDT"]?.first)
        let weth = try #require(bySymbol["WETH"]?.first)
        #expect(eth.tokenContract == nil)
        #expect(eth.decimals == SupportedChain.arbitrum.nativeDecimals)
        #expect(Decimal(string: eth.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdc.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdt.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: weth.rawBalance) ?? 0 > 0)
        #expect(bySymbol["DAI"]?.first != nil)
        #expect(bySymbol["USD0"]?.first != nil)
        #expect(bySymbol["USDAI"]?.first != nil)
        #expect(bySymbol["USDE"]?.first != nil)
        #expect(bySymbol["WBTC"]?.first != nil)

        let chainRepo = ChainStateRepository(modelContainer: container)
        let state = try #require(try await chainRepo.chainState(walletId: walletId, chain: .arbitrum))
        #expect(state.syncStateRaw == ChainSyncState.synced.rawValue)
        #expect(state.tokenCount > 0)
        #expect(Decimal(string: state.nativeBalanceRaw) ?? 0 > 0)
    }

    @Test("Base refresh persists ETH plus supported ERC-20 balances from PublicNode")
    func basePublicNodeRefreshPersistsBalances() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .base, address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")

        await WalletDataRefreshCoordinator.shared.refresh(
            walletId: walletId,
            currencyCode: "USD",
            modelContainer: container,
            userInitiated: true
        )

        let context = ModelContext(container)
        var walletDescriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        walletDescriptor.fetchLimit = 1
        let addressId = try #require(try context.fetch(walletDescriptor).first?.addresses.first?.id)

        let balances = try context.fetch(FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        let bySymbol = Dictionary(grouping: balances, by: { $0.tokenSymbol.uppercased() })
        let expectedCount = EVMTokenRegistry.tokens(for: .base).count + 1
        #expect(balances.count == expectedCount, "expected ETH plus every supported Base ERC-20 row")

        let eth = try #require(bySymbol["ETH"]?.first)
        let usdc = try #require(bySymbol["USDC"]?.first)
        let usdt = try #require(bySymbol["USDT"]?.first)
        let dai = try #require(bySymbol["DAI"]?.first)
        let weth = try #require(bySymbol["WETH"]?.first)
        #expect(eth.tokenContract == nil)
        #expect(eth.decimals == SupportedChain.base.nativeDecimals)
        #expect(Decimal(string: eth.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdc.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdt.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: dai.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: weth.rawBalance) ?? 0 > 0)
        #expect(bySymbol["USDS"]?.first != nil)
        #expect(bySymbol["USDE"]?.first != nil)
        #expect(bySymbol["AUSD"]?.first != nil)
        #expect(bySymbol["EURC"]?.first != nil)

        let chainRepo = ChainStateRepository(modelContainer: container)
        let state = try #require(try await chainRepo.chainState(walletId: walletId, chain: .base))
        #expect(state.syncStateRaw == ChainSyncState.synced.rawValue)
        #expect(state.tokenCount > 0)
        #expect(Decimal(string: state.nativeBalanceRaw) ?? 0 > 0)
    }

    @Test("Optimism refresh persists ETH plus supported ERC-20 balances from PublicNode")
    func optimismPublicNodeRefreshPersistsBalances() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .optimism, address: "0xF977814e90dA44bFA03b6295A0616a897441aceC")

        await WalletDataRefreshCoordinator.shared.refresh(
            walletId: walletId,
            currencyCode: "USD",
            modelContainer: container,
            userInitiated: true
        )

        let context = ModelContext(container)
        var walletDescriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        walletDescriptor.fetchLimit = 1
        let addressId = try #require(try context.fetch(walletDescriptor).first?.addresses.first?.id)

        let balances = try context.fetch(FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        let bySymbol = Dictionary(grouping: balances, by: { $0.tokenSymbol.uppercased() })
        let expectedCount = EVMTokenRegistry.tokens(for: .optimism).count + 1
        #expect(balances.count == expectedCount, "expected ETH plus every supported Optimism ERC-20 row")

        let eth = try #require(bySymbol["ETH"]?.first)
        let usdc = try #require(bySymbol["USDC"]?.first)
        let usdt = try #require(bySymbol["USDT"]?.first)
        #expect(eth.tokenContract == nil)
        #expect(eth.decimals == SupportedChain.optimism.nativeDecimals)
        #expect(Decimal(string: eth.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdc.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdt.rawBalance) ?? 0 > 0)
        #expect(bySymbol["DAI"]?.first != nil)
        #expect(bySymbol["FRAX"]?.first != nil)
        #expect(bySymbol["WBTC"]?.first != nil)
        #expect(bySymbol["WETH"]?.first != nil)

        let chainRepo = ChainStateRepository(modelContainer: container)
        let state = try #require(try await chainRepo.chainState(walletId: walletId, chain: .optimism))
        #expect(state.syncStateRaw == ChainSyncState.synced.rawValue)
        #expect(state.tokenCount > 0)
        #expect(Decimal(string: state.nativeBalanceRaw) ?? 0 > 0)
    }

    @Test("Scroll refresh persists ETH plus supported ERC-20 balances from PublicNode")
    func scrollPublicNodeRefreshPersistsBalances() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .scroll, address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")

        await WalletDataRefreshCoordinator.shared.refresh(
            walletId: walletId,
            currencyCode: "USD",
            modelContainer: container,
            userInitiated: true
        )

        let context = ModelContext(container)
        var walletDescriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        walletDescriptor.fetchLimit = 1
        let addressId = try #require(try context.fetch(walletDescriptor).first?.addresses.first?.id)

        let balances = try context.fetch(FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        let bySymbol = Dictionary(grouping: balances, by: { $0.tokenSymbol.uppercased() })
        let expectedCount = EVMTokenRegistry.tokens(for: .scroll).count + 1
        #expect(balances.count == expectedCount, "expected ETH plus every supported Scroll ERC-20 row")

        let eth = try #require(bySymbol["ETH"]?.first)
        let usdc = try #require(bySymbol["USDC"]?.first)
        #expect(eth.tokenContract == nil)
        #expect(eth.decimals == SupportedChain.scroll.nativeDecimals)
        #expect(Decimal(string: eth.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdc.rawBalance) ?? 0 > 0)
        #expect(bySymbol["USDT"]?.first != nil)

        let chainRepo = ChainStateRepository(modelContainer: container)
        let state = try #require(try await chainRepo.chainState(walletId: walletId, chain: .scroll))
        #expect(state.syncStateRaw == ChainSyncState.synced.rawValue)
        #expect(state.tokenCount > 0)
        #expect(Decimal(string: state.nativeBalanceRaw) ?? 0 > 0)
    }

    @Test("zkSync Era refresh persists ETH plus supported ERC-20 balances")
    func zkSyncEraRefreshPersistsBalances() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .zkSync, address: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")

        await WalletDataRefreshCoordinator.shared.refresh(
            walletId: walletId,
            currencyCode: "USD",
            modelContainer: container,
            userInitiated: true
        )

        let context = ModelContext(container)
        var walletDescriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        walletDescriptor.fetchLimit = 1
        let addressId = try #require(try context.fetch(walletDescriptor).first?.addresses.first?.id)

        let balances = try context.fetch(FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        let bySymbol = Dictionary(grouping: balances, by: { $0.tokenSymbol.uppercased() })
        let expectedCount = EVMTokenRegistry.tokens(for: .zkSync).count + 1
        #expect(balances.count == expectedCount, "expected ETH plus every supported zkSync Era ERC-20 row")

        let eth = try #require(bySymbol["ETH"]?.first)
        let usdc = try #require(bySymbol["USDC"]?.first)
        let usdt = try #require(bySymbol["USDT"]?.first)
        #expect(eth.tokenContract == nil)
        #expect(eth.decimals == SupportedChain.zkSync.nativeDecimals)
        #expect(Decimal(string: eth.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdc.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdt.rawBalance) ?? 0 > 0)

        let chainRepo = ChainStateRepository(modelContainer: container)
        let state = try #require(try await chainRepo.chainState(walletId: walletId, chain: .zkSync))
        #expect(state.syncStateRaw == ChainSyncState.synced.rawValue)
        #expect(state.tokenCount > 0)
        #expect(Decimal(string: state.nativeBalanceRaw) ?? 0 > 0)
    }

    @Test("Polygon refresh persists POL plus supported ERC-20 balances from PublicNode")
    func polygonPublicNodeRefreshPersistsBalances() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .polygon, address: "0xF977814e90dA44bFA03b6295A0616a897441aceC")

        await WalletDataRefreshCoordinator.shared.refresh(
            walletId: walletId,
            currencyCode: "USD",
            modelContainer: container,
            userInitiated: true
        )

        let context = ModelContext(container)
        var walletDescriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        walletDescriptor.fetchLimit = 1
        let addressId = try #require(try context.fetch(walletDescriptor).first?.addresses.first?.id)

        let balances = try context.fetch(FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        let bySymbol = Dictionary(grouping: balances, by: { $0.tokenSymbol.uppercased() })
        let expectedCount = EVMTokenRegistry.tokens(for: .polygon).count + 1
        #expect(balances.count == expectedCount, "expected POL plus every supported Polygon ERC-20 row")

        let pol = try #require(bySymbol["POL"]?.first)
        let usdc = try #require(bySymbol["USDC"]?.first)
        let usdt = try #require(bySymbol["USDT"]?.first)
        let dai = try #require(bySymbol["DAI"]?.first)
        let weth = try #require(bySymbol["WETH"]?.first)
        #expect(pol.tokenContract == nil)
        #expect(pol.decimals == SupportedChain.polygon.nativeDecimals)
        #expect(Decimal(string: pol.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdc.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdt.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: dai.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: weth.rawBalance) ?? 0 > 0)
        #expect(bySymbol["AUSD"]?.first != nil)
        #expect(bySymbol["FRAX"]?.first != nil)

        let chainRepo = ChainStateRepository(modelContainer: container)
        let state = try #require(try await chainRepo.chainState(walletId: walletId, chain: .polygon))
        #expect(state.syncStateRaw == ChainSyncState.synced.rawValue)
        #expect(state.tokenCount > 0)
        #expect(Decimal(string: state.nativeBalanceRaw) ?? 0 > 0)
    }

    @Test("BNB Smart Chain refresh persists BNB plus supported BEP-20 balances from PublicNode")
    func bnbSmartChainPublicNodeRefreshPersistsBalances() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .bnbChain, address: "0x8894E0a0c962CB723c1976a4421c95949bE2D4E3")

        await WalletDataRefreshCoordinator.shared.refresh(
            walletId: walletId,
            currencyCode: "USD",
            modelContainer: container,
            userInitiated: true
        )

        let context = ModelContext(container)
        var walletDescriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        walletDescriptor.fetchLimit = 1
        let addressId = try #require(try context.fetch(walletDescriptor).first?.addresses.first?.id)

        let balances = try context.fetch(FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        let bySymbol = Dictionary(grouping: balances, by: { $0.tokenSymbol.uppercased() })
        let expectedCount = EVMTokenRegistry.tokens(for: .bnbChain).count + 1
        #expect(balances.count == expectedCount, "expected BNB plus every supported BNB Chain BEP-20 row")

        let bnb = try #require(bySymbol["BNB"]?.first)
        let usdc = try #require(bySymbol["USDC"]?.first)
        let usdt = try #require(bySymbol["USDT"]?.first)
        let dai = try #require(bySymbol["DAI"]?.first)
        let usd1 = try #require(bySymbol["USD1"]?.first)
        let usde = try #require(bySymbol["USDE"]?.first)
        let fdusd = try #require(bySymbol["FDUSD"]?.first)
        let tusd = try #require(bySymbol["TUSD"]?.first)
        let usdp = try #require(bySymbol["USDP"]?.first)
        let weth = try #require(bySymbol["WETH"]?.first)
        #expect(bnb.tokenContract == nil)
        #expect(bnb.decimals == SupportedChain.bnbChain.nativeDecimals)
        #expect(Decimal(string: bnb.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdc.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdt.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: dai.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usd1.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usde.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: fdusd.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: tusd.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdp.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: weth.rawBalance) ?? 0 > 0)
        #expect(bySymbol["USDF"]?.first != nil)
        #expect(bySymbol["DUSD"]?.first != nil)
        #expect(bySymbol["FRAX"]?.first != nil)
        #expect(bySymbol["LISUSD"]?.first != nil)

        let chainRepo = ChainStateRepository(modelContainer: container)
        let state = try #require(try await chainRepo.chainState(walletId: walletId, chain: .bnbChain))
        #expect(state.syncStateRaw == ChainSyncState.synced.rawValue)
        #expect(state.tokenCount > 0)
        #expect(Decimal(string: state.nativeBalanceRaw) ?? 0 > 0)
    }

    @Test("Avalanche refresh persists AVAX plus supported ERC-20 balances from PublicNode")
    func avalanchePublicNodeRefreshPersistsBalances() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .avalanche, address: "0x742d35Cc6634C0532925a3b844Bc454e4438f44e")

        await WalletDataRefreshCoordinator.shared.refresh(
            walletId: walletId,
            currencyCode: "USD",
            modelContainer: container,
            userInitiated: true
        )

        let context = ModelContext(container)
        var walletDescriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        walletDescriptor.fetchLimit = 1
        let addressId = try #require(try context.fetch(walletDescriptor).first?.addresses.first?.id)

        let balances = try context.fetch(FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        let bySymbol = Dictionary(grouping: balances, by: { $0.tokenSymbol.uppercased() })
        let expectedCount = EVMTokenRegistry.tokens(for: .avalanche).count + 1
        #expect(balances.count == expectedCount, "expected AVAX plus every supported Avalanche ERC-20 row")

        let avax = try #require(bySymbol["AVAX"]?.first)
        let usdc = try #require(bySymbol["USDC"]?.first)
        let usdt = try #require(bySymbol["USDT"]?.first)
        let frax = try #require(bySymbol["FRAX"]?.first)
        #expect(avax.tokenContract == nil)
        #expect(avax.decimals == SupportedChain.avalanche.nativeDecimals)
        #expect(Decimal(string: avax.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdc.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdt.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: frax.rawBalance) ?? 0 > 0)
        #expect(bySymbol["DAI"]?.first != nil)
        #expect(bySymbol["AUSD"]?.first != nil)
        #expect(bySymbol["EURC"]?.first != nil)
        #expect(bySymbol["TUSD"]?.first != nil)
        #expect(bySymbol["WBTC"]?.first != nil)
        #expect(bySymbol["WETH"]?.first != nil)

        let chainRepo = ChainStateRepository(modelContainer: container)
        let state = try #require(try await chainRepo.chainState(walletId: walletId, chain: .avalanche))
        #expect(state.syncStateRaw == ChainSyncState.synced.rawValue)
        #expect(state.tokenCount > 0)
        #expect(Decimal(string: state.nativeBalanceRaw) ?? 0 > 0)
    }

    @Test("Celo refresh persists CELO plus supported ERC-20 balances from PublicNode")
    func celoPublicNodeRefreshPersistsBalances() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .celo, address: "0x471EcE3750Da237f93B8E339c536989b8978a438")

        await WalletDataRefreshCoordinator.shared.refresh(
            walletId: walletId,
            currencyCode: "USD",
            modelContainer: container,
            userInitiated: true
        )

        let context = ModelContext(container)
        var walletDescriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        walletDescriptor.fetchLimit = 1
        let addressId = try #require(try context.fetch(walletDescriptor).first?.addresses.first?.id)

        let balances = try context.fetch(FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        let bySymbol = Dictionary(grouping: balances, by: { $0.tokenSymbol.uppercased() })
        let expectedCount = EVMTokenRegistry.tokens(for: .celo).count + 1
        #expect(balances.count == expectedCount, "expected CELO plus every supported Celo ERC-20 row")

        let celo = try #require(bySymbol["CELO"]?.first)
        let usdc = try #require(bySymbol["USDC"]?.first)
        let usdt = try #require(bySymbol["USDT"]?.first)
        #expect(celo.tokenContract == nil)
        #expect(celo.decimals == SupportedChain.celo.nativeDecimals)
        #expect(Decimal(string: celo.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdc.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdt.rawBalance) ?? 0 > 0)

        let chainRepo = ChainStateRepository(modelContainer: container)
        let state = try #require(try await chainRepo.chainState(walletId: walletId, chain: .celo))
        #expect(state.syncStateRaw == ChainSyncState.synced.rawValue)
        #expect(state.tokenCount > 0)
        #expect(Decimal(string: state.nativeBalanceRaw) ?? 0 > 0)
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

@Suite(.serialized)
struct PolkadotRefreshPipelinePersistenceTests {
    static let polkadotAddress = "13UVJyLnbVp9RBZYFwFGyDvVd1y27Tt8tkntv6Q7JVPhFsTB"

    private func makeContainer() throws -> ModelContainer {
        try TestModelContainerFactory.makeContainer()
    }

    private func seedWallet(
        _ container: ModelContainer,
        chain: SupportedChain,
        address: String
    ) throws -> UUID {
        let context = ModelContext(container)
        let wallet = WalletRecord(
            name: "Polkadot Persistence Test",
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

    @Test("Polkadot refresh persists DOT balance and native transfer history")
    func polkadotRefreshPersistsBalanceAndHistory() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .polkadot, address: Self.polkadotAddress)

        await WalletDataRefreshCoordinator.shared.refresh(
            walletId: walletId,
            currencyCode: "USD",
            modelContainer: container,
            userInitiated: true
        )

        let context = ModelContext(container)
        var walletDescriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        walletDescriptor.fetchLimit = 1
        let addressId = try #require(try context.fetch(walletDescriptor).first?.addresses.first?.id)

        let balances = try context.fetch(FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        let dot = try #require(balances.first { $0.tokenSymbol.uppercased() == "DOT" })
        #expect(dot.tokenContract == nil)
        #expect(dot.decimals == SupportedChain.polkadot.nativeDecimals)
        #expect(Decimal(string: dot.rawBalance) ?? 0 > 0)

        let transactions = try context.fetch(FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        #expect(!transactions.isEmpty, "expected recent native DOT transfer rows")
        #expect(transactions.contains { $0.tokenSymbol.uppercased() == "DOT" })
        #expect(transactions.contains { $0.statusRaw == TransactionStatus.confirmed.rawValue })

        let chainRepo = ChainStateRepository(modelContainer: container)
        let state = try #require(try await chainRepo.chainState(walletId: walletId, chain: .polkadot))
        #expect(state.syncStateRaw == ChainSyncState.synced.rawValue)
        #expect(Decimal(string: state.nativeBalanceRaw) ?? 0 > 0)
        #expect(state.txTotalCount > 0)
    }
}

@Suite(.serialized)
struct SolanaRefreshPipelinePersistenceTests {
    static let solanaHistoryAddress = "7xKXtg2CW87d8V6zXKBq7cM8Y2FPHwzaAkxqEqD7x4rH"

    private func makeContainer() throws -> ModelContainer {
        try TestModelContainerFactory.makeContainer()
    }

    private func seedWallet(
        _ container: ModelContainer,
        chain: SupportedChain,
        address: String
    ) throws -> UUID {
        let context = ModelContext(container)
        let wallet = WalletRecord(
            name: "Solana Persistence Test",
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

    @Test("Solana refresh persists SOL balance, supported SPL rows, and history")
    func solanaRefreshPersistsBalanceTokensAndHistory() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .solana, address: Self.solanaHistoryAddress)

        await WalletDataRefreshCoordinator.shared.refresh(
            walletId: walletId,
            currencyCode: "USD",
            modelContainer: container,
            userInitiated: true
        )

        let context = ModelContext(container)
        var walletDescriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        walletDescriptor.fetchLimit = 1
        let addressId = try #require(try context.fetch(walletDescriptor).first?.addresses.first?.id)

        let balances = try context.fetch(FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        let sol = try #require(balances.first { $0.tokenSymbol.uppercased() == "SOL" && $0.tokenContract == nil })
        #expect(sol.decimals == SupportedChain.solana.nativeDecimals)
        #expect(Decimal(string: sol.rawBalance) ?? 0 > 0)

        let splRows = balances.filter { $0.tokenContract != nil }
        #expect(splRows.count == SolanaTokenRegistry.mints.count)
        for mint in SolanaTokenRegistry.mints.keys {
            #expect(splRows.contains { $0.tokenContract == mint }, "missing persisted SPL row for \(mint)")
        }

        let transactions = try context.fetch(FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        #expect(transactions.contains { $0.tokenSymbol.uppercased() == "SOL" })
        #expect(transactions.contains { $0.statusRaw == TransactionStatus.confirmed.rawValue })

        let chainRepo = ChainStateRepository(modelContainer: container)
        let state = try #require(try await chainRepo.chainState(walletId: walletId, chain: .solana))
        #expect(state.syncStateRaw == ChainSyncState.synced.rawValue)
        #expect(Decimal(string: state.nativeBalanceRaw) ?? 0 > 0)
    }
}

@Suite(.serialized)
struct AptosRefreshPipelinePersistenceTests {
    static let fundedAptosAddress = "0x8c76406665dda278f99b4aa35a3d2f07b483c63e41119534924056cb1a2817b1"

    private func makeContainer() throws -> ModelContainer {
        try TestModelContainerFactory.makeContainer()
    }

    private func seedWallet(
        _ container: ModelContainer,
        chain: SupportedChain,
        address: String
    ) throws -> UUID {
        let context = ModelContext(container)
        let wallet = WalletRecord(
            name: "Aptos Persistence Test",
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

    @Test("Aptos refresh persists APT plus supported fungible asset balances")
    func aptosRefreshPersistsNativeAndTokenBalances() async throws {
        let container = try makeContainer()
        let walletId = try seedWallet(container, chain: .aptos, address: Self.fundedAptosAddress)

        await WalletDataRefreshCoordinator.shared.refresh(
            walletId: walletId,
            currencyCode: "USD",
            modelContainer: container,
            userInitiated: true
        )

        let context = ModelContext(container)
        var walletDescriptor = FetchDescriptor<WalletRecord>(
            predicate: #Predicate { $0.id == walletId }
        )
        walletDescriptor.fetchLimit = 1
        let addressId = try #require(try context.fetch(walletDescriptor).first?.addresses.first?.id)

        let balances = try context.fetch(FetchDescriptor<TokenBalanceRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        let bySymbol = Dictionary(grouping: balances, by: { $0.tokenSymbol.uppercased() })
        #expect(balances.count == AptosTokenRegistry.tokens.count + 1)

        let apt = try #require(bySymbol["APT"]?.first)
        let usdc = try #require(bySymbol["USDC"]?.first)
        let usdt = try #require(bySymbol["USDT"]?.first)
        #expect(apt.tokenContract == nil)
        #expect(apt.decimals == SupportedChain.aptos.nativeDecimals)
        #expect(Decimal(string: apt.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdc.rawBalance) ?? 0 > 0)
        #expect(Decimal(string: usdt.rawBalance) ?? 0 > 0)

        let transactions = try context.fetch(FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.addressId == addressId }
        ))
        #expect(transactions.contains { $0.tokenSymbol.uppercased() == "APT" })
        #expect(transactions.contains { $0.tokenSymbol.uppercased() == "USDC" })
        #expect(transactions.contains { $0.tokenSymbol.uppercased() == "USDT" })
        #expect(transactions.contains { $0.statusRaw == TransactionStatus.confirmed.rawValue })

        let chainRepo = ChainStateRepository(modelContainer: container)
        let state = try #require(try await chainRepo.chainState(walletId: walletId, chain: .aptos))
        #expect(state.syncStateRaw == ChainSyncState.synced.rawValue)
        #expect(state.tokenCount > 0)
        #expect(Decimal(string: state.nativeBalanceRaw) ?? 0 > 0)
    }
}
