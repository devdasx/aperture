import Foundation
import OSLog

/// **Polkadot connector — the Substrate relay-chain implementation.**
///
/// A FULLY INDEPENDENT module for `.polkadot`: its own
/// `state_getStorage` native-DOT read against the `System::Account`
/// storage map, its own SCALE `AccountInfo` decode, and its own
/// keyless Statescan transfers history. It owns its request shapes +
/// parsing end-to-end and dispatches the JSON-RPC native read through
/// the shared `RPCClient` actor (rotation + rate-limit +
/// circuit-breaking + ConcurrencyGate) — never a raw `URLSession` for
/// the balance path. Endpoints come from
/// `RPCRegistry.endpoints(for: .polkadot)` (rpc.polkadot.io →
/// OnFinality).
///
/// **Ported verbatim-faithful from `PolkadotChainAdapter`
/// (LongTailAdapters) + `LongTailTransactionAdapters.fetchPolkadot`**
/// — same storage-key construction, same `callJSONStringOrNull`
/// `null`-is-unfunded handling, same u128-LE-at-offset-16 free-balance
/// decode ÷ 10^10, same Statescan `/accounts/{addr}/transfers`
/// zero-based pagination, same `{blockHeight}-{extrinsicIndex}`
/// extrinsic id, same DOT-only `isNativeAsset` gate. The only
/// re-shaping is at the boundary: this connector returns the
/// protocol's `ChainAccountSummary` / `[TransactionEvent]` directly.
///
/// **Why Substrate is its own world.** Polkadot's runtime RPC has no
/// "balanceOf(address)" — balances live in a SCALE-encoded storage
/// trie keyed by `twox128(pallet) ‖ twox128(storage) ‖
/// blake2_128(accountId) ‖ accountId`. The connector builds that key
/// from the SS58-decoded `AccountId32`, reads the raw storage blob,
/// and hand-decodes the `AccountData.free` field. The runtime also
/// can't serve "transactions for address" (that's an indexer
/// concern), so history GETs Statescan's keyless transfers API
/// directly — the same direct-indexer pattern the NEAR adapters use,
/// until an indexer slot exists in `RPCRegistry`.
///
/// **No token layer.** Polkadot's fungible assets (USDC, …) live on
/// the **Asset Hub** parachain (`assets.account` storage), not the
/// relay chain — and Asset Hub has no endpoint registered in
/// `RPCRegistry` yet. The existing `RealRPCBalanceScanner` contributes
/// only the native DOT ticker for `.polkadot` (see its `default:`
/// branch), so this connector's `fetchTokenBalances` faithfully
/// returns `[]` rather than fabricating an Asset Hub read it cannot
/// route. When the Asset Hub endpoint lands, the token read drops in
/// here (PolkadotAssetRegistry already ships the asset table).
struct PolkadotConnector: ChainConnector {
    let chain: SupportedChain = .polkadot
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "polkadot-connector")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    // MARK: - Native balance

    /// Native DOT balance via `state_getStorage` against the
    /// `System::Account` storage map. Ported verbatim from
    /// `PolkadotChainAdapter.fetchAccountSummary`.
    ///
    /// **Storage key (Substrate convention):**
    ///   `twox128("System") ‖ twox128("Account") ‖ blake2_128(accountId) ‖ accountId`
    ///
    /// **Response (AccountInfo SCALE):** a 4×u32 header
    /// (`nonce`/`consumers`/`providers`/`sufficients` = 16 bytes) then
    /// `AccountData { free: u128, reserved: u128, frozen: u128, flags:
    /// u128 }`. The first 16 bytes of `data` (offset 16) are the
    /// **free** balance in plancks → ÷ 10^10 = DOT.
    ///
    /// A `null` result (the account has NO `System::Account` entry —
    /// never funded, or reaped below the existential deposit) is the
    /// normal ZERO-balance answer, NOT an error: `callJSONStringOrNull`
    /// maps it to `nil` and the connector returns a clean zero summary
    /// with no rotation and no error log. A genuine endpoint failure
    /// (network, throttle, malformed body) still throws → rotates →
    /// logs; only `.cancelled` propagates.
    func fetchNativeBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        // 1. SS58 decode → AccountId32. A non-Polkadot / malformed
        //    address is a clean zero (never a throw): the caller's
        //    address is validated upstream, and a decode miss here can
        //    only mean "not this network," which holds no DOT.
        guard let accountId = SS58.decodeAccountId(address) else {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }

        // 2. Storage key: twox128(System) ‖ twox128(Account) ‖
        //    blake2_128_concat(accountId).
        var key: [UInt8] = []
        key.append(contentsOf: Twox.twox128(Array("System".utf8)))
        key.append(contentsOf: Twox.twox128(Array("Account".utf8)))
        key.append(contentsOf: BLAKE2b.hash(accountId, outlen: 16))
        key.append(contentsOf: accountId)
        let keyHex = "0x" + key.map { String(format: "%02x", $0) }.joined()

        // 3. state_getStorage through the shared client — positional
        //    params, so the standard JSON-RPC path applies (10 s
        //    timeout, rpc.polkadot.io → OnFinality rotation, rate
        //    limiter, circuit breaker). `callJSONStringOrNull` returns
        //    `nil` for a JSON `null` result (unfunded account) so it
        //    never throws the "result was not a string" miss.
        let resultStr: String?
        do {
            resultStr = try await client.callJSONStringOrNull(
                chain: chain,
                method: "state_getStorage",
                params: [keyHex]
            )
        } catch {
            if case .cancelled = error { throw error }
            Self.log.error("Polkadot balance fetch failed for \(address, privacy: .private): \(String(describing: error), privacy: .public)")
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }

        // 4. `nil` (null storage → never used) or a non-hex string ⇒
        //    zero. Only a proper "0x…" hex blob carries an AccountInfo.
        guard let resultStr, resultStr.hasPrefix("0x") else {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }
        let hex = String(resultStr.dropFirst(2))
        guard let bytes = Self.hexBytes(hex), bytes.count >= 32 else {
            return ChainAccountSummary(nativeBalance: 0, isUsed: false)
        }

        // 5. Decode `data.free` u128 at offset 16 (skip the 4×u32 =
        //    16-byte AccountInfo header). Plancks ÷ 10^10 → DOT.
        let freeBytes = Array(bytes[16..<32])
        let freePlanck = Self.decodeU128LE(freeBytes)
        let dot = freePlanck / Self.planckPerDot
        return ChainAccountSummary(nativeBalance: dot, isUsed: dot > 0)
    }

    // MARK: - Token balances

    /// Polkadot's relay chain has no fungible-token layer this
    /// connector can route. Its assets (USDC, …) live on the **Asset
    /// Hub** parachain under `assets.account` storage, which needs a
    /// separate RPC endpoint that isn't registered in `RPCRegistry`
    /// yet — the existing `RealRPCBalanceScanner` contributes only the
    /// native DOT ticker for `.polkadot`. Returning `[]` mirrors that
    /// honest scope (Rule #2 §A.7) and never fabricates an Asset Hub
    /// read. `PolkadotAssetRegistry` already ships the asset table for
    /// when the Asset Hub endpoint lands; the read drops in here then.
    func fetchTokenBalances(address: String, customContracts: [String]) async -> [TokenBalance] {
        []
    }

    // MARK: - Transaction history (Statescan transfers)

    /// Keyless Statescan transfers indexer — the relay-chain runtime
    /// RPC can't serve "transactions for address."
    private static let statescanHost = "https://polkadot-api.statescan.io"

    /// DOT history via Statescan's keyless `/accounts/{addr}/transfers`
    /// API, paged newest-first. Ported verbatim from
    /// `LongTailTransactionAdapters.fetchPolkadot`.
    ///
    /// **Item shape:** `{ indexer: { blockHeight, blockTime (ms),
    /// extrinsicIndex }, from, to, balance (plancks string),
    /// isNativeAsset }`. The feed identity is the canonical Substrate
    /// extrinsic id `{blockHeight}-{extrinsicIndex}` — the id every
    /// Polkadot explorer uses in its URLs.
    ///
    /// **Pagination:** zero-based `page` + `page_size` (max 100). Pages
    /// run sequentially until `limit` events (the per-chain
    /// full-history cap — logged when hit), a short page (history
    /// exhausted), or a mid-pagination failure (which keeps the pages
    /// already fetched). Only `.cancelled` aborts the whole walk;
    /// `customContracts` is unused (relay-chain DOT is native-only,
    /// non-native asset rows are dropped by the `isNativeAsset` gate).
    func fetchHistory(address: String, limit: Int, customContracts: [String]) async throws -> [TransactionEvent] {
        let pageSize = min(limit, 100)
        var events: [TransactionEvent] = []
        var page = 0
        pageLoop: while events.count < limit {
            if Task.isCancelled { throw RPCError.cancelled }
            var components = URLComponents(string: Self.statescanHost)
            components?.path = "/accounts/\(address)/transfers"
            components?.queryItems = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: String(pageSize)),
            ]
            guard let url = components?.url else { break }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw RPCError.cancelled
            } catch {
                if page == 0 { throw error }
                Self.log.error("Polkadot history page \(page, privacy: .public) failed — keeping \(events.count, privacy: .public) events: \(String(describing: error), privacy: .public)")
                break
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                if page == 0 {
                    Self.log.error("Polkadot history page 0 returned non-2xx for \(self.chain.rawValue, privacy: .public)")
                    break
                }
                Self.log.error("Polkadot history page \(page, privacy: .public) returned non-2xx — keeping \(events.count, privacy: .public) events")
                break
            }
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let transfers = root["items"] as? [[String: Any]] else {
                break
            }
            if transfers.isEmpty { break }
            events.reserveCapacity(min(events.count + transfers.count, limit))
            for transfer in transfers {
                if events.count >= limit {
                    // Honest bound: the caller's full-history cap.
                    Self.log.info("Polkadot history hit the \(limit, privacy: .public)-event cap — older rows not fetched this scan")
                    break pageLoop
                }
                guard let indexer = transfer["indexer"] as? [String: Any],
                      let blockHeight = (indexer["blockHeight"] as? NSNumber)?.int64Value,
                      let from = transfer["from"] as? String,
                      let to = transfer["to"] as? String,
                      let balanceStr = transfer["balance"] as? String,
                      let plancks = Decimal(string: balanceStr) else {
                    continue
                }
                // Relay-chain DOT only — skip (rare) non-native asset
                // rows rather than mislabel them as DOT.
                if let isNative = transfer["isNativeAsset"] as? Bool, !isNative {
                    continue
                }
                let extrinsicIndex = (indexer["extrinsicIndex"] as? NSNumber)?.intValue ?? 0
                let extrinsicId = "\(blockHeight)-\(extrinsicIndex)"
                // Plancks → DOT (10 decimals).
                let amount = plancks / Self.scale(decimals: 10)
                let blockTimeMs = (indexer["blockTime"] as? NSNumber)?.doubleValue ?? 0
                let occurredAt = Date(timeIntervalSince1970: blockTimeMs / 1000)

                let direction: TransactionDirection
                let counterparty: String
                if from == address && to == address {
                    direction = .internal
                    counterparty = ""
                } else if from == address {
                    direction = .outgoing
                    counterparty = to
                } else if to == address {
                    direction = .incoming
                    counterparty = from
                } else {
                    continue
                }

                events.append(TransactionEvent(
                    chain: chain,
                    address: address,
                    txHash: extrinsicId,
                    direction: direction,
                    amount: amount,
                    tokenSymbol: "DOT",
                    tokenContract: nil,
                    blockNumber: blockHeight,
                    occurredAt: occurredAt,
                    // Failed transfers don't emit Transfer events, so
                    // everything Statescan lists here executed.
                    status: .confirmed,
                    counterparty: counterparty,
                    fee: nil
                ))
            }
            if transfers.count < pageSize { break } // history exhausted
            page += 1
        }
        return events
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - SCALE / hex helpers (ported from PolkadotChainAdapter)

    /// 10^10 — plancks per DOT.
    private static let planckPerDot: Decimal = {
        var n = Decimal(1)
        for _ in 0..<10 { n *= 10 }
        return n
    }()

    /// Parse an even-length hex string (no `0x`) → bytes. `nil` on an
    /// odd length or a non-hex digit.
    private static func hexBytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<next], radix: 16) else { return nil }
            result.append(b)
            i = next
        }
        return result
    }

    /// Decode a little-endian unsigned integer (u128 here) → `Decimal`.
    private static func decodeU128LE(_ bytes: [UInt8]) -> Decimal {
        var n = Decimal(0)
        var place = Decimal(1)
        let b256 = Decimal(256)
        for byte in bytes {
            n += Decimal(Int(byte)) * place
            place *= b256
        }
        return n
    }

    /// 10^decimals as a `Decimal`.
    private static func scale(decimals: Int) -> Decimal {
        var result = Decimal(1)
        for _ in 0..<decimals { result *= 10 }
        return result
    }
}
