import SwiftUI

/// Settings → Security. Single surface for all device-side
/// authentication: PIN enable/change/disable, biometric toggle,
/// auto-lock duration, backup-pending shortcut, and reset-import-
/// warnings hatch.
struct SecuritySettingsView: View {
    @GRDBStorage("pinEnabled") private var pinEnabled: Bool = false
    @GRDBStorage("biometricEnabled") private var biometricEnabled: Bool = false
    // Per-action biometric gate (2026-06-20). Secure default ON; only takes
    // effect when biometrics are enabled. Enforced in SendReviewView.
    @GRDBStorage(PinCodePreference.requireBiometricForSendKey) private var requireForSend: Bool = true
    @GRDBStorage(PinCodePreference.forgotPasscodeResetEnabledKey) private var forgotPasscodeResetEnabled: Bool = false
    @GRDBStorage(PinCodePreference.forgotPasscodeResetEducationSeenKey) private var forgotPasscodeResetEducationSeen: Bool = false
    // iOS-style "Erase Data": wipe the app after N failed lock-screen passcode
    // attempts. OFF by default; arming it shows a confirmation first. Enforced
    // in `AppLockView` against `PinCodeStorage`'s dedicated unlock counter.
    @GRDBStorage("eraseDataAfterFailedAttempts") private var eraseDataEnabled: Bool = false
    @GRDBStorage(AutoLockPreference.storageKey) private var autoLockRaw: Int = AutoLockPreference.defaultValue

    @State private var isShowingPinSetup: Bool = false
    @State private var isShowingPinChangeVerify: Bool = false
    @State private var isShowingPinChange: Bool = false
    @State private var isShowingDisableVerify: Bool = false
    @State private var biometricAvailable: Bool = false
    @State private var biometryType: BiometricService.BiometryType = .none
    /// Confirms ARMING "Erase Data" — a destructive auto-wipe, so it's never
    /// turned on by a single stray tap. Turning it OFF needs no confirm.
    @State private var isShowingEraseDataConfirm: Bool = false
    /// First-enable education for the lock-screen forgot-passcode reset hatch.
    /// The toggle remains off until the user explicitly enables it from the
    /// sheet.
    @State private var isShowingForgotPasscodeResetExplanation: Bool = false

