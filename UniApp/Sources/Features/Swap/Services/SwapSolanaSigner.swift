import Foundation
import WalletCore

/// Signs a Jupiter-built (base64) Solana **v0 `VersionedTransaction`** the
/// way `SolanaTransactionSigner` can't — that signer *builds* a transfer
/// from a `SendDraft`, whereas a swap arrives fully formed (with Address
/// Lookup Tables) from Jupiter `/swap` and only needs the user's signature.
///
/// **Sign the message AS-IS (no blockhash surgery).** The transaction
/// already carries a fresh blockhash because the executor POSTs `/swap`
/// immediately before signing (post-auth), so we just sign the message
/// bytes and place the signature in slot 0 (the fee payer = userPublicKey,
/// the sole signer for a Jupiter swap). This avoids the fragile
/// blockhash-offset byte surgery — far lower risk for a funds path.
///
/// **Wire format** (Solana): `[numSignatures: compact-u16]
/// [signature: 64]×numSignatures [message…]`. The signature is over the
/// `message` bytes (everything after the signature slots). We preserve any
/// signature slots > 0 in case the provider pre-signed (it doesn't for a
/// standard swap, but preserving is safe; zeroing would not be).
///
/// Pure compute, `nonisolated` — runs inside the executor's off-main task.
enum SwapSolanaSigner {

    /// Sign `base64` (a Jupiter `/swap` VersionedTransaction) with `privateKey`
    /// (the wallet's ed25519 Solana key) and return the signed tx as base64
    /// ready for `sendTransaction`.
    static func signVersioned(base64: String, privateKey: PrivateKey) throws -> String {
        guard let data = Data(base64Encoded: base64), !data.isEmpty else {
            throw SigningError.signingFailed("empty Jupiter swap transaction")
        }
        let bytes = [UInt8](data)
        guard let (numSignatures, headerLen) = readCompactU16(bytes, at: 0) else {
            throw SigningError.signingFailed("malformed Jupiter swap transaction header")
        }
        let slotsEnd = headerLen + Int(numSignatures) * 64
        guard numSignatures >= 1, slotsEnd <= bytes.count else {
            throw SigningError.signingFailed("malformed Jupiter swap transaction")
        }

        let message = Data(bytes[slotsEnd...])
        // ed25519 signs the message bytes directly (no pre-hash).
        guard let signature = privateKey.sign(digest: message, curve: .ed25519),
              signature.count == 64 else {
            throw SigningError.signingFailed("Solana signature failed")
        }

        // Preserve the original signature slots; overwrite ONLY slot 0 (the
        // fee payer / user) with our signature. Slots > 0 stay as the
        // provider set them (zero for a standard swap).
        var slots = Array(bytes[headerLen..<slotsEnd])
        let sigBytes = [UInt8](signature)
        for k in 0..<64 { slots[k] = sigBytes[k] }

        var out = Data()
        writeCompactU16(&out, numSignatures)
        out.append(contentsOf: slots)
        out.append(message)
        return out.base64EncodedString()
    }

    // MARK: - compact-u16 (Solana "shortvec")

    /// Read a compact-u16 (shortvec) at `start`. Returns (value, bytesRead),
    /// or `nil` if the encoding is malformed — over-long (a u16 shortvec is
    /// at most 3 groups), value > 0xffff, or never terminated before the
    /// buffer ends. Rejecting these prevents a truncated/garbled header from
    /// silently producing a wrong signature count.
    private static func readCompactU16(_ bytes: [UInt8], at start: Int) -> (value: UInt16, length: Int)? {
        var value = 0
        var shift = 0
        var i = start
        var groups = 0
        while i < bytes.count {
            let byte = bytes[i]
            value |= Int(byte & 0x7f) << shift
            i += 1
            groups += 1
            if byte & 0x80 == 0 {
                guard groups <= 3, value <= 0xffff else { return nil }
                return (UInt16(value), i - start)
            }
            if groups >= 3 { return nil } // 4th continuation byte → not a valid u16 shortvec
            shift += 7
        }
        return nil // ran off the end without a terminating byte
    }

    /// Append `value` as a compact-u16 (shortvec).
    private static func writeCompactU16(_ data: inout Data, _ value: UInt16) {
        var v = UInt(value)
        repeat {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            data.append(byte)
        } while v != 0
    }
}
