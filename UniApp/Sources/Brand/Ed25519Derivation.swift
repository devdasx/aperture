import Foundation
import CryptoKit

/// Real per-chain address derivation for ed25519 chains where the
/// address-encoding primitive is in CryptoKit. Each function takes a
/// 64-byte BIP-39 seed and returns the chain's canonical first
/// address.
///
/// **Coverage matrix (today, v1).**
///
/// | Chain   | Path                  | Encoding                       | Status |
/// |---------|-----------------------|--------------------------------|--------|
/// | Solana  | m/44'/501'/0'/0'      | base58(pubkey)                 | REAL   |
/// | NEAR    | m/44'/397'/0'         | hex(pubkey).lowercased         | REAL   |
/// | Aptos   | m/44'/637'/0'/0'/0'   | 0x ‖ SHA3-256(pubkey ‖ 0x00)   | PENDING (SHA-3 not in CryptoKit) |
/// | Sui     | m/44'/784'/0'/0'/0'   | 0x ‖ BLAKE2b-256(0x00 ‖ pubkey)| PENDING (BLAKE2b not in CryptoKit) |
/// | Stellar | m/44'/148'/0'         | StrKey('G', pubkey, CRC16-XModem)| PENDING (CRC16-XModem not in CryptoKit) |
/// | TON     | m/44'/607'/0'         | TON wallet v3r2 contract addr  | PENDING (contract math not implemented) |
///
/// **Honesty (Rule #2 §A.7).** Chains marked PENDING fall through to
/// the existing stub derivation with a `[STUB]` prefix so the user
/// can never confuse a placeholder for a real address. The real
/// derivation for those chains lives behind T-031 — implementing
/// SHA-3 / BLAKE2b / StrKey from scratch is not a one-turn job.
enum Ed25519Derivation {

    /// Solana address: base58 of the 32-byte ed25519 public key,
    /// derived at the Phantom-compatible path `m/44'/501'/0'/0'`.
    /// First-account address (no sub-account index).
    static func solanaAddress(seed: Data) -> String {
        let node = SLIP0010.derive(seed: seed, hardenedPath: [44, 501, 0, 0])
        let publicKey = ed25519PublicKey(from: node.privateKey)
        return Base58.encode(publicKey)
    }

    /// NEAR implicit-account address: lowercased hex of the 32-byte
    /// ed25519 public key, derived at `m/44'/397'/0'`. Implicit
    /// accounts are the user's first NEAR address on a fresh wallet.
    /// "Named" accounts (e.g., `alice.near`) require an explicit
    /// registration transaction and are not derivable from the seed.
    static func nearImplicitAccount(seed: Data) -> String {
        let node = SLIP0010.derive(seed: seed, hardenedPath: [44, 397, 0])
        let publicKey = ed25519PublicKey(from: node.privateKey)
        return publicKey.map { String(format: "%02x", $0) }.joined()
    }

    /// Derive the ed25519 public key from a 32-byte private key seed
    /// via CryptoKit's Curve25519 primitive. CryptoKit does not expose
    /// the 32-byte raw public key directly through a stable property
    /// name across versions — `rawRepresentation` is the documented
    /// public-key serialization.
    private static func ed25519PublicKey(from privateKey: Data) -> Data {
        // Curve25519.Signing.PrivateKey accepts a 32-byte seed; the
        // public key is the canonical ed25519 verifying key.
        guard let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) else {
            // SLIP-0010 produces exactly 32 bytes — the only way this
            // initializer fails is a memory-corruption-class bug.
            // Return all zeros as a defensive fallback that will
            // produce an obviously-invalid address rather than crash.
            return Data(repeating: 0, count: 32)
        }
        return signingKey.publicKey.rawRepresentation
    }
}
