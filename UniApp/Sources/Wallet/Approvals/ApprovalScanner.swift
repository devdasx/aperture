import Foundation
import OSLog

/// Scans the active wallet's ERC-20 approvals across the EVM chains it
/// holds addresses for, ON-DEMAND, into value types (no persistence).
///
/// **The pipeline (all reused infrastructure — Rule #3 §B).**
///   1. For each EVM chain, `eth_getLogs` the ERC-20 `Approval` event
///      filtered by `topic0 = APPROVAL_TOPIC` and `topic1 = owner`
///      (the wallet's EVM address, left-padded to a 32-byte word). This
///      mirrors `EthereumConnector.fetchTokenTransfers`'s bounded,
///      chunked, parallel `eth_getLogs` shape — `eth_blockNumber` →
///      bounded lookback split into ≤`maxLogRange` sub-ranges fired in
///      parallel through the shared `RPCClient` (rate-limited, fallback-
///      rotated, circuit-broken).
///   2. Collect the unique `(token contract, spender)` pairs from those
///      logs (spender = `topic2`, unpadded; token = the log's `address`).
///   3. For each pair, read the LIVE allowance with `eth_call` for
///      `allowance(owner, spender)` (reusing `SwapAllowance.read` /
///      `SwapEVMABI.allowanceCallData`). The log only proves an approval
///      *happened*; the live `eth_call` proves what it is NOW. Keep only
///      allowances strictly greater than zero.
///
/// **Honesty (Rule #16).** A chain whose log scan fails is skipped (its
/// approvals simply don't appear) rather than fabricated; a fully-failed
/// scan surfaces as an error in the UI, never an empty "no approvals"
/// that could mislead. Token symbols/decimals come from the registry (or
/// the user's custom tokens); an unknown token shows its short contract
/// address, never an invented name. Spenders are shown as addresses.
///
/// **Cancellation.** Honors `Task.cancellation` at every await boundary
/// (and `RPCClient` maps `URLError.cancelled` → `RPCError.cancelled`), so
/// navigating away mid-scan aborts cleanly without poisoning circuit
/// breakers.
enum ApprovalScanner {

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "approval-scanner")

    /// ERC-20 `Approval(address indexed owner, address indexed spender,
    /// uint256 value)` topic-0 = keccak256 of that signature. Canonical
    /// constant (live-verified) — the same one Etherscan / every EVM
    /// indexer uses to find approvals.
    static let approvalTopic = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"

    /// One `eth_getLogs` lookback window, in blocks. Approvals are
    /// long-lived (an `approve` set months ago is still live), but a live
    /// `allowance` read in step 3 is what's authoritative — the log scan
    /// only needs to surface the spenders the wallet has interacted with
    /// recently. A bounded window keeps the scan fast and within public
    /// nodes' `eth_getLogs` span limits. Matches `EthereumConnector`'s
    /// 50k-block (~7 days on Ethereum) reference window.
    private static let scanBlockRange: Int64 = 50_000

    /// Per-`eth_getLogs`-call block cap. Public EVM nodes reject spans
    /// over ~10k blocks, so the lookback is split into ≤10k sub-ranges
    /// fired in parallel — same constant + chunking as `EthereumConnector`.
    private static let maxLogRange: Int64 = 10_000

    /// Scan every EVM chain in `chains` for the owner's non-zero ERC-20
    /// approvals. `walletAddresses` maps each chain to the wallet's
    /// address on it (EVM addresses are shared across EVM chains, but the
    /// map is per-chain so the caller controls exactly what's scanned).
    /// Non-EVM chains are skipped. Results are deduplicated and sorted
    /// (chain display name, then token symbol, then spender) for a stable
    /// list. Returns `[]` only when there are genuinely no non-zero
    /// approvals across every scanned chain; a transport failure on a
    /// chain skips that chain rather than blanking the rest.
    static func scan(
        walletAddresses: [SupportedChain: String],
        chains: [SupportedChain],
        client: RPCClient = .shared
    ) async -> [TokenApproval] {
        var all: [TokenApproval] = []

        for chain in chains where chain.family == .evm {
            if Task.isCancelled { return all }
            guard let owner = walletAddresses[chain], !owner.isEmpty else { continue }
            let chainApprovals = await scanChain(owner: owner, chain: chain, client: client)
            all.append(contentsOf: chainApprovals)
        }

        // Stable, human-friendly ordering.
        return all.sorted { lhs, rhs in
            if lhs.chain.displayName != rhs.chain.displayName {
                return lhs.chain.displayName < rhs.chain.displayName
            }
            if lhs.tokenSymbol != rhs.tokenSymbol {
                return lhs.tokenSymbol < rhs.tokenSymbol
            }
            return lhs.spender.lowercased() < rhs.spender.lowercased()
        }
    }

    // MARK: - Per-chain

    /// Scan one EVM chain: discover `(token, spender)` pairs from
    /// `Approval` logs, then read the live allowance for each. Any
    /// transport failure degrades to fewer rows (never a fabricated one).
    private static func scanChain(
        owner: String,
        chain: SupportedChain,
        client: RPCClient
    ) async -> [TokenApproval] {
        let pairs = await discoverApprovalPairs(owner: owner, chain: chain, client: client)
        guard !pairs.isEmpty else { return [] }
        if Task.isCancelled { return [] }

        var rows: [TokenApproval] = []
        rows.reserveCapacity(pairs.count)
        // Sequential reads through the shared RPCClient — the rate limiter
        // + ConcurrencyGate bound throughput either way; sequential keeps
        // the fan-out modest and the cancellation checks frequent.
        for pair in pairs {
            if Task.isCancelled { return rows }
            guard let allowanceHex = await SwapAllowance.read(
                token: pair.token, owner: owner, spender: pair.spender, chain: chain
            ) else { continue }
            guard isPositive(allowanceHex) else { continue }

            let meta = tokenMetadata(contract: pair.token, chain: chain)
            rows.append(TokenApproval(
                tokenSymbol: meta.symbol,
                tokenContract: pair.token,
                spender: pair.spender,
                allowanceRaw: allowanceHex,
                decimals: meta.decimals,
                chain: chain,
                isUnlimited: isUnlimited(allowanceHex)
            ))
        }
        return rows
    }

    /// A discovered `(token contract, spender)` pair the owner approved.
    private struct ApprovalPair: Hashable {
        let token: String
        let spender: String
    }

    /// `eth_getLogs` the `Approval` event over a bounded, chunked,
    /// parallel block range filtered by `topic1 = owner`. Returns the
    /// unique `(token, spender)` pairs. Mirrors
    /// `EthereumConnector.fetchTokenTransfers`'s range-splitting +
    /// parallel `TaskGroup` shape. A chunk that fails is skipped.
    private static func discoverApprovalPairs(
        owner: String,
        chain: SupportedChain,
        client: RPCClient
    ) async -> [ApprovalPair] {
        guard let latestBlock = await latestBlock(chain: chain, client: client) else {
            return []
        }
        let floorBlock = max(0, latestBlock - scanBlockRange)

        var blockRanges: [(from: String, to: String)] = []
        var hi = latestBlock
        while hi >= floorBlock {
            let lo = max(floorBlock, hi - maxLogRange + 1)
            blockRanges.append((from: "0x" + String(lo, radix: 16), to: "0x" + String(hi, radix: 16)))
            if lo == 0 { break }
            hi = lo - 1
        }

        let ownerTopic = padTopic(owner)
        var pairs: Set<ApprovalPair> = []

        await withTaskGroup(of: [ApprovalPair]?.self) { group in
            for range in blockRanges {
                group.addTask {
                    if Task.isCancelled { return nil }
                    guard let raw = try? await fetchApprovalLogs(
                        from: range.from, to: range.to, ownerTopic: ownerTopic,
                        chain: chain, client: client
                    ) else { return nil }
                    return extractPairs(raw, owner: owner)
                }
            }
            for await result in group {
                if let chunk = result { pairs.formUnion(chunk) }
            }
        }
        return Array(pairs)
    }

    /// One `eth_getLogs` call for the `Approval` event, filtered by
    /// `topic0 = approvalTopic` and `topic1 = ownerTopic` over a single
    /// block sub-range. The `address` filter is intentionally omitted so
    /// EVERY ERC-20 the owner approved is discovered (we don't know the
    /// token set in advance — that's the whole point of scanning logs).
    private static func fetchApprovalLogs(
        from fromBlock: String,
        to toBlock: String,
        ownerTopic: String,
        chain: SupportedChain,
        client: RPCClient
    ) async throws -> [[String: Any]] {
        // topics[0] = Approval signature, topics[1] = owner; topics[2]
        // (spender) left unconstrained (`nil`) so all spenders match.
        let topics: [String?] = [approvalTopic, ownerTopic, nil]
        let filter: [String: Sendable] = [
            "fromBlock": fromBlock,
            "toBlock": toBlock,
            "topics": topics,
        ]
        let data = try await client.callJSONResultData(
            chain: chain, method: "eth_getLogs", params: [filter]
        )
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    /// Project `eth_getLogs` rows into unique `(token, spender)` pairs.
    /// The token contract is the log's `address`; the spender is
    /// `topics[2]` unpadded. Self-approvals (spender == owner — a no-op
    /// some tokens emit) are dropped.
    private static func extractPairs(_ logs: [[String: Any]], owner: String) -> [ApprovalPair] {
        var out: [ApprovalPair] = []
        out.reserveCapacity(logs.count)
        let lowerOwner = owner.lowercased()
        for entry in logs {
            guard let topics = entry["topics"] as? [String], topics.count >= 3,
                  let token = entry["address"] as? String else { continue }
            let spender = unpadTopic(topics[2])
            guard !spender.isEmpty, spender.lowercased() != lowerOwner else { continue }
            out.append(ApprovalPair(token: token, spender: spender))
        }
        return out
    }

    // MARK: - RPC helpers

    /// `eth_blockNumber` → latest block height. `nil` on failure (the
    /// chain is then skipped honestly rather than scanned from block 0).
    private static func latestBlock(chain: SupportedChain, client: RPCClient) async -> Int64? {
        guard let hex = try? await client.callJSONString(
            chain: chain, method: "eth_blockNumber", params: []
        ) else { return nil }
        let stripped = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        return Int64(stripped, radix: 16)
    }

    // MARK: - Token metadata

    /// Resolve `(symbol, decimals)` for a contract from the chain's
    /// registry (the curated `(symbol, network)` table). An unknown token
    /// gets its short contract as the "symbol" and 18 decimals (the EVM
    /// standard) — honest, never an invented ticker (Rule #16).
    private static func tokenMetadata(contract: String, chain: SupportedChain) -> (symbol: String, decimals: Int) {
        let lower = contract.lowercased()
        if let entry = EVMTokenRegistry.tokens(for: chain).first(where: { $0.contract.lowercased() == lower }) {
            return (entry.symbol, entry.decimals)
        }
        return (shortContract(contract), 18)
    }

    // MARK: - Allowance value helpers

    /// Is the raw allowance word strictly greater than zero? Compared as
    /// big-endian bytes (a u256 overflows `Decimal`) — any non-zero
    /// nibble means a live allowance.
    private static func isPositive(_ hex: String) -> Bool {
        let stripped = SwapEVMABI.strip0x(hex)
        return stripped.contains { $0 != "0" }
    }

    /// Is the raw allowance word the uint256 max (the "unlimited"
    /// approval)? Compares against 64 `f` nibbles after trimming leading
    /// zeros — robust to the `0x` prefix and to a node that left-pads to
    /// fewer/more than 64 chars.
    private static func isUnlimited(_ hex: String) -> Bool {
        var stripped = SwapEVMABI.strip0x(hex)
        while stripped.first == "0" { stripped.removeFirst() }
        // uint256 max = 64 `f` nibbles. Treat anything that is all-`f`
        // and ≥ 64 nibbles as unlimited (some tokens approve 2^256-1).
        return stripped.count >= 64 && stripped.allSatisfy { $0 == "f" }
    }

    // MARK: - Topic / address helpers (ported from EthereumConnector)

    /// Left-pad a 20-byte EVM address to a 32-byte topic word, lowercased
    /// + `0x`-prefixed — the form `eth_getLogs` matches `topic1` against.
    private static func padTopic(_ address: String) -> String {
        let stripped = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        let padded = String(repeating: "0", count: max(0, 64 - stripped.count)) + stripped
        return "0x" + padded.lowercased()
    }

    /// Recover the trailing 20-byte address from a 32-byte topic word.
    private static func unpadTopic(_ topic: String) -> String {
        let stripped = topic.hasPrefix("0x") ? String(topic.dropFirst(2)) : topic
        if stripped.count >= 40 { return "0x" + String(stripped.suffix(40)) }
        return ""
    }

    /// `0x1234…ABCD` short form for a contract/address with no registry
    /// entry — shown verbatim, never replaced with an invented label.
    private static func shortContract(_ addr: String) -> String {
        let stripped = addr.hasPrefix("0x") ? String(addr.dropFirst(2)) : addr
        if stripped.count >= 10 {
            return "0x" + String(stripped.prefix(4)) + "…" + String(stripped.suffix(4))
        }
        return addr
    }
}
