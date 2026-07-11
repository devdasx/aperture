import Foundation

/// One recipient + amount in a draft send. `amount` is in the asset's
/// DISPLAY units as `Decimal` (e.g. 1.5 BTC, 100 USDT) — the signer
/// converts to base units via the asset's decimals. `name` is the
/// ENS/SNS/etc. name the address resolved from (nil when typed).
struct SendRecipientAmount: Codable, Hashable, Sendable, Identifiable {
    let address: String
    let amount: Decimal
    let name: String?
    var id: String { address }
}

/// A selected UTXO for a Bitcoin-family send. Carries everything
/// wallet-core's `BitcoinUnspentTransaction` needs at sign time: the
/// outpoint (txid + vout), the value in sats, and the locking script
/// (hex) when the provider returns it inline (Haskoin/BlockCypher) so no
/// extra script fetch is needed.
struct SelectedUTXO: Codable, Hashable, Sendable, Identifiable {
    /// Own address that controls this output. Required when a wallet has
    /// spendable coins across multiple receive/change paths.
    let ownerAddress: String?
    /// Transaction id (big-endian hex as the provider returns it).
    let txid: String
    /// Output index (vout).
    let vout: Int
    /// Value in satoshis/litoshi/koinu (integer).
    let valueSats: Int64
    /// Locking script (pkscript) hex, when provided inline. `nil` means
    /// the signer must derive it from the address (own address).
    let scriptHex: String?
    /// Whether the UTXO is confirmed. Confirmed inputs are preferred, but
    /// unconfirmed inputs remain valid spend candidates when they are still
    /// in the current UTXO set.
    let confirmed: Bool
    var id: String { "\(txid):\(vout)" }

    init(
        ownerAddress: String? = nil,
        txid: String,
        vout: Int,
        valueSats: Int64,
        scriptHex: String?,
        confirmed: Bool
    ) {
        self.ownerAddress = ownerAddress
        self.txid = txid
        self.vout = vout
        self.valueSats = valueSats
        self.scriptHex = scriptHex
        self.confirmed = confirmed
    }

    static func spendPrioritySorted(_ utxos: [SelectedUTXO]) -> [SelectedUTXO] {
        utxos.sorted { lhs, rhs in
            if lhs.confirmed != rhs.confirmed { return lhs.confirmed && !rhs.confirmed }
            if lhs.valueSats != rhs.valueSats { return lhs.valueSats > rhs.valueSats }
            return lhs.id < rhs.id
        }
    }
}

/// The kind of memo/tag value carried in a draft (matches `ComposeMemoKind`
/// but holds the concrete value). Codable so it rides into the draft.
enum SendMemoValue: Codable, Hashable, Sendable {
    case none
    /// XRP destination tag (uint32).
    case destinationTag(UInt32)
    /// TON text comment.
    case tonComment(String)
    /// Solana SPL memo.
    case splMemo(String)
    /// TRON memo / NEAR FT memo — free text.
    case text(String)
    /// Stellar memo with its type.
    case stellarMemo(StellarMemo)

    enum StellarMemo: Codable, Hashable, Sendable {
        case text(String)        // ≤28 bytes
        case id(UInt64)
        case hashHex(String)     // 32 bytes / 64 hex
    }
}

/// Auto-classifies Stellar memo input when the sender was only given a value.
/// Stellar itself still needs a typed memo in the signed transaction.
enum StellarMemoInference: Equatable, Sendable {
    case empty
    case text(String)
    case id(UInt64)
    case hashHex(String)
    case invalidID
    case invalidHash

    static func infer(_ raw: String) -> StellarMemoInference {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        let hasHexPrefix = trimmed.lowercased().hasPrefix("0x")
        let normalizedHex = hasHexPrefix ? String(trimmed.dropFirst(2)) : trimmed
        let isHex = normalizedHex.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil
        if hasHexPrefix {
            return normalizedHex.count == 64 && isHex ? .hashHex(normalizedHex) : .invalidHash
        }
        if normalizedHex.count == 64 && isHex {
            return .hashHex(normalizedHex)
        }

        let isDigits = trimmed.range(of: "^[0-9]+$", options: .regularExpression) != nil
        if isDigits {
            guard let id = UInt64(trimmed) else { return .invalidID }
            return .id(id)
        }

        return .text(trimmed)
    }

    var memo: SendMemoValue.StellarMemo? {
        switch self {
        case .empty, .invalidID, .invalidHash:
            return nil
        case .text(let text):
            return .text(text)
        case .id(let id):
            return .id(id)
        case .hashHex(let hash):
            return .hashHex(hash)
        }
    }

