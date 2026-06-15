import Foundation
import OSLog

/// Real Jupiter REST client — Solana↔Solana SWAP, against
/// `https://lite-api.jup.ag/swap/v1` (the keyless free tier — Aperture
/// has no Jupiter key; Jupiter is keyless per the brief).
///
/// **Host choice (doc-grounded).** Jupiter's docs state the keyless free
/// tier is `lite-api.jup.ag` (60 req/min) and `api.jup.ag` is the
/// API-keyed tier (migration deadline postponed). Aperture uses
/// `lite-api.jup.ag` — live-verified 2026-06-15 (1 SOL → 71.35 USDC,
/// HTTP 200). Sources: https://dev.jup.ag/docs/api-setup, the
/// `lite-api` free-tier note.
///
/// **Endpoints:**
/// - `GET /swap/v1/quote` — the price + route. `inputMint`,
///   `outputMint`, `amount` (raw u64), `slippageBps`.
/// - `GET /tokens/v2/tag?query=verified` (Token API) — the verified SPL
///   token universe for the picker. Live-verified (4205 tokens).
///
/// The raw quote JSON is preserved in `SwapQuote.solanaTx` so the future
/// execute turn POSTs it to `/swap` (which returns the serialized
/// `VersionedTransaction`) without re-quoting — a real seam, not a stub.
actor JupiterClient {
    private let http: SwapHTTP
    private let session: URLSession
    private let swapBase = "https://lite-api.jup.ag/swap/v1"
    private let tokenBase = "https://lite-api.jup.ag/tokens/v2"
    private let quoteTTLSeconds: TimeInterval = 20
    private let log = Logger(subsystem: "com.thuglife.aperture", category: "swap")

    init(http: SwapHTTP = .shared) {
        self.http = http
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    // MARK: - Quote

    func quote(_ request: SwapQuoteRequest) async throws(SwapError) -> SwapQuote {
        guard request.fromToken.kind == .solana, request.toToken.kind == .solana else {
            throw .unsupportedPair("Jupiter only swaps Solana tokens")
        }

        var components = URLComponents(string: "\(swapBase)/quote")
        components?.queryItems = [
            URLQueryItem(name: "inputMint", value: request.fromToken.address),
            URLQueryItem(name: "outputMint", value: request.toToken.address),
            URLQueryItem(name: "amount", value: request.rawFromAmount),
            URLQueryItem(name: "slippageBps", value: String(request.slippageBps)),
        ]
        guard let url = components?.url else {
            throw .invalidResponse("couldn't build the Jupiter quote URL")
        }

        // Fetch raw so we can BOTH decode the DTO AND keep the exact JSON
        // for the execute seam (Jupiter /swap requires the verbatim
        // quoteResponse object).
        let (dto, rawJSON) = try await fetchQuote(url: url)
        return buildQuote(from: dto, rawJSON: rawJSON, request: request)
    }

    // MARK: - Tokens

    /// Verified SPL token universe for the picker. Returns `[]` (never
    /// throws) on failure so the picker degrades to the Aperture Solana
    /// registry.
    func tokens() async -> [SwapToken] {
        guard let url = URL(string: "\(tokenBase)/tag?query=verified") else { return [] }
        do {
            let list = try await http.getJSON([JupiterTokenDTO].self, url: url)
            return list.map { token in
                SwapToken(
                    chain: .solana,
                    kind: .solana,
                    address: token.id,
                    symbol: token.symbol,
                    name: token.name ?? token.symbol,
                    decimals: token.decimals,
                    logoURI: token.icon
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - Raw fetch (keep JSON for execute seam)

    private func fetchQuote(url: URL) async throws(SwapError) -> (JupiterQuoteDTO, String) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw .cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw .cancelled
        } catch let urlError as URLError {
            throw .network(urlError.localizedDescription)
        } catch {
            throw .network("request failed")
        }

        guard let http = response as? HTTPURLResponse else {
            throw .invalidResponse("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SwapError.from(status: http.statusCode, body: body)
        }

        do {
            let dto = try JSONDecoder().decode(JupiterQuoteDTO.self, from: data)
            let rawJSON = String(data: data, encoding: .utf8) ?? "{}"
            return (dto, rawJSON)
        } catch {
            log.error("jupiter decode failed: \(String(describing: error), privacy: .public)")
            throw .invalidResponse("couldn't parse the Jupiter response")
        }
    }

    // MARK: - Quote builder

    private func buildQuote(
        from dto: JupiterQuoteDTO,
        rawJSON: String,
        request: SwapQuoteRequest
    ) -> SwapQuote {
        let toDecimals = request.toToken.decimals
        let toAmount = Self.humanAmount(dto.outAmount, decimals: toDecimals)
        let toAmountMin = Self.humanAmount(dto.otherAmountThreshold, decimals: toDecimals)

        let fromHuman = request.amount
        let rate: Decimal = fromHuman > 0 ? (toAmount / fromHuman) : 0

        // Jupiter priceImpactPct is a fraction string (e.g. "0.000056").
        let priceImpact = Decimal(string: dto.priceImpactPct ?? "")

        // Per-hop LP fees aren't USD-priced by Jupiter's quote; surface
        // the route hops as protocol-fee lines with the raw fee amount
        // (honest — we don't fabricate a USD value we don't have).
        var fees: [SwapFee] = []
        for hop in dto.routePlan ?? [] {
            guard let info = hop.swapInfo,
                  let feeAmount = info.feeAmount, feeAmount != "0" else { continue }
            // Jupiter's per-hop LP fee is in the fee MINT's base units and
            // the quote doesn't give us that mint's decimals, so we can't
            // honestly denominate it — surface the fee line with no amount
            // (the UI shows "—") rather than a raw base-unit number. The
            // `feeAmount != "0"` guard above still gates the row's presence.
            fees.append(SwapFee(
                kind: .protocolFee,
                name: "\(info.label ?? "DEX") fee",
                amountDecimal: nil,
                tokenSymbol: "",
                amountUSD: 0
            ))
        }

        let toolName = dto.routePlan?.first?.swapInfo?.label ?? "Jupiter"

        return SwapQuote(
            quoteID: "jup-\(dto.contextSlot ?? 0)-\(dto.outAmount)",
            fromToken: request.fromToken,
            toToken: request.toToken,
            provider: .jupiter,
            stepKind: .swap,
            toolName: toolName,
            bridgeName: nil,
            fromAmountRaw: dto.inAmount,
            toAmountRaw: dto.outAmount,
            toAmountMinRaw: dto.otherAmountThreshold,
            toAmount: toAmount,
            toAmountMin: toAmountMin,
            rate: rate,
            priceImpact: priceImpact,
            fees: fees,
            gasCostUSD: 0, // Solana fees are ~0.000005 SOL; not USD-priced by the quote.
            estimatedDurationSeconds: 15,
            approvalAddress: nil, // Solana has no ERC-20-style approval.
            evmTx: nil,
            solanaTx: SwapSolanaTx(quoteResponseJSON: rawJSON),
            expiresAt: Date().addingTimeInterval(quoteTTLSeconds)
        )
    }

    private static func humanAmount(_ raw: String, decimals: Int) -> Decimal {
        guard let value = Decimal(string: raw) else { return 0 }
        return value / pow(Decimal(10), decimals)
    }
}
