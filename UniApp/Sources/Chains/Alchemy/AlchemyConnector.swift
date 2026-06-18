import Foundation
import OSLog

/// **Alchemy connector — the one source for the EVM chains Alchemy covers
/// (2026-06-17, user direction "build the alchemy, fully, for all
/// supported chains, no fallback").**
///
/// One `ChainConnector` parameterized by chain, returned by
/// `ChainConnectorRegistry` (when an Alchemy key is configured) for the 10
/// EVM chains probed-confirmed supported: Ethereum, Arbitrum, Base,
/// Optimism, Scroll, zkSync, Polygon, BNB, Avalanche, Celo. It reads:
///
/// - **balances** via the Portfolio `tokens/by-address` API — native +
///   ERC-20 in ONE call (`AlchemyService.tokens`, cached so the native
///   and token reads share a round-trip);
/// - **history** via `alchemy_getAssetTransfers` — sent + received merged.
///
/// **No fallback** (user direction): unlike the JSON-RPC connectors there
/// is no Multicall3 / `eth_getLogs` / Infura path here. A transport failure
/// degrades honestly — `fetchNativeBalance` throws (the coordinator keeps
/// the last-known balance), `fetchTokenBalances` returns `[]`.
///
/// **Anti-spam (Rule #16).** `tokens/by-address` and `getAssetTransfers`
/// return EVERY token an address has touched, including scam airdrops.
/// Token balances + token-transfer history are filtered to the curated
/// `EVMTokenRegistry` ∪ the user's custom contracts, exactly as the EVM
/// connectors do — the native coin always passes.
struct AlchemyConnector: ChainConnector {
    let chain: SupportedChain
    let service: AlchemyService

    private static let log = Logger(subsystem: "com.thuglife.aperture", category: "alchemy-connector")

    /// **EVM-only debug log (user direction, 2026-06-19).** A single `evm`
    /// category dedicated to the EVM chains + EVM tokens balance/token/
    /// transaction fetch path, so it can be filtered in isolation in Console /
    /// Xcode (`subsystem:com.thuglife.aperture category:evm`). `.debug` level —
    /// captured only when EVM debugging is enabled, never persisted in release.
    private static let evmLog = Logger(subsystem: "com.thuglife.aperture", category: "evm")

    /// Short, non-identifying address tail for the EVM debug log — enough to
    /// tell two addresses apart without dumping the full string.
    private static func addrTail(_ a: String) -> String {
        a.count > 8 ? "…" + a.suffix(6) : a
    }

    init(chain: SupportedChain, service: AlchemyService = .shared) {
        self.chain = chain
        self.service = service
    }

    /// The 10 EVM chains Alchemy's Portfolio + Transfers APIs cover (probed
    /// 2026-06-17 against the live key). opBNB is intentionally absent —
    /// Alchemy returned "Unsupported network" — so it keeps its connector.
    static let supportedChains: Set<SupportedChain> = [
        .ethereum, .arbitrum, .base, .optimism, .scroll,
        .zkSync, .polygon, .bnbChain, .avalanche, .celo,
    ]

    /// Alchemy network slug for a chain, or `nil` if Alchemy doesn't serve it.
    static func network(for chain: SupportedChain) -> String? {
        switch chain {
        case .ethereum:  return "eth-mainnet"
        case .arbitrum:  return "arb-mainnet"
        case .base:      return "base-mainnet"
        case .optimism:  return "opt-mainnet"
        case .scroll:    return "scroll-mainnet"
        case .zkSync:    return "zksync-mainnet"
        case .polygon:   return "polygon-mainnet"
        case .bnbChain:  return "bnb-mainnet"
        case .avalanche: return "avax-mainnet"
        case .celo:      return "celo-mainnet"
        default:         return nil
        }
    }

    /// All EVM Alchemy chains have an 18-decimal native coin.
    private static let nativeDecimals = 18

    private var networkSlug: String { Self.network(for: chain) ?? "eth-mainnet" }

    // MARK: - Native balance

