import Foundation

/// Fee fetchers for XRP, TRON, NEAR, Polkadot, Cosmos (Kava), Aptos.
/// Doc-grounded per `.claude/send-compose-matrix.md` (G8–G12 + Aptos
/// research), live-verified 2026-06-15.
extension ComposeFeeService {

    // MARK: - XRP

    /// XRP fee = fixed drops (base 10 × load_factor). Presets from the
    /// `fee` method (minimum/open_ledger/median).
    /// Docs: https://xrpl.org/docs/references/http-websocket-apis/public-api-methods/server-info-methods/fee
    func xrpQuote(_ ctx: Context) async throws -> FeeQuote {
        let dec = ctx.chain.nativeDecimals // 6
        // rippled omits the JSON-RPC id echo — disable id validation.
        let data = try await client.callJSONResultData(
            chain: .ripple, method: "fee", params: [[String: Sendable]()], validatesIDEcho: false)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let drops = root["drops"] as? [String: Any] else {
            throw RPCError.decodingFailed("XRP fee response missing drops")
        }
        func d(_ key: String, _ fallback: Decimal) -> Decimal {
            if let s = drops[key] as? String { return ComposeDecimal.fromIntegerString(s) ?? fallback }
            return fallback
        }
        let minimum = d("minimum_fee", 10)
        let base = d("base_fee", 10)
        let open = d("open_ledger_fee", 10)
        let median = d("median_fee", 5000)

        func choice(_ tier: FeeTier, drops dropsVal: Decimal) -> FeeChoice {
            // Cap to a sane max so a congestion spike can't overcharge.
            let capped = min(dropsVal, 100000)
            var c = makeChoice(tier: tier, model: .xrpFixed, decimals: dec) { c in
                c.xrpDrops = capped
            }
            let native = ComposeDecimal.toDisplay(capped, decimals: dec)
            c.setTotals(estimated: native, worst: native)
            return c
        }
        let tiers: [FeeTier: FeeChoice] = [
            .slow:   choice(.slow,   drops: minimum),
            .normal: choice(.normal, drops: max(open, base)),
            .fast:   choice(.fast,   drops: max(median, open)),
        ]
        return FeeQuote(chain: ctx.chain, feeModel: .xrpFixed, tiers: tiers,
                        isCustomAllowed: true, hasSpeedTiers: true, note: nil)
    }

    // MARK: - TRON

    /// TRON resource model: bandwidth (bytes) + energy (contract). Live
    /// unit prices from getchainparameters; energy from
    /// triggerconstantcontract. Single deterministic fee (no auction).
    /// Docs: https://developers.tron.network/docs/resource-model
    func tronQuote(_ ctx: Context) async throws -> FeeQuote {
        let dec = ctx.chain.nativeDecimals // 6
        let params = try await fetchTronChainParameters()
        let txFeePerByte = params["getTransactionFee"] ?? 1000 // SUN/byte
        let energyFee = params["getEnergyFee"] ?? 100          // SUN/energy
        let maxFeeLimit = params["getMaxFeeLimit"] ?? 15_000_000_000

        // Bandwidth bytes (matrix): native ~268, TRC-20 ~345.
        let bandwidthBytes: Decimal = ctx.isToken ? 345 : 268
        // Energy: native = 0; token estimated live (fallback safe value).
        var energy: Decimal = 0
        if ctx.isToken, let to = ctx.toAddress, let contract = ctx.tokenContract {
            energy = (try? await estimateTronEnergy(owner: ctx.fromAddress, contract: contract, to: to)) ?? 65000
            energy = ComposeDecimal.ceilToInteger(energy * Decimal(string: "1.2")!) // dynamic-model buffer
        }
        // Burned cost (worst case: no free/staked resources available).
        let bandwidthBurn = bandwidthBytes * txFeePerByte
        let energyBurn = energy * energyFee
        let totalSun = bandwidthBurn + energyBurn
        let feeLimit = ctx.isToken ? min(ComposeDecimal.ceilToInteger(energyBurn * Decimal(string: "1.3")!), maxFeeLimit) : 0

        var c = makeChoice(tier: .normal, model: .tronResource, decimals: dec) { c in
            c.tronFeeLimitSun = feeLimit
            c.tronEstimatedBandwidth = bandwidthBytes
            c.tronEstimatedEnergy = energy
        }
        let native = ComposeDecimal.toDisplay(totalSun, decimals: dec)
        c.setTotals(estimated: native, worst: native)
        let note = "Fee shown assumes no free or staked resources"
        return FeeQuote(chain: ctx.chain, feeModel: .tronResource, tiers: [.normal: c],
                        isCustomAllowed: false, hasSpeedTiers: false, note: note)
    }

