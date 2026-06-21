import Foundation
import Observation
import OSLog

/// The engine behind the Send amount/compose screen. Owns the draft state
/// the user is building (per-recipient amounts, the chosen fee, the
/// advanced memo/tag/op_return/UTXO selections), fetches the live fee
/// quote and the live spendable balance off-main (Rule #28), runs the
/// `SendDraftValidator`, and produces the validated `SendDraft` the next
/// (sign) step will consume.
///
/// **Local-first (Rule #27).** Balances are read from the SwiftData store
/// by the view and handed in via `setBalances(...)` — the model never
/// imports a network type for balances. The ONE network read it owns is
/// the live fee quote (`ComposeFeeService`) and, for the Bitcoin family,
/// the live UTXO set (`UTXOService`) — both are action-time fetches whose
/// results feed the draft (the Send carve-out in Rule #27 §C), run
/// off-main, and refresh when the user changes amount or fee tier.
///
/// **Honesty (Rule #2 / #16).** A fee that can't be fetched is surfaced as
/// `feeState == .failed` with a retry — never fabricated. Reserve /
/// min-balance / activation deductions are computed by `SendAmountMath`
/// from the real account state so "Max" and the spendable line tell the
/// truth.
@MainActor
@Observable
final class SendComposeModel {

    // MARK: - Identity (fixed for this compose session)

    let chain: SupportedChain
    let tokenSymbol: String?
    let tokenContract: String?
    let tokenDecimals: Int?
    let fromAddress: String
    let capability: ChainComposeCapability

    /// One editable amount per recipient (display units, as a string so
    /// the field can hold partial input like "0." mid-typing).
    struct AmountEntry: Identifiable, Hashable {
        let id = UUID()
        let address: String
        let name: String?
        var amountText: String = ""
    }

    var amounts: [AmountEntry]

    // MARK: - Entry mode

    /// Whether the amount field shows crypto or fiat. The user types in the
    /// active unit; the inactive unit is shown beneath as the conversion.
    enum EntryUnit: Hashable { case crypto, fiat }
    var entryUnit: EntryUnit = .crypto

    /// True while a "Max" / send-all is engaged on the (single-recipient)
    /// amount. Cleared the moment the user edits the field.
    var isMaxSend: Bool = false

    // MARK: - Fee

    /// The fetched quote (tiers + custom support + note). `nil` until the
    /// first fetch lands.
    private(set) var feeQuote: FeeQuote?

    /// The user's chosen tier (or `.custom`).
    var selectedTier: FeeTier = .normal

    /// A user-supplied custom fee, when the model is `.custom`. Replaces
    /// the preset choice for that tier.
    var customFee: FeeChoice?

    enum FeeState: Equatable { case idle, loading, loaded, failed(String) }
    private(set) var feeState: FeeState = .idle

    /// The resolved fee the draft will pay — the custom override when set
    /// and selected, else the selected preset, else the normal preset.
    /// Two honest, reactive overlays are applied on top of the base choice
    /// so every consumer (fee row, MAX, validation, draft) sees the same
    /// truth: the EVM advanced gas-limit override (FIX 4) and the TRON
    /// +1 TRX memo surcharge (FIX 9). The fee math itself is owned by the
    /// data layer (`ComposeFeeService.recomputeEVMTotals` /
    /// `applyTronMemoFee`) — the model never hand-rolls per-chain
    /// arithmetic.
    var resolvedFee: FeeChoice? {
        guard let base = baseResolvedFee else { return nil }
        return applyFeeOverlays(base)
    }

    /// The base choice before the gas-limit / memo overlays: the custom
    /// override when set and selected, else the selected preset, else the
    /// normal preset.
    private var baseResolvedFee: FeeChoice? {
        if selectedTier == .custom, let customFee { return customFee }
        if let quote = feeQuote {
            return quote.tiers[selectedTier] ?? quote.normal
        }
        return nil
    }