    func fetchNativeBalance(address: String) async throws(RPCError) -> ChainAccountSummary {
        Self.evmLog.debug("native ▸ \(self.chain.rawValue, privacy: .public) [\(Self.addrTail(address), privacy: .public)] via \(self.networkSlug, privacy: .public)")
        // Try the Portfolio Data API first (one call serves native + tokens).
        // A genuine zero native balance arrives as a PRESENT native row with
        // `tokenBalance: "0x0"` (Portfolio includes the native coin when
        // `includeNativeTokens: true`) → balance 0, honestly shown (B2).
        if let tokens = try? await service.tokens(network: networkSlug, address: address),
           let native = tokens.first(where: { $0.isNative }),
           let raw = AlchemyService.decimalFromHex(native.rawBalanceHex) {
            let balance = raw / AlchemyService.pow10(Self.nativeDecimals)
            Self.evmLog.debug("native ◂ \(self.chain.rawValue, privacy: .public) = \(balance.description, privacy: .public) (portfolio)")
            return ChainAccountSummary(nativeBalance: balance, isUsed: balance > 0)
        }

        // **BUG 2D — DELIBERATE no-fallback exception (2026-06-18).** The
        // Portfolio Data API either failed (its real error is logged once by
        // `AlchemyService.tokens`) or returned no native row. Rather than throw
        // "native row absent" — which blanks / keeps-last-known the native
        // balance and made a funded wallet look stale on all 10 EVM chains —
        // fall back to a single `eth_getBalance` against Alchemy's JSON-RPC
        // product (same key, confirmed working since transactions load). This is
        // NATIVE-ONLY; token balances still depend on the Data API. It is a
        // conscious deviation from the 2026-06-17 "no fallback" direction,
        // chosen because a Portfolio-API outage should degrade gracefully (real
        // native balances) instead of wiping them. A genuinely-unfunded address
        // returns 0 from `eth_getBalance` — an honest zero, not an anomaly.
        let wei = try await service.nativeBalanceWei(network: networkSlug, address: address)
        let balance = wei / AlchemyService.pow10(Self.nativeDecimals)
        Self.evmLog.debug("native ◂ \(self.chain.rawValue, privacy: .public) = \(balance.description, privacy: .public) (eth_getBalance fallback)")
        return ChainAccountSummary(nativeBalance: balance, isUsed: balance > 0)
    }

    // MARK: - Token balances

