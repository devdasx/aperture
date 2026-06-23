import Foundation

// MARK: - TransactionKind

/// Persisted transaction taxonomy — *what the transaction was*, as
/// opposed to `TransactionDirection` (*which way value moved relative
/// to the user's address*). Stored on `TransactionRecord.kindRaw`
/// (optional `String`, additive column — pre-taxonomy rows decode
/// `nil` and resolve through `defaultKind(for:)`).
///
/// A self-transfer is one `.internal` leg with `kind == .selfTransfer`;
/// everything else is a plain `.transfer`.
///
/// `failed` is NOT a kind — it stays on `TransactionStatus`. Repository
/// filters compose the axes: sending = `direction == .outgoing`,
/// receiving = `direction == .incoming`, failed = `status == .failed`,
/// self = `kind == .selfTransfer`.
///
/// 2026-06-23 — the router-allowlist classifier (which upgraded transfers to
/// `.swap` / `.bridge`) was removed with the swap feature, so no leg is
/// produced with those kinds anymore. `.bridge` is kept only so stored rows
/// written before the removal still decode.
enum TransactionKind: String, Codable, CaseIterable, Sendable {
    /// Plain value transfer (send / receive). The default for every
    /// non-`.internal` leg until an adapter classifies otherwise.
    case transfer
    /// Value moved across chains through a bridge contract. Dormant since
    /// 2026-06-23 (kept for stored-row decoding only).
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
