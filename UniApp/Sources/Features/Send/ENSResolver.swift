import Foundation
import WalletCore

/// Resolves an ENS name (e.g. `"vitalik.eth"`) to a checksummed `0x`
/// address on Ethereum mainnet via the **real** on-chain ENS registry +
/// public resolver — no third-party SDK, no hand-rolled `URLSession`
/// (Rule #3). Resolution failure (unregistered name, zero resolver,
/// zero address, RPC error, malformed return) is **not fatal**: the
/// function returns `nil` and the Send UI simply treats the input as
/// "name not found" and asks the user to check it.
///
/// ## Algorithm (EIP-137 — verified live 2026-06-15)
///
/// 1. **namehash(name)** — recursive `keccak256`. Start with the 32-byte
///    zero node; for each label from RIGHT to LEFT,
///    `node = keccak256(node ‖ keccak256(label))`.
///    (`namehash("vitalik.eth")` =
///    `0xee6c4522aab0003e8d14cd40a6af439055fd2577951148c14b6cea9a53475835`.)
/// 2. **registry.resolver(node)** — `eth_call` the ENS registry at
///    `0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e` with calldata
///    `0x0178b8bf ‖ node`. The 32-byte return's last 20 bytes are the
///    resolver address. Zero → unresolved (`nil`).
/// 3. **resolver.addr(node)** — `eth_call` the resolver with calldata
///    `0x3b3b57de ‖ node`. The 32-byte return's last 20 bytes are the
///    address. Zero → `nil`.
/// 4. Return the address **EIP-55 checksummed** (`0x…` mixed case).
///
/// Live curl proof (publicnode, vitalik.eth) resolves to
/// `0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045` — see the PR report.
enum ENSResolver {

    // MARK: - Constants

    /// ENS registry (ENSRegistryWithFallback) — the single canonical
    /// mainnet registry address that owns the name → resolver mapping.
    private static let registryAddress = "0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e"

    /// `resolver(bytes32)` selector — `keccak256("resolver(bytes32)")[0..4]`.
    private static let resolverSelector = "0178b8bf"

    /// `addr(bytes32)` selector — `keccak256("addr(bytes32)")[0..4]`.
    private static let addrSelector = "3b3b57de"

    // MARK: - Public API

    /// Resolve an ENS name (already lowercased, ending in `".eth"`) to a
    /// checksummed `0x` address on Ethereum mainnet. `nil` if unresolved.
    ///
    /// `nonisolated` / free function — safe to call from any context.
    static func resolve(name: String) async -> String? {
        // namehash is pure + deterministic; an empty / malformed name
        // yields the zero node, which the registry maps to the zero
        // resolver → handled as `nil` below. No crash path.
        let nodeHex = namehash(name)

        // Step 2 — registry.resolver(node).
        guard let resolverReturn = await ethCall(
            to: registryAddress,
            data: "0x" + resolverSelector + nodeHex
        ),
        let resolverAddress = addressFromABIWord(resolverReturn),
        !isZeroAddress(resolverAddress) else {
            return nil
        }

        // Step 3 — resolver.addr(node).
        guard let addrReturn = await ethCall(
            to: resolverAddress,
            data: "0x" + addrSelector + nodeHex
        ),
        let resolved = addressFromABIWord(addrReturn),
        !isZeroAddress(resolved) else {
            return nil
        }

        // Step 4 — checksum (EIP-55). Falls back to the lowercase 0x
        // form if checksumming somehow fails; callers re-validate via
        // `CoinType.validate`, which accepts lowercase.
        return eip55Checksummed(resolved)
    }

    // MARK: - EIP-137 namehash

    /// EIP-137 namehash. Returns the 64-char (32-byte) hex node WITHOUT
    /// a `0x` prefix (ready to concatenate after a 4-byte selector).
    static func namehash(_ name: String) -> String {
        var node = [UInt8](repeating: 0, count: 32)
        // An empty name is the zero node ("" → root). Splitting "" on
        // "." yields [""], so guard against that producing a bogus
        // label hash.
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        if !trimmed.isEmpty {
            // RIGHT to LEFT: "vitalik.eth" → ["eth", "vitalik"].
            for label in trimmed.split(separator: ".", omittingEmptySubsequences: false).reversed() {
                let labelHash = keccak256(Array(Data(label.utf8)))
                node = keccak256(node + labelHash)
            }
        }
        return hexEncode(node)
    }

