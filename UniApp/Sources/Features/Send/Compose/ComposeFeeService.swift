import Foundation
import OSLog

/// Fetches live fee data for EVERY supported chain and returns a
/// `FeeQuote` (slow/normal/fast tiers + custom support). Off-main
/// (Rule #28); reuses the shared `RPCClient` rate-limiter + breakers.
///
/// Every fetcher cites its doc URL + RPC method in a comment and is
/// doc-grounded per `.claude/send-compose-matrix.md` (live-verified
/// 2026-06-15). Each fee fetcher returns the per-chain numeric fields a
/// signer needs PLUS an estimated total in native units.
///
/// The estimate for a NATIVE transfer uses the standard per-chain
/// transfer size/gas (21000 EVM, ~150 CU Solana, etc.); a TOKEN transfer
/// passes `tokenContract`/`isToken` so the gas/energy estimate reflects
/// the heavier contract path. When a live call fails the service throws —
/// it never fabricates a fee (Rule #2 honesty); the UI surfaces "fee
/// unavailable" and offers retry.
struct ComposeFeeService: Sendable {

    let client: RPCClient
    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "compose-fee")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    /// Parameters that shape the estimate (token vs native, sender for
    /// gas estimation, recipient for L1-data-fee / activation).
    struct Context: Sendable {
        let chain: SupportedChain
        let fromAddress: String
        let toAddress: String?
        /// nil = native send; non-nil = token contract/mint/denom/jetton.
        let tokenContract: String?
        let tokenDecimals: Int?
        let recipientCount: Int

        init(chain: SupportedChain, fromAddress: String, toAddress: String? = nil,
             tokenContract: String? = nil, tokenDecimals: Int? = nil, recipientCount: Int = 1) {
            self.chain = chain
            self.fromAddress = fromAddress
            self.toAddress = toAddress
            self.tokenContract = tokenContract
            self.tokenDecimals = tokenDecimals
            self.recipientCount = recipientCount
        }

        var isToken: Bool { tokenContract != nil }
    }

    /// Fetch a fee quote for the context's chain. Dispatches on the
    /// chain's `ComposeFeeModel`.
    func quote(_ ctx: Context) async throws -> FeeQuote {
        let cap = ChainComposeCapability.capability(for: ctx.chain)
        switch cap.feeModel {
        case .utxoByteFee, .utxoByteFeeNoWitness, .dogecoinFixedPerKB:
            return try await utxoQuote(ctx, model: cap.feeModel)
        case .evm1559, .evm1559PlusL1Data, .zkSyncEra:
            return try await evm1559Quote(ctx, model: cap.feeModel)
        case .evmLegacy:
            return try await evmLegacyQuote(ctx)
        case .solana:
            return try await solanaQuote(ctx)
        case .stellarPerOp:
            return try await stellarQuote(ctx)
        case .suiGasBudget:
            return try await suiQuote(ctx)
        case .tonFixed:
            return try await tonQuote(ctx)
        case .xrpFixed:
            return try await xrpQuote(ctx)
        case .tronResource:
            return try await tronQuote(ctx)
        case .nearGas:
            return try await nearQuote(ctx)
        case .polkadotWeight:
            return try await polkadotQuote(ctx)
        case .cosmosGas:
            return try await cosmosQuote(ctx)
        case .aptosGas:
            return try await aptosQuote(ctx)
        }
    }

    // MARK: - Shared helpers

    /// Build a `FeeChoice` for an EVM gas model from resolved fields.
    func makeChoice(
        tier: FeeTier, model: ComposeFeeModel,
        decimals: Int, mutate: (inout FeeChoice) -> Void
    ) -> FeeChoice {
        var choice = FeeChoice(
            tier: tier, feeModel: model,
            estimatedTotalNative: 0, worstCaseTotalNative: 0)
        mutate(&choice)
        return choice
    }
}
