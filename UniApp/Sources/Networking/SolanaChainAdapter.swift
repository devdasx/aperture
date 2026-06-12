import Foundation
import CommonCrypto

/// Solana adapter. JSON-RPC against the Solana RPC API.
/// `getBalance(address)` returns `{ value: lamports }` envelope.
struct SolanaChainAdapter: Sendable {
    let client: RPCClient

    /// Native SOL balance — lamports / 10^9.
    func fetchAccountSummary(address: String) async throws(RPCError) -> ChainAccountSummary {
        let data = try await client.callJSONResultData(
            chain: .solana,
            method: "getBalance",
            params: [address]
        )
        let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let lamports = (dict["value"] as? NSNumber)?.int64Value ?? 0
        let sol = NSDecimalNumber(value: lamports).decimalValue / 1_000_000_000
        return ChainAccountSummary(nativeBalance: sol, isUsed: sol > 0)
    }

    /// Raw SPL token discovery via `getTokenAccountsByOwner`. Returns
    /// every fungible SPL token the owner address holds, decoded into
    /// `(mint, amount, decimals)` triples. Aperture pairs each mint
    /// with a small built-in metadata registry for symbol/name; mints
    /// the registry doesn't know fall through to a truncated mint
    /// display (honest about what we don't know).
    struct SPLTokenAccount: Sendable {
        let mint: String
        let amount: Decimal       // canonical units, already decoded
        let decimals: Int
    }

    /// Legacy SPL Token program id (43 chars, decodes to 32 bytes).
    static let splTokenProgramId = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
    /// Token-2022 program id — 43 chars, decodes to a canonical 32-byte
    /// Solana pubkey. AUSD, DUSD, PYUSD, USDG mints live under this
    /// program owner.
    ///
    /// **The 44-char form ending in `Z` is NOT a valid Solana
    /// address** — `getAccountInfo` returns `WrongSize` because the
    /// base58 value decodes to 33 bytes (> 2^256, outside the 32-byte
    /// pubkey space). Mainnet verified at slot 425814213 against
    /// `api.mainnet-beta.solana.com`: the 43-char form is the
    /// deployed program owned by `BPFLoaderUpgradeab1e...`. See
    /// `MISTAKES.md` M-016 for the 2026-06-12 audit that reverted the
    /// `Z`-terminated misconception.
    static let splToken2022ProgramId = "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb"

    func fetchTokenAccounts(address: String) async throws(RPCError) -> [SPLTokenAccount] {
        // `getTokenAccountsByOwner` filtered by `programId` returns
        // ONLY that program's accounts, and token accounts live under
        // one of TWO owner programs — legacy SPL Token and Token-2022.
        // Both must be queried and merged, otherwise Token-2022
        // holdings (PYUSD, AUSD, DUSD, USDG) are invisible.
        let legacy = try await fetchTokenAccounts(address: address, programId: Self.splTokenProgramId)
        let token2022 = try await fetchTokenAccounts(address: address, programId: Self.splToken2022ProgramId)
        return legacy + token2022
    }

    private func fetchTokenAccounts(address: String, programId: String) async throws(RPCError) -> [SPLTokenAccount] {
        let filter: [String: Sendable] = [
            "programId": programId,
        ]
        let opts: [String: Sendable] = [
            "encoding": "jsonParsed",
        ]
        let data = try await client.callJSONResultData(
            chain: .solana,
            method: "getTokenAccountsByOwner",
            params: [address, filter, opts]
        )
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = dict["value"] as? [[String: Any]] else {
            return []
        }
        return value.compactMap { item in
            guard let account = item["account"] as? [String: Any],
                  let acctData = account["data"] as? [String: Any],
                  let parsed = acctData["parsed"] as? [String: Any],
                  let info = parsed["info"] as? [String: Any],
                  let mint = info["mint"] as? String,
                  let tokenAmount = info["tokenAmount"] as? [String: Any],
                  let amountStr = tokenAmount["amount"] as? String,
                  let raw = Decimal(string: amountStr) else {
                return nil
            }
            let decimals = (tokenAmount["decimals"] as? NSNumber)?.intValue ?? 0
            let amount = decimals == 0 ? raw : raw / Self.pow10(decimals)
            // Filter out zero-balance accounts — Solana keeps
            // closed-but-rent-exempt token accounts hanging around.
            guard amount > 0 else { return nil }
            return SPLTokenAccount(mint: mint, amount: amount, decimals: decimals)
        }
    }

    private static func pow10(_ n: Int) -> Decimal {
        var result = Decimal(1)
        for _ in 0..<n { result *= 10 }
        return result
    }

    // MARK: - Mint info + Metaplex metadata (for Custom Tokens)

