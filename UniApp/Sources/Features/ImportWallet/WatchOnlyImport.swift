import SwiftUI

// MARK: - Watch-only entry step

struct WatchOnlyEntryView: View {
    @Bindable var state: ImportWalletState
    let chain: SupportedChain
    let onContinue: () -> Void

    @FocusState private var isFieldFocused: Bool
    @State private var isShowingGuide: Bool = false

    private var supportsExtendedKey: Bool { chain.supportsExtendedPublicKey }

    private var headerSubtitleKey: LocalizedStringKey {
        supportsExtendedKey
            ? LocalizedStringKey("Paste one or more addresses, or an extended public key for \(chain.displayName). Aperture reads balances and transactions only — it cannot send.")
            : LocalizedStringKey("Paste one or more \(chain.displayName) addresses. Aperture reads balances and transactions only — it cannot send.")
    }

    private var exampleCaption: ImportExampleCaption {
        if supportsExtendedKey && state.watchOnlyExtendedKeyMode,
           let xkeyPreview = chain.exampleExtendedKeyPreview {
            return ImportExampleCaption(
                caption: "Example only — not a real extended key.",
                example: xkeyPreview,
                monospaced: true
            )
        }
        return ImportExampleCaption(
            caption: "Example only — not a real address.",
            example: chain.exampleAddressPreview,
            monospaced: true
        )
    }

