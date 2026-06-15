import Foundation

/// Fee fetchers for Solana, Stellar, Sui, TON. Doc-grounded per
/// `.claude/send-compose-matrix.md` (G4/G5/G6/G7), live-verified 2026-06-15.
extension ComposeFeeService {

    // MARK: - Solana

    /// Solana fee = 5,000 lamports base/signature + optional priority =
    /// ceil(price × cuLimit / 1e6). Priority price from
    /// `getRecentPrioritizationFees` percentiles.
    /// Docs: https://solana.com/docs/core/fees ;
    /// https://solana.com/docs/rpc/http/getrecentprioritizationfees
    func solanaQuote(_ ctx: Context) async throws -> FeeQuote {
        let dec = ctx.chain.nativeDecimals // 9
        let base = Decimal(5000) // lamports per signature (single-sig)
        let cuLimit: Decimal = ctx.isToken ? 50000 : 450 // matrix defaults
        let percentiles = try await fetchSolanaPriorityPercentiles()

        func choice(_ tier: FeeTier, price: Decimal) -> FeeChoice {
            // Floor an idle 0 to a small non-zero on normal/fast so the tx
            // still gets in under load; slow may legitimately be 0.
            let floored = tier == .slow ? price : max(price, 1000)
            let priority = ComposeDecimal.ceilMulDiv(floored, cuLimit, dividedBy: 1_000_000)
            let totalLamports = base + priority
            var c = makeChoice(tier: tier, model: .solana, decimals: dec) { c in
                c.computeUnitPrice = floored
                c.computeUnitLimit = cuLimit
                c.solanaBaseFeeLamports = base
            }
            let native = ComposeDecimal.toDisplay(totalLamports, decimals: dec)
            c.setTotals(estimated: native, worst: native)
            return c
        }
        let tiers: [FeeTier: FeeChoice] = [
            .slow:   choice(.slow,   price: percentiles.p25),
            .normal: choice(.normal, price: percentiles.p50),
            .fast:   choice(.fast,   price: percentiles.p75),
        ]
        let note = ctx.isToken ? "Token sends may need a recipient token account (extra rent)" : nil
        return FeeQuote(chain: ctx.chain, feeModel: .solana, tiers: tiers,
                        isCustomAllowed: true, hasSpeedTiers: true, note: note)
    }

