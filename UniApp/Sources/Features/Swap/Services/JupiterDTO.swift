import Foundation

/// Decodable mirror of the Jupiter `GET /quote` response.
///
/// **Doc-grounded** against the Jupiter Swap API quote reference
/// (https://dev.jup.ag/docs/swap-api/get-quote, swagger
/// `jup-ag/jupiter-quote-api-node`) and live-verified 2026-06-15
/// (1 SOL → USDC on `lite-api.jup.ag`). `Codable` so the execute turn
/// can re-encode the exact quote back to Jupiter `/swap`.
struct JupiterQuoteDTO: Codable, Sendable {
    let inputMint: String
    let inAmount: String
    let outputMint: String
    let outAmount: String
    let otherAmountThreshold: String
    let swapMode: String?
    let slippageBps: Int
    let priceImpactPct: String?
    let routePlan: [RoutePlan]?
    let contextSlot: Int?
    let timeTaken: Double?

    struct RoutePlan: Codable, Sendable {
        let swapInfo: SwapInfo?
        let percent: Int?
    }

    struct SwapInfo: Codable, Sendable {
        let ammKey: String?
        let label: String?
        let inputMint: String?
        let outputMint: String?
        let inAmount: String?
        let outAmount: String?
        let feeAmount: String?
        let feeMint: String?
    }
}

// MARK: - Jupiter token (v2 tag list)

/// One token from Jupiter's Token API v2 (`/tokens/v2/tag?query=verified`).
/// Live-verified 2026-06-15 — fields `id` (the mint), `symbol`, `name`,
/// `decimals`, `icon`.
struct JupiterTokenDTO: Decodable, Sendable {
    let id: String
    let symbol: String
    let name: String?
    let decimals: Int
    let icon: String?
}
