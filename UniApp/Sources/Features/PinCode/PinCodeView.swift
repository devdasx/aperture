import SwiftUI

/// The canonical PIN entry component per `CLAUDE.md` Rule #17 §A.
///
/// **One UI, three modes.**
/// - `.set` — fresh user picking a 6-digit PIN. On 6 digits, `onComplete(pin)`.
/// - `.confirm(expected:)` — user re-enters the PIN they just chose. On match,
///   `onComplete(pin)`; on mismatch, the dots shake + clear, a transient
///   footnote names the error, the user tries again.
/// - `.verify` — user unlocks an existing PIN. The view calls
///   `PinCodeStorage.verify(pin)` itself; on match, `onComplete("")`
///   (the storage layer holds the hash, not the plaintext); on mismatch,
///   the dots shake + clear, a transient footnote. Failed attempts are
///   recorded in Keychain and an escalating lockout (1 s doubling to a
///   16-minute cap from the fifth failure) disables the keypad with a
///   countdown under the dots — brute-force protection that survives
///   app kill. No wipe: the recovery path is the recovery phrase.
///
/// **Design rationale (Rule #17 §H).** Every PIN entry in the app — first
/// setup, unlock, transaction confirmation, Settings change — uses this
/// one view. Users recognize the screen across contexts. Same dots, same
/// keypad geometry, same biometric-fallback position. That muscle memory
/// is itself a security property: a phishing surface that looks "almost
/// right" reads as wrong.
///
/// **Custom keypad, not `keyboardType(.numberPad)`.** The system number pad
/// retains digit buffers and is inappropriate for PIN entry (Rule #17 §A).
/// We build the 12-button grid ourselves with native `Button`s in a
/// `LazyVGrid` — bare digits, no chrome on each key beyond a circular
/// `UniColors.Background.secondary` fill.
struct PinCodeView: View {

    // MARK: - Public surface

    enum Mode: Equatable {
        case set
        case confirm(expected: String)
        case verify
    }

    let mode: Mode
    /// Fires with the PIN the user entered (or empty string for `.verify`
    /// mode, since storage holds the hash, not the plaintext).
    let onComplete: (String) -> Void
    /// Fires when the user taps the leading Cancel / X button.
    let onCancel: () -> Void
    /// Optional. For `.verify` mode, presents a "Forgot PIN?" affordance
    /// at the bottom of the keypad. Tapping invokes this closure.
    var onForgotPin: (() -> Void)? = nil
    /// Optional. For `.confirm` mode, fires after a mismatch has been
    /// shown to the user (shake + inline error + brief pause). The parent
    /// is expected to revert to the `.set` step so the user re-enters
    /// from scratch — per user direction 2026-06-05, a confirm mismatch
    /// should not leave the user stuck on the confirm screen retrying
    /// against an unknown expected value; they should be sent back to
    /// pick a fresh PIN.
    var onConfirmMismatch: (() -> Void)? = nil

    // MARK: - State

    /// Current digit buffer. Only modified by the keypad — never by parent
    /// state. Always 0...6 digits, all `0`–`9`.
    @State private var digits: String = ""

    /// Animation hook for the dot row. Bumped when the user enters a
    /// mismatching PIN; drives the shake animation.
    @State private var shakeTrigger: Int = 0

    /// Transient inline-error state. `nil` when there's no error; non-nil
    /// after a `.confirm` mismatch or a `.verify` mismatch; cleared as
    /// soon as the user types again.
    @State private var inlineError: InlineError? = nil

    /// Haptic trigger — bumped on every digit keypress (soft impact per
    /// Rule #10) and on every error event (error haptic).
    @State private var keypressTrigger: Int = 0
    @State private var errorTrigger: Int = 0

    /// Cached biometric service. Single instance per view so `biometryType`
    /// and `isAvailable` are resolved once, not on every body evaluation.
    @State private var biometricService = BiometricService()

