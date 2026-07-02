import SwiftUI
import SwiftData
import WalletCore

struct ReceiveEVMAccountSearchSheet: View {
    let chain: SupportedChain
    let tokenSymbol: String?
    let activeAddress: String
    let wallet: WalletRecord?
    let onUseAddress: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @AppStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode

    @State private var fromIndex: String = "0"
    @State private var toIndex: String = "20"
    @State private var isSearching: Bool = false
    @State private var isSavingAddress: String?
    @State private var results: [EVMReceiveAccountSearchResult] = []
    @State private var hasSearched: Bool = false
    @State private var errorMessage: String?
    @State private var searchCandidateCount: Int = 0
    @State private var pendingAddressChoice: EVMReceiveAddressChoice?

    private var supportedTokens: [EVMTokenRegistry.Entry] {
        EVMTokenRegistry.tokens(for: chain)
    }

    private var parsedRange: ClosedRange<Int>? {
        guard let from = Int(fromIndex.trimmingCharacters(in: .whitespacesAndNewlines)),
              let to = Int(toIndex.trimmingCharacters(in: .whitespacesAndNewlines)),
              from >= 0,
              to >= from,
              to - from <= 100 else {
            return nil
        }
        return from...to
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.l) {
                    header
                    scopeCard
                    rangeCard
                    searchButton
                    resultSection
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.l)
                .padding(.bottom, UniSpacing.xxl)
            }
            .scrollIndicators(.hidden)
            .background(UniColors.Background.primary)
            .navigationTitle("Search accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .sheet(item: $pendingAddressChoice) { choice in
            EVMReceiveAddressScopeSheet(
                chain: chain,
                result: choice.result,
                isSaving: isSavingAddress == choice.result.address,
                onCurrentChain: {
                    Task { await saveAndUse(choice.result, scope: .currentChain) }
                },
                onAllEVMChains: {
                    Task { await saveAndUse(choice.result, scope: .allEVMChains) }
                }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            HStack(spacing: UniSpacing.m) {
                CoinMark(chain: chain, tokenSymbol: chain.ticker)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(chain.displayName) accounts")
                        .font(UniTypography.title2)
                        .foregroundStyle(UniColors.Text.primary)
                    Text("Searches this chain only.")
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                }
            }

            Text("Aperture derives account addresses locally, checks \(chain.displayName) native balance plus supported tokens, then lets you save the address you want to receive with.")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            HStack {
                Text("Current address")
                    .font(UniTypography.subheadline.weight(.semibold))
                    .foregroundStyle(UniColors.Text.primary)
                Spacer()
                Text(shortAddress(activeAddress))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(UniColors.Text.secondary)
            }

            UniDivider()

            HStack {
                scopeChip("\(supportedTokens.count)", "tokens")
                scopeChip(chain.ticker, "native")
                if let tokenSymbol {
                    scopeChip(tokenSymbol.uppercased(), "selected")
                }
            }
        }
        .padding(UniSpacing.m)
        .background(UniColors.Card.background)
        .clipShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
    }

    private var rangeCard: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            Text("Account range")
                .font(UniTypography.headline)
                .foregroundStyle(UniColors.Text.primary)

            HStack(spacing: UniSpacing.s) {
                UniTextField(
                    placeholder: "From",
                    text: $fromIndex,
                    directionPolicy: .forceLTR,
                    keyboardType: .numberPad
                )
                UniTextField(
                    placeholder: "To",
                    text: $toIndex,
                    directionPolicy: .forceLTR,
                    keyboardType: .numberPad
                )
            }

            Text("Keep the range tight first. You can search up to 100 accounts at a time without blocking the app.")
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UniSpacing.m)
        .background(UniColors.Card.background)
        .clipShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
    }

    private var searchButton: some View {
        UniButton(
            title: "Search accounts",
            variant: .primary,
            isLoading: isSearching,
            isEnabled: parsedRange != nil && !isSearching && isSavingAddress == nil
        ) {
            Task { await searchAccounts() }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            HStack {
                Text("Results")
                    .font(UniTypography.headline)
                    .foregroundStyle(UniColors.Text.primary)
                Spacer()
                if isSearching, searchCandidateCount > 0 {
                    Text("\(searchCandidateCount)")
                        .font(UniTypography.subheadline.weight(.semibold))
                        .foregroundStyle(UniColors.Text.secondary)
                } else if hasSearched {
                    Text("\(results.count)")
                        .font(UniTypography.subheadline.weight(.semibold))
                        .foregroundStyle(UniColors.Text.secondary)
                }
            }

            if let errorMessage {
                warningCard(errorMessage)
            } else if !hasSearched {
                UniListEmptyState(
                    title: "Search this chain",
                    detail: "Aperture will check account balances for this receive network only.",
                    minHeight: 180
                )
            } else if isSearching {
                searchingProcessCard
            } else if results.isEmpty {
                UniListEmptyState(
                    title: "No funded accounts found",
                    detail: "Try a wider account range, or receive to the current address.",
                    minHeight: 180
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(results) { result in
                        EVMReceiveAccountResultRow(
                            result: result,
                            currencyCode: currencyCode,
                            isCurrent: result.address.caseInsensitiveCompare(activeAddress) == .orderedSame,
                            isSaving: isSavingAddress == result.address,
                            onUse: {
                                pendingAddressChoice = EVMReceiveAddressChoice(result: result)
                            }
                        )
                        if result.id != results.last?.id {
                            UniDivider()
                                .padding(.leading, 64)
                        }
                    }
                }
                .background(UniColors.Card.background)
                .clipShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
            }
        }
    }

    private var searchingProcessCard: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            HStack(alignment: .center, spacing: UniSpacing.s) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(UniColors.Text.primary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Searching accounts")
                        .font(UniTypography.headline)
                        .foregroundStyle(UniColors.Text.primary)
                    Text(searchCandidateCount > 0 ? "Checking \(searchCandidateCount) addresses on \(chain.displayName)." : "Preparing local account addresses.")
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            UniDivider()

            VStack(alignment: .leading, spacing: UniSpacing.s) {
                searchStepRow(
                    title: "Derive local addresses",
                    detail: searchCandidateCount > 0 ? "\(searchCandidateCount) accounts ready" : "Using this wallet on-device",
                    state: searchCandidateCount > 0 ? .complete : .active
                )
                searchStepRow(
                    title: "Check balances and tokens",
                    detail: "\(chain.ticker) plus \(supportedTokens.count) supported tokens",
                    state: searchCandidateCount > 0 ? .active : .pending
                )
                searchStepRow(
                    title: "Build results",
                    detail: "Funded accounts move to the top",
                    state: .pending
                )
            }
        }
        .padding(UniSpacing.m)
        .background(UniColors.Card.background)
        .clipShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
    }

    private func searchStepRow(title: String, detail: String, state: AccountSearchStepState) -> some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            state.icon
                .frame(width: 22, height: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(UniTypography.subheadline.weight(.semibold))
                    .foregroundStyle(state == .pending ? UniColors.Text.tertiary : UniColors.Text.primary)
                Text(detail)
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func scopeChip(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(UniTypography.subheadline.weight(.semibold))
                .foregroundStyle(UniColors.Text.primary)
            Text(subtitle)
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, UniSpacing.s)
        .padding(.vertical, UniSpacing.xs)
        .background(UniColors.Fill.secondary)
        .clipShape(RoundedRectangle(cornerRadius: UniRadius.s, style: .continuous))
    }

    private func warningCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(UniColors.Feedback.Warning.foreground)
            Text(message)
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UniSpacing.m)
        .background(UniColors.Feedback.Warning.background)
        .clipShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
    }

    @MainActor
    private func searchAccounts() async {
        guard !isSearching else { return }
        guard chain.family == .evm else { return }
        guard let wallet else {
            errorMessage = "No active wallet was found for this receive screen."
            return
        }
        guard let range = parsedRange else {
            errorMessage = "Choose a valid account range. The maximum span is 100 accounts."
            return
        }

        isSearching = true
        hasSearched = true
        errorMessage = nil
        results = []
        searchCandidateCount = 0
        defer { isSearching = false }

        do {
            let candidates = try deriveCandidates(wallet: wallet, range: range)
            searchCandidateCount = candidates.count
            let searchResults = try await EVMReceiveAccountSearchService.shared.search(
                candidates: candidates,
                chain: chain,
                currencyCode: currencyCode
            )
            results = searchResults
        } catch {
            errorMessage = EVMReceiveAccountSearchError.message(for: error)
        }
    }

    private func deriveCandidates(
        wallet: WalletRecord,
        range: ClosedRange<Int>
    ) throws -> [EVMReceiveAccountCandidate] {
        switch wallet.kind {
        case .created, .importedMnemonic:
            guard !wallet.hasPassphrase else { throw EVMReceiveAccountSearchError.passphraseWallet }
            guard let words = try WalletSecretPersistence.loadMnemonic(for: wallet.id, in: modelContext),
                  !words.isEmpty else {
                throw EVMReceiveAccountSearchError.missingMnemonic
            }
            return try EVMReceiveAccountDeriver.deriveMnemonicAccounts(
                words: words,
                chain: chain,
                range: range
            )
        case .importedKey, .watchOnly:
            return [
                EVMReceiveAccountCandidate(
                    accountIndex: 0,
                    derivationPath: wallet.kind == .watchOnly ? "watch-only" : "imported-private-key",
                    address: activeAddress
                )
            ]
        }
    }

    @MainActor
    private func saveAndUse(
        _ result: EVMReceiveAccountSearchResult,
        scope: EVMReceiveAddressSaveScope
    ) async {
        guard isSavingAddress == nil else { return }
        guard let wallet else { return }
        isSavingAddress = result.address
        defer { isSavingAddress = nil }

        do {
            let addressId = try upsertAddressRows(wallet: wallet, result: result, scope: scope)
            try await persistBalances(addressId: addressId, walletId: wallet.id, result: result)
            pendingAddressChoice = nil
            onUseAddress(result.address)
            dismiss()
        } catch {
            errorMessage = EVMReceiveAccountSearchError.message(for: error)
        }
    }

    @MainActor
    private func upsertAddressRows(
        wallet: WalletRecord,
        result: EVMReceiveAccountSearchResult,
        scope: EVMReceiveAddressSaveScope
    ) throws -> UUID {
        let targets = try addressTargets(wallet: wallet, result: result, scope: scope)
        var currentChainAddressId: UUID?

        for target in targets {
            let addressId = try upsertAddressRow(wallet: wallet, target: target)
            if target.chain == chain {
                currentChainAddressId = addressId
            }
        }

        try modelContext.save()

        guard let currentChainAddressId else {
            throw EVMReceiveAccountSearchError.unsupportedChain
        }
        return currentChainAddressId
    }

    @MainActor
    private func addressTargets(
        wallet: WalletRecord,
        result: EVMReceiveAccountSearchResult,
        scope: EVMReceiveAddressSaveScope
    ) throws -> [EVMReceiveAddressTarget] {
        switch scope {
        case .currentChain:
            return [
                EVMReceiveAddressTarget(
                    chain: chain,
                    accountIndex: result.accountIndex,
                    derivationPath: result.derivationPath,
                    address: result.address,
                    isUsed: result.isUsed
                )
            ]
        case .allEVMChains:
            let evmChains = SupportedChain.allCases.filter { $0.family == .evm }
            switch wallet.kind {
            case .created, .importedMnemonic:
                guard !wallet.hasPassphrase else { throw EVMReceiveAccountSearchError.passphraseWallet }
                guard let words = try WalletSecretPersistence.loadMnemonic(for: wallet.id, in: modelContext),
                      !words.isEmpty else {
                    throw EVMReceiveAccountSearchError.missingMnemonic
                }
                return try evmChains.map { targetChain in
                    if targetChain == chain {
                        return EVMReceiveAddressTarget(
                            chain: targetChain,
                            accountIndex: result.accountIndex,
                            derivationPath: result.derivationPath,
                            address: result.address,
                            isUsed: result.isUsed
                        )
                    }
                    guard let candidate = try EVMReceiveAccountDeriver.deriveMnemonicAccounts(
                        words: words,
                        chain: targetChain,
                        range: result.accountIndex...result.accountIndex
                    ).first else {
                        throw EVMReceiveAccountSearchError.invalidMnemonic
                    }
                    return EVMReceiveAddressTarget(
                        chain: targetChain,
                        accountIndex: result.accountIndex,
                        derivationPath: candidate.derivationPath,
                        address: candidate.address,
                        isUsed: false
                    )
                }
            case .importedKey, .watchOnly:
                let derivationPath = wallet.kind == .watchOnly ? "watch-only" : "imported-private-key"
                return evmChains.map { targetChain in
                    EVMReceiveAddressTarget(
                        chain: targetChain,
                        accountIndex: result.accountIndex,
                        derivationPath: derivationPath,
                        address: result.address,
                        isUsed: targetChain == chain ? result.isUsed : false
                    )
                }
            }
        }
    }

    @MainActor
    private func upsertAddressRow(
        wallet: WalletRecord,
        target: EVMReceiveAddressTarget
    ) throws -> UUID {
        let walletId = Optional(wallet.id)
        let chainRaw = target.chain.rawValue
        let descriptor = FetchDescriptor<WalletAddressRecord>(
            predicate: #Predicate { $0.walletId == walletId && $0.chainRaw == chainRaw }
        )
        var rows = try modelContext.fetch(descriptor)

        let row: WalletAddressRecord
        if let existing = rows.first(where: { $0.address.caseInsensitiveCompare(target.address) == .orderedSame }) {
            row = existing
        } else {
            row = WalletAddressRecord(
                walletId: wallet.id,
                chainRaw: target.chain.rawValue,
                address: target.address,
                derivationPath: target.derivationPath,
                isUsed: target.isUsed,
                isReceivePreferred: true
            )
            row.wallet = wallet
            modelContext.insert(row)
            rows.append(row)
        }

        for existing in rows where existing.id != row.id {
            existing.isReceivePreferred = false
        }
        row.isReceivePreferred = true
        row.isUsed = row.isUsed || target.isUsed
        if target.chain == chain {
            row.lastScannedAt = Date()
        }
        if !target.derivationPath.isEmpty {
            row.derivationPath = target.derivationPath
        }

        return row.id
    }

    private func persistBalances(
        addressId: UUID,
        walletId: UUID,
        result: EVMReceiveAccountSearchResult
    ) async throws {
        let txRepo = TransactionRepository(modelContainer: modelContext.container)
        try await txRepo.upsertBalance(
            addressId: addressId,
            tokenSymbol: chain.ticker,
            tokenContract: nil,
            decimals: chain.nativeDecimals,
            rawBalance: result.nativeRawBalance,
            fiatValueCached: result.nativeFiat,
            fiatCurrencyCode: currencyCode,
            save: false
        )
        for token in result.tokens {
            try await txRepo.upsertBalance(
                addressId: addressId,
                tokenSymbol: token.symbol,
                tokenContract: token.contract,
                decimals: token.decimals,
                rawBalance: token.rawBalance,
                fiatValueCached: token.fiatValue,
                fiatCurrencyCode: currencyCode,
                save: false
            )
        }
        try await txRepo.markScanComplete(addressId: addressId, isUsed: result.isUsed, save: false)
        try await txRepo.flush()

        let chainStateRepo = ChainStateRepository(modelContainer: modelContext.container)
        _ = try await chainStateRepo.rebuild(
            walletId: walletId,
            fiatCurrencyCode: currencyCode,
            onlyChains: [chain]
        )
    }

    private func shortAddress(_ address: String) -> String {
        guard address.count > 14 else { return address }
        return "\(address.prefix(7))...\(address.suffix(5))"
    }
}

