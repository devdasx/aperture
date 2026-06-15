import SwiftUI

/// The compose-screen state + quote engine for one swap/bridge draft.
///
/// **What it owns.** The from-token, the to-token, the human amount the
/// user typed, the slippage tolerance, the live quote (and its loading /
/// error state), and the from/to balances read from the local store
/// (Rule #27). It is the single source of truth the `SwapComposeView`
/// renders from.
///
/// **Off-main + debounced (Rule #28).** `requestQuote()` debounces ~400ms,
/// then `await`s `SwapQuoteService.shared.quote(_:)` (an actor — the
/// network never touches the main thread). A monotonically-increasing
/// `quoteToken` discards stale responses when the user keeps typing. A
/// background ticker re-quotes every ~25s while the panel is valid, so the
/// price never goes stale under the user's eyes (Stabro behavior).
///
/// **Honest (Rule #16 / Rule #26).** The engine NEVER fabricates a quote.
/// On any `SwapError` it surfaces the typed `.message`; on success it shows
/// the real numbers from Li.Fi / Jupiter. Execution (sign + broadcast) is
/// the next increment — `makeReview()` produces an honest summary, not a
/// transaction.
@MainActor
@Observable
final class SwapComposeModel {

    // MARK: - Phase

    /// The quote panel's current phase. `.idle` until both sides + a
    /// positive amount are set; `.loading` while a fetch is in flight;
    /// `.quoted` with the live quote; `.failed` with the honest message.
    enum Phase: Equatable {
        case idle
        case loading
        case quoted(SwapQuote)
        case failed(SwapError)
    }

    // MARK: - Sides

    /// The asset being sold. Defaults to the wallet's highest-value
    /// swappable holding (set by the view from the store); falls back to
    /// the native coin of the first swappable chain.
    var fromToken: SwapToken {
        didSet { if fromToken != oldValue { onSidesChanged() } }
    }
    /// The asset being bought. `nil` until the user picks it — the screen
    /// opens with the TO side empty, inviting the choice.
    var toToken: SwapToken? {
        didSet { if toToken != oldValue { onSidesChanged() } }
    }

    /// Human-readable from-amount text the user typed (the hero field).
    var amountText: String = "" {
        didSet { if amountText != oldValue { onAmountChanged() } }
    }

    /// Slippage tolerance in basis points (50 = 0.50%). Default 0.5%.
    var slippageBps: Int = 50 {
        didSet { if slippageBps != oldValue { requestQuote() } }
    }

    // MARK: - Identity (signing side)

    /// The sender's address on `fromToken.chain` — resolved by the view
    /// from the active wallet. Required by both providers to build the tx.
    /// Empty when the wallet has no address on the from-chain (the screen
    /// gates the CTA + shows an honest note).
    var fromAddress: String = ""
    /// The receiver's address on `toToken.chain` for a cross-chain bridge
    /// (the wallet's own address on the destination chain). `nil` for a
    /// same-chain swap (provider defaults to `fromAddress`).
    var toAddress: String?

    // MARK: - Balances (local-first, Rule #27)

    /// Available balance of `fromToken` in chain units (read from the
    /// store by the view). Drives MAX + the available line + over-balance.
    var fromBalance: Decimal = 0
    /// Available balance of `toToken` in chain units, when the wallet
    /// holds it (display-only on the TO card).
    var toBalance: Decimal?

    // MARK: - Pricing (display-only fiat, optional)

    /// Unit fiat price of the from-token (active currency). Optional — the
    /// amount field works without it; when present the conversion line shows.
    var fromUnitPrice: Decimal?
    /// Active fiat currency code, for the conversion line.
    var currencyCode: String

    // MARK: - Quote state

    private(set) var phase: Phase = .idle

    /// Monotonic token — every `requestQuote` bumps it; a response whose
    /// token no longer matches is discarded (handles fast retyping).
    private var quoteToken = 0
    /// The in-flight debounce/fetch task, cancelled when inputs change.
    private var quoteTask: Task<Void, Never>?
    /// The background auto-refresh ticker, alive only while the panel is
    /// valid + visible.
    private var refreshTask: Task<Void, Never>?

    /// Set by `engageMax()` for a NATIVE-coin MAX. The full balance is
    /// filled immediately; once the next quote returns the real gas, the
    /// amount is re-capped to `balance − gas` so the swap leaves enough to
    /// pay the fee (prevents "insufficient funds for gas"). Cleared the
    /// moment the re-cap runs, so it fires at most once per MAX.
    private var pendingNativeMaxRecap = false