    /// Pending dot-clear (and confirm-mismatch callback) scheduled by
    /// `failWith(_:)`. Stored so `.onDisappear` can cancel it — a
    /// fire-and-forget delay outliving the view would mutate state and
    /// invoke parent callbacks after the screen is gone.
    @State private var clearTask: Task<Void, Never>? = nil

    /// In-flight manual biometric authentication started by the keypad's
    /// biometric key. Stored so `.onDisappear` can cancel it and the
    /// completion callback never fires after the view has gone away.
    @State private var biometricTask: Task<Void, Never>? = nil

    /// In-flight PBKDF2 verification for `.verify` mode (the derivation
    /// runs off the main thread). Stored so `.onDisappear` can cancel it.
    @State private var verifyTask: Task<Void, Never>? = nil

    /// Countdown driver for the brute-force lockout — sleeps in 1-second
    /// beats until the persisted lockout window expires, then re-enables
    /// the keypad. Stored so `.onDisappear` can cancel it.
    @State private var lockoutTask: Task<Void, Never>? = nil

    /// Seconds remaining in the active brute-force lockout window.
    /// `0` means input is allowed. Mirrors
    /// `PinCodeStorage.lockoutRemaining()` — the Keychain record is the
    /// source of truth; this is the UI-facing copy the countdown updates.
    @State private var lockoutRemaining: TimeInterval = 0

    // MARK: - Body

    var body: some View {
        VStack(spacing: UniSpacing.l) {
            // Header (title + body copy) follows the AMBIENT app
            // locale per the Rule #17 §I refinement (2026-06-06 user
            // feedback Image #51): "Set a passcode" / "Confirm your
            // passcode" / "Enter your passcode" and their body copy
            // are read-once descriptive text that benefits from
            // translation — not muscle memory. The keypad below is
            // what carries the universal-passcode-gesture guarantee.
            header
            // Keypad-subtree group: dots + keypad + forgot row are
            // forced LTR + English so dots fill L→R, keypad geometry
            // stays 1-2-3 / 4-5-6 / 7-8-9 in every locale, digit
            // glyphs render as ASCII 0–9 (not Arabic-Indic), and
            // "Forgot your passcode?" matches the keypad's English
            // muscle-memory register (the forgot tap leaves the
            // keypad context into a translated sheet).
            VStack(spacing: UniSpacing.l) {
                dotRow
                lockoutRow
                Spacer(minLength: 0)
                keypad
                    .disabled(isLockedOut)
                    .opacity(isLockedOut ? 0.4 : 1)
                    .animation(.easeInOut(duration: 0.2), value: isLockedOut)
                inlineErrorRow
                forgotRow
            }
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.locale, Locale(identifier: "en"))
        }
        .padding(.horizontal, UniSpacing.l)
        .padding(.vertical, UniSpacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .uniHaptic(.contextualImpact(.tap), trigger: keypressTrigger)
        .uniHaptic(.error, trigger: errorTrigger)
        .task {
            guard case .verify = mode else { return }
            // Restore any persisted brute-force lockout before anything
            // else — the Keychain record survives app kill, so a user
            // who force-quits mid-lockout lands back in the countdown,
            // not on a fresh keypad.
            refreshLockout()
            // Auto-fire Face ID / Touch ID on `.verify` entry when
            // the user has biometrics enabled. Matches iOS's own
            // pattern (Settings → Touch ID & Passcode prompts Face
            // ID immediately rather than waiting for an icon tap).
            // Runs once per view instance via SwiftUI's `.task`
            // lifecycle — exactly the right cadence here. The user
            // can still abort and type the passcode manually if the
            // biometric prompt fails or the user dismisses it.
            // Skipped during an active lockout — matching iOS's own
            // passcode-lockout behavior, no input path stays open.
            guard !isLockedOut,
                  biometricService.isAvailable,
                  PinCodePreference.isBiometricEnabled()
            else { return }
            let result = await biometricService.authenticate(
                reason: "Unlock Aperture with Face ID."
            )
            guard !Task.isCancelled else { return }
            if case .success = result {
                onComplete("")
            }
        }
        .onDisappear {
            clearTask?.cancel()
            biometricTask?.cancel()
            verifyTask?.cancel()
            lockoutTask?.cancel()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: UniSpacing.s) {
            UniLargeTitle(text: titleKey, alignment: .center)
            UniBody(
                text: bodyKey,
                alignment: .center,
                color: UniColors.Text.secondary
            )
        }
        .padding(.top, UniSpacing.l)
    }