enum AccountSearchStepState: Equatable {
    case pending
    case active
    case complete

    @ViewBuilder
    var icon: some View {
        switch self {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(UniColors.Text.quaternary)
        case .active:
            ProgressView()
                .controlSize(.small)
                .tint(UniColors.Text.primary)
        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(UniColors.Feedback.Success.foreground)
        }
    }
}

private struct EVMReceiveAddressChoice: Identifiable {
    let result: EVMReceiveAccountSearchResult
    var id: String { result.id }
}

private enum EVMReceiveAddressSaveScope {
    case currentChain
    case allEVMChains
}

private struct EVMReceiveAddressTarget {
    let chain: SupportedChain
    let accountIndex: Int
    let derivationPath: String
    let address: String
    let isUsed: Bool
}

private struct EVMReceiveAddressScopeSheet: View {
    let chain: SupportedChain
    let result: EVMReceiveAccountSearchResult
    let isSaving: Bool
    let onCurrentChain: () -> Void
    let onAllEVMChains: () -> Void

    var body: some View {
        UniSheet(title: "Use this address") {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                Text("Choose where Aperture should make Account \(result.accountIndex) the preferred receive account.")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    optionRow(
                        title: "\(chain.displayName) only",
                        detail: "Use \(shortAddress(result.address)) for this receive network. Other EVM chains keep their current receive address.",
                        systemImage: "network"
                    )
                    UniDivider()
                        .padding(.leading, 52)
                    optionRow(
                        title: "All EVM chains",
                        detail: "Use the same account index across Ethereum-compatible networks. Mnemonic wallets save each chain's correctly derived address; imported-key and watch-only wallets reuse the same 0x address.",
                        systemImage: "square.stack.3d.up"
                    )
                }
                .background(UniColors.Card.background)
                .clipShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
            }
        } actions: {
            VStack(spacing: UniSpacing.s) {
                UniButton(
                    verbatim: "Use on \(chain.displayName)",
                    variant: .primary,
                    isLoading: isSaving,
                    isEnabled: !isSaving,
                    action: onCurrentChain
                )
                UniButton(
                    title: "Use on all EVM chains",
                    variant: .secondary,
                    isLoading: isSaving,
                    isEnabled: !isSaving,
                    action: onAllEVMChains
                )
            }
        }
    }

    private func optionRow(title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 36, height: 36)
                .background(UniColors.Fill.secondary)
                .clipShape(RoundedRectangle(cornerRadius: UniRadius.s, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(UniTypography.headline)
                    .foregroundStyle(UniColors.Text.primary)
                Text(detail)
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(UniSpacing.m)
    }

    private func shortAddress(_ address: String) -> String {
        guard address.count > 14 else { return address }
        return "\(address.prefix(7))...\(address.suffix(5))"
    }
}

