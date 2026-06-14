import SwiftUI
import SwiftData

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
/// - `.entry` — chain Picker + contract `UniTextField`. Save disabled
///   until the validator says `.valid`.
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
    /// displayed chain on Receive). `nil` means the picker starts on
    /// `.ethereum` — the safe default since most user-added tokens
    /// are ERC-20.
    let initialChain: SupportedChain?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var selectedChain: SupportedChain
    @State private var contractInput: String = ""
    @State private var phase: Phase = .entry
    @State private var editedName: String = ""
    @State private var editedSymbol: String = ""
    @State private var validatedContract: String? = nil
    @State private var fetchTask: Task<Void, Never>? = nil

    init(initialChain: SupportedChain? = nil, onSaved: @escaping () -> Void) {
        self.initialChain = initialChain
        self.onSaved = onSaved
        _selectedChain = State(initialValue: initialChain ?? .ethereum)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.l) {
                    chainAndContractSection

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
            .background(UniColors.Background.primary)
            .navigationTitle("Add custom token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        fetchTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if case .preview = phase {
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                            .disabled(!canSave)
                    }
                }
            }
        }
        .onChange(of: contractInput) { _, _ in
            scheduleFetch()
        }
        .onChange(of: selectedChain) { _, _ in
            // Switching chain re-validates and re-fetches.
            scheduleFetch()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var chainAndContractSection: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            UniCaption(text: "Network", color: UniColors.Text.tertiary)
            chainPicker

            UniCaption(
                text: selectedChain.family == .ed25519 && selectedChain == .solana
                    ? "Token mint"
                    : "Contract address",
                color: UniColors.Text.tertiary
            )
            UniTextField(
                placeholder: selectedChain == .solana
                    ? LocalizedStringKey("Paste the mint address")
                    : LocalizedStringKey("Paste the contract address"),
                text: $contractInput,
                directionPolicy: .forceLTR,
                axis: .vertical,
                lineLimit: 2,
                autocapitalization: .never,
                disablesAutocorrection: true
            )
        }
    }

    @ViewBuilder
    private var chainPicker: some View {
        Menu {
            ForEach(Self.supportedChainsForCustomTokens, id: \.self) { chain in
                Button {
                    selectedChain = chain
                } label: {
                    if chain == selectedChain {
                        Label(chain.displayName, systemImage: "checkmark")
                    } else {
                        Text(chain.displayName)
                    }
                }
            }
        } label: {
            HStack {
                Text(verbatim: selectedChain.displayName)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.tertiary)
            }
            .padding(.horizontal, UniSpacing.m)
            .padding(.vertical, UniSpacing.s)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                    .fill(UniColors.Background.secondary)
            )
        }
        .uniHaptic(.selection, trigger: selectedChain.rawValue)
    }

    @ViewBuilder
    private var guidanceSection: some View {
        VStack(alignment: .leading, spacing: UniSpacing.xxs) {
            UniBody(
                text: selectedChain == .solana
                    ? "Paste an SPL token mint address. Aperture reads decimals from the mint and looks up name + symbol from Metaplex."
                    : "Paste an ERC-20-style contract address. Aperture reads name, symbol, and decimals directly from the contract.",
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
                    contract: validatedContract,
                    customIconURL: result.iconURL
                )
                .frame(width: 64, height: 64)
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
                    .foregroundStyle(UniColors.Status.warningForeground)
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

    private static let supportedChainsForCustomTokens: [SupportedChain] = [
        .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
        .polygon, .bnbChain, .opBNB, .avalanche, .celo, .kavaEvm,
        .solana,
    ]

    // MARK: - Actions

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
        let result: ValidationResult = selectedChain == .solana
            ? ContractValidator.validateSolanaMint(trimmed)
            : ContractValidator.validateEVM(trimmed)

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
                let iconURL = await probeTrustWalletIcon(contract: contract)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.phase = .preview(PreviewResult(
                        name: meta.name,
                        symbol: meta.symbol,
                        decimals: meta.decimals,
                        iconURL: iconURL,
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
                // Rule #28: the mint info, Metaplex metadata, and icon
                // probe are independent — run them concurrently instead of
                // one-after-another so the preview resolves ~3x faster. If
                // `fetchMintInfo` throws, structured concurrency cancels
                // the other two automatically.
                async let mintInfoTask = adapter.fetchMintInfo(mint: contract)
                async let metaplexTask = adapter.fetchMetaplexMetadata(mint: contract)
                async let iconTask = probeTrustWalletIcon(contract: contract)
                let mintInfo = try await mintInfoTask
                let metaplex = await metaplexTask
                let iconURL = await iconTask
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
                        iconURL: iconURL,
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

    /// HEAD-probe the Trust Wallet logo URL. Returns the URL string
    /// if the asset exists, nil otherwise. The probe is best-effort
    /// — a failure here is not a save blocker (the letter-glyph
    /// fallback renders fine).
    private func probeTrustWalletIcon(contract: String) async -> String? {
        guard let url = CoinMarkCache.trustWalletURL(
            chain: selectedChain,
            contract: contract
        ) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                return url.absoluteString
            }
            return nil
        } catch {
            return nil
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
        let iconURL = result.iconURL
        let metadataFromChain = result.metadataFromChain

        let onSavedClosure = self.onSaved
        let container = modelContext.container

        Task { @MainActor in
            let repo = CustomTokenRepository(modelContainer: container)
            do {
                try await repo.add(
                    chain: chain,
                    contract: contract,
                    symbol: symbol,
                    name: name,
                    decimals: decimals,
                    iconURL: iconURL,
                    metadataFromChain: metadataFromChain
                )
                onSavedClosure()
                dismiss()
            } catch CustomTokenError.duplicate {
                phase = .failed(.duplicate)
            } catch {
                phase = .failed(.persistence)
            }
        }
    }

    private func abbreviated(_ contract: String) -> String {
        guard contract.count > 12 else { return contract }
        let prefix = contract.prefix(6)
        let suffix = contract.suffix(4)
        return "\(prefix)…\(suffix)"
    }
}

// MARK: - Phase

extension AddCustomTokenSheet {
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
        let iconURL: String?
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
                    return chain == .solana
                        ? "Not a valid Solana mint — base58 mints decode to 32 bytes."
                        : "Not a valid EVM address — must be 0x followed by 40 hex characters."
                case .invalidCharacter:
                    return chain == .solana
                        ? "Mint contains characters that aren't valid base58."
                        : "Contract contains characters that aren't valid hexadecimal."
                case .invalidChecksum:
                    return "EIP-55 checksum doesn't match. Double-check the address — one wrong letter case can mean the wrong contract."
                case .notBase58:
                    return "Mint isn't valid base58 — paste it again from your source."
                }
            case .fetch:
                return "Couldn't fetch metadata. The contract may not implement the standard ERC-20 / SPL surface, or the network may be unreachable."
            case .duplicate:
                return "This token is already in your Custom Tokens list."
            case .persistence:
                return "Couldn't save the token locally. Try again."
            }
        }
    }
}