    private var parsedLines: [String] {
        state.watchOnlyRaw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canContinue: Bool {
        if supportsExtendedKey && state.watchOnlyExtendedKeyMode {
            // Extended-key mode: one xpub/ypub/zpub.
            let raw = state.watchOnlyRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if case .extendedPublicKey = state.service.detectFormat(raw, on: chain) {
                return true
            }
            return false
        } else {
            // Address mode: at least one line, all lines validate.
            let lines = parsedLines
            guard !lines.isEmpty else { return false }
            return lines.allSatisfy { state.service.validateAddress($0, on: chain) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                ImportHeaderBlock(
                    title: LocalizedStringKey("Add a watch-only \(chain.displayName) wallet"),
                    subtitle: headerSubtitleKey
                )

                if supportsExtendedKey {
                    modeToggle
                }

                inputField
                exampleCaption

                if !parsedLines.isEmpty && !state.watchOnlyExtendedKeyMode {
                    validationSummary
                }
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.l)
            .padding(.bottom, UniSpacing.xl)
        }
        .background(UniColors.Background.primary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChainNavTitle(chain: chain)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingGuide = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel(Text("What does watch-only mean?"))
            }
        }
        .sheet(isPresented: $isShowingGuide) {
            WatchOnlyGuideSheet(onDismiss: { isShowingGuide = false })
                .uniAppEnvironment()
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
        .safeAreaInset(edge: .bottom) {
            UniButton(title: "Continue", variant: .primary, isEnabled: canContinue) {
                onContinue()
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.bottom, UniSpacing.l)
        }
        .onChange(of: state.watchOnlyExtendedKeyMode) { _, _ in
            // Switching modes clears the buffer — the formats are
            // different and partial input from one mode is invalid
            // in the other.
            state.watchOnlyRaw = ""
        }
    }

    private var modeToggle: some View {
        Picker(selection: $state.watchOnlyExtendedKeyMode) {
            Text("Addresses").tag(false)
            Text("Extended key").tag(true)
        } label: {
            Text("Mode")
        }
        .pickerStyle(.segmented)
    }

    /// Watch-only input — `UniTextField` for the extended-key case,
    /// `TextEditor` + the `TextDirection` helper for the multi-address
    /// case. Both content shapes (xpub/ypub/zpub and on-chain addresses)
    /// are always LTR regardless of the app's locale, so the field forces
    /// LTR so an Arabic-locale user reads `xpub6Cq…` left-to-right with
    /// the caret advancing rightward.
    @ViewBuilder
    private var inputField: some View {
        if supportsExtendedKey && state.watchOnlyExtendedKeyMode {
            UniTextField(
                placeholder: "Paste an extended public key",
                text: $state.watchOnlyRaw,
                directionPolicy: .forceLTR,
                axis: .vertical,
                lineLimit: 3,
                reservesSpace: true,
                contentType: .password
            )
        } else {
            TextEditor(text: $state.watchOnlyRaw)
                .focused($isFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(UniTypography.body.monospaced())
                .scrollContentBackground(.hidden)
                .frame(minHeight: 120)
                .padding(.horizontal, UniSpacing.s)
                .padding(.vertical, UniSpacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                        .fill(UniColors.Background.secondary)
                )
                .environment(\.layoutDirection, .leftToRight)
                .multilineTextAlignment(.leading)
                // Enter = dismiss keyboard, never newline. Detect the
                // single-trailing-newline-on-prior-buffer signal (the
                // user pressed Enter, not pasted multi-line content)
                // and dismiss focus. Multi-line address pastes (where
                // many characters land at once) pass through untouched
                // — the parser already splits on `\n` further down, so
                // those newlines remain meaningful as line separators.
                // Aligns with the `UniTextField` contract; see
                // `CLAUDE.md` Rule #19 §D.
                .onChange(of: state.watchOnlyRaw) { oldValue, newValue in
                    if newValue.count == oldValue.count + 1,
                       newValue.last == "\n",
                       newValue.dropLast() == oldValue {
                        state.watchOnlyRaw = String(newValue.dropLast())
                        isFieldFocused = false
                    }
                }
        }
    }

    private var validationSummary: some View {
        let valid = parsedLines.filter { state.service.validateAddress($0, on: chain) }.count
        let invalid = parsedLines.count - valid
        return HStack(spacing: UniSpacing.xs) {
            Image(systemName: invalid == 0 ? "checkmark" : "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
            Text("\(valid) valid · \(invalid) invalid")
                .font(UniTypography.caption1)
        }
        .foregroundStyle(invalid == 0 ? UniColors.Text.secondary : UniColors.Status.warningForeground)
    }
}

// MARK: - Watch-only review step

struct WatchOnlyReviewView: View {
    @Bindable var state: ImportWalletState
    let chain: SupportedChain
    let onCommit: () -> Void

    @State private var addresses: [String] = []
    @State private var isDeriving = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                if isDeriving {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, UniSpacing.l)
                } else {
                    summary
                    addressList
                }
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.l)
            .padding(.bottom, UniSpacing.xl)
        }
        .background(UniColors.Background.primary)
        .navigationTitle("Review watch-only")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if !isDeriving && !addresses.isEmpty {
                GlassEffectContainer(spacing: UniSpacing.s) {
                    UniButton(title: "Add watch-only wallet", variant: .primary) {
                        onCommit()
                    }
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
            }
        }
        .task {
            await resolveAddresses()
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            UniHeadline(
                text: "Watching \(addresses.count) addresses on \(chain.displayName).",
                alignment: .leading
            )
            .fixedSize(horizontal: false, vertical: true)
            UniBody(
                text: "They will show balances and transactions. They cannot send.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addressList: some View {
        VStack(spacing: 0) {
            ForEach(Array(addresses.enumerated()), id: \.offset) { index, address in
                HStack(spacing: UniSpacing.s) {
                    Text(verbatim: String(format: "%02d", index + 1))
                        .font(UniTypography.caption2.monospacedDigit())
                        .foregroundStyle(UniColors.Text.tertiary)
                        .frame(minWidth: 22, alignment: .trailing)
                    Text(verbatim: shortened(address))
                        .font(UniTypography.subheadline.monospaced())
                        .foregroundStyle(UniColors.Text.primary)
                    Spacer()
                }
                .padding(.horizontal, UniSpacing.m)
                .padding(.vertical, UniSpacing.s)
                if index < addresses.count - 1 {
                    UniDivider()
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Background.secondary)
        )
    }

    private func shortened(_ address: String) -> String {
        guard address.count > 20 else { return address }
        return "\(address.prefix(10))…\(address.suffix(8))"
    }

    private func resolveAddresses() async {
        if state.watchOnlyExtendedKeyMode && chain.supportsExtendedPublicKey {
            do {
                let derived = try await state.service.deriveAddresses(
                    fromExtendedKey: state.watchOnlyRaw.trimmingCharacters(in: .whitespacesAndNewlines),
                    on: chain
                )
                await MainActor.run {
                    self.addresses = derived
                    self.state.watchOnlyAddresses = derived
                    self.isDeriving = false
                }
            } catch {
                await MainActor.run {
                    self.addresses = []
                    self.isDeriving = false
                }
            }
        } else {
            let lines = state.watchOnlyRaw
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && state.service.validateAddress($0, on: chain) }
            await MainActor.run {
                self.addresses = lines
                self.state.watchOnlyAddresses = lines
                self.isDeriving = false
            }
        }
    }
}
