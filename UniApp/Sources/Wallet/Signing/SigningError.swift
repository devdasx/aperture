import Foundation

/// Typed, honest errors for the sign + broadcast path. Every case maps
/// to a truthful sentence the Send UI can show the user (Rule #16 —
/// never a fabricated success, never a misleading message). `Sendable`
/// so it rides the off-main signing boundary back to the executor.
///
/// **No silent stubs (Rule #5 §F).** `chainNotWired` is the ONE
/// temporary seam this PASS leaves: the 10 non-EVM, non-Bitcoin chains
/// route here with a clearly-typed error until PASS 2 implements them.
/// It is NOT a `fatalError` and NOT a `// TODO` in shipped code — the
/// orchestrator ships only after PASS 2 closes the set, and until then
/// the seam refuses honestly rather than signing garbage.
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

    // MARK: - PASS-2 seam (not shipped on its own — see type doc)

    /// This chain's signer lands in PASS 2. PASS 1 ships the shared core
    /// + the EVM family (12 chains) + the Bitcoin family (4 chains); the
    /// remaining 10 chains route here with their identity named, so the
    /// failure is honest and traceable rather than a crash or a guess.
    case chainNotWired(SupportedChain)

    /// Honest, user-facing English sentence (Rule #9 source). The Send
    /// UI renders this verbatim; nothing here leaks key material.
    var userMessage: String {
        switch self {
        case .noWallet:
            return "No wallet is selected to sign this transaction."
        case .walletCannotSign:
            return "This wallet can't sign — it's watch-only."
        case .secretUnavailable:
            return "Aperture can't sign this transaction on this device yet."
        case .keyAddressMismatch:
            return "The signing key doesn't match this wallet's address. The transaction was not sent."
        case .invalidMnemonic:
            return "This wallet's recovery phrase couldn't be read."
        case .invalidPrivateKey:
            return "This wallet's private key couldn't be read for this network."
        case .unsupportedCoin(let chain):
            return "\(chain.displayName) isn't supported for sending."
        case .malformedDraft(let what):
            return "The transaction is incomplete: \(what)."
        case .signingFailed:
            return "Signing failed. The transaction was not sent."
        case .justInTimeRefreshFailed:
            return "Couldn't reach the network to prepare the transaction. Please try again."
        case .broadcastFailed(let reason):
            return "The network rejected the transaction: \(reason)"
        case .broadcastAmbiguous:
            return "Aperture couldn't confirm whether the transaction went through. Check the explorer before sending again."
        case .chainNotWired(let chain):
            return "Sending on \(chain.displayName) isn't available yet."
        }
    }
}
