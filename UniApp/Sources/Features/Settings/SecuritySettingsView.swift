import SwiftUI
import SwiftData

/// Settings → Security. Single surface for all device-side
/// authentication: PIN enable/change/disable, biometric toggle,
/// auto-lock duration, backup-pending shortcut, and reset-import-
/// warnings hatch.
struct SecuritySettingsView: View {
    @AppStorage("pinEnabled") private var pinEnabled: Bool = false
    @AppStorage("biometricEnabled") private var biometricEnabled: Bool = false
    @AppStorage(AutoLockPreference.storageKey) private var autoLockRaw: Int = AutoLockPreference.defaultValue
    @AppStorage("hideImportKeyWarning") private var hideImportKeyWarning: Bool = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var isShowingPinSetup: Bool = false
    @State private var isShowingPinChange: Bool = false
    @State private var isShowingDisableVerify: Bool = false
    @State private var biometricAvailable: Bool = false

    /// Per the user's 2026-06-06 direction: entering Settings →
    /// Security itself must be gated behind passcode (and Face ID
    /// when enabled), the same way Apple gates Settings → Touch ID
    /// & Passcode. `isUnlocked` is `false` on first appear; the
    /// fullScreenCover below shows `PinCodeView(.verify)` which
    /// auto-fires biometric (per the `.task` modifier added to
    /// `PinCodeView`). On successful verify we flip the flag and
    /// dismiss the cover, revealing the real settings list. If
    /// the user cancels the verify, the navigation pops back to
    /// the Settings root.
    @State private var isUnlocked: Bool = false

