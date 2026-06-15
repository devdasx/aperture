import Foundation

// MARK: - SwapChainKind

/// Whether a `SwapToken` lives on an EVM chain or on Solana. The quote
/// engine routes Solana→Solana to Jupiter and everything else to Li.Fi,
/// so the kind is the routing discriminant.
enum SwapChainKind: String, Sendable, Hashable, Codable {
    case evm
    case solana
}

// MARK: - SwapToken

/// One token the user can swap from / to. Mirrors the normalized shape
/// the providers return (Li.Fi `/tokens`, Jupiter token list) plus the
/// Aperture chain it belongs to.
///
/// **`address` is the provider-facing identifier:**
/// - EVM: the ERC-20 contract address, or `nativeEVMSentinel`
///   (`0x0000…0000`) for the native coin — Li.Fi's native-token
///   convention (live-verified 2026-06-15: Li.Fi returns native ETH as
///   `0x0000000000000000000000000000000000000000`).
/// - Solana: the SPL mint, or `wrappedSOLMint` for native SOL — Jupiter
///   treats SOL as wrapped-SOL (`So111…112`) and wraps/unwraps in the
///   swap tx.
struct SwapToken: Sendable, Hashable, Identifiable, Codable {
    /// EVM native-coin sentinel — Li.Fi's `fromToken`/`toToken`
    /// convention for the native asset (ETH/BNB/POL/AVAX/…). Confirmed
    /// live 2026-06-15.
    static let nativeEVMSentinel = "0x0000000000000000000000000000000000000000"
    /// Wrapped-SOL mint — Jupiter's input/output mint for native SOL.
    /// Confirmed live 2026-06-15 (Jupiter quote 1 SOL → USDC).
    static let wrappedSOLMint = "So11111111111111111111111111111111111111112"

    /// Stable id: `"<chain.rawValue>.<address-lowercased>"`.
    var id: String { "\(chain.rawValue).\(address.lowercased())" }

    /// Aperture chain this token lives on.
    let chain: SupportedChain
    /// Kind discriminant — EVM vs Solana — for provider routing.
    let kind: SwapChainKind
    /// Provider-facing token identifier (EVM contract / SPL mint /
    /// native sentinel). Verbatim from the provider; never re-checksummed
    /// here (Li.Fi accepts lowercase EVM addresses).
    let address: String
    let symbol: String
    let name: String
    let decimals: Int
    /// Remote logo URL (Li.Fi `logoURI` / Jupiter `icon`). The UI
    /// resolves marks via `CoinMark` (Trust Wallet) primarily; this is a
    /// provider-supplied fallback for tokens outside the Aperture
    /// registry.
    let logoURI: String?

    /// `true` for the native coin (EVM sentinel or wrapped-SOL mint).
    var isNative: Bool {
        switch kind {
        case .evm:    return address.lowercased() == Self.nativeEVMSentinel
        case .solana: return address == Self.wrappedSOLMint
        }
    }
}

// MARK: - SwapQuoteRequest

/// The single input the UI hands to `SwapQuoteService.quote(_:)`.
///
/// `amount` is the human-readable from-amount in `Decimal` (e.g. `0.01`
/// for 0.01 ETH). The service converts it to the provider's raw integer
/// (`amount × 10^fromToken.decimals`, rounded down) using `Decimal`
/// math — never `Double` (Rule #28 money-math + the Stabro
/// `computeRawAmount` pattern).
struct SwapQuoteRequest: Sendable, Hashable {
    let fromToken: SwapToken
    let toToken: SwapToken
    /// Human-readable from-amount (chain units, not raw integer).
    let amount: Decimal
    /// Slippage tolerance in basis points (50 = 0.50%). Li.Fi takes a
    /// decimal (`bps / 10_000`); Jupiter takes bps directly.
    let slippageBps: Int
    /// The sender's address on `fromToken.chain` (EVM 0x… / Solana
    /// base58). Required by both providers to build the tx + estimate gas.
    let fromAddress: String
    /// Optional receiver. Defaults (provider-side) to `fromAddress`.
    /// For cross-chain bridges where the destination address differs
    /// (e.g. a Solana recipient for an EVM→Solana bridge), set this.
    let toAddress: String?