    /// Read a mint's on-chain config via `getAccountInfo` on the mint
    /// itself. Decodes the 82-byte SPL mint account layout to extract
    /// `decimals` (required) and `supply` (informational only — Aperture
    /// doesn't render it but the field is honest about what we got).
    ///
    /// **SPL mint account layout** (`spl-token/src/state.rs::Mint`):
    /// - bytes 0..4:   mint-authority `COption` flag
    /// - bytes 4..36:  mint authority pubkey
    /// - bytes 36..44: supply (u64 little-endian)
    /// - byte  44:     decimals (u8)
    /// - byte  45:     is_initialized (u8)
    /// - bytes 46..50: freeze-authority `COption` flag
    /// - bytes 50..82: freeze authority pubkey
    ///
    /// Solana's `getAccountInfo` returns `{ value: { data: [base64,
    /// "base64"], ... }}`. Token-2022 mints have extra extension bytes
    /// past byte 82, but `decimals` and `supply` are at the same
    /// offsets in both standards. Throws `.decodingFailed` if the
    /// account doesn't exist or the data isn't a valid mint layout.
    func fetchMintInfo(mint: String) async throws(RPCError) -> SolanaMintInfo {
        let encoding: [String: Sendable] = ["encoding": "base64"]
        let data = try await client.callJSONResultData(
            chain: .solana,
            method: "getAccountInfo",
            params: [mint, encoding]
        )
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = dict["value"] as? [String: Any] else {
            throw .decodingFailed("getAccountInfo returned no value for mint")
        }
        // The account must actually BE a mint: owned (exactly) by one
        // of the two token programs. Without this check any ≥82-byte
        // account — Metaplex metadata, program data, stake account —
        // "decodes" an arbitrary data byte as decimals (up to 255,
        // which overflows downstream scale math).
        let owner = value["owner"] as? String ?? ""
        guard owner == Self.splTokenProgramId || owner == Self.splToken2022ProgramId else {
            throw .decodingFailed("Account is not owned by an SPL token program")
        }
        guard let dataArr = value["data"] as? [Any],
              let base64Str = dataArr.first as? String,
              let raw = Data(base64Encoded: base64Str),
              raw.count >= 82 else {
            throw .decodingFailed("Mint account data layout invalid")
        }
        let bytes = [UInt8](raw)
        // is_initialized (byte 45) must be set — an uninitialized
        // mint's decimals byte is garbage.
        guard bytes[45] == 1 else {
            throw .decodingFailed("Mint account is not initialized")
        }
        // Supply at bytes 36..44, little-endian u64.
        var supply: UInt64 = 0
        for i in 0..<8 {
            supply |= UInt64(bytes[36 + i]) << (8 * i)
        }
        let decimals = Int(bytes[44])
        let standard: SolanaTokenRegistry.Standard = owner == Self.splToken2022ProgramId
            ? .splToken2022
            : .splToken
        return SolanaMintInfo(decimals: decimals, supply: supply, standard: standard)
    }

    /// Read a token's Metaplex `Metadata` account if it exists. The
    /// metadata account is a Program-Derived Address (PDA) derived from
    /// `["metadata", MPL_TOKEN_METADATA_PROGRAM_ID, mintPubkey]`.
    ///
    /// **Borsh-encoded Metadata struct (mpl-token-metadata v1):**
    /// - 1  byte  key (4 = Metadata)
    /// - 32 bytes update_authority
    /// - 32 bytes mint
    /// - 4 bytes name length-prefix + 32 bytes name (null-padded)
    /// - 4 bytes symbol length-prefix + 10 bytes symbol (null-padded)
    /// - 4 bytes uri length-prefix + 200 bytes uri (null-padded)
    /// - (more fields follow — seller_fee_basis_points, creators
    ///   array, etc. — Aperture only reads name+symbol)
    ///
    /// **Bump iteration.** PDAs require the address to be off-curve.
    /// Rather than implement a full ed25519 on-curve check (which
    /// needs BigInt modular arithmetic over 2²⁵⁵−19), we exploit a
    /// Solana property: getAccountInfo for an on-curve address that
    /// happens to NOT be a real account simply returns null. So we
    /// can iterate candidate bumps 255 → 0, call getAccountInfo on
    /// each, and the FIRST hit that returns a non-null value with the
    /// metadata `key=4` prefix byte is the real Metaplex PDA. In
    /// practice the canonical bump is 254 or 255 for every mint, so
    /// the iteration terminates immediately for real metadata
    /// accounts. Tokens without metadata return nil after the cap
    /// (Aperture stops at bump 248 — 8 attempts is more than enough
    /// for the real-world distribution).
    ///
    /// Returns `nil` if no metadata account exists at any plausible
    /// bump (the common case for long-tail tokens). The Add Custom
    /// Token sheet falls back to user-typed name+symbol then.
    func fetchMetaplexMetadata(mint: String) async -> SolanaMetaplexMetadata? {
        guard let mintBytes = Base58.decodeBytes(mint), mintBytes.count == 32 else {
            return nil
        }
        guard let programIdBytes = Base58.decodeBytes(Self.mplTokenMetadataProgramId),
              programIdBytes.count == 32 else {
            return nil
        }

        // Try bumps 255 → 248. In production data the metadata PDA
        // always lands at bump 254 or 255; eight attempts gives us a
        // safety margin without burning RPC quota on a fruitless
        // search for tokens that just don't have metadata.
        for bumpInt in (248...255).reversed() {
            let bump = UInt8(bumpInt)
            var combined: [UInt8] = []
            combined.append(contentsOf: Array("metadata".utf8))
            combined.append(contentsOf: programIdBytes)
            combined.append(contentsOf: mintBytes)
            combined.append(bump)
            combined.append(contentsOf: programIdBytes)
            combined.append(contentsOf: Array("ProgramDerivedAddress".utf8))
            let hash = Self.sha256(combined)
            let candidate = Self.Base58Encode(Array(hash))

            // Ask the RPC. If it returns a non-null value AND the
            // first byte of decoded data is 4 (Metaplex Metadata
            // key), it's a real metadata account.
            let encoding: [String: Sendable] = ["encoding": "base64"]
            let dataOpt = try? await client.callJSONResultData(
                chain: .solana,
                method: "getAccountInfo",
                params: [candidate, encoding]
            )
            guard let data = dataOpt else { continue }
            guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            guard let value = dict["value"] as? [String: Any] else { continue }
            guard let dataArr = value["data"] as? [Any] else { continue }
            guard let base64Str = dataArr.first as? String else { continue }
            guard let raw = Data(base64Encoded: base64Str) else { continue }
            let minimumMetaplexSize = 1 + 32 + 32 + 4 + 32 + 4 + 10 + 4 + 200
            guard raw.count >= minimumMetaplexSize else { continue }
            guard raw[0] == 4 else { continue }

            let bytes = [UInt8](raw)
            var offset = 1 + 32 + 32
            let name = Self.readBorshString(bytes: bytes, offset: &offset, padTo: 32)
            let symbol = Self.readBorshString(bytes: bytes, offset: &offset, padTo: 10)
            return SolanaMetaplexMetadata(name: name, symbol: symbol)
        }
        return nil
    }

