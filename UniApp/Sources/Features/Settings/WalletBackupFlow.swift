import SwiftUI

/// **Back Up Wallet** — the full flow from the 2026-06-19 backup handoff,
/// reached from the recovery-phrase reveal's "Backup Now" button. One
/// chooser branches into two real paths:
///
/// - **iCloud:** create a backup password → encrypt the phrase on device →
///   upload the ciphertext to the user's private CloudKit DB → verify by
///   re-fetching. Real async stages drive the progress ring; the success
///   seal appears ONLY after iCloud confirms. (`WalletBackupCrypto` +
///   `CloudKitBackupStore`.)
/// - **Manual:** show the phrase to write down → the canonical
///   `BackupVerifyView` challenge → `markBackupComplete`. Nothing leaves
///   the device.
///
/// Security: the decrypted `words` are passed in from the already-authed
/// reveal screen (no second Keychain hit); the backup password lives only
/// in this flow's memory and is never stored. Everything is real — no
/// stubbed timers, no placeholder success (handoff requirement).
struct WalletBackupFlow: View {
    let walletId: UUID
    let walletName: String
    let words: [String]
    let onClose: () -> Void

    @State private var path: [Step] = []
    /// In-memory only; set by the password screen, consumed by the upload.
    @State private var backupPassword = ""
    /// Built once for the manual verify challenge (BackupVerifyView needs a
    /// stable CreateWalletState carrying the phrase).
    @State private var verifyState: CreateWalletState?

    enum Step: Hashable {
        case iCloudPassword
        case iCloudProgress
        case manualWriteDown
        case manualVerify
        case manualConfirmed
    }

    var body: some View {
        NavigationStack(path: $path) {
            ChooseMethodScreen(
                onICloud: { path.append(.iCloudPassword) },
                onManual: { path.append(.manualWriteDown) },
                onClose: onClose
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Step.self) { step in
                destination(for: step)
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
    }

    @ViewBuilder
    private func destination(for step: Step) -> some View {
        switch step {
        case .iCloudPassword:
            ICloudPasswordScreen { password in
                backupPassword = password
                path.append(.iCloudProgress)
            }
        case .iCloudProgress:
            ICloudProgressScreen(
                walletId: walletId,
                walletName: walletName,
                words: words,
                password: backupPassword,
                onDone: onClose
            )
        case .manualWriteDown:
            ManualWriteDownScreen(words: words) {
                let state = CreateWalletState(wordCount: words.count == 24 ? .twentyFour : .twelve)
                state.commit(words: words)
                verifyState = state
                path.append(.manualVerify)
            }
        case .manualVerify:
            ManualVerifyScreen(
                state: verifyState,
                walletId: walletId,
                onConfirmed: { path.append(.manualConfirmed) }
            )
        case .manualConfirmed:
            BackupConfirmedScreen(onDone: onClose)
        }
    }
}

// MARK: - 1 · Choose method

private struct ChooseMethodScreen: View {
    let onICloud: () -> Void
    let onManual: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: UniSpacing.l) {
                    Image("LogoCircle")
                        .resizable().scaledToFit()
                        .frame(width: 64, height: 64)
                        .padding(.top, UniSpacing.l)
                        .accessibilityHidden(true)

                    VStack(spacing: UniSpacing.xs) {
                        Text("Back up your wallet")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(UniColors.Text.primary)
                            .multilineTextAlignment(.center)
                        Text("Choose how to keep a copy of your recovery phrase. You can always do the other later.")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: UniSpacing.m) {
                        MethodCard(
                            icon: "icloud.fill",
                            iconTint: UniColors.Text.primary,
                            title: "iCloud Backup",
                            detail: "An encrypted copy syncs to iCloud. Restore on any device by signing in.",
                            action: { UniHapticEngine.shared.play(.selection); onICloud() }
                        )
                        MethodCard(
                            icon: "pencil.and.list.clipboard",
                            iconTint: UniColors.Text.secondary,
                            title: "Manual Backup",
                            detail: "Write the words down and store them offline yourself.",
                            action: { UniHapticEngine.shared.play(.selection); onManual() }
                        )
                    }
                    .padding(.top, UniSpacing.s)

                    Label {
                        Text("Both keep your phrase end-to-end encrypted. Aperture can never read it.")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 13))
                            .foregroundStyle(UniColors.Text.tertiary)
                    }
                    .padding(.top, UniSpacing.s)
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
                .frame(maxWidth: .infinity)
            }
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { onClose() } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel(Text("Close"))
            }
        }
    }
}

