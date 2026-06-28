import SwiftUI
import SwiftData

/// Settings → Security. Single surface for all device-side
/// authentication: PIN enable/change/disable, biometric toggle,
/// auto-lock duration, backup-pending shortcut, and reset-import-
/// warnings hatch.
struct SecuritySettingsView: View {
    @AppStorage("pinEnabled") private var pinEnabled: Bool = false
    @AppStorage("biometricEnabled") private var biometricEnabled: Bool = false
    // Per-action Face ID gate (2026-06-20). Secure default ON; only takes
    // effect when Face ID is enabled. Enforced in SendReviewView.
    @AppStorage(PinCodePreference.requireBiometricForSendKey) private var requireForSend: Bool = true
    // iOS-style "Erase Data": wipe the app after N failed lock-screen passcode
    // attempts. OFF by default; arming it shows a confirmation first. Enforced
    // in `AppLockView` against `PinCodeStorage`'s dedicated unlock counter.
    @AppStorage("eraseDataAfterFailedAttempts") private var eraseDataEnabled: Bool = false
    @AppStorage(AutoLockPreference.storageKey) private var autoLockRaw: Int = AutoLockPreference.defaultValue
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var isShowingPinSetup: Bool = false
    @State private var isShowingPinChange: Bool = false
    @State private var isShowingDisableVerify: Bool = false
    @State private var biometricAvailable: Bool = false
    /// Confirms ARMING "Erase Data" — a destructive auto-wipe, so it's never
    /// turned on by a single stray tap. Turning it OFF needs no confirm.
    @State private var isShowingEraseDataConfirm: Bool = false

    /// Per the user's 2026-06-06 direction: entering Settings →
    /// Security itself must be gated behind passcode, the same way
    /// Apple gates Settings → Touch ID & Passcode.
    ///
    /// **Passcode-only since 2026-06-25 (user direction):** even when
    /// Face ID is enabled for app unlock or sending, entering Security
    /// must require the typed app passcode. The gate passes
    /// `allowsBiometrics: false`, so `PinCodeView(.verify)` never
    /// auto-prompts Face ID and never renders the biometric keypad key.
    /// `isUnlocked` is `false` on first appear; the fullScreenCover below
    /// shows the verify keypad. On successful verify we flip the flag and
    /// dismiss the cover, revealing the real settings list. If the user
    /// cancels the verify, the navigation pops back to the Settings root.
    ///
    /// **Cold-launch restoration (2026-06-17):** the Security route is
    /// excluded from `ScreenRestoration`'s Settings stack
    /// (`SettingsDestination.isColdLaunchRestorable == false`), so
    /// closing + reopening the app never lands back inside Security —
    /// the user returns to the Settings root and re-enters with a fresh
    /// passcode prompt.
    ///
    /// **The flag means "this visit is authorized" (2026-06-13).**
    /// A user who enters with NO passcode set is authorized by
    /// definition — there is nothing to verify against — so
    /// `onAppear` marks the visit unlocked. Without that, creating
    /// a passcode mid-visit flipped `PinCodeStorage.hasPin` to true
    /// while `isUnlocked` was still false, and the gate re-armed
    /// against the very passcode the user had just typed twice:
    /// the list vanished to the empty backdrop and a spurious
    /// verify prompt appeared (user report 2026-06-13).
    @State private var isUnlocked: Bool = false

