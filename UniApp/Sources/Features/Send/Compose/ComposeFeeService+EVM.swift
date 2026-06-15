import Foundation

/// EVM fee fetchers. Doc-grounded per `.claude/send-compose-matrix.md`
/// (G2/G3) — Ethereum JSON-RPC spec + per-chain quirks. Live-verified
/// 2026-06-15 on publicnode endpoints.
extension ComposeFeeService {

    // MARK: - EIP-1559 (+ optional L1 data fee, + zkSync pubdata)

    /// EIP-1559 quote.
    /// Docs: https://eips.ethereum.org/EIPS/eip-1559 ;
    /// method `eth_feeHistory` (baseFeePerGas[N+1], reward[block][pct]) ;
    /// https://ethereum.org/en/developers/docs/apis/json-rpc/
    func evm1559Quote(_ ctx: Context, model: ComposeFeeModel) async throws -> FeeQuote {
        let chain = ctx.chain
        // Next-block base fee + percentile tips over ~20 blocks.
        let history = try await fetchFeeHistory(chain: chain)
        let baseNext = history.nextBaseFee
        let tips = history.tips // (p25, p50, p75) aggregated, floored

        let gasLimit = try await estimateGasLimit(ctx)

        // zkSync needs gasPerPubdata; OP-stack chains need the L1 data fee.
        // zkSync Era fee model (docs.zksync.io fee-model/fee-structure):
        // fee = gasLimit × gasPrice where the RETURNED gasLimit already
        // FOLDS IN the pubdata cost (gasLimit = compute + pubdata ×
        // gasPerPubdata). So `gasPerPubdataLimit` is carried as an EIP-712
        // SIGNING field only — it is NOT added to the fee total here (doing
        // so would double-count pubdata). The 1559 envelope (maxFee/tip)
        // applies on Era, so the standard gasLimit × (base+tip) estimate is
        // correct and pubdata-inclusive.
        var pubdata: Decimal?
        if model == .zkSyncEra {
            pubdata = await fetchZkSyncGasPerPubdata(chain: chain)
        }
        var l1DataFee: Decimal?
        if model == .evm1559PlusL1Data {
            l1DataFee = try await fetchOpStackL1Fee(ctx, gasLimit: gasLimit)
        }

        // Per-chain tip floors (matrix): Polygon 25 gwei, Kava EVM ≥
        // eth_gasPrice (1 gwei).
        let tipFloor = tipFloorWei(for: chain)
        let dec = chain.nativeDecimals

        func choice(_ tier: FeeTier, tip: Decimal, baseBuffer: Decimal) -> FeeChoice {
            let clampedTip = max(tip, tipFloor)
            let maxFee = baseNext * baseBuffer + clampedTip
            var c = makeChoice(tier: tier, model: model, decimals: dec) { c in
                c.maxFeePerGasWei = maxFee
                c.maxPriorityFeePerGasWei = clampedTip
                c.baseFeePerGasWei = baseNext
                c.gasLimit = gasLimit
                c.l1DataFeeWei = l1DataFee
                c.gasPerPubdataLimit = pubdata
            }
            // Expected = gasLimit × (baseNext + tip) [+ L1]; worst-case =
            // gasLimit × maxFee [+ L1] (reserve the ceiling for Max). The
            // data layer owns this fee math (FIX 6) so the UI's custom path
            // recomputes via `ComposeFeeService.recomputeEVMTotals`.
            c = ComposeFeeService.recomputeEVMTotals(c, decimals: dec)
            return c
        }

        let tiers: [FeeTier: FeeChoice] = [
            .slow:   choice(.slow,   tip: tips.p25, baseBuffer: Decimal(string: "1.25")!),
            .normal: choice(.normal, tip: tips.p50, baseBuffer: 2),
            .fast:   choice(.fast,   tip: tips.p75, baseBuffer: Decimal(string: "2.5")!),
        ]

        let note = noteFor(model: model, l1DataFee: l1DataFee, decimals: dec)
        return FeeQuote(chain: chain, feeModel: model, tiers: tiers,
                        isCustomAllowed: true, hasSpeedTiers: true, note: note)
    }

    // MARK: - Legacy (BNB Chain)