private struct MethodCard: View {
    let icon: String
    let iconTint: Color
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: UniSpacing.m) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(iconTint)
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(UniColors.Text.primary)
                    Text(detail)
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.tertiary)
            }
            .padding(UniSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                    .fill(UniColors.Background.secondary)
            )
            .contentShape(RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - iCloud · 2 · Create a backup password

private struct ICloudPasswordScreen: View {
    let onContinue: (String) -> Void

    @State private var password = ""
    @State private var confirm = ""
    @State private var showPassword = false
    @State private var showConfirm = false
    @State private var wasStrong = false

    private var strength: PasswordStrength { PasswordStrength.estimate(password) }
    private var passwordsMatch: Bool { !confirm.isEmpty && password == confirm }
    private var canContinue: Bool { strength.meetsMinimum && passwordsMatch }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: UniSpacing.l) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 40, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(UniColors.Text.primary)
                        .frame(width: 84, height: 84)
                        .background(Circle().fill(UniColors.Text.primary.opacity(0.12)))
                        .padding(.top, UniSpacing.m)
                        .accessibilityHidden(true)

                    VStack(spacing: UniSpacing.xs) {
                        Text("Create a backup password")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(UniColors.Text.primary)
                            .multilineTextAlignment(.center)
                        Text("This password encrypts your backup. You'll need it to restore on another device.")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: UniSpacing.s) {
                        passwordField(
                            placeholder: "Password",
                            text: $password,
                            isRevealed: $showPassword
                        )
                        StrengthMeter(strength: strength)
                        passwordField(
                            placeholder: "Confirm password",
                            text: $confirm,
                            isRevealed: $showConfirm
                        )
                        if !confirm.isEmpty && !passwordsMatch {
                            Text("Passwords don't match.")
                                .font(UniTypography.footnote)
                                .foregroundStyle(UniColors.Status.errorForeground)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, UniSpacing.s)

                    Label {
                        Text("Aperture can't reset this password. If you lose it, the iCloud backup can't be opened — store it in a password manager.")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Text.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 13))
                            .foregroundStyle(UniColors.Status.warningForeground)
                    }
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
            }

            UniButton(title: "Continue", variant: .primary, isEnabled: canContinue) {
                onContinue(password)
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.m)
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        .onChange(of: strength.score) { _, score in
            // "the moment the meter reaches strong" → a light tick.
            let strong = score >= PasswordStrength.Rating.good.rawValue
            if strong && !wasStrong { UniHapticEngine.shared.play(.contextualImpact(.tap)) }
            wasStrong = strong
        }
    }

    @ViewBuilder
    private func passwordField(
        placeholder: LocalizedStringKey,
        text: Binding<String>,
        isRevealed: Binding<Bool>
    ) -> some View {
        HStack(spacing: UniSpacing.s) {
            Group {
                if isRevealed.wrappedValue {
                    TextField(placeholder, text: text)
                } else {
                    SecureField(placeholder, text: text)
                }
            }
            .textContentType(.newPassword)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .font(UniTypography.body)
            .foregroundStyle(UniColors.Text.primary)

            Button {
                UniHapticEngine.shared.play(.selection)
                isRevealed.wrappedValue.toggle()
            } label: {
                Image(systemName: isRevealed.wrappedValue ? "eye.slash" : "eye")
                    .font(.system(size: 16))
                    .foregroundStyle(UniColors.Icon.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isRevealed.wrappedValue ? "Hide password" : "Show password"))
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s + 2)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Background.secondary)
        )
    }
}

/// The 4-segment strength meter — driven by the REAL entropy estimate.
private struct StrengthMeter: View {
    let strength: PasswordStrength

    private var label: LocalizedStringKey {
        switch strength.rating {
        case .empty: return ""
        case .weak: return "Weak"
        case .fair: return "Fair"
        case .good: return "Strong"
        case .strong: return "Very strong"
        }
    }

    private var tint: Color {
        switch strength.rating {
        case .empty, .weak: return UniColors.Status.errorForeground
        case .fair: return UniColors.Status.warningForeground
        case .good, .strong: return UniColors.Status.successForeground
        }
    }

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(i < strength.score ? tint : UniColors.Separator.regular)
                        .frame(height: 4)
                }
            }
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 78, alignment: .trailing)
                .animation(.easeInOut(duration: 0.15), value: strength.score)
        }
    }
}

// MARK: - iCloud · 3 · Encrypt + upload + verify (one morphing screen)

