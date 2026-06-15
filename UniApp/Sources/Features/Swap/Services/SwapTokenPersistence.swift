import Foundation
import OSLog
import SwiftData

/// Persists a swapped-TO token into the user's custom-token list so it
/// becomes curated after a successful swap (user direction 2026-06-15:
/// "if he have successfully swap to it, it should be added to the tokens
/// list automatically").
///
/// **Trigger — the execute step.** Swap sign+broadcast is the staged next
/// increment; the Swap flow currently ends at an honest, display-only
/// Review. This is the ready persistence that the execute success path
/// calls with the confirmed `quote.toToken` the moment a swap actually
/// lands. The READ side already works live (Rule #25): the Swap, Send,
/// Receive, and Settings pickers all `@Query` `CustomTokenRecord`, and the
/// balance scanner picks up the new token on the next refresh — so an
/// auto-added token appears everywhere without a relaunch.
///
/// **Guarded + idempotent.** Skips native coins (their "contract" is the
/// sentinel), skips tokens already in the curated registry, and swallows
/// the duplicate error — a re-swap into an already-listed token is a
/// silent no-op, never an error (Rule #16).
enum SwapTokenPersistence {

    /// Add `token` to the custom-token store if it isn't native and isn't
    /// already curated/custom. Best-effort; failures are non-fatal.
    static func persistIfNeeded(_ token: SwapToken, container: ModelContainer) async {
        // A native coin is not a token contract — never persist the sentinel.
        guard !token.isNative else { return }
        // Only ever write a row on a chain we can actually swap/transact on.
        guard SwapChainMap.isSwappable(token.chain) else { return }
        // Already curated (static registry / seeded AssetRecord) → don't
        // shadow it with a redundant "custom" row.
        guard !isCurated(chain: token.chain, contract: token.address) else { return }

        let repo = CustomTokenRepository(modelContainer: container)
        do {
            try await repo.add(
                chain: token.chain,
                // Store EVM contracts EIP-55 checksummed (matching the Add-
                // custom-token sheet + the repository's documented contract);
                // the provider hands EVM addresses lowercased. Solana mints
                // are case-sensitive base58 and stay verbatim.
                contract: normalizedContract(for: token),
                symbol: token.symbol,
                name: token.name,
                decimals: token.decimals,
                iconURL: token.logoURI,
                // The source is the swap provider's metadata, not a direct
                // on-chain probe — flag it so the row's provenance is honest.
                metadataFromChain: false
            )
        } catch CustomTokenError.duplicate {
            // Already a custom token (re-swap into a known token) — no-op.
        } catch {
            // Best-effort convenience add — non-fatal, but log so a real
            // SwiftData write failure is observable rather than invisible.
            Logger(subsystem: "com.thuglife.aperture", category: "swap")
                .warning("auto-add swapped-to token failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// EIP-55 checksum the EVM contract so the stored form matches the rest
    /// of the app (the Add sheet + `CustomTokenRepository`'s contract);
    /// Solana mints (case-sensitive base58) pass through verbatim. Falls back
    /// to the raw address if validation somehow fails (the contract still
    /// dedups via the repository's case-insensitive `dedupKey`).
    private static func normalizedContract(for token: SwapToken) -> String {
        guard token.kind == .evm else { return token.address }
        if case let .valid(normalized) = ContractValidator.validateEVM(token.address) {
            return normalized
        }
        return token.address
    }

    /// Whether `(chain, contract)` is already a curated catalog asset.
    /// Case-insensitive — provider addresses may be lowercase while the
    /// registry stores EIP-55 checksummed contracts.
    private static func isCurated(chain: SupportedChain, contract: String) -> Bool {
        for asset in AssetCatalog.allAssets where asset.chain == chain {
            if asset.contract.caseInsensitiveCompare(contract) == .orderedSame {
                return true
            }
        }
        return false
    }
}
