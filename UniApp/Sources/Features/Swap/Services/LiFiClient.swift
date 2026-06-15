import Foundation

/// Real Li.Fi REST client — same-chain SWAP + cross-chain BRIDGE for
/// every EVM chain and EVM↔Solana, against `https://li.quest/v1`.
///
/// **Endpoints (doc-grounded + live-verified 2026-06-15):**
/// - `GET /quote` — the single best route (swap when fromChain ==
///   toChain, bridge otherwise). Header `x-lifi-api-key`, query
///   `integrator=aperture`.
/// - `GET /tokens` — the swappable-token universe per chain.
///
/// **Money math is `Decimal`** (Rule #28). All work is off-main —
/// `SwapHTTP` is an actor and this is an actor; the UI awaits.
///
/// **Security:** every quote's router (`transactionRequest.to`) and
/// ERC-20 approval target are checked against `SwapRouterAllowlist`
/// before the quote is returned. An un-allowlisted target throws
/// `SwapError.untrustedRouter` — the funds never reach an unknown
/// contract (Rule #16).
actor LiFiClient {
    private let http: SwapHTTP
    private let baseURL = "https://li.quest/v1"
    /// Integrator id sent on every quote (Li.Fi attribution).
    private let integrator = "aperture"
    /// How long a Li.Fi quote is treated as fresh before the UI re-quotes.
    private let quoteTTLSeconds: TimeInterval = 30

    init(http: SwapHTTP = .shared) {
        self.http = http
    }

    // MARK: - Quote

    func quote(_ request: SwapQuoteRequest) async throws(SwapError) -> SwapQuote {
        // Honest gate: Li.Fi requires the key (Solana→Solana goes to
        // Jupiter, which is keyless, and never reaches here).
        guard Secrets.hasLifiKey else { throw .notConfigured }

        guard let fromChainID = SwapChainMap.lifiChainID(for: request.fromToken.chain) else {
            throw .unsupportedPair("\(request.fromToken.chain.displayName) isn't supported for swaps")
        }
        guard let toChainID = SwapChainMap.lifiChainID(for: request.toToken.chain) else {
            throw .unsupportedPair("\(request.toToken.chain.displayName) isn't supported for swaps")
        }

        var components = URLComponents(string: "\(baseURL)/quote")
        components?.queryItems = [
            URLQueryItem(name: "fromChain", value: String(fromChainID)),
            URLQueryItem(name: "toChain", value: String(toChainID)),
            URLQueryItem(name: "fromToken", value: request.fromToken.address),
            URLQueryItem(name: "toToken", value: request.toToken.address),
            URLQueryItem(name: "fromAmount", value: request.rawFromAmount),
            URLQueryItem(name: "fromAddress", value: request.fromAddress),
            URLQueryItem(name: "slippage", value: String(request.slippageFraction)),
            URLQueryItem(name: "integrator", value: integrator),
        ]
        if let toAddress = request.toAddress, !toAddress.isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "toAddress", value: toAddress))
        }

        guard let url = components?.url else {
            throw .invalidResponse("couldn't build the quote URL")
        }

        let dto = try await http.getJSON(
            LiFiQuoteDTO.self,
            url: url,
            headers: ["x-lifi-api-key": Secrets.lifiAPIKey]
        )

        return try buildQuote(from: dto, request: request)
    }

    // MARK: - Tokens

    /// The swappable-token universe for `chain` (Li.Fi `/tokens`).
    /// Returns `[]` (never throws) on failure so the picker degrades to
    /// the Aperture registry rather than going blank.
    func tokens(for chain: SupportedChain) async -> [SwapToken] {
        guard Secrets.hasLifiKey,
              let chainID = SwapChainMap.lifiChainID(for: chain),
              let kind = SwapChainMap.kind(for: chain) else { return [] }

        var components = URLComponents(string: "\(baseURL)/tokens")
        components?.queryItems = [URLQueryItem(name: "chains", value: String(chainID))]
        guard let url = components?.url else { return [] }

        do {
            let dto = try await http.getJSON(
                LiFiTokensDTO.self,
                url: url,
                headers: ["x-lifi-api-key": Secrets.lifiAPIKey]
            )
            let list = dto.tokens[String(chainID)] ?? []
            return list.map { info in
                SwapToken(
                    chain: chain,
                    kind: kind,
                    address: info.address,
                    symbol: info.symbol,
                    name: info.name ?? info.symbol,
                    decimals: info.decimals,
                    logoURI: info.logoURI
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - Search (provider fallback for tokens not in our list)

    /// Look a single token up on `chain` by symbol OR contract
    /// (`GET /token?chain=<id>&token=<query>`). Returns the matched token
    /// as a `SwapToken`, or `nil` when nothing matches (Li.Fi 404) or on
    /// any error. Drives the picker's provider fallback so a user can find
    /// an EVM token Aperture doesn't curate. Never throws.
    func searchToken(query: String, on chain: SupportedChain) async -> SwapToken? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Secrets.hasLifiKey, !trimmed.isEmpty,
              let chainID = SwapChainMap.lifiChainID(for: chain),
              let kind = SwapChainMap.kind(for: chain) else { return nil }

        var components = URLComponents(string: "\(baseURL)/token")
        components?.queryItems = [
            URLQueryItem(name: "chain", value: String(chainID)),
            URLQueryItem(name: "token", value: trimmed),
        ]
        guard let url = components?.url else { return nil }

        do {
            let info = try await http.getJSON(
                LiFiQuoteDTO.TokenInfo.self,
                url: url,
                headers: ["x-lifi-api-key": Secrets.lifiAPIKey]
            )
            return SwapToken(
                chain: chain,
                kind: kind,
                address: info.address,
                symbol: info.symbol,
                name: info.name ?? info.symbol,
                decimals: info.decimals,
                logoURI: info.logoURI
            )
        } catch {
            return nil
        }
    }

    // MARK: - Quote builder

    private func buildQuote(
        from dto: LiFiQuoteDTO,
        request: SwapQuoteRequest
    ) throws(SwapError) -> SwapQuote {
        let isCrossChain = dto.action.fromChainId != dto.action.toChainId

        // --- Security gate: router + approval target must be allowlisted.
        if let routerTo = dto.transactionRequest?.to {
            guard SwapRouterAllowlist.isTrustedLiFiTarget(routerTo) else {
                throw .untrustedRouter(routerTo)
            }
        }
        if let approval = dto.estimate.approvalAddress, !approval.isEmpty {
            guard SwapRouterAllowlist.isTrustedLiFiTarget(approval) else {
                throw .untrustedRouter(approval)
            }
        }

        let toDecimals = dto.action.toToken.decimals
        let toAmount = Self.humanAmount(dto.estimate.toAmount, decimals: toDecimals)
        let toAmountMinRaw = dto.estimate.toAmountMin ?? dto.estimate.toAmount
        let toAmountMin = Self.humanAmount(toAmountMinRaw, decimals: toDecimals)

        // Rate = toAmount(human) / fromAmount(human).
        let fromHuman = request.amount
        let rate: Decimal = fromHuman > 0 ? (toAmount / fromHuman) : 0

        // Gas cost USD = sum of gasCosts[].amountUSD.
        let gasCostUSD: Decimal = (dto.estimate.gasCosts ?? [])
            .compactMap { Decimal(string: $0.amountUSD ?? "") }
            .reduce(0, +)

        // Fee breakdown: gas line(s) + protocol/bridge fee line(s).
        var fees: [SwapFee] = []
        for gas in dto.estimate.gasCosts ?? [] {
            let usd = Decimal(string: gas.amountUSD ?? "") ?? 0
            // Decimalise the raw base-unit fee with the fee token's own
            // decimals (Li.Fi gives them) so the UI never shows raw wei.
            let human: Decimal? = {
                guard let raw = gas.amount, let d = gas.token?.decimals else { return nil }
                return Self.humanAmount(raw, decimals: d)
            }()
            fees.append(SwapFee(
                kind: .gas,
                name: "Network fee",
                amountDecimal: human,
                tokenSymbol: gas.token?.symbol ?? request.fromToken.chain.ticker,
                amountUSD: usd
            ))
        }
        for fee in dto.estimate.feeCosts ?? [] {
            let usd = Decimal(string: fee.amountUSD ?? "") ?? 0
            let lower = (fee.name ?? "").lowercased()
            let kind: SwapFee.Kind = (lower.contains("relayer") || lower.contains("bridge")) ? .bridge : .protocolFee
            let human: Decimal? = {
                guard let raw = fee.amount, let d = fee.token?.decimals else { return nil }
                return Self.humanAmount(raw, decimals: d)
            }()
            fees.append(SwapFee(
                kind: kind,
                name: fee.name ?? "Fee",
                amountDecimal: human,
                tokenSymbol: fee.token?.symbol ?? "",
                amountUSD: usd
            ))
        }

        // Bridge name (cross-chain): prefer the `cross` included-step's
        // tool, else the top-level tool.
        let bridgeName: String? = {
            guard isCrossChain else { return nil }
            if let crossStep = dto.includedSteps?.first(where: { $0.type == "cross" }),
               let tool = crossStep.tool {
                return tool
            }
            return dto.tool
        }()

        // Execute seam: the real, signable EVM tx (Li.Fi).
        let evmTx: SwapTxRequest? = dto.transactionRequest.flatMap { tx in
            guard let to = tx.to, let data = tx.data else { return nil }
            return SwapTxRequest(
                to: to,
                data: data,
                value: tx.value ?? "0x0",
                chainId: tx.chainId,
                gasLimit: tx.gasLimit,
                gasPrice: tx.gasPrice
            )
        }

        return SwapQuote(
            quoteID: dto.id ?? UUID().uuidString,
            fromToken: request.fromToken,
            toToken: request.toToken,
            provider: .lifi,
            stepKind: isCrossChain ? .bridge : .swap,
            toolName: dto.tool ?? "Li.Fi",
            bridgeName: bridgeName,
            fromAmountRaw: dto.action.fromAmount,
            toAmountRaw: dto.estimate.toAmount,
            toAmountMinRaw: toAmountMinRaw,
            toAmount: toAmount,
            toAmountMin: toAmountMin,
            rate: rate,
            priceImpact: Self.priceImpact(dto: dto),
            fees: fees,
            gasCostUSD: gasCostUSD,
            estimatedDurationSeconds: Int(dto.estimate.executionDuration ?? 0),
            approvalAddress: dto.estimate.approvalAddress,
            evmTx: evmTx,
            solanaTx: nil,
            expiresAt: Date().addingTimeInterval(quoteTTLSeconds)
        )
    }

    /// Price impact from the USD legs when both are present:
    /// `(fromUSD - toUSD) / fromUSD`. Li.Fi same-chain often omits a
    /// direct impact field, so we derive it honestly from the priced
    /// legs; `nil` when we can't.
    private static func priceImpact(dto: LiFiQuoteDTO) -> Decimal? {
        guard let fromUSD = Decimal(string: dto.estimate.fromAmountUSD ?? ""),
              let toUSD = Decimal(string: dto.estimate.toAmountUSD ?? ""),
              fromUSD > 0 else { return nil }
        let impact = (fromUSD - toUSD) / fromUSD
        // Clamp tiny negative noise (toUSD slightly > fromUSD) to 0.
        return impact < 0 ? 0 : impact
    }

    /// raw integer string ÷ 10^decimals → `Decimal` chain units.
    private static func humanAmount(_ raw: String, decimals: Int) -> Decimal {
        guard let value = Decimal(string: raw) else { return 0 }
        return value / pow(Decimal(10), decimals)
    }
}
