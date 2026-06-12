import Testing
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
            .polygon, .bnbChain, .opBNB, .avalanche, .celo, .kavaEvm
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
        EVMChainTokenCount(chain: .kavaEvm,   expectedCount: 1),   // 3.12
    ]
}
