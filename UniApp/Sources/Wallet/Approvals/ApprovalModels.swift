import Foundation

/// Value types for the "Token approvals" surface in Connection &
/// Approvals. Approvals are scanned ON-DEMAND into these plain structs —
/// there is deliberately NO SwiftData `@Model` here, so no schema
/// migration is taken and nothing approval-shaped is persisted. The
/// screen re-scans the chain on every `.task`; the chain is the source
/// of truth (Rule #16 — never a cached/fabricated allowance).
///
/// **What a `TokenApproval` is.** One non-zero ERC-20 allowance the
/// active wallet has granted: the live `allowance(owner, spender)`
/// returned by `eth_call`, read for a `(token, spender)` pair the
/// scanner discovered from on-chain `Approval` logs. Only allowances
/// strictly greater than zero are surfaced.

/// A single non-zero ERC-20 approval the active wallet has granted to a
/// spender on one EVM chain. Built entirely from on-chain reads —
/// `allowanceRaw` is the raw 32-byte word `eth_call` returned for
/// `allowance(owner, spender)` (compared as big-endian bytes, never as
/// `Decimal`, because u256 overflows `Decimal`).
struct TokenApproval: Identifiable, Sendable, Hashable {

    /// Stable identity for `ForEach` — the `(chain, token, spender)`
    /// triple uniquely identifies an allowance row.
    var id: String { "\(chain.rawValue):\(tokenContract.lowercased()):\(spender.lowercased())" }

    /// Display ticker for the token, when known (registry or the user's
    /// custom tokens). Falls back to a shortened contract address when
    /// the token isn't in the registry — never a fabricated name.
    let tokenSymbol: String

    /// The ERC-20 contract the allowance is set on (the `to` of the
    /// `eth_call` / the `approve` tx). EIP-55 case is display-only.
    let tokenContract: String

    /// The spender the allowance was granted to — shown as its
    /// checksummed/short address (Rule #16 — never an invented label).
    let spender: String

    /// Raw `allowance(owner, spender)` result — the `0x`-prefixed
    /// 32-byte hex word straight from `eth_call`. Kept raw so the UI can
    /// render it honestly and `isUnlimited` can compare it without a
    /// lossy `Decimal` round-trip.
    let allowanceRaw: String

    /// Token decimals (registry / custom metadata; defaults to 18 — the
    /// EVM standard — when unknown). Used only for a human-readable
    /// formatted allowance; the raw word stays authoritative.
    let decimals: Int

    /// The EVM chain this allowance lives on.
    let chain: SupportedChain

    /// `true` when the allowance equals (or rounds to) the uint256 max —
    /// the "unlimited" approval every major aggregator wallet sets. The
    /// scanner computes this once from the raw word so the UI doesn't
    /// re-parse.
    let isUnlimited: Bool
}

/// The lifecycle of a single approval row's REVOKE action, owned per-row
/// by the screen. Mirrors the small state machine the Send sheet
/// uses so the row can show idle → in-progress → honest success/failure
/// (Rule #16 — a failure names what we couldn't do; a success carries the
/// real tx hash, never a fabricated one).
enum RevocationState: Sendable, Equatable {
    /// No revoke in flight — the default Revoke affordance is shown.
    case idle
    /// The revoke tx is being signed + broadcast (biometric already
    /// passed). The row shows a spinner and disables the button.
    case revoking
    /// The revoke tx broadcast successfully — carries the REAL on-chain
    /// tx hash returned by the node (never invented).
    case revoked(txHash: String)
    /// The revoke failed (custody refusal, sign error, node rejection,
    /// or an ambiguous broadcast). Carries the honest, user-facing
    /// reason for inline display.
    case failed(reason: String)
}

/// The scan's own load state, owned by the screen, so the Approvals
/// section can show scanning / empty / error / loaded honestly rather
/// than a blank list that could be read as "no approvals" during a
/// transient failure.
enum ApprovalScanState: Sendable, Equatable {
    /// Not yet started / between scans.
    case idle
    /// A scan is running.
    case scanning
    /// Scan finished — the associated array may be empty (genuinely no
    /// non-zero approvals across the wallet's EVM chains).
    case loaded([TokenApproval])
    /// The scan failed before completing — honest error state. The
    /// associated string names what we couldn't do.
    case failed(reason: String)
}
