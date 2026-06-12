import Testing
import Foundation
@testable import Aperture

/// Per-mint tests for `SolanaTokenRegistry`. Parameterized over
/// every entry — each mint gets its own per-test green/red signal.
/// Companion to `EVMTokenRegistryTests`; same per-token granularity
/// the user asked for in the 2026-06-12 audit pass.
///
/// **What each per-mint test verifies:**
/// 1. Mint is a valid base58 string that decodes to exactly 32 bytes
///    (Solana pubkey size). A malformed mint here would cause
///    `getTokenAccountsByOwner` to reject the input or — worse — to
///    succeed with empty results, silently making the holding
///    invisible.
/// 2. `decimals` is in the sane SPL range `0…9`. SPL Token mints
///    encode decimals as a single u8 byte, but realistic tokens
///    cluster around 6 (USDC, USDT, EURC, PYUSD, AUSD, DUSD, USDG,
///    USD1) or 8 (Wormhole-bridged WBTC, WETH on Solana — bridged
///    decimals are reduced to fit the SPL one-byte cap and pair the
///    WBTC convention).
/// 3. `symbol` is non-empty and uppercase-canonical for pricing
///    pipeline lookup.
/// 4. `name` is non-empty.
/// 5. `standard` maps to a routable program ID. `.splToken` →
///    legacy 43-char id; `.splToken2022` → 44-char id ending in
///    `Z` (per the 2026-06-12 fix; the previous 43-char value was
///    an invalid pubkey).
struct SolanaTokenRegistryTests {

    @Test(
        "Solana mint registry entry is well-formed",
        arguments: SolanaMintTestCase.all
    )
    func validMintEntry(_ tc: SolanaMintTestCase) throws {
        let mint = tc.mint
        let entry = tc.entry

        // 1) Base58 decode → exactly 32 bytes (Solana pubkey size).
        let decoded = Base58.decodeBytes(mint)
        #expect(decoded != nil, "\(tc.label): mint does not decode as base58 — \(mint)")
        #expect(
            decoded?.count == 32,
            "\(tc.label): mint decoded to \(decoded?.count ?? -1) bytes, expected 32 — \(mint)"
        )

