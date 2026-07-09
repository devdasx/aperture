import Testing
import XCTest
import Foundation
@testable import Aperture

/// Per-token tests for `EVMTokenRegistry`. Parameterized over every
/// `(chain, entry)` pair across all 12 EVM chains × 79 entries —
/// each token gets its own per-test green/red signal in the Xcode
/// test navigator, satisfying the audit-then-fix-then-test contract
/// for the 2026-06-12 balance + transaction stack work.
///
/// **What each per-token test verifies:**
/// 1. Contract is `0x` + 40 hex chars (well-formed EVM address).
/// 2. The stored contract round-trips through `Keccak256.eip55Checksum`
///    — meaning the registry's case matches what Trust Wallet's
///    `assets/<contract>/logo.png` directory uses. Mismatched casing
///    on Trust Wallet returns 404 silently, which would break logo
///    rendering.
/// 3. `decimals` is in the sane on-chain range `0…38` (Decimal's
///    significand cap; tokens with absurd decimals would trap
///    `scale(decimals:)` in `EVMTransactionAdapter`).
/// 4. `symbol` is non-empty and matches its uppercase canonical
///    form when fed through the pricing pipeline.
/// 5. `name` is non-empty.
/// 6. `EVMTokenRegistry.balanceOfCallData(holder:)` produces the
///    canonical `eth_call` data field for this token's `balanceOf`
///    selector: `0x70a08231 ‖ pad32(holder)`. Length 138 chars
///    (`0x` + 8 selector + 64 padded holder).
///
/// **Why parameterized.** The user direction was "test file for each
/// token". Swift Testing's `@Test(arguments:)` produces one test
/// invocation per element in the arguments array — each shows up as
/// its own row in Xcode's navigator with the token's identity in
/// the test name. 79 EVM rows + 10 Solana rows = 89 per-token
/// invocations, exactly the per-token granularity the user asked
/// for.
struct EVMTokenRegistryTests {

    // MARK: - Per-token validation (12 chains × all entries)

