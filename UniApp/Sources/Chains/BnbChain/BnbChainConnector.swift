import Foundation
import OSLog

/// **BNB Chain (BSC) connector — a FULLY INDEPENDENT EVM module for `.bnbChain`.**
///
/// Its own `eth_getBalance`, its own Multicall3 `balanceOf` token
/// batching, its own `eth_getLogs` token-transfer history. It owns its
/// request shapes + parsing end-to-end and dispatches every call through
/// the shared `RPCClient` actor (rotation + rate-limit + circuit-breaking
/// + ConcurrencyGate) — never a raw `URLSession` for the JSON-RPC calls.
/// Endpoints come from `RPCRegistry.endpoints(for: .bnbChain)`
/// (`bsc-rpc.publicnode.com` primary + Binance dataseeds + 1rpc).
///
/// **Copied from `EthereumConnector` (the EVM reference)** with the
/// `.bnbChain` knobs swapped — the duplication is intentional (user
/// direction): one chain's quirk never leaks into a sibling. Ported
/// verbatim-faithful from `EVMChainAdapter` + `EVMTransactionAdapter`:
/// same `eth_getBalance` 18-decimals native, same Multicall3 `aggregate3`
/// ABI codec (Multicall3 is deployed at the canonical address on BSC —
/// verified live), same chunked contract-scoped `eth_getLogs`.
///
/// **The one BNB-specific difference from Ethereum: no native history.**
/// BSC has NO public Blockscout instance Aperture trusts
/// (`blockscoutHost(for: .bnbChain)` returns `nil` in
/// `EVMTransactionAdapter`; the official explorer bscscan.com is
/// key-only), and native BNB transfers don't emit `Transfer` logs, so
/// `eth_getLogs` can't see them. `fetchHistory` therefore returns ONLY
/// the ERC-20 (BEP-20) `Transfer` rows — the native send rows are
/// honestly omitted rather than fabricated, exactly as
/// `EVMTransactionAdapter.fetchNativeTransactions` returns `[]` for BSC.
/// Token balances, native balance, and token history all work fully.
///
/// Per-chain knobs (vs. the Ethereum template):
/// - `chain` → `.bnbChain`
/// - native history → omitted (no Blockscout host)
/// - `scanBlockRange` / `maxLogRange` / `getLogsAddressChunk` →
///   identical to Ethereum (publicnode's BSC node enforces the same
///   ≤10k-block / ≤5-contract `eth_getLogs` limits — verified live).
struct BnbChainConnector: ChainConnector {
    let chain: SupportedChain = .bnbChain
    let client: RPCClient

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "bnbchain-connector")

    init(client: RPCClient = .shared) {
        self.client = client
    }

    // MARK: - Native balance

    /// Native BNB balance + used-address flag. Ported from
    /// `EVMChainAdapter.fetchAccountSummary` /
    /// `fetchNativeBalance` / `fetchTransactionCount`.
    ///
    /// `eth_getBalance` returns hex-encoded wei → divided by 10^18.
    /// `eth_getTransactionCount` (nonce) > 0 OR balance > 0 ⇒ "used".
    /// The nonce read is best-effort: if it fails on a fallback while
    /// the balance read succeeded, the summary is still honest (balance
    /// from the working endpoint, `isUsed` from the balance signal).
    func fetchNativeBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        let hexString = try await client.callJSONString(
            chain: chain,
            method: "eth_getBalance",
            params: [address, "latest"]
        )
        guard let wei = Self.decimalFromHex(hexString) else {
            throw .decodingFailed("Failed to parse hex balance: \(hexString)")
        }
        let balance = wei / Self.weiPerEther

        let nonce = (try? await fetchTransactionCount(address: address)) ?? 0
        let isUsed = nonce > 0 || balance > 0
        return ChainAccountSummary(nativeBalance: balance, isUsed: isUsed)
    }

    /// `eth_getTransactionCount` (nonce) at the latest block.
    private func fetchTransactionCount(address: String) async throws(RPCError) -> Int {
        let hexString = try await client.callJSONString(
            chain: chain,
            method: "eth_getTransactionCount",
            params: [address, "latest"]
        )
        let stripped = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard let nonce = Int(stripped, radix: 16) else {
            throw .decodingFailed("Failed to parse hex nonce: \(hexString)")
        }
        return nonce
    }

    // MARK: - Token balances

    /// BEP-20 balances for the chain's registry tokens + the user's
    /// `customContracts`, in ONE Multicall3 `aggregate3` `eth_call`
    /// (ported from `EVMChainAdapter.fetchTokenBalancesBatched`).
    ///
    /// Non-throwing per the `ChainConnector` contract: a transport-level
    /// failure degrades to `[]` (no token rows), never a fabricated set
    /// of zeros — pricing/persistence stays in the coordinator, which
    /// preserves the user's stored balances when a refresh yields no
    /// rows. Only POSITIVE balances are returned (Rule #2 §A.7).
    func fetchTokenBalances(address: String, customContracts: [String]) async -> [TokenBalance] {
        // Build the (contract, symbol, name, decimals) work list:
        // registry tokens first, then the user's custom contracts
        // (deduplicated against the registry by lowercased contract).
        let registry = EVMTokenRegistry.tokens(for: chain)
        var specs: [TokenSpec] = registry.map {
            TokenSpec(contract: $0.contract, symbol: $0.symbol, name: $0.name, decimals: $0.decimals)
        }
        let known = Set(registry.map { $0.contract.lowercased() })
        for contract in customContracts where !known.contains(contract.lowercased()) {
            // Custom contracts ship without registry metadata here; the
            // coordinator's custom-token pass owns symbol/name/decimals.
            // The connector still reads their balance so a user-added
            // token surfaces. Decimals default to 18 (EVM standard) —
            // the canonical amount is re-derived downstream if needed.
            specs.append(TokenSpec(contract: contract, symbol: Self.shortContract(contract), name: contract, decimals: 18))
        }
        guard !specs.isEmpty else { return [] }

        let contracts = specs.map { $0.contract }
        var raw: [Decimal?]
        do {
            raw = try await fetchTokenBalancesBatched(holder: address, contracts: contracts)
        } catch {
            if case .cancelled = error { return [] }
            Self.log.error("token balance scan failed on \(self.chain.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
        // Defensive: a malformed Multicall3 response can decode short.
        if raw.count < contracts.count {
            raw.append(contentsOf: [Decimal?](repeating: nil, count: contracts.count - raw.count))
        }

        let now = Date()
        var rows: [TokenBalance] = []
        rows.reserveCapacity(specs.count)
        for (i, spec) in specs.enumerated() {
            let rawAmount = raw[i] ?? 0
            let amount = rawAmount / Self.pow10(spec.decimals)
            guard amount > 0 else { continue }
            rows.append(TokenBalance(
                chain: chain,
                address: address,
                contract: spec.contract,
                symbol: spec.symbol,
                name: spec.name,
                decimals: spec.decimals,
                amount: amount,
                fiatBalance: nil,           // pricing stays in the coordinator
                fiatCurrencyCode: "",       // coordinator stamps the active currency
                lastUpdated: now
            ))
        }
        return rows
    }

    /// One discovered token's metadata + contract — the connector's
    /// internal work item before a balance lands.
    private struct TokenSpec: Sendable {
        let contract: String
        let symbol: String
        let name: String
        let decimals: Int
    }

    /// Multicall3 `aggregate3((address,bool,bytes)[])` batched
    /// `balanceOf` read for N contracts in ONE `eth_call`. Ported from
    /// `EVMChainAdapter.fetchTokenBalancesBatched` — same selector
    /// `0x82ad56cb`, same Multicall3 address (deployed identically on
    /// BSC — verified live), same per-token sequential fallback when
    /// Multicall3 isn't deployed (empty bytes / deterministic JSON-RPC
    /// error). Returns one `Decimal?` per contract in input order; `nil`
    /// = that token's call reverted / returned no data.
    private func fetchTokenBalancesBatched(
        holder: String,
        contracts: [String]
    ) async throws(RPCError) -> [Decimal?] {
        guard !contracts.isEmpty else { return [] }

        let callData = Self.encodeMulticall3Aggregate3(holder: holder, tokenContracts: contracts)
        let txObject: [String: Sendable] = ["to": Self.multicall3Address, "data": callData]
        let hexString: String
        do {
            hexString = try await client.callJSONString(
                chain: chain,
                method: "eth_call",
                params: [txObject, "latest"]
            )
        } catch {
            // Only fall back to per-token reads on a deterministic
            // JSON-RPC error (Multicall3 not deployed / reverting on
            // this chain). Everything else — cancelled, rate-limited,
            // network, all-endpoints-failed — rethrows: firing N more
            // calls at a fleet that is offline / throttling us would
            // amplify traffic ~25× at the worst moment, and swallowing
            // it would convert an outage into silent all-zero balances.
            if case .rpcError = error {
                return try await fetchTokenBalancesSequentialFallback(holder: holder, contracts: contracts)
            }
            throw error
        }
        let stripped = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard !stripped.isEmpty else {
            return try await fetchTokenBalancesSequentialFallback(holder: holder, contracts: contracts)
        }
        return Self.decodeMulticall3Result(stripped, expectedCount: contracts.count)
    }

    /// Per-token `eth_call balanceOf` fan-out (Multicall3 absent).
    /// Ported from `EVMChainAdapter.fetchTokenBalancesSequentialFallback`
    /// — parallel `withTaskGroup`, results written back at each token's
    /// INPUT index so the order matches `contracts`. A failed token →
    /// `nil`; if EVERY token failed, the last error rethrows (an outage
    /// surfaces as an error, never a wallet that suddenly holds nothing).
    /// Cancellation aborts the whole fan-out.
    private func fetchTokenBalancesSequentialFallback(
        holder: String,
        contracts: [String]
    ) async throws(RPCError) -> [Decimal?] {
        guard !contracts.isEmpty else { return [] }

        enum Outcome: Sendable {
            case success(Decimal)
            case failure(RPCError)
        }
        var slots: [Outcome?] = Array(repeating: nil, count: contracts.count)

        await withTaskGroup(of: (Int, Outcome).self) { group in
            for (index, contract) in contracts.enumerated() {
                group.addTask {
                    do {
                        let balance = try await self.fetchTokenBalance(holder: holder, contract: contract)
                        return (index, .success(balance))
                    } catch {
                        return (index, .failure((error as? RPCError) ?? .allEndpointsFailed(self.chain)))
                    }
                }
            }
            for await (index, outcome) in group {
                slots[index] = outcome
            }
        }

        var results: [Decimal?] = []
        results.reserveCapacity(contracts.count)
        var lastError: RPCError?
        for slot in slots {
            switch slot {
            case .success(let value):
                results.append(value)
            case .failure(let error):
                if case .cancelled = error { throw error }
                lastError = error
                results.append(nil)
            case .none:
                results.append(nil)
            }
        }
        if let lastError, !results.isEmpty, results.allSatisfy({ $0 == nil }) {
            throw lastError
        }
        return results
    }

    /// Single BEP-20 `balanceOf` via `eth_call`. Raw integer balance
    /// (token base units); `0` when the call returns empty data
    /// (contract not deployed on this chain / reverted).
    private func fetchTokenBalance(holder: String, contract: String) async throws(RPCError) -> Decimal {
        let callData = EVMTokenRegistry.balanceOfCallData(holder: holder)
        let txObject: [String: Sendable] = ["to": contract, "data": callData]
        let hexString = try await client.callJSONString(
            chain: chain,
            method: "eth_call",
            params: [txObject, "latest"]
        )
        let stripped = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard !stripped.isEmpty, let raw = Self.decimalFromHex(hexString) else {
            return 0
        }
        return raw
    }

    // MARK: - Transaction history

    /// BEP-20 `Transfer` topic-0 — `keccak256("Transfer(address,address,uint256)")`.
    /// (Identical event signature to ERC-20; BEP-20 is ERC-20-compatible.)
    private static let transferTopic = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

    /// One `eth_getLogs` call's block span. BSC's publicnode tolerates
    /// the same span Ethereum's does; the per-call cap is enforced by
    /// `maxLogRange` chunking below. ~50k blocks ≈ 1.7 days on BSC
    /// (~0.75s block time — denser than Ethereum, so 50k spans less
    /// wall-clock; the row cap, not the time window, bounds the result).
    private static let scanBlockRange: Int64 = 50_000

    /// Per-`eth_getLogs`-call block cap. BSC's publicnode rejects spans
    /// over 10k blocks (`-32701 exceed maximum block range` — verified
    /// live), so the lookback is split into ≤10k sub-ranges fired in
    /// parallel.
    private static let maxLogRange: Int64 = 10_000

    /// Token contracts per `eth_getLogs` `address` array. publicnode's
    /// BSC node blocks arrays above ~5 (`-32602 … blocked parameter`).
    private static let getLogsAddressChunk = 5

    /// History = BEP-20 `Transfer` logs (`eth_getLogs`) ONLY, sorted
    /// newest-first, capped at `limit`. Ported from
    /// `EVMTransactionAdapter.fetch` minus the native path.
    ///
    /// **No native BNB rows.** BSC has no public Blockscout indexer
    /// Aperture trusts (`EVMTransactionAdapter.blockscoutHost(for:
    /// .bnbChain)` → `nil`), and native BNB transfers emit no
    /// `Transfer` logs, so `eth_getLogs` cannot surface them. The native
    /// send rows are honestly omitted (same behavior as the existing
    /// adapter), never fabricated.
    ///
    /// Token rows are gated by an allowlist (registry ∪ `customContracts`)
    /// so unsolicited airdrop spam from un-tracked contracts is dropped.
    func fetchHistory(address: String, limit: Int, customContracts: [String]) async throws -> [TransactionEvent] {
        let allowed = Self.buildAllowedContracts(chain: chain, customContracts: customContracts)
        let tokenEvents = try await fetchTokenTransfers(address: address, limit: limit, allowedContracts: allowed)
        return tokenEvents
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Token-transfer history (eth_getLogs)

    /// Lowercase set of contracts the user tracks (registry ∪ custom).
    /// Spam from contracts outside the set is dropped at parse time.
    private static func buildAllowedContracts(chain: SupportedChain, customContracts: [String]) -> Set<String> {
        var allowed: Set<String> = []
        for token in EVMTokenRegistry.tokens(for: chain) { allowed.insert(token.contract.lowercased()) }
        for contract in customContracts { allowed.insert(contract.lowercased()) }
        return allowed
    }

    /// BEP-20 `Transfer` logs via chunked, parallel, contract-scoped
    /// `eth_getLogs`. Ported from
    /// `EVMTransactionAdapter.fetchTokenTransfersViaLogs`: lookback split
    /// into ≤10k sub-ranges × {from,to} direction × ≤5-contract chunks,
    /// each fired in parallel; logs merged, sorted, capped. A chunk that
    /// fails is skipped; throws only if EVERY chunk failed.
    private func fetchTokenTransfers(
        address: String,
        limit: Int,
        allowedContracts: Set<String>
    ) async throws -> [TransactionEvent] {
        let latestBlock = try await fetchLatestBlock()
        let floorBlock = max(0, latestBlock - Self.scanBlockRange)

        var blockRanges: [(from: String, to: String)] = []
        var hi = latestBlock
        while hi >= floorBlock {
            let lo = max(floorBlock, hi - Self.maxLogRange + 1)
            blockRanges.append((from: "0x" + String(lo, radix: 16), to: "0x" + String(hi, radix: 16)))
            if lo == 0 { break }
            hi = lo - 1
        }

        let padded = Self.padTopic(address)
        let contractList = Array(allowedContracts)
        let chunks: [[String]?] = contractList.isEmpty
            ? [nil]
            : stride(from: 0, to: contractList.count, by: Self.getLogsAddressChunk).map {
                Array(contractList[$0..<min($0 + Self.getLogsAddressChunk, contractList.count)])
            }

        var allLogs: [RawLog] = []
        var anySuccess = false
        await withTaskGroup(of: [RawLog]?.self) { group in
            for range in blockRanges {
                for chunk in chunks {
                    group.addTask {
                        guard let raw = try? await self.fetchLogs(
                            from: range.from, to: range.to,
                            fromTopic: nil, toTopic: padded, contractAddresses: chunk
                        ) else { return nil }
                        return Self.extractRawLogs(raw)
                    }
                    group.addTask {
                        guard let raw = try? await self.fetchLogs(
                            from: range.from, to: range.to,
                            fromTopic: padded, toTopic: nil, contractAddresses: chunk
                        ) else { return nil }
                        return Self.extractRawLogs(raw)
                    }
                }
            }
            for await result in group {
                if let logs = result { anySuccess = true; allLogs.append(contentsOf: logs) }
            }
        }
        if !anySuccess { throw RPCError.allEndpointsFailed(chain) }

        let trimmed = Array(allLogs.sorted { $0.blockNumber > $1.blockNumber }.prefix(limit))
        var blockTimes: [Int64: Date] = [:]
        var events: [TransactionEvent] = []
        events.reserveCapacity(trimmed.count)
        let lower = address.lowercased()
        for log in trimmed {
            guard log.topics.count >= 3 else { continue }
            let contractAddr = log.contract
            if !allowedContracts.isEmpty, !allowedContracts.contains(contractAddr.lowercased()) { continue }
            let fromAddr = Self.unpadTopic(log.topics[1])
            let toAddr = Self.unpadTopic(log.topics[2])
            let amountRaw = Self.decimalFromHex(log.dataHex) ?? 0

            let direction: TransactionDirection
            let counterparty: String
            if fromAddr.lowercased() == lower && toAddr.lowercased() == lower {
                direction = .internal; counterparty = ""
            } else if toAddr.lowercased() == lower {
                direction = .incoming; counterparty = fromAddr
            } else if fromAddr.lowercased() == lower {
                direction = .outgoing; counterparty = toAddr
            } else { continue }

            let occurredAt: Date
            if let cached = blockTimes[log.blockNumber] {
                occurredAt = cached
            } else if let fetched = try? await fetchBlockTimestamp(blockNumber: log.blockNumber) {
                blockTimes[log.blockNumber] = fetched
                occurredAt = fetched
            } else {
                occurredAt = Date()
            }

            let token = EVMTokenRegistry.tokens(for: chain).first { $0.contract.lowercased() == contractAddr.lowercased() }
            let symbol = token?.symbol ?? Self.shortContract(contractAddr)
            let decimals = token?.decimals ?? 18
            let amount = amountRaw / Self.scale(decimals: decimals)

            events.append(TransactionEvent(
                chain: chain, address: address, txHash: log.txHash,
                direction: direction, amount: amount, tokenSymbol: symbol,
                tokenContract: contractAddr, blockNumber: log.blockNumber, occurredAt: occurredAt,
                status: .confirmed, counterparty: counterparty, fee: nil
            ))
        }
        return events
    }

    // MARK: - JSON-RPC plumbing

    /// `Sendable` projection of one `eth_getLogs` entry — `[[String:
    /// Any]]` is not `Sendable` and can't return from a parallel
    /// `TaskGroup` task, so each task maps to this value type in-task.
    private struct RawLog: Sendable {
        let topics: [String]
        let dataHex: String
        let txHash: String
        let blockNumber: Int64
        let contract: String
    }

    private static func extractRawLogs(_ logs: [[String: Any]]) -> [RawLog] {
        var out: [RawLog] = []
        out.reserveCapacity(logs.count)
        for log in logs {
            guard let topics = log["topics"] as? [String],
                  let dataHex = log["data"] as? String,
                  let txHash = log["transactionHash"] as? String,
                  let blockHex = log["blockNumber"] as? String,
                  let contract = log["address"] as? String else { continue }
            let blockNum = Int64(blockHex.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
            out.append(RawLog(topics: topics, dataHex: dataHex, txHash: txHash, blockNumber: blockNum, contract: contract))
        }
        return out
    }

    private func fetchLatestBlock() async throws -> Int64 {
        let hexBlock = try await client.callJSONString(chain: chain, method: "eth_blockNumber", params: [])
        let stripped = hexBlock.hasPrefix("0x") ? String(hexBlock.dropFirst(2)) : hexBlock
        return Int64(stripped, radix: 16) ?? 0
    }

    private func fetchLogs(
        from fromBlock: String,
        to toBlock: String,
        fromTopic: String?,
        toTopic: String?,
        contractAddresses: [String]? = nil
    ) async throws -> [[String: Any]] {
        let topics: [String?] = [Self.transferTopic, fromTopic, toTopic]
        var filter: [String: Sendable] = ["fromBlock": fromBlock, "toBlock": toBlock, "topics": topics]
        if let contracts = contractAddresses, !contracts.isEmpty {
            filter["address"] = contracts.map { $0.lowercased() }
        }
        let data = try await client.callJSONResultData(chain: chain, method: "eth_getLogs", params: [filter])
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    private func fetchBlockTimestamp(blockNumber: Int64) async throws -> Date {
        let hexBlock = "0x" + String(blockNumber, radix: 16)
        let data = try await client.callJSONResultData(chain: chain, method: "eth_getBlockByNumber", params: [hexBlock, false])
        guard let block = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let timestampHex = block["timestamp"] as? String else { return Date() }
        let stripped = timestampHex.hasPrefix("0x") ? String(timestampHex.dropFirst(2)) : timestampHex
        guard let ts = Int64(stripped, radix: 16) else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    // MARK: - Hex / topic helpers

    private static func padTopic(_ address: String) -> String {
        let stripped = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        let padded = String(repeating: "0", count: max(0, 64 - stripped.count)) + stripped
        return "0x" + padded.lowercased()
    }

    private static func unpadTopic(_ topic: String) -> String {
        let stripped = topic.hasPrefix("0x") ? String(topic.dropFirst(2)) : topic
        if stripped.count >= 40 { return "0x" + String(stripped.suffix(40)) }
        return topic
    }

    private static func shortContract(_ addr: String) -> String {
        let stripped = addr.hasPrefix("0x") ? String(addr.dropFirst(2)) : addr
        if stripped.count >= 10 { return "0x" + String(stripped.prefix(4)) + "…" + String(stripped.suffix(4)) }
        return addr
    }

    /// Parse a `0x…` hex string → `Decimal`. EVM balances/values are
    /// hex-encoded base-10 integers.
    static func decimalFromHex(_ hexString: String) -> Decimal? {
        var hex = hexString
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { hex.removeFirst(2) }
        if hex.isEmpty { return .zero }
        var result = Decimal(0)
        let sixteen = Decimal(16)
        for char in hex {
            guard let digit = char.hexDigitValue else { return nil }
            result = result * sixteen + Decimal(digit)
        }
        return result
    }

    private static func scale(decimals: Int) -> Decimal {
        let clamped = min(max(decimals, 0), 38)
        var result = Decimal(1)
        for _ in 0..<clamped { result *= 10 }
        return result
    }

    private static func pow10(_ n: Int) -> Decimal {
        let clamped = min(max(n, 0), 38)
        var r = Decimal(1)
        for _ in 0..<clamped { r *= 10 }
        return r
    }

    private static let weiPerEther: Decimal = {
        var result = Decimal(1)
        for _ in 0..<18 { result *= 10 }
        return result
    }()

    private static let multicall3Address = "0xcA11bde05977b3631167028862bE2a173976CA11"

    // MARK: - Multicall3 ABI codec (ported verbatim from EVMChainAdapter)

    /// Encode `aggregate3((address,bool,bytes)[])` for N `balanceOf`
    /// reads against the same holder. `allowFailure: true` so one
    /// reverted token doesn't kill the batch.
    static func encodeMulticall3Aggregate3(holder: String, tokenContracts: [String]) -> String {
        let selector = "82ad56cb"
        let outerOffset = pad32(toHex: 0x20)
        let n = tokenContracts.count
        let nHex = pad32(toHex: n)

        let holderHex = strip0xLower(holder)
        let holderPadded = padLeft(holderHex, to: 64)
        let balanceOfSelector = "70a08231"
        let balanceOfData = balanceOfSelector + holderPadded
        let bytesDataPadded = balanceOfData + String(repeating: "0", count: 128 - balanceOfData.count)

        let itemSize = 192
        let itemBoolTrue = pad32(toHex: 1)
        let itemBytesOffset = pad32(toHex: 0x60)
        let itemBytesLength = pad32(toHex: 0x24)

        var offsetsHex = ""
        for i in 0..<n {
            let off = n * 32 + i * itemSize
            offsetsHex += pad32(toHex: off)
        }
        var itemsHex = ""
        for contract in tokenContracts {
            itemsHex += padLeft(strip0xLower(contract), to: 64)
            itemsHex += itemBoolTrue
            itemsHex += itemBytesOffset
            itemsHex += itemBytesLength
            itemsHex += bytesDataPadded
        }
        return "0x" + selector + outerOffset + nHex + offsetsHex + itemsHex
    }

    /// Decode the `(bool success, bytes returnData)[]` of `aggregate3`.
    /// `nil` per item = reverted / empty / sub-word returnData. The
    /// length-word validation (≥ 32 bytes) prevents a no-code-contract's
    /// empty returndata from fabricating a phantom 1-base-unit balance.
    static func decodeMulticall3Result(_ hex: String, expectedCount: Int) -> [Decimal?] {
        guard hex.count >= 128 else { return Array(repeating: nil, count: expectedCount) }
        let lengthHex = substring(hex, from: 64, length: 64)
        guard let n = Int(lengthHex, radix: 16), n == expectedCount else {
            return Array(repeating: nil, count: expectedCount)
        }
        var results: [Decimal?] = []
        results.reserveCapacity(n)
        let arrayDataStart = 128
        for i in 0..<n {
            let offHex = substring(hex, from: arrayDataStart + i * 64, length: 64)
            guard let off = Int(offHex, radix: 16) else { results.append(nil); continue }
            let itemStart = arrayDataStart + off * 2
            guard itemStart + 192 <= hex.count else { results.append(nil); continue }
            let successHex = substring(hex, from: itemStart, length: 64)
            let success = (Int(successHex, radix: 16) ?? 0) != 0
            if !success { results.append(nil); continue }
            let lengthWordHex = substring(hex, from: itemStart + 128, length: 64)
            guard let byteLength = Int(lengthWordHex, radix: 16), byteLength >= 32, itemStart + 256 <= hex.count else {
                results.append(nil); continue
            }
            let dataHex = substring(hex, from: itemStart + 192, length: 64)
            results.append(decimalFromHex(dataHex))
        }
        return results
    }

    static func padLeft(_ s: String, to width: Int) -> String {
        if s.count >= width { return s }
        return String(repeating: "0", count: width - s.count) + s
    }

    static func strip0xLower(_ s: String) -> String {
        let core = s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
        return core.lowercased()
    }

    static func pad32(toHex value: Int) -> String { String(format: "%064x", value) }

    static func substring(_ s: String, from: Int, length: Int) -> String {
        guard from >= 0, length >= 0, from + length <= s.count else { return "" }
        let start = s.index(s.startIndex, offsetBy: from)
        let end = s.index(start, offsetBy: length)
        return String(s[start..<end])
    }
}