    /// Apply the reactive fee overlays via the data layer. EVM: when the
    /// user set a gas-limit override, re-stamp `gasLimit` and recompute the
    /// totals (`recomputeEVMTotals`). UTXO: when a vsize-dependent total
    /// has been computed for the current inputs, use it (FIX 3). TRON: when
    /// the user attached a memo, fold in the +1 TRX surcharge
    /// (`applyTronMemoFee`). Order is safe — these overlays never apply to
    /// the same chain.
    private func applyFeeOverlays(_ choice: FeeChoice) -> FeeChoice {
        var result = choice
        if chain.family == .evm, let override = gasLimitOverride, override > 0 {
            result.gasLimit = override
            result = ComposeFeeService.recomputeEVMTotals(result, decimals: chain.nativeDecimals)
        }
        if capability.supportsUTXO,
           let computed = utxoComputedFee, utxoFeeKey == utxoComputedFeeKey {
            // The off-main `selectCoins` recompute (FIX 3) derived the real
            // vsize-dependent total for the current rate + coins + amount.
            // Carry it onto the resolved choice's totals so the fee row and
            // MAX reflect the actual inputs, not the typical 1-in/2-out
            // estimate. Only apply when the key matches (no stale override).
            result.setTotals(
                estimated: computed.estimatedTotalNative,
                worst: computed.worstCaseTotalNative)
        }
        result = ComposeFeeService.applyTronMemoFee(
            result, hasMemo: hasMemoValue, decimals: chain.nativeDecimals)
        return result
    }

    // MARK: - UTXO vsize-dependent fee (FIX 3)

    /// The vsize-dependent fee total computed off-main by `selectCoins`
    /// from the selected/available coins + the target amount. nil until a
    /// recompute lands. Applied as an overlay in `applyFeeOverlays`.
    private(set) var utxoComputedFee: FeeChoice?
    /// The inputs fingerprint `utxoComputedFee` was computed for — guards
    /// against applying a stale override after coins/amount/rate change.
    private(set) var utxoComputedFeeKey: String = ""

    /// A fingerprint of the inputs that drive the UTXO vsize-dependent fee:
    /// the selected (or available) coin set + the target amount + the
    /// current byte-fee rate + tier. Recompute when this changes (FIX 3).
    var utxoFeeKey: String {
        guard capability.supportsUTXO else { return "" }
        let coins = (selectedUTXOs ?? availableUTXOs).map(\.id).sorted().joined(separator: ",")
        let rate = baseResolvedFee?.byteFeeRate.map { Self.plainString($0, decimals: 4) } ?? "?"
        // `rawTotalCrypto` (NOT `totalCrypto`) — the latter reads the funding
        // cascade → `resolvedFee` → here, an infinite recursion. See
        // `rawTotalCrypto`'s doc.
        let amount = Self.plainString(rawTotalCrypto, decimals: effectiveDecimals)
        return "\(coins)|\(amount)|\(rate)|\(selectedTier.rawValue)"
    }

    /// Re-derive the vsize-dependent UTXO fee off-main via the data layer's
    /// coin selection, then stamp the resulting total onto an overlay the
    /// `resolvedFee` applies (FIX 3 + Rule #28: the `selectCoins` work runs
    /// off the main actor; only the small write lands on the main actor).
    func recomputeUTXOFee(service: UTXOService = UTXOService()) async {
        guard capability.supportsUTXO, let base = baseResolvedFee,
              let rate = base.byteFeeRate, rate > 0 else { return }
        let dec = chain.nativeDecimals
        let coins = selectedUTXOs ?? availableUTXOs
        guard !coins.isEmpty else { return }
        let targetSats = NSDecimalNumber(
            decimal: ComposeDecimal.toBaseUnits(totalCrypto, decimals: dec)).int64Value
        let recipientCount = amounts.count
        let isAllSends = isMaxSend
        let chainForCalc = chain
        let key = utxoFeeKey

        // Off-main: the heavy coin selection + vsize estimation (Rule #28).
        let selection = await Task.detached(priority: .userInitiated) {
            service.selectCoins(
                utxos: coins, targetSats: max(targetSats, 0), feeRate: rate,
                chain: chainForCalc, recipientCount: recipientCount, sendAll: isAllSends)
        }.value
        guard !Task.isCancelled else { return }

        // Small write on the main actor: stamp the computed total. The
        // byte-fee model is deterministic, so estimated == worst.
        let feeNative = ComposeDecimal.toDisplay(Decimal(selection.feeSats), decimals: dec)
        var computed = base
        computed.setTotals(estimated: feeNative, worst: feeNative)
        utxoComputedFee = computed
        utxoComputedFeeKey = key
    }