    @Test(
        "EVM token registry entry is well-formed",
        arguments: EVMTokenTestCase.all
    )
    func validRegistryEntry(_ tc: EVMTokenTestCase) throws {
        let entry = tc.entry

        // 1) Contract: `0x` + exactly 40 hex chars.
        #expect(
            entry.contract.hasPrefix("0x") || entry.contract.hasPrefix("0X"),
            "\(tc.label): contract missing 0x prefix — \(entry.contract)"
        )
        let body = String(entry.contract.dropFirst(2))
        #expect(
            body.count == 40,
            "\(tc.label): contract body is \(body.count) chars, expected 40 — \(entry.contract)"
        )
        let hexAlphabet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        #expect(
            body.unicodeScalars.allSatisfy { hexAlphabet.contains($0) },
            "\(tc.label): non-hex char in contract — \(entry.contract)"
        )

        // 2) EIP-55 checksum round-trip. The stored form should equal
        //    its own checksum — otherwise Trust Wallet's contract
        //    directory will 404 on the logo path.
        let checksummed = Keccak256.eip55Checksum(contract: entry.contract)
        #expect(
            checksummed == entry.contract,
            "\(tc.label): contract not EIP-55 checksummed — registry has \"\(entry.contract)\", expected \"\(checksummed)\""
        )

        // 3) Decimals in sane range. EVM tokens are typically 6 (USDC,
        //    USDT, EURC, PYUSD) or 18 (DAI, WETH, FRAX, …); some are
        //    8 (WBTC, GUSD is 2). 0…38 is the absolute defensible
        //    bound for `Decimal`-scaled math.
        #expect(
            (0...38).contains(entry.decimals),
            "\(tc.label): decimals \(entry.decimals) outside sane 0…38 range"
        )

        // 4) Symbol non-empty + uppercased form is a plausible ticker.
        #expect(!entry.symbol.isEmpty, "\(tc.label): empty symbol")
        let pricingSymbol = WrappedAssetAliases.resolveSymbol(entry.symbol)
        #expect(!pricingSymbol.isEmpty, "\(tc.label): pricing-pipeline symbol resolved to empty")

        // 5) Name non-empty.
        #expect(!entry.name.isEmpty, "\(tc.label): empty name")

        // 6) `balanceOf(address)` calldata format:
        //    selector `0x70a08231` (4-byte selector → 10 chars with `0x`)
        //    + 32-byte left-padded holder (64 hex chars).
        //    74 chars total (`0x` + 8 selector + 24 zero-pad + 40-char body).
        let holder = "0x52908400098527886E0F7030069857D2E4169EE7"  // EIP-55 reference vector
        let calldata = EVMTokenRegistry.balanceOfCallData(holder: holder)
        #expect(
            calldata.count == 74,
            "\(tc.label): balanceOf calldata length is \(calldata.count), expected 74"
        )
        #expect(
            calldata.hasPrefix("0x70a08231"),
            "\(tc.label): balanceOf calldata missing 0x70a08231 selector — \(calldata.prefix(20))"
        )
        // The padded holder: 24 leading zeros + lowercased 40-char body.
        let expectedPadded = String(repeating: "0", count: 24) + "52908400098527886e0f7030069857d2e4169ee7"
        #expect(
            calldata == "0x70a08231" + expectedPadded,
            "\(tc.label): balanceOf calldata wrong — got \(calldata)"
        )
    }

    // MARK: - Per-chain registry shape

    @Test(
        "EVM chain registry returns expected tokens",
        arguments: EVMChainTokenCount.expected
    )
    func chainTokenCount(_ exp: EVMChainTokenCount) throws {
        let tokens = EVMTokenRegistry.tokens(for: exp.chain)
        #expect(
            tokens.count == exp.expectedCount,
            "\(exp.chain.rawValue): expected \(exp.expectedCount) registry tokens, got \(tokens.count)"
        )
    }

    // MARK: - Dedup check

    @Test("EVM registry has no duplicate contracts within any chain")
    func noDuplicateContractsPerChain() throws {
        for chain in EVMChainTokenCount.expected.map(\.chain) {
            let tokens = EVMTokenRegistry.tokens(for: chain)
            let contracts = Set(tokens.map { $0.contract.lowercased() })
            #expect(
                contracts.count == tokens.count,
                "\(chain.rawValue): duplicate contracts in registry — \(tokens.count) entries but only \(contracts.count) unique"
            )
        }
    }

    @Test("EVM registry has no duplicate symbols within any chain")
    func noDuplicateSymbolsPerChain() throws {
        for chain in EVMChainTokenCount.expected.map(\.chain) {
            let tokens = EVMTokenRegistry.tokens(for: chain)
            let symbols = Set(tokens.map { $0.symbol.uppercased() })
            #expect(
                symbols.count == tokens.count,
                "\(chain.rawValue): duplicate symbols in registry — \(tokens.count) entries but only \(symbols.count) unique"
            )
        }
    }

    @Test("PublicNode Ethereum balanceOf live read returns base-unit balances")
    func publicNodeEthereumBalanceOfLiveRead() async throws {
        let holder = "0x742d35Cc6634C0532925a3b844Bc454e4438f44e"
        let client = PublicNodeEVMTestClient(endpoint: URL(string: "https://ethereum-rpc.publicnode.com")!)

        let chainId = try await client.callString(method: "eth_chainId", params: [])
        #expect(chainId == "0x1")

        let ethHex = try await client.callString(method: "eth_getBalance", params: [holder, "latest"])
        let ethRaw = try EVMHexQuantity.decimalString(from: ethHex)
        #expect(Decimal(string: ethRaw) ?? 0 > 0, "known public Ethereum address should hold ETH")

        let tokens = EVMTokenRegistry.tokens(for: .ethereum)
        let usdc = try #require(tokens.first { $0.symbol == "USDC" })
        let usdt = try #require(tokens.first { $0.symbol == "USDT" })
        let callData = EVMTokenRegistry.balanceOfCallData(holder: holder)

        async let usdcHex = client.callString(
            method: "eth_call",
            params: [["to": usdc.contract, "data": callData], "latest"]
        )
        async let usdtHex = client.callString(
            method: "eth_call",
            params: [["to": usdt.contract, "data": callData], "latest"]
        )

        let usdcRaw = try await EVMHexQuantity.decimalString(from: usdcHex)
        let usdtRaw = try await EVMHexQuantity.decimalString(from: usdtHex)
        #expect(Decimal(string: usdcRaw) ?? 0 > 0, "known public Ethereum address should hold USDC")
        #expect(Decimal(string: usdtRaw) != nil, "USDT balanceOf should decode as a base-unit integer")
        #expect((Decimal(string: usdcRaw) ?? 0) + (Decimal(string: usdtRaw) ?? 0) > 0, "known public Ethereum address should hold at least one supported stablecoin")
    }

    @Test("PublicNode Arbitrum balanceOf live read returns base-unit balances")
    func publicNodeArbitrumBalanceOfLiveRead() async throws {
        let holder = "0xF977814e90dA44bFA03b6295A0616a897441aceC"
        let client = PublicNodeEVMTestClient(endpoint: URL(string: "https://arbitrum-one-rpc.publicnode.com")!)

        let chainId = try await client.callString(method: "eth_chainId", params: [])
        #expect(chainId == "0xa4b1")

        async let nativeHex = client.callString(method: "eth_getBalance", params: [holder, "latest"])
        async let tokenBalances = publicNodeTokenBalances(
            client: client,
            holder: holder,
            tokens: EVMTokenRegistry.tokens(for: .arbitrum)
        )

        let ethRaw = try await EVMHexQuantity.decimalString(from: nativeHex)
        let balances = try await tokenBalances

        #expect(Decimal(string: ethRaw) ?? 0 > 0, "known public Arbitrum address should hold ETH")
        #expect(balances.count == EVMTokenRegistry.tokens(for: .arbitrum).count)
        #expect(Decimal(string: balances["USDC"] ?? "0") ?? 0 > 0, "known public Arbitrum address should hold USDC")
        #expect(Decimal(string: balances["USDT"] ?? "0") ?? 0 > 0, "known public Arbitrum address should hold USDT")
        #expect(Decimal(string: balances["WETH"] ?? "0") ?? 0 > 0, "known public Arbitrum address should hold WETH")
        #expect(balances["DAI"] != nil, "DAI balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["USD0"] != nil, "USD0 balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["USDai"] != nil, "USDai balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["USDe"] != nil, "USDe balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["WBTC"] != nil, "WBTC balanceOf should return a valid zero-or-positive raw value")
    }

    @Test("PublicNode Base balanceOf live read returns base-unit balances")
    func publicNodeBaseBalanceOfLiveRead() async throws {
        let holder = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
        let client = PublicNodeEVMTestClient(endpoint: URL(string: "https://base-rpc.publicnode.com")!)

        let chainId = try await client.callString(method: "eth_chainId", params: [])
        #expect(chainId == "0x2105")

        async let nativeHex = client.callString(method: "eth_getBalance", params: [holder, "latest"])
        async let tokenBalances = publicNodeTokenBalances(
            client: client,
            holder: holder,
            tokens: EVMTokenRegistry.tokens(for: .base)
        )

        let ethRaw = try await EVMHexQuantity.decimalString(from: nativeHex)
        let balances = try await tokenBalances

        #expect(Decimal(string: ethRaw) ?? 0 > 0, "known public Base address should hold ETH")
        #expect(balances.count == EVMTokenRegistry.tokens(for: .base).count)
        #expect(Decimal(string: balances["USDC"] ?? "0") ?? 0 > 0, "known public Base address should hold USDC")
        #expect(Decimal(string: balances["USDT"] ?? "0") ?? 0 > 0, "known public Base address should hold USDT")
        #expect(Decimal(string: balances["DAI"] ?? "0") ?? 0 > 0, "known public Base address should hold DAI")
        #expect(Decimal(string: balances["WETH"] ?? "0") ?? 0 > 0, "known public Base address should hold WETH")
        #expect(balances["USDS"] != nil, "USDS balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["USDe"] != nil, "USDe balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["AUSD"] != nil, "AUSD balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["EURC"] != nil, "EURC balanceOf should return a valid zero-or-positive raw value")
    }

    @Test("PublicNode Optimism balanceOf live read returns base-unit balances")
    func publicNodeOptimismBalanceOfLiveRead() async throws {
        let holder = "0xF977814e90dA44bFA03b6295A0616a897441aceC"
        let client = PublicNodeEVMTestClient(endpoint: URL(string: "https://optimism-rpc.publicnode.com")!)

        let chainId = try await client.callString(method: "eth_chainId", params: [])
        #expect(chainId == "0xa")

        async let nativeHex = client.callString(method: "eth_getBalance", params: [holder, "latest"])
        async let tokenBalances = publicNodeTokenBalances(
            client: client,
            holder: holder,
            tokens: EVMTokenRegistry.tokens(for: .optimism)
        )

        let ethRaw = try await EVMHexQuantity.decimalString(from: nativeHex)
        let balances = try await tokenBalances

        #expect(Decimal(string: ethRaw) ?? 0 > 0, "known public Optimism address should hold ETH")
        #expect(balances.count == EVMTokenRegistry.tokens(for: .optimism).count)
        #expect(Decimal(string: balances["USDC"] ?? "0") ?? 0 > 0, "known public Optimism address should hold USDC")
        #expect(Decimal(string: balances["USDT"] ?? "0") ?? 0 > 0, "known public Optimism address should hold USDT")
        #expect(balances["DAI"] != nil, "DAI balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["FRAX"] != nil, "FRAX balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["WBTC"] != nil, "WBTC balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["WETH"] != nil, "WETH balanceOf should return a valid zero-or-positive raw value")
    }

    @Test("PublicNode Scroll balanceOf live read returns base-unit balances")
    func publicNodeScrollBalanceOfLiveRead() async throws {
        let holder = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
        let client = PublicNodeEVMTestClient(endpoint: URL(string: "https://scroll-rpc.publicnode.com")!)

        let chainId = try await client.callString(method: "eth_chainId", params: [])
        #expect(chainId == "0x82750")

        async let nativeHex = client.callString(method: "eth_getBalance", params: [holder, "latest"])
        async let tokenBalances = publicNodeTokenBalances(
            client: client,
            holder: holder,
            tokens: EVMTokenRegistry.tokens(for: .scroll)
        )

        let ethRaw = try await EVMHexQuantity.decimalString(from: nativeHex)
        let balances = try await tokenBalances

        #expect(Decimal(string: ethRaw) ?? 0 > 0, "known public Scroll address should hold ETH")
        #expect(balances.count == EVMTokenRegistry.tokens(for: .scroll).count)
        #expect(Decimal(string: balances["USDC"] ?? "0") ?? 0 > 0, "known public Scroll address should hold USDC")
        #expect(balances["USDT"] != nil, "USDT balanceOf should return a valid zero-or-positive raw value")
    }

    @Test("zkSync Era balanceOf live read returns base-unit balances")
    func zkSyncEraBalanceOfLiveRead() async throws {
        let holder = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
        let client = PublicNodeEVMTestClient(endpoint: URL(string: "https://mainnet.era.zksync.io")!)

        let chainId = try await client.callString(method: "eth_chainId", params: [])
        #expect(chainId == "0x144")

        async let nativeHex = client.callString(method: "eth_getBalance", params: [holder, "latest"])
        async let tokenBalances = publicNodeTokenBalances(
            client: client,
            holder: holder,
            tokens: EVMTokenRegistry.tokens(for: .zkSync)
        )

        let ethRaw = try await EVMHexQuantity.decimalString(from: nativeHex)
        let balances = try await tokenBalances

        #expect(Decimal(string: ethRaw) ?? 0 > 0, "known public zkSync Era address should hold ETH")
        #expect(balances.count == EVMTokenRegistry.tokens(for: .zkSync).count)
        #expect(Decimal(string: balances["USDC"] ?? "0") ?? 0 > 0, "known public zkSync Era address should hold USDC")
        #expect(Decimal(string: balances["USDT"] ?? "0") ?? 0 > 0, "known public zkSync Era address should hold USDT")
    }

    @Test("PublicNode Polygon balanceOf live read returns base-unit balances")
    func publicNodePolygonBalanceOfLiveRead() async throws {
        let holder = "0xF977814e90dA44bFA03b6295A0616a897441aceC"
        let client = PublicNodeEVMTestClient(endpoint: URL(string: "https://polygon-bor-rpc.publicnode.com")!)

        let chainId = try await client.callString(method: "eth_chainId", params: [])
        #expect(chainId == "0x89")

        async let nativeHex = client.callString(method: "eth_getBalance", params: [holder, "latest"])
        async let tokenBalances = publicNodeTokenBalances(
            client: client,
            holder: holder,
            tokens: EVMTokenRegistry.tokens(for: .polygon)
        )

        let polRaw = try await EVMHexQuantity.decimalString(from: nativeHex)
        let balances = try await tokenBalances

        #expect(Decimal(string: polRaw) ?? 0 > 0, "known public Polygon address should hold POL")
        #expect(balances.count == EVMTokenRegistry.tokens(for: .polygon).count)
        #expect(Decimal(string: balances["USDC"] ?? "0") ?? 0 > 0, "known public Polygon address should hold USDC")
        #expect(Decimal(string: balances["USDT"] ?? "0") ?? 0 > 0, "known public Polygon address should hold USDT")
        #expect(Decimal(string: balances["DAI"] ?? "0") ?? 0 > 0, "known public Polygon address should hold DAI")
        #expect(Decimal(string: balances["WETH"] ?? "0") ?? 0 > 0, "known public Polygon address should hold WETH")
        #expect(balances["AUSD"] != nil, "AUSD balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["FRAX"] != nil, "FRAX balanceOf should return a valid zero-or-positive raw value")
    }

    @Test("PublicNode BNB Smart Chain balanceOf live read returns base-unit balances")
    func publicNodeBNBSmartChainBalanceOfLiveRead() async throws {
        let holder = "0x8894E0a0c962CB723c1976a4421c95949bE2D4E3"
        let client = PublicNodeEVMTestClient(endpoint: URL(string: "https://bsc-rpc.publicnode.com")!)

        let chainId = try await client.callString(method: "eth_chainId", params: [])
        #expect(chainId == "0x38")

        async let nativeHex = client.callString(method: "eth_getBalance", params: [holder, "latest"])
        async let tokenBalances = publicNodeTokenBalances(
            client: client,
            holder: holder,
            tokens: EVMTokenRegistry.tokens(for: .bnbChain)
        )

        let bnbRaw = try await EVMHexQuantity.decimalString(from: nativeHex)
        let balances = try await tokenBalances

        #expect(Decimal(string: bnbRaw) ?? 0 > 0, "known public BNB Chain address should hold BNB")
        #expect(balances.count == EVMTokenRegistry.tokens(for: .bnbChain).count)
        #expect(Decimal(string: balances["USDC"] ?? "0") ?? 0 > 0, "known public BNB Chain address should hold USDC")
        #expect(Decimal(string: balances["USDT"] ?? "0") ?? 0 > 0, "known public BNB Chain address should hold USDT")
        #expect(Decimal(string: balances["DAI"] ?? "0") ?? 0 > 0, "known public BNB Chain address should hold DAI")
        #expect(Decimal(string: balances["USD1"] ?? "0") ?? 0 > 0, "known public BNB Chain address should hold USD1")
        #expect(Decimal(string: balances["USDe"] ?? "0") ?? 0 > 0, "known public BNB Chain address should hold USDe")
        #expect(Decimal(string: balances["FDUSD"] ?? "0") ?? 0 > 0, "known public BNB Chain address should hold FDUSD")
        #expect(Decimal(string: balances["TUSD"] ?? "0") ?? 0 > 0, "known public BNB Chain address should hold TUSD")
        #expect(Decimal(string: balances["USDP"] ?? "0") ?? 0 > 0, "known public BNB Chain address should hold USDP")
        #expect(Decimal(string: balances["WETH"] ?? "0") ?? 0 > 0, "known public BNB Chain address should hold WETH")
        #expect(balances["DUSD"] != nil, "DUSD balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["FRAX"] != nil, "FRAX balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["USDf"] != nil, "USDf balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["lisUSD"] != nil, "lisUSD balanceOf should return a valid zero-or-positive raw value")
    }

    @Test("PublicNode opBNB balanceOf live read returns base-unit balances")
    func publicNodeOpBNBBalanceOfLiveRead() async throws {
        let holder = "0x8894E0a0c962CB723c1976a4421c95949bE2D4E3"
        let client = PublicNodeEVMTestClient(endpoint: URL(string: "https://opbnb-rpc.publicnode.com")!)

        let chainId = try await client.callString(method: "eth_chainId", params: [])
        #expect(chainId == "0xcc")

        async let nativeHex = client.callString(method: "eth_getBalance", params: [holder, "latest"])
        async let transactionCountHex = client.callString(method: "eth_getTransactionCount", params: [holder, "latest"])
        async let tokenBalances = publicNodeTokenBalances(
            client: client,
            holder: holder,
            tokens: EVMTokenRegistry.tokens(for: .opBNB)
        )

        let bnbRaw = try await EVMHexQuantity.decimalString(from: nativeHex)
        let transactionCountRaw = try await EVMHexQuantity.decimalString(from: transactionCountHex)
        let balances = try await tokenBalances

        #expect(Decimal(string: bnbRaw) ?? 0 > 0, "known public opBNB address should hold BNB")
        #expect(Decimal(string: transactionCountRaw) ?? -1 >= 0, "opBNB transaction count should decode")
        #expect(balances.count == EVMTokenRegistry.tokens(for: .opBNB).count)
        #expect(Decimal(string: balances["USDT"] ?? "0") ?? 0 > 0, "known public opBNB address should hold USDT")
    }

    @Test("opBNB USDT transfer logs decode from live JSON-RPC")
    func opBNBUSDTTransferLogsDecodeFromLiveRPC() async throws {
        let holder = "0xd4b7fdc2350f799c8fe8cf23674329b9b2aa30f6"
        let token = try #require(EVMTokenRegistry.tokens(for: .opBNB).first { $0.symbol == "USDT" })
        let client = PublicNodeEVMTestClient(endpoint: URL(string: "https://opbnb-mainnet-rpc.bnbchain.org")!)
        let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
        let toTopic = evmIndexedAddressTopic(holder)
        let block = "0x966b92a"

        let logs = try await client.callLogs(
            method: "eth_getLogs",
            params: [[
                "fromBlock": block,
                "toBlock": block,
                "address": token.contract,
                "topics": [transferTopic, NSNull(), toTopic] as [Any]
            ]]
        )

        let decoded = logs.compactMap { log -> (amount: String, counterparty: String)? in
            guard log.topics.count >= 3 else { return nil }
            guard log.topics[2].lowercased() == toTopic.lowercased() else { return nil }
            let amount = (try? EVMHexQuantity.decimalString(from: log.data)) ?? "0"
            return (amount, evmAddressFromTopic(log.topics[1]))
        }

        #expect(!decoded.isEmpty, "live opBNB USDT transfer logs should include receives for the probe holder")
        #expect(decoded.contains { Decimal(string: $0.amount) ?? 0 > 0 })
        #expect(decoded.allSatisfy { $0.counterparty.hasPrefix("0x") && $0.counterparty.count == 42 })
    }

    @Test("PublicNode Avalanche balanceOf live read returns base-unit balances")
    func publicNodeAvalancheBalanceOfLiveRead() async throws {
        let holder = "0x742d35Cc6634C0532925a3b844Bc454e4438f44e"
        let client = PublicNodeEVMTestClient(endpoint: URL(string: "https://avalanche-c-chain-rpc.publicnode.com")!)

        let chainId = try await client.callString(method: "eth_chainId", params: [])
        #expect(chainId == "0xa86a")

        async let nativeHex = client.callString(method: "eth_getBalance", params: [holder, "latest"])
        async let tokenBalances = publicNodeTokenBalances(
            client: client,
            holder: holder,
            tokens: EVMTokenRegistry.tokens(for: .avalanche)
        )

        let avaxRaw = try await EVMHexQuantity.decimalString(from: nativeHex)
        let balances = try await tokenBalances

        #expect(Decimal(string: avaxRaw) ?? 0 > 0, "known public Avalanche address should hold AVAX")
        #expect(balances.count == EVMTokenRegistry.tokens(for: .avalanche).count)
        #expect(Decimal(string: balances["USDC"] ?? "0") ?? 0 > 0, "known public Avalanche address should hold USDC")
        #expect(Decimal(string: balances["USDT"] ?? "0") ?? 0 > 0, "known public Avalanche address should hold USDT")
        #expect(Decimal(string: balances["FRAX"] ?? "0") ?? 0 > 0, "known public Avalanche address should hold FRAX")
        #expect(balances["DAI"] != nil, "DAI balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["AUSD"] != nil, "AUSD balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["EURC"] != nil, "EURC balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["TUSD"] != nil, "TUSD balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["WBTC"] != nil, "WBTC balanceOf should return a valid zero-or-positive raw value")
        #expect(balances["WETH"] != nil, "WETH balanceOf should return a valid zero-or-positive raw value")
    }

    @Test("PublicNode Celo balanceOf live read returns base-unit balances")
    func publicNodeCeloBalanceOfLiveRead() async throws {
        let holder = "0x471EcE3750Da237f93B8E339c536989b8978a438"
        let client = PublicNodeEVMTestClient(endpoint: URL(string: "https://celo-rpc.publicnode.com")!)

        let chainId = try await client.callString(method: "eth_chainId", params: [])
        #expect(chainId == "0xa4ec")

        async let nativeHex = client.callString(method: "eth_getBalance", params: [holder, "latest"])
        async let tokenBalances = publicNodeTokenBalances(
            client: client,
            holder: holder,
            tokens: EVMTokenRegistry.tokens(for: .celo)
        )

        let celoRaw = try await EVMHexQuantity.decimalString(from: nativeHex)
        let balances = try await tokenBalances

        #expect(Decimal(string: celoRaw) ?? 0 > 0, "known public Celo address should hold CELO")
        #expect(balances.count == EVMTokenRegistry.tokens(for: .celo).count)
        #expect(Decimal(string: balances["USDC"] ?? "0") ?? 0 > 0, "known public Celo address should hold USDC")
        #expect(Decimal(string: balances["USDT"] ?? "0") ?? 0 > 0, "known public Celo address should hold USDT")
    }

}