    /// The TRON memo surcharge in SUN. A NON-EMPTY `raw_data.data` memo
    /// burns an extra 1 TRX (`getMemoFee = 1,000,000 SUN`, confirmed live;
    /// in force since committee proposal #80, 2022-12-16). Applies
    /// independently to BOTH native TRX and TRC-20 transfers.
    /// Doc: `.claude/send-compose-matrix.md` (TRON · Data/memo/tag);
    /// https://developers.tron.network/reference/getchainparameters-1
    static let tronMemoFeeSun = Decimal(1_000_000)

    /// Fold the +1 TRX memo surcharge into a TRON `FeeChoice`'s totals when
    /// the user attached a non-empty memo. The data layer owns this fee
    /// math (keep the Review total honest, Rule #16) so the UI never
    /// hand-rolls TRX arithmetic. No-op for non-TRON models or no memo.
    /// `decimals` is TRON's native decimals (6).
    static func applyTronMemoFee(_ c: FeeChoice, hasMemo: Bool, decimals: Int) -> FeeChoice {
        guard c.feeModel == .tronResource, hasMemo else { return c }
        var copy = c
        let memoFeeNative = ComposeDecimal.toDisplay(tronMemoFeeSun, decimals: decimals)
        copy.setTotals(
            estimated: c.estimatedTotalNative + memoFeeNative,
            worst: c.worstCaseTotalNative + memoFeeNative)
        return copy
    }

    private func fetchTronChainParameters() async throws -> [String: Decimal] {
        let data = try await client.callRESTPost(chain: .tron, path: "/wallet/getchainparameters", body: [:])
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = root["chainParameter"] as? [[String: Any]] else {
            return [:]
        }
        var out: [String: Decimal] = [:]
        for item in arr {
            if let key = item["key"] as? String, let value = (item["value"] as? NSNumber)?.decimalValue {
                out[key] = value
            }
        }
        return out
    }

