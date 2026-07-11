import Foundation
import WalletCore

/// Shared recipient validation for every chain signer.
///
/// **BUG-001 contract:** a draft either pays **every** listed recipient in
/// one transaction, or signing refuses honestly. Signers must never take
/// only `recipients.first` when `count > 1`.
///
/// **P3-018 / product rule:** **Max** (send-all) cannot be combined with
/// multi-recipient. Max uses chain-specific "drain remaining after fee"
/// primitives that assume a single destination; multi needs explicit
/// per-recipient amounts. The UI should disable Max when N>1; signing
/// refuses with `malformedDraft("send-max cannot be combined…")` if a
/// crafted draft still arrives.
enum SendRecipientSigning {

    /// Validated, ordered recipients ready for signing.
    /// - Ensures non-empty, within `ChainSendCapability.maxRecipients`,
    ///   positive amounts, and (when a WalletCore coin exists) address shape.
    static func requireRecipients(
        _ draft: SendDraft,
        coin: CoinType? = nil
    ) throws -> [SendRecipientAmount] {
        let max = ChainSendCapability.maxRecipients(for: draft.chain)
        let list = draft.recipients
        guard !list.isEmpty else {
            throw SigningError.malformedDraft("no recipient")
        }
        guard list.count <= max else {
            throw SigningError.malformedDraft(
                "too many recipients for \(draft.chain.displayName) (max \(max))"
            )
        }
        if max == 1, list.count > 1 {
            throw SigningError.malformedDraft(
                "\(draft.chain.displayName) supports only one recipient per transaction"
            )
        }
        if draft.isMaxSend, list.count > 1 {
            throw SigningError.malformedDraft(
                "send-max cannot be combined with multiple recipients"
            )
        }
        for r in list {
            let address = r.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else {
                throw SigningError.malformedDraft("empty recipient address")
            }
            guard r.amount > 0 else {
                throw SigningError.malformedDraft("recipient amount must be positive")
            }
            if let coin, !coin.validate(address: address) {
                throw SigningError.malformedDraft(
                    "invalid \(draft.chain.displayName) recipient address"
                )
            }
        }
        return list
    }

    /// Single-recipient chains (and single-recipient code paths).
    static func requireSingleRecipient(
        _ draft: SendDraft,
        coin: CoinType? = nil
    ) throws -> SendRecipientAmount {
        let list = try requireRecipients(draft, coin: coin)
        guard list.count == 1, let only = list.first else {
            throw SigningError.malformedDraft(
                "\(draft.chain.displayName) supports only one recipient per transaction"
            )
        }
        return only
    }
}