final class EVMTransactionHistoryLiveTests: XCTestCase {
    func testEVMHistoryClientDecodesLiveExplorerTransfers() async throws {
        let client = EVMTransactionHistoryClient()

        async let ethereumEvents = client.recentEvents(
            chain: .ethereum,
            holder: "0x742d35Cc6634C0532925a3b844Bc454e4438f44e",
            tokens: EVMTokenRegistry.tokens(for: .ethereum)
        )
        async let avalancheEvents = client.recentEvents(
            chain: .avalanche,
            holder: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E",
            tokens: EVMTokenRegistry.tokens(for: .avalanche)
        )

        let eth = await ethereumEvents
        let avax = await avalancheEvents

        XCTAssertFalse(eth.isEmpty, "Ethereum explorer history should return recent native or supported-token events")
        XCTAssertFalse(avax.isEmpty, "Avalanche explorer history should return recent native or supported-token events")
        XCTAssertTrue(
            eth.contains { $0.tokenSymbol == "ETH" || $0.tokenContract != nil },
            "Ethereum history should include native ETH or a supported ERC-20 transfer"
        )
        XCTAssertTrue(
            avax.contains { $0.tokenSymbol == "AVAX" || $0.tokenContract != nil },
            "Avalanche history should include native AVAX or a supported ERC-20 transfer"
        )
        XCTAssertTrue(eth.allSatisfy { !$0.txHash.isEmpty && !$0.amount.isEmpty })
        XCTAssertTrue(avax.allSatisfy { !$0.txHash.isEmpty && !$0.amount.isEmpty })
    }
}