private struct ICloudProgressScreen: View {
    let walletId: UUID
    let walletName: String
    let words: [String]
    let password: String
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var progress: Double = 0
    @State private var steps: [StepState] = [.pending, .pending, .pending]
    @State private var phase: Phase = .running
    @State private var didStart = false

    enum Phase: Equatable { case running, done, failed(String) }
    enum StepState: Equatable { case pending, active, done }

    private let store = CloudKitBackupStore()

    private var isDone: Bool { phase == .done }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: UniSpacing.l) {
                    BackupRing(progress: progress, isDone: isDone, reduceMotion: reduceMotion)
                        .frame(width: 132, height: 132)
                        .padding(.top, UniSpacing.xl)

                    Text(isDone ? "Backed up to iCloud" : "Backing up to iCloud")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(UniColors.Text.primary)
                        .multilineTextAlignment(.center)
                        .animation(.easeInOut(duration: 0.25), value: isDone)

                    if case .failed(let message) = phase {
                        VStack(spacing: UniSpacing.s) {
                            Text(verbatim: message)
                                .font(UniTypography.body)
                                .foregroundStyle(UniColors.Status.errorForeground)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if isDone {
                        Text("Your encrypted recovery phrase is safe in your iCloud. Restore it on any device by signing in and entering this password.")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(spacing: UniSpacing.s) {
                            StepRow(state: steps[0], label: "Encrypting on this device")
                            StepRow(state: steps[1], label: "Uploading to iCloud")
                            StepRow(state: steps[2], label: "Verifying")
                        }
                        .padding(.top, UniSpacing.s)
                    }
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
                .frame(maxWidth: .infinity)
            }

            footer
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.s)
                .padding(.bottom, UniSpacing.m)
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationBarBackButtonHidden(!isDone && phase == .running)
        .interactiveDismissDisabled(phase == .running)
        .task {
            guard !didStart else { return }
            didStart = true
            await run()
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .done:
            UniButton(title: "Done", variant: .primary) { onDone() }
        case .failed:
            UniButton(title: "Try again", variant: .primary) {
                Task { await run() }
            }
        case .running:
            EmptyView()
        }
    }

    private func run() async {
        phase = .running
        steps = [.active, .pending, .pending]
        progress = reduceMotion ? 0.34 : 0.06

        let wid = walletId, wname = walletName, w = words, pw = password
        do {
            // 1 · Encrypt on device (PBKDF2 600k → AES-GCM) off the main actor.
            let blob = try await Task.detached(priority: .userInitiated) {
                try WalletBackupBlob.make(
                    walletId: wid, walletName: wname, words: w, password: pw, createdAt: Date()
                )
            }.value
            steps[0] = .done; steps[1] = .active
            setProgress(0.4)
            UniHapticEngine.shared.play(.contextualImpact(.commit))

            // 2 · Upload to the user's private CloudKit DB (real progress).
            try await store.ensureAccountAvailable()
            try await store.save(blob) { frac in
                Task { @MainActor in setProgress(0.4 + frac * 0.4) }
            }
            steps[1] = .done; steps[2] = .active
            setProgress(0.85)
            UniHapticEngine.shared.play(.contextualImpact(.commit))

            // 3 · Verify by re-fetching — the seal only appears on real proof.
            _ = try await store.verify(walletId: wid)
            steps[2] = .done
            setProgress(1.0)
            withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.4)) { phase = .done }
            UniHapticEngine.shared.play(.contextualImpact(.consequential))
        } catch {
            withAnimation(.easeInOut(duration: 0.2)) { phase = .failed(Self.message(for: error)) }
            UniHapticEngine.shared.play(.warning)
        }
    }

    private func setProgress(_ value: Double) {
        withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.4)) { progress = max(progress, value) }
    }

    /// Map the real backend error to an honest, human message.
    private static func message(for error: Error) -> String {
        if let e = error as? CloudKitBackupStore.StoreError {
            switch e {
            case .notSignedIn:
                return String.apertureLocalized("You're not signed in to iCloud. Sign in from Settings, then try again.")
            case .iCloudUnavailable:
                return String.apertureLocalized("iCloud isn't available on this device right now. Try again later.")
            case .networkUnavailable:
                return String.apertureLocalized("No internet connection. Reconnect and try again.")
            case .quotaExceeded:
                return String.apertureLocalized("Your iCloud storage is full. Free up space and try again.")
            case .notFound:
                return String.apertureLocalized("The backup couldn't be verified. Try again.")
            case .cloudKit, .unknown:
                return String.apertureLocalized("Something went wrong talking to iCloud. Try again.")
            }
        }
        return String.apertureLocalized("Couldn't complete the backup. Try again.")
    }
}

