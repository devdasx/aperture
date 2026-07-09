import SwiftUI

struct DiscoveredContractToken: Sendable, Equatable, Identifiable {
    let chain: SupportedChain
    let contract: String
    let symbol: String
    let name: String
    let decimals: Int

    var id: String { "\(chain.rawValue)|\(contract.lowercased())" }
}

enum ContractTokenDiscovery {
    static func matchingChains(
        symbol: String,
        chains: [SupportedChain],
        query: String,
        catalogAssets: [CatalogAsset],
        customTokens: [CustomTokenSnapshot]
    ) -> [SupportedChain] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return [] }
        let symbolUpper = symbol.uppercased()
        return chains.filter { chain in
            catalogAssets.contains { asset in
                asset.chain == chain
                    && asset.symbol.uppercased() == symbolUpper
                    && contractMatches(asset.contract, chain: chain, query: trimmed)
            } || customTokens.contains { token in
                token.chain == chain
                    && token.symbol.uppercased() == symbolUpper
                    && contractMatches(token.contract, chain: chain, query: trimmed)
            }
        }
    }

    static func contractMatches(_ contract: String, chain: SupportedChain, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return false }

        if let normalized = normalizedContract(trimmed, for: chain) {
            return compareKey(contract, chain: chain) == compareKey(normalized, chain: chain)
        }

        let needle = looseKey(trimmed)
        guard needle.count >= 4 else { return false }
        return searchKeys(contract, chain: chain).contains { $0.contains(needle) }
    }

    static func canAttemptLookup(query: String, availableChains: [SupportedChain]) -> Bool {
        !candidateContracts(query: query, availableChains: availableChains).isEmpty
    }

    static func discover(
        query: String,
        availableChains: [SupportedChain],
        catalogAssets: [CatalogAsset],
        customTokens: [CustomTokenSnapshot]
    ) async -> DiscoveredContractToken? {
        for candidate in candidateContracts(query: query, availableChains: availableChains) {
            if isKnown(
                chain: candidate.chain,
                contract: candidate.contract,
                catalogAssets: catalogAssets,
                customTokens: customTokens
            ) {
                continue
            }

            if let metadata = await fetchMetadata(chain: candidate.chain, contract: candidate.contract) {
                return DiscoveredContractToken(
                    chain: candidate.chain,
                    contract: candidate.contract,
                    symbol: metadata.symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                    name: metadata.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    decimals: metadata.decimals
                )
            }
        }
        return nil
    }

    private struct Candidate: Sendable, Hashable {
        let chain: SupportedChain
        let contract: String
    }

    private static func candidateContracts(query: String, availableChains: [SupportedChain]) -> [Candidate] {
        let chains = CustomTokenSupport.orderedChains(availableChains: availableChains)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates: [Candidate] = []
        if chains.contains(.solana),
           case .valid(let mint) = ContractValidator.validateSolanaMint(trimmed) {
            candidates.append(Candidate(chain: .solana, contract: mint))
        }
        if chains.contains(.tron),
           case .valid(let contract) = ContractValidator.validateTronContract(trimmed) {
            candidates.append(Candidate(chain: .tron, contract: contract))
        }
        if case .valid(let contract) = ContractValidator.validateEVM(trimmed) {
            candidates.append(contentsOf: chains
                .filter { $0.family == .evm }
                .map { Candidate(chain: $0, contract: contract) })
        }

        var seen: Set<Candidate> = []
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func normalizedContract(_ input: String, for chain: SupportedChain) -> String? {
        switch chain {
        case .solana:
            if case .valid(let normalized) = ContractValidator.validateSolanaMint(input) {
                return normalized
            }
        case .tron:
            if case .valid(let normalized) = ContractValidator.validateTronContract(input) {
                return normalized
            }
        default:
            if chain.family == .evm,
               case .valid(let normalized) = ContractValidator.validateEVM(input) {
                return normalized
            }
        }
        return nil
    }

    private static func isKnown(
        chain: SupportedChain,
        contract: String,
        catalogAssets: [CatalogAsset],
        customTokens: [CustomTokenSnapshot]
    ) -> Bool {
        catalogAssets.contains {
            $0.chain == chain && compareKey($0.contract, chain: chain) == compareKey(contract, chain: chain)
        } || customTokens.contains {
            $0.chain == chain && compareKey($0.contract, chain: chain) == compareKey(contract, chain: chain)
        }
    }

    private static func fetchMetadata(
        chain: SupportedChain,
        contract: String
    ) async -> TokenMetadataFetchResult? {
        switch chain.family {
        case .evm:
            return try? await EVMChainAdapter(chain: chain, client: RPCClient.shared)
                .fetchTokenMetadata(contract: contract)
        case .tron:
            return try? await TronChainAdapter(client: RPCClient.shared)
                .fetchTokenMetadata(contract: contract)
        default:
            guard chain == .solana else { return nil }
            let adapter = SolanaChainAdapter(client: RPCClient.shared)
            guard let mintInfo = try? await adapter.fetchMintInfo(mint: contract),
                  let metaplex = await adapter.fetchMetaplexMetadata(mint: contract),
                  !metaplex.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !metaplex.symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let symbol = metaplex.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = metaplex.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return TokenMetadataFetchResult(
                name: name.isEmpty ? symbol : name,
                symbol: symbol.isEmpty ? name : symbol,
                decimals: mintInfo.decimals
            )
        }
    }

    private static func compareKey(_ contract: String, chain: SupportedChain) -> String {
        if let normalized = normalizedContract(contract, for: chain) {
            return looseKey(normalized)
        }
        return looseKey(contract)
    }

    private static func searchKeys(_ contract: String, chain: SupportedChain) -> [String] {
        var keys: [String] = [looseKey(contract)]
        if chain.family == .evm {
            let stripped = contract.hasPrefix("0x") || contract.hasPrefix("0X")
                ? String(contract.dropFirst(2))
                : contract
            keys.append(looseKey(stripped))
        }
        if chain == .tron, let payload = TronAddressCodec.hexPayloadWithoutPrefix(contract) {
            keys.append(looseKey("41\(payload)"))
            keys.append(looseKey(payload))
        }
        return Array(Set(keys))
    }

    private static func looseKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct ContractTokenSearchPrompt: View {
    let query: String
    let availableChains: [SupportedChain]
    let catalogAssets: [CatalogAsset]
    let customTokens: [CustomTokenSnapshot]
    let onAdded: () -> Void

    @State private var state: PromptState = .idle

    init(
        query: String,
        availableChains: [SupportedChain],
        catalogAssets: [CatalogAsset],
        customTokens: [CustomTokenSnapshot],
        onAdded: @escaping () -> Void
    ) {
        self.query = query
        self.availableChains = availableChains
        self.catalogAssets = catalogAssets
        self.customTokens = customTokens
        self.onAdded = onAdded
    }

    var body: some View {
        Group {
            switch state {
            case .idle:
                EmptyView()
            case .checking:
                HStack(spacing: UniSpacing.s) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(UniColors.Tint.accent)
                    UniBody(text: "Checking contract address…", color: UniColors.Text.secondary)
                }
                .frame(maxWidth: .infinity)
            case .found(let token):
                foundView(token)
            case .notFound:
                UniFootnote(
                    text: "Aperture couldn't find a supported ERC-20, Solana, or TRON token at this contract address.",
                    color: UniColors.Text.tertiary
                )
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            case .adding(let token):
                HStack(spacing: UniSpacing.s) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(UniColors.Tint.accent)
                    Text(verbatim: "Adding \(token.symbol)...")
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.secondary)
                }
                .frame(maxWidth: .infinity)
            case .added(let token):
                Text(verbatim: "\(token.symbol) was added to Custom Tokens.")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            case .failed(let message):
                UniFootnote(text: LocalizedStringKey(message), color: UniColors.Feedback.Warning.foreground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .task(id: lookupKey) {
            await lookup()
        }
    }

    @ViewBuilder
    private func foundView(_ token: DiscoveredContractToken) -> some View {
        UniCard {
            VStack(spacing: UniSpacing.m) {
                CoinMark(chain: token.chain, tokenSymbol: token.symbol, contract: token.contract)
                    .frame(width: AssetLogoMetrics.standard, height: AssetLogoMetrics.standard)
                    .accessibilityHidden(true)

                VStack(spacing: UniSpacing.xxs) {
                    Text(verbatim: token.symbol)
                        .font(UniTypography.headline)
                        .foregroundStyle(UniColors.Text.primary)
                        .multilineTextAlignment(.center)
                    Text(verbatim: "\(token.name) on \(token.chain.displayName)")
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                        .multilineTextAlignment(.center)
                }

                UniBody(
                    text: "This token is not in your list yet. Add it to Custom Tokens?",
                    color: UniColors.Text.secondary
                )
                .multilineTextAlignment(.center)

                UniButton(title: "Add token", variant: .secondary, systemImage: "plus") {
                    add(token)
                }
            }
            .padding(.vertical, UniSpacing.xs)
            .frame(maxWidth: .infinity)
        }
    }

    private var lookupKey: String {
        [
            query.trimmingCharacters(in: .whitespacesAndNewlines),
            availableChains.map(\.rawValue).joined(separator: ","),
            "\(customTokens.count)",
            "\(catalogAssets.count)"
        ].joined(separator: "|")
    }

    private func lookup() async {
        guard ContractTokenDiscovery.canAttemptLookup(query: query, availableChains: availableChains) else {
            await MainActor.run { state = .idle }
            return
        }

        await MainActor.run { state = .checking }
        let found = await ContractTokenDiscovery.discover(
            query: query,
            availableChains: availableChains,
            catalogAssets: catalogAssets,
            customTokens: customTokens
        )
        await MainActor.run {
            state = found.map(PromptState.found) ?? .notFound
        }
    }

    private func add(_ token: DiscoveredContractToken) {
        state = .adding(token)
        Task { @MainActor in
            do {
                try CustomTokenRepository(database: AppDatabase.shared).add(
                    chain: token.chain,
                    contract: token.contract,
                    symbol: token.symbol,
                    name: token.name,
                    decimals: token.decimals,
                    metadataFromChain: true
                )
                UniHapticEngine.shared.fire(.success)
                state = .added(token)
                onAdded()
            } catch CustomTokenError.duplicate {
                state = .added(token)
                onAdded()
            } catch {
                state = .failed("Couldn't add this token locally. Try again.")
            }
        }
    }

    private enum PromptState: Equatable {
        case idle
        case checking
        case found(DiscoveredContractToken)
        case adding(DiscoveredContractToken)
        case added(DiscoveredContractToken)
        case notFound
        case failed(String)
    }
}