    var body: some View {
        Group {
            if isUnlocked || !PinCodeStorage.hasPin {
                content
            } else {
                // Empty backdrop while gating — the actual settings
                // list is hidden behind the fullScreenCover, so a
                // quick glance at the screen below the cover doesn't
                // briefly leak the toggles before auth.
                UniColors.Background.primary.ignoresSafeArea()
            }
        }
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Security"))
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            biometricAvailable = BiometricService().isAvailable
            syncBiometricActionTogglesWithMaster()
            // No passcode ⇒ nothing to gate ⇒ the visit is
            // authorized for its whole lifetime, including after a
            // passcode is created mid-visit (see `isUnlocked` doc).
            if !PinCodeStorage.hasPin {
                isUnlocked = true
            }
        }
        .fullScreenCover(isPresented: shouldShowGate) {
            NavigationStack {
                PinCodeView(
                    mode: .verify,
                    onComplete: { _ in
                        isUnlocked = true
                    },
                    onCancel: {
                        // User declined to authenticate — pop back
                        // to the previous Settings level.
                        dismiss()
                    },
                    // Passcode-only per user direction 2026-06-25.
                    // Face ID may be enabled inside Security for app
                    // unlock / send actions, but it cannot be used to
                    // enter this screen.
                    allowsBiometrics: false,
                    showsNavigationControls: false
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .accessibilityLabel(Text("Cancel"))
                    }
                }
            }
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
    }

    /// `fullScreenCover` binding that's `true` only when the user
    /// is unauthenticated AND has a passcode set. Wallets with no
    /// passcode (fresh installs, users who explicitly skipped)
    /// fall through and see the list immediately — there's
    /// nothing to gate.
    private var shouldShowGate: Binding<Bool> {
        Binding(
            get: { !isUnlocked && PinCodeStorage.hasPin },
            set: { _ in
                // Intentionally inert. The cover's visibility is
                // derived state — only `PinCodeView`'s `onComplete`
                // may flip `isUnlocked`. Treating any dismissal of
                // the cover (including Cancel) as success would be
                // an authentication bypass; cancelling pops back to
                // the Settings root via `onCancel` instead.
            }
        )
    }

    private var content: some View {
        List {
            // LOCK — passcode + Face ID master toggle. BOTH are always
            // visible so the user can always find Face ID (2026-06-20 user
            // report: "I don't see Face ID to enable"). When no passcode is
            // set, the Face ID toggle is greyed with a footer hint — exactly
            // how iOS gates Face ID behind a passcode — instead of hiding it.
            Section {
                if !pinEnabled {
                    pinRow // "Turn Passcode On"
                }
                if biometricAvailable {
                    // Disabled (greyed, non-interactive) until a passcode
                    // exists — Face ID needs the passcode as its fallback.
                    biometricRow
                        .disabled(!pinEnabled)
                        .opacity(pinEnabled ? 1 : 0.5)
                }
            } header: {
                Text("Lock").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
            } footer: {
                Text(lockFooter)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // "Use Face ID For:" — iOS register. Shown whenever the device
            // has Face ID; rows are greyed until Face ID is on (which needs a
            // passcode), the same way iOS greys these until the master is on.
            if biometricAvailable {
                Section {
                    faceIDActionRow("Sending transactions", isOn: $requireForSend)
                } header: {
                    Text("Use Face ID For").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
                } footer: {
                    Text("Require Face ID before each of these actions. If Face ID fails, you can fall back to your passcode.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // iOS groups "Turn Passcode Off" + "Change Passcode" in one
            // rounded block, both as plain blue action rows (no icons,
            // not red) — 2026-06-20 user direction to match Apple exactly.
            // Only present once a passcode is set.
            if pinEnabled {
                Section {
                    Button {
                        isShowingDisableVerify = true
                    } label: {
                        HStack {
                            Text("Turn Passcode Off")
                                .font(UniTypography.body)
                                .foregroundStyle(UniColors.Button.text)
                            Spacer()
                        }
                        .padding(.vertical, UniSpacing.xxs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(UniColors.List.rowBackground)

                    Button {
                        isShowingPinChange = true
                    } label: {
                        HStack {
                            Text("Change Passcode")
                                .font(UniTypography.body)
                                .foregroundStyle(UniColors.Button.text)
                            Spacer()
                        }
                        .padding(.vertical, UniSpacing.xxs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(UniColors.List.rowBackground)
                } footer: {
                    Text("Turning off the passcode removes the lock from this iPhone's copy of your wallets. Your wallet secrets stay encrypted locally — but anyone with this phone unlocked can open Aperture without proving they own it.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // ERASE DATA — iOS-style auto-wipe after repeated wrong
                // passcodes. Only offered once a passcode is set (there's
                // nothing to fail without one). Disableable.
                eraseDataSection
            }

            if pinEnabled {
                Section {
                    NavigationLink(value: SettingsDestination.autoLock) {
                        SettingsRowShared(
                            systemImage: "lock.rotation",
                            title: "Auto-lock",
                            trailing: LocalizedStringKey(AutoLockPreference.option(for: autoLockRaw).label),
                            iconTint: .purple
                        )
                    }
                    .listRowBackground(UniColors.List.rowBackground)
                } header: {
                    Text("Timing").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
                }
            }

        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // Arming Erase Data is destructive — confirm before turning it on.
        .alert(Text("Turn on Erase Data?"), isPresented: $isShowingEraseDataConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Turn On", role: .destructive) { eraseDataEnabled = true }
        } message: {
            Text("After 10 failed passcode attempts, every wallet and all data on this iPhone will be erased. Make sure your recovery phrases are backed up — a wallet you didn't back up can't be recovered.")
        }
        // navigationTitle / navigationBarTitleDisplayMode /
        // background / onAppear / Security-gate fullScreenCover are
        // all attached to the outer Group above. The per-action
        // covers (PinSetup / PinChange / PinDisableVerify) stay
        // here because they're only reachable once the user is
        // unlocked and looking at this list.
        .fullScreenCover(isPresented: $isShowingPinSetup) {
            // Re-uses the canonical PIN setup flow per Rule #17.
            // On finish, pinEnabled has been written by PinSetupFlow's
            // internal handler. Mark the visit authorized BEFORE
            // dismissing — the user just chose and confirmed this
            // passcode seconds ago; re-verifying it immediately is
            // hostile and was the Bug-B loop (belt-and-braces with
            // the `onAppear` authorization; this also covers the
            // entered-with-no-PIN → created-one path directly).
            PinSetupFlow(
                onFinish: {
                    isUnlocked = true
                    isShowingPinSetup = false
                },
                onBack:   { isShowingPinSetup = false }
            )
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        .fullScreenCover(isPresented: $isShowingPinChange) {
            PinChangeFlow(
                onFinish: { isShowingPinChange = false }
            )
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        .fullScreenCover(isPresented: $isShowingDisableVerify) {
            PinDisableVerifyFlow(
                onSuccess: {
                    PinCodeStorage.clear()
                    pinEnabled = false
                    setBiometricEnabled(false)
                    isShowingDisableVerify = false
                },
                onCancel: { isShowingDisableVerify = false }
            )
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
    }

    // MARK: - Rows

    /// iOS "Face ID & Passcode" register: a single blue "Turn Passcode On"
    /// action row, no leading icon, no status pill (2026-06-20 user
    /// direction — match Apple's exact wording + style). The On state's
    /// Change / Turn-Off actions live in their own section below.
    private var pinRow: some View {
        Button {
            isShowingPinSetup = true
        } label: {
            HStack(spacing: UniSpacing.s) {
                Text("Turn Passcode On")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Button.text)
                Spacer()
            }
            .padding(.vertical, UniSpacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(UniColors.List.rowBackground)
    }

    private var biometricRow: some View {
        UniToggle(isOn: Binding(
            get: { biometricEnabled },
            set: { newValue in
                if newValue {
                    Task { await tryEnableBiometric() }
                } else {
                    setBiometricEnabled(false)
                }
            }
        )) {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: "faceid")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(UniColors.Icon.secondary)
                    .frame(width: 28, alignment: .center)
                    .accessibilityHidden(true)
                Text("Face ID")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
            }
        }
        .tint(UniColors.Button.Primary.tint)
        .padding(.vertical, UniSpacing.xxs)
        .listRowBackground(UniColors.List.rowBackground)
    }

    /// A per-action Face ID toggle. Disabled (greyed) until Face ID is on,
    /// matching iOS's "Use Face ID For" rows.
    private func faceIDActionRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        UniToggle(isOn: isOn) {
            Text(title)
                .font(UniTypography.body)
                .foregroundStyle(biometricEnabled ? UniColors.Text.primary : UniColors.Text.disabled)
        }
        .tint(UniColors.Button.Primary.tint)
        .disabled(!biometricEnabled)
        .padding(.vertical, UniSpacing.xxs)
        .listRowBackground(UniColors.List.rowBackground)
    }

    /// Footer under the Lock section. Names what the passcode does and, when
    /// no passcode is set, that Face ID needs one first (so the greyed Face ID
    /// toggle above is explained rather than mysterious — 2026-06-20).
    private var lockFooter: LocalizedStringKey {
        if pinEnabled {
            return "Your passcode unlocks Aperture. Face ID is a faster shortcut to the same lock — you can always fall back to passcode."
        } else if biometricAvailable {
            return "Without a passcode, your wallet is only protected by your iPhone's lock screen. Turn on a passcode to require authentication every time you open Aperture — and to use Face ID."
        } else {
            return "Without a passcode, your wallet is only protected by your iPhone's lock screen. Turn on a passcode to require authentication every time you open Aperture."
        }
    }

    // MARK: - Erase Data section

    /// iOS-style "Erase Data" — auto-wipe after repeated wrong passcodes.
    /// Destructive accent; arming it routes through a confirmation. The
    /// threshold (`PinCodeStorage.eraseDataThreshold` = 10) is named in the
    /// footer; keep the two in sync if the constant ever changes.
    private var eraseDataSection: some View {
        Section {
            UniToggle(isOn: Binding(
                get: { eraseDataEnabled },
                set: { newValue in
                    if newValue {
                        isShowingEraseDataConfirm = true // confirm before arming
                    } else {
                        eraseDataEnabled = false
                    }
                }
            )) {
                Text("Erase Data")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Feedback.Error.foreground)
            }
            .tint(UniColors.Feedback.Error.foreground)
            .padding(.vertical, UniSpacing.xxs)
            .listRowBackground(UniColors.List.rowBackground)
        } footer: {
            Text("Erase all wallets and data on this iPhone after 10 failed passcode attempts. A wallet you backed up can be restored from its recovery phrase — one you didn't is gone for good.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @MainActor
    private func tryEnableBiometric() async {
        let outcome = await BiometricService().authenticate(
            reason: LocalizedStringResource("Enable Face ID for Aperture.")
        )
        if case .success = outcome {
            setBiometricEnabled(true)
            BiometricEnrollmentTracker.captureSnapshot(in: modelContext.container)
        } else {
            setBiometricEnabled(false)
        }
    }

    private func setBiometricEnabled(_ enabled: Bool) {
        biometricEnabled = enabled
        requireForSend = enabled
    }

    private func syncBiometricActionTogglesWithMaster() {
        guard pinEnabled, biometricEnabled else {
            requireForSend = false
            return
        }
    }
}

// MARK: - Shared row primitive

/// Same shape as `SettingsView`'s private `SettingsRow` but lifted to
/// internal so the new section views can reuse without duplicating.
struct SettingsRowShared: View {
    let systemImage: String
    let title: LocalizedStringKey
    let trailing: LocalizedStringKey?
    var iconTint: Color = .blue

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            SettingsIconTile(systemImage: systemImage, tint: iconTint)
                .accessibilityHidden(true)
            Text(title)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(UniTypography.subheadline)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, UniSpacing.xxs)
    }
}

// MARK: - Auto-lock picker

struct AutoLockPickerView: View {
    @AppStorage(AutoLockPreference.storageKey) private var raw: Int = AutoLockPreference.defaultValue

    var body: some View {
        List {
            Section {
                ForEach(AutoLockPreference.Option.allCases) { option in
                    Button {
                        raw = option.rawValue
                    } label: {
                        HStack {
                            Text(LocalizedStringKey(option.label))
                                .font(UniTypography.body)
                                .foregroundStyle(UniColors.Text.primary)
                            Spacer()
                            if raw == option.rawValue {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(UniColors.Icon.accent)
                            }
                        }
                        .padding(.vertical, UniSpacing.xxs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(UniColors.List.rowBackground)
                }
            } footer: {
                Text("Aperture locks when this much time has passed in the background. Re-opening requires PIN or Face ID.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Auto-lock"))
        .navigationBarTitleDisplayMode(.large)
        .uniHaptic(.selection, trigger: raw)
    }
}

// MARK: - PIN change / disable flows

/// Three-step flat state machine: verify current PIN → set new PIN
/// → confirm new PIN. Mirrors `PinSetupFlow`'s shape but with the
/// verify gate up front. Per Rule #17 + M-004 (no nested
/// NavigationStack — flat state machine).
struct PinChangeFlow: View {
    let onFinish: () -> Void

    private enum Step: Equatable {
        case verify
        case setNew
        case confirmNew(expected: String)
    }
    @State private var step: Step = .verify
    @State private var inlineError: String?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .verify:
                    PinCodeView(
                        mode: .verify,
                        onComplete: { _ in
                            step = .setNew
                        },
                        onCancel: { onFinish() },
                        showsNavigationControls: false
                    )
                case .setNew:
                    PinCodeView(
                        mode: .set,
                        onComplete: { newPin in
                            step = .confirmNew(expected: newPin)
                        },
                        onCancel: { onFinish() },
                        showsNavigationControls: false
                    )
                case .confirmNew(let expected):
                    PinCodeView(
                        mode: .confirm(expected: expected),
                        onComplete: { newPin in
                            _ = PinCodeStorage.setPin(newPin)
                            onFinish()
                        },
                        onCancel: { onFinish() },
                        onConfirmMismatch: {
                            step = .setNew
                        },
                        showsNavigationControls: false
                    )
                }
            }
            .transition(.opacity)
            .toolbar {
                // Leading toolbar affordance depends on the step
                // (per the user's 2026-06-06 direction). Step 1
                // (verify current passcode) is the entry surface —
                // close × cancels the whole change attempt. Steps
                // 2–3 are intra-flow navigation — back ← pops to
                // the previous step.
                ToolbarItem(placement: .topBarLeading) {
                    switch step {
                    case .verify:
                        Button { onFinish() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .accessibilityLabel(Text("Cancel"))
                    case .setNew:
                        Button { step = .verify } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .accessibilityLabel(Text("Back"))
                    case .confirmNew:
                        Button { step = .setNew } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .accessibilityLabel(Text("Back"))
                    }
                }
            }
        }
    }
}

struct PinDisableVerifyFlow: View {
    let onSuccess: () -> Void
    let onCancel: () -> Void

    var body: some View {
        // Wrap in NavigationStack so the close affordance lives in
        // a native toolbar slot. Disable-passcode is a single-step
        // verify — close × cancels and returns to Security settings.
        NavigationStack {
            PinCodeView(
                mode: .verify,
                onComplete: { _ in onSuccess() },
                onCancel: { onCancel() },
                showsNavigationControls: false
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onCancel() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel(Text("Cancel"))
                }
            }
        }
    }
}