private struct EVMReceiveAccountResultRow: View {
    let result: EVMReceiveAccountSearchResult
    let currencyCode: String
    let isCurrent: Bool
    let isSaving: Bool
    let onUse: () -> Void

    private var fundedTokenSummary: String {
        let funded = result.tokens.filter(\.hasFunds)
        guard !funded.isEmpty else { return "No token balance" }
        return funded.prefix(3).map { "\($0.displayAmount) \($0.symbol)" }.joined(separator: "  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            HStack(alignment: .top, spacing: UniSpacing.m) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: UniSpacing.xs) {
                        Text("Account \(result.accountIndex)")
                            .font(UniTypography.headline)
                            .foregroundStyle(UniColors.Text.primary)
                        if isCurrent {
                            Text("Current")
                                .font(UniTypography.caption1.weight(.semibold))
                                .foregroundStyle(UniColors.Feedback.Success.foreground)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(UniColors.Feedback.Success.background)
                                .clipShape(Capsule())
                        }
                    }
                    Text(result.derivationPath)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(UniColors.Text.tertiary)
                    Text(result.shortAddress)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(UniColors.Text.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(WalletFormatting.fiat(result.totalFiat, currencyCode: currencyCode))
                        .font(UniTypography.headline)
                        .foregroundStyle(result.hasFunds ? UniColors.Text.primary : UniColors.Text.tertiary)
                    Text("\(result.displayNativeBalance) native")
                        .font(UniTypography.caption1)
                        .foregroundStyle(UniColors.Text.tertiary)
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text(fundedTokenSummary)
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(2)
                Spacer()
                Text(result.transactionCount == 1 ? "1 tx" : "\(result.transactionCount) tx")
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
            }

            UniButton(
                title: isCurrent ? "Use current address" : "Use this address",
                variant: result.hasFunds ? .primary : .secondary,
                isLoading: isSaving,
                isEnabled: !isSaving,
                action: onUse
            )
        }
        .padding(UniSpacing.m)
    }
}