    var body: some View {
        Group {
            if isUnlocked || !PinCodeStorage.hasPin {
                content
            } else {
                // Empty backdrop while gating — the actual settings
                // list is hidden behind the fullScreenCover. Using
                // `Color.clear` rather than the list so a quick
                // glance at the screen below the cover doesn't
                // briefly leak the toggles before auth.
                Color(uiColor: .systemBackground).ignoresSafeArea()
            }
        }
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Security"))
        .navigationBarTitleDisplayMode(.large)
        .onAppear { biometricAvailable = BiometricService().isAvailable }
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
                    }
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
            if pinEnabled {
                // When the passcode is set up, the row that used to
                // surface "Passcode: On •••" is gone (per the user's
                // 2026-06-06 direction — the Menu-with-ellipsis was
                // off-pattern for iOS settings). Change + Disable are
                // each their own section now, with the Face ID toggle
                // grouped under the existing Lock section above them.
                Section {
                    if biometricAvailable {
                        biometricRow
                    }
                } header: {
                    Text("Lock").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
                } footer: {
                    Text(pinFooter)
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section {
                    Button {
                        isShowingPinChange = true
                    } label: {
                        SettingsRowShared(
                            systemImage: "pencil",
                            title: "Change passcode",
                            trailing: nil
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(UniColors.Background.secondary)
                }

                Section {
                    Button {
                        isShowingDisableVerify = true
                    } label: {
                        HStack(spacing: UniSpacing.s) {
                            Image(systemName: "lock.open")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(UniColors.Status.errorForeground)
                                .frame(width: 28, alignment: .center)
                                .accessibilityHidden(true)
                            Text("Disable passcode")
                                .font(UniTypography.body)
                                .foregroundStyle(UniColors.Status.errorForeground)
                            Spacer()
                        }
                        .padding(.vertical, UniSpacing.xxs)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(UniColors.Background.secondary)
                } footer: {
                    Text("Disabling the passcode removes the lock from this iPhone's copy of your wallets. Your seed and mnemonic stay encrypted in Keychain — but anyone with this phone unlocked will be able to open Aperture without proving they own it.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Section {
                    pinRow
                } header: {
                    Text("Lock").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
                } footer: {
                    Text(pinFooter)
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if pinEnabled {
                Section {
                    NavigationLink(value: SettingsDestination.autoLock) {
                        SettingsRowShared(
                            systemImage: "lock.rotation",
                            title: "Auto-lock",
                            trailing: LocalizedStringKey(AutoLockPreference.option(for: autoLockRaw).label)
                        )
                    }
                    .listRowBackground(UniColors.Background.secondary)
                } header: {
                    Text("Timing").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
                }
            }

            if hideImportKeyWarning {
                Section {
                    Button {
                        hideImportKeyWarning = false
                    } label: {
                        SettingsRowShared(
                            systemImage: "arrow.counterclockwise",
                            title: "Reset import warnings",
                            trailing: nil
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(UniColors.Background.secondary)
                } footer: {
                    Text("Re-enables the security warning that appears before you import a recovery phrase or private key.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // navigationTitle / navigationBarTitleDisplayMode /
        // background / onAppear / Security-gate fullScreenCover are
        // all attached to the outer Group above. The per-action
        // covers (PinSetup / PinChange / PinDisableVerify) stay
        // here because they're only reachable once the user is
        // unlocked and looking at this list.
        .fullScreenCover(isPresented: $isShowingPinSetup) {
            // Re-uses the canonical PIN setup flow per Rule #17.
            // On finish, pinEnabled has been written by PinSetupFlow's
            // internal handler; we just dismiss.
            PinSetupFlow(
                onFinish: { isShowingPinSetup = false },
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
                    biometricEnabled = false
                    isShowingDisableVerify = false
                },
                onCancel: { isShowingDisableVerify = false }
            )
            .uniAppEnvironment()
            .presentationBackground(UniColors.Background.primary)
        }
    }

    // MARK: - Rows

    private var pinRow: some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: "lock")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
            Text("Passcode")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
            Spacer()
            if pinEnabled {
                Menu {
                    Button {
                        isShowingPinChange = true
                    } label: {
                        Label("Change passcode", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        isShowingDisableVerify = true
                    } label: {
                        Label("Disable passcode", systemImage: "lock.open")
                    }
                } label: {
                    HStack(spacing: UniSpacing.xxs) {
                        Text("On")
                            .font(UniTypography.subheadlineEmphasized)
                            .foregroundStyle(UniColors.Status.successForeground)
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(UniColors.Icon.tertiary)
                    }
                }
            } else {
                Button {
                    isShowingPinSetup = true
                } label: {
                    Text("Set up")
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(UniColors.Tint.accent)
                }
            }
        }
        .padding(.vertical, UniSpacing.xxs)
        .listRowBackground(UniColors.Background.secondary)
    }

    private var biometricRow: some View {
        UniToggle(isOn: Binding(
            get: { biometricEnabled },
            set: { newValue in
                if newValue {
                    Task { await tryEnableBiometric() }
                } else {
                    biometricEnabled = false
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
        .tint(UniColors.Button.primaryTint)
        .padding(.vertical, UniSpacing.xxs)
        .listRowBackground(UniColors.Background.secondary)
    }

    private var pinFooter: LocalizedStringKey {
        if pinEnabled {
            return "Your passcode unlocks Aperture. Face ID is a faster shortcut to the same lock — you can always fall back to passcode."
        } else {
            return "Without a passcode, your wallet is only protected by your iPhone's lock screen. Set one to require authentication every time you open Aperture."
        }
    }

    @MainActor
    private func tryEnableBiometric() async {
        let outcome = await BiometricService().authenticate(
            reason: LocalizedStringResource("Enable Face ID for Aperture.")
        )
        if case .success = outcome {
            biometricEnabled = true
            BiometricEnrollmentTracker.captureSnapshot(in: modelContext.container)
        } else {
            biometricEnabled = false
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

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .frame(width: 28, alignment: .center)
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
                    .listRowBackground(UniColors.Background.secondary)
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
                        onCancel: { onFinish() }
                    )
                case .setNew:
                    PinCodeView(
                        mode: .set,
                        onComplete: { newPin in
                            step = .confirmNew(expected: newPin)
                        },
                        onCancel: { onFinish() }
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
                        }
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
                onCancel: { onCancel() }
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
