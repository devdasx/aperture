import SwiftUI

/// Settings -> Wallets -> Wallet -> Bitcoin path search.
///
/// This is a wallet-repair/discovery tool, not a receive-screen shortcut.
/// It derives explicit Bitcoin BIP paths from the wallet's stored mnemonic,
/// asks Electrum for balance + history, then optionally persists only the
/// funded/used addresses into `WalletAddressRecord` so the rest of the app
/// remains database-backed.
struct BitcoinPathSearchView: View {
    let walletId: UUID

    @StateObject private var databaseSnapshot = DatabaseSnapshotObservation()

    @State private var purpose: BitcoinPathSearchPurpose = .bip84
    @State private var accountFrom: String = "0"
    @State private var accountTo: String = "0"
    @State private var changeFrom: String = "0"
    @State private var changeTo: String = "1"
    @State private var indexFrom: String = "0"
    @State private var indexTo: String = "20"
    @State private var saveFoundAddresses: Bool = true

    @State private var isSearching: Bool = false
    @State private var hasSearched: Bool = false
    @State private var results: [BitcoinPathSearchResult] = []
    @State private var savedCount: Int?
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    private var wallet: WalletRecord? {
        databaseSnapshot.wallets.first { $0.id == walletId }
    }

    private var walletName: String {
        wallet?.name ?? String.apertureLocalized("Wallet")
    }

    private var requestPreview: BitcoinPathSearchRequest? {
        try? makeRequest(validate: false)
    }

    private var targetCount: Int {
        requestPreview?.targetCount ?? 0
    }

    private var targetCountLabel: String {
        guard targetCount > 0 else { return "Enter valid ranges" }
        if targetCount == 1 { return "1 address" }
        return "\(targetCount) addresses"
    }

    var body: some View {
        List {
            overviewSection
            pathSection
            saveSection
            runSection
            resultsSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Bitcoin path search"))
        .navigationBarTitleDisplayMode(.large)
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

    private var overviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                HStack(spacing: UniSpacing.s) {
                    SettingsIconTile(
                        systemImage: "point.3.connected.trianglepath.dotted",
                        tint: UniColors.Tint.accent
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: walletName)
                            .font(UniTypography.headline)
                            .foregroundStyle(UniColors.Text.primary)
                        Text("Search balance and history by exact Bitcoin derivation path.")
                            .font(UniTypography.subheadline)
                            .foregroundStyle(UniColors.Text.secondary)
                    }
                }

                Text("Use this when funds were sent to a different account, change branch, or legacy SegWit path. Aperture checks Electrum and saves only addresses that have balance or history when you keep saving enabled.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, UniSpacing.xxs)
        }
    }

    private var pathSection: some View {
        Section {
            Picker("Address type", selection: $purpose) {
                ForEach(BitcoinPathSearchPurpose.allCases) { option in
                    Text(verbatim: option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding(.vertical, UniSpacing.xxs)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: purpose.pathTemplate)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(UniColors.Text.primary)
                Text(verbatim: purpose.subtitle)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
            .padding(.vertical, UniSpacing.xxs)

            rangeRow(
                title: "Account",
                subtitle: "Hardened account number",
                from: $accountFrom,
                to: $accountTo
            )
            rangeRow(
                title: "Branch",
                subtitle: "0 receive, 1 change",
                from: $changeFrom,
                to: $changeTo
            )
            rangeRow(
                title: "Index",
                subtitle: "Address index inside each branch",
                from: $indexFrom,
                to: $indexTo
            )
        } header: {
            Text("Path range")
        } footer: {
            Text(verbatim: "This run will check \(targetCountLabel). Keep searches under \(BitcoinPathSearchRequest.maxTargets) addresses so the phone stays responsive.")
        }
    }

    private var saveSection: some View {
        Section {
            Toggle(isOn: $saveFoundAddresses) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save found addresses")
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                    Text("Saved addresses become part of this wallet's database record and sync with balance/history scans.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                }
            }
        }
    }

    private var runSection: some View {
        Section {
            UniButton(
                title: "Search paths",
                variant: .primary,
                isLoading: isSearching,
                isEnabled: !isSearching
            ) {
                startSearch()
            }
            .listRowInsets(EdgeInsets(
                top: UniSpacing.s,
                leading: UniSpacing.s,
                bottom: UniSpacing.s,
                trailing: UniSpacing.s
            ))
            .listRowBackground(Color.clear)

            if let savedCount {
                Label {
                    Text(verbatim: savedCount == 1 ? "Saved 1 address" : "Saved \(savedCount) addresses")
                        .font(UniTypography.subheadline)
                        .foregroundStyle(UniColors.Feedback.Success.foreground)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(UniColors.Feedback.Success.foreground)
                }
                .padding(.vertical, UniSpacing.xxs)
            }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if !hasSearched {
            Section {
                Text("Results appear here after the search finishes.")
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
        } else if results.isEmpty {
            Section {
                UniListEmptyState(
                    title: "No funded paths found.",
                    detail: "Try another account, branch, index range, or address type.",
                    minHeight: 260
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, UniSpacing.l)
            }
        } else {
            Section {
                ForEach(results) { result in
                    resultRow(result)
                }
            } header: {
                Text(verbatim: results.count == 1 ? "Found 1 path" : "Found \(results.count) paths")
            }
        }
    }

    private func rangeRow(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        from: Binding<String>,
        to: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                    Text(subtitle)
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                }

                Spacer()

                HStack(spacing: UniSpacing.xs) {
                    compactNumberField("From", text: from)
                    Text("to")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                    compactNumberField("To", text: to)
                }
            }
        }
        .padding(.vertical, UniSpacing.xxs)
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

    private func resultRow(_ result: BitcoinPathSearchResult) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: result.path)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .foregroundStyle(UniColors.Text.primary)
                    Text(verbatim: result.address)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(UniColors.Text.secondary)
                        .lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: formatBTC(result.btcAmount))
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(result.totalSats > 0 ? UniColors.Text.primary : UniColors.Text.secondary)
                    Text(verbatim: result.historyCount == 1 ? "1 tx" : "\(result.historyCount) tx")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                }
            }

            if result.unconfirmedSats != 0 {
                Text("Includes unconfirmed balance")
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Feedback.Warning.foreground)
            }
        }
        .padding(.vertical, UniSpacing.xxs)
    }

    private func startSearch() {
        guard let request = try? makeRequest(validate: true) else { return }
        searchTask?.cancel()

        let walletId = walletId
        let shouldSave = saveFoundAddresses

        isSearching = true
        hasSearched = false
        results = []
        savedCount = nil
        errorMessage = nil

        searchTask = Task {
            do {
                let found = try await BitcoinPathSearchEngine.search(
                    walletId: walletId,
                    request: request,
                    database: AppDatabase.shared
                )
                let saved = shouldSave && !found.isEmpty
                    ? try await BitcoinPathSearchAddressStore(database: AppDatabase.shared)
                        .save(walletId: walletId, results: found)
                    : nil

                await MainActor.run {
                    results = found
                    savedCount = saved
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

    private func formatBTC(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 8
        let number = value as NSDecimalNumber
        return "\(formatter.string(from: number) ?? number.stringValue) BTC"
    }
}