    init(
        fromToken: SwapToken,
        toToken: SwapToken,
        amount: Decimal,
        slippageBps: Int = 50,
        fromAddress: String,
        toAddress: String? = nil
    ) {
        self.fromToken = fromToken
        self.toToken = toToken
        self.amount = amount
        self.slippageBps = slippageBps
        self.fromAddress = fromAddress
        self.toAddress = toAddress
    }

    /// Same chain ⇒ swap; different chain ⇒ bridge.
    var isCrossChain: Bool {
        fromToken.chain != toToken.chain
    }

    /// Slippage as a decimal fraction (Li.Fi format): `0.005` for 50 bps.
    var slippageFraction: Double {
        Double(slippageBps) / 10_000.0
    }

    /// Raw integer from-amount as a plain-decimal string
    /// (`amount × 10^decimals`, rounded down). Plain-decimal — never
    /// scientific notation — via `NSDecimalNumber.stringValue`, matching
    /// the Stabro `computeRawAmount` pattern.
    var rawFromAmount: String {
        let multiplier = pow(Decimal(10), fromToken.decimals)
        var scaled = amount * multiplier
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .down)
        return (rounded as NSDecimalNumber).stringValue
    }
}

// MARK: - SwapProviderKind

/// Which engine produced a quote. Surfaced in the UI ("via Li.Fi" /
/// "via Jupiter") and used by the future execute step to pick the
/// signer path.
enum SwapProviderKind: String, Sendable, Hashable, Codable {
    case lifi
    case jupiter
    /// KyberSwap aggregator — independent same-chain EVM quote source raced
    /// against Li.Fi (keyless). Signs through the same EVM path as Li.Fi.
    case kyberswap
    /// OpenOcean aggregator — independent same-chain EVM quote source raced
    /// against Li.Fi (keyless; its Solana support is a later increment).
    case openocean

    /// `true` when the quote is signed via the EVM path (`evmTx`). Every EVM
    /// aggregator shares Li.Fi's sign+approval flow; only Jupiter is Solana.
    var isEVMSigned: Bool {
        switch self {
        case .lifi, .kyberswap, .openocean: return true
        case .jupiter: return false
        }
    }
}

// MARK: - SwapStepKind

enum SwapStepKind: String, Sendable, Hashable, Codable {
    case swap
    case bridge
}

// MARK: - SwapFee

/// One line in the quote's fee breakdown. `kind` separates the gas
/// estimate, the protocol/integrator fee, and the bridge/relayer fee so
/// the UI can group them (Rule #16 — honest fee disclosure).
struct SwapFee: Sendable, Hashable, Codable, Identifiable {
    enum Kind: String, Sendable, Hashable, Codable {
        case gas       // network gas (Li.Fi gasCosts)
        case bridge    // bridge / relayer fee (cross-chain)
        case protocolFee // integrator / LP / protocol fee
    }
    var id: String { "\(kind.rawValue).\(name).\(amountUSD)" }
    let kind: Kind
    /// Human-readable label, e.g. "Relayer fee", "LIFI Fixed Fee", "Gas".
    let name: String
    /// Human fee amount in the fee token's OWN units (already divided by the
    /// token's decimals at construction). `nil` when the provider didn't give
    /// us the fee token's decimals (e.g. Jupiter per-hop LP fees in an
    /// unknown-decimals mint) — the UI then shows "—" rather than a raw
    /// base-unit number, which would be a wrong-magnitude lie (Rule #16).
    let amountDecimal: Decimal?
    /// Fee token symbol (e.g. "ETH", "USDC").
    let tokenSymbol: String
    /// Fee value in USD (`Decimal`). `0` when the provider didn't price it.
    let amountUSD: Decimal
}

// MARK: - SwapTxRequest (EVM execute seam)

/// The raw EVM transaction Li.Fi returns in `transactionRequest`. The
/// FUTURE execute step signs + broadcasts this via Aperture's existing
/// signing engine (mirrors Stabro `TransactionSigner.signRawEVM`). All
/// numeric fields are hex-quantity strings as the chain expects.
///
/// This is a SEAM, not a stub: the quote carries the real, signable tx
/// today; the execute turn wires the signer to it without re-fetching.
struct SwapTxRequest: Sendable, Hashable, Codable {
    /// Router/spender contract the tx calls. MUST be allowlist-verified
    /// (`SwapRouterAllowlist`) before it is ever signed.
    let to: String
    /// ABI-encoded calldata (hex `0x…`).
    let data: String
    /// Native value to send (hex wei, e.g. `0x2386f26fc10000`).
    let value: String
    /// EIP-155 chain id the tx must be signed for.
    let chainId: Int?
    /// Suggested gas limit (hex). The signer may re-estimate.
    let gasLimit: String?
    /// Legacy gas price (hex) when present. EIP-1559 chains derive
    /// maxFee/maxPriorityFee at sign time from live base fee.
    let gasPrice: String?
}