    /// MPL Token Metadata program id (base58). Constant across all
    /// Solana networks.
    private static let mplTokenMetadataProgramId = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"

    /// Read a Borsh-encoded `String` from `bytes` starting at
    /// `offset`. Borsh strings are u32-LE length-prefixed; the
    /// Metaplex format additionally null-pads them to a fixed size.
    /// Returns the trimmed UTF-8 string and advances `offset` past
    /// the padded region.
    private static func readBorshString(bytes: [UInt8], offset: inout Int, padTo: Int) -> String {
        guard offset + 4 + padTo <= bytes.count else {
            offset = bytes.count
            return ""
        }
        var length: UInt32 = 0
        for i in 0..<4 {
            length |= UInt32(bytes[offset + i]) << (8 * i)
        }
        offset += 4
        let capped = min(Int(length), padTo)
        let dataBytes = Array(bytes[offset..<(offset + capped)])
        offset += padTo
        let str = String(data: Data(dataBytes), encoding: .utf8) ?? ""
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\0", with: "")
    }

    /// SHA-256 via CommonCrypto (Apple system framework — no third
    /// party dependency per Rule #3). Returns a 32-byte digest.
    private static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: 32)
        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)
        let data = bytes
        data.withUnsafeBufferPointer { buf in
            _ = CC_SHA256_Update(&ctx, buf.baseAddress, CC_LONG(buf.count))
        }
        CC_SHA256_Final(&digest, &ctx)
        return digest
    }

    private static func Base58Encode(_ bytes: [UInt8]) -> String {
        Base58.encode(Data(bytes))
    }

    /// First-page of recent signatures via `getSignaturesForAddress`.
    func fetchRecentTransactions(address: String, limit: Int = 25) async throws(RPCError) -> [SolanaRawTransaction] {
        let params: [Sendable] = [address, ["limit": limit]]
        let data = try await client.callJSONResultData(
            chain: .solana,
            method: "getSignaturesForAddress",
            params: params
        )
        let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return array.map { dict in
            let sig = dict["signature"] as? String ?? ""
            let slot = (dict["slot"] as? NSNumber)?.int64Value
            let blockTime = (dict["blockTime"] as? NSNumber)?.doubleValue
            let hasErr = dict["err"] != nil && !(dict["err"] is NSNull)
            return SolanaRawTransaction(
                txHash: sig,
                blockNumber: slot,
                occurredAt: blockTime.map { Date(timeIntervalSince1970: $0) } ?? Date(),
                status: hasErr ? .failed : .confirmed
            )
        }
    }
}

struct SolanaRawTransaction: Sendable {
    let txHash: String
    let blockNumber: Int64?
    let occurredAt: Date
    let status: SolanaTxStatus
}

enum SolanaTxStatus: Sendable { case pending, confirmed, failed }

/// Decoded SPL mint config — `decimals` + `supply` + the SPL standard
/// (legacy `splToken` vs `splToken2022`). Required for Custom Tokens
/// so the Add sheet can render the decimals honestly and the scanner
/// can pick the right token program for balance reads.
struct SolanaMintInfo: Sendable, Equatable {
    let decimals: Int
    let supply: UInt64
    let standard: SolanaTokenRegistry.Standard
}

/// Decoded Metaplex token metadata — `name` + `symbol`. Best-effort
/// — many long-tail tokens don't have a Metaplex account, in which
/// case the Add sheet falls back to user-typed values.
struct SolanaMetaplexMetadata: Sendable, Equatable {
    let name: String
    let symbol: String
}