    var displayName: String? {
        switch self {
        case .empty:
            return nil
        case .text:
            return "Text"
        case .id, .invalidID:
            return "ID"
        case .hashHex, .invalidHash:
            return "Hash"
        }
    }

    var isTextLike: Bool {
        switch self {
        case .empty, .text:
            return true
        default:
            return false
        }
    }

    var validationError: String? {
        switch self {
        case .text(let text) where text.utf8.count > 28:
            return "Memo text must be 28 bytes or less."
        case .invalidID:
            return "Memo ID must be a whole number from 0 to 18,446,744,073,709,551,615."
        case .invalidHash:
            return "Memo hash must be exactly 32 bytes, written as 64 hex characters."
        default:
            return nil
        }
    }
}

/// The complete, validated output of the compose screen — everything the
/// FUTURE sign step needs to build, sign, and broadcast the transaction.
/// Nothing the signer needs is missing (per the brief). Codable +
/// Hashable + Sendable so it rides the NavigationPath into the sign step
/// and persists to the outbox (Rule #27).
///
/// NOTE: this is the *intent*; chain-specific just-in-time data (fresh
/// nonce/sequence/blockhash/UTXO set/gas-price) is re-fetched immediately
/// before signing (Rule #27 §C). The draft carries the values known at
/// compose time plus the fields needed to re-fetch the volatile ones.
struct SendDraft: Codable, Hashable, Sendable {

    // MARK: - Identity

    let chain: SupportedChain
    /// Token symbol when sending a token (USDT, USDC, …); `nil` for a
    /// native-coin send.
    let tokenSymbol: String?
    /// Token contract / mint / asset-id / jetton-master / denom when
    /// sending a token; `nil` for native. The signer routes on this.
    let tokenContract: String?
    /// The token's decimals when sending a token; `nil` for native (use
    /// `chain.nativeDecimals`).
    let tokenDecimals: Int?

    /// The sender's address (from the active wallet).
    let fromAddress: String

    /// One or more recipients (multi where the chain supports it).
    let recipients: [SendRecipientAmount]

    // MARK: - Fee

    /// The chosen, fully-resolved fee.
    let fee: FeeChoice

    // MARK: - Bitcoin family

    /// Selected inputs for a UTXO send (the planner's choice). `nil` for
    /// account-model chains.
    let selectedUTXOs: [SelectedUTXO]?
    /// The change address (own fresh address) for a UTXO send.
    let changeAddress: String?
    /// Computed change amount in sats for a UTXO send (sub-dust folds to
    /// fee, so this is post-dust).
    let changeSats: Int64?
    /// OP_RETURN data payload (Bitcoin family advanced).
    let opReturn: Data?
    /// Whether the UTXO send signals RBF (BIP-125 opt-in).
    let signalsRBF: Bool

    // MARK: - Memo / tag

    /// The memo/tag/comment value (typed per chain).
    let memo: SendMemoValue

    // MARK: - Flags / per-chain extras the signer needs

    /// Whether this is a send-all / "Max" send (so the signer uses the
    /// chain's max-send primitive: use_max_amount / PayAllSui /
    /// transferAll / send-mode 128 / etc.).
    let isMaxSend: Bool

    /// Whether sending to a brand-new/unactivated recipient (XRP/TRON/
    /// Stellar create-account / Solana ATA creation / NEAR implicit).
    /// Drives the activation surcharge + the create-vs-pay branch.
    let recipientNeedsActivation: Bool

    /// TON: resolved bounceable flag for the recipient (default false
    /// for user wallets so funds aren't lost to an uninitialized dest).
    let tonBounceable: Bool?

    /// Convenience: total amount across recipients in display units.
    var totalAmount: Decimal {
        recipients.reduce(Decimal.zero) { $0 + $1.amount }
    }

    /// Whether this draft sends a token (vs the native coin).
    var isTokenSend: Bool { tokenContract != nil }

    /// The decimals to use for amount → base-unit conversion.
    var effectiveDecimals: Int { tokenDecimals ?? chain.nativeDecimals }

    /// Copy with a different `fromAddress` (BUG-002 post-migration send path).
    func replacingFromAddress(_ newFrom: String) -> SendDraft {
        SendDraft(
            chain: chain,
            tokenSymbol: tokenSymbol,
            tokenContract: tokenContract,
            tokenDecimals: tokenDecimals,
            fromAddress: newFrom,
            recipients: recipients,
            fee: fee,
            selectedUTXOs: selectedUTXOs,
            changeAddress: changeAddress,
            changeSats: changeSats,
            opReturn: opReturn,
            signalsRBF: signalsRBF,
            memo: memo,
            isMaxSend: isMaxSend,
            recipientNeedsActivation: recipientNeedsActivation,
            tonBounceable: tonBounceable
        )
    }
}
