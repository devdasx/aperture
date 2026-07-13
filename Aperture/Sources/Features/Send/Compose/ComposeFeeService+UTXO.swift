import Foundation

/// UTXO-family fee fetchers. Doc-grounded per `.claude/send-compose-matrix.md`
/// (G1) — live-verified 2026-06-15.
extension ComposeFeeService {

    /// UTXO fee quote. Returns sat/vB (BTC/LTC), sat/byte (BCH) or
    /// koinu/byte (DOGE) preset rates. The total is estimated for a
    /// typical 1-input + 2-output tx; the real total is recomputed after
    /// coin selection in `UTXOService`.
    func utxoQuote(_ ctx: Context, model: ComposeFeeModel) async throws -> FeeQuote {
        let chain = ctx.chain
        let rates = try await fetchUTXORates(chain: chain, model: model)
        let dec = chain.nativeDecimals
        // Typical native transfer: 1 input + 2 outputs.
        let typicalVsize = typicalVsize(for: chain)

        func choice(_ tier: FeeTier, rate: Decimal) -> FeeChoice {
            let feeSats = ComposeDecimal.ceilToInteger(rate * Decimal(typicalVsize))
            var c = makeChoice(tier: tier, model: model, decimals: dec) { c in
                c.byteFeeRate = rate
            }
            let native = ComposeDecimal.toDisplay(feeSats, decimals: dec)
            c.setTotals(estimated: native, worst: native)
            return c
        }

        let tiers: [FeeTier: FeeChoice] = [
            .slow:   choice(.slow,   rate: rates.slow),
            .normal: choice(.normal, rate: rates.normal),
            .fast:   choice(.fast,   rate: rates.fast),
        ]
        let note = "Final fee depends on the coins selected"
        return FeeQuote(chain: chain, feeModel: model, tiers: tiers,
                        isCustomAllowed: true, hasSpeedTiers: true, note: note)
    }

    private struct UTXORates { let slow: Decimal; let normal: Decimal; let fast: Decimal }

    private func fetchUTXORates(chain: SupportedChain, model: ComposeFeeModel) async throws -> UTXORates {
        switch model {
        case .utxoByteFee:
            // BTC: **real** recommended sat/vB from mempool.space only
            // (never Blockstream, never Electrum `estimatefee`).
            // LTC: litecoinspace Esplora sibling of the same path.
            // Docs: https://mempool.space/docs/api/rest#get-v1-fees-recommended
            if chain == .bitcoin {
                return try await fetchMempoolSpaceRecommendedFees()
            }
            return try await fetchEsploraRecommended(chain: chain)
        case .utxoByteFeeNoWitness:
            // BCH — LIVE via the registered Blockbook provider's
            // `/api/v2/estimatefee/{blocks}` (BUG 2; Haskoin has no fee
            // endpoint). Blockbook returns BCH/kB; convert to sat/byte and
            // clamp ≥ 1 (relay floor). Falls back to the doc-grounded 1
            // sat/byte network default when the oracle is unreachable.
            // Docs: https://github.com/trezor/blockbook/blob/master/docs/api.md ;
            // reference.cash min relay = 1 sat/byte.
            return await fetchBCHRates()
        case .dogecoinFixedPerKB:
            // DOGE — Dogecoin Core fee-recommendation.md (koinu/byte; 1 DOGE
            // = 1e8 koinu): slow/min = MIN RELAY 0.001 DOGE/kB = 100,000
            // koinu/1000B = 100 koinu/byte (the hard floor); normal =
            // RECOMMENDED 0.01 DOGE/kB = 1,000,000 koinu/1000B = 1000
            // koinu/byte (what DOGE wallets ship + what confirms). FAST is
            // now LIVE (BUG 2): the registered primary provider BlockCypher
            // `/v1/doge/main`.high_fee_per_kb (koinu/kB ÷ 1000 = koinu/byte)
            // reflects the current market upper rate (live-verified
            // 2026-06-15 high_fee_per_kb ≈ 200,247,134 koinu/kB ≈ 200,247
            // koinu/byte). The matrix's guidance: doc-grounded floor for
            // slow/normal, live market high for fast. Docs:
            // github.com/dogecoin/dogecoin/blob/master/doc/fee-recommendation.md ;
            // https://www.blockcypher.com/dev/bitcoin/#blockchain-api
            let liveFast = await fetchDogecoinLiveFastRate()
            // fast = max(0.05 DOGE/kB doc floor, live market high).
            return UTXORates(slow: 100, normal: 1000, fast: max(5000, liveFast))
        default:
            throw RPCError.invalidResponse("Non-UTXO model in utxoQuote")
        }
    }

    /// Bitcoin fee ladder — mempool.space only, via `RPCClient` / shared
    /// rate limiter + circuit breaker (P1 #9 — never a bare URLSession).
    private func fetchMempoolSpaceRecommendedFees() async throws -> UTXORates {
        let rates = try await BitcoinMempoolSpaceClient.shared.recommendedFees()
        return UTXORates(slow: rates.slow, normal: rates.normal, fast: rates.fast)
    }