// MARK: - SwapSolanaTx (Solana execute seam)

/// The Solana execute seam. Jupiter's `/quote` is the price; the
/// `/swap` POST (execute turn) returns a base64 serialized
/// `VersionedTransaction` the signer signs + broadcasts (mirrors Stabro
/// `TransactionSigner.signRawSolana`). For the quote-only scope this
/// turn, we carry the raw Jupiter quote JSON so the execute turn can
/// POST it to `/swap` without re-quoting.
struct SwapSolanaTx: Sendable, Hashable, Codable {
    /// The exact Jupiter quote-response JSON (UTF-8). The execute turn
    /// sends it back to Jupiter `/swap` as `quoteResponse` to get the
    /// serialized tx. Opaque to the quote layer — it never parses it
    /// beyond what `SwapQuote` already surfaces.
    let quoteResponseJSON: String
}

// MARK: - SwapQuote

/// The single, provider-agnostic quote the UI renders. Money fields are
/// `Decimal` for display math; raw integer amounts are kept as `String`
/// (provider-native) so no precision is lost crossing the boundary.
struct SwapQuote: Sendable, Hashable, Identifiable, Codable {
    var id: String { quoteID }
    /// Provider-supplied id (Li.Fi step id / Jupiter — a synthesized id).
    let quoteID: String

    // What is being swapped.
    let fromToken: SwapToken
    let toToken: SwapToken
    let provider: SwapProviderKind
    let stepKind: SwapStepKind
    /// Underlying tool/DEX/bridge name (e.g. "across", "fly", "Quantum").
    let toolName: String
    /// Bridge name when cross-chain (nil for same-chain swaps).
    let bridgeName: String?

    // Amounts — raw integer strings (provider-native, exact).
    /// Raw from-amount (smallest unit of `fromToken`).
    let fromAmountRaw: String
    /// Estimated raw to-amount (smallest unit of `toToken`).
    let toAmountRaw: String
    /// Guaranteed-minimum raw to-amount after slippage.
    let toAmountMinRaw: String

    // Human-readable derived (Decimal) for the UI.
    /// Estimated to-amount in chain units.
    let toAmount: Decimal
    /// Minimum to-amount after slippage, in chain units.
    let toAmountMin: Decimal
    /// 1 from-token = `rate` to-token.
    let rate: Decimal
    /// Price impact as a fraction (0.0023 = 0.23%). `nil` when the
    /// provider didn't report it (Li.Fi same-chain often omits it).
    let priceImpact: Decimal?

    // Fees + timing.
    let fees: [SwapFee]
    /// Total gas cost in USD (sum of Li.Fi `gasCosts.amountUSD`).
    let gasCostUSD: Decimal
    /// Estimated completion time in seconds (bridges take longer).
    let estimatedDurationSeconds: Int

    // Execute seam (future turn).
    /// Router/spender that needs ERC-20 approval before an EVM token
    /// swap (Li.Fi `estimate.approvalAddress`). `nil` for native-coin
    /// swaps and Solana.
    let approvalAddress: String?
    /// Signable EVM tx (Li.Fi). `nil` for Solana quotes.
    let evmTx: SwapTxRequest?
    /// Solana execute seam (Jupiter). `nil` for EVM quotes.
    let solanaTx: SwapSolanaTx?

    /// When this quote stops being trustworthy. The UI re-quotes after.
    let expiresAt: Date

    var isExpired: Bool { Date() > expiresAt }

    /// `1 USD` worth of slippage protection shown as a percentage label
    /// derived from estimate vs min. Convenience for the UI.
    var slippagePercent: Decimal {
        guard toAmount > 0 else { return 0 }
        return ((toAmount - toAmountMin) / toAmount) * 100
    }
}