    // MARK: - eth_call via our network layer

    /// One `eth_call` against Ethereum mainnet through the shared
    /// `RPCClient` (rate-limited, fallback-rotating, circuit-broken).
    /// Returns the `0x…`-prefixed 32-byte return hex, or `nil` on any
    /// RPC failure (resolution is best-effort — failure is not fatal).
    private static func ethCall(to contract: String, data: String) async -> String? {
        let txObject: [String: Sendable] = [
            "to": contract,
            "data": data,
        ]
        do {
            return try await RPCClient.shared.callJSONString(
                chain: .ethereum,
                method: "eth_call",
                params: [txObject, "latest"]
            )
        } catch {
            // RPCError (offline, rate-limited, revert, bad endpoint) —
            // treat as "couldn't resolve" so the Send flow degrades
            // gracefully to "name not found".
            return nil
        }
    }

    // MARK: - ABI return parsing

    /// Extract a 20-byte address from a 32-byte ABI-encoded word. ENS
    /// `resolver(bytes32)` and `addr(bytes32)` both return a left-padded
    /// `address` — the last 40 hex chars are the address. Returns a
    /// lowercase `0x…` string, or `nil` if the return is too short
    /// (empty bytes → name not configured for this coin).
    private static func addressFromABIWord(_ hex: String) -> String? {
        let stripped = stripHexPrefix(hex)
        guard stripped.count >= 40 else { return nil }
        let last40 = String(stripped.suffix(40)).lowercased()
        // Validate it's well-formed hex before handing it on.
        guard last40.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "0x" + last40
    }

    /// `true` when the `0x…` address is all zeros — the ENS sentinel for
    /// "no resolver set" / "no address record."
    private static func isZeroAddress(_ address: String) -> Bool {
        let stripped = stripHexPrefix(address)
        return stripped.allSatisfy { $0 == "0" }
    }

    // MARK: - EIP-55 checksum

    /// Apply the EIP-55 mixed-case checksum to a lowercase `0x…`
    /// address. Hashes the lowercase 40-char hex *string* (its ASCII
    /// bytes, no `0x`) with keccak256; each hex letter is uppercased
    /// when the corresponding nibble of the hash is ≥ 8. Returns the
    /// lowercase input unchanged if the address isn't a clean 20-byte
    /// hex value (defensive — callers accept lowercase too).
    static func eip55Checksummed(_ address: String) -> String {
        let lower = stripHexPrefix(address).lowercased()
        guard lower.count == 40, lower.allSatisfy({ $0.isHexDigit }) else {
            return "0x" + lower
        }
        // keccak256 over the ASCII bytes of the lowercase hex string.
        let hash = keccak256(Array(Data(lower.utf8)))
        let hashHex = hexEncode(hash) // 64 hex chars, one nibble per address char
        let hashChars = Array(hashHex)
        let addrChars = Array(lower)

        var out = ""
        out.reserveCapacity(42)
        out += "0x"
        for i in 0..<40 {
            let c = addrChars[i]
            if c.isNumber {
                out.append(c)
            } else {
                // Nibble ≥ 8 → uppercase. `hashChars[i]` is a single
                // hex digit; its value is 0...15.
                let nibble = hashChars[i].hexDigitValue ?? 0
                out.append(nibble >= 8 ? Character(c.uppercased()) : c)
            }
        }
        return out
    }

    // MARK: - Keccak-256 (WalletCore) + hex helpers

    /// keccak256 via WalletCore's `Hash.keccak256(data:)`. The app
    /// already links WalletCore (key import, dApp signing) — this is the
    /// same primitive Ethereum uses everywhere (NOT NIST SHA3-256).
    private static func keccak256(_ bytes: [UInt8]) -> [UInt8] {
        [UInt8](Hash.keccak256(data: Data(bytes)))
    }

    /// Lowercase hex-encode bytes (no `0x` prefix).
    private static func hexEncode(_ bytes: [UInt8]) -> String {
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(hexDigit(b >> 4))
            out.append(hexDigit(b & 0x0F))
        }
        return out
    }

    private static func hexDigit(_ nibble: UInt8) -> Character {
        let v = nibble & 0x0F
        return Character(UnicodeScalar(v < 10 ? (0x30 + v) : (0x61 + v - 10)))
    }

    private static func stripHexPrefix(_ s: String) -> String {
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            return String(s.dropFirst(2))
        }
        return s
    }
}