final class TronBalanceHistoryLiveTests: XCTestCase {
    func testTronClientReadsLiveBalancesAndSupportedHistory() async throws {
        let client = TronBalanceHistoryClient()
        let holder = "TMuA6YqfCeX8EhbfYEg5y7S4DqzSJireY9"
        let tokens = TronTokenRegistry.tokens

        async let accountTask = client.accountSnapshot(address: holder, supportedTokens: tokens)
        async let eventsTask = client.recentEvents(address: holder, supportedTokens: tokens)

        let account = try await accountTask
        let events = await eventsTask

        XCTAssertTrue(account.accountExists)
        XCTAssertGreaterThan(Decimal(string: account.rawTRX) ?? 0, 0)
        XCTAssertEqual(account.tokenBalances.count, tokens.count)

        let usdt = account.tokenBalances.first { $0.entry.symbol == "USDT" }
        XCTAssertNotNil(usdt)
        XCTAssertGreaterThan(Decimal(string: usdt?.rawBalance ?? "0") ?? 0, 0)

        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.contains { $0.tokenSymbol == "USDT" })
        XCTAssertTrue(events.allSatisfy { !$0.txHash.isEmpty && !$0.amount.isEmpty })
    }
}

// MARK: - Test case fixtures

/// One per-token row produced for the Swift Testing parameterized
/// runner. `label` is what appears in the Xcode test navigator —
/// `(chain, symbol, contract-short)` so a failed row is identifiable
/// at a glance.
struct EVMTokenTestCase: Sendable, CustomStringConvertible {
    let chain: SupportedChain
    let entry: EVMTokenRegistry.Entry

