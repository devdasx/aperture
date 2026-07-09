import SwiftUI
import UniformTypeIdentifiers

/// Add Custom Token sheet — paste a contract / mint, Aperture fetches
/// the rest.
///
/// **Design intent (Rule #2 §D.1).** Resolve the user's question in
/// the order it actually surfaces in their head: *"which chain is the
/// token on?"* (the first thing they know), *"what's the contract?"*
/// (the thing they're pasting), *"is this real?"* (Aperture's
/// answer: live `eth_call` / Solana RPC for name+symbol+decimals,
/// Trust Wallet probe for the icon). The result lands as a preview
/// card with the same visual shape as `ReceiveQRDetailView`'s asset
/// header — same icon size, same `UniHeadline` for the symbol, same
/// secondary line for the name — so the user reads it as a token
/// row, not a form.
///
/// **Phases.**
/// - `.networkSelection` — Receive-style supported-network picker.
/// - `.entry` — contract `UniTextField`. Save disabled until the
///   validator says `.valid`.
/// - `.fetching` — calm spinner + "Fetching token info…". Auto-fired
///   when the contract leaves `.valid` shape.
/// - `.preview(...)` — `UniCard` with icon + symbol + name + contract
///   abbreviation + decimals. Editable name + symbol when the chain
///   is Solana AND Metaplex returned nil; locked when chain returned
///   real metadata.
/// - `.failed(reason)` — calm sentence per the `ValidationError` /
///   metadata-fetch outcome. Single CTA: "Try again."
///
/// **Layers (Rule #2 §B.3).** Content layer — opaque `UniCard`s,
/// opaque text fields, opaque list. Functional layer — the sheet's
/// system nav bar + the `Save` `UniButton(.primary)`. Two glass
/// layers max.
///
/// **Honesty (Rule #16).** The footer line "Aperture reads what the
/// contract says about itself. We don't audit token contracts —
/// verify trust before holding." stays visible on every phase, never
/// hidden behind a disclosure.
struct AddCustomTokenSheet: View {
    /// Chain pre-selected by the call site (e.g. wallet's currently
    /// displayed chain on Receive). The sheet still starts on the
    /// network picker; this value only chooses the first contract-entry
    /// network when a caller has a strong context.
    let initialChain: SupportedChain?
    let availableChains: [SupportedChain]
    let actionContext: ActionContext
    let onSaved: () -> Void
    let onUseIncludedToken: (TokenNavigationTarget) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedChain: SupportedChain
    @State private var navigationPath: [Destination] = []
    @State private var networkSearchText: String = ""
    @State private var contractInput: String = ""
    @State private var phase: Phase = .entry
    @State private var editedName: String = ""
    @State private var editedSymbol: String = ""
    @State private var validatedContract: String? = nil
    @State private var fetchTask: Task<Void, Never>? = nil
    @State private var isImportingCSV: Bool = false
    @State private var isExportingCSV: Bool = false
    @State private var csvExportDocument = CustomTokenCSVDocument()
    @State private var csvAlert: CSVAlert?
    @State private var includedTokenAlert: IncludedTokenAlert?
    @State private var isScanningContract: Bool = false

