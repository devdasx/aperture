import Foundation
import SwiftUI
import OSLog
import CryptoKit

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
    private var inflight: [String: Task<DownloadOutcome, Never>] = [:]

    /// Negative cache (2026-06-12): URL → don't-retry-before date.
    /// Trust Wallet doesn't host logos for several long-tail registry
    /// tokens and most user-added custom tokens, so those URLs
    /// permanently 404 — and `CoinMark`'s `.task(id: url)` re-fires on
    /// every lazy list-row reappearance, so every scroll re-downloaded
    /// every missing logo (10 s timeout each, URLCache disabled).
    /// Definitive misses (HTTP 4xx) are remembered for hours;
    /// transient failures (offline, 5xx, timeout) for a couple of
    /// minutes so a flaky moment doesn't blank logos for the session.
    private var negativeUntil: [String: Date] = [:]
    private static let notFoundTTL: TimeInterval = 6 * 60 * 60
    private static let transientTTL: TimeInterval = 2 * 60

    /// What one network attempt produced — distinguishes "the logo
    /// doesn't exist upstream" from "the network hiccuped" so the
    /// negative cache can apply the right TTL.
    private enum DownloadOutcome: Sendable {
        case success(Data)
        case notFound   // definitive HTTP 4xx — upstream has no logo
        case transient  // URL error / 5xx / anything retryable-soon
    }

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
    /// request fires per URL. Failed lookups are negative-cached
    /// (2026-06-12) so scrolling a token list doesn't re-fire a
    /// request per missing logo on every row reappearance.
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

        // Negative-cache hit — a recent attempt already failed;
        // don't hammer raw.githubusercontent.com until the TTL lapses.
        if let until = negativeUntil[key] {
            if Date() < until { return nil }
            negativeUntil[key] = nil
        }

        // In-flight de-dup
        if let task = inflight[key] {
            if case .success(let data) = await task.value {
                return data
            }
            return nil
        }

        // Network fetch
        let task = Task<DownloadOutcome, Never> {
            await Self.download(url: url, savingTo: path)
        }
        inflight[key] = task
        let outcome = await task.value
        inflight[key] = nil

        switch outcome {
        case .success(let data):
            promote(key: key, data: data)
            return data
        case .notFound:
            negativeUntil[key] = Date().addingTimeInterval(Self.notFoundTTL)
            return nil
        case .transient:
            negativeUntil[key] = Date().addingTimeInterval(Self.transientTTL)
            return nil
        }
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

    private static func download(url: URL, savingTo path: URL) async -> DownloadOutcome {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                // 4xx is definitive — the repo has no logo at this
                // path; remember it for hours. Everything else (5xx,
                // odd redirects) is plausibly transient.
                if let http = response as? HTTPURLResponse,
                   (400..<500).contains(http.statusCode) {
                    return .notFound
                }
                return .transient
            }
            // Persist to disk for subsequent launches.
            try? FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: path, options: [.atomic])
            return .success(data)
        } catch {
            log.warning("CoinMark fetch failed for \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
            return .transient
        }
    }

    nonisolated static func diskPath(for url: URL) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("AperturePaint/CoinMarks", isDirectory: true)
        let hash = sha256(url.absoluteString)
        return dir.appendingPathComponent(hash).appendingPathExtension("png")
    }

    nonisolated static func sha256(_ s: String) -> String {
        // Real SHA-256 via CryptoKit (2026-06-10). The previous
        // implementation mixed `Swift.Hasher` / `hashValue`, whose
        // seeds are randomized per process launch — the "stable"
        // disk key changed every launch, so the disk cache NEVER hit
        // across launches and every logo was re-downloaded. CryptoKit
        // is deterministic across launches, processes, and devices.
        // (Old randomly-keyed cache files simply become unreferenced;
        // the system evicts them from Caches under disk pressure.)
        SHA256.hash(data: Data(s.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Apply the EIP-55 mixed-case checksum to an EVM contract
    /// address. Trust Wallet's `assets/<contract>` directory uses
    /// the checksummed form; sending the lowercase form returns 404.
    ///
    /// Delegates to the shared `Keccak256` helper so this file no
    /// longer carries an inline copy of the algorithm. Same digest,
    /// same output, one audit surface.
    nonisolated static func eip55Checksum(contract: String) -> String {
        Keccak256.eip55Checksum(contract: contract)
    }
}