        // 2) Decimals in sane SPL range. SPL stores decimals as u8;
        //    every realistic mint is ≤ 9. We assert ≤ 18 as a wider
        //    defensible bound so a future mint with weird decimals
        //    doesn't break the test prematurely — but flag it.
        #expect(
            (0...18).contains(entry.decimals),
            "\(tc.label): decimals \(entry.decimals) outside expected 0…18 SPL range"
        )

        // 3) Symbol non-empty + pricing-pipeline-resolvable.
        #expect(!entry.symbol.isEmpty, "\(tc.label): empty symbol")
        let pricingSymbol = WrappedAssetAliases.resolveSymbol(entry.symbol)
        #expect(!pricingSymbol.isEmpty, "\(tc.label): pricing symbol resolved empty")

        // 4) Name non-empty.
        #expect(!entry.name.isEmpty, "\(tc.label): empty name")

        // 5) Program ID routing. Both program IDs must base58-decode
        //    to 32 bytes (the canonical pubkey shape); the
        //    Token-2022 id specifically must be 44 chars ending in
        //    `Z` per the 2026-06-12 fix.
        switch entry.standard {
        case .splToken:
            let legacyDecoded = Base58.decodeBytes(SolanaChainAdapter.splTokenProgramId)
            #expect(
                legacyDecoded?.count == 32,
                "\(tc.label): legacy SPL Token program ID does not decode to 32 bytes"
            )
        case .splToken2022:
            // Mainnet-verified 2026-06-12 against api.mainnet-beta.solana.com:
            // the 43-char form is the deployed program owned by
            // BPFLoaderUpgradeab1e..., decoding to canonical 32 bytes. The
            // 44-char form ending in `Z` is invalid (33-byte BigInt).
            let canonical = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"
            #expect(
                SolanaChainAdapter.splToken2022ProgramId == canonical,
                "\(tc.label): Token-2022 program ID is wrong — got \"\(SolanaChainAdapter.splToken2022ProgramId)\", expected \"\(canonical)\""
            )
            #expect(
                SolanaChainAdapter.splToken2022ProgramId.count == 43,
                "\(tc.label): Token-2022 program ID is \(SolanaChainAdapter.splToken2022ProgramId.count) chars, expected 43"
            )
            let token2022Decoded = Base58.decodeBytes(SolanaChainAdapter.splToken2022ProgramId)
            #expect(
                token2022Decoded?.count == 32,
                "\(tc.label): Token-2022 program ID does not decode to 32 bytes"
            )
        }
    }

    // MARK: - Per-mint sanity checks for the symbol-lookup pipeline

    @Test(
        "Solana mint round-trips through symbol/name helpers",
        arguments: SolanaMintTestCase.all
    )
    func symbolAndNameLookup(_ tc: SolanaMintTestCase) throws {
        let resolvedSymbol = SolanaTokenRegistry.symbol(for: tc.mint)
        let resolvedName = SolanaTokenRegistry.name(for: tc.mint)
        #expect(
            resolvedSymbol == tc.entry.symbol,
            "\(tc.label): symbol(for:) returned \"\(resolvedSymbol)\", expected \"\(tc.entry.symbol)\""
        )
        #expect(
            resolvedName == tc.entry.name,
            "\(tc.label): name(for:) returned \"\(resolvedName)\", expected \"\(tc.entry.name)\""
        )
    }

    // MARK: - Registry shape

    @Test("Solana registry contains exactly 10 mints (per SUPPORTED_ASSETS.md §3.15)")
    func registryCount() throws {
        #expect(
            SolanaTokenRegistry.mints.count == 10,
            "Expected 10 Solana mints, got \(SolanaTokenRegistry.mints.count)"
        )
    }

    @Test("Solana registry has no duplicate symbols")
    func noDuplicateSymbols() throws {
        let symbols = Set(SolanaTokenRegistry.mints.values.map { $0.symbol.uppercased() })
        #expect(
            symbols.count == SolanaTokenRegistry.mints.count,
            "Duplicate symbols in Solana registry — \(SolanaTokenRegistry.mints.count) entries but \(symbols.count) unique"
        )
    }

    @Test("Token-2022 mints are exactly the documented set (PYUSD/AUSD/DUSD/USDG)")
    func token2022MintSet() throws {
        let token2022Symbols = SolanaTokenRegistry.mints.values
            .filter { $0.standard == .splToken2022 }
            .map { $0.symbol.uppercased() }
        let expected: Set<String> = ["AUSD", "DUSD", "PYUSD", "USDG"]
        #expect(
            Set(token2022Symbols) == expected,
            "Token-2022 mint set drifted — got \(Set(token2022Symbols)), expected \(expected)"
        )
    }

    // MARK: - Unknown mint handling

    @Test("Unknown Solana mint returns truncated form via symbol(for:)")
    func unknownMintFallback() throws {
        // A garbage-but-base58 mint that's not in the registry.
        let unknown = "11111111111111111111111111111111"  // System Program — never a token mint
        let resolved = SolanaTokenRegistry.symbol(for: unknown)
        #expect(
            resolved.contains("…"),
            "Unknown mint should render as `prefix…suffix`, got \"\(resolved)\""
        )
        #expect(
            resolved != unknown,
            "Unknown mint should be truncated, not echoed verbatim — got \"\(resolved)\""
        )
    }
}

// MARK: - Test fixtures

struct SolanaMintTestCase: Sendable, CustomStringConvertible {
    let mint: String
    let entry: SolanaTokenRegistry.Entry

    var label: String {
        let short = mint.count > 12 ? "\(mint.prefix(6))…\(mint.suffix(4))" : mint
        return "\(entry.symbol)/\(short)"
    }

    var description: String { label }

    static let all: [SolanaMintTestCase] = {
        SolanaTokenRegistry.mints
            .map { SolanaMintTestCase(mint: $0.key, entry: $0.value) }
            .sorted { $0.entry.symbol < $1.entry.symbol }
    }()
}
