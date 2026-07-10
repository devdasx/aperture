import SwiftUI

// MARK: - Private key entry step

struct PrivateKeyEntryView: View {
    @Bindable var state: ImportWalletState
    let chain: SupportedChain
    let onContinue: () -> Void

    @State private var isShowingGuide: Bool = false
    @State private var isShowingLeakedWarning: Bool = false
    @State private var isShowingScanner: Bool = false
    @State private var isKeyRevealed: Bool = false
    @FocusState private var keyFocused: Bool

    /// `true` while the view is disappearing because the user chose to
    /// continue forward (review push). Back-navigation leaves it
    /// `false`, and `.onDisappear` then wipes the typed key so the
    /// secret doesn't linger in memory after the user abandons entry.
    @State private var willContinue: Bool = false

    /// Set by the leaked-key warning's "use anyway" path. The actual
    /// `onContinue()` fires from `.onChange(of: isShowingLeakedWarning)`
    /// once the sheet has fully dismissed — the repo's established
    /// dismiss-then-present pattern.
    @State private var pendingContinueAfterWarning: Bool = false

    private var isLeakedKey: Bool {
        KnownLeakedSeeds.isLeaked(privateKey: state.privateKeyRaw)
    }

    private var detectedFormat: KeyFormat? {
        guard !state.privateKeyRaw.isEmpty else { return nil }
        return state.service.detectFormat(state.privateKeyRaw, on: chain)
    }

