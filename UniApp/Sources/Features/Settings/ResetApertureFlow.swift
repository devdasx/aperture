import SwiftUI
import SwiftData
import Observation

/// Drives the full-screen Reset Aperture flow, which is presented at the APP
/// ROOT (above `RootGate`), NOT from the Settings tab. Presenting it at the
/// root is what lets the erasing→factory-fresh morph survive the wipe: once the
/// wipe empties the wallets, `RootGate` swaps `MainTabView` for onboarding
/// underneath, but this root-level cover stays on top showing the morph until
/// the user taps "Get Started" — which dismisses it onto the fresh onboarding.
@MainActor
@Observable
final class ResetFlowGate {
    static let shared = ResetFlowGate()
    private init() {}
    var isPresenting = false
}

/// **Reset Aperture — the full-screen factory-reset flow** (`design_handoff_reset`,
/// rebuilt to match the HTML reference 1:1).
///
/// Five gates in a mandatory order — nothing is deleted until every one passes:
/// Warning → Backup checkpoint → Acknowledge (3 checks) → Confirm (type RESET +
/// Face ID) → Erasing→Factory-fresh (one morphing screen). The backup checkpoint
/// branches into the real unified backup flow (`WalletBackupFlow` for phrase
/// wallets, `ExportPrivateKeyFlow` for key wallets). The wipe is the shared
/// `FactoryReset.performStagedWipe`, reported stage-by-stage so the ring is
/// honest; the iris seal appears only after the wipe truly completes.
///
/// Visual contract (handoff): centered hero screens, a nav bar with a circular
/// chip button + centered title, **leading glyphs** on the erase list,
/// **text-only** action buttons, and the muted brick red `UniColors.Reset.danger`
/// (`#E0483D` / `#FF5B51`) as the ONLY accent.
struct ResetApertureFlow: View {
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \WalletRecord.sortOrder) private var wallets: [WalletRecord]

    enum Step { case warning, backup, backupPicker, acknowledge, confirm, erasing }
    @State private var step: Step = .warning

    @State private var ackWallets = false
    @State private var ackIrreversible = false
    @State private var ackBackedUp = false
    private var allAcknowledged: Bool { ackWallets && ackIrreversible && ackBackedUp }

    @State private var typed = ""
    private let confirmWord = "RESET"
    private var typedMatches: Bool { typed == confirmWord }
    @State private var didFireTypedHaptic = false
    @State private var isShowingPinGate = false
    /// Defers the PIN cover until the keyboard has fully retracted.
    @State private var pinGateTask: Task<Void, Never>?

    @State private var stagesDone: Set<FactoryReset.Stage> = []
    @State private var isComplete = false
    @State private var eraseError: String?
    @FocusState private var confirmFocused: Bool

    @State private var backupTarget: BackupTarget?
    @State private var exportTarget: ExportTarget?

    private struct BackupTarget: Identifiable {
        let id: UUID; let name: String; let words: [String]; let avatar: WalletAvatarSpec?
    }
    private struct ExportTarget: Identifiable { let id: UUID }

    // MARK: - Tokens (handoff-exact)

    private let hPad: CGFloat = 26
    private let cardRadius: CGFloat = 20
    private let danger = UniColors.Reset.danger

    var body: some View {
        NavigationStack {
        ZStack {
            UniColors.Background.primary.ignoresSafeArea()
            switch step {
            case .warning:      warningScreen
            case .backup:       backupScreen
            case .backupPicker: walletPickerScreen
            case .acknowledge:  acknowledgeScreen
            case .confirm:      confirmScreen
            case .erasing:      erasingScreen
            }
        }
        .animation(.smooth(duration: 0.28), value: step)
        .fullScreenCover(item: $backupTarget) { target in
            WalletBackupFlow(
                walletId: target.id, walletName: target.name, words: target.words,
                avatar: target.avatar, onClose: { backupTarget = nil }
            )
            .uniAppEnvironment()
        }
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
        // The reset's final gate is the app's UNIFIED lock screen — auto Face
        // ID (when the user enabled biometrics) with the PIN keypad fallback,
        // not a raw LAContext prompt. Presented after the user types RESET.
        .fullScreenCover(isPresented: $isShowingPinGate) {
            NavigationStack {
                PinCodeView(
                    mode: .verify,
                    onComplete: { _ in
                        isShowingPinGate = false
                        step = .erasing
                    },
                    onCancel: { isShowingPinGate = false },
                    allowsBiometrics: true
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { isShowingPinGate = false } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .accessibilityLabel(Text("Cancel"))
                    }
                }
            }
            .uniAppEnvironment()
        }
        }
    }

    // MARK: - 1 · Warning

    private var warningScreen: some View {
        screenScaffold(
            title: "Settings", leading: .close, onLeading: { close() },
            footer: {
                dangerButton("Continue") { step = .backup }
                ghostButton("Cancel") { close() }
            }
        ) {
            VStack(spacing: UniSpacing.mPlus) {
                heroGlyph("trash", tint: danger)
                bigTitle("Reset Aperture", centered: true)
                subtitle("Resetting removes all content from this device and returns Aperture to its original state. This can’t be undone.", centered: true)
                eraseList
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var eraseList: some View {
        card {
            eraseRow("creditcard", "Wallets", "Every wallet you’ve created, imported, or are watching.")
            hair
            eraseRow("key", "Keys & Recovery Phrases", "Permanently removed from this device’s Secure Enclave.")
            hair
            eraseRow("clock.arrow.circlepath", "Transactions & Balances", "Your full history, contacts, and cached balances.")
            hair
            eraseRow("gearshape", "Settings", "Networks, passcode, and all preferences.")
        }
    }

    private func eraseRow(_ symbol: String, _ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(UniColors.Text.primary)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(UniColors.Text.primary)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 15)
    }

    // MARK: - 2 · Backup checkpoint

    private var backupScreen: some View {
        screenScaffold(
            title: "Reset Aperture", leading: .back, onLeading: { step = .warning },
            footer: {
                primaryButton("My Wallets Are Backed Up") { step = .acknowledge }
                ghostButton("Back Up First") { step = .backupPicker }
            }
        ) {
            VStack(spacing: UniSpacing.mPlus) {
                heroGlyph("shield", tint: UniColors.Text.primary)
                bigTitle("Before you continue", centered: true)
                subtitleRich(centered: true) {
                    Text("Aperture is self-custodial. Your keys never leave this device, and we keep \(Text("no copy").foregroundColor(UniColors.Text.primary).bold()). Without your recovery phrase or private key, any wallet erased here \(Text("can’t be recovered").foregroundColor(UniColors.Text.primary).bold()).")
                }
                calloutCard()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func calloutCard() -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(UniColors.Status.warningForeground)
                .frame(width: 22, height: 22)
            Text("\(Text("No recovery phrase, no recovery.").bold()) Make sure every wallet you want to keep is backed up first.")
                .foregroundColor(UniColors.Status.warningForeground)
                .font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(UniColors.Status.warningBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 2b · Wallet picker (backup branch)

    private var walletPickerScreen: some View {
        screenScaffold(
            title: "Back Up", leading: .back, onLeading: { step = .backup },
            centered: false,
            footer: { EmptyView() }
        ) {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                bigTitle("Which wallet?", centered: false)
                subtitle("Choose the wallet you want to back up. Each wallet has its own recovery phrase or key.", centered: false)
                card {
                    ForEach(Array(wallets.enumerated()), id: \.element.id) { offset, wallet in
                        walletRow(wallet)
                        if offset < wallets.count - 1 { hair }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func walletRow(_ wallet: WalletRecord) -> some View {
        let isWatchOnly = wallet.kind == .watchOnly
        Button {
            beginBackup(for: wallet)
        } label: {
            HStack(spacing: 13) {
                irisDisc(size: 40, irisFraction: 0.6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: wallet.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(UniColors.Text.primary)
                    Text(backupKindLabel(wallet.kind))
                        .font(.system(size: 12.5))
                        .foregroundStyle(UniColors.Text.secondary)
                }
                Spacer(minLength: 0)
                if !isWatchOnly {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(UniColors.Text.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .opacity(isWatchOnly ? 0.5 : 1)
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
        UniHapticEngine.shared.play(.contextualImpact(.commit))
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

    private func exportChainEntries(_ wallet: WalletRecord) -> [ExportChainEntry] {
        wallet.addresses.compactMap { addr in
            guard let chain = SupportedChain(rawValue: addr.chainRaw), !addr.address.isEmpty else { return nil }
            return ExportChainEntry(chain: chain, address: addr.address)
        }
    }

    // MARK: - 3 · Acknowledge

    private var acknowledgeScreen: some View {
        screenScaffold(
            title: "Reset Aperture", leading: .back, onLeading: { step = .backup },
            centered: false,
            footer: {
                dangerButton("Continue", isEnabled: allAcknowledged) { step = .confirm }
            }
        ) {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                bigTitle("Confirm you understand", centered: false)
                subtitle("Acknowledge each item to continue.", centered: false)
                card {
                    ackRow("All wallets will be erased", "Wallets, keys, and recovery phrases are removed from this device.", isOn: $ackWallets)
                    hair
                    ackRow("This can’t be undone", "Aperture keeps no backup. Erased wallets are gone for good.", isOn: $ackIrreversible)
                    hair
                    ackRow("My wallets are backed up", "I have the recovery phrase for every wallet I want to keep.", isOn: $ackBackedUp)
                }
            }
        }
    }

    private func ackRow(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Button {
            let wasAll = allAcknowledged
            isOn.wrappedValue.toggle()
            UniHapticEngine.shared.play(isOn.wrappedValue ? .selection : .contextualImpact(.whisper))
            if !wasAll && allAcknowledged { UniHapticEngine.shared.play(.contextualImpact(.commit)) }
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(UniColors.Text.primary)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(UniColors.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle()
                        .strokeBorder(isOn.wrappedValue ? danger : UniColors.Text.tertiary, lineWidth: 2)
                        .background(Circle().fill(isOn.wrappedValue ? danger : .clear))
                        .frame(width: 27, height: 27)
                    if isOn.wrappedValue {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(UniColors.Reset.onDanger)
                    }
                }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 4 · Confirm (type RESET + Face ID)

    private var confirmScreen: some View {
        screenScaffold(
            title: "Reset Aperture", leading: .back, onLeading: { step = .acknowledge },
            footer: {
                dangerButton("Erase Aperture", isEnabled: typedMatches) {
                    confirmAndAuthenticate()
                }
                ghostButton("Cancel") { close() }
            }
        ) {
            VStack(spacing: UniSpacing.mPlus) {
                heroGlyph("trash", tint: danger)
                bigTitle("One last step", centered: true)
                subtitle("Typing the word below confirms the reset. This erases everything and can’t be undone.", centered: true)
                VStack(spacing: 10) {
                    Text("Type \(Text(verbatim: confirmWord).foregroundColor(UniColors.Text.primary).bold()) to continue")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(UniColors.Text.secondary)
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(UniColors.Background.secondary)
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(danger, lineWidth: 2)
                        TextField("", text: $typed)
                            .font(.system(size: 21, weight: .bold).monospaced())
                            .foregroundStyle(danger)
                            .tint(danger)
                            .multilineTextAlignment(.center)
                            .tracking(4)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .focused($confirmFocused)
                            .padding(.horizontal, 16)
                            .onChange(of: typed) { _, newValue in
                                if newValue == confirmWord, !didFireTypedHaptic {
                                    didFireTypedHaptic = true
                                    UniHapticEngine.shared.play(.success)
                                } else if newValue != confirmWord {
                                    didFireTypedHaptic = false
                                }
                            }
                    }
                    .frame(height: 58)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
            .onAppear { confirmFocused = true }
        }
    }

    /// Tapping "Erase Aperture" routes through the app's UNIFIED lock screen
    /// (`PinCodeView(.verify)`, which auto-presents Face ID when the user has
    /// enabled biometrics and otherwise shows the PIN keypad) — NOT a raw
    /// `LAContext` Face ID prompt. When no PIN is set there is nothing to
    /// verify, so the typed RESET + the three acknowledgements are the
    /// deliberate gates and we proceed.
    private func confirmAndAuthenticate() {
        guard typedMatches else { return }
        guard PinCodeStorage.hasPin else {
            // No PIN to verify → the typed RESET + acknowledgements are the
            // gates. Drop the keyboard and go straight to the wipe.
            confirmFocused = false
            step = .erasing
            return
        }
        // Dismiss the keyboard FIRST and let it fully retract before the PIN
        // cover slides up — otherwise the keyboard and the cover animate over
        // each other (2026-06-21 user direction). Resign focus, then present
        // once the standard keyboard-dismiss animation has settled.
        confirmFocused = false
        pinGateTask?.cancel()
        pinGateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isShowingPinGate = true
        }
    }

    // MARK: - 5 · Erasing → Factory fresh (one morphing screen)

    private var erasingScreen: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: UniSpacing.mPlus) {
                    morphingEmblem
                    bigTitle(isComplete ? "Reset complete" : (eraseError == nil ? "Erasing Aperture…" : "Couldn’t reset"), centered: true)
                    if let eraseError {
                        subtitleVerbatim(eraseError)
                    } else {
                        subtitle(isComplete
                            ? "Aperture has been restored to its original state. Everything on this device has been erased."
                            : "Securely erasing all wallets and data from this device.",
                            centered: true)
                    }
                    if eraseError == nil, !isComplete { stepsBlock }
                    if isComplete { feedbackCard }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, hPad)
                .padding(.top, UniSpacing.s)
                .padding(.bottom, UniSpacing.xl)
            }
            .scrollIndicators(.hidden)
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    if eraseError != nil {
                        dangerButton("Try again") { eraseError = nil; stagesDone = []; Task { await runWipe() } }
                        ghostButton("Cancel") { close() }
                    } else if isComplete {
                        primaryButton("Get Started") { close() }
                    }
                }
            }
            .padding(.horizontal, hPad)
            .padding(.bottom, UniSpacing.l)
        }
        .navigationTitle("Reset Aperture")
        .navigationBarTitleDisplayMode(.inline)
        .task { await runWipe() }
    }

    private let emblem: CGFloat = 132
    private var ringProgress: Double { Double(stagesDone.count) / Double(FactoryReset.Stage.allCases.count) }

    private var morphingEmblem: some View {
        ZStack {
            ZStack {
                Circle().stroke(UniColors.Fill.quaternary, lineWidth: 7)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(danger, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: ringProgress)
                Image(systemName: "trash")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(danger)
            }
            .opacity(isComplete ? 0 : 1)
            .scaleEffect(!reduceMotion && isComplete ? 0.9 : 1)

            irisDisc(size: emblem)
                .opacity(isComplete ? 1 : 0)
                .scaleEffect(isComplete ? 1 : (reduceMotion ? 1 : 0.85))
        }
        .frame(width: emblem, height: emblem)
        .padding(.vertical, 12)
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : .smooth(duration: 0.6), value: isComplete)
    }

    /// The brand iris seal — an `--ink` disc with the iris in the `--surface`
    /// colour, matching the handoff (and reused as the wallet-picker avatar).
    private func irisDisc(size: CGFloat, irisFraction: CGFloat = 0.82) -> some View {
        ZStack {
            Circle().fill(UniColors.Brand.mark)
            // The iris fills ~82% of the disc to match the handoff (the seal's
            // `mlogo` is 98px inside a 123px disc). A smaller fraction is passed
            // for the wallet-picker avatar.
            Image("IrisWatermarkWhite")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(UniColors.Background.secondary)
                .frame(width: size * irisFraction, height: size * irisFraction)
        }
        .frame(width: size, height: size)
    }

    private var stepsBlock: some View {
        VStack(spacing: 10) {
            stepRow("Erasing wallets & history", state: stepState(.wallets, index: 0))
            stepRow("Wiping keys & recovery phrases", state: stepState(.keys, index: 1))
            stepRow("Restoring default settings", state: stepState(.settings, index: 2))
        }
        .padding(.top, 6)
    }

    private enum StepVisual { case done, active, idle }
    private func stepState(_ stage: FactoryReset.Stage, index: Int) -> StepVisual {
        if stagesDone.contains(stage) { return .done }
        if stagesDone.count == index { return .active }
        return .idle
    }

    private func stepRow(_ label: LocalizedStringKey, state: StepVisual) -> some View {
        HStack(spacing: 12) {
            ZStack {
                switch state {
                case .done:
                    Circle().fill(danger)
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(UniColors.Reset.onDanger)
                case .active:
                    Circle().strokeBorder(danger, lineWidth: 2.5)
                case .idle:
                    Circle().fill(UniColors.Fill.quaternary)
                }
            }
            .frame(width: 22, height: 22)
            Text(label)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(state == .idle ? UniColors.Text.tertiary : UniColors.Text.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(UniColors.Background.secondary, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var feedbackCard: some View {
        VStack(spacing: 0) {
            Text("Help us improve")
                .font(.system(size: 15.5, weight: .bold))
                .foregroundStyle(UniColors.Text.primary)
                .padding(.bottom, 5)
            Text("We’d love to know why you’re leaving and how we could be better. Every message reaches our team.")
                .font(.system(size: 13))
                .foregroundStyle(UniColors.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            Button {
                UniHapticEngine.shared.play(.contextualImpact(.whisper))
                if let url = URL(string: "mailto:care@aperturex.io?subject=Aperture%20feedback") { openURL(url) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "envelope").font(.system(size: 16, weight: .semibold))
                    Text(verbatim: "care@aperturex.io").font(.system(size: 14.5, weight: .bold))
                }
                .foregroundStyle(UniColors.Text.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(UniColors.Fill.quaternary, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(UniColors.Background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, UniSpacing.s)
    }

    // MARK: - The wipe

    private func runWipe() async {
        guard eraseError == nil, !isComplete else { return }
        let animate = !reduceMotion

        // Run the REAL staged wipe in parallel with a minimum-duration paced
        // animation. A real wipe is near-instant, which would flash the ring;
        // pacing the visible steps over ~3s (the handoff's choreography) makes
        // the reset read as a deliberate process. The success morph waits for
        // the real wipe — we NEVER show "complete" before the data is gone.
        let wipe = Task<Bool, Never> { @MainActor in
            do {
                try await FactoryReset.performStagedWipe(modelContext: modelContext) { _ in }
                return true
            } catch {
                return false
            }
        }

        if animate {
            // Reveal each step on a paced timeline (the ring fills as they land).
            let timeline: [(FactoryReset.Stage, Duration)] = [
                (.wallets, .milliseconds(850)),
                (.keys, .milliseconds(900)),
                (.settings, .milliseconds(800)),
            ]
            for (stage, dwell) in timeline {
                try? await Task.sleep(for: dwell)
                UniHapticEngine.shared.play(.contextualImpact(.whisper))
                _ = withAnimation(.easeOut(duration: 0.3)) { stagesDone.insert(stage) }
            }
        }

        // Resolve the real wipe (almost always already finished). Failure ⇒
        // nothing was destroyed; show the error + reset the ring, never morph.
        guard await wipe.value else {
            UniHapticEngine.shared.play(.error)
            withAnimation { stagesDone = [] }
            eraseError = String.apertureLocalized("Couldn’t erase Aperture. Nothing was removed — your wallets, keys, and settings are untouched. Try again.")
            return
        }

        if !animate { stagesDone = Set(FactoryReset.Stage.allCases) }
        if animate { try? await Task.sleep(for: .milliseconds(450)) }
        UniHapticEngine.shared.play(.success)
        withAnimation { isComplete = true }
    }

    private func close() {
        onClose()
    }

    // MARK: - Shared scaffold + components

    private enum NavLeading { case close, back, none }

    /// Native nav-bar leading control for the reset flow. iOS 26 wraps the
    /// toolbar button in its own circular liquid-glass chip automatically —
    /// we just supply the glyph, no custom background.
    @ToolbarContentBuilder
    private func resetLeading(_ leading: NavLeading, onTap: @escaping () -> Void) -> some ToolbarContent {
        if leading != .none {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    UniHapticEngine.shared.play(.contextualImpact(.whisper))
                    onTap()
                } label: {
                    Image(systemName: leading == .close ? "xmark" : "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel(Text(leading == .close ? "Close" : "Back"))
            }
        }
    }

    @ViewBuilder
    private func screenScaffold<C: View, F: View>(
        title: LocalizedStringKey,
        leading: NavLeading,
        onLeading: @escaping () -> Void = {},
        centered: Bool = true,
        @ViewBuilder footer: () -> F,
        @ViewBuilder content: () -> C
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                content()
                    .padding(.horizontal, hPad)
                    .padding(.top, UniSpacing.s)
                    .padding(.bottom, UniSpacing.xl)
                    .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            }
            .scrollIndicators(.hidden)
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) { footer() }
            }
            .padding(.horizontal, hPad)
            .padding(.bottom, UniSpacing.l)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { resetLeading(leading, onTap: onLeading) }
    }

    private func heroGlyph(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 50, weight: .light))
            .foregroundStyle(tint)
            .frame(height: 62)
            .padding(.top, UniSpacing.s)
            .accessibilityHidden(true)
    }

    private func bigTitle(_ text: LocalizedStringKey, centered: Bool) -> some View {
        Text(text)
            .font(.system(size: 27, weight: .bold))
            .tracking(-0.6)
            .foregroundStyle(UniColors.Text.primary)
            .multilineTextAlignment(centered ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            .padding(.top, centered ? 0 : UniSpacing.xs)
    }

    private func subtitle(_ text: LocalizedStringKey, centered: Bool) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(UniColors.Text.secondary)
            .multilineTextAlignment(centered ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: centered ? 330 : .infinity, alignment: centered ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    private func subtitleRich(centered: Bool, _ build: () -> Text) -> some View {
        build()
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(UniColors.Text.secondary)
            .multilineTextAlignment(centered ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 330)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private func subtitleVerbatim(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(UniColors.Text.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 330)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity)
            .background(UniColors.Background.secondary, in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
    }

    private var hair: some View {
        Rectangle().fill(UniColors.Separator.regular).frame(height: 1)
    }

    // MARK: - Buttons (unified Liquid Glass — UniButton)

    /// Destructive CTA — glass-prominent, tinted to the reset's exact red.
    private func dangerButton(_ title: LocalizedStringKey, isEnabled: Bool = true, isLoading: Bool = false, action: @escaping () -> Void) -> some View {
        UniButton(title: title, variant: .destructive, isLoading: isLoading, isEnabled: isEnabled, tint: UniColors.Reset.danger, action: action)
    }

    /// Primary (non-destructive) CTA — glass-prominent, accent tint.
    private func primaryButton(_ title: LocalizedStringKey, isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        UniButton(title: title, variant: .primary, isEnabled: isEnabled, action: action)
    }

    /// Secondary CTA — the unified `.glass` button (no longer bare text).
    private func ghostButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        UniButton(title: title, variant: .secondary, action: action)
    }
}
