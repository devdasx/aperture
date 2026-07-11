import Foundation

/// A precise, user-facing validation error for a draft send. English
/// source messages (Rule #9); the orchestrator's i18n scanner extracts
/// them. The associated values let the UI format amounts.
enum SendValidationError: Error, Hashable, Sendable {
    /// Amount (excluding fee) is zero or negative.
    case amountNotPositive
    /// Native balance can't cover amount + fee.
    case insufficientFunds(needed: Decimal, available: Decimal)
    /// Token send: enough token, but not enough NATIVE coin for gas.
    case insufficientNativeForFee(feeNeeded: Decimal, nativeAvailable: Decimal)
    /// An output is below the chain's dust floor.
    case belowDust(minimum: Decimal)
    /// Send would drop the account below its reserve / ED.
    case belowReserve(reserve: Decimal)
    /// Funding a brand-new account below its activation minimum.
    case belowActivationMinimum(minimum: Decimal)
    /// XRP destination requires a destination tag and none was set.
    case destinationTagRequired
    /// TON comment / Stellar memo required by recipient.
    case memoRequired
    /// Memo exceeds the chain's byte cap.
    case memoTooLong(maxBytes: Int)
    /// Memo is not valid for the chain's typed memo field.
    case memoInvalid
    /// OP_RETURN data note exceeds the chain's byte cap.
    case opReturnTooLong(maxBytes: Int)
    /// No recipients.
    case noRecipients
    /// More recipients than the chain supports in one tx.
    case tooManyRecipients(max: Int)
    /// A recipient with a typed amount can't be funded — the earlier
    /// recipients consume the balance, leaving too little (below the
    /// network minimum) for this one. Blocks Review so a typed amount is
    /// never silently dropped from the broadcast (Rule #16). The model
    /// appends this when a `.blocked` row still holds a positive amount.
    case recipientUnfunded

    /// English catalog key for display. Resolved via
    /// `String.apertureLocalizedKey` so in-app language is honored.
    var message: String {
        let key: String
        switch self {
        case .amountNotPositive:
            key = "Enter an amount greater than zero"
        case .insufficientFunds:
            key = "Not enough balance to cover the amount and fee"
        case .insufficientNativeForFee:
            key = "Not enough balance to cover the network fee"
        case .belowDust:
            key = "Amount is too small to send"
        case .belowReserve:
            key = "This would drop your account below its required reserve"
        case .belowActivationMinimum:
            key = "This new account needs a larger first payment to activate"
        case .destinationTagRequired:
            key = "This recipient requires a destination tag"
        case .memoRequired:
            key = "This recipient requires a memo"
        case .memoTooLong:
            key = "Memo is too long"
        case .memoInvalid:
            key = "Memo is invalid"
        case .opReturnTooLong:
            key = "Data note is too long"
        case .noRecipients:
            key = "Add at least one recipient"
        case .tooManyRecipients:
            key = "Too many recipients for one transaction"
        case .recipientUnfunded:
            key = "A recipient can't be paid with what's left — lower an earlier amount or remove it"
        }
        return String.apertureLocalizedKey(key)
    }
}

/// Validates a draft against amounts + fee + balances + reserves and
/// returns ALL precise errors (so the UI can show every problem at once).
/// Pure value logic (Sendable, off-main friendly).
struct SendDraftValidator: Sendable {

    /// Validation inputs the UI/coordinator supplies.
    struct Inputs: Sendable {
        let chain: SupportedChain
        let isToken: Bool
        let nativeBalance: Decimal
        let tokenBalance: Decimal?
        let recipients: [SendRecipientAmount]
        let fee: FeeChoice
        let state: SendAmountMath.AccountState
        let memo: SendMemoValue
        /// UTF-8 byte count of the optional OP_RETURN data note (Bitcoin
        /// family), or `nil` when no data note is attached / unsupported.
        /// Checked against the chain's `opReturnMaxBytes` cap.
        let opReturnByteCount: Int?
        /// Whether the recipient's account flag requires a destination
        /// tag (XRP `requireDestinationTag`) — pre-checked by the caller.
        let recipientRequiresDestinationTag: Bool
        /// Whether the recipient requires a memo (Stellar SEP-29 / known
        /// CEX) — pre-checked by the caller.
        let recipientRequiresMemo: Bool
        /// Whether the recipient account is brand-new (activation rules).
        let recipientIsNew: Bool
    }

