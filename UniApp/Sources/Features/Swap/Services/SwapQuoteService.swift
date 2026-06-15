import Foundation

/// The single API the Swap UI talks to. Routes every quote request to
/// the right provider and exposes the swappable-token universe per chain.
///
/// **Routing (doc-grounded + live-verified 2026-06-15):**
/// - Solana → Solana ⇒ **Jupiter** (`lite-api.jup.ag`, keyless).
/// - Everything else (EVM↔EVM same-chain swap, EVM↔EVM bridge,
///   EVM↔Solana bridge) ⇒ **Li.Fi** (`li.quest`, `x-lifi-api-key`).
///
/// **Honest gating (Rule #16 / Rule #24).** EVM/cross-chain quotes
/// require the Li.Fi key — if `Secrets.hasLifiKey == false`, the service
/// throws `SwapError.notConfigured` instead of faking a quote. Jupiter
/// (Solana→Solana) is keyless and always available.
///
/// **Off-main (Rule #28).** This is an `actor`; the clients are actors;
/// the HTTP layer is an actor. The UI `await`s; nothing blocks the main
/// thread. The UI is expected to debounce amount changes — the service
/// performs one live call per invocation (no internal debounce, so the
/// UI keeps full control of cancellation).
///
/// **Local-first note (Rule #27).** A swap quote is an inherently
/// real-time, action-time read (a stale quote loses funds), so it is the
/// Send/dApp-class carve-out: fetched at the moment the user is
/// composing the swap, surfaced live, and — in the future execute turn —
/// the resulting tx is persisted to the outbox before broadcast. The
/// quote itself is not cached as a source of truth; only the token
/// universe is cached (it's reference data, not a price).
actor SwapQuoteService {
    private let lifi: LiFiClient
    private let jupiter: JupiterClient

    /// Token-universe cache: `chain → (tokens, fetchedAt)`. Reference
    /// data, refreshed lazily. Quotes are never cached.
    private var tokenCache: [SupportedChain: (tokens: [SwapToken], fetchedAt: Date)] = [:]
    private let tokenCacheTTL: TimeInterval = 60 * 30 // 30 min

    static let shared = SwapQuoteService()

    init(lifi: LiFiClient = LiFiClient(), jupiter: JupiterClient = JupiterClient()) {
        self.lifi = lifi
        self.jupiter = jupiter
    }

    // MARK: - Quote

    /// Fetch the single best live quote for `request`. Throws typed
    /// `SwapError` (never returns a fabricated quote).
    func quote(_ request: SwapQuoteRequest) async throws(SwapError) -> SwapQuote {
        // Reject same-token same-chain (nothing to swap).
        if request.fromToken.chain == request.toToken.chain,
           request.fromToken.address.lowercased() == request.toToken.address.lowercased() {
            throw .unsupportedPair("choose two different tokens")
        }
        // Reject dust / zero.
        guard request.amount > 0 else { throw .amountTooSmall }

        // Both chains must be swappable.
        guard SwapChainMap.isSwappable(request.fromToken.chain) else {
            throw .unsupportedPair("\(request.fromToken.chain.displayName) isn't supported for swaps")
        }
        guard SwapChainMap.isSwappable(request.toToken.chain) else {
            throw .unsupportedPair("\(request.toToken.chain.displayName) isn't supported for swaps")
        }

        let fromKind = SwapChainMap.kind(for: request.fromToken.chain)
        let toKind = SwapChainMap.kind(for: request.toToken.chain)

        // Solana → Solana ⇒ Jupiter. Everything else ⇒ Li.Fi.
        if fromKind == .solana && toKind == .solana {
            return try await jupiter.quote(request)
        }
        return try await lifi.quote(request)
    }

    // MARK: - Tokens

    /// The swappable-token universe for `chain` (cached). Solana →
    /// Jupiter verified list; EVM → Li.Fi `/tokens`. Returns `[]` on
    /// failure (the UI falls back to the Aperture registry).
    func tokens(for chain: SupportedChain) async -> [SwapToken] {
        guard SwapChainMap.isSwappable(chain) else { return [] }

        if let cached = tokenCache[chain],
           Date().timeIntervalSince(cached.fetchedAt) < tokenCacheTTL,
           !cached.tokens.isEmpty {
            return cached.tokens
        }

        let fetched: [SwapToken]
        if chain == .solana {
            fetched = await jupiter.tokens()
        } else {
            fetched = await lifi.tokens(for: chain)
        }

        if !fetched.isEmpty {
            tokenCache[chain] = (fetched, Date())
        }
        return fetched
    }

    // MARK: - Search (provider fallback for tokens we don't curate)

    /// Search the providers for a token NOT in Aperture's curated list,
    /// across the given swappable `chains` in PARALLEL (Rule #28). EVM
    /// chains → Li.Fi `GET /token` (one match each, by symbol or contract);
    /// Solana → Jupiter `GET /tokens/v2/search` (verified-first). Returns
    /// the flat union of matches — the picker folds them into `SwapAsset`
    /// rows so provider hits render exactly like curated rows. Empty query
    /// or no swappable chains → `[]`. Never throws (best-effort search).
    func searchTokens(query: String, chains: [SupportedChain]) async -> [SwapToken] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let swappable = Set(chains.filter { SwapChainMap.isSwappable($0) })
        guard !swappable.isEmpty else { return [] }
        let evmChains = swappable.filter { SwapChainMap.kind(for: $0) == .evm }
        let includeSolana = swappable.contains(.solana)

        // Two parallel calls (Rule #28): ONE Li.Fi multi-chain token search
        // across every swappable EVM chain (`/tokens?chains=…&search=`), plus
        // Jupiter for Solana. Both match name / symbol / contract; both
        // return [] on failure. EVM hits come first so a canonical multi-EVM
        // token (e.g. LINK) is seen before single-chain Solana look-alikes;
        // `SwapAsset.fromProviderTokens` then folds + ranks the union.
        async let evm: [SwapToken] = evmChains.isEmpty
            ? [] : lifi.searchTokens(query: trimmed, chains: Array(evmChains))
        async let solana: [SwapToken] = includeSolana
            ? jupiter.searchTokens(query: trimmed) : []
        return await evm + solana
    }

    // MARK: - Execute (build the signable Solana swap tx)

    /// Build the signable Solana swap transaction (Jupiter `/swap`) from the
    /// quote's verbatim `quoteResponseJSON`. Delegates to the shared Jupiter
    /// client so the executor doesn't spin up its own. Returns the base64
    /// `VersionedTransaction`, or `nil` on failure.
    func buildSolanaSwap(quoteResponseJSON: String, userPublicKey: String) async -> String? {
        await jupiter.fetchSwapTransaction(quoteResponseJSON: quoteResponseJSON, userPublicKey: userPublicKey)
    }

    /// `true` when EVM/cross-chain quotes are available (Li.Fi key set).
    /// Solana→Solana (Jupiter) is always available regardless.
    nonisolated var isLiFiConfigured: Bool { Secrets.hasLifiKey }

    /// The chains the user can swap on (EVM subset + Solana).
    nonisolated var swappableChains: [SupportedChain] {
        SupportedChain.allCases.filter { SwapChainMap.isSwappable($0) }
    }
}
