import Foundation

// MARK: - TransactionKind

/// Persisted transaction taxonomy — *what the transaction was*, as
/// opposed to `TransactionDirection` (*which way value moved relative
/// to the user's address*). Stored on `TransactionRecord.kindRaw`
/// (optional `String`, additive column — pre-taxonomy rows decode
/// `nil` and resolve through `defaultKind(for:)`).
///
/// The two axes compose: a swap routinely persists as TWO ledger legs
/// (an `.outgoing` leg in one asset and an `.incoming` leg in
/// another, both `kind == .swap` under the same `txHash`); a
/// self-transfer is one `.internal` leg with `kind == .selfTransfer`.
///
/// `failed` is NOT a kind — it stays on `TransactionStatus` (a swap
/// can fail; a transfer can fail). Repository filters compose the
/// three axes: sending = `direction == .outgoing`, receiving =
/// `direction == .incoming`, failed = `status == .failed`,
/// swap / bridge / self = `kind`.
// TODO: (T-067) Swap / bridge classification — the chain adapters emit only direction today, so every non-self transfer persists as `.transfer` until router/bridge contract recognition lands. See TODO.md.
enum TransactionKind: String, Codable, CaseIterable, Sendable {
    /// Plain value transfer (send / receive). The default for every
    /// non-`.internal` leg until an adapter classifies otherwise.
    case transfer
    /// Asset exchange through a DEX router / aggregator on one chain.
    case swap
    /// Value moved across chains through a bridge contract.
    case bridge
    /// Value moved between the user's own addresses (the adapters'
    /// `.internal` direction — every owned input AND output).
    case selfTransfer

    /// The kind a leg gets when the writer didn't classify it: the
    /// adapters already detect self-sends as `direction == .internal`,
    /// so that direction maps to `.selfTransfer`; everything else is a
    /// plain `.transfer`.
    static func defaultKind(for direction: TransactionDirection) -> TransactionKind {
        direction == .internal ? .selfTransfer : .transfer
    }

    /// Resolve a persisted `(kindRaw, directionRaw)` pair to the
    /// effective kind. Handles both legacy rows (`kindRaw == nil` —
    /// written before the taxonomy column existed) and rows holding
    /// an unknown future raw value (decoded conservatively via the
    /// direction-derived default, never crashing on stored data).
    static func effectiveKind(kindRaw: String?, directionRaw: String) -> TransactionKind {
        if let kindRaw, let decoded = TransactionKind(rawValue: kindRaw) {
            return decoded
        }
        let direction = TransactionDirection(rawValue: directionRaw) ?? .incoming
        return defaultKind(for: direction)
    }
}

// MARK: - TransactionRecord taxonomy surface

extension TransactionRecord {
    /// Effective kind of this leg — decodes `kindRaw`, falling back to
    /// the direction-derived default for legacy / unknown raws. Read
    /// this, never `kindRaw` directly, outside the repository.
    var kind: TransactionKind {
        TransactionKind.effectiveKind(kindRaw: kindRaw, directionRaw: directionRaw)
    }
}
