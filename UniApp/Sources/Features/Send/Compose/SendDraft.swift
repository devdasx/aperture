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
    /// Transaction id (big-endian hex as the provider returns it).
    let txid: String
    /// Output index (vout).
    let vout: Int
    /// Value in satoshis/litoshi/koinu (integer).
    let valueSats: Int64
    /// Locking script (pkscript) hex, when provided inline. `nil` means
    /// the signer must derive it from the address (own address).
    let scriptHex: String?
    /// Whether the UTXO is confirmed (prefer confirmed inputs).
    let confirmed: Bool
    var id: String { "\(txid):\(vout)" }
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
    /// Cosmos memo / TRON memo / NEAR FT memo — free text.
    case text(String)
    /// Stellar memo with its type.
    case stellarMemo(StellarMemo)

    enum StellarMemo: Codable, Hashable, Sendable {
        case text(String)        // ≤28 bytes
        case id(UInt64)
        case hashHex(String)     // 32 bytes / 64 hex
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
}