struct EVMReceiveAccountCandidate: Identifiable, Sendable, Hashable {
    let accountIndex: Int
    let derivationPath: String
    let address: String

    var id: String { "\(derivationPath)|\(address.lowercased())" }
}

struct EVMReceiveTokenBalance: Identifiable, Sendable, Hashable {
    let symbol: String
    let name: String
    let contract: String
    let decimals: Int
    let rawBalance: String
    let displayAmount: String
    let fiatValue: Decimal

    var id: String { contract.lowercased() }
    var hasFunds: Bool { EVMHexQuantity.isPositiveDecimalString(rawBalance) }
}

struct EVMReceiveAccountSearchResult: Identifiable, Sendable, Hashable {
    let accountIndex: Int
    let derivationPath: String
    let address: String
    let nativeRawBalance: String
    let displayNativeBalance: String
    let nativeFiat: Decimal
    let tokens: [EVMReceiveTokenBalance]
    let transactionCount: Int
    let totalFiat: Decimal

    var id: String { "\(derivationPath)|\(address.lowercased())" }
    var hasFunds: Bool { totalFiat > 0 || EVMHexQuantity.isPositiveDecimalString(nativeRawBalance) || tokens.contains(where: \.hasFunds) }
    var isUsed: Bool { hasFunds || transactionCount > 0 }

