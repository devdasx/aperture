import Foundation
import WalletCore

/// Real, per-chain recipient validation + name resolution for the Send
/// recipient step. Address validation is wallet-core's
/// `CoinType.validate(address:)` (the same check the importer uses), so a
/// "valid" address here is one the chain's own format rules accept. Name
/// resolution (ENS for EVM `.eth`, SNS for Solana `.sol`) hits the real
/// on-chain registries via `ENSResolver` / `SNSResolver`.

/// A finalized recipient the user chose: the on-chain `address` to send
/// to, plus the `name` it was resolved from (nil when typed directly).
/// Codable + Hashable so it rides the NavigationPath into the amount step.
struct SendRecipientEntry: Codable, Hashable, Identifiable {
    let address: String
    let name: String?
    var id: String { address }
}

/// The outcome of resolving the recipient field.
enum RecipientResolution: Sendable, Equatable {
    /// Field is empty — nothing to validate yet.
    case empty
    /// Looks like a name (`.eth` / `.sol`) and is being resolved.
    case resolving
    /// A usable recipient: the on-chain `address` to send to, plus the
    /// `name` it was resolved from (nil when the user typed an address).
    case resolved(address: String, name: String?)
    /// A name that resolved to nothing on-chain.
    case nameNotFound(String)
    /// Not a valid address for this chain (and not a resolvable name).
    case invalid
}

enum RecipientResolver {

    /// Validate a raw address string against the chain's own format
    /// rules (wallet-core). Trimmed; empty is invalid.
    static func isValidAddress(_ address: String, for chain: SupportedChain) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let coin = ChainCoinType.coinType(for: chain) else { return false }
        return coin.validate(address: trimmed)
    }

    /// Whether the input looks like a name this chain can resolve
    /// (`.eth` on EVM, `.sol` on Solana) rather than a raw address.
    static func looksLikeName(_ input: String, for chain: SupportedChain) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.contains(".") else { return false }
        if chain.family == .evm { return trimmed.hasSuffix(".eth") }
        if chain == .solana { return trimmed.hasSuffix(".sol") }
        return false
    }

    /// Resolve the recipient field to a usable address. Handles both a
    /// raw address (validated) and a name (`.eth` / `.sol`, resolved on
    /// chain). Runs off the main actor (the name lookup is an RPC call).
    static func resolve(_ input: String, chain: SupportedChain) async -> RecipientResolution {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        // A name we can resolve on-chain.
        if looksLikeName(trimmed, for: chain) {
            if let address = await resolveName(trimmed, chain: chain) {
                // Defensive: the resolved address must itself be valid for
                // the chain (a registry could return garbage).
                guard isValidAddress(address, for: chain) else {
                    return .nameNotFound(trimmed)
                }
                return .resolved(address: address, name: trimmed)
            }
            return .nameNotFound(trimmed)
        }

        // A raw address.
        if isValidAddress(trimmed, for: chain) {
            return .resolved(address: trimmed, name: nil)
        }
        return .invalid
    }

    /// Resolve a name to an address via the chain's real registry.
    private static func resolveName(_ name: String, chain: SupportedChain) async -> String? {
        let lower = name.lowercased()
        if chain.family == .evm, lower.hasSuffix(".eth") {
            return await ENSResolver.resolve(name: lower)
        }
        if chain == .solana, lower.hasSuffix(".sol") {
            return await SNSResolver.resolve(name: lower)
        }
        return nil
    }
}