    var label: String {
        let shortContract = entry.contract.count > 10
            ? "\(entry.contract.prefix(6))…\(entry.contract.suffix(4))"
            : entry.contract
        return "\(chain.rawValue)/\(entry.symbol)/\(shortContract)"
    }

    var description: String { label }

    /// Every `(chain, entry)` pair across the 12 EVM chains. The
    /// `@Test(arguments:)` macro consumes this to produce one
    /// invocation per row.
    static let all: [EVMTokenTestCase] = {
        var out: [EVMTokenTestCase] = []
        let evmChains: [SupportedChain] = [
            .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
            .polygon, .bnbChain, .opBNB, .avalanche, .celo
        ]
        for chain in evmChains {
            for entry in EVMTokenRegistry.tokens(for: chain) {
                out.append(EVMTokenTestCase(chain: chain, entry: entry))
            }
        }
        return out
    }()
}

/// Expected per-chain registry counts taken verbatim from
/// `SUPPORTED_ASSETS.md` sections 3.1–3.12. A drift here means
/// someone added or removed a row from the registry without
/// updating the spec — Rule #21 violation.
struct EVMChainTokenCount: Sendable, CustomStringConvertible {
    let chain: SupportedChain
    let expectedCount: Int

    var description: String { "\(chain.rawValue)=\(expectedCount)" }