    private let service: SwapQuoteService
    private let debounce: Duration = .milliseconds(400)
    private let autoRefresh: Duration = .seconds(25)

    // MARK: - Init

    init(
        fromToken: SwapToken,
        toToken: SwapToken? = nil,
        currencyCode: String,
        service: SwapQuoteService = .shared
    ) {
        self.fromToken = fromToken
        self.toToken = toToken
        self.currencyCode = currencyCode
        self.service = service
    }

    // MARK: - Derived

    /// `0` when the field is empty / unparseable; the parsed amount otherwise.
    var amount: Decimal {
        Self.parseAmount(amountText)
    }

    /// `true` when the from/to chains differ — this is a BRIDGE, not a swap.
    var isCrossChain: Bool {
        guard let toToken else { return false }
        return fromToken.chain != toToken.chain
    }

    /// The verb for titles / labels: "Bridge" cross-chain, "Swap" same-chain.
    var actionVerb: LocalizedStringKey {
        isCrossChain ? "Bridge" : "Swap"
    }

    /// `true` when the typed amount can't actually be spent. Two cases: it
    /// exceeds the from-balance outright; OR — for the native coin — the REAL
    /// native outflow the signed tx pulls (`evmTx.value`, which on a bridge
    /// can exceed the requested amount via a folded-in native fee) plus the
    /// network gas would exceed the balance, leaving nothing for the fee. The
    /// gas leg uses the live quote's real estimate with a last-resort
    /// per-family floor, so a native swap is NEVER allowed to consume the gas
    /// headroom (Rule #26). This is what prevents the "insufficient funds for
    /// gas" broadcast failure at (or near) the full native balance.
    var isOverBalance: Bool {
        guard amount > 0 else { return false }
        if amount > fromBalance { return true }
        guard fromToken.isNative, let quote = liveQuote else { return false }
        return nativeSpend(in: quote) + gasReserve(in: quote) > fromBalance
    }

    /// The live quote's network-gas reserve in the FROM-coin's own units, or
    /// `nil` for a token swap (gas is paid separately in the native coin) or
    /// before a quote exists. Display-only accessor; the gate uses
    /// `gasReserve(in:)` directly.
    var gasReserveNative: Decimal? {
        guard fromToken.isNative, let quote = liveQuote else { return nil }
        return gasReserve(in: quote)
    }

    /// The native-coin gas to keep aside for a NATIVE-coin swap, in coin
    /// units. Layered so it is NEVER zero for a native swap with a live quote:
    ///  1. Sum every `.gas` fee — Li.Fi prices EVM gas in the chain's native
    ///     coin, so for a native FROM coin every gas fee is native-denominated;
    ///     match by KIND, not symbol (avoids the POL ≠ "MATIC" rebrand trap and
    ///     the EIP-1559 case where the quote carries no `gasPrice` hex).
    ///  2. EVM-tx fallback mirroring the executor's worst case: gasLimit + 20%
    ///     (or the 800k ceiling the executor falls back to) × gasPrice.
    ///  3. A conservative per-family floor — Solana/Jupiter reports no `.gas`
    ///     fee and no evmTx (and an EVM route omitting both is unheard-of but
    ///     still guarded) — so a full-balance native MAX can never broadcast
    ///     with less than the fee. `0` for token swaps (gas paid separately).
    private func gasReserve(in quote: SwapQuote) -> Decimal {
        guard fromToken.isNative else { return 0 }
        let feeGas = quote.fees
            .filter { $0.kind == .gas }
            .compactMap(\.amountDecimal)
            .reduce(0, +)
        var evmGas: Decimal = 0
        if let tx = quote.evmTx, let price = Self.hexToDecimal(tx.gasPrice), price > 0 {
            let limit = Self.hexToDecimal(tx.gasLimit).map { $0 + $0 / Decimal(5) } ?? Self.fallbackGasLimit
            evmGas = (limit * price) / Self.weiPerEther
        }
        let known = max(feeGas, evmGas)
        if known > 0 { return known }
        return fromToken.kind == .solana ? Self.solanaFeeFloor : Self.evmFeeFloor
    }