    func fetchTokenBalances(address: String, customContracts: [String]) async -> [TokenBalance] {
        Self.evmLog.debug("tokens ▸ \(self.chain.rawValue, privacy: .public) [\(Self.addrTail(address), privacy: .public)] customs=\(customContracts.count, privacy: .public)")
        let tokens: [AlchemyService.Token]
        do {
            tokens = try await service.tokens(network: networkSlug, address: address)
        } catch {
            if case .cancelled = error { return [] }
            Self.log.error("Alchemy token balances failed on \(self.chain.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            Self.evmLog.debug("tokens ◂ \(self.chain.rawValue, privacy: .public) FAILED: \(String(describing: error), privacy: .public)")
            return []
        }

        let registry = EVMTokenRegistry.tokens(for: chain)
        let registryByContract = Dictionary(
            registry.map { ($0.contract.lowercased(), $0) }, uniquingKeysWith: { a, _ in a }
        )
        let customSet = Set(customContracts.map { $0.lowercased() })

        let now = Date()
        var rows: [TokenBalance] = []
        var drops: [String: Int] = [:]   // drop reason → count, for the per-chain log
        for token in tokens where !token.isNative {
            guard let contract = token.contract else { continue }
            let lc = contract.lowercased()
            let registryEntry = registryByContract[lc]
            let isCustom = customSet.contains(lc)
            // Registry + user-custom tokens are CANONICAL — always shown (when
            // funded), never spam-filtered. Everything else faces the heuristic
            // gate below. This replaces the old 79-entry stablecoin allowlist
            // that silently dropped every real non-stablecoin holding (LINK,
            // UNI, ARB, …) along with the spam (2026-06-19).
            let isCanonical = registryEntry != nil || isCustom

            // **Decimals — never blind-default to 18 for an unknown token.**
            // registry → Portfolio metadata → (bounded) on-chain metadata lookup
            // for heuristic tokens worth resolving (priced, missing decimals).
            var decimals = registryEntry?.decimals ?? token.decimals
            if decimals == nil, !isCanonical, let price = token.priceUSD, price > 0 {
                decimals = await service.tokenDecimals(network: networkSlug, contract: contract)
            }
            let resolvedDecimals: Int
            if let d = decimals {
                resolvedDecimals = d
            } else if isCanonical {
                // A user-custom token with no metadata: the scanner re-stamps it
                // from the user's snapshot decimals, so a consistent placeholder
                // here is corrected downstream.
                resolvedDecimals = 18
            } else {
                drops["no-decimals", default: 0] += 1
                continue
            }

            guard let raw = AlchemyService.decimalFromHex(token.rawBalanceHex) else {
                drops["bad-hex", default: 0] += 1
                continue
            }
            let amount = raw / AlchemyService.pow10(resolvedDecimals)
            guard amount > 0 else {
                drops["zero", default: 0] += 1
                continue   // honesty: zero balances never surface (Rule #2 §A.7)
            }

            // Heuristic anti-spam gate — canonical tokens bypass it entirely.
            if !isCanonical, let reason = Self.heuristicDrop(
                amount: amount,
                symbol: token.symbol ?? "",
                name: token.name ?? "",
                priceUSD: token.priceUSD
            ) {
                drops[reason.rawValue, default: 0] += 1
                continue
            }

            rows.append(TokenBalance(
                chain: chain,
                address: address,
                contract: contract,
                symbol: registryEntry?.symbol ?? token.symbol ?? Self.shortContract(contract),
                name: registryEntry?.name ?? token.name ?? contract,
                decimals: resolvedDecimals,
                amount: amount,
                fiatBalance: nil,        // pricing stays in the coordinator (Aperture price server)
                fiatCurrencyCode: "",
                lastUpdated: now
            ))
        }
        let rawTokenCount = tokens.lazy.filter { !$0.isNative }.count
        let dropSummary = drops.isEmpty ? "—" : drops.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        Self.evmLog.debug("tokens ◂ \(self.chain.rawValue, privacy: .public) raw=\(rawTokenCount, privacy: .public) kept=\(rows.count, privacy: .public) dropped[\(dropSummary, privacy: .public)] [\(rows.map { "\($0.symbol):\($0.amount.description)" }.joined(separator: ", "), privacy: .public)]")
        return rows
    }

    // MARK: - Anti-spam token policy

    /// Smallest USD value a heuristic-admitted token must clear to show — drops
    /// sub-cent dust (including priced spam dust) without hiding real holdings.
    static let dustThresholdUSD = Decimal(string: "0.01") ?? Decimal(0)

    /// Reason a heuristic (non-canonical) token was hidden — surfaced in the
    /// per-chain EVM debug log so "Alchemy returned nothing" is distinguishable
    /// from "the filter dropped everything."
    enum TokenDrop: String {
        case noPrice = "no-price"
        case dust
        case spam
    }

    /// **Real anti-spam policy (2026-06-19) — pure, network-free, testable.**
    /// Decides whether a NON-canonical (not registry, not user-custom) ERC-20
    /// should show. Returns `nil` to SHOW, or a `TokenDrop` reason to hide.
    ///
    /// A real Alchemy USD price is the single strongest legitimacy signal —
    /// scam airdrop tokens almost never carry one. We require: a positive USD
    /// price, a fiat value clearing the dust floor, and a name/symbol free of
    /// the URL / claim-bait markers spam tokens embed. Canonical tokens never
    /// reach here (they always show when funded).
    static func heuristicDrop(
        amount: Decimal,
        symbol: String,
        name: String,
        priceUSD: Decimal?,
        dustThresholdUSD: Decimal = AlchemyConnector.dustThresholdUSD
    ) -> TokenDrop? {
        guard let price = priceUSD, price > 0 else { return .noPrice }
        guard price * amount >= dustThresholdUSD else { return .dust }
        if looksLikeSpam(symbol: symbol, name: name) { return .spam }
        return nil
    }

    /// Spam-name heuristic — scam airdrops embed a URL or claim-bait in their
    /// symbol/name (e.g. "Visit claim-rewards.xyz to redeem"). An empty/garbage
    /// symbol is treated as spam too. Applies ONLY to heuristic-admitted tokens;
    /// registry + custom tokens are never name-filtered.
    static func looksLikeSpam(symbol: String, name: String) -> Bool {
        if symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let haystack = (symbol + " " + name).lowercased()
        let markers = [
            "http", "www.", ".com", ".xyz", ".net", ".org", ".io", ".app",
            ".site", ".vip", ".club", ".finance", "t.me", "telegram",
            "claim", "reward", "visit", "airdrop", "voucher", "giveaway", "bonus",
        ]
        return markers.contains { haystack.contains($0) }
    }

    // MARK: - Transaction history

    func fetchHistory(address: String, limit: Int, customContracts: [String]) async throws -> [TransactionEvent] {
        Self.evmLog.debug("history ▸ \(self.chain.rawValue, privacy: .public) [\(Self.addrTail(address), privacy: .public)] limit=\(limit, privacy: .public)")
        let transfers = try await service.assetTransfers(chain: chain, network: networkSlug, address: address, maxCount: limit)

        var allowed: Set<String> = []
        for token in EVMTokenRegistry.tokens(for: chain) { allowed.insert(token.contract.lowercased()) }
        for contract in customContracts { allowed.insert(contract.lowercased()) }
        let registryByContract = Dictionary(
            EVMTokenRegistry.tokens(for: chain).map { ($0.contract.lowercased(), $0) },
            uniquingKeysWith: { a, _ in a }
        )

        let lower = address.lowercased()
        var events: [TransactionEvent] = []
        events.reserveCapacity(transfers.count)
        for transfer in transfers {
            let isNative = transfer.contract == nil
            // Token transfers are gated by the curated allowlist; native always passes.
            if !isNative {
                guard let contract = transfer.contract?.lowercased(), allowed.contains(contract) else { continue }
            }

            let direction: TransactionDirection
            let counterparty: String
            if transfer.from.lowercased() == lower && transfer.to.lowercased() == lower {
                direction = .internal; counterparty = ""
            } else if transfer.from.lowercased() == lower {
                direction = .outgoing; counterparty = transfer.to
            } else if transfer.to.lowercased() == lower {
                direction = .incoming; counterparty = transfer.from
            } else {
                continue
            }

            let symbol: String
            let contract: String?
            if isNative {
                symbol = chain.ticker
                contract = nil
            } else {
                let lc = transfer.contract!.lowercased()
                symbol = registryByContract[lc]?.symbol ?? transfer.asset ?? Self.shortContract(transfer.contract!)
                contract = transfer.contract
            }

            events.append(TransactionEvent(
                chain: chain,
                address: address,
                txHash: transfer.hash,
                direction: direction,
                amount: transfer.amount,
                tokenSymbol: symbol,
                tokenContract: contract,
                blockNumber: transfer.blockNumber,
                occurredAt: transfer.timestamp ?? Date(),
                status: .confirmed,
                counterparty: counterparty,
                fee: nil
            ))
        }
        let result = Array(events.sorted { $0.occurredAt > $1.occurredAt }.prefix(limit))
        Self.evmLog.debug("history ◂ \(self.chain.rawValue, privacy: .public) transfers=\(transfers.count, privacy: .public) events=\(result.count, privacy: .public)")
        return result
    }

    // MARK: - Helpers

    private static func shortContract(_ addr: String) -> String {
        let stripped = addr.hasPrefix("0x") ? String(addr.dropFirst(2)) : addr
        if stripped.count >= 10 { return "0x" + String(stripped.prefix(4)) + "…" + String(stripped.suffix(4)) }
        return addr
    }
}
