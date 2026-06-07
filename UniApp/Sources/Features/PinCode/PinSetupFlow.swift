import SwiftUI

/// First-time PIN setup coordinator, pushed onto the create-wallet
/// `NavigationStack` after `BackupVerifyView` succeeds (or after the user
/// skips backup, per the user's 2026-06-04 direction that both paths land
/// at the PIN offer).
///
/// **Intent (one sentence):** invite the user to set a PIN — honestly, and
/// without locking them out if they decline.
///
/// **Sequence (Rule #17 §E).**
/// 1. `.set` step — `PinCodeView(mode: .set)`. User picks 6 digits.
/// 2. `.confirm` step — `PinCodeView(mode: .confirm(expected: setPin))`.
///    On match, save via `PinCodeStorage.setPin(_:)` + set
///    `pinEnabled = true`, advance to the biometric prompt.
/// 3. `.biometricPrompt` step — invite the user to enable Face ID / Touch
///    ID. **Skipped entirely** if `BiometricService.isAvailable == false`.
/// 4. The view calls `onFinish()`. The parent flow pushes `WalletReadyView`.
///
/// **No nested `NavigationStack`.** This view is itself pushed onto the
/// parent recovery-phrase stack; the steps advance via internal `@State`
/// + `withAnimation`, not via push. Nesting `NavigationStack` inside
/// `NavigationStack` was the root cause of the 2026-06-04 "opens a
/// screen, then navigates me back" bug: iOS treats the inner stack's
/// pushes as parent-stack pops in some cases, popping the user out of
/// the entire flow. This file's prior implementation had that bug; the
/// flat state-machine is the fix.
///
/// **Skip path.** A "Skip" affordance lives in the trailing toolbar from
/// the moment the user lands. Tapping presents `PinSkipWarningSheet`,
/// which names the consequence and offers "Set a passcode" / "Skip anyway".
struct PinSetupFlow: View {

    /// Fires when the flow resolves — either by completing PIN + biometric
    /// (with whatever combination of `pinEnabled` / `biometricEnabled`
    /// state the user chose), or by skipping with the warning sheet
    /// confirmation. The caller pushes `WalletReadyView`.
    let onFinish: () -> Void

    /// Fires when the user taps the leading back chevron on the `.set`
    /// step. The caller pops the parent `NavigationStack` so the user
    /// returns to the previous step in the create-wallet flow
    /// (typically `BackupVerifyView`, or `RecoveryPhraseView` if the
    /// user reached PIN setup via the skip-backup path). Replaces the
    /// prior `onAbandon` callback which routed through a separate
    /// "stop creating this wallet" warning sheet — per user direction
    /// 2026-06-05, every step in the create-wallet flow should offer
    /// straightforward back navigation instead.
    let onBack: () -> Void

    // MARK: - State

    /// Linear step machine. No nested `NavigationStack` — the steps just
    /// swap content via `withAnimation`.
    enum Step: Hashable {
        case set
        case confirm
        case biometricPrompt
    }

    @State private var step: Step = .set

    /// The PIN entered on the `.set` step, captured here so the `.confirm`
    /// step can pass it back as the `expected` value. Cleared on completion
    /// so it doesn't linger in memory longer than necessary.
    @State private var pendingSetPin: String = ""

    @State private var isShowingSkipWarning: Bool = false

    /// Direction flag for the step transition. `false` = forward push
    /// (incoming from trailing, outgoing to leading — iOS NavigationStack
    /// push). `true` = backward pop (incoming from leading, outgoing to
    /// trailing — iOS NavigationStack pop). Set immediately before any
    /// `withAnimation { step = ... }` change and reset shortly after.
    /// See `revertToSet()` and `commitPin()` for the two callers.
    @State private var isReversing: Bool = false

    @AppStorage(PinCodePreference.pinEnabledKey)
    private var pinEnabled: Bool = PinCodePreference.defaultValue

    @AppStorage(PinCodePreference.biometricEnabledKey)
    private var biometricEnabled: Bool = PinCodePreference.defaultValue

    @State private var biometricService = BiometricService()

    // MARK: - Body