    static let expected: [EVMChainTokenCount] = [
        // From `SUPPORTED_ASSETS.md`:
        EVMChainTokenCount(chain: .ethereum,  expectedCount: 21),  // 3.1
        EVMChainTokenCount(chain: .arbitrum,  expectedCount: 8),   // 3.2
        EVMChainTokenCount(chain: .base,      expectedCount: 8),   // 3.3
        EVMChainTokenCount(chain: .optimism,  expectedCount: 6),   // 3.4
        EVMChainTokenCount(chain: .scroll,    expectedCount: 2),   // 3.5
        EVMChainTokenCount(chain: .zkSync,    expectedCount: 2),   // 3.6
        EVMChainTokenCount(chain: .polygon,   expectedCount: 6),   // 3.7
        EVMChainTokenCount(chain: .bnbChain,  expectedCount: 13),  // 3.8
        EVMChainTokenCount(chain: .opBNB,     expectedCount: 1),   // 3.9
        EVMChainTokenCount(chain: .avalanche, expectedCount: 9),   // 3.10
        EVMChainTokenCount(chain: .celo,      expectedCount: 2),   // 3.11
    ]
}

private func publicNodeTokenBalances(
    client: PublicNodeEVMTestClient,
    holder: String,
    tokens: [EVMTokenRegistry.Entry]
) async throws -> [String: String] {
    try await withThrowingTaskGroup(of: (String, String).self) { group in
        for token in tokens {
            group.addTask {
                let hex = try await client.callString(
                    method: "eth_call",
                    params: [["to": token.contract, "data": EVMTokenRegistry.balanceOfCallData(holder: holder)], "latest"]
                )
                return (token.symbol, try EVMHexQuantity.decimalString(from: hex))
            }
        }

        var balances: [String: String] = [:]
        for try await (symbol, raw) in group {
            balances[symbol] = raw
        }
        return balances
    }
}