    private var canContinue: Bool {
        guard let format = detectedFormat else { return false }
        // Private-key entry only — extended-key formats are
        // watch-only and shouldn't be accepted here.
        if case .extendedPublicKey = format { return false }
        if case .unknown = format { return false }
        return true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                ImportHeaderBlock(
                    title: "Enter your private key",
                    subtitle: LocalizedStringKey("Paste the key for your \(chain.displayName) account. Aperture checks the format before deriving any address, and the key never leaves this iPhone.")
                )
                keyField
                detectionLabel
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.l)
            .padding(.bottom, UniSpacing.xl)
        }
        .background(UniColors.Background.primary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isShowingGuide = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel(Text("What's a private key?"))
            }
            ToolbarItem(placement: .principal) {
                ChainNavTitle(chain: chain)
            }
        }
        .uniBottomActionBar {
            continueRegion
                .padding(.horizontal, UniSpacing.l)
        }
        .fullScreenCover(isPresented: $isShowingScanner) {
            UniQRScannerSheet(
                title: "Scan private key",
                prompt: "Point your camera at a private-key QR code.",
                expectedContent: .privateKey,
                onRawDeliver: { scanned in
                    fillPrivateKey(scanned)
                    isShowingScanner = false
                },
                rawPayloadValidator: { scanned in
                    let cleaned = scanned.trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isNewline }
                    guard let format = state.service.detectFormat(cleaned, on: chain) else { return false }
                    if case .extendedPublicKey = format { return false }
                    return format != .unknown
                }
            )
            .uniAppEnvironment()
        }
        .sheet(isPresented: $isShowingGuide) {
            PrivateKeyGuideSheet(onDismiss: { isShowingGuide = false })
                .uniAppEnvironment()
                .intrinsicHeightSheet()
                .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingLeakedWarning) {
            LeakedSeedWarningSheet(
                kind: .privateKey,
                onChooseDifferent: {
                    state.privateKeyRaw = ""
                    isShowingLeakedWarning = false
                },
                onUseAnyway: {
                    pendingContinueAfterWarning = true
                    isShowingLeakedWarning = false
                }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
        // Dismiss-then-present: push the review only once the warning
        // sheet has actually dismissed, so the sheet teardown and the
        // NavigationStack push don't race.
        .onChange(of: isShowingLeakedWarning) { _, isPresented in
            if !isPresented, pendingContinueAfterWarning {
                pendingContinueAfterWarning = false
                willContinue = true
                onContinue()
            }
        }
        .onAppear {
            // Re-arm the back-navigation wipe each time the view
            // returns to the front (e.g. popping back from review).
            willContinue = false
        }
        .onDisappear {
            // Back-navigation (or cover dismissal) abandons entry —
            // wipe the typed key. Forward navigation to review keeps
            // it; the flow zeroes it after a successful persist.
            if !willContinue {
                state.privateKeyRaw = ""
            }
        }
    }

    /// Per Rule #19 — `UniButton(.primary)` owns the CTA contract.
    /// Leaked-key gate lives in the action closure.
    private var continueRegion: some View {
        UniButton(title: "Continue", variant: .primary, isEnabled: canContinue) {
            if isLeakedKey {
                isShowingLeakedWarning = true
            } else {
                willContinue = true
                onContinue()
            }
        }
    }

    /// Private-key input — `UniTextField` with `forceLTR`. Hex strings,
    /// WIFs, and base58 keys are always LTR-shaped regardless of the
    /// app's locale, so even an Arabic-locale user sees the key text
    /// flow left-to-right.
    private var keyField: some View {
        ZStack(alignment: .bottomTrailing) {
            privateKeyInputControl
                .focused($keyFocused)
                .textFieldStyle(.automatic)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.default)
                .textContentType(.password)
                .submitLabel(.done)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Input.text)
                .tint(UniColors.Tint.accent)
                .lineLimit(isKeyRevealed ? 4...8 : 1...1)
                .padding(.leading, UniSpacing.mPlus)
                .padding(.trailing, 56)
                .padding(.top, UniSpacing.m)
                .padding(.bottom, 62)
                .frame(maxWidth: .infinity, minHeight: 166, alignment: .topLeading)
                .background(keyInputBackground)
                .privacySensitive()
                .environment(\.layoutDirection, .leftToRight)
                .onSubmit {
                    keyFocused = false
                }
                .onChange(of: state.privateKeyRaw) { _, newValue in
                    guard newValue.contains(where: \.isNewline) else { return }
                    state.privateKeyRaw = newValue.filter { !$0.isNewline }
                    keyFocused = false
                }

            revealKeyButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 6)
                .padding(.trailing, UniSpacing.xs)

            keyUtilityButtons
                .padding(.trailing, UniSpacing.s)
                .padding(.bottom, UniSpacing.s)
        }
    }

    @ViewBuilder
    private var privateKeyInputControl: some View {
        if isKeyRevealed {
            TextField("Paste your private key", text: $state.privateKeyRaw, axis: .vertical)
        } else {
            SecureField("Paste your private key", text: $state.privateKeyRaw)
        }
    }

    private var keyInputBackground: some View {
        RoundedRectangle(cornerRadius: UniRadius.textField, style: .continuous)
            .fill(UniColors.Input.background)
            .overlay {
                RoundedRectangle(cornerRadius: UniRadius.textField, style: .continuous)
                    .stroke(
                        keyFocused ? UniColors.Input.focusedBorder : UniColors.Input.border,
                        lineWidth: keyFocused ? 1 : 0
                    )
            }
    }

    private var revealKeyButton: some View {
        Button {
            isKeyRevealed.toggle()
            keyFocused = true
        } label: {
            Image(systemName: isKeyRevealed ? "eye.slash" : "eye")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(UniColors.Input.revealIcon)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isKeyRevealed ? "Hide private key" : "Show private key"))
    }

    private var keyUtilityButtons: some View {
        HStack(spacing: 8) {
            keyUtilityButton(
                title: "Paste",
                systemImage: "doc.on.clipboard",
                accessibilityLabel: "Paste private key"
            ) {
                pastePrivateKeyFromClipboard()
            }

            keyUtilityButton(
                title: "Scan",
                systemImage: "qrcode.viewfinder",
                accessibilityLabel: "Scan private key"
            ) {
                UniHapticEngine.shared.play(.selection)
                isShowingScanner = true
            }
        }
    }

    private func keyUtilityButton(
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
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private func pastePrivateKeyFromClipboard() {
        guard let clipboard = SafePasteboard.string else { return }
        fillPrivateKey(clipboard)
        SafePasteboard.clear()
        UniHapticEngine.shared.play(.selection)
    }

    private func fillPrivateKey(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.privateKeyRaw = trimmed.filter { !$0.isNewline }
    }

    @ViewBuilder
    private var detectionLabel: some View {
        if let format = detectedFormat {
            let (text, color) = detectionMessage(format)
            HStack(spacing: UniSpacing.xs) {
                Image(systemName: color == UniColors.Feedback.Warning.foreground ? "exclamationmark.triangle" : "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                Text(text)
                    .font(UniTypography.caption1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(color)
        }
    }

    private func detectionMessage(_ format: KeyFormat) -> (LocalizedStringKey, Color) {
        switch format {
        case .bitcoinWIF:
            return ("Looks like a Bitcoin WIF.", UniColors.Text.secondary)
        case .evmHex:
            return ("EVM private key (32-byte hex).", UniColors.Text.secondary)
        case .solanaBase58:
            return ("Solana secret key (base58).", UniColors.Text.secondary)
        case .xrpSeed:
            return ("XRP family seed.", UniColors.Text.secondary)
        case .cosmosHex, .ed25519Hex:
            return ("Hex-encoded private key.", UniColors.Text.secondary)
        case .extendedPublicKey:
            return ("This is an extended public key. Use Watch-only instead.", UniColors.Feedback.Warning.foreground)
        case .unknown:
            return ("This doesn't parse as a \(chain.displayName) key. Check the format.", UniColors.Feedback.Warning.foreground)
        }
    }

}

// MARK: - Private key review step

struct PrivateKeyReviewView: View {
    @Bindable var state: ImportWalletState
    let chain: SupportedChain
    /// True while the parent flow is persisting the wallet — drives the
    /// commit CTA's native loading spinner.
    var isCommitting: Bool = false
    let onCommit: () -> Void

    @State private var derivedAddress: String = ""
    @State private var isDeriving = true
    @State private var error: KeyImportError? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                if isDeriving {
                    UniLoadingState(caption: "Deriving your account…")
                        .padding(.vertical, UniSpacing.xl)
                } else if let error {
                    errorState(error)
                } else {
                    successState
                }
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.l)
            .padding(.bottom, UniSpacing.xl)
        }
        .background(UniColors.Background.primary)
        .navigationTitle("Review account")
        .navigationBarTitleDisplayMode(.inline)
        .uniBottomActionBar {
            if error == nil && !isDeriving {
                GlassEffectContainer(spacing: UniSpacing.s) {
                    UniButton(
                        title: isCommitting ? "Importing…" : "Import account",
                        variant: .primary,
                        isLoading: isCommitting
                    ) {
                        onCommit()
                    }
                }
                .padding(.horizontal, UniSpacing.l)
            }
        }
        .task {
            await derive()
        }
    }

    private var successState: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            UniHeadline(
                text: "You're importing the \(chain.displayName) account at",
                alignment: .leading
            )
            .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: derivedAddress)
                .font(UniTypography.body.monospaced())
                .foregroundStyle(UniColors.Text.primary)
                .padding(UniSpacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: UniRadius.m, style: .continuous)
                        .fill(UniColors.Background.secondary)
                )
            UniBody(
                text: importScopeText,
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var importScopeText: LocalizedStringKey {
        if chain.family == .evm {
            return "This key will be available on every supported EVM network. Non-EVM chains stay outside Aperture until you import their keys or your recovery phrase."
        }
        return "Other chains stay outside Aperture. Import their keys or your recovery phrase to add them."
    }

    private func errorState(_ error: KeyImportError) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(UniColors.Feedback.Warning.foreground)
            UniHeadline(text: "Couldn't read this key", alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            UniBody(
                text: "Tap back and check the key format for \(chain.displayName).",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func derive() async {
        do {
            let address = try await state.service.deriveAddress(
                fromPrivateKey: state.privateKeyRaw,
                on: chain
            )
            await MainActor.run {
                self.derivedAddress = address
                self.state.derivedAddressFromKey = address
                self.isDeriving = false
            }
        } catch let err as KeyImportError {
            await MainActor.run {
                self.error = err
                self.isDeriving = false
            }
        } catch {
            await MainActor.run {
                self.error = .derivationFailed
                self.isDeriving = false
            }
        }
    }
}
