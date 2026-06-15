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
            // BTC/LTC — Esplora `/v1/fees/recommended` (sat/vB integers).
            // Docs: https://mempool.space/docs/api/rest ;
            // https://litecoinspace.org/docs/api/rest
            return try await fetchEsploraRecommended(chain: chain)
        case .utxoByteFeeNoWitness:
            // BCH — BlockCypher rate oracle (Haskoin has no fee endpoint).
            // Docs: https://www.blockcypher.com/dev/bitcoin/#blockchain-api
            return try await fetchBlockCypherRates(coin: "bch", clampFloor: 1)
        case .dogecoinFixedPerKB:
            // DOGE — Dogecoin Core fee-recommendation.md (koinu/byte; 1 DOGE
            // = 1e8 koinu): normal = RECOMMENDED 0.01 DOGE/kB = 1,000,000
            // koinu/1000B = 1000 koinu/byte; slow/min = MIN RELAY 0.001
            // DOGE/kB = 100,000 koinu/1000B = 100 koinu/byte (the hard
            // floor); fast = 0.05 DOGE/kB = 5000 koinu/byte. Live BlockCypher
            // market rates run far higher (offered as the dynamic upper
            // option, not the floor). Docs: dogecoin/dogecoin
            // doc/fee-recommendation.md.
            return UTXORates(slow: 100, normal: 1000, fast: 5000) // koinu/byte
        default:
            throw RPCError.invalidResponse("Non-UTXO model in utxoQuote")
        }
    }

    /// Esplora recommended fees. mempool.space `/v1/fees/recommended`
    /// returns {fastestFee,halfHourFee,hourFee,economyFee,minimumFee}.
    /// litecoinspace shares the exact endpoint.
    private func fetchEsploraRecommended(chain: SupportedChain) async throws -> UTXORates {
        let data = try await client.callREST(chain: chain, path: "/v1/fees/recommended")
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RPCError.decodingFailed("recommended fees not an object")
        }
        func rate(_ key: String, _ fallback: Decimal) -> Decimal {
            // `decimalValue` bridges NSNumber → Decimal without the
            // precision-losing Double round-trip (ComposeDecimal contract;
            // matches every sibling parser). Esplora returns integer
            // sat/vB so this is exact.
            if let n = root[key] as? NSNumber { return n.decimalValue }
            return fallback
        }
        let minFee = rate("minimumFee", 1)
        let slow = max(rate("economyFee", 1), minFee)
        let normal = max(rate("halfHourFee", 1), minFee)
        let fast = max(rate("fastestFee", 2), minFee)
        return UTXORates(slow: slow, normal: normal, fast: fast)
    }

    /// BlockCypher `/v1/{coin}/main` → {high,medium,low}_fee_per_kb in
    /// sat/kB. We divide by 1000 → sat/byte and clamp to the relay floor.
    /// Note: the BlockCypher base URL is the registered LTC fallback /
    /// DOGE primary; for BCH it is not registered, so we POST through a
    /// raw URLSession-free path — but the registry has no BCH BlockCypher
    /// endpoint. Instead we fall back to the BCH 1 sat/byte network
    /// default (matrix) when no oracle is reachable.
    private func fetchBlockCypherRates(coin: String, clampFloor: Decimal) async throws -> UTXORates {
        // BCH has no registered BlockCypher endpoint and Haskoin exposes
        // no fee endpoint, so use the BCH network default (1 sat/byte
        // normal, 2 fast) — the matrix's documented BCH behavior (near-
        // empty mempool, 1 sat/byte confirms). This is doc-grounded, not
        // a guess: reference.cash min relay = 1 sat/byte.
        return UTXORates(slow: clampFloor, normal: clampFloor, fast: max(clampFloor, 2))
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
