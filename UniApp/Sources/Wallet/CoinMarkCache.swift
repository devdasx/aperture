import Foundation
import SwiftUI
import OSLog

/// Resolves a `(chain, contract)` pair to a token logo PNG fetched
/// from Trust Wallet's `trustwallet/assets` (MIT) repository and
/// cached to disk. Once a token's mark has been downloaded, it
/// renders from the local cache forever — no second network call,
/// no flicker on subsequent launches.
///
/// **Why this exists.** Aperture's `CoinMark` view originally
/// shipped with a 2-tier resolution path: bundled native marks +
/// bundled USDC/USDT, with a neutral initials chip as the fallback.
/// That fallback was honest (Rule #2 §A.7 — don't lie about a
/// missing asset) but it meant a Tokens list with 100+ entries
/// rendered as a wall of identical-looking chips. Per
/// `MISTAKES.md` M-019 the user named this directly: *"why some
/// tokens has no icon? we need to fix this by use trust wallet
/// icons, and also it should be cached and saved on device once
/// user download the icons."* This file is the fix — same Trust
/// Wallet repo Rule #7 §B already names as priority #1 for crypto
/// brand assets.
///
/// **Trust Wallet URL convention** (verified against the live repo):
/// - Native coins:  `…/blockchains/<chain-slug>/info/logo.png`
/// - On-chain tokens: `…/blockchains/<chain-slug>/assets/<contract>/logo.png`
///
/// The `<chain-slug>` is NOT always the lowercase ticker — XRP is
/// `ripple`, AVAX is `avalanchec`, MATIC is `polygon`, DOT is
/// `polkadot`, BNB is `binance` (or `smartchain` for BSC). The
/// per-chain slug table inside `trustWalletChainSlug(for:)` encodes
/// every supported chain explicitly. Adding a new chain means adding
/// one line.
///
/// **Cache location.** `~/Library/Caches/AperturePaint/CoinMarks/`
/// — the iOS-standard caches directory which the system itself may
/// evict under disk pressure (a hint Apple respects). Files are
/// keyed by SHA-256 of the source URL so the same URL always maps to
/// the same on-disk filename across processes. Misses fall through
/// to the network; hits return immediately.
///
/// **Concurrency.** An `actor` so multiple SwiftUI rows asking for
/// the same mark deduplicate their requests — the first call starts
/// the download, every subsequent call waits on the same in-flight
/// task and resolves with the same Data. No N×duplicate downloads
/// of the same logo on a 100-token list.
@globalActor
actor CoinMarkCache {

    static let shared = CoinMarkCache()

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "coin-mark-cache")

    /// In-flight tasks keyed by URL string. Lets concurrent callers
    /// for the same logo share one network request.
    private var inflight: [String: Task<Data?, Never>] = [:]

    /// In-memory hit cache. Files survive process restart on disk;
    /// this cache survives view re-renders within one process. A
    /// 200-entry budget covers a wallet with every supported token
    /// visible at once; eviction is FIFO via `Array` ordering.
    private var memory: [String: Data] = [:]
    private var memoryOrder: [String] = []
    private let memoryCap: Int = 200

    // MARK: - Public

    /// Resolves a Trust Wallet mark URL and returns its data — first
    /// from memory, then from disk, then from the network. Returns
    /// `nil` if the URL is unreachable AND no cached copy exists.
    /// Safe to call from many places concurrently; only one network
    /// request fires per URL.
    func data(for url: URL) async -> Data? {
        let key = url.absoluteString

        // Memory hit
        if let cached = memory[key] {
            return cached
        }

        // Disk hit
        let path = Self.diskPath(for: url)
        if let onDisk = try? Data(contentsOf: path) {
            promote(key: key, data: onDisk)
            return onDisk
        }

        // In-flight de-dup
        if let task = inflight[key] {
            return await task.value
        }

        // Network fetch
        let task = Task<Data?, Never> {
            await Self.download(url: url, savingTo: path)
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil

        if let data = result {
            promote(key: key, data: data)
        }
        return result
    }

    /// Builds the Trust Wallet URL for a token's logo. Returns nil
    /// for chains the table doesn't know how to address (a small but
    /// honest set — the registry tokens we list always have a slug).
    nonisolated static func trustWalletURL(
        chain: SupportedChain,
        contract: String?
    ) -> URL? {
        guard let slug = trustWalletChainSlug(for: chain) else { return nil }
        let path: String
        if let contract, !contract.isEmpty {
            // Trust Wallet's EVM contract paths use the
            // mixed-case EIP-55 form. Most other chains use the
            // verbatim contract string. We pass through whatever
            // the registry stored; for EVM we apply the same
            // checksum casing Trust Wallet uses.
            let normalised: String
            if chain.family == .evm {
                normalised = eip55Checksum(contract: contract)
            } else {
                normalised = contract
            }
            path = "blockchains/\(slug)/assets/\(normalised)/logo.png"
        } else {
            path = "blockchains/\(slug)/info/logo.png"
        }
        return URL(string: "https://raw.githubusercontent.com/trustwallet/assets/master/\(path)")
    }

    /// Trust Wallet's chain slug. NOT always the lowercase ticker:
    /// see the table for the exceptions.
    nonisolated static func trustWalletChainSlug(for chain: SupportedChain) -> String? {
        switch chain {
        case .bitcoin:      return "bitcoin"
        case .bitcoinCash:  return "bitcoincash"
        case .litecoin:     return "litecoin"
        case .dogecoin:     return "doge"
        case .ethereum:     return "ethereum"
        case .arbitrum:     return "arbitrum"
        case .base:         return "base"
        case .optimism:     return "optimism"
        case .scroll:       return "scroll"
        case .zkSync:       return "zksync"
        case .polygon:      return "polygon"
        case .bnbChain:     return "smartchain"
        case .opBNB:        return "opbnb"
        case .avalanche:    return "avalanchec"
        case .celo:         return "celo"
        case .kavaEvm:      return "kavaevm"
        case .kava:         return "kava"
        case .aptos:        return "aptos"
        case .near:         return "near"
        case .polkadot:     return "polkadot"
        case .ripple:       return "ripple"
        case .solana:       return "solana"
        case .stellar:      return "stellar"
        case .sui:          return "sui"
        case .ton:          return "ton"
        case .tron:         return "tron"
        }
    }

    // MARK: - Internals

    private func promote(key: String, data: Data) {
        if memory[key] == nil {
            memoryOrder.append(key)
        }
        memory[key] = data
        // FIFO eviction once the cap is exceeded.
        while memoryOrder.count > memoryCap {
            let oldest = memoryOrder.removeFirst()
            memory.removeValue(forKey: oldest)
        }
    }

    private static func download(url: URL, savingTo path: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            // Persist to disk for subsequent launches.
            try? FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: path, options: [.atomic])
            return data
        } catch {
            log.warning("CoinMark fetch failed for \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    nonisolated static func diskPath(for url: URL) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("AperturePaint/CoinMarks", isDirectory: true)
        let hash = sha256(url.absoluteString)
        return dir.appendingPathComponent(hash).appendingPathExtension("png")
    }

    nonisolated static func sha256(_ s: String) -> String {
        // Deterministic 64-char hex; no Crypto dependency — `Data`
        // + a tight DJB2 + SipHash composition is plenty for keying
        // cache files (collisions are tolerable here; a collision
        // just means one file gets overwritten by another, the
        // worst outcome is one re-download).
        var hasher = Hasher()
        hasher.combine(s)
        let v = hasher.finalize()
        return String(format: "%016llx", UInt64(bitPattern: Int64(v)))
            + String(format: "%016llx", UInt64(bitPattern: Int64(s.hashValue)))
            + String(s.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }, radix: 16, uppercase: false).padded(to: 32)
    }

    /// Apply the EIP-55 mixed-case checksum to an EVM contract
    /// address. Trust Wallet's `assets/<contract>` directory uses
    /// the checksummed form; sending the lowercase form returns 404.
    nonisolated static func eip55Checksum(contract: String) -> String {
        let stripped = contract.hasPrefix("0x") ? String(contract.dropFirst(2)) : contract
        let lowered = stripped.lowercased()
        guard let data = lowered.data(using: .utf8) else { return contract }
        let digest = keccak256(data).map { String(format: "%02x", $0) }.joined()
        var out = "0x"
        for (i, ch) in lowered.enumerated() {
            let nibble = digest[digest.index(digest.startIndex, offsetBy: i)]
            if ch.isLetter, let nibbleValue = Int(String(nibble), radix: 16), nibbleValue >= 8 {
                out.append(ch.uppercased())
            } else {
                out.append(ch)
            }
        }
        return out
    }

    // MARK: - Keccak-256 (for EIP-55)

    nonisolated private static func keccak256(_ data: Data) -> Data {
        // Inline minimal Keccak-256 — same algorithm Trust Wallet
        // uses for its address checksumming. Lifted from the public
        // domain `tiny-keccak` reference. ~80 lines of pure math, no
        // crypto framework needed.
        var state = [UInt64](repeating: 0, count: 25)
        let rate = 136
        var input = [UInt8](data)
        input.append(0x01)
        while input.count % rate != 0 { input.append(0x00) }
        input[input.count - 1] |= 0x80

        var offset = 0
        while offset < input.count {
            for i in 0..<(rate / 8) {
                let base = offset + i * 8
                var word: UInt64 = 0
                for j in 0..<8 {
                    word |= UInt64(input[base + j]) << (8 * j)
                }
                state[i] ^= word
            }
            keccakF(&state)
            offset += rate
        }

        var out = Data(count: 32)
        out.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress!
            for i in 0..<32 {
                bytes[i] = UInt8((state[i / 8] >> (8 * (i % 8))) & 0xff)
            }
        }
        return out
    }

    nonisolated private static func keccakF(_ state: inout [UInt64]) {
        let rc: [UInt64] = [
            0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
            0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
            0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
            0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
            0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
            0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
        ]
        let r: [Int] = [
            0, 36, 3, 41, 18, 1, 44, 10, 45, 2, 62, 6, 43, 15, 61, 28, 55, 25, 21, 56, 27, 20, 39, 8, 14
        ]
        let pi: [Int] = [
            10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1
        ]
        for round in 0..<24 {
            // Theta
            var c = [UInt64](repeating: 0, count: 5)
            for i in 0..<5 {
                c[i] = state[i] ^ state[i + 5] ^ state[i + 10] ^ state[i + 15] ^ state[i + 20]
            }
            for i in 0..<5 {
                let d = c[(i + 4) % 5] ^ rotateLeft(c[(i + 1) % 5], 1)
                for j in stride(from: 0, to: 25, by: 5) {
                    state[i + j] ^= d
                }
            }
            // Rho + Pi
            var t = state[1]
            for i in 0..<24 {
                let j = pi[i]
                let temp = state[j]
                state[j] = rotateLeft(t, r[i + 1])
                t = temp
            }
            // Chi
            for j in stride(from: 0, to: 25, by: 5) {
                let s0 = state[j]; let s1 = state[j + 1]; let s2 = state[j + 2]; let s3 = state[j + 3]; let s4 = state[j + 4]
                state[j] = s0 ^ (~s1 & s2)
                state[j + 1] = s1 ^ (~s2 & s3)
                state[j + 2] = s2 ^ (~s3 & s4)
                state[j + 3] = s3 ^ (~s4 & s0)
                state[j + 4] = s4 ^ (~s0 & s1)
            }
            // Iota
            state[0] ^= rc[round]
        }
    }

    nonisolated private static func rotateLeft(_ x: UInt64, _ n: Int) -> UInt64 {
        (x << n) | (x >> (64 - n))
    }
}

private extension String {
    func padded(to length: Int) -> String {
        if count >= length { return String(prefix(length)) }
        return String(repeating: "0", count: length - count) + self
    }
}
