import SwiftUI
import SwiftData

struct ReceiveSolanaAccountSearchSheet: View {
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
    @State private var results: [SolanaReceiveAccountSearchResult] = []
    @State private var hasSearched: Bool = false
    @State private var errorMessage: String?
    @State private var searchCandidateCount: Int = 0
    @State private var searchRequest: SolanaReceiveAccountSearchRequest?

    private var supportedTokens: [SolanaReceiveSupportedToken] {
        SolanaReceiveSupportedToken.supported
    }

    private var parsedRange: ClosedRange<Int>? {
        guard let from = Int(fromIndex.trimmingCharacters(in: .whitespacesAndNewlines)),
              let to = Int(toIndex.trimmingCharacters(in: .whitespacesAndNewlines)),
              from >= 0,
              to >= from,
              (to - from + 1) <= SolanaReceiveAccountSearchLimits.maxAccountsPerSearch else {
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
        .sheet(item: $searchRequest) { request in
            SolanaReceiveAccountSearchProgressSheet(
                request: request,
                onFinished: finishSearch,
                onCancel: cancelSearch
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            HStack(spacing: UniSpacing.m) {
                CoinMark(chain: .solana, tokenSymbol: SupportedChain.solana.ticker)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Solana addresses")
                        .font(UniTypography.title2)
                        .foregroundStyle(UniColors.Text.primary)
                    Text("Trust Wallet and Phantom paths.")
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                }
            }

            Text("Aperture derives Solana addresses locally, checks SOL plus every supported SPL token, and lets you save the address you want to receive with.")
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
                scopeChip("2", "address types")
                scopeChip("\(supportedTokens.count)", "SPL tokens")
                scopeChip("SOL", "native")
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

            VStack(alignment: .leading, spacing: UniSpacing.xs) {
                pathLegend(.trustWallet)
                pathLegend(.phantom)
            }

            Text("Search a small range first. Both address families are checked for balance and history without changing your current receive address until you choose one.")
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UniSpacing.m)
        .background(UniColors.Card.background)
        .clipShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
    }

    private func pathLegend(_ type: SolanaReceiveAddressType) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UniSpacing.xs) {
            Text(type.title)
                .font(UniTypography.caption1.weight(.semibold))
                .foregroundStyle(UniColors.Text.primary)
            Text(type.subtitle)
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
                .lineLimit(1)
        }
    }

    private var searchButton: some View {
        UniButton(
            title: "Search Solana",
            variant: .primary,
            isLoading: isSearching,
            isEnabled: parsedRange != nil && !isSearching && isSavingAddress == nil
        ) {
            searchAccounts()
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
                    title: "Search Solana",
                    detail: "Aperture will check Trust Wallet and Phantom addresses for SOL and supported SPL token balances.",
                    minHeight: 180
                )
            } else if isSearching {
                UniListEmptyState(
                    title: "Search running",
                    detail: "Aperture is checking Solana accounts in a separate progress sheet.",
                    minHeight: 180
                )
            } else if results.isEmpty {
                UniListEmptyState(
                    title: "No Solana accounts found",
                    detail: "Try a wider account range, or receive to the current address.",
                    minHeight: 180
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(results) { result in
                        SolanaReceiveAccountResultRow(
                            result: result,
                            currencyCode: currencyCode,
                            isCurrent: result.address == activeAddress,
                            isSaving: isSavingAddress == result.address,
                            onUse: {
                                Task { await saveAndUse(result) }
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
                    Text(searchCandidateCount > 0 ? "Checking \(searchCandidateCount) Solana addresses." : "Preparing Trust Wallet and Phantom addresses.")
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            UniDivider()

            VStack(alignment: .leading, spacing: UniSpacing.s) {
                searchStepRow(
                    title: "Derive local addresses",
                    detail: searchCandidateCount > 0 ? "\(searchCandidateCount) addresses ready" : "Trust Wallet and Phantom paths",
                    state: searchCandidateCount > 0 ? .complete : .active
                )
                searchStepRow(
                    title: "Check SOL and SPL tokens",
                    detail: "SOL plus \(supportedTokens.count) supported SPL tokens",
                    state: searchCandidateCount > 0 ? .active : .pending
                )
                searchStepRow(
                    title: "Build results",
                    detail: "Funded addresses move to the top",
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
    private func searchAccounts() {
        guard !isSearching else { return }
        guard let wallet else {
            errorMessage = "No active wallet was found for this receive screen."
            return
        }
        guard let range = parsedRange else {
            errorMessage = SolanaReceiveAccountSearchLimits.rangeErrorMessage
            return
        }

        isSearching = false
        hasSearched = false
        errorMessage = nil
        results = []
        searchCandidateCount = 0

        do {
            let candidates = try deriveCandidates(wallet: wallet, range: range)
            searchCandidateCount = candidates.count
            isSearching = true
            searchRequest = SolanaReceiveAccountSearchRequest(
                candidates: candidates,
                currencyCode: currencyCode
            )
        } catch {
            errorMessage = SolanaReceiveAccountSearchError.message(for: error)
            isSearching = false
        }
    }

    @MainActor
    private func finishSearch(_ outcome: Result<[SolanaReceiveAccountSearchResult], Error>) {
        searchRequest = nil
        isSearching = false
        hasSearched = true

        switch outcome {
        case .success(let searchResults):
            errorMessage = nil
            results = searchResults
        case .failure(let error):
            results = []
            errorMessage = SolanaReceiveAccountSearchError.message(for: error)
        }
    }

    @MainActor
    private func cancelSearch() {
        searchRequest = nil
        isSearching = false
    }

    private func deriveCandidates(
        wallet: WalletRecord,
        range: ClosedRange<Int>
    ) throws -> [SolanaReceiveAccountCandidate] {
        switch wallet.kind {
        case .created, .importedMnemonic:
            guard !wallet.hasPassphrase else { throw SolanaReceiveAccountSearchError.passphraseWallet }
            guard let words = try WalletSecretPersistence.loadMnemonic(for: wallet.id, in: modelContext),
                  !words.isEmpty else {
                throw SolanaReceiveAccountSearchError.missingMnemonic
            }
            return try SolanaReceiveAccountDeriver.deriveMnemonicAccounts(words: words, range: range)
        case .importedKey, .watchOnly:
            return [
                SolanaReceiveAccountCandidate(
                    type: .current,
                    accountIndex: 0,
                    derivationPath: wallet.kind == .watchOnly ? "watch-only" : "imported-private-key",
                    address: activeAddress
                )
            ]
        }
    }

    @MainActor
    private func saveAndUse(_ result: SolanaReceiveAccountSearchResult) async {
        guard isSavingAddress == nil else { return }
        guard let wallet else { return }
        isSavingAddress = result.address
        defer { isSavingAddress = nil }

        do {
            let addressId = try upsertAddressRow(wallet: wallet, result: result)
            try await persistBalances(addressId: addressId, walletId: wallet.id, result: result)
            onUseAddress(result.address)
            dismiss()
        } catch {
            errorMessage = SolanaReceiveAccountSearchError.message(for: error)
        }
    }

    @MainActor
    private func upsertAddressRow(
        wallet: WalletRecord,
        result: SolanaReceiveAccountSearchResult
    ) throws -> UUID {
        let walletId = Optional(wallet.id)
        let chainRaw = SupportedChain.solana.rawValue
        let descriptor = FetchDescriptor<WalletAddressRecord>(
            predicate: #Predicate { $0.walletId == walletId && $0.chainRaw == chainRaw }
        )
        var rows = try modelContext.fetch(descriptor)

        let row: WalletAddressRecord
        if let existing = rows.first(where: { $0.address == result.address }) {
            row = existing
        } else {
            row = WalletAddressRecord(
                walletId: wallet.id,
                chainRaw: SupportedChain.solana.rawValue,
                address: result.address,
                derivationPath: result.derivationPath,
                isUsed: result.isUsed,
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
        row.isUsed = row.isUsed || result.isUsed
        row.lastScannedAt = Date()
        if row.derivationPath.isEmpty || row.derivationPath == "m/44'/501'/0'/0'" {
            row.derivationPath = result.derivationPath
        }

        try modelContext.save()
        return row.id
    }

    private func persistBalances(
        addressId: UUID,
        walletId: UUID,
        result: SolanaReceiveAccountSearchResult
    ) async throws {
        let txRepo = TransactionRepository(modelContainer: modelContext.container)
        try await txRepo.upsertBalance(
            addressId: addressId,
            tokenSymbol: SupportedChain.solana.ticker,
            tokenContract: nil,
            decimals: SupportedChain.solana.nativeDecimals,
            rawBalance: result.nativeRawBalance,
            fiatValueCached: result.nativeFiat,
            fiatCurrencyCode: currencyCode,
            save: false
        )
        for token in result.tokens {
            try await txRepo.upsertBalance(
                addressId: addressId,
                tokenSymbol: token.symbol,
                tokenContract: token.mint,
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
            onlyChains: [.solana]
        )
    }

    private func shortAddress(_ address: String) -> String {
        guard address.count > 14 else { return address }
        return "\(address.prefix(7))...\(address.suffix(5))"
    }
}

private struct SolanaReceiveAccountResultRow: View {
    let result: SolanaReceiveAccountSearchResult
    let currencyCode: String
    let isCurrent: Bool
    let isSaving: Bool
    let onUse: () -> Void

    private var fundedTokenSummary: String {
        let funded = result.tokens.filter(\.hasFunds)
        guard !funded.isEmpty else { return "No SPL token balance" }
        return funded.prefix(3).map { "\($0.displayAmount) \($0.symbol)" }.joined(separator: "  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            HStack(alignment: .top, spacing: UniSpacing.m) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: UniSpacing.xs) {
                        Text(result.title)
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
                    Text("\(result.displayNativeBalance) SOL")
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

private enum SolanaReceiveAddressType: String, Identifiable, Sendable, Hashable {
    case trustWallet
    case phantom
    case current

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trustWallet: return "Trust Wallet"
        case .phantom: return "Phantom"
        case .current: return "Current"
        }
    }

    var subtitle: String {
        switch self {
        case .trustWallet: return "m/44'/501'/account'"
        case .phantom: return "m/44'/501'/account'/0'"
        case .current: return "Saved wallet address"
        }
    }

    func derivationPath(account: Int) -> String {
        switch self {
        case .trustWallet:
            return "m/44'/501'/\(account)'"
        case .phantom:
            return "m/44'/501'/\(account)'/0'"
        case .current:
            return "current"
        }
    }
}

private struct SolanaReceiveSupportedToken: Sendable, Hashable {
    let mint: String
    let entry: SolanaTokenRegistry.Entry

    static var supported: [SolanaReceiveSupportedToken] {
        SolanaTokenRegistry.mints
            .map { SolanaReceiveSupportedToken(mint: $0.key, entry: $0.value) }
            .sorted { $0.entry.symbol < $1.entry.symbol }
    }
}

private struct SolanaReceiveAccountCandidate: Identifiable, Sendable, Hashable {
    let type: SolanaReceiveAddressType
    let accountIndex: Int
    let derivationPath: String
    let address: String

    var id: String { "\(type.rawValue)|\(derivationPath)|\(address)" }
}

private struct SolanaReceiveTokenBalance: Identifiable, Sendable, Hashable {
    let symbol: String
    let name: String
    let mint: String
    let decimals: Int
    let rawBalance: String
    let displayAmount: String
    let fiatValue: Decimal

    var id: String { mint }
    var hasFunds: Bool { EVMHexQuantity.isPositiveDecimalString(rawBalance) }
}

private struct SolanaReceiveAccountSearchResult: Identifiable, Sendable, Hashable {
    let type: SolanaReceiveAddressType
    let accountIndex: Int
    let derivationPath: String
    let address: String
    let nativeRawBalance: String
    let displayNativeBalance: String
    let nativeFiat: Decimal
    let tokens: [SolanaReceiveTokenBalance]
    let transactionCount: Int
    let totalFiat: Decimal

    var id: String { "\(type.rawValue)|\(derivationPath)|\(address)" }
    var title: String {
        type == .current ? "Current address" : "\(type.title) \(accountIndex)"
    }
    var hasFunds: Bool { totalFiat > 0 || EVMHexQuantity.isPositiveDecimalString(nativeRawBalance) || tokens.contains(where: \.hasFunds) }
    var isUsed: Bool { hasFunds || transactionCount > 0 }

    var shortAddress: String {
        guard address.count > 16 else { return address }
        return "\(address.prefix(8))...\(address.suffix(6))"
    }
}

private enum SolanaReceiveAccountSearchLimits {
    static let maxAccountsPerSearch = 100
    static let rangeErrorMessage = "Search up to 100 accounts at once. Use ranges like 0 to 99, then continue with the next 100."
}

private struct SolanaReceiveAccountSearchRequest: Identifiable {
    let id = UUID()
    let candidates: [SolanaReceiveAccountCandidate]
    let currencyCode: String
}

private struct SolanaReceiveAccountSearchProgressSheet: View {
    let request: SolanaReceiveAccountSearchRequest
    let onFinished: (Result<[SolanaReceiveAccountSearchResult], Error>) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var didFinish = false

    var body: some View {
        UniSheet(title: "Searching accounts") {
            VStack(alignment: .leading, spacing: UniSpacing.m) {
                HStack(alignment: .center, spacing: UniSpacing.s) {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(UniColors.Text.primary)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Checking \(request.candidates.count) Solana addresses")
                            .font(UniTypography.headline)
                            .foregroundStyle(UniColors.Text.primary)
                        Text("Trust Wallet and Phantom balances, history, and supported SPL token balances are running in parallel.")
                            .font(UniTypography.subheadline)
                            .foregroundStyle(UniColors.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                UniDivider()

                VStack(alignment: .leading, spacing: UniSpacing.s) {
                    searchStepRow(
                        title: "Local addresses ready",
                        detail: "\(request.candidates.count) addresses derived on this device",
                        state: .complete
                    )
                    searchStepRow(
                        title: "Parallel Solana scan",
                        detail: "SOL plus \(SolanaReceiveSupportedToken.supported.count) supported SPL tokens",
                        state: .active
                    )
                    searchStepRow(
                        title: "Build results",
                        detail: "Funded accounts move to the top when the scan completes",
                        state: .pending
                    )
                }
            }
        } actions: {
            UniButton(title: "Cancel", variant: .secondary) {
                didFinish = true
                onCancel()
                dismiss()
            }
        }
        .task(id: request.id) {
            do {
                let searchResults = try await SolanaReceiveAccountSearchService.shared.search(
                    candidates: request.candidates,
                    currencyCode: request.currencyCode
                )
                try Task.checkCancellation()
                didFinish = true
                onFinished(.success(searchResults))
                dismiss()
            } catch is CancellationError {
                if !didFinish {
                    didFinish = true
                    onCancel()
                }
            } catch {
                didFinish = true
                onFinished(.failure(error))
                dismiss()
            }
        }
        .onDisappear {
            guard !didFinish else { return }
            didFinish = true
            onCancel()
        }
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
}

private enum SolanaReceiveAccountSearchError: Error {
    case missingMnemonic
    case invalidRange
    case passphraseWallet

    static func message(for error: Error) -> String {
        if let error = error as? SolanaReceiveAccountSearchError {
            switch error {
            case .missingMnemonic:
                return "This wallet's local recovery phrase is not available on this device."
            case .invalidRange:
                return "Choose a valid account range."
            case .passphraseWallet:
                return "This wallet uses a BIP-39 passphrase. Search extra accounts from the original import source."
            }
        }
        return "Could not search Solana accounts right now. Try again in a moment."
    }
}

private enum SolanaReceiveAccountDeriver {
    static func deriveMnemonicAccounts(
        words: [String],
        range: ClosedRange<Int>
    ) throws -> [SolanaReceiveAccountCandidate] {
        let normalizedWords = words
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !normalizedWords.isEmpty else { throw SolanaReceiveAccountSearchError.missingMnemonic }

        let seed = BIP39.deriveSeed(words: normalizedWords, passphrase: "")
        var candidates: [SolanaReceiveAccountCandidate] = []
        candidates.reserveCapacity(range.count * 2)

        for index in range {
            guard let account = UInt32(exactly: index) else {
                throw SolanaReceiveAccountSearchError.invalidRange
            }

            let trustPath = SolanaReceiveAddressType.trustWallet.derivationPath(account: index)
            candidates.append(
                SolanaReceiveAccountCandidate(
                    type: .trustWallet,
                    accountIndex: index,
                    derivationPath: trustPath,
                    address: Ed25519Derivation.solanaTrustWalletAddress(seed: seed, account: account)
                )
            )

            let phantomPath = SolanaReceiveAddressType.phantom.derivationPath(account: index)
            candidates.append(
                SolanaReceiveAccountCandidate(
                    type: .phantom,
                    accountIndex: index,
                    derivationPath: phantomPath,
                    address: Ed25519Derivation.solanaPhantomAddress(seed: seed, account: account)
                )
            )
        }

        return Array(Dictionary(grouping: candidates, by: \.address).values.compactMap(\.first))
    }
}

private actor SolanaReceiveAccountSearchService {
    static let shared = SolanaReceiveAccountSearchService()

    func search(
        candidates: [SolanaReceiveAccountCandidate],
        currencyCode: String
    ) async throws -> [SolanaReceiveAccountSearchResult] {
        let tokens = SolanaReceiveSupportedToken.supported
        let symbols = Array(Set(([SupportedChain.solana.ticker] + tokens.map(\.entry.symbol)).map { $0.uppercased() }))
        let prices = await TokenPricingEngine.shared.unitPrices(
            symbols: symbols,
            currencyCode: currencyCode
        )

        let results = try await withThrowingTaskGroup(
            of: SolanaReceiveAccountSearchResult?.self,
            returning: [SolanaReceiveAccountSearchResult].self
        ) { group in
            for candidate in candidates {
                group.addTask {
                    try Task.checkCancellation()
                    return await self.search(candidate: candidate, tokens: tokens, prices: prices)
                }
            }

            var searchResults: [SolanaReceiveAccountSearchResult] = []
            searchResults.reserveCapacity(candidates.count)
            for try await result in group {
                if let result { searchResults.append(result) }
            }
            return searchResults
        }

        return results.sorted {
            if $0.hasFunds != $1.hasFunds { return $0.hasFunds && !$1.hasFunds }
            if $0.totalFiat != $1.totalFiat { return $0.totalFiat > $1.totalFiat }
            if $0.type != $1.type { return $0.type.rawValue < $1.type.rawValue }
            return $0.accountIndex < $1.accountIndex
        }
    }

    private func search(
        candidate: SolanaReceiveAccountCandidate,
        tokens: [SolanaReceiveSupportedToken],
        prices: [String: TokenPricingEngine.ResolvedPrice]
    ) async -> SolanaReceiveAccountSearchResult? {
        async let nativeTask = nativeBalance(address: candidate.address)
        async let txCountTask = transactionCount(address: candidate.address)
        async let tokenReadsTask = readTokens(owner: candidate.address, tokens: tokens)

        let nativeRaw = (try? await nativeTask) ?? "0"
        let txCount = (try? await txCountTask) ?? 0
        let tokenReads = await tokenReadsTask

        let nativeFiat = fiatValue(
            rawBalance: nativeRaw,
            decimals: SupportedChain.solana.nativeDecimals,
            symbol: SupportedChain.solana.ticker,
            prices: prices
        )
        let displayNative = EVMHexQuantity.displayAmount(
            rawBalance: nativeRaw,
            decimals: SupportedChain.solana.nativeDecimals
        ) ?? "0"
        let balances = tokenReads.map { read in
            SolanaReceiveTokenBalance(
                symbol: read.token.entry.symbol,
                name: read.token.entry.name,
                mint: read.token.mint,
                decimals: read.token.entry.decimals,
                rawBalance: read.rawBalance,
                displayAmount: EVMHexQuantity.displayAmount(
                    rawBalance: read.rawBalance,
                    decimals: read.token.entry.decimals
                ) ?? "0",
                fiatValue: fiatValue(
                    rawBalance: read.rawBalance,
                    decimals: read.token.entry.decimals,
                    symbol: read.token.entry.symbol,
                    prices: prices
                )
            )
        }
        let totalFiat = nativeFiat + balances.reduce(Decimal(0)) { $0 + $1.fiatValue }

        return SolanaReceiveAccountSearchResult(
            type: candidate.type,
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

    private func nativeBalance(address: String) async throws -> String {
        let data = try await RPCClient.shared.callJSONResultData(
            chain: .solana,
            method: "getBalance",
            params: [address, ["commitment": "confirmed"] as [String: Sendable]]
        )
        let response = try JSONDecoder().decode(SolanaReceiveGetBalanceResult.self, from: data)
        return String(response.value)
    }

    private func transactionCount(address: String) async throws -> Int {
        let data = try await RPCClient.shared.callJSONResultData(
            chain: .solana,
            method: "getSignaturesForAddress",
            params: [address, ["limit": 25, "commitment": "confirmed"] as [String: Sendable]]
        )
        let signatures = try JSONDecoder().decode([SolanaReceiveSignatureInfo].self, from: data)
        return signatures.count
    }

    private func readTokens(
        owner: String,
        tokens: [SolanaReceiveSupportedToken]
    ) async -> [SolanaReceiveTokenRead] {
        await withTaskGroup(of: SolanaReceiveTokenRead?.self) { group in
            for token in tokens {
                group.addTask {
                    try? await self.tokenBalance(owner: owner, token: token)
                }
            }

            var reads: [SolanaReceiveTokenRead] = []
            reads.reserveCapacity(tokens.count)
            for await read in group {
                if let read { reads.append(read) }
            }
            return reads.sorted { $0.token.entry.symbol < $1.token.entry.symbol }
        }
    }

    private func tokenBalance(
        owner: String,
        token: SolanaReceiveSupportedToken
    ) async throws -> SolanaReceiveTokenRead {
        let data = try await RPCClient.shared.callJSONResultData(
            chain: .solana,
            method: "getTokenAccountsByOwner",
            params: [
                owner,
                ["mint": token.mint] as [String: Sendable],
                ["encoding": "jsonParsed", "commitment": "confirmed"] as [String: Sendable],
            ]
        )
        let result = try JSONDecoder().decode(SolanaReceiveTokenAccountsResult.self, from: data)
        let rawBalance = result.value.reduce("0") { current, row in
            SolanaReceiveDecimalString.add(current, row.account.data.parsed.info.tokenAmount.amount)
        }
        return SolanaReceiveTokenRead(token: token, rawBalance: rawBalance)
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

private struct SolanaReceiveTokenRead: Sendable {
    let token: SolanaReceiveSupportedToken
    let rawBalance: String
}

private struct SolanaReceiveGetBalanceResult: Decodable {
    let value: UInt64
}

private struct SolanaReceiveSignatureInfo: Decodable, Sendable {
    let signature: String
}

private struct SolanaReceiveTokenAccountsResult: Decodable {
    let value: [SolanaReceiveTokenAccountRow]
}

private struct SolanaReceiveTokenAccountRow: Decodable {
    let account: AccountBody

    struct AccountBody: Decodable {
        let data: DataBody
    }

    struct DataBody: Decodable {
        let parsed: ParsedBody
    }

    struct ParsedBody: Decodable {
        let info: InfoBody
    }

    struct InfoBody: Decodable {
        let tokenAmount: TokenAmountBody
    }

    struct TokenAmountBody: Decodable {
        let amount: String
    }
}

private enum SolanaReceiveDecimalString {
    static func add(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.reversed().map { Int(String($0)) ?? 0 }
        let right = rhs.reversed().map { Int(String($0)) ?? 0 }
        let count = max(left.count, right.count)
        var carry = 0
        var result: [Int] = []
        result.reserveCapacity(count + 1)
        for index in 0..<count {
            let sum = (index < left.count ? left[index] : 0)
                + (index < right.count ? right[index] : 0)
                + carry
            result.append(sum % 10)
            carry = sum / 10
        }
        while carry > 0 {
            result.append(carry % 10)
            carry /= 10
        }
        while result.count > 1 && result.last == 0 {
            result.removeLast()
        }
        return result.reversed().map(String.init).joined()
    }
}