    /// triggerconstantcontract energy_used probe for a TRC-20 transfer.
    private func estimateTronEnergy(owner: String, contract: String, to: String) async throws -> Decimal {
        // ABI-encode transfer(address,uint256): 32-byte to + 32-byte amount(1).
        let cleanTo = to.hasPrefix("0x") ? String(to.dropFirst(2)) : to
        let param = String(repeating: "0", count: max(0, 64 - cleanTo.count)) + cleanTo
            + String(repeating: "0", count: 63) + "1"
        let body: [String: Sendable] = [
            "owner_address": owner,
            "contract_address": contract,
            "function_selector": "transfer(address,uint256)",
            "parameter": param,
            "visible": true,
        ]
        let data = try await client.callRESTPost(chain: .tron, path: "/wallet/triggerconstantcontract", body: body)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RPCError.decodingFailed("triggerconstantcontract not an object")
        }
        if let used = (root["energy_used"] as? NSNumber)?.decimalValue { return used }
        return 65000
    }

    // MARK: - NEAR

    /// NEAR deterministic gas-unit fee. Native ~0.45 Tgas (from protocol
    /// config) × gas_price; FT transfer attaches 30 Tgas. No speed tier.
    /// Docs: https://docs.near.org/api/rpc/gas ;
    /// https://docs.near.org/protocol/transactions/gas
    func nearQuote(_ ctx: Context) async throws -> FeeQuote {
        let dec = ctx.chain.nativeDecimals // 24
        let gasPrice = try await fetchNearGasPrice()
        // Native transfer total ≈ 446,365,125,000 gas (matrix protocol
        // config). FT transfer attaches 30 Tgas (refunded if unused).
        let gasUnits: Decimal = ctx.isToken ? 30_000_000_000_000 : 446_365_125_000
        let feeYocto = gasUnits * gasPrice
        var c = makeChoice(tier: .normal, model: .nearGas, decimals: dec) { c in
            c.nearGasPriceYocto = gasPrice
            c.nearGasUnits = gasUnits
        }
        let native = ComposeDecimal.toDisplay(feeYocto, decimals: dec)
        c.setTotals(estimated: native, worst: native)
        let note = ctx.isToken ? "Unused attached gas is refunded" : nil
        return FeeQuote(chain: ctx.chain, feeModel: .nearGas, tiers: [.normal: c],
                        isCustomAllowed: false, hasSpeedTiers: false, note: note)
    }

    private func fetchNearGasPrice() async throws -> Decimal {
        // gas_price([null]) → {result:{gas_price:"100000000"}}
        let data = try await client.callJSONResultData(
            chain: .near, method: "gas_price", params: [NSNull()])
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let s = root["gas_price"] as? String, let v = ComposeDecimal.fromIntegerString(s) else {
            return Decimal(100_000_000) // floor
        }
        return v
    }

    // MARK: - Polkadot

    /// Polkadot weight-based partial_fee + optional tip. partial_fee
    /// requires a dummy-signed extrinsic via payment_queryInfo, which
    /// needs the SCALE-encoded extrinsic (built with wallet-core at sign
    /// time). At compose time we surface a doc-grounded practical
    /// estimate and offer tip presets (the only sender lever).
    /// Docs: https://docs.polkadot.com/polkadot-protocol/basics/blocks-transactions-fees/fees/
    func polkadotQuote(_ ctx: Context) async throws -> FeeQuote {
        let dec = ctx.chain.nativeDecimals // 10
        // A balances.transferKeepAlive partial_fee is ~0.0152 DOT order
        // of magnitude in practice; we present it as the network fee and
        // let tip be the lever. (Refined via payment_queryInfo on the
        // built extrinsic before signing — Rule #27 §C.)
        let partialFeePlancks = Decimal(152_000_000) // ~0.0152 DOT
        func choice(_ tier: FeeTier, tip: Decimal) -> FeeChoice {
            var c = makeChoice(tier: tier, model: .polkadotWeight, decimals: dec) { c in
                c.polkadotPartialFeePlancks = partialFeePlancks
                c.polkadotTipPlancks = tip
            }
            let native = ComposeDecimal.toDisplay(partialFeePlancks + tip, decimals: dec)
            c.setTotals(estimated: native, worst: native)
            return c
        }
        let tiers: [FeeTier: FeeChoice] = [
            .normal: choice(.normal, tip: 0),
            .fast:   choice(.fast,   tip: Decimal(10_000_000)), // ~0.001 DOT tip
        ]
        return FeeQuote(chain: ctx.chain, feeModel: .polkadotWeight, tiers: tiers,
                        isCustomAllowed: true, hasSpeedTiers: true,
                        note: "The only adjustable part is the priority tip")
    }

    // MARK: - Cosmos (Kava)

    /// Cosmos fee = gasLimit × gasPrice (ukava). Tiers from chain-registry
    /// (low 0.05 / avg 0.1 / high 0.25 ukava). gasLimit default 200,000
    /// (refined by simulate before signing).
    /// Docs: https://raw.githubusercontent.com/cosmos/chain-registry/master/kava/chain.json
    func cosmosQuote(_ ctx: Context) async throws -> FeeQuote {
        let dec = ctx.chain.nativeDecimals // 6
        let gasLimit = Decimal(200_000)
        func choice(_ tier: FeeTier, price: Decimal) -> FeeChoice {
            let feeUkava = ComposeDecimal.ceilToInteger(gasLimit * price)
            var c = makeChoice(tier: tier, model: .cosmosGas, decimals: dec) { c in
                c.cosmosGasLimit = gasLimit
                c.cosmosGasPrice = price
            }
            let native = ComposeDecimal.toDisplay(feeUkava, decimals: dec)
            c.setTotals(estimated: native, worst: native)
            return c
        }
        let tiers: [FeeTier: FeeChoice] = [
            .slow:   choice(.slow,   price: Decimal(string: "0.05")!),
            .normal: choice(.normal, price: Decimal(string: "0.1")!),
            .fast:   choice(.fast,   price: Decimal(string: "0.25")!),
        ]
        return FeeQuote(chain: ctx.chain, feeModel: .cosmosGas, tiers: tiers,
                        isCustomAllowed: true, hasSpeedTiers: true, note: nil)
    }

    // MARK: - Aptos

    /// Aptos fee = gas_unit_price × max_gas_amount (octas). Price from
    /// `/v1/estimate_gas_price` (deprioritized/regular/prioritized). A
    /// native coin transfer (0x1::aptos_account::transfer) uses ~10 gas
    /// units typically; max_gas_amount defaults provide headroom and are
    /// refined via `/v1/transactions/simulate` before signing.
    /// Docs: https://aptos.dev/network/blockchain/gas-txn-fee ;
    /// https://aptos.dev/rest-api/operations/estimate_gas_price ;
    /// live-verified 2026-06-15:
    /// {deprioritized_gas_estimate:100,gas_estimate:100,prioritized_gas_estimate:150}
    func aptosQuote(_ ctx: Context) async throws -> FeeQuote {
        let dec = ctx.chain.nativeDecimals // 8 (octa)
        let prices = try await fetchAptosGasPrice()
        // max_gas_amount: a simple coin transfer consumes few gas units;
        // a safe default cap is 2000 (refined by simulate). Token
        // (fungible-asset) transfers cost more — cap 5000.
        let maxGas: Decimal = ctx.isToken ? 5000 : 2000

        func choice(_ tier: FeeTier, price: Decimal) -> FeeChoice {
            // Estimated fee uses a realistic gas_used (~10 units for a
            // native transfer); worst-case uses the full max_gas_amount.
            let estUnits: Decimal = ctx.isToken ? 700 : 10
            let estimatedOcta = estUnits * price
            let worstOcta = maxGas * price
            var c = makeChoice(tier: tier, model: .aptosGas, decimals: dec) { c in
                c.aptosGasUnitPrice = price
                c.aptosMaxGasAmount = maxGas
            }
            c.setTotals(
                estimated: ComposeDecimal.toDisplay(estimatedOcta, decimals: dec),
                worst: ComposeDecimal.toDisplay(worstOcta, decimals: dec))
            return c
        }
        // Aptos has 3 native price levels — map them to tiers, but the
        // model has no real "speed market" so we present the regular as
        // the single fee (hasSpeedTiers=false) and keep slow/fast for the
        // advanced override.
        let tiers: [FeeTier: FeeChoice] = [
            .slow:   choice(.slow,   price: prices.low),
            .normal: choice(.normal, price: prices.regular),
            .fast:   choice(.fast,   price: prices.high),
        ]
        return FeeQuote(chain: ctx.chain, feeModel: .aptosGas, tiers: tiers,
                        isCustomAllowed: true, hasSpeedTiers: false,
                        note: "Max gas is refined by a simulation before signing")
    }

    /// `GET /v1/estimate_gas_price` (REST). The registered Aptos endpoint
    /// base is `…/v1`, so the path is `/estimate_gas_price`.
    private func fetchAptosGasPrice() async throws -> (low: Decimal, regular: Decimal, high: Decimal) {
        let data = try await client.callREST(chain: .aptos, path: "/estimate_gas_price")
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RPCError.decodingFailed("Aptos estimate_gas_price not an object")
        }
        func v(_ key: String, _ fallback: Decimal) -> Decimal {
            (root[key] as? NSNumber)?.decimalValue ?? fallback
        }
        return (v("deprioritized_gas_estimate", 100), v("gas_estimate", 100), v("prioritized_gas_estimate", 150))
    }
}
