import Foundation
import CryptoKit

/// SLIP-0010 hierarchical-deterministic derivation for ed25519, the
/// "BIP-32 for ed25519" spec adopted by Solana, NEAR, Aptos, Sui,
/// Stellar, and others. Only **hardened** derivation is defined for
/// ed25519 (the spec forbids unhardened children because ed25519
/// scalar arithmetic cannot produce the parent-derives-child public
/// key identity that BIP-32 secp256k1 relies on).
///
/// **Algorithm (SLIP-0010 §4):**
/// 1. Master key:
///    - `I = HMAC-SHA512(key: "ed25519 seed", data: seed)`
///    - `master_secret = I[0..32]`, `master_chain_code = I[32..64]`
/// 2. Hardened child at index `i` (always ≥ 0x80000000):
///    - `I = HMAC-SHA512(key: parent_chain_code, data: 0x00 ‖ parent_secret ‖ ser32(i))`
///    - `child_secret = I[0..32]`, `child_chain_code = I[32..64]`
///
/// **Native-only (Rule #3).** HMAC-SHA512 comes from CryptoKit; the
/// per-byte index packing is straightforward. No third-party SDK.
///
/// **Honesty (Rule #2 §A.7).** The 32-byte secret produced by this
/// chain is the **real** ed25519 seed/private key for the leaf node.
/// It must never be logged, persisted to UserDefaults, or sent over
/// the network. Callers consume it immediately (derive the public
/// key, encode the address) and let the value go out of scope.
enum SLIP0010 {

    struct Node: Sendable {
        let privateKey: Data   // 32 bytes
        let chainCode: Data    // 32 bytes
    }

    /// Derive the master node from a BIP-39 seed (64 bytes typical;
    /// any non-empty bytes are accepted per the spec).
    static func masterNode(seed: Data) -> Node {
        let key = SymmetricKey(data: Data("ed25519 seed".utf8))
        let mac = HMAC<SHA512>.authenticationCode(for: seed, using: key)
        let bytes = Data(mac)
        return Node(
            privateKey: bytes.prefix(32),
            chainCode: bytes.suffix(32)
        )
    }

    /// Derive a hardened child at index `i`. The hardened bit
    /// (`0x80000000`) is added internally — callers pass logical
    /// indices like `0`, `44`, `501`, etc.
    static func hardenedChild(of parent: Node, index: UInt32) -> Node {
        // ser32(i') where i' = i | 0x80000000
        let hardenedIndex = index | 0x8000_0000
        var indexBytes = Data(count: 4)
        indexBytes[0] = UInt8((hardenedIndex >> 24) & 0xff)
        indexBytes[1] = UInt8((hardenedIndex >> 16) & 0xff)
        indexBytes[2] = UInt8((hardenedIndex >> 8) & 0xff)
        indexBytes[3] = UInt8(hardenedIndex & 0xff)

        // data = 0x00 ‖ parent_secret ‖ ser32(i')
        var data = Data()
        data.append(0x00)
        data.append(parent.privateKey)
        data.append(indexBytes)

        let key = SymmetricKey(data: parent.chainCode)
        let mac = HMAC<SHA512>.authenticationCode(for: data, using: key)
        let bytes = Data(mac)
        return Node(
            privateKey: bytes.prefix(32),
            chainCode: bytes.suffix(32)
        )
    }

    /// Walk a BIP-44-style path of hardened indices from a seed.
    /// Path values must be the logical index (not pre-hardened).
    /// Example for Solana `m/44'/501'/0'/0'`: pass `[44, 501, 0, 0]`.
    static func derive(seed: Data, hardenedPath: [UInt32]) -> Node {
        var node = masterNode(seed: seed)
        for index in hardenedPath {
            node = hardenedChild(of: node, index: index)
        }
        return node
    }
}

#if DEBUG
/// Debug-mode smoke check against SLIP-0010 §6 ed25519 test vector 1.
///
/// Seed (hex): 000102030405060708090a0b0c0d0e0f
/// Master node:
///   privateKey: 2b4be7f19ee27bbf30c667b642d5f4aa69fd169872f8fc3059c08ebae2eb19e7
///   chainCode:  90046a93de5380a72b5e45010748567d5ea02bbf6522f979e05c0d8d8ca9fffb
private let _slip0010SmokeCheck: Void = {
    var seed = Data()
    for v: UInt8 in 0x00...0x0f { seed.append(v) }
    let master = SLIP0010.masterNode(seed: seed)
    let pkHex = master.privateKey.map { String(format: "%02x", $0) }.joined()
    let ccHex = master.chainCode.map { String(format: "%02x", $0) }.joined()
    assert(
        pkHex == "2b4be7f19ee27bbf30c667b642d5f4aa69fd169872f8fc3059c08ebae2eb19e7",
        "SLIP-0010 master priv mismatch — got \(pkHex)"
    )
    assert(
        ccHex == "90046a93de5380a72b5e45010748567d5ea02bbf6522f979e05c0d8d8ca9fffb",
        "SLIP-0010 master chain mismatch — got \(ccHex)"
    )

    // m/0' from the same seed:
    //   privateKey: 68e0fe46dfb67e368c75379acec591dad19df3cde26e63b93a8e704f1dade7a3
    let child = SLIP0010.hardenedChild(of: master, index: 0)
    let childHex = child.privateKey.map { String(format: "%02x", $0) }.joined()
    assert(
        childHex == "68e0fe46dfb67e368c75379acec591dad19df3cde26e63b93a8e704f1dade7a3",
        "SLIP-0010 m/0' priv mismatch — got \(childHex)"
    )
}()
#endif