    /// Esplora recommended fees for non-BTC chains that share the shape
    /// (LTC → litecoinspace via registry). Path: `/v1/fees/recommended`
    /// → {fastestFee, halfHourFee, hourFee, economyFee, minimumFee}.
    private func fetchEsploraRecommended(chain: SupportedChain) async throws -> UTXORates {
        let data = try await client.callREST(chain: chain, path: "/v1/fees/recommended")
        return try parseEsploraRecommendedFees(data)
    }

    /// Shared decoder for Esplora-style recommended fee JSON (integer sat/vB).
    private func parseEsploraRecommendedFees(_ data: Data) throws -> UTXORates {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RPCError.decodingFailed("recommended fees not an object")
        }
        func rate(_ key: String) throws -> Decimal {
            // `decimalValue` bridges NSNumber → Decimal without a Double
            // round-trip (ComposeDecimal contract). Esplora returns integer
            // sat/vB so this is exact.
            guard let n = root[key] as? NSNumber else {
                throw RPCError.decodingFailed("recommended fees missing \(key)")
            }
            return n.decimalValue
        }
        // Real market ladder — no invented floors beyond the server's own minimumFee.
        let minFee = try rate("minimumFee")
        let slow = max(try rate("economyFee"), minFee)
        let normal = max(try rate("halfHourFee"), minFee)
        let fast = max(try rate("fastestFee"), minFee)
        guard slow > 0, normal > 0, fast > 0 else {
            throw RPCError.decodingFailed("recommended fees non-positive")
        }
        return UTXORates(slow: slow, normal: normal, fast: fast)
    }

    /// BCH live fee rate from the registered Blockbook provider
    /// `/api/v2/estimatefee/{blocks}` (BUG 2). Blockbook returns BCH/kB as a
    /// decimal string; convert to sat/byte (× 1e8 ÷ 1000 = × 100,000) and
    /// clamp to the 1 sat/byte relay floor. slow=12-block, normal=6-block,
    /// fast=2-block targets. Tolerant: any failed leg keeps the doc-grounded
    /// 1 sat/byte default (reference.cash min relay; BCH mempool is near-empty
    /// so 1 sat/byte confirms — live-verified 2026-06-15 estimatefee →
    /// "0.00001" BCH/kB = 1 sat/byte). NEVER fabricates beyond the doc floor.
    private func fetchBCHRates() async -> UTXORates {
        async let slowF = fetchBlockbookSatPerByte(blocks: 12)
        async let normalF = fetchBlockbookSatPerByte(blocks: 6)
        async let fastF = fetchBlockbookSatPerByte(blocks: 2)
        let (slow, normal, fast) = await (slowF, normalF, fastF)
        return UTXORates(
            slow: max(slow, 1),
            normal: max(normal, 1),
            fast: max(fast, max(normal, 1), 2))
    }

    /// One Blockbook `estimatefee/{blocks}` call → sat/byte. Returns 0 on any
    /// failure (caller clamps to the relay floor).
    private func fetchBlockbookSatPerByte(blocks: Int) async -> Decimal {
        guard let data = try? await client.callREST(
                chain: .bitcoinCash, path: "/api/v2/estimatefee/\(blocks)"),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let s = root["result"] as? String,
              let bchPerKb = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")),
              bchPerKb > 0 else {
            return 0
        }
        // BCH/kB → sat/byte: × 1e8 (BCH→sat) ÷ 1000 (kB→byte) = × 100,000.
        return ComposeDecimal.ceilToInteger(bchPerKb * Decimal(100_000))
    }

    /// DOGE live market FAST rate (koinu/byte) from the registered primary
    /// BlockCypher provider `/v1/doge/main`.high_fee_per_kb ÷ 1000 (BUG 2 ·
    /// make DOGE's fast tier live, not a static guess). Tolerant: returns 0
    /// on any failure so the caller keeps the doc-grounded 0.05 DOGE/kB floor
    /// — never fabricates and never throws away the whole quote for the fast
    /// tier alone. Doc: https://www.blockcypher.com/dev/bitcoin/#blockchain-api
    private func fetchDogecoinLiveFastRate() async -> Decimal {
        guard let data = try? await client.callREST(chain: .dogecoin, path: ""),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let highPerKb = (root["high_fee_per_kb"] as? NSNumber)?.decimalValue,
              highPerKb > 0 else {
            return 0
        }
        // koinu/kB → koinu/byte. (BlockCypher's "kb" is 1000 bytes.)
        return ComposeDecimal.ceilToInteger(highPerKb / 1000)
    }

    /// Typical vsize for a 1-input + 2-output native transfer (matrix
    /// per-input/output constants).
    private func typicalVsize(for chain: SupportedChain) -> Int {
        switch chain {
        case .bitcoin, .litecoin:
            // overhead 10.5 + 1×68 (P2WPKH in) + 2×31 (P2WPKH out) ≈ 141
            return 141
        case .bitcoinCash:
            // 10 + 1×148 + 2×34 = 226
            return 226
        case .dogecoin:
            // 10 + 1×148 + 2×34 = 226 (no segwit)
            return 226
        default:
            return 226
        }
    }
}