    // MARK: - Balances (handed in from the local-first store)

    /// Native-coin spendable balance in display units.
    private(set) var nativeBalance: Decimal = 0
    /// Token balance in display units (nil for a native send).
    private(set) var tokenBalance: Decimal?
    /// Live account state for the reserve math (XRP owner count, Polkadot
    /// frozen/reserved, NEAR storage, Stellar subentries). Defaults are
    /// honest zeros until a refresh fills them.
    private(set) var accountState: SendAmountMath.AccountState = .init()

    // MARK: - Advanced data

    /// The typed memo/tag/comment value (per chain).
    var memo: SendMemoValue = .none
    /// OP_RETURN payload (UTXO advanced).
    var opReturnText: String = ""
    /// Selected UTXOs (nil = auto-select via coin selection).
    var selectedUTXOs: [SelectedUTXO]?
    /// The fetched UTXO set (Bitcoin family). Empty until fetched.
    private(set) var availableUTXOs: [SelectedUTXO] = []
    /// True while `loadUTXOs` is fetching — drives the coin-selection
    /// sheet's honest loading state so the user sees a spinner instead of
    /// a premature "no coins found" while the fetch is still in flight.
    private(set) var isLoadingUTXOs = false
    /// EVM advanced — a user gas-limit override (gas units). nil = use the
    /// fee service's estimate.
    var gasLimitOverride: Decimal?

    /// Whether the recipient is a brand-new/unactivated account (drives
    /// the activation surcharge + create-vs-pay branch). Set by the view
    /// from a live account check; defaults false (no surcharge shown).
    var recipientNeedsActivation: Bool = false
    /// Whether the recipient's account flag requires a destination tag
    /// (XRP) — drives the validator's required-tag gate.
    var recipientRequiresDestinationTag: Bool = false
    /// Whether the recipient requires a memo (known CEX / SEP-29).
    var recipientRequiresMemo: Bool = false

    // MARK: - Pricing (for the crypto⇄fiat toggle + fee fiat)