    /// The actual native-coin outflow the SIGNED tx pulls from the sender —
    /// `evmTx.value` (which on a native cross-chain bridge can EXCEED the
    /// requested `amount` by a folded-in native relayer/deposit fee), else the
    /// requested amount (Solana / no evmTx, where `amount` is the outflow and
    /// the network fee is reserved separately by `gasReserve(in:)`).
    private func nativeSpend(in quote: SwapQuote) -> Decimal {
        if let tx = quote.evmTx, let value = Self.hexToDecimal(tx.value) {
            return value / Self.weiPerEther
        }
        return amount
    }

    /// Whether the from-chain has a usable sending address.
    var hasFromAddress: Bool {
        !fromAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A cross-chain BRIDGE needs the wallet's OWN receiving address on the
    /// destination chain. If it's missing, the provider would default the
    /// receiver to the SOURCE address — harmless for EVM→EVM (same 0x
    /// address) but a cross-family bridge (EVM↔Solana) would send the
    /// bridged funds to a wrong-format address = loss (Rule #16). We block
    /// the quote + the CTA when it's missing.
    var needsBridgeReceiver: Bool {
        guard isCrossChain else { return false }
        return (toAddress ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The live quote when the panel is in `.quoted` and not expired.
    var liveQuote: SwapQuote? {
        if case let .quoted(quote) = phase, !quote.isExpired { return quote }
        return nil
    }

    /// The CTA is enabled only with a real, current, affordable quote on a
    /// fundable address (Rule #19 — gate the commit on a valid quote).
    var canReview: Bool {
        liveQuote != nil && hasFromAddress && !isOverBalance && amount > 0
            && !needsBridgeReceiver
    }

    /// Slippage as a percent string for the chips ("0.5%"). Plain-decimal,
    /// trailing zeros trimmed, locale-neutral (the value is a fixed config
    /// number, not user-facing currency).
    static func slippageLabel(bps: Int) -> String {
        let pct = (Decimal(bps) / 100) as NSDecimalNumber
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        let text = formatter.string(from: pct) ?? pct.stringValue
        return "\(text)%"
    }

    /// An editable, plain-decimal percent string for a bps value (no `%`
    /// suffix, no grouping) — used to seed the custom-slippage input field
    /// from the current tolerance. `"0.5"` for 50 bps, `"2.5"` for 250 bps.
    static func customPercentString(bps: Int) -> String {
        let pct = (Decimal(bps) / 100) as NSDecimalNumber
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: pct) ?? pct.stringValue
    }

    /// Parse a typed custom-slippage percent string → basis points
    /// (`bps = round(percent * 100)`). Accepts `.` or `,` as the decimal
    /// separator (the value is small — 0.01–50% — so a grouping separator is
    /// never legitimate). Returns `nil` for empty input AND for anything that
    /// isn't ONE clean decimal: a second separator, a grouped number, spaces,
    /// or stray characters are REJECTED — not silently truncated to a
    /// wrong-but-plausible value (`"1.2.3"`, a German/French `"12,345.6"`, and
    /// `"1 000,5"` all return nil rather than committing 1.2% / 12.35% / 10%).
    /// Does NOT clamp — the caller applies the sane bounds so the bound policy
    /// lives at one site.
    static func parseSlippagePercent(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Comma → dot (comma-locale keyboards), then tolerate a lone leading or
        // trailing dot the decimal pad can leave (".5" → "0.5", "1." → "1").
        var normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        if normalized.hasPrefix(".") { normalized = "0" + normalized }
        if normalized.hasSuffix(".") { normalized.removeLast() }
        // Require exactly one clean decimal — no second separator, no spaces,
        // no other characters — so a grouped/garbled string is rejected
        // instead of `Decimal(string:)` keeping only its leading prefix.
        guard normalized.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let percent = Decimal(string: normalized) else { return nil }
        let bps = (percent * 100) as NSDecimalNumber
        let rounded = bps.rounding(accordingToBehavior:
            NSDecimalNumberHandler(roundingMode: .plain, scale: 0,
                                   raiseOnExactness: false, raiseOnOverflow: false,
                                   raiseOnUnderflow: false, raiseOnDivideByZero: false))
        return rounded.intValue
    }

    // MARK: - Actions

    /// Swap the FROM and TO sides (the flip button). When the to-side is
    /// empty there's nothing to flip into FROM, so it's a no-op.
    func flipSides() {
        guard let currentTo = toToken else { return }
        // A flip is a fresh composition, never a continuation of a pending
        // MAX — drop the recap flag so a later quote can't re-cap a side the
        // user didn't MAX (a double-flip back to native would otherwise leak).
        pendingNativeMaxRecap = false
        let currentFrom = fromToken
        // Swap balances + prices too so the cards stay coherent until the
        // view re-reads the store.
        let newFromBalance = toBalance ?? 0
        let newToBalance: Decimal? = fromBalance
        fromToken = currentTo
        toToken = currentFrom
        fromBalance = newFromBalance
        toBalance = newToBalance
        // The new from-price is unknown until the view re-resolves it.
        fromUnitPrice = nil
        // Carry the received estimate into the from-field as the new amount
        // (the natural "swap back roughly this much" gesture); fall back to
        // clearing if there was no quote.
        if case let .quoted(quote) = phase {
            amountText = Self.editableString(quote.toAmount)
        } else {
            amountText = ""
        }
        // onSidesChanged() fires via the didSet on fromToken/toToken.
    }

    /// Fill the from-amount with the full available balance (MAX). For the
    /// native coin we still must leave gas behind, so we fill the full
    /// balance now and re-cap to `balance − gas` once the quote returns the
    /// real gas estimate (`pendingNativeMaxRecap`). A token MAX is the full
    /// token balance — its gas is paid separately in the native coin.
    func engageMax() {
        guard fromBalance > 0 else { return }
        // Fill first (its didSet clears any prior pending recap), THEN arm the
        // recap — so this MAX's flag survives but a later manual edit cancels it.
        amountText = Self.editableString(fromBalance)
        pendingNativeMaxRecap = fromToken.isNative
    }

    /// Cancel everything (view disappeared).
    func cancel() {
        quoteTask?.cancel()
        refreshTask?.cancel()
        quoteTask = nil
        refreshTask = nil
    }

    // MARK: - Quote engine

    /// (Re)start the debounced quote. Called on every input change. Resets
    /// to `.idle` when the inputs aren't a complete, positive request.
    func requestQuote() {
        quoteTask?.cancel()
        refreshTask?.cancel()
        refreshTask = nil

        guard let toToken, amount > 0, hasFromAddress else {
            phase = .idle
            return
        }
        // Same token, same chain → nothing to swap. Surface an honest
        // message instead of a silent idle dead-end, so the user sees WHY no
        // quote appears when both sides are the identical token (Rule #16).
        if fromToken.chain == toToken.chain,
           fromToken.address.lowercased() == toToken.address.lowercased() {
            quoteTask?.cancel(); refreshTask?.cancel(); refreshTask = nil
            phase = .failed(.unsupportedPair("choose two different tokens"))
            return
        }
        // Fund-safety: a cross-chain bridge with no receiving address on the
        // destination chain would default the receiver to the source address
        // (wrong on a cross-family bridge). Refuse honestly rather than quote
        // — and bake — a mis-addressed transaction (Rule #16).
        if needsBridgeReceiver {
            quoteTask?.cancel(); refreshTask?.cancel(); refreshTask = nil
            phase = .failed(.noReceivingAddress(toToken.chain.displayName))
            return
        }

        quoteToken &+= 1
        let token = quoteToken
        let request = SwapQuoteRequest(
            fromToken: fromToken,
            toToken: toToken,
            amount: amount,
            slippageBps: slippageBps,
            fromAddress: fromAddress,
            toAddress: toAddress
        )

        phase = .loading
        quoteTask = Task { [weak self] in
            // Debounce so fast typing makes one network call, not many.
            try? await Task.sleep(for: self?.debounce ?? .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.runQuote(request, token: token)
        }
    }

    /// Perform one quote fetch + apply iff still the newest request.
    private func runQuote(_ request: SwapQuoteRequest, token: Int) async {
        do {
            let quote = try await service.quote(request)
            guard !Task.isCancelled, token == quoteToken else { return }
            phase = .quoted(quote)
            applyNativeMaxRecapIfNeeded(using: quote)
            scheduleAutoRefresh()
        } catch let error as SwapError {
            guard !Task.isCancelled, token == quoteToken else { return }
            if case .cancelled = error { return } // not a user-facing error
            phase = .failed(error)
        }
    }

    /// After a native-coin MAX, re-cap the amount to `balance − gas×headroom`
    /// using the quote's REAL gas, so the swap leaves enough to pay the fee
    /// (prevents the "insufficient funds for gas" broadcast failure). Fires
    /// at most once per MAX engagement — it clears the flag before mutating
    /// `amountText`, so the re-quote that mutation triggers won't recurse.
    private func applyNativeMaxRecapIfNeeded(using quote: SwapQuote) {
        guard pendingNativeMaxRecap else { return }
        pendingNativeMaxRecap = false
        guard fromToken.isNative else { return }
        let reserve = gasReserve(in: quote)
        guard reserve > 0 else { return }
        // Account for any native fee Li.Fi folds ON TOP of the requested amount
        // (a bridge/relayer deposit makes evmTx.value > amount); 0 for a
        // same-chain swap where evmTx.value == amount.
        let extraNativeFee = max(0, nativeSpend(in: quote) - amount)
        let capped = fromBalance - reserve * Self.gasHeadroom - extraNativeFee
        let newText = capped > 0 ? Self.editableString(capped) : ""
        if newText != amountText { amountText = newText }
    }

    /// Re-quote silently every ~25s while a live quote is shown, so the
    /// numbers stay fresh without the user re-touching anything.
    private func scheduleAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.autoRefresh)
                guard !Task.isCancelled else { return }
                // Only refresh while a live quote is on screen.
                guard self.liveQuote != nil else { return }
                self.requestQuote()
                return // requestQuote reschedules its own refresh on success
            }
        }
    }

    // MARK: - Change hooks

    private func onSidesChanged() {
        requestQuote()
    }

    private func onAmountChanged() {
        // A manual edit (anything that isn't the recap's own write, which
        // already cleared the flag before mutating `amountText`) cancels a
        // pending native MAX recap — the user has taken over the amount, so we
        // must not later overwrite it with balance − gas.
        pendingNativeMaxRecap = false
        requestQuote()
    }

    // MARK: - Review (honest boundary — execution is the next increment)

    /// Build the honest review summary from the live quote. Returns `nil`
    /// when there's no current quote (the CTA is gated, so this shouldn't
    /// be reached without one).
    func makeReview() -> SwapReviewSummary? {
        guard let quote = liveQuote else { return nil }
        return SwapReviewSummary(quote: quote, fromAmount: amount, slippageBps: slippageBps)
    }

    // MARK: - Parsing helpers

    /// Parse a user-typed amount string to `Decimal` (locale-tolerant —
    /// accepts both `.` and `,` as the decimal separator). `0` on failure.
    static func parseAmount(_ text: String) -> Decimal {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        return Decimal(string: normalized) ?? 0
    }

    /// A plain-decimal, editable string for a `Decimal` (no grouping, no
    /// scientific notation) — used to seed the field from MAX / flip.
    static func editableString(_ value: Decimal) -> String {
        guard value > 0 else { return "" }
        return (value as NSDecimalNumber).stringValue
    }

    // MARK: - Gas-reserve helpers (native MAX safety)

    /// Headroom multiplier over the reserved gas kept aside on a native MAX.
    /// `1.5` covers the executor's own +20% gasLimit bump plus live base-fee
    /// drift between quote and broadcast, erring toward a little harmless dust
    /// rather than a failed broadcast.
    private static let gasHeadroom = Decimal(15) / Decimal(10)
    /// `10^18` — wei per native coin (every EVM native is 18 decimals).
    private static let weiPerEther = Decimal(sign: .plus, exponent: 18, significand: 1)
    /// The gasLimit ceiling the executor falls back to when Li.Fi omits one
    /// (`SwapExecutor` uses `800_000`); mirrored here so the reserve covers it.
    private static let fallbackGasLimit = Decimal(800_000)
    /// Conservative native floor when no per-quote estimate exists. Solana:
    /// ~base fee + priority + temporary wSOL ATA rent (~0.00204 SOL). EVM:
    /// defensive only (Li.Fi always reports gas, so this is near-unreachable).
    private static let solanaFeeFloor = Decimal(3) / Decimal(1000)   // 0.003 SOL
    private static let evmFeeFloor = Decimal(1) / Decimal(1000)      // 0.001 native

    /// Parse a hex-quantity string (`0x…` or bare hex) to `Decimal`. `nil`
    /// for empty / malformed input. Used for the `gasLimit × gasPrice`
    /// fallback when a quote omits the native-denominated gas fee.
    static func hexToDecimal(_ hex: String?) -> Decimal? {
        guard var s = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s = String(s.dropFirst(2)) }
        guard !s.isEmpty, s.allSatisfy(\.isHexDigit) else { return nil }
        let sixteen = Decimal(16)
        var result = Decimal(0)
        for ch in s {
            guard let d = ch.hexDigitValue else { return nil }
            result = result * sixteen + Decimal(d)
        }
        return result
    }
}