    init(
        initialChain: SupportedChain? = nil,
        availableChains: [SupportedChain] = [],
        actionContext: ActionContext = .none,
        onSaved: @escaping () -> Void,
        onUseIncludedToken: @escaping (TokenNavigationTarget) -> Void = { _ in }
    ) {
        self.initialChain = initialChain
        self.availableChains = availableChains
        self.actionContext = actionContext
        self.onSaved = onSaved
        self.onUseIncludedToken = onUseIncludedToken

        let choices = CustomTokenSupport.orderedChains(availableChains: availableChains)
        let normalizedInitial = CustomTokenSupport.normalizedInitialChain(initialChain)
        let selected = choices.contains(normalizedInitial)
            ? normalizedInitial
            : (choices.first ?? normalizedInitial)
        _selectedChain = State(initialValue: selected)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            networkSelectionScreen
            .background(UniColors.Background.primary)
            .navigationTitle("Choose network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if navigationPath.isEmpty {
                        Button("Cancel") {
                            fetchTask?.cancel()
                            dismiss()
                        }
                        .tint(UniColors.Button.text)
                    }
                }
            }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .contractEntry(let chain):
                    contractEntryScreen
                        .background(UniColors.Background.primary)
                        .navigationTitle("Add on \(chain.displayName)")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                if case .preview = phase {
                                    Button("Save") { save() }
                                        .tint(UniColors.Button.text)
                                        .fontWeight(.semibold)
                                        .disabled(!canSave)
                                }
                            }
                        }
                }
            }
        }
        .onChange(of: navigationPath) { _, newPath in
            guard newPath.isEmpty else { return }
            resetContractEntryState(clearInput: true)
        }
        .onChange(of: contractInput) { _, _ in
            scheduleFetch()
        }
        .onChange(of: selectedChain) { _, _ in
            // Switching chain re-validates and re-fetches.
            scheduleFetch()
        }
        .fileImporter(
            isPresented: $isImportingCSV,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleCSVImport(result)
        }
        .fileExporter(
            isPresented: $isExportingCSV,
            document: csvExportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: "aperture-custom-tokens.csv"
        ) { result in
            if case .failure(let error) = result {
                csvAlert = CSVAlert(
                    title: "Couldn't export CSV",
                    message: error.localizedDescription
                )
            }
        }
        .alert(item: $csvAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(item: $includedTokenAlert) { alert in
            if let actionTitle = actionContext.actionTitle {
                Alert(
                    title: Text("Token already included"),
                    message: Text(alert.message),
                    primaryButton: .default(Text(actionTitle)) {
                        onUseIncludedToken(alert.target)
                        dismiss()
                    },
                    secondaryButton: .cancel(Text("OK"))
                )
            } else {
                Alert(
                    title: Text("Token already included"),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .fullScreenCover(isPresented: $isScanningContract) {
            UniQRScannerSheet(
                title: "Scan contract",
                prompt: scannerPrompt,
                onRawDeliver: { payload in
                    applyIncomingContract(payload)
                    isScanningContract = false
                }
            )
            .uniAppEnvironment()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var networkSelectionScreen: some View {
        List {
            csvSection

            if filteredNetworkChoices.isEmpty {
                Section {
                    UniListEmptyState(
                        title: networkEmptyTitle,
                        detail: networkEmptyDetail,
                        mark: .icon(systemName: "network.slash"),
                        minHeight: 300
                    )
                }
            } else {
                Section {
                    ForEach(filteredNetworkChoices, id: \.self) { chain in
                        Button {
                            openContractEntry(for: chain)
                        } label: {
                            AssetPickerNetworkRow(
                                chain: chain,
                                subtitle: networkSubtitle(for: chain),
                                totals: AssetPickerHoldings.Totals(),
                                currencyCode: CurrencyPreference.defaultCode
                            )
                        }
                        .buttonStyle(.uniListRow)
                        .listRowBackground(UniColors.List.rowBackground)
                        .accessibilityLabel(Text(verbatim: chain.displayName))
                        .accessibilityHint(Text("Add a custom token on \(chain.displayName)"))
                    }
                } footer: {
                    UniFootnote(
                        text: "Choose the network where the token contract exists. Aperture will ask for that network's contract or mint address next.",
                        color: UniColors.Text.tertiary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, UniSpacing.xs)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .searchable(text: $networkSearchText, prompt: Text("Search"))
    }

    @ViewBuilder
    private var csvSection: some View {
        Section {
            Button {
                isImportingCSV = true
            } label: {
                Label("Import token list CSV", systemImage: "square.and.arrow.down")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
            }
            .buttonStyle(.uniListRow)
            .listRowBackground(UniColors.List.rowBackground)

            Button {
                prepareCSVExport()
            } label: {
                Label("Export custom tokens CSV", systemImage: "square.and.arrow.up")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
            }
            .buttonStyle(.uniListRow)
            .listRowBackground(UniColors.List.rowBackground)
        } header: {
            UniCaption(text: "Token lists", color: UniColors.Text.tertiary)
        } footer: {
            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                UniFootnote(
                    text: "CSV format: chain, contract, symbol, name, decimals, metadata_from_chain.",
                    color: UniColors.Text.tertiary
                )
                UniFootnote(
                    text: "Example: tron,TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t,USDT,Tether USD,6,true",
                    color: UniColors.Text.tertiary
                )
                UniFootnote(
                    text: "Use chain IDs like solana, tron, ethereum, base, arbitrum, polygon, bnbChain, optimism, avalanche, zkSync, scroll, celo, or opBNB.",
                    color: UniColors.Text.tertiary
                )
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, UniSpacing.xs)
        }
    }

    private var networkEmptyTitle: LocalizedStringKey {
        let query = networkSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? "No supported networks." : "No networks match your search."
    }

    private var networkEmptyDetail: LocalizedStringKey {
        let query = networkSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "This wallet does not have a Solana, TRON, or EVM receive address available for custom tokens."
        }
        return "Try Solana, TRON, Ethereum, Base, Arbitrum, or another supported EVM network."
    }

    @ViewBuilder
    private var contractEntryScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                contractSection

                switch phase {
                case .entry:
                    guidanceSection
                case .fetching:
                    fetchingSection
                case .preview(let result):
                    previewSection(result: result)
                case .failed(let reason):
                    failedSection(reason: reason)
                }

                honestyFooter
            }
            .padding(.horizontal, UniSpacing.m)
            .padding(.vertical, UniSpacing.l)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var contractSection: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            UniCaption(
                text: contractFieldLabel,
                color: UniColors.Text.tertiary
            )
            ContractAddressInputField(
                placeholder: contractFieldPlaceholder,
                text: $contractInput,
                label: contractFieldLabel,
                onPaste: pasteContractFromClipboard,
                onScan: {
                    UniHapticEngine.shared.play(.selection)
                    isScanningContract = true
                }
            )
        }
    }

    @ViewBuilder
    private var guidanceSection: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xxs) {
            UniBody(
                text: guidanceCopy,
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var fetchingSection: some View {
        HStack(spacing: UniSpacing.s) {
            ProgressView()
                .controlSize(.small)
                .tint(UniColors.Tint.accent)
            UniBody(text: "Fetching token info…", color: UniColors.Text.secondary)
        }
        .padding(.vertical, UniSpacing.s)
    }

    @ViewBuilder
    private func previewSection(result: PreviewResult) -> some View {
        UniCard {
            VStack(spacing: UniSpacing.m) {
                // Icon + symbol + name — same shape as the asset
                // header on `ReceiveQRDetailView`.
                CoinMark(
                    chain: selectedChain,
                    tokenSymbol: editedSymbol.isEmpty ? result.symbol : editedSymbol,
                    contract: validatedContract
                )
                .frame(width: AssetLogoMetrics.standard, height: AssetLogoMetrics.standard)
                .accessibilityHidden(true)

                VStack(spacing: UniSpacing.xxs) {
                    if result.metadataFromChain {
                        UniHeadline(text: LocalizedStringKey(result.symbol), alignment: .center)
                        UniSubtitle(
                            text: LocalizedStringKey(result.name),
                            alignment: .center,
                            color: UniColors.Text.secondary
                        )
                    } else {
                        // User-typed fallback — editable fields. The
                        // visual register stays the same; the user
                        // can adjust before saving.
                        UniTextField(
                            placeholder: "Symbol (e.g. PEPE)",
                            text: $editedSymbol,
                            directionPolicy: .automatic
                        )
                        UniTextField(
                            placeholder: "Name (e.g. Pepe)",
                            text: $editedName,
                            directionPolicy: .automatic
                        )
                    }
                }

                UniDivider()

                metadataRow(
                    label: "Decimals",
                    value: "\(result.decimals)"
                )
                metadataRow(
                    label: "Contract",
                    value: abbreviated(validatedContract ?? "")
                )
                metadataRow(
                    label: "Network",
                    value: selectedChain.displayName
                )

                if !result.metadataFromChain {
                    UniFootnote(
                        text: "Aperture couldn't read name and symbol from chain — please confirm above.",
                        color: UniColors.Text.tertiary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, UniSpacing.xs)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func failedSection(reason: FailureReason) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            HStack(alignment: .top, spacing: UniSpacing.s) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(UniColors.Feedback.Warning.foreground)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                UniBody(text: reason.copy, color: UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            UniButton(title: "Try again", variant: .secondary) {
                scheduleFetch()
            }
        }
        .padding(.vertical, UniSpacing.s)
    }

    @ViewBuilder
    private var honestyFooter: some View {
        UniFootnote(
            text: "Aperture reads what the contract says about itself. We don't audit token contracts — verify trust before holding.",
            color: UniColors.Text.tertiary
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func metadataRow(label: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(label)
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.tertiary)
            Spacer()
            Text(verbatim: value)
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.primary)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Derived

    /// Whether the Save button is enabled in `.preview` phase. The
    /// user-edited symbol and name must be non-empty (when they're
    /// editable); when metadata came from chain, the cached values
    /// are always non-empty.
    private var canSave: Bool {
        guard case let .preview(result) = phase else { return false }
        if result.metadataFromChain { return true }
        return !editedSymbol.trimmingCharacters(in: .whitespaces).isEmpty
            && !editedName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var contractFieldLabel: LocalizedStringKey {
        selectedChain == .solana ? "Token mint" : "Contract address"
    }

    private var contractFieldPlaceholder: LocalizedStringKey {
        switch selectedChain {
        case .solana:
            return "Paste the mint address"
        case .tron:
            return "Paste the TRC-20 contract address"
        default:
            return "Paste the contract address"
        }
    }

    private var guidanceCopy: LocalizedStringKey {
        switch selectedChain {
        case .solana:
            return "Paste an SPL token mint address. Aperture reads decimals from the mint and looks up name + symbol from Metaplex."
        case .tron:
            return "Paste a TRC-20 contract address. Aperture reads name, symbol, and decimals directly from the contract."
        default:
            return "Paste an ERC-20-style contract address. Aperture reads name, symbol, and decimals directly from the contract."
        }
    }

    private var scannerPrompt: LocalizedStringKey {
        switch selectedChain {
        case .solana:
            return "Point your camera at an SPL token mint QR code."
        case .tron:
            return "Point your camera at a TRC-20 contract QR code."
        default:
            return "Point your camera at an ERC-20 contract QR code."
        }
    }

    private var networkChoices: [SupportedChain] {
        CustomTokenSupport.orderedChains(availableChains: availableChains)
    }

    private var filteredNetworkChoices: [SupportedChain] {
        let query = networkSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return networkChoices }
        return networkChoices.filter {
            $0.displayName.localizedStandardContains(query) || $0.ticker.localizedStandardContains(query)
        }
    }

    private func networkSubtitle(for chain: SupportedChain) -> LocalizedStringKey {
        switch chain {
        case .solana:
            return "Add an SPL token"
        case .tron:
            return "Add a TRC-20 token"
        default:
            return "Add an ERC-20 token"
        }
    }

    // MARK: - Actions

    private func openContractEntry(for chain: SupportedChain) {
        fetchTask?.cancel()
        let changedNetwork = chain != selectedChain
        selectedChain = chain
        networkSearchText = ""
        if changedNetwork {
            contractInput = ""
        }
        phase = .entry
        validatedContract = nil
        navigationPath.append(.contractEntry(chain))
    }

    private func resetContractEntryState(clearInput: Bool) {
        fetchTask?.cancel()
        phase = .entry
        validatedContract = nil
        editedName = ""
        editedSymbol = ""
        if clearInput {
            contractInput = ""
        }
    }

    private func prepareCSVExport() {
        Task { @MainActor in
            do {
                let snapshots = try CustomTokenRepository(database: AppDatabase.shared).fetchAll()
                let records = snapshots.map {
                    CustomTokenRecord(
                        id: $0.id,
                        chainRaw: $0.chain.rawValue,
                        contract: $0.contract,
                        symbol: $0.symbol,
                        name: $0.name,
                        decimals: $0.decimals,
                        addedAt: $0.addedAt,
                        metadataFromChain: $0.metadataFromChain
                    )
                }
                csvExportDocument = CustomTokenCSVDocument(text: CustomTokenCSV.export(records: records))
                isExportingCSV = true
            } catch {
                csvAlert = CSVAlert(
                    title: "Couldn't export CSV",
                    message: "Aperture couldn't read your custom tokens from the local database."
                )
            }
        }
    }

    private func pasteContractFromClipboard() {
        UniHapticEngine.shared.play(.selection)
        guard let pasted = SafePasteboard.trimmedString else { return }
        applyIncomingContract(pasted)
    }

    private func applyIncomingContract(_ raw: String) {
        let clean = parseIncomingContract(raw)
        guard !clean.isEmpty else { return }
        contractInput = clean
    }

    private func parseIncomingContract(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeRange = value.range(of: ":"), value.range(of: "://") == nil {
            let afterScheme = String(value[schemeRange.upperBound...])
            if !afterScheme.isEmpty {
                value = afterScheme
            }
        }
        if let queryStart = value.firstIndex(of: "?") {
            value = String(value[..<queryStart])
        }
        if let atSign = value.firstIndex(of: "@") {
            value = String(value[..<atSign])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handleCSVImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            csvAlert = CSVAlert(title: "Couldn't import CSV", message: error.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            importCSV(from: url)
        }
    }

    private func importCSV(from url: URL) {
        Task { @MainActor in
            do {
                let didStartAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccess {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let text = try String(contentsOf: url, encoding: .utf8)
                let parse = CustomTokenCSV.parse(text, allowedChains: availableChains)
                var summary = CustomTokenCSV.ImportSummary(
                    failed: parse.errors.count,
                    errors: parse.errors
                )
                let repo = CustomTokenRepository(database: AppDatabase.shared)
                for row in parse.rows {
                    do {
                        try repo.add(
                            chain: row.chain,
                            contract: row.contract,
                            symbol: row.symbol,
                            name: row.name,
                            decimals: row.decimals,
                            metadataFromChain: row.metadataFromChain
                        )
                        summary.added += 1
                    } catch CustomTokenError.duplicate {
                        summary.duplicates += 1
                    } catch {
                        summary.failed += 1
                        summary.errors.append("Line \(row.line): couldn't save token.")
                    }
                }
                if summary.added > 0 {
                    UniHapticEngine.shared.fire(.success)
                }
                csvAlert = CSVAlert(title: summary.title, message: summary.message)
            } catch {
                csvAlert = CSVAlert(
                    title: "Couldn't import CSV",
                    message: "Aperture couldn't read this file as UTF-8 CSV."
                )
            }
        }
    }

    private func scheduleFetch() {
        // Cancel any in-flight fetch — the user changed something.
        fetchTask?.cancel()
        let trimmed = contractInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .entry
            validatedContract = nil
            return
        }

        // Validate shape.
        let result = validateContractInput(trimmed)

        switch result {
        case .invalid(let reason):
            // While the user is still typing, stay quiet on `.empty`
            // and `.wrongLength` — those are mid-type states. Only
            // surface `.invalidChecksum` / `.invalidCharacter` /
            // `.notBase58` immediately since those mean a bad paste.
            if reason == .empty || reason == .wrongLength {
                phase = .entry
            } else {
                phase = .failed(.validation(reason, chain: selectedChain))
            }
            validatedContract = nil
            return
        case .valid(let normalized):
            validatedContract = normalized
            phase = .fetching
            fetchTask = Task {
                await runFetch(contract: normalized)
            }
        }
    }

    private func runFetch(contract: String) async {
        // Per Rule #21 — full completion contract. Both EVM and
        // Solana paths execute fully and surface every outcome
        // honestly.
        switch selectedChain.family {
        case .evm:
            let adapter = EVMChainAdapter(chain: selectedChain, client: RPCClient.shared)
            do {
                let meta = try await adapter.fetchTokenMetadata(contract: contract)
                // A newer fetch may have superseded this one while we
                // were awaiting — a cancelled task must never write
                // its stale result over the current phase.
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.phase = .preview(PreviewResult(
                        name: meta.name,
                        symbol: meta.symbol,
                        decimals: meta.decimals,
                        metadataFromChain: true
                    ))
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.phase = .failed(.fetch(chain: selectedChain))
                }
            }
        case .tron:
            let adapter = TronChainAdapter(client: RPCClient.shared)
            do {
                let meta = try await adapter.fetchTokenMetadata(contract: contract)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.phase = .preview(PreviewResult(
                        name: meta.name,
                        symbol: meta.symbol,
                        decimals: meta.decimals,
                        metadataFromChain: true
                    ))
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.phase = .failed(.fetch(chain: selectedChain))
                }
            }
        default:
            // Solana
            let adapter = SolanaChainAdapter(client: RPCClient.shared)
            do {
                // Rule #28: the mint info and Metaplex metadata are
                // independent — run them concurrently instead of one after
                // another so the preview resolves faster. If `fetchMintInfo`
                // throws, structured concurrency cancels the metadata task.
                async let mintInfoTask = adapter.fetchMintInfo(mint: contract)
                async let metaplexTask = adapter.fetchMetaplexMetadata(mint: contract)
                let mintInfo = try await mintInfoTask
                let metaplex = await metaplexTask
                guard !Task.isCancelled else { return }
                let metadataFromChain = metaplex != nil
                let name = metaplex?.name ?? ""
                let symbol = metaplex?.symbol ?? ""
                await MainActor.run {
                    self.editedName = name
                    self.editedSymbol = symbol
                    self.phase = .preview(PreviewResult(
                        name: name,
                        symbol: symbol,
                        decimals: mintInfo.decimals,
                        metadataFromChain: metadataFromChain
                    ))
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.phase = .failed(.fetch(chain: selectedChain))
                }
            }
        }
    }

    private func validateContractInput(_ trimmed: String) -> ValidationResult {
        switch selectedChain {
        case .solana:
            return ContractValidator.validateSolanaMint(trimmed)
        case .tron:
            return ContractValidator.validateTronContract(trimmed)
        default:
            return ContractValidator.validateEVM(trimmed)
        }
    }

    private func save() {
        guard let contract = validatedContract,
              case let .preview(result) = phase else { return }
        let symbol = result.metadataFromChain
            ? result.symbol
            : editedSymbol.trimmingCharacters(in: .whitespaces)
        let name = result.metadataFromChain
            ? result.name
            : editedName.trimmingCharacters(in: .whitespaces)
        let chain = selectedChain
        let decimals = result.decimals
        let metadataFromChain = result.metadataFromChain

        let onSavedClosure = self.onSaved

        Task { @MainActor in
            let repo = CustomTokenRepository(database: AppDatabase.shared)
            do {
                if let included = try includedTokenTarget(chain: chain, contract: contract, repository: repo) {
                    includedTokenAlert = IncludedTokenAlert(target: included)
                    return
                }
                try repo.add(
                    chain: chain,
                    contract: contract,
                    symbol: symbol,
                    name: name,
                    decimals: decimals,
                    metadataFromChain: metadataFromChain
                )
                onSavedClosure()
                dismiss()
            } catch CustomTokenError.duplicate {
                if let included = try? includedCustomTokenTarget(
                    chain: chain,
                    contract: contract,
                    repository: repo
                ) {
                    includedTokenAlert = IncludedTokenAlert(target: included)
                } else {
                    includedTokenAlert = IncludedTokenAlert(
                        target: TokenNavigationTarget(
                            chain: chain,
                            contract: contract,
                            symbol: symbol,
                            name: name,
                            decimals: decimals,
                            source: .custom
                        )
                    )
                }
            } catch {
                phase = .failed(.persistence)
            }
        }
    }

    private func includedTokenTarget(
        chain: SupportedChain,
        contract: String,
        repository: CustomTokenRepository
    ) throws -> TokenNavigationTarget? {
        if let catalogToken = catalogTokenTarget(chain: chain, contract: contract) {
            return catalogToken
        }
        return try includedCustomTokenTarget(chain: chain, contract: contract, repository: repository)
    }

    private func catalogTokenTarget(chain: SupportedChain, contract: String) -> TokenNavigationTarget? {
        guard let asset = AssetCatalog.allAssets.first(where: {
            $0.chain == chain && ContractTokenDiscovery.contractMatches($0.contract, chain: chain, query: contract)
        }) else {
            return nil
        }
        return TokenNavigationTarget(
            chain: asset.chain,
            contract: asset.contract,
            symbol: asset.symbol,
            name: asset.name,
            decimals: asset.decimals,
            source: .catalog
        )
    }

    private func includedCustomTokenTarget(
        chain: SupportedChain,
        contract: String,
        repository: CustomTokenRepository
    ) throws -> TokenNavigationTarget? {
        guard let token = try repository.fetchByContract(chain: chain, contract: contract) else {
            return nil
        }
        return TokenNavigationTarget(
            chain: token.chain,
            contract: token.contract,
            symbol: token.symbol,
            name: token.name,
            decimals: token.decimals,
            source: .custom
        )
    }

    private func abbreviated(_ contract: String) -> String {
        guard contract.count > 12 else { return contract }
        let prefix = contract.prefix(6)
        let suffix = contract.suffix(4)
        return "\(prefix)…\(suffix)"
    }
}

private struct ContractAddressInputField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    let label: LocalizedStringKey
    let onPaste: () -> Void
    let onScan: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TextField(
                text: $text,
                prompt: Text(placeholder),
                axis: .vertical
            ) {
                Text(label)
            }
            .focused($isFocused)
            .textFieldStyle(.automatic)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .keyboardType(.default)
            .submitLabel(.done)
            .font(UniTypography.body)
            .foregroundStyle(UniColors.Input.text)
            .tint(UniColors.Tint.accent)
            .lineLimit(2...4)
            .padding(.horizontal, UniSpacing.mPlus)
            .padding(.top, UniSpacing.m)
            .padding(.bottom, 62)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .background(inputBackground)
            .environment(\.layoutDirection, .leftToRight)
            .onSubmit {
                isFocused = false
            }
            .onChange(of: text) { _, newValue in
                guard newValue.contains(where: \.isNewline) else { return }
                text = newValue.filter { !$0.isNewline }
                isFocused = false
            }

            fieldUtilities
                .padding(.trailing, UniSpacing.s)
                .padding(.bottom, UniSpacing.s)
        }
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: UniRadius.textField, style: .continuous)
            .fill(isFocused ? UniColors.Input.focusedBackground : UniColors.Input.background)
    }

    private var fieldUtilities: some View {
        HStack(spacing: 8) {
            fieldUtilityButton(
                title: "Paste",
                systemImage: "doc.on.clipboard",
                accessibilityLabel: "Paste contract address",
                action: onPaste
            )
            fieldUtilityButton(
                title: "Scan",
                systemImage: "qrcode.viewfinder",
                accessibilityLabel: "Scan contract address",
                action: onScan
            )
        }
    }

    private func fieldUtilityButton(
        title: LocalizedStringKey,
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(UniColors.Text.primary)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(.regularMaterial, in: Capsule(style: .continuous))
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(UniColors.Input.border.opacity(0.7), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
    }
}

// MARK: - Phase

extension AddCustomTokenSheet {
    enum ActionContext: Equatable {
        case none
        case receive
        case send

        var actionTitle: String? {
            switch self {
            case .none:
                return nil
            case .receive:
                return "Receive"
            case .send:
                return "Send"
            }
        }
    }

    struct TokenNavigationTarget: Sendable, Equatable {
        let chain: SupportedChain
        let contract: String
        let symbol: String
        let name: String
        let decimals: Int
        let source: Source

        enum Source: Sendable, Equatable {
            case catalog
            case custom
        }
    }

    struct IncludedTokenAlert: Identifiable, Equatable {
        let id = UUID()
        let target: TokenNavigationTarget

        var message: String {
            switch target.source {
            case .catalog:
                return "\(target.symbol) on \(target.chain.displayName) is already included in Aperture."
            case .custom:
                return "\(target.symbol) on \(target.chain.displayName) is already in your Custom Tokens list."
            }
        }
    }

    struct CSVAlert: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    enum Destination: Hashable {
        case contractEntry(SupportedChain)
    }

    enum Phase: Equatable {
        case entry
        case fetching
        case preview(PreviewResult)
        case failed(FailureReason)
    }

    struct PreviewResult: Sendable, Equatable {
        let name: String
        let symbol: String
        let decimals: Int
        let metadataFromChain: Bool
    }

    enum FailureReason: Equatable {
        case validation(ValidationError, chain: SupportedChain)
        case fetch(chain: SupportedChain)
        case duplicate
        case persistence

        var copy: LocalizedStringKey {
            switch self {
            case .validation(let reason, let chain):
                switch reason {
                case .empty:
                    return "Paste a contract address to continue."
                case .wrongLength:
                    switch chain {
                    case .solana:
                        return "Not a valid Solana mint — base58 mints decode to 32 bytes."
                    case .tron:
                        return "Not a valid TRON contract address — Base58Check addresses start with T, or use the 41-prefixed hex form."
                    default:
                        return "Not a valid EVM address — must be 0x followed by 40 hex characters."
                    }
                case .invalidCharacter:
                    switch chain {
                    case .solana:
                        return "Mint contains characters that aren't valid base58."
                    case .tron:
                        return "TRON contract contains characters that aren't valid Base58Check or hex."
                    default:
                        return "Contract contains characters that aren't valid hexadecimal."
                    }
                case .invalidChecksum:
                    return chain == .tron
                        ? "TRON address checksum doesn't match. Paste it again from your source."
                        : "EIP-55 checksum doesn't match. Double-check the address — one wrong letter case can mean the wrong contract."
                case .notBase58:
                    return chain == .tron
                        ? "TRON contract isn't valid Base58Check — paste it again from your source."
                        : "Mint isn't valid base58 — paste it again from your source."
                }
            case .fetch:
                return "Couldn't fetch metadata. The contract may not implement the standard ERC-20 / SPL / TRC-20 surface, or the network may be unreachable."
            case .duplicate:
                return "This token is already in your Custom Tokens list."
            case .persistence:
                return "Couldn't save the token locally. Try again."
            }
        }
    }
}