    /// Unit price of the SENT asset in the user's currency (per 1 token).
    /// nil = price unavailable (the toggle hides, fee fiat hides).
    private(set) var assetUnitPrice: Decimal?
    /// Unit price of the NATIVE coin in the user's currency (for the fee's
    /// fiat value, which is always paid in native).
    private(set) var nativeUnitPrice: Decimal?
    let currencyCode: String

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "send-compose")

    // MARK: - Init

    init(
        chain: SupportedChain,
        tokenSymbol: String?,
        tokenContract: String?,
        tokenDecimals: Int?,
        fromAddress: String,
        recipients: [SendRecipientEntry],
        currencyCode: String
    ) {
        self.chain = chain
        self.tokenSymbol = tokenSymbol
        self.tokenContract = tokenContract
        self.tokenDecimals = tokenDecimals
        self.fromAddress = fromAddress
        self.currencyCode = currencyCode
        self.capability = ChainComposeCapability.capability(for: chain)
        self.amounts = recipients.map { AmountEntry(address: $0.address, name: $0.name) }
    }

    // MARK: - Derived identity

    var isToken: Bool { tokenContract != nil }
    var assetSymbol: String { tokenSymbol ?? chain.ticker }
    var effectiveDecimals: Int { tokenDecimals ?? chain.nativeDecimals }
    var isMultiRecipient: Bool { capability.maxRecipients > 1 && amounts.count > 1 }

    /// The single amount entry (single-recipient screens bind to this).
    var primaryAmountText: String {
        get { amounts.first?.amountText ?? "" }
        set {
            guard !amounts.isEmpty else { return }
            amounts[0].amountText = newValue
            isMaxSend = false
        }
    }

    // MARK: - Parsing

    /// Parse a display-unit amount string (the user's typed value) into a
    /// `Decimal`. Locale-tolerant: accepts both "." and the locale's
    /// decimal separator. Empty / non-numeric → nil.
    static func parseAmount(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Normalize a comma decimal separator to a dot for `Decimal(string:)`.
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              value >= 0 else { return nil }
        // A send amount can never be negative. The numeric keypad can't type a
        // minus, but a crafted payment URI (EIP-681 / Solana Pay) could carry
        // one — reject it at the parse boundary so a negative amount can never
        // reach base-unit conversion or signing.
        return value
    }

    /// The crypto amount for one entry, resolving the fiat→crypto
    /// conversion when the user is typing in fiat.
    func cryptoAmount(for entry: AmountEntry) -> Decimal {
        guard let typed = Self.parseAmount(entry.amountText) else { return 0 }
        switch entryUnit {
        case .crypto:
            return typed
        case .fiat:
            guard let price = assetUnitPrice, price > 0 else { return 0 }
            return typed / price
        }
    }

    /// The resolved recipient+amount list (always in crypto display units).
    /// Excludes BLOCKED recipients (FIX 4): a recipient there isn't enough
    /// balance left to pay is intentionally unpaid — it contributes nothing
    /// to the draft and nothing to the total. Over-balance recipients DO
    /// contribute (so the validator's insufficient-funds gate still fires
    /// and Review stays honest).
    var recipientAmounts: [SendRecipientAmount] {
        let statuses = recipientFundingStatuses
        return amounts.enumerated().compactMap { offset, entry in
            if case .blocked = statuses[offset] { return nil }
            return SendRecipientAmount(address: entry.address, amount: cryptoAmount(for: entry), name: entry.name)
        }
    }

    /// Total crypto amount across all PAYABLE recipients (blocked excluded).
    var totalCrypto: Decimal {
        recipientAmounts.reduce(Decimal.zero) { $0 + $1.amount }
    }

    /// Sum of EVERY recipient's typed amount in crypto, WITHOUT the
    /// funding-status filter. Used to fingerprint the UTXO fee inputs
    /// (`utxoFeeKey`). It MUST NOT read the funding cascade — `totalCrypto`
    /// → `recipientFundingStatuses` → `allocatableTotal` → `resolvedFee` →
    /// `applyFeeOverlays` → `utxoFeeKey` would recurse infinitely (the
    /// Bitcoin amount-screen crash). This reads only `amounts` + the unit,
    /// so the fee-key fingerprint is cycle-free.
    var rawTotalCrypto: Decimal {
        amounts.reduce(Decimal.zero) { $0 + cryptoAmount(for: $1) }
    }

    /// Fiat value of an amount of the SENT asset (nil when no price).
    func fiatValue(ofCrypto crypto: Decimal) -> Decimal? {
        guard let price = assetUnitPrice, price > 0 else { return nil }
        return crypto * price
    }

    /// Fiat value of the network fee (paid in native), nil when no price.
    var feeFiat: Decimal? {
        guard let fee = resolvedFee, let price = nativeUnitPrice, price > 0 else { return nil }
        return fee.estimatedTotalNative * price
    }

    // MARK: - Spendable / Max

    var spendableNative: Decimal {
        SendAmountMath.available(
            chain: chain, nativeBalance: nativeBalance,
            tokenBalance: tokenBalance, isToken: isToken, state: accountState
        )
    }

    /// The "Max" amount (send-all) for the active asset in display units.
    /// nil when the fee isn't loaded yet (we can't honestly compute it).
    var maxAmount: Decimal? {
        guard let fee = resolvedFee else { return nil }
        return SendAmountMath.maxSend(
            chain: chain, nativeBalance: nativeBalance,
            tokenBalance: tokenBalance, isToken: isToken, fee: fee,
            state: accountState, recipientNeedsActivation: recipientNeedsActivation
        )
    }

    // MARK: - Per-recipient funding status (FIX 3 / FIX 4)

    /// The funding verdict for one recipient row.
    enum RecipientFundingStatus: Equatable {
        /// Funded and within what's left.
        case ok
        /// Editable, but the typed amount exceeds what's left to allocate
        /// (its amount renders red + a warning shows). Still contributes to
        /// the draft so the validator's insufficient-funds gate fires.
        case overBalance
        /// Not payable: too little balance remains to fund even the chain's
        /// minimum output. The row is dimmed + non-editable, with `reason`
        /// explaining why. Excluded from the total and the draft.
        case blocked(reason: String)
    }

    /// The chain's minimum payable output in display units. UTXO chains use
    /// the real per-output dust floor (BTC ≈546/294, DOGE hard dust) from
    /// the data layer (`SendAmountMath.dustMinimum`). Account-model chains
    /// have no protocol dust, so any positive amount above zero is payable
    /// — we treat "nothing left at all" as the block condition there.
    var minimumOutput: Decimal {
        SendAmountMath.dustMinimum(chain: chain)
    }

    /// The native balance available for allocation across recipients =
    /// spendable (already net of standing reserves) − worst-case fee. For a
    /// token send the fee is paid in native, so the full token balance is
    /// allocatable (the native-fee shortfall is the validator's job).
    var allocatableTotal: Decimal {
        if isToken { return max(tokenBalance ?? 0, 0) }
        let fee = resolvedFee?.worstCaseTotalNative ?? 0
        return max(spendableNative - fee, 0)
    }

    /// The cascade verdict for EVERY recipient, computed in ONE forward
    /// linear pass (Rule #28). Allocates in row order with a running
    /// accumulator: available for recipient `i` =
    /// `allocatableTotal − Σ(crypto of earlier, NON-blocked recipients)`.
    ///
    /// - Below the chain's minimum output (or nothing left) → `.blocked`
    ///   with an honest reason; a blocked row consumes nothing.
    /// - Typed amount exceeds the running available → `.overBalance` (red +
    ///   warning); it still consumes + contributes so the validator's
    ///   insufficient-funds gate fires and Review stays honest.
    /// - Else `.ok`.
    ///
    /// Single-recipient sends never block (no cascade). This is the single
    /// source of truth all consumers read (the old per-index recursive
    /// method was Θ(2ⁿ) — this is Θ(n), one pass over `Decimal` arithmetic).
    var recipientFundingStatuses: [RecipientFundingStatus] {
        guard resolvedFee != nil else {
            // No fee yet → can't honestly judge funding; calm `.ok` until
            // the quote lands.
            return Array(repeating: .ok, count: amounts.count)
        }
        let floor = max(minimumOutput, 0)
        let total = allocatableTotal
        var consumed: Decimal = .zero
        var result: [RecipientFundingStatus] = []
        result.reserveCapacity(amounts.count)
        for index in amounts.indices {
            let runningAvailable = total - consumed
            if isMultiRecipient {
                if runningAvailable <= 0 {
                    result.append(.blocked(reason: blockReason(.exhausted, index: index)))
                    continue // blocked rows consume nothing
                }
                if runningAvailable < floor {
                    result.append(.blocked(reason: blockReason(.belowMinimum, index: index)))
                    continue
                }
            }
            let typed = cryptoAmount(for: amounts[index])
            result.append(typed > runningAvailable ? .overBalance : .ok)
            consumed += typed // both .ok and .overBalance consume
        }
        return result
    }

    /// The cascade verdict for one row — indexes the single-pass array.
    func recipientFundingStatus(at index: Int) -> RecipientFundingStatus {
        let statuses = recipientFundingStatuses
        return statuses.indices.contains(index) ? statuses[index] : .ok
    }

    private enum BlockKind { case exhausted, belowMinimum }

    private func blockReason(_ kind: BlockKind, index: Int) -> String {
        switch kind {
        case .exhausted:
            return String(localized: "The earlier recipients use your whole balance — nothing is left for this one.")
        case .belowMinimum:
            // DISPLAY string → go through the central 8-decimal-truncated
            // helper (not plainString, which would render the chain's full
            // 18/24-decimal precision for this user-facing sentence).
            let floor = "\(WalletFormatting.native(minimumOutput, decimals: WalletFormatting.maxDisplayFractionDigits)) \(assetSymbol)"
            return String(localized: "Less than the network minimum (\(floor)) remains, so this recipient can't be paid.")
        }
    }

    /// Whether ANY recipient row is over its running available (drives the
    /// single/multi over-balance red treatment + warning).
    var hasOverBalanceRecipient: Bool {
        recipientFundingStatuses.contains(.overBalance)
    }

    /// Single-recipient over-balance (FIX 3): the typed amount exceeds what
    /// can be sent. Drives the hero amount's red color.
    var isOverBalance: Bool {
        recipientFundingStatuses.first == .overBalance
    }

    /// A recipient with a POSITIVE typed amount that resolved to `.blocked`
    /// — the earlier rows consume the balance so this one can't be paid.
    /// Excluding it from the draft silently would drop a typed amount, so
    /// this hard-gates Review with an honest reason (Rule #16).
    var hasBlockedFundedRecipient: Bool {
        let statuses = recipientFundingStatuses
        return amounts.indices.contains { i in
            if case .blocked = statuses[i] { return cryptoAmount(for: amounts[i]) > 0 }
            return false
        }
    }

    // MARK: - Validation

    var validationErrors: [SendValidationError] {
        guard let fee = resolvedFee else { return [] } // can't validate without a fee
        // OP_RETURN byte count for the data-note cap check (Bitcoin
        // family) — same gating as `makeDraft`: only when the chain
        // supports OP_RETURN and the user attached a note.
        let opReturnByteCount: Int? = {
            guard capability.opReturnMaxBytes != nil, hasOpReturn else { return nil }
            return opReturnText.utf8.count
        }()
        let inputs = SendDraftValidator.Inputs(
            chain: chain, isToken: isToken,
            nativeBalance: nativeBalance, tokenBalance: tokenBalance,
            recipients: recipientAmounts, fee: fee, state: accountState,
            memo: memo,
            opReturnByteCount: opReturnByteCount,
            recipientRequiresDestinationTag: recipientRequiresDestinationTag,
            recipientRequiresMemo: recipientRequiresMemo,
            recipientIsNew: recipientNeedsActivation
        )
        var errors = SendDraftValidator().validate(inputs)
        // A blocked row that still holds a positive amount would be dropped
        // from the draft silently — hard-gate Review instead (Rule #16).
        if hasBlockedFundedRecipient { errors.append(.recipientUnfunded) }
        return errors
    }

    /// The single blocking reason to surface beneath the CTA (the first
    /// error, in priority order). nil = nothing blocking from validation.
    var blockingError: SendValidationError? {
        validationErrors.first
    }

    /// Whether Review is reachable: a positive amount, a loaded fee, and
    /// zero validation errors.
    var canReview: Bool {
        guard feeState == .loaded || resolvedFee != nil else { return false }
        guard totalCrypto > 0 else { return false }
        return validationErrors.isEmpty
    }

    // MARK: - Memo presence (for the menu's checkmark / summary)

    var hasMemoValue: Bool {
        switch memo {
        case .none: return false
        default: return true
        }
    }

    var hasOpReturn: Bool {
        !opReturnText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Setters (off-render-path writers)

    func setBalances(
        native: Decimal, token: Decimal?, state: SendAmountMath.AccountState
    ) {
        nativeBalance = native
        tokenBalance = token
        accountState = state
    }

    func setPrices(asset: Decimal?, native: Decimal?) {
        assetUnitPrice = asset
        nativeUnitPrice = native
        // If no asset price, force crypto entry (the fiat toggle is moot).
        if assetUnitPrice == nil { entryUnit = .crypto }
    }

    func setAvailableUTXOs(_ utxos: [SelectedUTXO]) {
        availableUTXOs = utxos
    }

    // MARK: - Max

    func engageMax() {
        guard amounts.count == 1, let maxAmount, maxAmount > 0 else { return }
        isMaxSend = true
        // Write the max into the field in the ACTIVE unit so the user sees
        // what they're sending.
        switch entryUnit {
        case .crypto:
            amounts[0].amountText = Self.plainString(maxAmount, decimals: effectiveDecimals)
        case .fiat:
            if let price = assetUnitPrice, price > 0 {
                amounts[0].amountText = Self.plainString(maxAmount * price, decimals: 2)
            } else {
                entryUnit = .crypto
                amounts[0].amountText = Self.plainString(maxAmount, decimals: effectiveDecimals)
            }
        }
    }

    /// Toggle crypto⇄fiat, converting EVERY recipient's typed value so each
    /// displayed amount represents the same money in the new unit (FIX 1 —
    /// multi-aware). Capturing each row's crypto value BEFORE flipping the
    /// unit is essential: `cryptoAmount(for:)` reads `entryUnit`, so the
    /// conversions must be resolved against the OLD unit first, then written
    /// back as the NEW unit's text. `isMaxSend` is preserved (the raw
    /// writer doesn't clear it).
    func toggleEntryUnit() {
        guard let price = assetUnitPrice, price > 0 else { return }
        // Resolve each row's crypto value under the CURRENT unit first.
        let cryptoValues = amounts.map { cryptoAmount(for: $0) }
        switch entryUnit {
        case .crypto:
            entryUnit = .fiat
            for i in amounts.indices where cryptoValues[i] > 0 {
                let fiat = cryptoValues[i] * price
                amounts[i].amountText = Self.plainString(fiat, decimals: 2)
            }
        case .fiat:
            entryUnit = .crypto
            for i in amounts.indices where cryptoValues[i] > 0 {
                amounts[i].amountText = Self.plainString(cryptoValues[i], decimals: effectiveDecimals)
            }
        }
    }

    /// Plain decimal string (no grouping, trimmed trailing zeros) for
    /// writing a computed value back into the editable field.
    static func plainString(_ value: Decimal, decimals: Int) -> String {
        var v = value
        var rounded = Decimal.zero
        NSDecimalRound(&rounded, &v, decimals, .down)
        // `description` on Decimal is plain (no grouping); trim trailing
        // zeros and a dangling separator.
        var s = rounded.description
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    // MARK: - Draft assembly

    /// Build the validated draft the sign step consumes. Returns nil if
    /// the draft can't be assembled (no fee / failing validation) — the
    /// caller gates on `canReview` first.
    func makeDraft() -> SendDraft? {
        guard let fee = resolvedFee else { return nil }

        // Bitcoin family: use the selected UTXOs, else the planner's
        // auto-selection over the available set.
        let utxosForDraft: [SelectedUTXO]?
        var changeSats: Int64?
        if capability.supportsUTXO {
            utxosForDraft = selectedUTXOs ?? availableUTXOs
            changeSats = nil // computed at sign time from the final plan
        } else {
            utxosForDraft = nil
        }

        let opReturnData: Data? = {
            guard capability.opReturnMaxBytes != nil, hasOpReturn else { return nil }
            return opReturnText.data(using: .utf8)
        }()

        return SendDraft(
            chain: chain,
            tokenSymbol: tokenSymbol,
            tokenContract: tokenContract,
            tokenDecimals: tokenDecimals,
            fromAddress: fromAddress,
            recipients: recipientAmounts,
            fee: fee,
            selectedUTXOs: utxosForDraft,
            changeAddress: nil, // own fresh change addr resolved at sign time
            changeSats: changeSats,
            opReturn: opReturnData,
            signalsRBF: capability.supportsUTXO && chain != .dogecoin && chain != .bitcoinCash,
            memo: memo,
            isMaxSend: isMaxSend,
            recipientNeedsActivation: recipientNeedsActivation,
            tonBounceable: chain == .ton ? false : nil
        )
    }

    // MARK: - Fee fetch (the one owned network read)

    /// Fetch the live fee quote off-main and apply on the main actor. Sets
    /// `feeState`. Honest on failure (no fabricated fee). Re-run when the
    /// amount or recipient count changes materially.
    func loadFee(service: ComposeFeeService = ComposeFeeService()) async {
        feeState = .loading
        let ctx = ComposeFeeService.Context(
            chain: chain, fromAddress: fromAddress,
            toAddress: amounts.first?.address,
            tokenContract: tokenContract, tokenDecimals: tokenDecimals,
            recipientCount: amounts.count
        )
        do {
            let quote = try await service.quote(ctx)
            guard !Task.isCancelled else { return }
            applyFeeQuote(quote)
            feeState = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            Self.log.error("Fee quote failed for \(self.chain.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            feeState = .failed(String(localized: "Couldn't load the network fee"))
        }
    }

    /// Adopt a freshly-fetched (or test-supplied) quote, preserving the
    /// user's chosen tier across refreshes (BUG 1 · fix #1). Extracted from
    /// `loadFee` so the network call and the unit test exercise the SAME
    /// resolution path. The OLD `loadFee` unconditionally pinned `.normal`
    /// whenever the chain had no speed tiers — which silently reverted a
    /// user-picked `.custom` on every debounced refresh for
    /// custom-allowed/single-tier chains (Aptos), so the typed custom fee
    /// never reached `resolvedFee`/`makeDraft`. Now we only change the tier
    /// when the CURRENT one is genuinely invalid for the NEW quote.
    func applyFeeQuote(_ quote: FeeQuote) {
        feeQuote = quote
        selectedTier = resolvedSelectedTier(for: quote)
    }

    /// Decide which tier survives a fee refresh given the NEW quote (BUG 1 ·
    /// fix #1). Keeps the user's choice unless it can't be honored by the new
    /// quote, in which case it degrades to the safest present preset. Never
    /// silently drops a user-picked `.custom` that still has a `customFee`.
    private func resolvedSelectedTier(for quote: FeeQuote) -> FeeTier {
        switch selectedTier {
        case .custom:
            // Honor custom iff the chain allows it and the user actually
            // entered one. Otherwise prefer the present normal preset.
            if quote.isCustomAllowed, customFee != nil { return .custom }
            return quote.tiers[.normal] != nil ? .normal : (quote.tiers.keys.first ?? .normal)
        case .slow, .normal, .fast:
            // Keep the preset if the new quote carries it; else normal.
            if quote.tiers[selectedTier] != nil { return selectedTier }
            return .normal
        }
    }

    /// Fetch the Bitcoin-family UTXO set off-main (advanced "Select coins"
    /// + auto-selection). No-op for non-UTXO chains.
    func loadUTXOs(service: UTXOService = UTXOService()) async {
        guard capability.supportsUTXO else { return }
        isLoadingUTXOs = true
        defer { isLoadingUTXOs = false }
        do {
            let utxos = try await service.fetchUTXOs(address: fromAddress, chain: chain)
            guard !Task.isCancelled else { return }
            availableUTXOs = utxos.sorted { $0.valueSats > $1.valueSats }
        } catch {
            Self.log.error("UTXO fetch failed for \(self.chain.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            // Leave availableUTXOs empty — the menu's "Select coins" sheet
            // shows an honest "couldn't load" state and offers retry.
        }
    }
}