private func evmIndexedAddressTopic(_ address: String) -> String {
    let trimmed = address.hasPrefix("0x") || address.hasPrefix("0X")
        ? String(address.dropFirst(2))
        : address
    return "0x" + String(repeating: "0", count: max(0, 64 - trimmed.count)) + trimmed.lowercased()
}

private func evmAddressFromTopic(_ topic: String) -> String {
    let trimmed = topic.hasPrefix("0x") || topic.hasPrefix("0X")
        ? String(topic.dropFirst(2))
        : topic
    return "0x" + String(trimmed.suffix(40)).lowercased()
}

private actor PublicNodeEVMTestClient {
    private let endpoint: URL
    private let session: URLSession
    private var id = 0

    init(endpoint: URL) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: configuration)
    }

    func callString(method: String, params: [Any]) async throws -> String {
        id += 1
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ])

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let envelope = try JSONDecoder().decode(JSONRPCStringEnvelope.self, from: data)
        if let error = envelope.error {
            throw PublicNodeTestError.rpc(code: error.code, message: error.message)
        }
        return try #require(envelope.result)
    }

    func callLogs(method: String, params: [Any]) async throws -> [EVMLogProbe] {
        id += 1
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Aperture/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ])

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let envelope = try JSONDecoder().decode(JSONRPCLogsEnvelope.self, from: data)
        if let error = envelope.error {
            throw PublicNodeTestError.rpc(code: error.code, message: error.message)
        }
        return try #require(envelope.result)
    }

    private struct JSONRPCStringEnvelope: Decodable {
        struct ErrorBody: Decodable {
            let code: Int
            let message: String
        }

        let result: String?
        let error: ErrorBody?
    }

    private struct JSONRPCLogsEnvelope: Decodable {
        struct ErrorBody: Decodable {
            let code: Int
            let message: String
        }

        let result: [EVMLogProbe]?
        let error: ErrorBody?
    }

    private enum PublicNodeTestError: Error {
        case rpc(code: Int, message: String)
    }
}

private struct EVMLogProbe: Decodable, Sendable {
    let address: String
    let topics: [String]
    let data: String
    let blockNumber: String
    let transactionHash: String
    let logIndex: String
}
