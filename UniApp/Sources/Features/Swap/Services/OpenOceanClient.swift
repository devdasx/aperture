import Foundation
import OSLog

/// Real OpenOcean v4 aggregator client — **same-chain EVM SWAP only**
/// (this increment), against `https://open-api.openocean.finance/v4`.
/// Keyless (free tier ~1–2 RPS). Raced against Li.Fi by
/// `SwapQuoteService`; on any unsupported pair it throws
/// `SwapError.unsupportedPair` so the race falls back to Li.Fi.
///
/// **Endpoints (doc-grounded + live-verified 2026-06-16):**
/// - `GET /{chainCode}/quote` — the price leg. Query `inTokenAddress`,
///   `outTokenAddress`, `amountDecimals` (plain integer string, smallest
///   units — NO scientific notation), `gasPrice` (gwei integer),
///   `slippage` (percent; `1` = 1%). Response `{ code:200, data:{ … } }`.
/// - `GET /{chainCode}/swap` — the signable tx. Same params + `account`
///   (the sender). Response `data { to, data, value, gasPrice,
///   estimatedGas, outAmount, minOutAmount, chainId, from, price_impact }`.
///
/// **Native sentinel** (in/out): OpenOcean uses
/// `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`. Aperture's `SwapToken`
/// uses the all-zero sentinel (Li.Fi convention), so this client
/// translates zero → the OpenOcean `EeeE…EEeE` form on the way out.
///
/// **Money math is `Decimal`** (Rule #28). All work is off-main —
/// `SwapHTTP` is an actor and this is an actor; the UI awaits.
///
/// **Security (Rule #16):** before returning, the swap tx target
/// (`data.to`) AND the ERC-20 approval spender (= the router) are checked
/// against `SwapRouterAllowlist`. An un-allowlisted target throws
/// `SwapError.untrustedRouter` — the funds never reach an unknown
/// contract. The verified router
/// `0x6352a56caadC4F1E25CD6c75970Fa768A3304e64` is already in the
/// allowlist's aggregator set.
actor OpenOceanClient {
    private let http: SwapHTTP
    private let baseURL = "https://open-api.openocean.finance/v4"
    /// How long an OpenOcean quote is treated as fresh before re-quote.
    private let quoteTTLSeconds: TimeInterval = 30
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "swap")

    /// OpenOcean's native-coin sentinel (in/out token). Distinct from
    /// Aperture's all-zero `SwapToken.nativeEVMSentinel`.
    private static let openOceanNativeSentinel = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"

    init(http: SwapHTTP = .shared) {
        self.http = http
    }

    // MARK: - Provider chain-code map (kept INSIDE the client per the brief)

    /// Maps an Aperture `SupportedChain` to the OpenOcean v4 path
    /// `{chainCode}`. Only the codes OpenOcean actually serves are mapped
    /// — live-verified 2026-06-16: `eth`, `bsc`, `polygon`, `base`,
    /// `arbitrum`, `optimism`, `scroll`, `zksync` returned `code:200`;
    /// Avalanche is **`avax`** (the literal `avalanche` 400s with
    /// "support chain is eth,bsc,avax,fantom,arbitrum,xdai"). Any chain
    /// not in this map → `.unsupportedPair`, so the race falls to Li.Fi.
    private static func chainCode(for chain: SupportedChain) -> String? {
        switch chain {
        case .ethereum:  return "eth"
        case .bnbChain:  return "bsc"
        case .polygon:   return "polygon"
        case .base:      return "base"
        case .arbitrum:  return "arbitrum"
        case .optimism:  return "optimism"
        case .avalanche: return "avax"
        case .scroll:    return "scroll"
        case .zkSync:    return "zksync"
        // .celo and any other Aperture swappable chain OpenOcean doesn't
        // index → unsupported here; Li.Fi covers it in the race.
        default:         return nil
        }
    }

    /// Translate Aperture's all-zero native sentinel to OpenOcean's
    /// `EeeE…EEeE` form; pass ERC-20 contracts through verbatim.
    private static func providerAddress(for token: SwapToken) -> String {
        token.isNative ? openOceanNativeSentinel : token.address
    }

    // MARK: - Quote

    func quote(_ request: SwapQuoteRequest) async throws(SwapError) -> SwapQuote {
        // Same-chain EVM only this increment. A cross-chain pair, or any
        // non-EVM side (Solana/Sui), falls back to Li.Fi/Jupiter.
        guard request.fromToken.kind == .evm, request.toToken.kind == .evm else {
            throw .unsupportedPair("OpenOcean only swaps EVM tokens")
        }
        guard request.fromToken.chain == request.toToken.chain else {
            throw .unsupportedPair("OpenOcean doesn't bridge across chains")
        }
        guard let code = Self.chainCode(for: request.fromToken.chain) else {
            throw .unsupportedPair("\(request.fromToken.chain.displayName) isn't supported by OpenOcean")
        }

        let inAddr = Self.providerAddress(for: request.fromToken)
        let outAddr = Self.providerAddress(for: request.toToken)
        // Slippage as a PERCENT (OpenOcean: 1 = 1%). bps/100 → percent,
        // Decimal math, plain-decimal string (never sci-notation).
        let slippagePercent = Self.slippagePercentString(bps: request.slippageBps)
        // gasPrice in gwei (integer). The exact value only nudges the gas
        // estimate; "1" is a safe, valid floor for the quote (the signer
        // re-derives the real fee at sign time from live base fee).
        let gasPriceGwei = "1"

        // Shared query items for BOTH /quote and /swap.
        let baseItems: [URLQueryItem] = [
            URLQueryItem(name: "inTokenAddress", value: inAddr),
            URLQueryItem(name: "outTokenAddress", value: outAddr),
            // amountDecimals MUST be a plain integer string of smallest
            // units — request.rawFromAmount is exactly that.
            URLQueryItem(name: "amountDecimals", value: request.rawFromAmount),
            URLQueryItem(name: "gasPrice", value: gasPriceGwei),
            URLQueryItem(name: "slippage", value: slippagePercent),
        ]

        // 1) Price leg — validates the route + gives a clean outAmount.
        guard var quoteComponents = URLComponents(string: "\(baseURL)/\(code)/quote") else {
            throw .invalidResponse("couldn't build the OpenOcean quote URL")
        }
        quoteComponents.queryItems = baseItems
        guard let quoteURL = quoteComponents.url else {
            throw .invalidResponse("couldn't build the OpenOcean quote URL")
        }
        let quoteDTO = try await http.getJSON(OpenOceanQuoteDTO.self, url: quoteURL)
        guard quoteDTO.code == 200, let quoteData = quoteDTO.data else {
            // A non-200 envelope means no route for this pair/amount.
            throw .noRoute
        }

        // 2) Calldata leg — the signable tx (needs the sender `account`).
        guard var swapComponents = URLComponents(string: "\(baseURL)/\(code)/swap") else {
            throw .invalidResponse("couldn't build the OpenOcean swap URL")
        }
        swapComponents.queryItems = baseItems + [
            URLQueryItem(name: "account", value: request.fromAddress),
        ]
        guard let swapURL = swapComponents.url else {
            throw .invalidResponse("couldn't build the OpenOcean swap URL")
        }
        let swapDTO = try await http.getJSON(OpenOceanSwapDTO.self, url: swapURL)
        guard swapDTO.code == 200, let swapData = swapDTO.data else {
            throw .noRoute
        }

        return try buildQuote(
            quoteData: quoteData,
            swapData: swapData,
            request: request
        )
    }

    // MARK: - Quote builder

    private func buildQuote(
        quoteData: OpenOceanQuoteDTO.QuoteData,
        swapData: OpenOceanSwapDTO.SwapData,
        request: SwapQuoteRequest
    ) throws(SwapError) -> SwapQuote {
        // The signable tx target MUST be present + allowlisted.
        guard let router = swapData.to, !router.isEmpty,
              let calldata = swapData.data, !calldata.isEmpty else {
            throw .invalidResponse("OpenOcean returned no swap transaction")
        }

        // --- FUNDS-SAFETY GATE (Rule #16, mirrors LiFiClient.buildQuote).
        // The tx target AND the ERC-20 approval spender (= the router for
        // OpenOcean) must both be allowlisted. Never return a quote whose
        // tx target isn't trusted.
        guard SwapRouterAllowlist.isTrusted(router) else {
            throw .untrustedRouter(router)
        }
        // approvalAddress == the router for OpenOcean (the spender the
        // ERC-20 allowance is set to). Gate it too.
        let approvalSpender = router
        guard SwapRouterAllowlist.isTrusted(approvalSpender) else {
            throw .untrustedRouter(approvalSpender)
        }

        // Amounts — provider raw out + slippage-protected min-out. Prefer
        // the swap leg's outAmount (the value tied to this exact tx); fall
        // back to the quote leg's outAmount if the swap omitted it.
        let toAmountRaw = swapData.outAmount ?? quoteData.outAmount
        // minOutAmount is OpenOcean's slippage-protected floor — use it. When
        // the provider OMITS it, DON'T fall back to the expected out (that
        // would display zero slippage protection while the calldata enforces
        // outAmount×(1−slip)) — derive the real floor the same conservative
        // way Kyber does, so the shown "minimum received" never overstates the
        // on-chain guarantee (Rule #16).
        let toAmountMinRaw = swapData.minOutAmount
            ?? Self.slippageMinRaw(toAmountRaw, slippageBps: request.slippageBps)

        let toDecimals = request.toToken.decimals
        let toAmount = Self.humanAmount(toAmountRaw, decimals: toDecimals)
        let toAmountMin = Self.humanAmount(toAmountMinRaw, decimals: toDecimals)

        // Rate = toAmount(human) / fromAmount(human).
        let fromHuman = request.amount
        let rate: Decimal = fromHuman > 0 ? (toAmount / fromHuman) : 0

        // Price impact: OpenOcean gives a PERCENT string ("0.06%", can be
        // negative). Convert to a fraction (0.0006); clamp tiny negative
        // noise to 0; `nil` when absent or unparseable.
        let priceImpact = Self.priceImpactFraction(swapData.price_impact)

        // Funds-safety (Rule #16): validate the native value against the
        // reviewed input BEFORE trusting it — ERC-20-in MUST attach 0, native-
        // in MUST attach exactly the swap amount. A mismatch signals a buggy/
        // stale/tampered keyless response → refuse. Exact width-safe compare.
        let expectedValueNorm = request.fromToken.isNative ? Self.normDec(request.rawFromAmount) : "0"
        guard Self.normDec(swapData.value) == expectedValueNorm else {
            throw .invalidResponse("OpenOcean returned an unexpected native value")
        }

        // Native-in swaps carry a native value; ERC-20-in carry "0". Take
        // exactly what the API returned (verified: "0" / native amount),
        // normalized to a hex-quantity string the signer expects.
        let valueHex = Self.hexQuantity(fromDecimalString: swapData.value ?? "0")

        // Gas: estimatedGas is gas-UNITS. Pad ~30% headroom (per the brief)
        // and emit as a hex quantity. A 0/absent estimate becomes `nil` so the
        // executor's 800k ceiling applies — a signed gasLimit of 0 reverts
        // (intrinsic gas too low) AFTER a paid approval (Rule #26).
        let gasLimitHex = swapData.estimatedGas.flatMap { units -> String? in
            guard units.value > 0 else { return nil }
            let padded = (units.value * 13) / 10  // ×1.3, integer math
            return Self.hexQuantity(fromInt: max(padded, units.value))
        }
        let gasPriceHex = swapData.gasPrice.map { Self.hexQuantity(fromDecimalString: $0) }

        let chainId = swapData.chainId ?? EVMChainIdentity.chainId(for: request.fromToken.chain)

        let evmTx = SwapTxRequest(
            to: router,
            data: calldata,
            value: valueHex,
            chainId: chainId,
            gasLimit: gasLimitHex,
            gasPrice: gasPriceHex
        )

        return SwapQuote(
            quoteID: "oo-\(chainId ?? 0)-\(toAmountRaw)",
            fromToken: request.fromToken,
            toToken: request.toToken,
            provider: .openocean,
            stepKind: .swap,
            toolName: "OpenOcean",
            bridgeName: nil,
            fromAmountRaw: request.rawFromAmount,
            toAmountRaw: toAmountRaw,
            toAmountMinRaw: toAmountMinRaw,
            toAmount: toAmount,
            toAmountMin: toAmountMin,
            rate: rate,
            priceImpact: priceImpact,
            // OpenOcean's quote doesn't USD-price the gas; surface gas as a
            // native-unit line only when we know the gas amount, else [].
            fees: Self.gasFee(
                gasLimitUnits: swapData.estimatedGas?.value,
                gasPriceWeiString: swapData.gasPrice,
                chain: request.fromToken.chain
            ),
            gasCostUSD: 0, // OpenOcean's quote doesn't price gas in USD.
            estimatedDurationSeconds: 0, // Same-chain swap — effectively instant.
            approvalAddress: approvalSpender,
            evmTx: evmTx,
            solanaTx: nil,
            expiresAt: Date().addingTimeInterval(quoteTTLSeconds)
        )
    }

    // MARK: - Helpers

    /// Slippage bps → OpenOcean percent string (1 = 1%). 50 bps → "0.5".
    /// Decimal math, plain-decimal (never scientific notation).
    private static func slippagePercentString(bps: Int) -> String {
        let percent = Decimal(bps) / 100
        return (percent as NSDecimalNumber).stringValue
    }

    /// `raw × (1 − slippageBps/10_000)`, rounded DOWN to the integer
    /// smallest-unit, as a plain-decimal string. The conservative on-chain
    /// floor used when OpenOcean omits `minOutAmount`. Decimal math (Rule #28).
    private static func slippageMinRaw(_ raw: String, slippageBps: Int) -> String {
        guard let amount = Decimal(string: raw) else { return raw }
        let factor = Decimal(10_000 - slippageBps) / Decimal(10_000)
        var scaled = amount * factor
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .down)
        return (rounded as NSDecimalNumber).stringValue
    }

    /// Normalize a decimal integer string: nil/empty/all-zero → "0", else the
    /// digits with leading zeros stripped. Width-safe exact comparison for the
    /// native-value invariant (no Double/Decimal rounding).
    private static func normDec(_ s: String?) -> String {
        let trimmed = (s ?? "").drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    /// Build a `.gas` `SwapFee` (native units, no USD) when the gas
    /// amount is known. Returns `[]` otherwise — honest empty, never a
    /// fabricated fee (Rule #16).
    private static func gasFee(
        gasLimitUnits: Int?,
        gasPriceWeiString: String?,
        chain: SupportedChain
    ) -> [SwapFee] {
        guard let units = gasLimitUnits,
              let weiStr = gasPriceWeiString,
              let gasPriceWei = Decimal(string: weiStr) else { return [] }
        // fee(native) = gasLimit × gasPrice(wei) / 10^18.
        let feeWei = Decimal(units) * gasPriceWei
        let feeNative = feeWei / pow(Decimal(10), 18)
        guard feeNative > 0 else { return [] }
        return [SwapFee(
            kind: .gas,
            name: "Network fee",
            amountDecimal: feeNative,
            tokenSymbol: chain.ticker,
            amountUSD: 0
        )]
    }

    /// OpenOcean percent string ("0.06%", "-0.01%") → fraction (0.0006).
    /// Clamps tiny negative noise to 0; `nil` when absent/unparseable.
    private static func priceImpactFraction(_ raw: String?) -> Decimal? {
        guard let raw else { return nil }
        let trimmed = raw.replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let percent = Decimal(string: trimmed) else { return nil }
        let fraction = percent / 100
        return fraction < 0 ? 0 : fraction
    }

    /// raw integer string ÷ 10^decimals → `Decimal` chain units.
    /// Mirrors `LiFiClient.humanAmount`.
    private static func humanAmount(_ raw: String, decimals: Int) -> Decimal {
        guard let value = Decimal(string: raw) else { return 0 }
        return value / pow(Decimal(10), decimals)
    }

    /// Plain decimal integer STRING (e.g. "10000000000000000") → hex
    /// quantity string ("0x2386f26fc10000") the EVM signer expects. Uses
    /// exact integer arithmetic via `NSDecimalNumber` digit conversion —
    /// never a lossy `Double`. Returns "0x0" on any parse failure.
    private static func hexQuantity(fromDecimalString decimalString: String) -> String {
        let trimmed = decimalString.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("0x") { return trimmed }
        // Convert an arbitrary-length base-10 integer string to base-16 by
        // repeated division on the digit string (exact, no overflow).
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else { return "0x0" }
        var digits = Array(trimmed).map { Int(String($0)) ?? 0 }
        // Strip leading zeros.
        while digits.count > 1 && digits.first == 0 { digits.removeFirst() }
        if digits == [0] { return "0x0" }
        var hex = ""
        let hexChars = Array("0123456789abcdef")
        while !(digits.count == 1 && digits[0] == 0) {
            var remainder = 0
            var quotient: [Int] = []
            for d in digits {
                let cur = remainder * 10 + d
                quotient.append(cur / 16)
                remainder = cur % 16
            }
            hex.append(hexChars[remainder])
            // Strip leading zeros from the quotient.
            while quotient.count > 1 && quotient.first == 0 { quotient.removeFirst() }
            digits = quotient
        }
        return "0x" + String(hex.reversed())
    }

    /// Int → hex quantity string ("0x…").
    private static func hexQuantity(fromInt value: Int) -> String {
        value <= 0 ? "0x0" : "0x" + String(value, radix: 16)
    }
}
