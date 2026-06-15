import Foundation

/// Decodable mirror of the Li.Fi `GET /quote` response.
///
/// **Doc-grounded** against
/// https://docs.li.fi/api-reference/get-a-quote-for-a-token-transfer
/// and live-verified 2026-06-15 (same-chain 0.01 ETH→USDC on Ethereum,
/// cross-chain 0.05 ETH→USDC Ethereum→Arbitrum). Only the fields
/// Aperture's `SwapQuote` needs are decoded; the rest are ignored.
struct LiFiQuoteDTO: Decodable, Sendable {
    let id: String?
    let type: String?
    let tool: String?
    let action: Action
    let estimate: Estimate
    let transactionRequest: TxRequest?
    let includedSteps: [IncludedStep]?

    struct Action: Decodable, Sendable {
        let fromChainId: Int
        let toChainId: Int
        let fromToken: TokenInfo
        let toToken: TokenInfo
        let fromAmount: String
    }

    struct Estimate: Decodable, Sendable {
        let fromAmount: String?
        let toAmount: String
        let toAmountMin: String?
        let approvalAddress: String?
        let toAmountUSD: String?
        let fromAmountUSD: String?
        let executionDuration: Double?
        let feeCosts: [FeeCost]?
        let gasCosts: [GasCost]?
    }

    struct TokenInfo: Decodable, Sendable {
        let address: String
        let symbol: String
        let decimals: Int
        let chainId: Int
        let name: String?
        let logoURI: String?
        let priceUSD: String?
    }

    struct FeeCost: Decodable, Sendable {
        let name: String?
        let description: String?
        let percentage: String?
        let amount: String?
        let amountUSD: String?
        let included: Bool?
        let token: TokenInfo?
    }

    struct GasCost: Decodable, Sendable {
        let type: String?
        let amount: String?
        let amountUSD: String?
        let token: TokenInfo?
    }

    struct TxRequest: Decodable, Sendable {
        let from: String?
        let to: String?
        let chainId: Int?
        let data: String?
        let value: String?
        let gasPrice: String?
        let gasLimit: String?
    }

    struct IncludedStep: Decodable, Sendable {
        let type: String?
        let tool: String?
    }
}

// MARK: - Li.Fi /tokens

/// `GET /tokens` response: `{ "tokens": { "<chainId>": [TokenInfo, …] } }`.
/// Live-verified 2026-06-15 (4763 tokens on Ethereum). The `extended`
/// key in the live response is ignored.
struct LiFiTokensDTO: Decodable, Sendable {
    let tokens: [String: [LiFiQuoteDTO.TokenInfo]]
}
