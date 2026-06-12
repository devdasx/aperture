import Foundation

/// Validates user-pasted contract addresses for the Add Custom Token
/// flow. The two families differ enough that one function each is
/// honest — EVM uses 20-byte hex with the optional EIP-55 mixed-case
/// checksum, Solana uses 32-byte base58 with no checksum.
///
/// **Honesty (Rule #16 §A.7).** Validation here ONLY checks the
/// shape of the address — it does not verify the contract exists on
/// chain, is a real token, or isn't malicious. Existence verification
/// is the next step in the Add sheet (the metadata fetch). Trust is
/// the user's responsibility per Rule #16; this validator just
/// catches typos before we waste a round-trip.
///
/// **EIP-55 (Rule #3 native-only).** Implemented inline using the
/// shared Keccak-256 helper in `Keccak256.swift`. Trust Wallet's
/// `assets/<contract>` directory expects checksummed form; the same
/// digest is used here, so a contract that fails our checksum will
/// also fail their URL — a single source of normalization.
enum ContractValidator {

    /// Validate an EVM contract address.
    ///
    /// - Strip whitespace.
    /// - Require `0x` prefix + 40 hex chars.
    /// - Hex alphabet only.
    /// - Always normalize the output via EIP-55 — the case the user
    ///   pasted does not gate acceptance.
    ///
    /// **2026-06-09 — relaxed from strict EIP-55 reject.** The
    /// original behavior rejected any mixed-case input whose case
    /// didn't match the keccak256 checksum. That's spec-correct but
    /// hostile UX: most addresses in the wild come from sources that
    /// don't checksum (Etherscan API JSON, GitHub READMEs, Discord
    /// snippets, the address bar of half the block explorers).
    /// Trust Wallet, MetaMask, Rabby, Phantom all accept any-case
    /// hex and silently normalize. We do the same. The user's
    /// `0xBc65ad17c5C0a2A4D159fa5a503f4992c7B545FE` is a perfectly
    /// good 40-char hex string; the next step (on-chain metadata
    /// fetch via `eth_call`) is the real verification — if the
    /// contract doesn't exist at this address, `name()`/`symbol()`/
    /// `decimals()` will fail and the sheet surfaces that honestly.
    ///
    /// **Honesty kept (Rule #16).** We still check shape strictly
    /// (length, hex alphabet, prefix). We do NOT lie about what we
    /// don't audit — the safety copy below the form already says
    /// "Aperture reads what the contract says about itself."
    static func validateEVM(_ input: String) -> ValidationResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid(.empty) }
        guard trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") else {
            return .invalid(.wrongLength)
        }
        guard trimmed.count == 42 else {
            return .invalid(.wrongLength)
        }
        let body = String(trimmed.dropFirst(2))
        let hexAlphabet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        if body.unicodeScalars.contains(where: { !hexAlphabet.contains($0) }) {
            return .invalid(.invalidCharacter)
        }
        // Always emit the EIP-55 form so downstream paths (Trust
        // Wallet asset URL, dedup key, persisted contract column)
        // are case-stable regardless of how the user typed it.
        let checksummed = Keccak256.eip55Checksum(contract: body)
        return .valid(normalized: checksummed)
    }

    /// Validate a Solana SPL mint address.
    ///
    /// - Strip whitespace.
    /// - Base58 decode → exactly 32 bytes.
    /// - Returns the original (case-sensitive) base58 string as the
    ///   normalized output; Solana addresses are not normalized in
    ///   any other way.
    static func validateSolanaMint(_ input: String) -> ValidationResult {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalid(.empty) }
        // Base58 character set is `[1-9A-HJ-NP-Za-km-z]` — quick
        // sanity check before invoking the decoder so a stray "0" or
        // "O" returns the more-specific `invalidCharacter` rather
        // than the catch-all `notBase58`.
        let allowed = CharacterSet(charactersIn: "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return .invalid(.invalidCharacter)
        }
        guard let bytes = Base58.decodeBytes(trimmed) else {
            return .invalid(.notBase58)
        }
        guard bytes.count == 32 else {
            return .invalid(.wrongLength)
        }
        return .valid(normalized: trimmed)
    }
}

/// Result of a `ContractValidator` call. `.valid` carries the
/// normalized form the caller should persist (EIP-55 for EVM, verbatim
/// for Solana); `.invalid` carries a specific reason the Add sheet
/// surfaces as honest copy ("Not a valid EVM address — must be 42 hex
/// chars" rather than "Invalid token!").
enum ValidationResult: Sendable, Equatable {
    case valid(normalized: String)
    case invalid(ValidationError)
}

/// Specific reason a contract address didn't validate. Each case maps
/// to a localized error string in the Add Custom Token sheet so the
/// user can fix the typo.
enum ValidationError: Sendable, Equatable {
    case empty
    case wrongLength
    case invalidCharacter
    case invalidChecksum
    case notBase58
}