    private var titleKey: LocalizedStringKey {
        switch mode {
        case .set:     return "Set a passcode"
        case .confirm: return "Confirm your passcode"
        case .verify:  return "Enter your passcode"
        }
    }

    private var bodyKey: LocalizedStringKey {
        switch mode {
        case .set:
            return "Choose a 6-digit passcode. You'll use it to unlock Aperture and confirm transactions."
        case .confirm:
            return "Enter the same passcode again."
        case .verify:
            return "Enter your passcode to continue."
        }
    }

    // MARK: - Dot row

    /// Six dots, filled count = `digits.count`. Animates a horizontal
    /// shake on mismatch. The shake amplitude is small (8 pt) — enough
    /// to register without feeling alarming.
    private var dotRow: some View {
        HStack(spacing: UniSpacing.s) {
            ForEach(0..<6, id: \.self) { index in
                Circle()
                    .fill(
                        index < digits.count
                            ? UniColors.Brand.mark
                            : UniColors.Fill.tertiary
                    )
                    .frame(width: 16, height: 16)
            }
        }
        .modifier(ShakeEffect(animatableData: CGFloat(shakeTrigger)))
        .animation(.spring(response: 0.3, dampingFraction: 0.4), value: shakeTrigger)
    }

    // MARK: - Brute-force lockout

    private var isLockedOut: Bool {
        lockoutRemaining > 0
    }

    /// Countdown line under the dots, shown in `.verify` mode while an
    /// escalating brute-force delay is active. Reserves a fixed-height
    /// slot (like `inlineErrorRow`) so the keypad doesn't jump when the
    /// lockout engages or expires. `.set` / `.confirm` modes render
    /// nothing — their layout is unchanged.
    @ViewBuilder
    private var lockoutRow: some View {
        if mode == .verify {
            Group {
                if isLockedOut {
                    UniFootnote(
                        text: "Try again in \(lockoutCountdown)",
                        alignment: .center,
                        color: UniColors.Text.secondary
                    )
                } else {
                    UniFootnote(text: " ", alignment: .center)
                }
            }
            .frame(height: 20)
        }
    }