    var body: some View {
        content
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Security"))
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            refreshBiometryState()
            syncBiometricActionTogglesWithMaster()
        }
    }

    private var content: some View {
        List {
            // LOCK — passcode + the current device biometric, if available.
            // The biometric row is hidden when iOS reports no enrolled
            // biometric policy, and its name/icon follow the hardware.
            Section {
                if !pinEnabled {
                    pinRow // "Turn Passcode On"
                }
                if biometricAvailable {
                    // Disabled (greyed, non-interactive) until a passcode
                    // exists — biometrics need the passcode as fallback.
                    biometricRow
                        .disabled(!pinEnabled)
                        .opacity(pinEnabled ? 1 : 0.5)
                }
            } header: {
                Text("Lock").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
            } footer: {
                Text(verbatim: lockFooter)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // "Use <biometry> For:" — iOS register. Shown whenever the
            // current device has enrolled biometrics; rows are greyed until
            // the master toggle is on.
            if biometricAvailable {
                Section {
                    biometricActionRow("Sending transactions", isOn: $requireForSend)
                } header: {
                    Text(verbatim: "Use \(biometryType.displayName) For").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
                } footer: {
                    Text(verbatim: "Require \(biometryType.displayName) before each of these actions. If it fails, you can fall back to your passcode.")
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
                        .uniListRowHitTarget()
                    }
                    .buttonStyle(.uniListRow)
                    .listRowBackground(UniColors.List.rowBackground)

                    Button {
                        isShowingPinChangeVerify = true
                    } label: {
                        HStack {
                            Text("Change Passcode")
                                .font(UniTypography.body)
                                .foregroundStyle(UniColors.Button.text)
                            Spacer()
                        }
                        .padding(.vertical, UniSpacing.xxs)
                        .uniListRowHitTarget()
                    }
                    .buttonStyle(.uniListRow)
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
                forgotPasscodeResetSection
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
        .alert(Text("Enable lock-screen reset?"), isPresented: $isShowingForgotPasscodeResetExplanation) {
            Button("Not now", role: .cancel) {
                isShowingForgotPasscodeResetExplanation = false
            }
            Button("Enable Reset", role: .destructive) {
                forgotPasscodeResetEducationSeen = true
                forgotPasscodeResetEnabled = true
                isShowingForgotPasscodeResetExplanation = false
            }
        } message: {
            Text(verbatim: forgotPasscodeResetAlertMessage)
        }
        // navigationTitle / navigationBarTitleDisplayMode /
        // background / onAppear are attached to the outer view above.
        // The per-action covers (PinSetup / PinChange /
        // PinDisableVerify) stay here because they're only reachable
        // once the user is already looking at this list.
        .fullScreenCover(isPresented: $isShowingPinSetup) {
            // Re-uses the canonical PIN setup flow per Rule #17.
            // On finish, pinEnabled has been written by PinSetupFlow's
            // internal handler.
            PinSetupFlow(
                onFinish: {
                    isShowingPinSetup = false
                },
                onBack:   { isShowingPinSetup = false }
            )
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingPinChangeVerify) {
            PinChangeVerifyFlow(
                onSuccess: {
                    isShowingPinChangeVerify = false
                    DispatchQueue.main.async {
                        isShowingPinChange = true
                    }
                },
                onCancel: { isShowingPinChangeVerify = false }
            )
            .uniAppEnvironment()
            .uniSheetDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
        .fullScreenCover(isPresented: $isShowingPinChange) {
            PinChangeFlow(
                onFinish: { isShowingPinChange = false }
            )
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingDisableVerify) {
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
            .uniSheetDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
    }

    // MARK: - Rows

    /// iOS passcode register: a single blue "Turn Passcode On"
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
            .uniListRowHitTarget()
        }
        .buttonStyle(.uniListRow)
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
                Image(systemName: biometryType.systemImageName)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(UniColors.Icon.secondary)
                    .frame(width: 28, alignment: .center)
                    .accessibilityHidden(true)
                Text(verbatim: biometryType.displayName)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
            }
        }
        .tint(UniColors.Button.Primary.tint)
        .padding(.vertical, UniSpacing.xxs)
        .listRowBackground(UniColors.List.rowBackground)
    }

    /// A per-action biometric toggle. Disabled (greyed) until biometrics are
    /// on, matching iOS's "Use <biometry> For" rows.
    private func biometricActionRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
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
    /// no passcode is set, that biometrics need one first.
    private var lockFooter: String {
        if pinEnabled {
            if biometricAvailable {
                return "Your passcode unlocks Aperture. \(biometryType.displayName) is a faster shortcut to the same lock — you can always fall back to passcode."
            } else {
                return "Your passcode unlocks Aperture and protects this iPhone's copy of your wallets."
            }
        } else if biometricAvailable {
            return "Without a passcode, your wallet is only protected by your iPhone's lock screen. Turn on a passcode to require authentication every time you open Aperture — and to use \(biometryType.displayName)."
        } else {
            return "Without a passcode, your wallet is only protected by your iPhone's lock screen. Turn on a passcode to require authentication every time you open Aperture."
        }
    }

    // MARK: - Erase Data section

    /// Optional lock-screen recovery hatch. Off by default: if enabled, anyone
    /// holding this unlocked iPhone can erase Aperture from the forgot-passcode
    /// sheet. It never reveals secrets, but it does remove local wallet access.
    private var forgotPasscodeResetSection: some View {
        Section {
            UniToggle(isOn: Binding(
                get: { forgotPasscodeResetEnabled },
                set: { newValue in
                    if newValue {
                        if forgotPasscodeResetEducationSeen {
                            forgotPasscodeResetEnabled = true
                        } else {
                            isShowingForgotPasscodeResetExplanation = true
                        }
                    } else {
                        forgotPasscodeResetEnabled = false
                    }
                }
            )) {
                Text("Reset from Forgot Passcode")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
            }
            .tint(UniColors.Button.Primary.tint)
            .padding(.vertical, UniSpacing.xxs)
            .listRowBackground(UniColors.List.rowBackground)
        } header: {
            Text("Recovery").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
        } footer: {
            Text("When enabled, the forgot-passcode sheet can erase Aperture from this iPhone. Use this only if every wallet is backed up, because local wallets, recovery phrases, passcodes, and app data are removed.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

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
        let service = BiometricService()
        let outcome = await service.authenticate(reason: service.biometryType.enableReason)
        if case .success = outcome {
            setBiometricEnabled(true)
            BiometricEnrollmentTracker.captureSnapshot(database: AppDatabase.shared)
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

    private func refreshBiometryState() {
        let service = BiometricService()
        biometricAvailable = service.isAvailable
        biometryType = service.biometryType
        if !service.isAvailable {
            setBiometricEnabled(false)
        }
    }

    private var resetSecurityItemName: String {
        biometricAvailable ? "\(biometryType.displayName) setting" : "security settings"
    }

    private var forgotPasscodeResetAlertMessage: String {
        """
        This adds a Reset Aperture option to the forgot-passcode sheet.

        It can help if you forget your passcode and have your recovery phrase backed up. Resetting erases every local wallet, recovery phrase, passcode, \(resetSecurityItemName), and app cache from this iPhone.

        Only enable this if you understand that someone holding your unlocked iPhone could erase Aperture from the passcode screen. They cannot see your funds, but you would need your recovery phrase to restore access.
        """
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
        .uniListRowHitTarget()
    }
}

// MARK: - Auto-lock picker

struct AutoLockPickerView: View {
    @GRDBStorage(AutoLockPreference.storageKey) private var raw: Int = AutoLockPreference.defaultValue

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
                        .uniListRowHitTarget()
                    }
                    .buttonStyle(.uniListRow)
                    .listRowBackground(UniColors.List.rowBackground)
                }
            } footer: {
                Text("Aperture locks when this much time has passed in the background. Re-opening requires authentication.")
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

/// Current-passcode verification before the full-screen change flow. This
/// is a verify gate, so it presents as a dismissible sheet like every other
/// in-flow passcode authorization.
struct PinChangeVerifyFlow: View {
    let onSuccess: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            PinCodeView(
                mode: .verify,
                onComplete: { _ in onSuccess() },
                onCancel: { onCancel() },
                showsNavigationControls: false,
                accessContext: .changePasscode
            )
        }
    }
}

/// Two-step full-screen state machine: set new PIN → confirm new PIN.
/// Current-PIN verification happens in `PinChangeVerifyFlow` first so only
/// passcode creation and confirmation occupy a full-screen surface.
struct PinChangeFlow: View {
    let onFinish: () -> Void

    private enum Step: Equatable {
        case setNew
        case confirmNew(expected: String)
    }
    @State private var step: Step = .setNew
    @State private var inlineError: String?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
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
                // (set new passcode) is the entry surface — close × cancels
                // the whole change attempt. Confirm is intra-flow navigation
                // — back ← pops to the previous step.
                ToolbarItem(placement: .topBarLeading) {
                    switch step {
                    case .setNew:
                        Button { onFinish() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .accessibilityLabel(Text("Cancel"))
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
        // Wrap in NavigationStack so the unified passcode surface keeps the
        // same navigation environment as the other sheet-hosted verify gates.
        // The sheet itself owns dismissal through the native swipe-down gesture.
        NavigationStack {
            PinCodeView(
                mode: .verify,
                onComplete: { _ in onSuccess() },
                onCancel: { onCancel() },
                showsNavigationControls: false,
                accessContext: .turnOffPasscode
            )
        }
    }
}
