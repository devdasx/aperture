import Foundation
import SwiftData

/// Routes a send to the correct per-family service. Every supported chain
/// maps to exactly one send family, and each family service exposes the
/// same three entry points — `loadFees`, `performSend`, `status` — so the
/// `@MainActor` view-model stays family-agnostic and never branches on the
/// chain itself.
///
/// **Off-main (Rule #28).** Every method here is `nonisolated async`; the
/// per-family services run the RPC + signing off the main actor and only
/// return small Sendable values.
///
/// **Funds-safety (Rule #16 / #26).** The router only dispatches — every
/// fee/nonce/sequence/UTXO value is fetched live inside the family service
/// (no guesses), and a node rejection surfaces its real reason.
enum ChainSendRouter {

    /// The 12 send families. Note this is NOT `SupportedChain.family`
    /// (which groups by *crypto curve* — Solana/Stellar/Sui all share
    /// `.ed25519`). Sending differs per chain even within a curve family,
    /// so each gets its own service.
    enum SendFamily {
        case evm, bitcoin, solana, tron, ton, xrpl, stellar, aptos, near, polkadot, sui, cosmos
    }

    static func family(for chain: SupportedChain) -> SendFamily {
        switch chain {
        case .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
             .polygon, .bnbChain, .opBNB, .avalanche, .celo, .kavaEvm:
            return .evm
        case .bitcoin, .bitcoinCash, .litecoin, .dogecoin:
            return .bitcoin
        case .solana:   return .solana
        case .tron:     return .tron
        case .ton:      return .ton
        case .ripple:   return .xrpl
        case .stellar:  return .stellar
        case .aptos:    return .aptos
        case .near:     return .near
        case .polkadot: return .polkadot
        case .sui:      return .sui
        case .kava:     return .cosmos
        }
    }

    // MARK: - Fee tiers

    static func loadFees(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, container: ModelContainer
    ) async throws(ChainSendError) -> [ChainFeeOption] {
        switch family(for: chain) {
        case .evm:
            return try await EVMSendService.loadFees(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, container: container)
        case .bitcoin:
            return try await BitcoinSendService.loadFees(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, container: container)
        case .solana:
            return try await SolanaSendService.loadFees(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, container: container)
        case .tron:
            return try await TronSendService.loadFees(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, container: container)
        case .ton:
            return try await TonSendService.loadFees(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, container: container)
        case .xrpl:
            return try await XRPLSendService.loadFees(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, container: container)
        case .stellar:
            return try await StellarSendService.loadFees(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, container: container)
        case .aptos:
            return try await AptosSendService.loadFees(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, container: container)
        case .near:
            return try await NearSendService.loadFees(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, container: container)
        case .polkadot:
            return try await PolkadotSendService.loadFees(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, container: container)
        case .sui:
            return try await SuiSendService.loadFees(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, container: container)
        case .cosmos:
            return try await CosmosSendService.loadFees(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, container: container)
        }
    }

    // MARK: - Sign + broadcast

    static func performSend(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, memo: String?,
        speed: ChainFeeOption.Speed, container: ModelContainer
    ) async throws(ChainSendError) -> ChainSignedTransaction {
        switch family(for: chain) {
        case .evm:
            return try await EVMSendService.performSend(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, speed: speed, container: container)
        case .bitcoin:
            return try await BitcoinSendService.performSend(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, memo: memo, speed: speed, container: container)
        case .solana:
            return try await SolanaSendService.performSend(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, memo: memo, speed: speed, container: container)
        case .tron:
            return try await TronSendService.performSend(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, memo: memo, speed: speed, container: container)
        case .ton:
            return try await TonSendService.performSend(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, memo: memo, speed: speed, container: container)
        case .xrpl:
            return try await XRPLSendService.performSend(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, memo: memo, speed: speed, container: container)
        case .stellar:
            return try await StellarSendService.performSend(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, memo: memo, speed: speed, container: container)
        case .aptos:
            return try await AptosSendService.performSend(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, memo: memo, speed: speed, container: container)
        case .near:
            return try await NearSendService.performSend(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, memo: memo, speed: speed, container: container)
        case .polkadot:
            return try await PolkadotSendService.performSend(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, memo: memo, speed: speed, container: container)
        case .sui:
            return try await SuiSendService.performSend(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, memo: memo, speed: speed, container: container)
        case .cosmos:
            return try await CosmosSendService.performSend(chain: chain, toAddress: toAddress, rawAmount: rawAmount, isNative: isNative, contract: contract, decimals: decimals, memo: memo, speed: speed, container: container)
        }
    }

    // MARK: - Status

    static func status(chain: SupportedChain, txHash: String) async throws(ChainSendError) -> ChainSendStatus {
        switch family(for: chain) {
        case .evm:      return try await EVMSendService.status(chain: chain, txHash: txHash)
        case .bitcoin:  return try await BitcoinSendService.status(chain: chain, txHash: txHash)
        case .solana:   return try await SolanaSendService.status(chain: chain, txHash: txHash)
        case .tron:     return try await TronSendService.status(chain: chain, txHash: txHash)
        case .ton:      return try await TonSendService.status(chain: chain, txHash: txHash)
        case .xrpl:     return try await XRPLSendService.status(chain: chain, txHash: txHash)
        case .stellar:  return try await StellarSendService.status(chain: chain, txHash: txHash)
        case .aptos:    return try await AptosSendService.status(chain: chain, txHash: txHash)
        case .near:     return try await NearSendService.status(chain: chain, txHash: txHash)
        case .polkadot: return try await PolkadotSendService.status(chain: chain, txHash: txHash)
        case .sui:      return try await SuiSendService.status(chain: chain, txHash: txHash)
        case .cosmos:   return try await CosmosSendService.status(chain: chain, txHash: txHash)
        }
    }
}
