import SwiftUI
import SwiftData
import Observation
import UIKit

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
/// Visual contract (handoff): centered hero screens, native NavigationStack
/// pushes between gates, **leading glyphs** on reset lists, text-only action
/// buttons, and the muted brick red `UniColors.Reset.danger` (`#E0483D` /
/// `#FF5B51`) as the ONLY accent.
struct ResetApertureFlow: View {
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \WalletRecord.sortOrder) private var wallets: [WalletRecord]

    private enum Route: Hashable {
        case backup
        case backupPicker
        case acknowledge
        case confirm
        case erasing
    }
    @State private var path: [Route] = []

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
    @State private var confirmFocused = false

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
    private static let visibleProcessStages: [FactoryReset.Stage] = [
        .wallets,
        .privateData,
        .keys,
        .security,
        .settings
    ]
    private static let minimumProcessStepDuration: Duration = .milliseconds(650)

    var body: some View {
        NavigationStack(path: $path) {
            routedScreen(warningScreen)
                .navigationDestination(for: Route.self) { route in
                    routedScreen(destination(for: route))
                }
        }
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
                        push(.erasing)
                    },
                    onCancel: { isShowingPinGate = false },
                    allowsBiometrics: true,
                    showsNavigationControls: false
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

    private func push(_ route: Route) {
        guard path.last != route else { return }
        path.append(route)
    }

    @ViewBuilder
    private func routedScreen<V: View>(_ view: V) -> some View {
        ZStack {
            UniColors.Background.primary.ignoresSafeArea()
            view
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .backup:
            backupScreen
        case .backupPicker:
            walletPickerScreen
        case .acknowledge:
            acknowledgeScreen
        case .confirm:
            confirmScreen
        case .erasing:
            erasingScreen
        }
    }

    // MARK: - 1 · Warning

    private var warningScreen: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    VStack(spacing: UniSpacing.mPlus) {
                        heroGlyph("trash", tint: danger)
                        bigTitle("Reset Aperture", centered: true)
                        subtitle("Resetting removes wallets, keys, balances, and private activity from this device.", centered: true)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: UniSpacing.s, trailing: 0))
                }
                resetImpactSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    dangerButton("Continue") { push(.backup) }
                    ghostButton("Cancel") { close() }
                }
            }
            .padding(.horizontal, hPad)
            .padding(.bottom, UniSpacing.l)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            resetLeading(.close) { close() }
        }
    }

    private var resetImpactSection: some View {
        Section {
            resetImpactRow("creditcard", "Wallets", "Every wallet you’ve created, imported, or are watching.")
            resetImpactRow("key", "Keys & Recovery Phrases", "Permanently removed from this device’s Keychain.")
            resetImpactRow("clock.arrow.circlepath", "Transactions & Balances", "Your wallet history, contacts, cached balances, and portfolio snapshots.")
        }
    }

    private func resetImpactRow(_ symbol: String, _ title: LocalizedStringKey, _ subtitle: LocalizedStringKey) -> some View {
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
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 2 · Backup checkpoint

    private var backupScreen: some View {
        screenScaffold(
            title: "Reset Aperture", leading: .none,
            footer: {
                primaryButton("My Wallets Are Backed Up") { push(.acknowledge) }
                ghostButton("Back Up First") { push(.backupPicker) }
            }
        ) {
            VStack(spacing: UniSpacing.mPlus) {
                heroGlyph("shield", tint: UniColors.Text.primary)
                bigTitle("Before you continue", centered: true)
                // Emphasis below uses `Text` string interpolation
                // (`Text("… \(Text("x").bold()) …")`), the iOS 26-correct
                // form — NOT the deprecated `Text + Text` `+` operator
                // (removed in ad60889). If Xcode still flags a `+` here,
                // it's a stale Issue-Navigator entry; rebuild to clear it.
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
            title: "Back Up", leading: .none,
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
            let id = wallet.id
            let name = wallet.name
            let avatar = wallet.avatarSpec
            let container = modelContext.container
            Task { @MainActor in
                let words = try? await WalletSecretRepository(modelContainer: container)
                    .loadMnemonic(for: id)
                guard let words, !words.isEmpty else { return }
                backupTarget = BackupTarget(id: id, name: name, words: words, avatar: avatar)
            }
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
        VStack(spacing: 0) {
            List {
                acknowledgeIntroSection
                acknowledgeChecklistSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    dangerButton("Continue", isEnabled: allAcknowledged) { push(.confirm) }
                }
            }
            .padding(.horizontal, hPad)
            .padding(.bottom, UniSpacing.l)
        }
        .navigationTitle("Reset Aperture")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var acknowledgeIntroSection: some View {
        Section {
            acknowledgeIntro
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: UniSpacing.s, trailing: 0))
        }
    }

    @ViewBuilder
    private var acknowledgeChecklistSection: some View {
        Section {
            ackRow(
                symbol: "wallet.pass",
                title: "All wallets will be erased",
                isOn: $ackWallets
            ) {
                Text("\(Text("Every wallet profile").foregroundColor(UniColors.Text.primary).fontWeight(.semibold)) on this iPhone will be removed, including created, imported, and watch-only wallets.")
            }
            ackRow(
                symbol: "key.slash",
                title: "Keys cannot be recovered",
                isOn: $ackIrreversible
            ) {
                Text("Aperture keeps \(Text("no cloud backup").foregroundColor(UniColors.Text.primary).fontWeight(.semibold)). Deleted recovery phrases and private keys are gone for good.")
            }
            ackRow(
                symbol: "checkmark.shield",
                title: "My wallets are backed up",
                isOn: $ackBackedUp
            ) {
                Text("I have saved the \(Text("recovery phrase or private key").foregroundColor(UniColors.Text.primary).fontWeight(.semibold)) for every wallet I want to keep.")
            }
        }
    }

    private var acknowledgeIntro: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            HStack(spacing: UniSpacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Destructive reset")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(danger)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(UniColors.Reset.dangerWash, in: Capsule(style: .continuous))

            HStack(alignment: .top, spacing: UniSpacing.m) {
                ZStack {
                    Circle()
                        .fill(UniColors.Reset.dangerWash)
                    Image(systemName: "trash")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(danger)
                }
                .frame(width: 58, height: 58)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: UniSpacing.xs) {
                    Text("Review Before Reset")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(UniColors.Text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Resetting Aperture deletes \(Text("local wallet data, encrypted secrets, cached activity, and security state").foregroundColor(UniColors.Text.primary).fontWeight(.semibold)) from this device.")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(UniColors.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func ackRow(
        symbol: String,
        title: LocalizedStringKey,
        isOn: Binding<Bool>,
        detail: @escaping () -> Text
    ) -> some View {
        Button {
            let wasAll = allAcknowledged
            isOn.wrappedValue.toggle()
            UniHapticEngine.shared.play(isOn.wrappedValue ? .selection : .contextualImpact(.whisper))
            if !wasAll && allAcknowledged { UniHapticEngine.shared.play(.contextualImpact(.commit)) }
        } label: {
            HStack(alignment: .top, spacing: UniSpacing.s) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(isOn.wrappedValue ? danger : UniColors.Text.primary)
                    .frame(width: 28, height: 28)
                    .padding(.top, 2)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(UniColors.Text.primary)
                    detail()
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundColor(UniColors.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isOn.wrappedValue ? danger : UniColors.Text.tertiary)
                    .padding(.top, 4)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .animation(.smooth(duration: 0.22), value: isOn.wrappedValue)
    }

    // MARK: - 4 · Confirm (type RESET + Face ID)

    private var confirmScreen: some View {
        screenScaffold(
            title: "Reset Aperture", leading: .none,
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
                        ResetConfirmationTextField(
                            text: $typed,
                            isFocused: $confirmFocused,
                            tint: danger
                        )
                            .padding(.horizontal, 16)
                            .onChange(of: typed) { _, newValue in
                                let normalized = Self.normalizedResetConfirmation(newValue)
                                if normalized != newValue {
                                    typed = normalized
                                    return
                                }
                                if normalized == confirmWord, !didFireTypedHaptic {
                                    didFireTypedHaptic = true
                                    UniHapticEngine.shared.play(.success)
                                } else if normalized != confirmWord {
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
            push(.erasing)
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

    private static func normalizedResetConfirmation(_ value: String) -> String {
        value.uppercased(with: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - 5 · Erasing → Factory fresh (one morphing screen)

    private var erasingScreen: some View {
        VStack(spacing: 0) {
            List {
                erasingHeaderSection
                if eraseError == nil, !isComplete { processSection }
                if isComplete { feedbackSection }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)
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
        .navigationBarBackButtonHidden(true)
        .task { await runWipe() }
    }

    @ViewBuilder
    private var erasingHeaderSection: some View {
        Section {
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
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, hPad)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.s)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
    }

    private let emblem: CGFloat = 132
    private var ringProgress: Double {
        Double(stagesDone.count) / Double(Self.visibleProcessStages.count)
    }

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

    @ViewBuilder
    private var processSection: some View {
        Section {
            ForEach(Self.visibleProcessStages, id: \.self) { stage in
                processRow(stage, state: stepState(stage))
                    .listRowBackground(UniColors.Background.secondary)
            }
        }
    }

    private enum StepVisual { case done, active, idle }
    private func stepState(_ stage: FactoryReset.Stage) -> StepVisual {
        if stagesDone.contains(stage) { return .done }
        if Self.visibleProcessStages.first(where: { !stagesDone.contains($0) }) == stage { return .active }
        return .idle
    }

    private func processRow(_ stage: FactoryReset.Stage, state: StepVisual) -> some View {
        HStack(alignment: .center, spacing: 12) {
            processStatusGlyph(state)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(stage.processTitle)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(state == .idle ? UniColors.Text.tertiary : UniColors.Text.primary)
                Text(stage.processDetail)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func processStatusGlyph(_ state: StepVisual) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(danger)
        case .active:
            ProgressView()
                .controlSize(.small)
                .tint(danger)
        case .idle:
            Image(systemName: "circle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(UniColors.Fill.quaternary)
        }
    }

    @ViewBuilder
    private var feedbackSection: some View {
        Section {
            feedbackCard
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
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

        do {
            try await FactoryReset.performStagedWipe(modelContext: modelContext) { stage in
                await completeVisibleProcessStage(stage, animate: animate)
            }
        } catch {
            UniHapticEngine.shared.play(.error)
            withAnimation { stagesDone = [] }
            eraseError = String.apertureLocalized("Couldn’t erase Aperture. Nothing was removed — your wallets, keys, and settings are untouched. Try again.")
            return
        }

        if stagesDone.count < Self.visibleProcessStages.count {
            withAnimation(animate ? .easeOut(duration: 0.28) : nil) {
                stagesDone = Set(Self.visibleProcessStages)
            }
        }
        if animate { try? await Task.sleep(for: .milliseconds(450)) }
        UniHapticEngine.shared.play(.success)
        withAnimation { isComplete = true }
    }

    private func completeVisibleProcessStage(_ stage: FactoryReset.Stage, animate: Bool) async {
        guard Self.visibleProcessStages.contains(stage), !stagesDone.contains(stage) else { return }
        try? await Task.sleep(for: Self.minimumProcessStepDuration)
        UniHapticEngine.shared.play(.contextualImpact(.whisper))
        withAnimation(animate ? .easeOut(duration: 0.28) : nil) {
            _ = stagesDone.insert(stage)
        }
    }

    private func close() {
        onClose()
    }

    // MARK: - Shared scaffold + components

    private enum NavLeading { case close, none }

    /// Root close control. Pushed reset screens use the system NavigationStack
    /// back button and edge-swipe gesture.
    @ToolbarContentBuilder
    private func resetLeading(_ leading: NavLeading, onTap: @escaping () -> Void) -> some ToolbarContent {
        if leading == .close {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    UniHapticEngine.shared.play(.contextualImpact(.whisper))
                    onTap()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel(Text("Close"))
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

private extension FactoryReset.Stage {
    var processTitle: LocalizedStringKey {
        switch self {
        case .wallets:
            return "Erasing wallets & history"
        case .privateData:
            return "Clearing private app records"
        case .keys:
            return "Wiping keys & recovery phrases"
        case .security:
            return "Clearing passcode & app keys"
        case .networkCache:
            return ""
        case .settings:
            return "Restoring default settings"
        }
    }

    var processDetail: LocalizedStringKey {
        switch self {
        case .wallets:
            return "Wallet records, balances, transactions, and manifests."
        case .privateData:
            return "Security records and wallet-specific sync data."
        case .keys:
            return "Seeds, mnemonics, and imported private keys."
        case .security:
            return "PIN records and app encryption keys."
        case .networkCache:
            return ""
        case .settings:
            return "Active wallet, screen restoration, and resettable preferences."
        }
    }
}

// MARK: - Reset confirmation input

/// UIKit-backed field for the destructive RESET confirmation. SwiftUI can ask
/// for `.characters` capitalization, but it cannot pin the keyboard language;
/// this field forces an English text input mode when one exists and normalizes
/// every typed or pasted value to uppercase.
private struct ResetConfirmationTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let tint: Color

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> EnglishUppercaseUITextField {
        let field = EnglishUppercaseUITextField(frame: .zero)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.keyboardType = .asciiCapable
        field.autocapitalizationType = .allCharacters
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.smartQuotesType = .no
        field.textContentType = nil
        field.returnKeyType = .done
        field.textAlignment = .center
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.adjustsFontForContentSizeCategory = false
        field.accessibilityLabel = String.apertureLocalized("Type RESET to continue")
        return field
    }

    func updateUIView(_ field: EnglishUppercaseUITextField, context: Context) {
        context.coordinator.parent = self
        let normalized = Self.normalized(text)
        let uiTint = UIColor(tint)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        field.defaultTextAttributes = [
            .font: UIFont.monospacedSystemFont(ofSize: 21, weight: .bold),
            .foregroundColor: uiTint,
            .kern: 4,
            .paragraphStyle: paragraphStyle
        ]
        field.tintColor = uiTint
        field.textColor = uiTint
        field.font = .monospacedSystemFont(ofSize: 21, weight: .bold)
        field.textAlignment = .center
        field.contentHorizontalAlignment = .center

        if field.text != normalized {
            field.text = normalized
        }
        if text != normalized {
            DispatchQueue.main.async {
                text = normalized
            }
        }

        if isFocused, !field.isFirstResponder {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard UIApplication.shared.applicationState == .active,
                      field.window != nil,
                      !field.isFirstResponder
                else { return }
                field.becomeFirstResponder()
            }
        } else if !isFocused, field.isFirstResponder {
            DispatchQueue.main.async {
                field.resignFirstResponder()
            }
        }
    }

    private static func normalized(_ value: String) -> String {
        value.uppercased(with: Locale(identifier: "en_US_POSIX"))
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ResetConfirmationTextField

        init(_ parent: ResetConfirmationTextField) {
            self.parent = parent
        }

        @objc func editingChanged(_ field: UITextField) {
            let normalized = ResetConfirmationTextField.normalized(field.text ?? "")
            if field.text != normalized {
                field.text = normalized
            }
            if parent.text != normalized {
                parent.text = normalized
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.isFocused = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isFocused = false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            parent.isFocused = false
            return false
        }
    }
}

private final class EnglishUppercaseUITextField: UITextField {
    override var textInputMode: UITextInputMode? {
        for mode in UITextInputMode.activeInputModes {
            guard let language = mode.primaryLanguage?.lowercased() else { continue }
            if language == "en" || language.hasPrefix("en-") {
                return mode
            }
        }
        return super.textInputMode
    }
}