    var shortAddress: String {
        guard address.count > 16 else { return address }
        return "\(address.prefix(8))...\(address.suffix(6))"
    }
}

enum EVMReceiveAccountSearchError: Error {
    case unsupportedChain
    case missingMnemonic
    case invalidMnemonic
    case passphraseWallet
    case noRPC

    static func message(for error: Error) -> String {
        if let error = error as? EVMReceiveAccountSearchError {
            switch error {
            case .unsupportedChain:
                return "This chain is not an EVM receive network."
            case .missingMnemonic:
                return "This wallet's local recovery phrase is not available on this device."
            case .invalidMnemonic:
                return "The stored recovery phrase could not derive accounts."
            case .passphraseWallet:
                return "This wallet uses a BIP-39 passphrase. Search extra accounts from the original import source."
            case .noRPC:
                return "Aperture does not have a live RPC endpoint for this chain right now."
            }
        }
        return "Could not search accounts right now. Try again in a moment."
    }
}

enum EVMReceiveAccountDeriver {
    static func deriveMnemonicAccounts(
        words: [String],
        chain: SupportedChain,
        range: ClosedRange<Int>
    ) throws -> [EVMReceiveAccountCandidate] {
        guard chain.family == .evm else { throw EVMReceiveAccountSearchError.unsupportedChain }
        guard let coin = ChainCoinType.coinType(for: chain) else { throw EVMReceiveAccountSearchError.unsupportedChain }
        let phrase = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let wallet = HDWallet(mnemonic: phrase, passphrase: "") else {
            throw EVMReceiveAccountSearchError.invalidMnemonic
        }

        return range.map { index in
            let path = "m/44'/\(coin.rawValue)'/0'/0/\(index)"
            let privateKey = wallet.getKey(coin: coin, derivationPath: path)
            let address = coin.deriveAddress(privateKey: privateKey)
            return EVMReceiveAccountCandidate(
                accountIndex: index,
                derivationPath: path,
                address: address
            )
        }
    }
}

