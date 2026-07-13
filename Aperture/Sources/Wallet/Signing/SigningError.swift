import Foundation

/// Typed, honest errors for the sign + broadcast path. Every case maps
/// to a truthful sentence the Send UI can show the user (Rule #16 —
/// never a fabricated success, never a misleading message). `Sendable`
/// so it rides the off-main signing boundary back to the executor.
///
/// **M-006 / P3-008:** Every currently supported chain has a signer.
/// `chainNotWired` is a defensive residual only (misroute / retired
/// chain) — not a “PASS-2 still building” main seam.
enum SigningError: Error, Sendable, Equatable {

    // MARK: - Custody boundaries (honest refusals)

    /// No active/selected wallet to sign with.
    case noWallet

    /// The wallet cannot sign — watch-only (no secret on device) or a
    /// kind that doesn't own the key for this chain's family.
    case walletCannotSign

    /// The wallet's mnemonic is no longer on device (the user completed
    /// backup, so `MnemonicVault` deleted the local copy), or a
    /// passphrase-protected wallet whose passphrase was never persisted
    /// (BIP-39 spec; see `WalletRecord.hasPassphrase`). Deriving with an
    /// empty passphrase would sign with the WRONG key, so we refuse
    /// rather than sign-to-a-wrong-address. The UI's passphrase prompt
    /// (T-019) supplies it; until then this is the honest result.
    case secretUnavailable

    /// Key↔address parity failed: the key derived from the on-device
    /// secret does not produce the wallet's persisted `fromAddress` for
    /// this chain. A guard against signing with the wrong derivation —
    /// never sign a transaction the funds can't be recovered from.
    case keyAddressMismatch(expected: String, derived: String)

    // MARK: - Build / sign failures

    /// `HDWallet(mnemonic:passphrase:)` returned nil — the stored
    /// mnemonic failed BIP-39 validation (corrupted vault entry).
    case invalidMnemonic

    /// The imported single-private-key bytes couldn't be decoded for
    /// this chain (wrong format / wrong network / unsupported encoding).
    case invalidPrivateKey

    /// `CoinType` resolution failed for the chain (not in the registry
    /// map). Defensive — every supported chain has a coin id.
    case unsupportedCoin(SupportedChain)

    /// The draft is missing a value the signer needs (recipient, amount,
    /// UTXO set, change address, contract for a token send, …). The
    /// associated string names the missing field for the log/UI.
    case malformedDraft(String)

    /// wallet-core's `AnySigner` returned an empty / errored output. The
    /// associated string carries the chain + the wallet-core error
    /// reason where available (never key material).
    case signingFailed(String)

    // MARK: - Just-in-time refresh failures

    /// A volatile pre-sign value (nonce, gas price, fee-rate, UTXO set,
    /// blockhash, sequence) couldn't be refreshed before building the
    /// SigningInput. We never sign against a stale value (Rule #27 §C);
    /// the associated string names what failed.
    case justInTimeRefreshFailed(String)

    // MARK: - Broadcast failures

    /// The node DEFINITIVELY REJECTED the signed transaction (a structured
    /// rejection: decode/validation error, HTTP 4xx, error codes) — it
    /// never entered the network, so the funds did NOT move. The associated
    /// string carries the provider's reason (e.g. "min relay fee not met",
    /// "nonce too low", "insufficient funds for gas").
    case broadcastFailed(String)

    /// The broadcast outcome is UNKNOWN — the request left the device but
    /// no definitive accept/reject came back (timeout, dropped connection,
    /// or an unparseable response). The transaction MAY or may not have
    /// relayed, so the UI must NOT claim the funds are safe; it tells the
    /// user to check the explorer before sending again (Rule #16 honesty).
    case broadcastAmbiguous(String)

    // MARK: - Defensive residual (M-006)

    /// No signer for this chain in this build (should be unreachable for
    /// the live SupportedChain set). Kept so a misrouted draft refuses
    /// honestly rather than signing garbage — not an active “coming soon”
    /// product path.
    case chainNotWired(SupportedChain)

    /// Honest, user-facing sentence (Rule #9 source). Honors the in-app
    /// language via `String.apertureLocalized`. Nothing here leaks key material.
    var userMessage: String {
        switch self {
        case .noWallet:
            return String.apertureLocalized("No wallet is selected to sign this transaction.")
        case .walletCannotSign:
            return String.apertureLocalized("This wallet can't sign — it's watch-only.")
        case .secretUnavailable:
            return String.apertureLocalized("Aperture can't sign this transaction on this device yet.")
        case .keyAddressMismatch:
            return String.apertureLocalized("The signing key doesn't match this wallet's address. The transaction was not sent.")
        case .invalidMnemonic:
            return String.apertureLocalized("This wallet's recovery phrase couldn't be read.")
        case .invalidPrivateKey:
            return String.apertureLocalized("This wallet's private key couldn't be read for this network.")
        case .unsupportedCoin(let chain):
            return String(format: String.apertureLocalized("%@ isn't supported for sending."), chain.displayName)
        case .malformedDraft(let what):
            return String(format: String.apertureLocalized("The transaction is incomplete: %@."), what)
        case .signingFailed:
            return String.apertureLocalized("Signing failed. The transaction was not sent.")
        case .justInTimeRefreshFailed:
            return String.apertureLocalized("Couldn't reach the network to prepare the transaction. Please try again.")
        case .broadcastFailed(let reason):
            return String(format: String.apertureLocalized("The network rejected the transaction: %@"), reason)
        case .broadcastAmbiguous:
            return String.apertureLocalized("Aperture couldn't confirm whether the transaction went through. Check the explorer before sending again.")
        case .chainNotWired(let chain):
            return String(format: String.apertureLocalized("Sending on %@ isn't available yet."), chain.displayName)
        }
    }
}