    /// Legacy quote. BSC base fee = 0, single gasPrice.
    /// Docs: https://docs.chainstack.com/reference/bnb-getgasprice ;
    /// method `eth_gasPrice`.
    func evmLegacyQuote(_ ctx: Context) async throws -> FeeQuote {
        let chain = ctx.chain
        let dec = chain.nativeDecimals
        let gasPrice = try await fetchGasPrice(chain: chain)
        let gasLimit = try await estimateGasLimit(ctx)

        func choice(_ tier: FeeTier, mult: Decimal) -> FeeChoice {
            let price = ComposeDecimal.ceilToInteger(gasPrice * mult)
            let c = makeChoice(tier: tier, model: .evmLegacy, decimals: dec) { c in
                c.gasPriceWei = price
                c.gasLimit = gasLimit
            }
            // Data layer owns the fee math (FIX 6); legacy is deterministic
            // (estimated == worst == gasLimit × gasPrice).
            return ComposeFeeService.recomputeEVMTotals(c, decimals: dec)
        }
        let tiers: [FeeTier: FeeChoice] = [
            .slow:   choice(.slow,   mult: 1),
            .normal: choice(.normal, mult: Decimal(string: "1.1")!),
            .fast:   choice(.fast,   mult: Decimal(string: "1.25")!),
        ]
        return FeeQuote(chain: chain, feeModel: .evmLegacy, tiers: tiers,
                        isCustomAllowed: true, hasSpeedTiers: true, note: nil)
    }

    // MARK: - RPC primitives

    private struct FeeHistory { let nextBaseFee: Decimal; let tips: (p25: Decimal, p50: Decimal, p75: Decimal) }

    /// `eth_feeHistory("0x14","latest",[25,50,75])`. The last element of
    /// baseFeePerGas is the predicted next-block base fee.
    private func fetchFeeHistory(chain: SupportedChain) async throws -> FeeHistory {
        let data = try await client.callJSONResultData(
            chain: chain, method: "eth_feeHistory",
            params: ["0x14", "latest", [25, 50, 75]])
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let baseArr = root["baseFeePerGas"] as? [String], let last = baseArr.last,
              let nextBase = ComposeDecimal.fromHexQuantity(last) else {
            // Fallback: no base fee (pre-London / stripped) → use gasPrice
            // as a single combined value, tip 0.
            let gp = try await fetchGasPrice(chain: chain)
            return FeeHistory(nextBaseFee: gp, tips: (0, 0, 0))
        }
        // Aggregate each percentile column (median across blocks).
        let reward = (root["reward"] as? [[String]]) ?? []
        func column(_ idx: Int) -> Decimal {
            let vals = reward.compactMap { row -> Decimal? in
                guard idx < row.count else { return nil }
                return ComposeDecimal.fromHexQuantity(row[idx])
            }.sorted()
            guard !vals.isEmpty else { return 0 }
            return vals[vals.count / 2]
        }
        return FeeHistory(nextBaseFee: nextBase, tips: (column(0), column(1), column(2)))
    }

    /// `eth_gasPrice` → wei.
    private func fetchGasPrice(chain: SupportedChain) async throws -> Decimal {
        let hex = try await client.callJSONString(chain: chain, method: "eth_gasPrice", params: [])
        guard let wei = ComposeDecimal.fromHexQuantity(hex) else {
            throw RPCError.decodingFailed("eth_gasPrice non-hex: \(hex)")
        }
        return wei
    }

    /// `eth_estimateGas` for native (21000 floor) or token (live + 25% pad).
    /// Docs: https://www.quicknode.com/docs/ethereum/eth_estimateGas
    private func estimateGasLimit(_ ctx: Context) async throws -> Decimal {
        // Native plain transfer: 21000 is exact (live-verified 0x5208) —
        // but L2s (Arbitrum) inflate it, so still estimate when we have a
        // recipient; default 21000 when no recipient yet.
        if !ctx.isToken {
            guard let to = ctx.toAddress else { return 21000 }
            let txObj: [String: Sendable] = ["from": ctx.fromAddress, "to": to, "value": "0x1"]
            if let est = try? await callEstimateGas(chain: ctx.chain, tx: txObj) {
                return max(est, 21000)
            }
            return 21000
        }
        // Token transfer: encode transfer(address,uint256) and estimate
        // live, then pad 25% for state-change drift (matrix).
        guard let to = ctx.toAddress, let contract = ctx.tokenContract else { return 100000 }
        let data = encodeERC20Transfer(to: to, amountHex: "0x1")
        let txObj: [String: Sendable] = ["from": ctx.fromAddress, "to": contract, "value": "0x0", "data": data]
        if let est = try? await callEstimateGas(chain: ctx.chain, tx: txObj) {
            return ComposeDecimal.ceilToInteger(est * Decimal(string: "1.25")!)
        }
        return 100000 // generous ceiling fallback (matrix)
    }

