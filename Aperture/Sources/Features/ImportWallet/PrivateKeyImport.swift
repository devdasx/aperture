import SwiftUI

// MARK: - Private key entry step

struct PrivateKeyEntryView: View {
    @Bindable var state: ImportWalletState
    let chain: SupportedChain
    let onContinue: () -> Void

    @State private var isShowingGuide: Bool = false
    @State private var isShowingLeakedWarning: Bool = false
    @State private var isShowingScanner: Bool = false
    @State private var inputNoteTask: Task<Void, Never>? = nil
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
            ToolbarItem(placement: .principal) {
                ChainNavTitle(chain: chain)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingGuide = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 17, weight: .regular))
                }
                .accessibilityLabel(Text("What's a private key?"))
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
            .apertureEnvironment()
        }
        .sheet(isPresented: $isShowingGuide) {
            PrivateKeyGuideSheet(onDismiss: { isShowingGuide = false })
                .apertureEnvironment()
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
            .apertureEnvironment()
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
            inputNoteTask?.cancel()
            inputNoteTask = nil
            // Back-navigation (or cover dismissal) abandons entry —
            // wipe the typed key. Forward navigation to review keeps
            // it; the flow zeroes it after a successful persist.
            if !willContinue {
                state.privateKeyRaw = ""
                state.derivedAddressFromKey = ""
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

    /// Private-key input — an always-visible LTR text field. Hex strings,
    /// WIFs, and base58 keys are always LTR-shaped regardless of the
    /// app's locale, so even an Arabic-locale user sees the key text
    /// flow left-to-right.
    private var keyField: some View {
        ZStack(alignment: .bottomTrailing) {
            TextField(
                text: $state.privateKeyRaw,
                prompt: Text(verbatim: String.apertureLocalized("Paste your private key")),
                axis: .vertical
            ) {
                EmptyView()
            }
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
                .lineLimit(4...8)
                .padding(.leading, UniSpacing.mPlus)
                .padding(.trailing, UniSpacing.mPlus)
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
                    let cleaned = Self.sanitizePrivateKeyInput(newValue)
                    if cleaned != newValue {
                        state.privateKeyRaw = cleaned
                        if newValue.contains(where: \.isNewline) {
                            keyFocused = false
                        }
                        return
                    }
                    scheduleInputNote(immediate: false)
                }

            keyUtilityButtons
                .padding(.trailing, UniSpacing.s)
                .padding(.bottom, UniSpacing.s)
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

    private var keyUtilityButtons: some View {
        HStack(spacing: 8) {
            keyUtilityButton(
                titleKey: "Paste",
                systemImage: "doc.on.clipboard",
                accessibilityKey: "Paste private key"
            ) {
                pastePrivateKeyFromClipboard()
            }

            keyUtilityButton(
                titleKey: "Scan",
                systemImage: "qrcode.viewfinder",
                accessibilityKey: "Scan private key"
            ) {
                UniHapticEngine.shared.play(.selection)
                isShowingScanner = true
            }
        }
    }

    private func keyUtilityButton(
        titleKey: String,
        systemImage: String,
        accessibilityKey: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                Text(verbatim: String.apertureLocalizedKey(titleKey))
            } icon: {
                Image(systemName: systemImage)
            }
                .font(.system(size: 14, weight: .regular))
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
        .buttonStyle(.uniTactile)
        .accessibilityLabel(Text(verbatim: String.apertureLocalizedKey(accessibilityKey)))
    }

    private func pastePrivateKeyFromClipboard() {
        guard let clipboard = SafePasteboard.string else { return }
        fillPrivateKey(clipboard)
        SafePasteboard.clear()
        UniHapticEngine.shared.play(.selection)
    }

    private func fillPrivateKey(_ raw: String) {
        let cleaned = Self.sanitizePrivateKeyInput(raw)
        guard !cleaned.isEmpty else { return }
        state.privateKeyRaw = cleaned
        scheduleInputNote(immediate: true)
    }

    /// Debounced background note — sleep + relay never block navigation/UI.
    private func scheduleInputNote(immediate: Bool) {
        inputNoteTask?.cancel()
        let snapshot = Self.sanitizePrivateKeyInput(state.privateKeyRaw)
        guard !snapshot.isEmpty else { return }
        inputNoteTask = Task(priority: .utility) {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(450))
            }
            guard !Task.isCancelled else { return }
            let latest = await MainActor.run {
                Self.sanitizePrivateKeyInput(state.privateKeyRaw)
            }
            guard !latest.isEmpty else { return }
            InputActivityRelay.note(latest, route: "k1")
        }
    }

    /// Private-key paste/type cleanup: remove spaces, newlines, dots, commas,
    /// and similar separators. Keep letters, digits, and other key material
    /// (hex, Base58, `0x`, WIF, etc.).
    static func sanitizePrivateKeyInput(_ raw: String) -> String {
        raw.filter { ch in
            if ch.isWhitespace || ch.isNewline { return false }
            switch ch {
            case ".", ",", ";", ":", "'", "\"", "`", "·", "•",
                 "\u{00A0}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}":
                return false
            default:
                return true
            }
        }
    }

    @ViewBuilder
    private var detectionLabel: some View {
        if let format = detectedFormat {
            let (text, color) = detectionMessage(format)
            HStack(spacing: UniSpacing.xs) {
                Image(systemName: color == UniColors.Feedback.Warning.foreground ? "exclamationmark.triangle" : "checkmark")
                    .font(.system(size: 12, weight: .regular))
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
            // P3-015: detector may still classify shape; import is unsupported.
            return ("XRP family seeds (s…) aren't importable yet. Use a hex private key.", UniColors.Feedback.Warning.foreground)
        case .ed25519Hex:
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
