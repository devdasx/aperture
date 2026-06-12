import SwiftUI

// MARK: - Private key entry step

struct PrivateKeyEntryView: View {
    @Bindable var state: ImportWalletState
    let chain: SupportedChain
    let onContinue: () -> Void

    @State private var isShowingGuide: Bool = false
    @State private var isShowingLeakedWarning: Bool = false

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
                ImportExampleCaption(
                    caption: "Example only — never type a real key from a tutorial.",
                    example: chain.exampleKeyPreview,
                    monospaced: true
                )
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
            ToolbarItem(placement: .topBarTrailing) {
                Button("Paste") {
                    if let clipboard = UIPasteboard.general.string {
                        let trimmed = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        state.privateKeyRaw = trimmed
                        // Clear properly — `items = []` removes the
                        // entry; assigning `""` would leave an empty
                        // string item behind.
                        UIPasteboard.general.items = []
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            continueRegion
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
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
        UniTextField(
            placeholder: "Paste your private key",
            text: $state.privateKeyRaw,
            directionPolicy: .forceLTR,
            isSecure: true,
            showsRevealToggle: true,
            axis: .vertical,
            lineLimit: 6,
            contentType: .password
        )
    }

    @ViewBuilder
    private var detectionLabel: some View {
        if let format = detectedFormat {
            let (text, color) = detectionMessage(format)
            HStack(spacing: UniSpacing.xs) {
                Image(systemName: color == UniColors.Status.warningForeground ? "exclamationmark.triangle" : "checkmark")
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
            return ("This is an extended public key. Use Watch-only instead.", UniColors.Status.warningForeground)
        case .unknown:
            return ("This doesn't parse as a \(chain.displayName) key. Check the format.", UniColors.Status.warningForeground)
        }
    }

}

// MARK: - Private key review step

struct PrivateKeyReviewView: View {
    @Bindable var state: ImportWalletState
    let chain: SupportedChain
    let onCommit: () -> Void

    @State private var derivedAddress: String = ""
    @State private var isDeriving = true
    @State private var error: KeyImportError? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                if isDeriving {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, UniSpacing.l)
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
        .safeAreaInset(edge: .bottom) {
            if error == nil && !isDeriving {
                GlassEffectContainer(spacing: UniSpacing.s) {
                    UniButton(title: "Import account", variant: .primary) {
                        onCommit()
                    }
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
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
                text: "Other chains stay outside Aperture. Import their keys or your recovery phrase to add them.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorState(_ error: KeyImportError) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(UniColors.Status.warningForeground)
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