    private func callEstimateGas(chain: SupportedChain, tx: [String: Sendable]) async throws -> Decimal {
        let hex = try await client.callJSONString(chain: chain, method: "eth_estimateGas", params: [tx])
        guard let units = ComposeDecimal.fromHexQuantity(hex) else {
            throw RPCError.decodingFailed("eth_estimateGas non-hex: \(hex)")
        }
        return units
    }

    /// zkSync `zks_gasPerPubdata` (live 0x5 on mainnet.era.zksync.io).
    /// Docs: https://docs.zksync.io/zksync-protocol/api/zks-rpc
    /// Some fallback endpoints don't expose the method (`-32601`); since
    /// that error is deterministic the shared client won't rotate past
    /// it, so we tolerate a failure here and use the EIP-712 field cap
    /// default rather than failing the whole quote. The signer re-fetches
    /// the live value just-in-time before signing (Rule #27 §C).
    private func fetchZkSyncGasPerPubdata(chain: SupportedChain) async -> Decimal {
        guard let hex = try? await client.callJSONString(
            chain: chain, method: "zks_gasPerPubdata", params: []),
              let v = ComposeDecimal.fromHexQuantity(hex) else {
            return Decimal(50000) // EIP-712 field cap default
        }
        return v
    }

    /// OP-stack L1 data fee via the GasPriceOracle predeploy.
    /// Docs: https://docs.optimism.io/stack/transactions/fees ;
    /// https://docs.optimism.io/app-developers/transactions/estimates ;
    /// `getL1Fee(bytes)` (selector 0x49948e0e) on 0x420…0F (Scroll: 0x530…02).
    /// Per the OP docs the function expects the **unsigned, fully
    /// RLP-encoded transaction** and the oracle adds the ~68-byte signature
    /// allowance itself (Ecotone) / FastLZ-compresses it (post-Fjord). We
    /// pass a representative unsigned-tx byte length since the real RLP
    /// isn't built until sign time; this is the display/reserve component
    /// (the sequencer charges the exact amount at inclusion).
    private func fetchOpStackL1Fee(_ ctx: Context, gasLimit: Decimal) async throws -> Decimal {
        let oracle = ctx.chain == .scroll
            ? "0x5300000000000000000000000000000000000002"
            : "0x420000000000000000000000000000000000000F"
        // Representative UNSIGNED RLP type-2 (EIP-1559) tx byte length:
        //  - native transfer ≈ 110 bytes (chainId,nonce,2×fee,gas,to(20B),
        //    value, empty data, empty accessList + RLP framing);
        //  - ERC-20 transfer ≈ +68 bytes calldata (selector + 2×32) ≈ 180.
        // The oracle adds the signature overhead, so these unsigned lengths
        // yield a representative L1 fee. NEVER pass 0 bytes (that under-
        // reserves the L1 component and could strand the tx at inclusion).
        let dummyLen = ctx.isToken ? 180 : 110
        let callData = encodeGetL1Fee(dummyTxLen: dummyLen)
        let txObj: [String: Sendable] = ["to": oracle, "data": callData]
        guard let hex = try? await client.callJSONString(chain: ctx.chain, method: "eth_call", params: [txObj, "latest"]),
              let fee = ComposeDecimal.fromHexQuantity(hex) else {
            return 0 // honest: if the oracle read fails, omit (don't fabricate)
        }
        return fee
    }

    // MARK: - Per-chain tip floors