    func validate(_ inputs: Inputs) -> [SendValidationError] {
        var errors: [SendValidationError] = []
        let cap = ChainComposeCapability.capability(for: inputs.chain)

        // Recipients.
        if inputs.recipients.isEmpty {
            errors.append(.noRecipients)
            return errors
        }
        if inputs.recipients.count > cap.maxRecipients {
            errors.append(.tooManyRecipients(max: cap.maxRecipients))
        }

        let total = inputs.recipients.reduce(Decimal.zero) { $0 + $1.amount }
        if total <= 0 {
            errors.append(.amountNotPositive)
        }

        // Dust (per output, only where the chain has a dust floor).
        let dust = SendAmountMath.dustMinimum(chain: inputs.chain)
        if dust > 0 {
            for r in inputs.recipients where r.amount > 0 && r.amount < dust {
                errors.append(.belowDust(minimum: dust))
                break
            }
        }

        // Activation minimum for a brand-new account.
        if inputs.recipientIsNew {
            let actMin = SendAmountMath.activationMinimum(chain: inputs.chain)
            if actMin > 0, let first = inputs.recipients.first, first.amount < actMin {
                errors.append(.belowActivationMinimum(minimum: actMin))
            }
        }

        // Funds + reserve. `estimatedTotalNative` is for DISPLAY only; the
        // can-I-afford decision always reserves the WORST-CASE fee so an
        // EIP-1559 base-fee rise between quote and sign (worst ≈ 2–2.5×
        // the estimate) can't strand the tx after signing lands.
        let worstFee = inputs.fee.worstCaseTotalNative
        if inputs.isToken {
            // Token amount must fit the token balance.
            let tokenBal = inputs.tokenBalance ?? 0
            if total > tokenBal {
                errors.append(.insufficientFunds(needed: total, available: tokenBal))
            }
            // Native must cover the WORST-CASE fee (not the optimistic
            // estimate) — otherwise a user between the two passes here but
            // can't pay gas once the real maxFee applies at sign time.
            if inputs.nativeBalance < worstFee {
                errors.append(.insufficientNativeForFee(feeNeeded: worstFee, nativeAvailable: inputs.nativeBalance))
            }
        } else {
            let reserve = SendAmountMath.standingReserve(rule: cap.reserve, state: inputs.state)
            var activation: Decimal = 0
            if inputs.recipientIsNew, case .tronActivation(let surcharge) = cap.reserve {
                activation = surcharge
            }
            let needed = total + worstFee + activation + reserve
            if needed > inputs.nativeBalance {
                let available = max(inputs.nativeBalance - reserve, 0)
                if reserve > 0 && (total + worstFee + activation) > available {
                    errors.append(.belowReserve(reserve: reserve))
                } else {
                    errors.append(.insufficientFunds(needed: total + worstFee + activation, available: available))
                }
            }
        }

        // Destination tag / memo requirements.
        if cap.memoKind == .destinationTag, inputs.recipientRequiresDestinationTag {
            if case .destinationTag = inputs.memo {} else {
                errors.append(.destinationTagRequired)
            }
        }
        if inputs.recipientRequiresMemo, !memoIsPresent(inputs.memo) {
            errors.append(.memoRequired)
        }

        // Memo length.
        if let maxBytes = cap.memoMaxBytes, let bytes = memoByteLength(inputs.memo), bytes > maxBytes {
            errors.append(.memoTooLong(maxBytes: maxBytes))
        }
        if !memoHasValidTypedShape(inputs.memo) {
            errors.append(.memoInvalid)
        }

        // OP_RETURN data-note length (Bitcoin family). Over the chain's
        // datacarrier cap → the output is non-standard and won't relay.
        if let maxBytes = cap.opReturnMaxBytes, let bytes = inputs.opReturnByteCount, bytes > maxBytes {
            errors.append(.opReturnTooLong(maxBytes: maxBytes))
        }

        return errors
    }

    private func memoIsPresent(_ memo: SendMemoValue) -> Bool {
        switch memo {
        case .none: return false
        case .destinationTag: return true
        case .tonComment(let s), .splMemo(let s), .text(let s):
            return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .stellarMemo(let m):
            switch m {
            case .text(let s): return !s.isEmpty
            case .id: return true
            case .hashHex(let h): return !h.isEmpty
            }
        }
    }

    private func memoByteLength(_ memo: SendMemoValue) -> Int? {
        switch memo {
        case .none, .destinationTag:
            return nil
        case .tonComment(let s), .splMemo(let s), .text(let s):
            return s.utf8.count
        case .stellarMemo(let m):
            if case .text(let s) = m { return s.utf8.count }
            return nil
        }
    }

    private func memoHasValidTypedShape(_ memo: SendMemoValue) -> Bool {
        switch memo {
        case .stellarMemo(.hashHex(let hex)):
            let normalized = hex.lowercased().hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
            return normalized.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil
        default:
            return true
        }
    }
}
