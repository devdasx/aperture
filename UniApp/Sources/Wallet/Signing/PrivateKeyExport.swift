import Foundation
import WalletCore

/// Derives and formats a wallet's per-chain private key for the user-initiated
/// export reveal (Settings → Wallets → <wallet> → "View private keys").
///
/// **Security (Rule #16).** The `PrivateKey` is produced ONLY inside
/// `SigningKeyProvider.withPrivateKey`'s scoped closure — the SAME derivation
/// the signer + importer use, so the exported key always corresponds to the
/// wallet's real key for that chain. The raw bytes are formatted to the
/// chain's canonical secret string and the `PrivateKey` drops at the closure's
/// return; nothing key-shaped is ever logged or persisted. Pure, `nonisolated`
/// so the (PBKDF2 + per-chain) derivation runs off the main actor.
enum PrivateKeyExport {

    /// One exported key, ready to display.
    struct Row: Identifiable, Sendable, Hashable {
        let chain: SupportedChain
        let address: String
        /// The formatted secret (WIF / `0x`-hex / base58), or `nil` when it
        /// couldn't be derived — a legacy wallet whose secret isn't on this
        /// device, or a passphrase wallet without the phrase supplied.
        let value: String?
        /// Short format label shown beside the key.
        let format: String
        var id: String { chain.rawValue }
    }

    /// WIF version bytes per UTXO chain — mirrors the importer's table so an
    /// exported WIF round-trips back through `decodePrivateKeyBytes`.
    private static let wifVersion: [SupportedChain: UInt8] = [
        .bitcoin: 0x80, .bitcoinCash: 0x80, .litecoin: 0xB0, .dogecoin: 0x9E,
    ]

    /// Derive + format the private key for one `(wallet, chain)`.
    ///
    /// Passes the displayed account address into `SigningKeyProvider` so export
    /// uses the same key↔address parity guard as transaction signing.
    nonisolated static func exportKey(
        wallet: WalletDescriptor,
        chain: SupportedChain,
        expectedAddress: String,
        passphrase: String? = nil
    ) throws -> (value: String, format: String) {
        try SigningKeyProvider.withPrivateKey(
            wallet: wallet,
            chain: chain,
            passphrase: passphrase,
            expectedAddress: expectedAddress
        ) { privateKey in
            let keyData = privateKey.data
            switch chain.family {
            case .bitcoin:
                // WIF = base58check(version ‖ 32-byte key ‖ 0x01 compressed
                // flag). `WalletCore.Base58.encode` computes the 4-byte
                // double-SHA256 checksum, so no checksum is hand-rolled.
                let version = wifVersion[chain] ?? 0x80
                let payload = Data([version]) + keyData + Data([0x01])
                return (WalletCore.Base58.encode(data: payload), "WIF")
            case .ed25519, .aptos, .near, .ton, .polkadot:
                // Solana's importable secret is base58(32-byte ed25519 seed ‖
                // 32-byte public key) — the Phantom / Solana-CLI shape. Other
                // ed25519-family chains export the raw 32-byte seed as hex.
                if chain == .solana {
                    let pub = privateKey.getPublicKeyEd25519().data
                    return (WalletCore.Base58.encodeNoCheck(data: keyData + pub), "Base58")
                }
                return ("0x" + hexString(keyData), "Hex")
            case .evm, .tron, .ripple:
                // Raw secp256k1 scalar as 0x-hex — the universal import form
                // for these families.
                return ("0x" + hexString(keyData), "Hex")
            }
        }
    }

    /// Derive every chain's key for a wallet, off the main actor. A chain that
    /// can't derive (no secret / passphrase required) yields a `nil`-value row
    /// rather than failing the whole set.
    nonisolated static func exportAll(
        wallet: WalletDescriptor,
        chains: [(chain: SupportedChain, address: String)],
        passphrase: String? = nil
    ) -> [Row] {
        chains.map { entry in
            if let result = try? exportKey(
                wallet: wallet,
                chain: entry.chain,
                expectedAddress: entry.address,
                passphrase: passphrase
            ) {
                return Row(chain: entry.chain, address: entry.address, value: result.value, format: result.format)
            }
            return Row(chain: entry.chain, address: entry.address, value: nil, format: "—")
        }
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