    private func tipFloorWei(for chain: SupportedChain) -> Decimal {
        switch chain {
        case .polygon: return ComposeDecimal.pow10(9) * 25 // 25 gwei floor (matrix)
        case .kavaEvm: return ComposeDecimal.pow10(9)      // ≥ 1 gwei feemarket floor
        default:       return 0
        }
    }

    // MARK: - Totals + notes

    /// Recompute an EVM `FeeChoice`'s estimated + worst-case native totals
    /// from its resolved gas fields. The data layer owns this fee math so
    /// the UI's CUSTOM fee path (user overrides gasLimit / maxFee / tip)
    /// just mutates those fields and calls this — it never does money math
    /// itself (Rule: money math lives in the data layer).
    ///
    /// - EIP-1559: estimated = gasLimit × (baseFee + min(tip, maxFee−baseFee))
    ///   [+ L1]; worst-case = gasLimit × maxFee [+ L1] (reserve the ceiling
    ///   so a base-fee rise can't strand the tx).
    /// - Legacy: estimated = worst = gasLimit × gasPrice (deterministic).
    /// When `baseFeePerGasWei` is absent (e.g. a custom 1559 choice with no
    /// live base fee carried) the estimate falls back to the worst-case so
    /// the can-I-afford decision stays conservative.
    static func recomputeEVMTotals(_ c: FeeChoice, decimals: Int) -> FeeChoice {
        var copy = c
        let gasLimit = c.gasLimit ?? 0
        let l1 = c.l1DataFeeWei ?? 0

        if let gasPrice = c.gasPriceWei {
            // Legacy (single gasPrice) — deterministic.
            let feeWei = gasLimit * gasPrice + l1
            copy.setTotals(
                estimated: ComposeDecimal.toDisplay(feeWei, decimals: decimals),
                worst: ComposeDecimal.toDisplay(feeWei, decimals: decimals))
            return copy
        }

        // EIP-1559.
        let maxFee = c.maxFeePerGasWei ?? 0
        let tip = c.maxPriorityFeePerGasWei ?? 0
        let worstWei = gasLimit * maxFee + l1

        let expectedWei: Decimal
        if let baseFee = c.baseFeePerGasWei {
            // effective tip is capped so total per-gas never exceeds maxFee.
            let headroom = max(maxFee - baseFee, 0)
            let effectiveTip = min(tip, headroom)
            expectedWei = gasLimit * (baseFee + effectiveTip) + l1
        } else {
            // No live base fee → stay conservative (estimate == worst).
            expectedWei = worstWei
        }

        copy.setTotals(
            estimated: ComposeDecimal.toDisplay(expectedWei, decimals: decimals),
            worst: ComposeDecimal.toDisplay(worstWei, decimals: decimals))
        return copy
    }

    private func noteFor(model: ComposeFeeModel, l1DataFee: Decimal?, decimals: Int) -> String? {
        if model == .evm1559PlusL1Data, let l1 = l1DataFee, l1 > 0 {
            return "Includes an L1 data fee"
        }
        if model == .zkSyncEra { return "Includes pubdata cost in the gas limit" }
        return nil
    }

    // MARK: - ABI encoding

    /// transfer(address,uint256) = 0xa9059cbb + 32-byte to + 32-byte amount.
    private func encodeERC20Transfer(to: String, amountHex: String) -> String {
        let addr = to.hasPrefix("0x") ? String(to.dropFirst(2)) : to
        let amt = amountHex.hasPrefix("0x") ? String(amountHex.dropFirst(2)) : amountHex
        let paddedAddr = String(repeating: "0", count: max(0, 64 - addr.count)) + addr
        let paddedAmt = String(repeating: "0", count: max(0, 64 - amt.count)) + amt
        return "0xa9059cbb" + paddedAddr + paddedAmt
    }

    /// getL1Fee(bytes) = 0x49948e0e + offset(0x20) + length + data (padded).
    private func encodeGetL1Fee(dummyTxLen: Int) -> String {
        let offset = String(format: "%064x", 0x20)
        let length = String(format: "%064x", dummyTxLen)
        // Pad the dummy data to a 32-byte multiple of zero bytes.
        let words = (dummyTxLen + 31) / 32
        let data = String(repeating: "0", count: words * 64)
        return "0x49948e0e" + offset + length + data
    }
}