    var body: some View {
        ZStack {
            UniColors.Background.primary.ignoresSafeArea()

            // Single content slot — switched by `step`, animated with an
            // iOS-native step transition: incoming view slides from the
            // trailing edge, outgoing view slides to the leading edge.
            // Matches `NavigationStack` push visually, without the
            // nested-stack anti-pattern (see MISTAKES.md M-004). The
            // `.move(edge:)` API honors `layoutDirection`, so in an RTL
            // app the slide direction naturally flips — matches iOS's
            // native push direction in every locale.
            Group {
                switch step {
                case .set:
                    PinCodeView(
                        mode: .set,
                        onComplete: { pin in
                            pendingSetPin = pin
                            withAnimation(stepAnimation) {
                                step = .confirm
                            }
                        },
                        onCancel: {
                            isShowingSkipWarning = true
                        }
                    )
                    .transition(stepTransition)

                case .confirm:
                    PinCodeView(
                        mode: .confirm(expected: pendingSetPin),
                        onComplete: { _ in
                            commitPin()
                        },
                        onCancel: {
                            isShowingSkipWarning = true
                        },
                        onConfirmMismatch: {
                            // User direction 2026-06-05: on mismatch,
                            // send the user back to .set so they can
                            // pick a fresh PIN. Retrying on confirm
                            // against an unknown expected value is a
                            // dead-end — the prior pin is the only
                            // truth and we shouldn't make them guess it.
                            revertToSet()
                        }
                    )
                    .transition(stepTransition)

                case .biometricPrompt:
                    BiometricPromptStep(
                        biometryType: biometricService.biometryType,
                        onEnable: {
                            Task { @MainActor in
                                await enableBiometric()
                            }
                        },
                        onSkip: {
                            // Don't set `biometricEnabled = true` — leave
                            // the default `false`. Advance.
                            finishSuccessfully()
                        }
                    )
                    .transition(stepTransition)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar { toolbar }
        .sheet(isPresented: $isShowingSkipWarning) {
            PinSkipWarningSheet(
                onSetPin: {
                    isShowingSkipWarning = false
                },
                onSkipAnyway: {
                    isShowingSkipWarning = false
                    // User chose no PIN — clear any half-written state +
                    // ensure the flag is honest.
                    PinCodeStorage.clear()
                    pinEnabled = false
                    biometricEnabled = false
                    onFinish()
                }
            )
            .uniAppEnvironment()
            .intrinsicHeightSheet()
            .presentationBackground(UniColors.Background.primary)
        }
    }

    // MARK: - Step transition

    /// Directional iOS-native transition. Forward push (default):
    /// incoming from trailing, outgoing to leading — matches
    /// `NavigationStack.push`. Reverse pop: incoming from leading,
    /// outgoing to trailing — matches `NavigationStack.pop`. The
    /// direction is determined by `isReversing` at the moment SwiftUI
    /// evaluates the transition (i.e. inside the `withAnimation` block).
    /// Both fade slightly through the move so the swap reads as a single
    /// motion.
    private var stepTransition: AnyTransition {
        if isReversing {
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        } else {
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        }
    }

    /// Matches iOS NavigationStack push timing — slightly longer than
    /// the prior 0.25s cross-fade because a real slide reads better at
    /// ~0.35s, especially with the spring deceleration curve. Apple's
    /// own push uses ~0.4s.
    private var stepAnimation: Animation {
        .spring(response: 0.35, dampingFraction: 0.85)
    }

    /// Revert to the `.set` step. Used by (a) the user tapping the back
    /// chevron on the confirm step's toolbar, and (b) `PinCodeView`
    /// reporting a confirm mismatch via `onConfirmMismatch`. Both paths
    /// clear the pending PIN so the user starts fresh on `.set`.
    private func revertToSet() {
        isReversing = true
        pendingSetPin = ""
        withAnimation(stepAnimation) {
            step = .set
        }
        // Reset the direction flag after the animation completes so the
        // next forward advance uses the forward transition again. The
        // delay matches the spring's settle time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            isReversing = false
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Leading slot — back chevron for both `.set` and `.confirm`.
        // - `.set`: pops the parent NavigationStack via `onBack`,
        //   returning to the previous step in the create-wallet flow
        //   (BackupVerifyView or RecoveryPhraseView).
        // - `.confirm`: reverts the internal state machine to `.set`
        //   via `revertToSet()` — the user re-enters their PIN from
        //   scratch (the prior `pendingSetPin` is discarded).
        // - `.biometricPrompt`: no leading toolbar item — the PIN is
        //   already committed; the body's "Not now" CTA is the only
        //   correct skip affordance.
        // Bare SF Symbols per M-002/M-003; `chevron.backward`
        // auto-mirrors in RTL.
        ToolbarItem(placement: .topBarLeading) {
            if step == .set {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel(Text("Back"))
            } else if step == .confirm {
                Button {
                    revertToSet()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel(Text("Back"))
            }
            // .biometricPrompt: no leading toolbar item.
        }
        // Trailing "Skip" — present the skip-PIN warning sheet on the
        // .set and .confirm steps (PIN isn't saved yet there; skipping
        // means "no PIN"). On `.biometricPrompt`, the PIN is already
        // committed — "Skip" here means "no Face ID", which is what the
        // body's "Not now" CTA already handles. Surfacing the
        // PIN-skip-warning sheet again at that point was the
        // 2026-06-05 bug: it asked the user to set a PIN they had
        // already just set. So hide this trailing button on the
        // biometric step.
        if step != .biometricPrompt {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingSkipWarning = true
                } label: {
                    Text("Skip")
                }
            }
        }
    }

    // MARK: - PIN commit

    /// Confirmation succeeded. Persist the PIN, flip the flag, and either
    /// route to the biometric prompt or finish directly (no biometry
    /// available on this device).
    private func commitPin() {
        let success = PinCodeStorage.setPin(pendingSetPin)
        pendingSetPin = "" // never linger
        guard success else {
            // Keychain write failed — extremely rare (only when the device
            // can't unlock its own keychain). Honest fallback: don't claim
            // the PIN is set; route the user to finish without PIN.
            pinEnabled = false
            onFinish()
            return
        }
        pinEnabled = true

        if biometricService.isAvailable {
            withAnimation(stepAnimation) {
                step = .biometricPrompt
            }
        } else {
            // Device has no biometry — skip the prompt entirely per the
            // user's 2026-06-04 direction. Don't show a "Face ID not
            // available" message; just advance to WalletReadyView.
            finishSuccessfully()
        }
    }

    /// Invokes the real biometric prompt. On `.success`, set
    /// `biometricEnabled = true` and finish. On any failure (user
    /// cancelled, unavailable, system error), leave the flag `false` and
    /// finish anyway — the user can enable it later in Settings.
    private func enableBiometric() async {
        let result = await biometricService.authenticate(
            reason: "Unlock Aperture with Face ID."
        )
        if case .success = result {
            biometricEnabled = true
        } else {
            biometricEnabled = false
        }
        finishSuccessfully()
    }

    private func finishSuccessfully() {
        onFinish()
    }
}

// MARK: - Biometric prompt step

/// "Enable Face ID" screen — Rule #17 §E step 3.
///
/// One hero icon, two sentences, two buttons. Restraint per Rule #16 §B:
/// brand-graphite SF Symbol, no alarming red, no marketing. The body
/// names the protection mechanism (Rule #16 §A.2) and the user's role in
/// it (Rule #16 §A.3).
private struct BiometricPromptStep: View {
    let biometryType: BiometricService.BiometryType
    let onEnable: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: UniSpacing.l) {
            Spacer()
            hero
            copyBlock
            Spacer()
        }
        .padding(.horizontal, UniSpacing.l)
        .safeAreaInset(edge: .bottom) {
            actionRegion
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hero: some View {
        Image(systemName: heroSymbol)
            .font(.system(size: 72, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(UniColors.Brand.mark)
            .accessibilityHidden(true)
    }

    private var heroSymbol: String {
        switch biometryType {
        case .faceID:  return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .none:    return "lock.shield"
        }
    }

    private var copyBlock: some View {
        VStack(spacing: UniSpacing.s) {
            UniLargeTitle(text: titleKey, alignment: .center)
            UniBody(
                text: "Unlock Aperture and confirm transactions with a glance — without typing your PIN every time.",
                alignment: .center,
                color: UniColors.Text.secondary
            )
        }
    }

    private var titleKey: LocalizedStringKey {
        switch biometryType {
        case .faceID:  return "Enable Face ID"
        case .touchID: return "Enable Touch ID"
        case .opticID: return "Enable Optic ID"
        case .none:    return "Enable biometrics"
        }
    }

    private var actionRegion: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            VStack(spacing: UniSpacing.s) {
                UniButton(title: enableTitleKey, variant: .primary) {
                    onEnable()
                }
                UniButton(title: "Not now", variant: .secondary) {
                    onSkip()
                }
            }
        }
    }

    private var enableTitleKey: LocalizedStringKey {
        switch biometryType {
        case .faceID:  return "Enable Face ID"
        case .touchID: return "Enable Touch ID"
        case .opticID: return "Enable Optic ID"
        case .none:    return "Enable biometrics"
        }
    }
}

// MARK: - Previews

#Preview("Light") {
    NavigationStack {
        PinSetupFlow(onFinish: {}, onBack: {})
    }
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    NavigationStack {
        PinSetupFlow(onFinish: {}, onBack: {})
    }
    .preferredColorScheme(.dark)
}