/// The progress ring around the Aperture mark that morphs into the green
/// success seal in place (handoff: ring fades/scales out as the seal scales
/// in at the same spot). Reduced motion shows the final state with no spin.
private struct BackupRing: View {
    let progress: Double
    let isDone: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if isDone {
                // Solid green seal + white check (2026-06-20 user direction —
                // a filled seal, not a thin ring), scaling in where the ring was.
                Circle()
                    .fill(UniColors.Status.successForeground)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 52, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            } else {
                Circle().stroke(UniColors.Separator.regular, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(UniColors.Text.primary, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image("LogoCircle")
                    .resizable().scaledToFit()
                    .frame(width: 60, height: 60)
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct StepRow: View {
    let state: ICloudProgressScreen.StepState
    let label: LocalizedStringKey

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            Group {
                switch state {
                case .pending:
                    Image(systemName: "circle")
                        .foregroundStyle(UniColors.Icon.tertiary)
                case .active:
                    ProgressView().controlSize(.small)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(UniColors.Status.successForeground)
                }
            }
            .font(.system(size: 18))
            .frame(width: 22, height: 22)

            Text(label)
                .font(UniTypography.body)
                .foregroundStyle(state == .pending ? UniColors.Text.tertiary : UniColors.Text.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Background.secondary)
        )
    }
}

// MARK: - Manual · 2 · Write down phrase

private struct ManualWriteDownScreen: View {
    let words: [String]
    let onWrittenDown: () -> Void

    @State private var isShowingScreenshotWarning = false
    @State private var isVisible = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: UniSpacing.l) {
                    VStack(alignment: .leading, spacing: UniSpacing.xs) {
                        Text("Write these words down")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(UniColors.Text.primary)
                        Text("Copy all \(words.count) words onto paper, in order, and store them somewhere only you can reach.")
                            .font(UniTypography.subheadline)
                            .foregroundStyle(UniColors.Text.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, UniSpacing.s)

                    PhraseGrid(words: words)
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
            }

            UniButton(title: "I've written it down", variant: .primary) {
                UniHapticEngine.shared.play(.contextualImpact(.tap))
                onWrittenDown()
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.m)
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        // This IS a seed-phrase screen, so a screenshot here warns (the
        // password / progress / success screens don't — they show no phrase).
        .sheet(isPresented: $isShowingScreenshotWarning) {
            ScreenshotWarningSheet(
                onKeepScreenshot: { isShowingScreenshotWarning = false }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            guard isVisible else { return }
            isShowingScreenshotWarning = true
        }
    }
}

// (PhraseGrid now lives in the shared Features/Wallet/PhraseGrid.swift.)

// MARK: - Manual · 3 · Verify

private struct ManualVerifyScreen: View {
    let state: CreateWalletState?
    let walletId: UUID
    let onConfirmed: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var isShowingError = false

    var body: some View {
        Group {
            if let state {
                BackupVerifyView(state: state) {
                    Task { await complete() }
                }
            } else {
                UniLoadingState(caption: "Preparing…")
            }
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        .alert(Text("Couldn't record the backup"), isPresented: $isShowingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Aperture couldn't save the backup confirmation. Your phrase is still on this iPhone. Try again.")
        }
    }

    @MainActor
    private func complete() async {
        let repo = WalletRepository(modelContainer: modelContext.container)
        do {
            try await repo.markBackupComplete(id: walletId)
        } catch {
            isShowingError = true
            return
        }
        onConfirmed()
    }
}

// MARK: - Manual · 4 · Confirmed

private struct BackupConfirmedScreen: View {
    let onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: UniSpacing.l) {
                Circle()
                    .fill(UniColors.Status.successForeground)
                    .frame(width: 96, height: 96)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.system(size: 44, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.6)
                    .opacity(appeared || reduceMotion ? 1 : 0)
                    .accessibilityHidden(true)

                VStack(spacing: UniSpacing.xs) {
                    Text("Backup confirmed")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundStyle(UniColors.Text.primary)
                    Text("Your written phrase is the only copy. Aperture has no copy of it — keep it safe.")
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, UniSpacing.l)
            Spacer()

            UniButton(title: "Done", variant: .primary) { onDone() }
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.m)
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { appeared = true }
        }
    }
}
