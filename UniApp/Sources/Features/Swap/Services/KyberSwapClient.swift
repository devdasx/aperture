import Foundation

/// Real KyberSwap Aggregator client — same-chain EVM SWAP only, KEYLESS,
/// against `https://aggregator-api.kyberswap.com/{chainSlug}/api/v1`.
///
/// **Why it exists.** An independent same-chain EVM quote source raced
/// against Li.Fi by `SwapQuoteService`. KyberSwap is keyless (no
/// `Secrets` gate), so it can quote even when the Li.Fi key is absent.
/// For any pair it can't serve, it throws `.unsupportedPair` so the race
/// falls back to Li.Fi.
///
/// **Two-step flow (doc-grounded + live-verified 2026-06-16):**
/// 1. `GET /routes?tokenIn=&tokenOut=&amountIn=` → `code 0`,
///    `data.routeSummary` (opaque) + `data.routerAddress`.
/// 2. `POST /route/build` with the **verbatim** `routeSummary` + sender /
///    recipient / `slippageTolerance` (bps) / `source` → `code 0`,
///    `data { data (calldata), routerAddress, amountOut, gas,
///    transactionValue }`. The build is called immediately after routes —
///    the route summary expires fast.
///
/// **Gas estimation is disabled on build (`enableGasEstimation: false`).**
/// The build runs at quote time, BEFORE any ERC-20 approval to the spender
/// exists. With estimation on, KyberSwap simulates the swap and reverts
/// (`TransferHelper: TRANSFER_FROM_FAILED`) for ERC-20-in pairs the sender
/// hasn't yet approved — live-verified 2026-06-16. Disabling it returns a
/// reliable signable tx; the signer re-estimates gas at sign time anyway
/// (per `SwapTxRequest`).
///
/// **Money math is `Decimal`** (Rule #28). All work is off-main — `SwapHTTP`
/// is an actor and this is an actor; the UI awaits.
///
/// **Security (Rule #16):** before returning, the router (`data.routerAddress`,
/// which is both the tx `to` AND the ERC-20 spender) is checked against
/// `SwapRouterAllowlist.isTrusted(_:)`. The KyberSwap aggregator router
/// `0x6131B5fae19EA4f9D964eAc0408E4408b66337b5` is already in the allowlist.
/// An un-allowlisted target throws `SwapError.untrustedRouter` — funds
/// never reach an unknown contract.
actor KyberSwapClient {
    private let http: SwapHTTP
    private let baseHost = "https://aggregator-api.kyberswap.com"
    /// Sent as `X-Client-Id` (better free-tier bucket) AND as the build
    /// `source` (KyberSwap attribution).
    private let clientID = "aperture"
    /// How long a KyberSwap quote is treated as fresh before the UI re-quotes.
    private let quoteTTLSeconds: TimeInterval = 30

    init(http: SwapHTTP = .shared) {
        self.http = http
    }

    // MARK: - Chain-slug map (inside the client per the brief — never edit SwapChainMap)

    /// Aperture `SupportedChain` → KyberSwap chain slug (lowercase path
    /// segment). Only chains KyberSwap actually serves are mapped
    /// (live-verified 2026-06-16: `scroll`, `zksync`, and `celo` return
    /// 404 on the aggregator API and are intentionally absent). A chain
    /// not in this map → `.unsupportedPair` → the race falls back to Li.Fi.
    private static func chainSlug(for chain: SupportedChain) -> String? {
        switch chain {
        case .ethereum:  return "ethereum"
        case .bnbChain:  return "bsc"
        case .arbitrum:  return "arbitrum"
        case .polygon:   return "polygon"
        case .optimism:  return "optimism"
        case .avalanche: return "avalanche"
        case .base:      return "base"
        // Aperture-swappable EVM chains KyberSwap does NOT serve under
        // these slugs (live-verified 404): scroll, zkSync, celo. They fall
        // through to `nil` → `.unsupportedPair` (Li.Fi handles them).
        default:         return nil
        }
    }

    // MARK: - Quote

    func quote(_ request: SwapQuoteRequest) async throws(SwapError) -> SwapQuote {
        // Same-chain EVM only. Cross-chain (bridge) and Solana go elsewhere.
        guard request.fromToken.kind == .evm, request.toToken.kind == .evm else {
            throw .unsupportedPair("KyberSwap only swaps EVM tokens on the same chain")
        }
        guard !request.isCrossChain else {
            throw .unsupportedPair("KyberSwap doesn't bridge across chains")
        }
        guard let slug = Self.chainSlug(for: request.fromToken.chain) else {
            throw .unsupportedPair("\(request.fromToken.chain.displayName) isn't supported by KyberSwap")
        }

        // --- Step 1: GET /routes
        var routesComponents = URLComponents(string: "\(baseHost)/\(slug)/api/v1/routes")
        routesComponents?.queryItems = [
            URLQueryItem(name: "tokenIn", value: Self.kyberAddress(request.fromToken)),
            URLQueryItem(name: "tokenOut", value: Self.kyberAddress(request.toToken)),
            URLQueryItem(name: "amountIn", value: request.rawFromAmount),
        ]
        guard let routesURL = routesComponents?.url else {
            throw .invalidResponse("couldn't build the KyberSwap routes URL")
        }

        let routesDTO = try await http.getJSON(
            KyberRoutesDTO.self,
            url: routesURL,
            headers: ["X-Client-Id": clientID]
        )
        guard routesDTO.code == 0, let routeData = routesDTO.data else {
            throw Self.mappedError(code: routesDTO.code, message: routesDTO.message)
        }

        // --- Step 2: POST /route/build (verbatim routeSummary, immediately).
        let recipient: String = {
            if let to = request.toAddress, !to.isEmpty { return to }
            return request.fromAddress
        }()
        let buildBody = KyberBuildRequest(
            routeSummary: routeData.routeSummary,
            sender: request.fromAddress,
            recipient: recipient,
            slippageTolerance: request.slippageBps,
            source: clientID,
            enableGasEstimation: false
        )
        guard let buildURL = URL(string: "\(baseHost)/\(slug)/api/v1/route/build") else {
            throw .invalidResponse("couldn't build the KyberSwap build URL")
        }

        let buildDTO = try await http.postJSON(
            KyberBuildDTO.self,
            url: buildURL,
            body: buildBody,
            headers: ["X-Client-Id": clientID]
        )
        guard buildDTO.code == 0, let build = buildDTO.data else {
            throw Self.mappedError(code: buildDTO.code, message: buildDTO.message)
        }

        return try buildQuote(
            request: request,
            slug: slug,
            routeSummary: KyberRouteSummaryView(routeData.routeSummary),
            build: build
        )
    }

    // MARK: - Quote builder

    private func buildQuote(
        request: SwapQuoteRequest,
        slug: String,
        routeSummary: KyberRouteSummaryView,
        build: KyberBuildDTO.BuildData
    ) throws(SwapError) -> SwapQuote {
        // --- Security gate: the router is BOTH the tx target AND the ERC-20
        //     spender. Both must be allowlisted before the quote is returned.
        let router = build.routerAddress
        guard SwapRouterAllowlist.isTrusted(router) else {
            throw .untrustedRouter(router)
        }
        // The approval spender is the same router; gate it explicitly too
        // (mirrors LiFiClient.buildQuote checking both `to` and approval).
        let approvalSpender = router
        guard SwapRouterAllowlist.isTrusted(approvalSpender) else {
            throw .untrustedRouter(approvalSpender)
        }

        let toDecimals = request.toToken.decimals

        // Raw out: prefer the build's amountOut (post-build expected out);
        // fall back to the route summary's amountOut.
        let toAmountRaw = build.amountOut ?? routeSummary.amountOut ?? "0"
        let toAmount = Self.humanAmount(toAmountRaw, decimals: toDecimals)

        // Honest min-out. KyberSwap's calldata enforces `slippageTolerance`
        // internally; neither `/routes` nor `/route/build` returns the
        // protected min as a field (live-verified 2026-06-16: build's
        // amountOut ≈ route's amountOut, i.e. the expected out, not the min).
        // So derive it: amountOut × (1 − slippage), in Decimal, rounded down
        // to the token's smallest unit.
        let toAmountMinRaw = Self.slippageMinRaw(toAmountRaw, slippageBps: request.slippageBps)
        let toAmountMin = Self.humanAmount(toAmountMinRaw, decimals: toDecimals)

        // Rate = toAmount(human) / fromAmount(human).
        let fromHuman = request.amount
        let rate: Decimal = fromHuman > 0 ? (toAmount / fromHuman) : 0

        // Native value: the build's transactionValue (in-amount for
        // native-in, "0" for ERC-20-in). The SwapTxRequest convention is a
        // hex string, so convert the decimal string to hex `0x…`.
        let valueHex = Self.hexValue(from: build.transactionValue)

        // Gas limit: the build returns a decimal string; SwapTxRequest's
        // gasLimit is a hex string. Convert (signer may re-estimate).
        let gasLimitHex = Self.hexValue(from: build.gas)

        let evmTx = SwapTxRequest(
            to: router,
            data: build.data,
            value: valueHex,
            chainId: EVMChainIdentity.chainId(for: request.fromToken.chain),
            gasLimit: gasLimitHex,
            gasPrice: nil // EIP-1559 chains derive maxFee at sign time.
        )

        return SwapQuote(
            quoteID: "kyber-\(slug)-\(toAmountRaw)",
            fromToken: request.fromToken,
            toToken: request.toToken,
            provider: .kyberswap,
            stepKind: .swap,
            toolName: "KyberSwap",
            bridgeName: nil,
            fromAmountRaw: request.rawFromAmount,
            toAmountRaw: toAmountRaw,
            toAmountMinRaw: toAmountMinRaw,
            toAmount: toAmount,
            toAmountMin: toAmountMin,
            rate: rate,
            priceImpact: Self.priceImpact(routeSummary: routeSummary),
            fees: [], // KyberSwap doesn't itemize a fee here; gas is the signer's.
            gasCostUSD: 0, // Not USD-priced for the quote (build gives gasUsd; left 0 per the output contract default).
            estimatedDurationSeconds: 0, // Same-chain swap — near-instant.
            approvalAddress: approvalSpender,
            evmTx: evmTx,
            solanaTx: nil,
            expiresAt: Date().addingTimeInterval(quoteTTLSeconds)
        )
    }

    // MARK: - Helpers

    /// KyberSwap's token identifier: the ERC-20 contract, or its native
    /// sentinel (`0xEeee…EEeE`) for the native coin. Aperture stores the
    /// native coin as the zero sentinel (`0x0…0`, Li.Fi's convention), so
    /// translate native → KyberSwap's sentinel; pass ERC-20 contracts
    /// through verbatim.
    private static func kyberAddress(_ token: SwapToken) -> String {
        token.isNative ? kyberNativeSentinel : token.address
    }

    /// KyberSwap's native-coin sentinel (EIP-7528 style). Lowercased on the
    /// wire is fine — KyberSwap echoes it lowercased (live-verified).
    private static let kyberNativeSentinel = "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

    /// `raw × (1 − slippageBps/10_000)`, rounded DOWN to the integer
    /// smallest-unit, as a plain-decimal string. Decimal math (Rule #28).
    private static func slippageMinRaw(_ raw: String, slippageBps: Int) -> String {
        guard let amount = Decimal(string: raw) else { return raw }
        let factor = Decimal(10_000 - slippageBps) / Decimal(10_000)
        var scaled = amount * factor
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .down)
        return (rounded as NSDecimalNumber).stringValue
    }

    /// Price impact from the priced legs: `(fromUSD − toUSD) / fromUSD`,
    /// clamped at 0 for tiny positive-noise. `nil` when either leg is
    /// unpriced (honest — never fabricate). Mirrors LiFiClient.priceImpact.
    private static func priceImpact(routeSummary: KyberRouteSummaryView) -> Decimal? {
        guard let fromUSD = Decimal(string: routeSummary.amountInUsd ?? ""),
              let toUSD = Decimal(string: routeSummary.amountOutUsd ?? ""),
              fromUSD > 0 else { return nil }
        let impact = (fromUSD - toUSD) / fromUSD
        return impact < 0 ? 0 : impact
    }

    /// Convert a decimal integer string (KyberSwap returns `transactionValue`
    /// and `gas` as base-10 strings) to a `0x…` hex-quantity string for
    /// `SwapTxRequest`. `nil`/empty/unparseable → `nil` (gas) or `0x0`
    /// (handled by the caller's default). Decimal-string → hex via
    /// big-integer-safe `Decimal` division; small enough values use UInt64.
    private static func hexValue(from decimalString: String?) -> String {
        guard let s = decimalString, !s.isEmpty, s != "0" else {
            return "0x0"
        }
        // Fast path: fits in UInt64 (gas limits and most native values do;
        // 1 ETH = 10^18 wei < UInt64.max ≈ 1.8×10^19).
        if let u = UInt64(s) {
            return "0x" + String(u, radix: 16)
        }
        // Big-value fallback: decimal-string → hex via repeated division by
        // 16 in Decimal space (handles values > UInt64.max, e.g. large
        // native amounts), exact integer math, no Double.
        guard var value = Decimal(string: s), value > 0 else { return "0x0" }
        let sixteen = Decimal(16)
        let hexAlphabet = Array("0123456789abcdef")
        var digits = ""
        while value > 0 {
            // floored = floor(value / 16); remainder = value − floored*16.
            var divided = value / sixteen
            var floored = Decimal()
            NSDecimalRound(&floored, &divided, 0, .down)
            let remainder = value - (floored * sixteen)
            let idx = (remainder as NSDecimalNumber).intValue
            digits.append(hexAlphabet[idx])
            value = floored
        }
        return "0x" + String(digits.reversed())
    }

    /// Map a non-zero KyberSwap envelope `code` to a typed `SwapError`.
    /// `code 0` is success (handled by the caller). Known route-absence /
    /// liquidity / amount codes map to the honest cases; everything else
    /// scans the message via the shared body-pattern mapper.
    private static func mappedError(code: Int, message: String?) -> SwapError {
        let msg = message ?? ""
        // Route the message through the shared pattern matcher first (it
        // recognizes "no route", "insufficient liquidity", "amount too
        // low", "not supported", etc.).
        let mapped = SwapError.from(status: 400, body: msg)
        if case .noRoute = mapped, msg.isEmpty {
            // Empty message + non-zero code: surface the provider code.
            return .provider(status: code, message: "KyberSwap error \(code)")
        }
        return mapped
    }

    /// raw integer string ÷ 10^decimals → `Decimal` chain units.
    private static func humanAmount(_ raw: String, decimals: Int) -> Decimal {
        guard let value = Decimal(string: raw) else { return 0 }
        return value / pow(Decimal(10), decimals)
    }
}

// MARK: - Build request body (verbatim routeSummary embedded)

/// The `POST /route/build` body. `routeSummary` is the opaque `JSONValue`
/// captured verbatim from `/routes` — re-encoding it via `Codable`
/// round-trips every field the build step requires (pool extras, checksum,
/// routing internals) without lossy re-modeling.
private struct KyberBuildRequest: Encodable, Sendable {
    let routeSummary: JSONValue
    let sender: String
    let recipient: String
    let slippageTolerance: Int
    let source: String
    let enableGasEstimation: Bool
}