actor EVMReceiveAccountSearchService {
    static let shared = EVMReceiveAccountSearchService()

    func search(
        candidates: [EVMReceiveAccountCandidate],
        chain: SupportedChain,
        currencyCode: String
    ) async throws -> [EVMReceiveAccountSearchResult] {
        guard chain.family == .evm else { throw EVMReceiveAccountSearchError.unsupportedChain }
        guard PublicNodeEVMRPCClient.shared.supports(chain: chain) else {
            throw EVMReceiveAccountSearchError.noRPC
        }

        let tokens = EVMTokenRegistry.tokens(for: chain)
        let symbols = Array(Set(([chain.ticker] + tokens.map(\.symbol)).map { $0.uppercased() }))
        let prices = await TokenPricingEngine.shared.unitPrices(
            symbols: symbols,
            currencyCode: currencyCode
        )

        var results: [EVMReceiveAccountSearchResult] = []
        results.reserveCapacity(candidates.count)
        for candidate in candidates {
            try Task.checkCancellation()
            if let result = try await search(candidate: candidate, chain: chain, tokens: tokens, prices: prices) {
                results.append(result)
            }
        }

        return results.sorted {
            if $0.hasFunds != $1.hasFunds { return $0.hasFunds && !$1.hasFunds }
            if $0.totalFiat != $1.totalFiat { return $0.totalFiat > $1.totalFiat }
            return $0.accountIndex < $1.accountIndex
        }
    }

    private func search(
        candidate: EVMReceiveAccountCandidate,
        chain: SupportedChain,
        tokens: [EVMTokenRegistry.Entry],
        prices: [String: TokenPricingEngine.ResolvedPrice]
    ) async throws -> EVMReceiveAccountSearchResult? {
        async let nativeHexTask = PublicNodeEVMRPCClient.shared.nativeBalance(chain: chain, address: candidate.address)
        async let txCountHexTask = PublicNodeEVMRPCClient.shared.transactionCount(chain: chain, address: candidate.address)
        async let tokenReadsTask = readTokens(chain: chain, address: candidate.address, tokens: tokens)

        let nativeHex = (try? await nativeHexTask) ?? "0x0"
        let txCountHex = (try? await txCountHexTask) ?? "0x0"
        let tokenReads = await tokenReadsTask

        let nativeRaw = (try? EVMHexQuantity.decimalString(from: nativeHex)) ?? "0"
        let nativeFiat = fiatValue(
            rawBalance: nativeRaw,
            decimals: chain.nativeDecimals,
            symbol: chain.ticker,
            prices: prices
        )
        let displayNative = EVMHexQuantity.displayAmount(
            rawBalance: nativeRaw,
            decimals: chain.nativeDecimals
        ) ?? "0"
        let balances = tokenReads.map { token, rawBalance in
            EVMReceiveTokenBalance(
                symbol: token.symbol,
                name: token.name,
                contract: token.contract,
                decimals: token.decimals,
                rawBalance: rawBalance,
                displayAmount: EVMHexQuantity.displayAmount(rawBalance: rawBalance, decimals: token.decimals) ?? "0",
                fiatValue: fiatValue(rawBalance: rawBalance, decimals: token.decimals, symbol: token.symbol, prices: prices)
            )
        }

        let txCount = Int((try? EVMHexQuantity.int64(from: txCountHex)) ?? 0)
        let totalFiat = nativeFiat + balances.reduce(Decimal(0)) { $0 + $1.fiatValue }
        return EVMReceiveAccountSearchResult(
            accountIndex: candidate.accountIndex,
            derivationPath: candidate.derivationPath,
            address: candidate.address,
            nativeRawBalance: nativeRaw,
            displayNativeBalance: displayNative,
            nativeFiat: nativeFiat,
            tokens: balances,
            transactionCount: txCount,
            totalFiat: totalFiat
        )
    }

    private func readTokens(
        chain: SupportedChain,
        address: String,
        tokens: [EVMTokenRegistry.Entry]
    ) async -> [(EVMTokenRegistry.Entry, String)] {
        await withTaskGroup(of: (EVMTokenRegistry.Entry, String)?.self) { group in
            for token in tokens {
                group.addTask {
                    let hex = try? await PublicNodeEVMRPCClient.shared.tokenBalance(
                        chain: chain,
                        contract: token.contract,
                        holder: address
                    )
                    let raw = hex.flatMap { try? EVMHexQuantity.decimalString(from: $0) } ?? "0"
                    return (token, raw)
                }
            }

            var reads: [(EVMTokenRegistry.Entry, String)] = []
            reads.reserveCapacity(tokens.count)
            for await read in group {
                if let read { reads.append(read) }
            }
            return reads.sorted { $0.0.symbol < $1.0.symbol }
        }
    }

    private func fiatValue(
        rawBalance: String,
        decimals: Int,
        symbol: String,
        prices: [String: TokenPricingEngine.ResolvedPrice]
    ) -> Decimal {
        guard let amount = EVMHexQuantity.decimalAmount(rawBalance: rawBalance, decimals: decimals) else {
            return 0
        }
        let price = prices[symbol.uppercased()]?.amount ?? 0
        return amount * price
    }
}
