import SwiftUI

// Kept in this legacy source path because the local Xcode project compiles
// it from here. The Settings route is removed; this sheet is presented from
// the Bitcoin receive options menu.
struct ReceiveBitcoinPathSearchSheet: View {
    let activeAddress: String
    let wallet: WalletRecord?
    let onUseAddress: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var purpose: BitcoinPathSearchPurpose = .bip84
    @State private var accountFrom: String = "0"
    @State private var accountTo: String = "0"
    @State private var changeFrom: String = "0"
    @State private var changeTo: String = "1"
    @State private var indexFrom: String = "0"
    @State private var indexTo: String = "20"
    @State private var saveFoundAddresses: Bool = true

    @State private var isSearching: Bool = false
    @State private var isSavingAddress: String?
    @State private var hasSearched: Bool = false
    @State private var results: [BitcoinPathSearchResult] = []
    @State private var savedCount: Int?
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    private var requestPreview: BitcoinPathSearchRequest? {
        try? makeRequest(validate: false)
    }

    private var targetCount: Int {
        requestPreview?.targetCount ?? 0
    }

    private var targetCountLabel: String {
        guard targetCount > 0 else { return "Enter valid ranges" }
        return targetCount == 1 ? "1 address" : "\(targetCount) addresses"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.l) {
                    header
                    scopeCard
                    pathCard
                    saveCard
                    searchButton
                    resultSection
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.l)
                .padding(.bottom, UniSpacing.xxl)
            }
            .scrollIndicators(.hidden)
            .background(UniColors.Background.primary)
            .navigationTitle("Search paths")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .alert(
            Text("Search failed"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(LocalizedStringKey(errorMessage ?? ""))
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            HStack(spacing: UniSpacing.m) {
                CoinMark(chain: .bitcoin, tokenSymbol: SupportedChain.bitcoin.ticker)
                    .frame(width: AssetLogoMetrics.standard, height: AssetLogoMetrics.standard)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Bitcoin paths")
                        .font(UniTypography.title2)
                        .foregroundStyle(UniColors.Text.primary)
                    Text("Receive and change addresses.")
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Text.secondary)
                }
            }

            Text("Aperture derives Bitcoin addresses locally, checks Electrum for balance and history, then lets you save the address you want to receive with.")
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
                Text(WalletFormatting.shortAddress(activeAddress))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(UniColors.Text.secondary)
            }

            UniDivider()

            HStack {
                scopeChip("4", "BIP types")
                scopeChip("BTC", "native")
                scopeChip("Electrum", "history")
            }
        }
        .padding(UniSpacing.m)
        .background(UniColors.Card.background)
        .clipShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
    }

    private var pathCard: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            Text("Path range")
                .font(UniTypography.headline)
                .foregroundStyle(UniColors.Text.primary)

            Picker("Address type", selection: $purpose) {
                ForEach(BitcoinPathSearchPurpose.allCases) { option in
                    Text(verbatim: option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: UniSpacing.xs) {
                Text(verbatim: purpose.pathTemplate)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(UniColors.Text.primary)
                Text(verbatim: purpose.subtitle)
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            rangeRow(
                title: "Account",
                detail: "Hardened account number",
                from: $accountFrom,
                to: $accountTo
            )
            rangeRow(
                title: "Branch",
                detail: "0 receive, 1 change",
                from: $changeFrom,
                to: $changeTo
            )
            rangeRow(
                title: "Index",
                detail: "Address index",
                from: $indexFrom,
                to: $indexTo
            )

            Text("This run checks \(targetCountLabel). Keep searches under \(BitcoinPathSearchRequest.maxTargets) addresses so the phone stays responsive.")
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UniSpacing.m)
        .background(UniColors.Card.background)
        .clipShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
    }

    private var saveCard: some View {
        Toggle(isOn: $saveFoundAddresses) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Save found paths")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                Text("Saved addresses become part of this wallet's database record and keep syncing with balance/history scans.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
            }
        }
        .padding(UniSpacing.m)
        .background(UniColors.Card.background)
        .clipShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
    }

    private var searchButton: some View {
        UniButton(
            title: "Search Bitcoin",
            variant: .primary,
            isLoading: isSearching,
            isEnabled: !isSearching && isSavingAddress == nil
        ) {
            startSearch()
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
                if isSearching, targetCount > 0 {
                    Text("\(targetCount)")
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
                    title: "Search Bitcoin",
                    detail: "Aperture will check BIP44, BIP49, BIP84, or BIP86 paths for funded or previously used addresses.",
                    minHeight: 180
                )
            } else if isSearching {
                UniListEmptyState(
                    title: "Search running",
                    detail: "Aperture is checking Bitcoin paths with Electrum.",
                    minHeight: 180
                )
            } else if results.isEmpty {
                UniListEmptyState(
                    title: "No Bitcoin paths found",
                    detail: "Try another BIP type, account, branch, or index range.",
                    minHeight: 180
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(results) { result in
                        BitcoinReceivePathResultRow(
                            result: result,
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

            if let savedCount {
                Label {
                    Text(verbatim: savedCount == 1 ? "Saved 1 address" : "Saved \(savedCount) addresses")
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Feedback.Success.foreground)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(UniColors.Feedback.Success.foreground)
                }
            }
        }
    }

    private func rangeRow(
        title: String,
        detail: String,
        from: Binding<String>,
        to: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(UniTypography.subheadline.weight(.semibold))
                        .foregroundStyle(UniColors.Text.primary)
                    Text(detail)
                        .font(UniTypography.caption1)
                        .foregroundStyle(UniColors.Text.tertiary)
                }

                Spacer()

                HStack(spacing: UniSpacing.xs) {
                    compactNumberField("From", text: from)
                    Text("to")
                        .font(UniTypography.caption1)
                        .foregroundStyle(UniColors.Text.tertiary)
                    compactNumberField("To", text: to)
                }
            }
        }
    }

    private func compactNumberField(
        _ placeholder: LocalizedStringKey,
        text: Binding<String>
    ) -> some View {
        UniTextField(
            placeholder: placeholder,
            text: text,
            textAlignment: .center,
            directionPolicy: .forceLTR,
            keyboardType: .numberPad,
            minHeight: 42
        )
        .frame(width: 68)
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

    private func startSearch() {
        guard !isSearching else { return }
        guard let wallet else {
            errorMessage = "No active wallet was found for this receive screen."
            return
        }
        let request: BitcoinPathSearchRequest
        do {
            request = try makeRequest(validate: true)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        searchTask?.cancel()
        isSearching = true
        hasSearched = false
        results = []
        savedCount = nil
        errorMessage = nil

        searchTask = Task {
            do {
                let found = try await BitcoinPathSearchEngine.search(
                    walletId: wallet.id,
                    request: request,
                    database: AppDatabase.shared
                )
                await MainActor.run {
                    results = found
                    hasSearched = true
                    isSearching = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    isSearching = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    hasSearched = true
                    isSearching = false
                }
            }
        }
    }

    @MainActor
    private func saveAndUse(_ result: BitcoinPathSearchResult) async {
        guard isSavingAddress == nil else { return }
        guard let wallet else { return }

        isSavingAddress = result.address
        defer { isSavingAddress = nil }

        do {
            let rowsToSave = saveFoundAddresses ? results : [result]
            let saved = try await BitcoinPathSearchAddressStore(database: AppDatabase.shared).save(
                walletId: wallet.id,
                results: rowsToSave,
                preferredResult: result
            )
            savedCount = saved
            onUseAddress(result.address)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makeRequest(validate: Bool) throws -> BitcoinPathSearchRequest {
        let request = BitcoinPathSearchRequest(
            purpose: purpose,
            accountStart: try parseInteger(accountFrom),
            accountEnd: try parseInteger(accountTo),
            changeStart: try parseInteger(changeFrom),
            changeEnd: try parseInteger(changeTo),
            indexStart: try parseInteger(indexFrom),
            indexEnd: try parseInteger(indexTo)
        )
        if validate {
            do {
                try request.validate()
            } catch {
                errorMessage = error.localizedDescription
                throw error
            }
        }
        return request
    }

    private func parseInteger(_ text: String) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 0 else {
            throw BitcoinPathSearchError.invalidRange
        }
        return value
    }
}

private struct BitcoinReceivePathResultRow: View {
    let result: BitcoinPathSearchResult
    let isCurrent: Bool
    let isSaving: Bool
    let onUse: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: UniSpacing.s) {
            Image(systemName: result.totalSats > 0 ? "bitcoinsign.circle.fill" : "clock.arrow.circlepath")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(result.totalSats > 0 ? UniColors.Tint.accent : UniColors.Icon.secondary)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: result.path)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(verbatim: WalletFormatting.shortAddress(result.address, prefix: 8, suffix: 6))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(UniColors.Text.secondary)
                HStack(spacing: UniSpacing.xs) {
                    Text(verbatim: formatBTC(result.btcAmount))
                    Text(verbatim: result.historyCount == 1 ? "1 tx" : "\(result.historyCount) tx")
                    if result.unconfirmedSats != 0 {
                        Text("unconfirmed")
                            .foregroundStyle(UniColors.Feedback.Warning.foreground)
                    }
                }
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
            }

            Spacer()

            UniButton(
                title: isCurrent ? "Current" : "Use",
                variant: isCurrent ? .secondary : .primary,
                isLoading: isSaving,
                isEnabled: !isCurrent && !isSaving,
                action: onUse
            )
            .frame(width: 96)
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
    }

    private func formatBTC(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 8
        let number = value as NSDecimalNumber
        return "\(formatter.string(from: number) ?? number.stringValue) BTC"
    }
}
