import SwiftUI
import SwiftData

/// **Reset Aperture — the full-screen factory-reset flow** (`design_handoff_reset`).
///
/// Supersedes the old bottom sheet (app rule: app-wide reset is full-screen,
/// not the unified sheet). Five gates, in a mandatory order, each a real
/// barrier — nothing is deleted until every gate passes:
///
/// 1. **Warning** — what gets erased (wallets · keys & phrases · history &
///    balances · settings).
/// 2. **Backup checkpoint** — self-custody reminder; a real branch to the
///    unified backup flow (`WalletBackupFlow` / `ExportKeysFlow`).
/// 3. **Acknowledge** — three checks; Continue stays disabled until all three.
/// 4. **Confirm** — type `RESET` (exact) → Face ID / passcode
///    (`BiometricService.authenticateOwner`, `.deviceOwnerAuthentication`).
/// 5. **Erasing → Factory fresh** — ONE morphing screen: a red progress ring
///    fills as the REAL deletion stages complete (`FactoryReset.performStagedWipe`),
///    then morphs IN PLACE into the brand iris seal. A failed stage stops and
///    offers Retry — it never morphs to "fresh" on failure.
///
/// Every function is real: the gates are honest, the wipe is the shared
/// `FactoryReset` routine reported stage-by-stage, and the success seal appears
/// only after the wipe truly completes. Red is used ONLY for destructive
/// accents; all buttons are text-only (no icons), per the handoff.
struct ResetApertureFlow: View {
    /// Dismiss the whole flow (✕ / Cancel, and "Get Started" after the wipe —
    /// by then the wallet count is zero, so `RootGate` shows onboarding).
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \WalletRecord.sortOrder) private var wallets: [WalletRecord]

    enum Step { case warning, backup, backupPicker, acknowledge, confirm, erasing }
    @State private var step: Step = .warning

    // Acknowledge gate.
    @State private var ackWallets = false
    @State private var ackIrreversible = false
    @State private var ackBackedUp = false
    private var allAcknowledged: Bool { ackWallets && ackIrreversible && ackBackedUp }

    // Confirm gate.
    @State private var typed = ""
    private let confirmWord = "RESET"
    private var typedMatches: Bool { typed == confirmWord }
    @State private var didFireTypedHaptic = false
    @State private var isAuthenticating = false

    // Erasing / morph state.
    @State private var stagesDone: Set<FactoryReset.Stage> = []
    @State private var isComplete = false
    @State private var eraseError: String?

    // Backup branch.
    @State private var backupTarget: BackupTarget?
    @State private var exportTarget: ExportTarget?

    private struct BackupTarget: Identifiable {
        let id: UUID
        let name: String
        let words: [String]
        let avatar: WalletAvatarSpec?
    }
    private struct ExportTarget: Identifiable {
        let id: UUID
    }

    var body: some View {
        ZStack {
            UniColors.Background.primary.ignoresSafeArea()
            switch step {
            case .warning:      warningScreen
            case .backup:       backupCheckpointScreen
            case .backupPicker: backupPickerScreen
            case .acknowledge:  acknowledgeScreen
            case .confirm:      confirmScreen
            case .erasing:      erasingScreen
            }
        }
        .animation(.smooth(duration: 0.3), value: step)
        // The unified backup flow for a phrase wallet (iCloud / manual).
        .fullScreenCover(item: $backupTarget) { target in
            WalletBackupFlow(
                walletId: target.id,
                walletName: target.name,
                words: target.words,
                avatar: target.avatar,
                onClose: { backupTarget = nil }
            )
            .uniAppEnvironment()
        }
        // Private-key wallets back up by exporting the key (the same per-chain
        // export flow used from wallet management).
        .fullScreenCover(item: $exportTarget) { target in
            if let wallet = wallets.first(where: { $0.id == target.id }) {
                ExportPrivateKeyFlow(
                    descriptor: WalletDescriptor(record: wallet),
                    chains: exportChainEntries(wallet),
                    onClose: { exportTarget = nil }
                )
                .uniAppEnvironment()
            }
        }
    }

    // MARK: - 1 · Warning

    private var warningScreen: some View {
        gatedScreen(
            showsClose: true,
            hero: heroGlyph("trash", tint: UniColors.Status.errorForeground),
            title: "Reset Aperture",
            content: {
                UniBody(
                    text: "This returns Aperture to a brand-new install. Everything below is erased from this iPhone — there is no copy on a server.",
                    color: UniColors.Text.secondary
                )
                erasedList
            },
            primary: { destructiveButton("Continue") {
                UniHapticEngine.shared.play(.warning)
                step = .backup
            } },
            ghost: AnyView(ghostButton("Cancel") { close() })
        )
    }

    private var erasedList: some View {
        UniCard {
            VStack(alignment: .leading, spacing: 0) {
                erasedRow("All wallets", "Every wallet on this device")
                UniDivider()
                erasedRow("Keys & recovery phrases", "Seeds and private keys")
                UniDivider()
                erasedRow("History & balances", "Transactions and cached balances")
                UniDivider()
                erasedRow("Settings & preferences", "Every preference and the passcode")
            }
        }
    }

    private func erasedRow(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(UniTypography.subheadlineEmphasized)
                .foregroundStyle(UniColors.Text.primary)
            Text(subtitle)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, UniSpacing.s)
    }

    // MARK: - 2 · Backup checkpoint

    private var backupCheckpointScreen: some View {
        gatedScreen(
            showsClose: true,
            hero: heroGlyph("checkmark.shield", tint: UniColors.Icon.secondary),
            title: "Before you continue",
            content: {
                UniBody(
                    text: "Aperture is self-custodial. There is no server copy of your wallets — a recovery phrase you never wrote down cannot be recovered after this.",
                    color: UniColors.Text.secondary
                )
                calloutCard("No recovery phrase, no recovery. Make sure every wallet you want to keep is backed up before you erase.")
            },
            primary: { primaryButton("My Wallets Are Backed Up") { step = .acknowledge } },
            ghost: AnyView(ghostButton("Back Up First") { step = .backupPicker })
        )
    }

    private func calloutCard(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(UniTypography.footnote)
            .foregroundStyle(UniColors.Status.warningForeground)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(UniSpacing.m)
            .background(UniColors.Status.warningBackground, in: RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
    }

    // MARK: - 2b · Backup branch — pick a wallet

    private var backupPickerScreen: some View {
        VStack(spacing: 0) {
            flowTopBar(title: "Which wallet?", onBack: { step = .backup })
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.m) {
                    UniBody(
                        text: "Pick a wallet to back up. Watch-only wallets have no keys to save.",
                        color: UniColors.Text.secondary
                    )
                    UniCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(wallets.enumerated()), id: \.element.id) { offset, wallet in
                                backupWalletRow(wallet)
                                if offset < wallets.count - 1 { UniDivider().padding(.leading, UniSpacing.m) }
                            }
                        }
                    }
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.m)
            }
        }
    }

    @ViewBuilder
    private func backupWalletRow(_ wallet: WalletRecord) -> some View {
        let isWatchOnly = wallet.kind == .watchOnly
        Button {
            beginBackup(for: wallet)
        } label: {
            HStack(spacing: UniSpacing.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: wallet.name)
                        .font(UniTypography.body)
                        .foregroundStyle(isWatchOnly ? UniColors.Text.disabled : UniColors.Text.primary)
                    Text(backupKindLabel(wallet.kind))
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                }
                Spacer(minLength: 0)
                if !isWatchOnly {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.tertiary)
                }
            }
            .padding(.horizontal, UniSpacing.m)
            .padding(.vertical, UniSpacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isWatchOnly)
    }

    private func backupKindLabel(_ kind: WalletKind) -> LocalizedStringKey {
        switch kind {
        case .created, .importedMnemonic: return "Recovery phrase"
        case .importedKey:                return "Private key"
        case .watchOnly:                  return "Watch-only · nothing to back up"
        }
    }

    private func beginBackup(for wallet: WalletRecord) {
        UniHapticEngine.shared.play(.selection)
        switch wallet.kind {
        case .importedKey:
            exportTarget = ExportTarget(id: wallet.id)
        case .created, .importedMnemonic:
            let words = (try? MnemonicVault.loadMnemonic(for: wallet.id)) ?? nil
            guard let words, !words.isEmpty else { return }
            backupTarget = BackupTarget(id: wallet.id, name: wallet.name, words: words, avatar: wallet.avatarSpec)
        case .watchOnly:
            break
        }
    }

    /// Build the per-chain export entries for a private-key wallet from its own
    /// address records (the same shape `WalletDetailView` feeds `ExportPrivateKeyFlow`).
    private func exportChainEntries(_ wallet: WalletRecord) -> [ExportChainEntry] {
        wallet.addresses.compactMap { addr in
            guard let chain = SupportedChain(rawValue: addr.chainRaw), !addr.address.isEmpty else { return nil }
            return ExportChainEntry(chain: chain, address: addr.address)
        }
    }

    // MARK: - 3 · Acknowledge

    private var acknowledgeScreen: some View {
        gatedScreen(
            showsClose: false,
            onBack: { step = .backup },
            hero: nil,
            title: "Acknowledge",
            content: {
                UniBody(
                    text: "Confirm you understand what happens next. All three are required.",
                    color: UniColors.Text.secondary
                )
                UniCard(padding: 0) {
                    VStack(spacing: 0) {
                        ackRow("Wallets & keys erased", "Every wallet, seed, and private key on this iPhone is deleted.", isOn: $ackWallets)
                        UniDivider().padding(.leading, UniSpacing.m)
                        ackRow("This can't be undone", "There is no server backup — Aperture can't restore it for you.", isOn: $ackIrreversible)
                        UniDivider().padding(.leading, UniSpacing.m)
                        ackRow("I've backed up", "I have the recovery phrase or key for any wallet I want to keep.", isOn: $ackBackedUp)
                    }
                }
            },
            primary: { destructiveButton("Continue", isEnabled: allAcknowledged) { step = .confirm } },
            ghost: nil
        )
    }

    private func ackRow(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Button {
            let wasAllOn = allAcknowledged
            isOn.wrappedValue.toggle()
            UniHapticEngine.shared.play(isOn.wrappedValue ? .selection : .contextualImpact(.whisper))
            // The moment the LAST check enables Continue → a weightier beat.
            if !wasAllOn && allAcknowledged { UniHapticEngine.shared.play(.contextualImpact(.commit)) }
        } label: {
            HStack(alignment: .top, spacing: UniSpacing.s) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(UniColors.Text.primary)
                    Text(subtitle)
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: UniSpacing.s)
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isOn.wrappedValue ? UniColors.Status.errorForeground : UniColors.Icon.tertiary)
            }
            .padding(UniSpacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 4 · Confirm — type RESET + Face ID

    private var confirmScreen: some View {
        gatedScreen(
            showsClose: false,
            onBack: { step = .acknowledge },
            hero: heroGlyph("trash", tint: UniColors.Status.errorForeground),
            title: "Type RESET to confirm",
            content: {
                UniBody(
                    text: "Type the word RESET, then authenticate with Face ID or your passcode to erase Aperture.",
                    color: UniColors.Text.secondary
                )
                TextField("", text: $typed, prompt: Text(verbatim: confirmWord))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(size: 21, weight: .bold).monospaced())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(UniColors.Text.primary)
                    .padding(.vertical, UniSpacing.m)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: UniRadius.row, style: .continuous)
                            .strokeBorder(
                                typedMatches ? UniColors.Status.errorForeground : UniColors.Separator.regular,
                                lineWidth: typedMatches ? 2 : 1
                            )
                    )
                    .onChange(of: typed) { _, newValue in
                        if newValue == confirmWord, !didFireTypedHaptic {
                            didFireTypedHaptic = true
                            UniHapticEngine.shared.play(.success)
                        } else if newValue != confirmWord {
                            didFireTypedHaptic = false
                        }
                    }
            },
            primary: {
                destructiveButton(isAuthenticating ? "Authenticating…" : "Erase Aperture", isEnabled: typedMatches && !isAuthenticating) {
                    confirmAndAuthenticate()
                }
            },
            ghost: AnyView(ghostButton("Cancel") { close() })
        )
    }

    private func confirmAndAuthenticate() {
        guard typedMatches, !isAuthenticating else { return }
        isAuthenticating = true
        UniHapticEngine.shared.play(.warning)
        Task {
            let result = await BiometricService().authenticateOwner(
                reason: "Authenticate to erase Aperture"
            )
            isAuthenticating = false
            switch result {
            case .success:
                UniHapticEngine.shared.play(.success)
                step = .erasing
            case .failure(.unavailable):
                // No biometrics AND no passcode on the device — the typed RESET
                // and the three acknowledgements are the deliberate gates. Proceed.
                UniHapticEngine.shared.play(.success)
                step = .erasing
            case .failure(.userCancelled):
                break   // silent — the user backed out of the system prompt
            case .failure:
                UniHapticEngine.shared.play(.error)
            }
        }
    }

    // MARK: - 5 · Erasing → Factory fresh (one morphing screen)

    private var erasingScreen: some View {
        VStack(spacing: UniSpacing.l) {
            Spacer()
            morphingEmblem
            Text(isComplete ? "Reset complete" : (eraseError == nil ? "Erasing Aperture…" : "Couldn't reset"))
                .font(UniTypography.title2)
                .foregroundStyle(UniColors.Text.primary)
                .animation(.smooth(duration: 0.3), value: isComplete)

            if let eraseError {
                eraseErrorBlock(eraseError)
            } else if isComplete {
                doneBlock
            } else {
                stepsBlock
            }
            Spacer()
            erasingCTA
        }
        .padding(.horizontal, UniSpacing.l)
        .padding(.bottom, UniSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await runWipe() }
    }

    private var emblemDiameter: CGFloat { 132 }
    private var ringProgress: Double { Double(stagesDone.count) / Double(FactoryReset.Stage.allCases.count) }

    /// The ONE emblem that morphs in place: the progress ring (around a trash
    /// glyph) crossfades/scales into the brand iris seal at the same spot and
    /// diameter — never a hard cut to a separate success screen.
    private var morphingEmblem: some View {
        ZStack {
            // Erasing state — concentric progress ring + trash glyph.
            ZStack {
                Circle().stroke(UniColors.Separator.regular, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(UniColors.Status.errorForeground, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: ringProgress)
                Image(systemName: "trash")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(UniColors.Status.errorForeground)
            }
            .opacity(isComplete ? 0 : 1)
            .scaleEffect(!reduceMotion && isComplete ? 0.9 : 1)

            // Factory-fresh state — the brand iris seal (same diameter).
            irisSeal
                .opacity(isComplete ? 1 : 0)
                .scaleEffect(isComplete ? 1 : (reduceMotion ? 1 : 0.9))
        }
        .frame(width: emblemDiameter, height: emblemDiameter)
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : .smooth(duration: 0.6), value: isComplete)
    }

    private var irisSeal: some View {
        ZStack {
            Circle().fill(UniColors.Brand.mark)
            Image("IrisWatermarkWhite")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(UniColors.Button.primaryLabel)
                .padding(emblemDiameter * 0.3)
        }
    }

    /// Honest live steps — each lights up only when its real deletion stage
    /// completes (handoff rule #4).
    private var stepsBlock: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            stepRow("Erasing wallets & history", done: stagesDone.contains(.wallets))
            stepRow("Wiping keys & phrases", done: stagesDone.contains(.keys))
            stepRow("Clearing settings & cache", done: stagesDone.contains(.settings))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, UniSpacing.s)
    }

    private func stepRow(_ label: LocalizedStringKey, done: Bool) -> some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(done ? UniColors.Status.errorForeground : UniColors.Icon.tertiary)
            Text(label)
                .font(UniTypography.subheadline)
                .foregroundStyle(done ? UniColors.Text.primary : UniColors.Text.tertiary)
            Spacer(minLength: 0)
        }
    }

    private var doneBlock: some View {
        VStack(spacing: UniSpacing.m) {
            Text("Aperture is back to a brand-new install. Your erased wallets can be imported again only with the recovery phrases or keys you saved.")
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Help us improve — a tappable mailto.
            VStack(spacing: UniSpacing.xs) {
                Text("Help us improve")
                    .font(UniTypography.subheadlineEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                Text("Leaving for a reason? Tell us what we could do better.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .multilineTextAlignment(.center)
                Button {
                    UniHapticEngine.shared.play(.contextualImpact(.whisper))
                    if let url = feedbackMailURL { openURL(url) }
                } label: {
                    Text(verbatim: "care@aperturex.io")
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(UniColors.Button.text)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(UniSpacing.m)
            .background(UniColors.Background.secondary, in: RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
        }
    }

    private var feedbackMailURL: URL? {
        URL(string: "mailto:care@aperturex.io?subject=Aperture%20feedback")
    }

    private func eraseErrorBlock(_ message: String) -> some View {
        VStack(spacing: UniSpacing.s) {
            Text(verbatim: message)
                .font(UniTypography.subheadline)
                .foregroundStyle(UniColors.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, UniSpacing.s)
    }

    @ViewBuilder
    private var erasingCTA: some View {
        if eraseError != nil {
            VStack(spacing: UniSpacing.xs) {
                destructiveButton("Try again") {
                    eraseError = nil
                    stagesDone = []
                    Task { await runWipe() }
                }
                ghostButton("Cancel") { close() }
            }
        } else if isComplete {
            VStack(spacing: UniSpacing.xs) {
                primaryButton("Get Started") {
                    UniHapticEngine.shared.play(.success)
                    close()
                }
                ghostButton("Replay") { replayMorph() }
            }
        }
    }

    // MARK: - The wipe

    private func runWipe() async {
        guard eraseError == nil, !isComplete else { return }
        do {
            try await FactoryReset.performStagedWipe(modelContext: modelContext) { stage in
                UniHapticEngine.shared.play(.contextualImpact(.whisper))
                _ = withAnimation(.easeOut(duration: 0.3)) { stagesDone.insert(stage) }
            }
            UniHapticEngine.shared.play(.success)
            withAnimation { isComplete = true }
        } catch {
            // Stage 1 (the SwiftData custody gate) failed → NOTHING was
            // destroyed. Surface the error + Retry; never morph to "fresh".
            UniHapticEngine.shared.play(.error)
            eraseError = String.apertureLocalized("Couldn't erase Aperture. Nothing was removed — your wallets, keys, and settings are untouched. Try again.")
        }
    }

    /// Visual-only replay of the erasing → fresh morph (the data is already
    /// gone; this never re-runs the wipe).
    private func replayMorph() {
        guard isComplete else { return }
        withAnimation(.easeIn(duration: 0.2)) { isComplete = false; stagesDone = [] }
        Task {
            for stage in FactoryReset.Stage.allCases {
                try? await Task.sleep(for: .milliseconds(450))
                _ = withAnimation(.easeOut(duration: 0.3)) { stagesDone.insert(stage) }
            }
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(.smooth(duration: 0.6)) { isComplete = true }
        }
    }

    // MARK: - Shared chrome

    private func close() {
        UniHapticEngine.shared.play(.contextualImpact(.whisper))
        onClose()
    }

    /// One gated screen shell: optional top bar (✕ or ‹ Back), centered hero +
    /// title, scrollable content, and pinned text-only CTAs.
    @ViewBuilder
    private func gatedScreen<Content: View, Primary: View>(
        showsClose: Bool,
        onBack: (() -> Void)? = nil,
        hero: AnyView?,
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content,
        @ViewBuilder primary: () -> Primary,
        ghost: AnyView?
    ) -> some View {
        VStack(spacing: 0) {
            topBar(showsClose: showsClose, onBack: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.l) {
                    if let hero {
                        hero.frame(maxWidth: .infinity, alignment: .center)
                    }
                    Text(title)
                        .font(.system(size: 27, weight: .bold))
                        .foregroundStyle(UniColors.Text.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    content()
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.s)
                .padding(.bottom, UniSpacing.xl)
            }
            .scrollIndicators(.hidden)
            VStack(spacing: UniSpacing.xs) {
                primary()
                if let ghost { ghost }
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.bottom, UniSpacing.l)
        }
    }

    @ViewBuilder
    private func topBar(showsClose: Bool, onBack: (() -> Void)?) -> some View {
        HStack {
            if let onBack {
                Button { onBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.primary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Back"))
            } else if showsClose {
                Button { close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.primary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Cancel"))
            } else {
                Spacer().frame(width: 36, height: 36)
            }
            Spacer()
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.top, UniSpacing.xs)
    }

    private func flowTopBar(title: LocalizedStringKey, onBack: @escaping () -> Void) -> some View {
        HStack(spacing: UniSpacing.s) {
            Button { onBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Back"))
            Text(title)
                .font(UniTypography.headline)
                .foregroundStyle(UniColors.Text.primary)
            Spacer()
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.top, UniSpacing.xs)
    }

    private func heroGlyph(_ symbol: String, tint: Color) -> AnyView {
        AnyView(
            Image(systemName: symbol)
                .font(.system(size: 50, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .padding(.top, UniSpacing.s)
                .accessibilityHidden(true)
        )
    }

    // MARK: - Buttons (text-only, per handoff)

    private func primaryButton(_ title: LocalizedStringKey, isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        UniButton(title: title, variant: .primary, isEnabled: isEnabled, action: action)
    }

    private func destructiveButton(_ title: LocalizedStringKey, isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        UniButton(title: title, variant: .destructive, isEnabled: isEnabled, action: action)
    }

    private func ghostButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(UniTypography.buttonLabel)
                .foregroundStyle(UniColors.Text.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
