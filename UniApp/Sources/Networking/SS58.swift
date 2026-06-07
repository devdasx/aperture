import Foundation

/// SS58 (Substrate / Polkadot address) codec.
///
/// **Format (Polkadot/Kusama spec):**
/// `base58( network_prefix || account_id_32 || checksum_2 )`
/// where `checksum_2` is the first 2 bytes of
/// `blake2b_512( "SS58PRE" || network_prefix || account_id_32 )`.
///
/// For Polkadot mainnet `network_prefix = 0x00` (single byte) and
/// total raw length is **35 bytes** = 1 prefix + 32 accountId + 2
/// checksum. Other Substrate chains may use a 2-byte prefix and 36
/// total bytes — Aperture handles Polkadot mainnet only.
enum SS58 {

    /// Decode a Polkadot mainnet address (`1…` or `13…`) to its
    /// 32-byte AccountId32. Returns nil on:
    /// - non-Base58 character in the input,
    /// - wrong total length after decode,
    /// - checksum mismatch.
    static func decodeAccountId(_ address: String) -> [UInt8]? {
        guard let raw = Base58.decodeBytes(address) else { return nil }
        guard raw.count == 35 else { return nil }
        let prefix = raw[0]
        let accountId = Array(raw[1..<33])
        let checksum = Array(raw[33..<35])

        // BLAKE2b-512("SS58PRE" || prefix || accountId)[0..2]
        var checkInput: [UInt8] = Array("SS58PRE".utf8)
        checkInput.append(prefix)
        checkInput.append(contentsOf: accountId)
        let expected = Array(BLAKE2b.hash(checkInput, outlen: 64).prefix(2))
        guard expected == checksum else { return nil }
        return accountId
    }
}