    /// Localized remaining-time string, e.g. "16 min" / "4 sec" /
    /// "1 min, 30 sec" — native `Duration` formatting, no hand-rolled
    /// time math (Rule #3).
    private var lockoutCountdown: String {
        let seconds = Int(max(1, lockoutRemaining.rounded(.up)))
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.minutes, .seconds], width: .abbreviated)
        )
    }

    /// Re-read the persisted lockout window and, when one is active,
    /// drive a once-per-second countdown by sleeping until the next
    /// beat (a `.task`-style sleeping loop — deliberately NOT a `Timer`,
    /// which would keep firing detached from the view lifecycle). The
    /// loop re-reads `PinCodeStorage.lockoutRemaining()` on every beat
    /// so the Keychain record stays the single source of truth.
    private func refreshLockout() {
        lockoutTask?.cancel()
        let remaining = PinCodeStorage.lockoutRemaining()
        lockoutRemaining = remaining
        guard remaining > 0 else { return }
        lockoutTask = Task {
            while !Task.isCancelled {
                let left = PinCodeStorage.lockoutRemaining()
                lockoutRemaining = left
                guard left > 0 else { return }
                try? await Task.sleep(for: .seconds(min(left, 1)))
                if Task.isCancelled { return }
            }
        }
    }

    // MARK: - Keypad

    /// 12 buttons in a 3-column `LazyVGrid` — digits 1–9 across rows 1–3,
    /// then biometric / 0 / delete on row 4.
    ///
    /// **Liquid Glass (Rule #2 §B).** The ten digit keys live inside one
    /// `GlassEffectContainer` so their circular glass shapes participate
    /// in one shared material — touches reflect light across neighboring
    /// keys (Rule #2 §B.2 — "the materiality is the affordance"). The
    /// container's spacing matches the grid spacing so the system handles
    /// edge merging cleanly when keys are close enough to share material.
    private var keypad: some View {
        GlassEffectContainer(spacing: UniSpacing.m) {
            LazyVGrid(columns: keypadColumns, spacing: UniSpacing.m) {
                ForEach(1...9, id: \.self) { digit in
                    digitKey(String(digit))
                }
                biometricKey
                digitKey("0")
                deleteKey
            }
            .frame(maxWidth: 340) // tightens the keypad on wide screens; sized for 88pt keys + 16pt gaps
        }
    }

    private var keypadColumns: [GridItem] {
        let spacing = UniSpacing.m
        return [
            GridItem(.flexible(), spacing: spacing),
            GridItem(.flexible(), spacing: spacing),
            GridItem(.flexible(), spacing: spacing)
        ]
    }

    /// iOS phone-keypad letter mapping. Standard since the 1948 rotary dial
    /// re-mapped to push-button: 2→ABC, 3→DEF, 4→GHI, 5→JKL, 6→MNO, 7→PQRS,
    /// 8→TUV, 9→WXYZ. 1 and 0 carry no letters (per Apple's lock-screen
    /// passcode keypad — the Phone app uses "+" on 0 instead; we follow the
    /// lock-screen convention because this *is* a PIN entry, not a dialer).
    /// Letters are not localized — they are the ITU-T E.161 mnemonic
    /// mapping used worldwide, including in RTL UIs (Apple's Arabic
    /// keypad on iOS shows the same Latin letters underneath).
    private func letters(for digit: String) -> String {
        switch digit {
        case "2": return "ABC"
        case "3": return "DEF"
        case "4": return "GHI"
        case "5": return "JKL"
        case "6": return "MNO"
        case "7": return "PQRS"
        case "8": return "TUV"
        case "9": return "WXYZ"
        default:  return ""   // "1" and "0"
        }
    }

    @ViewBuilder
    private func digitKey(_ digit: String) -> some View {
        let letterRow = letters(for: digit)
        Button {
            handleDigitTap(digit)
        } label: {
            VStack(spacing: 2) {
                Text(verbatim: digit)
                    .font(.system(size: 36, weight: .regular, design: .default))
                    .foregroundStyle(UniColors.Text.primary)
                if letterRow.isEmpty {
                    // Reserved space so 1 and 0 don't shift their digit
                    // upward relative to keys with letters — preserves
                    // the grid's vertical rhythm.
                    Text(verbatim: " ")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(2)
                        .opacity(0)
                } else {
                    Text(verbatim: letterRow)
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(UniColors.Text.secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 88, height: 88)
            .glassEffect(.regular.interactive(), in: .circle)
            // Hit-test fix (2026-06-08, same root cause as Rule #19's
            // UniButton fix): `.glassEffect(_:in: .circle)` paints a
            // circle that fills the 88×88 frame, but `Button` with
            // `.plain` style hit-tests the VStack's intrinsic bounds
            // — the digit glyph and letter row. Taps in the corners
            // of the circle fell through. `.contentShape(Circle())`
            // brings the tap region back in line with the painted
            // material. Apple's `.glassEffect(_:in:)` API takes the
            // shape parameter for the visual *and* the interactive
            // boundary; SwiftUI's `Button` does not infer the second
            // one — we declare it explicitly.
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: digit))
    }

    /// Bottom-left key. Renders the biometric trigger when (a) we're in
    /// `.verify` mode, (b) the device supports biometrics, and (c) the
    /// user previously enabled biometrics. Otherwise renders an empty
    /// placeholder so the grid stays 3×4.
    @ViewBuilder
    private var biometricKey: some View {
        if shouldShowBiometricKey {
            Button {
                handleBiometricTap()
            } label: {
                Image(systemName: biometricSymbol)
                    .font(.system(size: 32, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(UniColors.Brand.mark)
                    .frame(width: 88, height: 88)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(biometricAccessibilityKey))
        } else {
            // Empty placeholder — same dimensions so the grid math stays.
            Color.clear.frame(width: 88, height: 88)
        }
    }

    @ViewBuilder
    private var deleteKey: some View {
        Button {
            handleDeleteTap()
        } label: {
            Image(systemName: "delete.left")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(UniColors.Text.primary)
                .frame(width: 88, height: 88)
        }
        .buttonStyle(.plain)
        .disabled(digits.isEmpty)
        .opacity(digits.isEmpty ? 0.4 : 1)
        .accessibilityLabel(Text("Delete last digit"))
    }

    // MARK: - Inline error

    /// Renders the transient mismatch / incorrect-PIN footnote. Reserves a
    /// fixed-height slot so the keypad doesn't jump up/down as the error
    /// appears and disappears.
    private var inlineErrorRow: some View {
        Group {
            if let error = inlineError {
                UniFootnote(
                    text: error.localizedKey,
                    alignment: .center,
                    color: UniColors.Status.errorForeground
                )
            } else {
                UniFootnote(text: " ", alignment: .center)
            }
        }
        .frame(height: 20)
    }

    // MARK: - Forgot row

    @ViewBuilder
    private var forgotRow: some View {
        if mode == .verify, let onForgotPin {
            Button {
                onForgotPin()
            } label: {
                Text("Forgot PIN?")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
            .buttonStyle(.plain)
        } else {
            // Reserve consistent footer height — empty when absent so the
            // dots/keypad don't shift between modes.
            Color.clear.frame(height: 20)
        }
    }

    // MARK: - Biometric symbol resolution

    private var shouldShowBiometricKey: Bool {
        guard case .verify = mode else { return false }
        guard biometricService.isAvailable else { return false }
        return PinCodePreference.isBiometricEnabled()
    }

    private var biometricSymbol: String {
        switch biometricService.biometryType {
        case .faceID:  return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .none:    return "lock.shield"
        }
    }

    private var biometricAccessibilityKey: LocalizedStringKey {
        switch biometricService.biometryType {
        case .faceID:  return "Use Face ID"
        case .touchID: return "Use Touch ID"
        case .opticID: return "Use Optic ID"
        case .none:    return "Use biometrics"
        }
    }

    // MARK: - Input handling

    private func handleDigitTap(_ digit: String) {
        // Defense in depth — the keypad is `.disabled` during a lockout,
        // but a tap racing the lockout's engagement must not slip
        // through into `evaluate()`.
        guard !isLockedOut else { return }
        guard digits.count < 6 else { return }
        // Clear any prior error as soon as the user touches the keypad.
        inlineError = nil
        digits.append(digit)
        keypressTrigger &+= 1
        if digits.count == 6 {
            evaluate()
        }
    }

    private func handleDeleteTap() {
        guard !digits.isEmpty else { return }
        inlineError = nil
        digits.removeLast()
        keypressTrigger &+= 1
    }

    /// Tapping the biometric trigger invokes `BiometricService.authenticate`.
    /// On success, `onComplete("")` — same contract as a passing `.verify`.
    /// On failure, the dots stay where they are; the user can still type
    /// their PIN.
    ///
    /// The task handle is stored in `biometricTask` and cancelled in
    /// `.onDisappear`; the post-`await` cancellation guard ensures
    /// `onComplete` never fires into a parent after this view is gone.
    private func handleBiometricTap() {
        biometricTask?.cancel()
        biometricTask = Task {
            let result = await biometricService.authenticate(
                reason: "Unlock Aperture with Face ID."
            )
            guard !Task.isCancelled else { return }
            if case .success = result {
                onComplete("")
            }
        }
    }

    // MARK: - Mode evaluation

    private func evaluate() {
        switch mode {
        case .set:
            // Caller decides what "set complete" means — typically pushing
            // the confirm step. We don't clear digits here; the parent
            // navigates away.
            onComplete(digits)
        case .confirm(let expected):
            if digits == expected {
                onComplete(digits)
            } else {
                failWith(.mismatch)
            }
        case .verify:
            verifyPin()
        }
    }

    /// `.verify`-mode evaluation with brute-force rate limiting.
    ///
    /// - The escalating lockout (`PinCodeStorage.lockoutRemaining()`) is
    ///   consulted before the attempt; an active window rejects the
    ///   entry without burning PBKDF2 cycles.
    /// - The 100k-iteration derivation runs off the main thread via the
    ///   async `PinCodeStorage.verify(_:)` — the keypad stays responsive.
    /// - Wrong PIN → `recordFailure()` persists the incremented count +
    ///   timestamp to Keychain; success → `clearFailures()`.
    private func verifyPin() {
        guard PinCodeStorage.lockoutRemaining() <= 0 else {
            // Keypad is disabled during lockout; this guard covers any
            // race between expiry and a queued sixth digit.
            digits = ""
            refreshLockout()
            return
        }
        let candidate = digits
        verifyTask?.cancel()
        verifyTask = Task {
            let isValid = await PinCodeStorage.verify(candidate)
            guard !Task.isCancelled else { return }
            if isValid {
                PinCodeStorage.clearFailures()
                onComplete("")
            } else {
                PinCodeStorage.recordFailure()
                failWith(.incorrect)
                refreshLockout()
            }
        }
    }

    /// Common failure path: bump the shake animation, fire the error
    /// haptic, show the inline footnote, and clear the digits after a
    /// short delay so the user sees what was wrong.
    ///
    /// **Confirm-mode special case:** after the shake + clear, if the
    /// parent provided `onConfirmMismatch`, we fire it to send the user
    /// back to the `.set` step. Per user direction 2026-06-05, retrying
    /// on the confirm screen against an unknown expected value is a
    /// dead-end — the user must be allowed to pick a fresh PIN. The
    /// extra delay (0.9s total) gives them time to read the "Those
    /// don't match" footnote before the screen slides back.
    private func failWith(_ error: InlineError) {
        inlineError = error
        errorTrigger &+= 1
        shakeTrigger &+= 1
        // Brief pause so the user perceives the shake before the dots
        // empty — clearing immediately would make the shake invisible.
        // Tracked task (not `DispatchQueue.asyncAfter`) so `.onDisappear`
        // can cancel it — the dispatch version would mutate state and
        // call `onConfirmMismatch` into a parent after the view is gone.
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            digits = ""
            if case .confirm = mode, let onConfirmMismatch {
                try? await Task.sleep(for: .seconds(0.4))
                guard !Task.isCancelled else { return }
                onConfirmMismatch()
            }
        }
    }

    // MARK: - Types

    /// Inline error messages keyed off the catalog. We keep the enum
    /// internal rather than expose `String` so the catalog source stays
    /// authoritative.
    private enum InlineError: Equatable {
        case mismatch
        case incorrect

        var localizedKey: LocalizedStringKey {
            switch self {
            case .mismatch:  return "Those don't match. Try again."
            case .incorrect: return "Incorrect PIN."
            }
        }
    }
}

// MARK: - Shake effect

/// Geometric shake effect — translates the host view horizontally in a
/// damped sinusoid driven by `animatableData`. Small amplitude (8 pt)
/// keeps the motion polite. Rule #2 §A.4 (motion serves meaning, not
/// decoration): the shake says "those digits are wrong" — one beat, no
/// more.
private struct ShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        let amplitude: CGFloat = 8
        let phase = animatableData * .pi * 4
        let x = sin(phase) * amplitude
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

// MARK: - Previews

#Preview("Set — Light") {
    PinCodeView(mode: .set, onComplete: { _ in }, onCancel: {})
        .preferredColorScheme(.light)
}

#Preview("Confirm — Dark") {
    PinCodeView(
        mode: .confirm(expected: "123456"),
        onComplete: { _ in },
        onCancel: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Verify — Light") {
    PinCodeView(
        mode: .verify,
        onComplete: { _ in },
        onCancel: {},
        onForgotPin: {}
    )
    .preferredColorScheme(.light)
}