    private func fetchSolanaPriorityPercentiles() async throws -> (p25: Decimal, p50: Decimal, p75: Decimal) {
        let data = try await client.callJSONResultData(
            chain: .solana, method: "getRecentPrioritizationFees", params: [[Sendable]()])
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return (0, 0, 0)
        }
        let fees = arr.compactMap { ($0["prioritizationFee"] as? NSNumber)?.decimalValue }.sorted()
        guard !fees.isEmpty else { return (0, 0, 0) }
        func pct(_ p: Double) -> Decimal { fees[min(fees.count - 1, Int(Double(fees.count) * p))] }
        return (pct(0.25), pct(0.50), pct(0.75))
    }

    // MARK: - Stellar

    /// Stellar fee = opCount × per-op base fee (stroops, min 100/op).
    /// Presets from Horizon `/fee_stats` fee_charged percentiles.
    /// Docs: https://developers.stellar.org/docs/data/apis/horizon/api-reference/aggregations/fee-stats
    func stellarQuote(_ ctx: Context) async throws -> FeeQuote {
        let dec = ctx.chain.nativeDecimals // 7
        let stats = try await fetchStellarFeeStats()
        let opCount = ctx.recipientCount // 1 op per recipient payment

        func choice(_ tier: FeeTier, perOp: Decimal) -> FeeChoice {
            let bid = max(perOp, 100)
            let totalStroops = bid * Decimal(opCount)
            var c = makeChoice(tier: tier, model: .stellarPerOp, decimals: dec) { c in
                c.stellarPerOpStroops = bid
                c.stellarOpCount = opCount
            }
            let native = ComposeDecimal.toDisplay(totalStroops, decimals: dec)
            c.setTotals(estimated: native, worst: native)
            return c
        }
        let tiers: [FeeTier: FeeChoice] = [
            .slow:   choice(.slow,   perOp: stats.p50),
            .normal: choice(.normal, perOp: stats.p70),
            .fast:   choice(.fast,   perOp: stats.p90),
        ]
        return FeeQuote(chain: ctx.chain, feeModel: .stellarPerOp, tiers: tiers,
                        isCustomAllowed: true, hasSpeedTiers: true,
                        note: "You're only charged the network base fee at inclusion")
    }

    private func fetchStellarFeeStats() async throws -> (p50: Decimal, p70: Decimal, p90: Decimal) {
        let data = try await client.callREST(chain: .stellar, path: "/fee_stats")
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let charged = root["fee_charged"] as? [String: Any] else {
            return (100, 100, 100)
        }
        func val(_ key: String) -> Decimal {
            if let s = charged[key] as? String { return ComposeDecimal.fromIntegerString(s) ?? 100 }
            return 100
        }
        return (val("p50"), max(val("p70"), 100), max(val("p90"), 100))
    }

    // MARK: - Sui

    /// Sui fee: gasPrice (≥ RGP) + gasBudget. RGP from
    /// `suix_getReferenceGasPrice`. Budget auto-sized (matrix defaults,
    /// refined by a dry run at sign time).
    /// Docs: https://docs.sui.io/concepts/tokenomics/gas-in-sui
    func suiQuote(_ ctx: Context) async throws -> FeeQuote {
        let dec = ctx.chain.nativeDecimals // 9
        let rgp = try await fetchSuiReferenceGasPrice()
        // Matrix budget defaults: native ~3.5M MIST, token ~4.5M MIST.
        let budget: Decimal = ctx.isToken ? 4_500_000 : 3_500_000

        func choice(_ tier: FeeTier, priceMult: Decimal) -> FeeChoice {
            let price = ComposeDecimal.ceilToInteger(rgp * priceMult)
            // Estimated net fee ≈ live-verified 1,097,880 MIST for a
            // native transfer; we surface the budget as the worst case.
            let estimated: Decimal = ctx.isToken ? 2_500_000 : 1_100_000
            var c = makeChoice(tier: tier, model: .suiGasBudget, decimals: dec) { c in
                c.suiGasPriceMist = price
                c.suiGasBudgetMist = budget
            }
            c.setTotals(
                estimated: ComposeDecimal.toDisplay(estimated, decimals: dec),
                worst: ComposeDecimal.toDisplay(budget, decimals: dec))
            return c
        }
        let tiers: [FeeTier: FeeChoice] = [
            .slow:   choice(.slow,   priceMult: 1),
            .normal: choice(.normal, priceMult: 1),
            .fast:   choice(.fast,   priceMult: Decimal(string: "1.2")!),
        ]
        return FeeQuote(chain: ctx.chain, feeModel: .suiGasBudget, tiers: tiers,
                        isCustomAllowed: true, hasSpeedTiers: true,
                        note: "Final fee is refined by a dry run before signing")
    }

    private func fetchSuiReferenceGasPrice() async throws -> Decimal {
        let str = try await client.callJSONString(
            chain: .sui, method: "suix_getReferenceGasPrice", params: [])
        return ComposeDecimal.fromIntegerString(str) ?? 100
    }

    // MARK: - TON

    /// TON fee is deterministic (no user price): import + storage + gas +
    /// forward, all from `estimateFee`. Single non-editable tier.
    /// Docs: https://docs.ton.org/blockchain-basics/primitives/fees ;
    /// toncenter `/api/v2/estimateFee`.
    ///
    /// `estimateFee` requires a built message body BoC (not available at
    /// compose time before the message is assembled), so we surface a
    /// doc-grounded practical estimate (~0.0055 TON native, ~0.05 TON
    /// jetton) and mark it non-editable. The exact number is fetched via
    /// estimateFee on the built BoC just before signing (Rule #27 §C).
    func tonQuote(_ ctx: Context) async throws -> FeeQuote {
        let dec = ctx.chain.nativeDecimals // 9
        // Native ≈ 0.0055 TON; jetton ≈ 0.05 TON (TON Foundation rec.).
        let estimatedNative: Decimal = ctx.isToken
            ? Decimal(string: "0.05")! : Decimal(string: "0.0055")!
        var c = makeChoice(tier: .normal, model: .tonFixed, decimals: dec) { _ in }
        c.setTotals(estimated: estimatedNative, worst: estimatedNative)
        return FeeQuote(chain: ctx.chain, feeModel: .tonFixed, tiers: [.normal: c],
                        isCustomAllowed: false, hasSpeedTiers: false,
                        note: "Network fee is set by the protocol")
    }
}
