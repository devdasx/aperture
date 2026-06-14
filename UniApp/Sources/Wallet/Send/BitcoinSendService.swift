import Foundation
import SwiftData
import WalletCore

/// Bitcoin / UTXO (BTC, BCH, LTC, DOGE) send — STUB pending the real implementation (Send V2).
///
/// Mirrors `EVMSendService`'s contract so `ChainSendRouter` dispatches to
/// it uniformly. Until the real pipeline lands, every entry point throws
/// `.unsupportedChain` — honest (Rule #16): the UI shows "isn't available
/// yet" rather than faking a fee or a broadcast.
enum BitcoinSendService {

    nonisolated static func loadFees(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, container: ModelContainer
    ) async throws(ChainSendError) -> [ChainFeeOption] {
        throw .unsupportedChain(chain)
    }

    nonisolated static func performSend(
        chain: SupportedChain, toAddress: String, rawAmount: String,
        isNative: Bool, contract: String?, decimals: Int, memo: String?,
        speed: ChainFeeOption.Speed, container: ModelContainer
    ) async throws(ChainSendError) -> ChainSignedTransaction {
        throw .unsupportedChain(chain)
    }

    nonisolated static func status(
        chain: SupportedChain, txHash: String
    ) async throws(ChainSendError) -> ChainSendStatus {
        throw .unsupportedChain(chain)
    }
}
