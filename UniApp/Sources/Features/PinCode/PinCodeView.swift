import SwiftUI
import UIKit

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
///   16-minute cap from the fifth failure) disables input with a
///   countdown under the dots — brute-force protection that survives
///   app kill. No wipe: the recovery path is the recovery phrase.
///   `.verify` is Face ID-first by default; callers that must be
///   passcode-only (Security gate, wallet removal, Reset Aperture —
///   user direction 2026-06-13) pass `allowsBiometrics: false`.
///
/// **Design rationale (Rule #17 §H).** Every PIN entry in the app — first
/// setup, unlock, transaction confirmation, Settings change — uses this
/// one view. Users recognize the screen across contexts. Same dots, same
/// native numeric keyboard. That muscle memory is itself a security property:
/// a phishing surface that looks "almost right" reads as wrong.
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
    /// from the options button. Tapping invokes this closure.
    var onForgotPin: (() -> Void)? = nil
    /// Optional. For `.verify` mode, fires after each FAILED attempt (the
    /// wrong-PIN path, after the failure is recorded). The app-unlock gate
    /// uses it to drive the optional "Erase Data" wipe; other gates leave it
    /// nil. It carries no count — the caller owns its own attempt policy.
    var onFailedAttempt: (() -> Void)? = nil
    /// Optional. For `.confirm` mode, fires after a mismatch has been
    /// shown to the user (shake + inline error + brief pause). The parent
    /// is expected to revert to the `.set` step so the user re-enters
    /// from scratch — per user direction 2026-06-05, a confirm mismatch
    /// should not leave the user stuck on the confirm screen retrying
    /// against an unknown expected value; they should be sent back to
    /// pick a fresh PIN.
    var onConfirmMismatch: (() -> Void)? = nil
    /// Biometric policy for `.verify` mode. Default `true` — every
    /// pre-existing call site keeps the Face ID-first behavior
    /// unchanged (auto-prompt on entry).
    ///
    /// `false` makes the verify **passcode-only**: the `.task`
    /// auto-prompt never fires, even when the device supports biometrics
    /// and the user has them enabled. The Forgot affordance is unaffected.
    ///
    /// Per user direction 2026-06-13, the passcode-only gates are:
    /// the Settings → Security entry gate, wallet removal, and Reset
    /// Aperture. Face ID-first remains the policy everywhere else
    /// (app unlock, secret reveals, transaction signing).
    ///
    /// Ignored in `.set` / `.confirm` modes — they never offer
    /// biometrics regardless. This stays the ONE PIN surface per
    /// Rule #17; policy is a parameter, never a second component.
    var allowsBiometrics: Bool = true

    /// Optional, `.verify` only. When non-nil AND it returns a value, the
    /// wrong-passcode line reads "Wrong passcode. N attempts remaining."
    /// instead of the bare "Wrong passcode." The app-unlock screen passes the
    /// count down from its optional Erase-Data wipe (`AppLockView` → `Pin-
    /// CodeStorage.eraseDataThreshold − unlockFailureCount()`); other gates
    /// leave it nil and show no counter. Read AFTER each failed attempt so the
    /// freshly-incremented count is reflected.
    var attemptsRemaining: (() -> Int?)? = nil

    /// When true, the view installs the optional native navigation-bar
    /// options menu. Dismissal belongs to the presenter / native app bar, so
    /// this component does not add its own close button.
    var showsNavigationControls: Bool = true

    // MARK: - State

    /// Current digit buffer. Only modified by the native numeric keyboard —
    /// never by parent state. Always 0...6 digits, all `0`–`9`.
    @State private var digits: String = ""

    /// Animation hook for the dot row. Bumped when the user enters a
    /// mismatching PIN; drives the shake animation.
    @State private var shakeTrigger: Int = 0

    /// Transient inline-error state. `nil` when there's no error; non-nil
    /// after a `.confirm` mismatch or a `.verify` mismatch; cleared as
    /// soon as the user types again.
    @State private var inlineError: InlineError? = nil

    /// Haptic trigger for error events. Digit entry relies on the native
    /// keyboard's own feedback; adding a second app-level haptic on every
    /// keypress makes fast PIN entry heavier and can produce CoreAudio noise.
    @State private var errorTrigger: Int = 0

    /// Cached biometric service. Single instance per view so `biometryType`
    /// and `isAvailable` are resolved once, not on every body evaluation.
    @State private var biometricService = BiometricService()

    /// Pending dot-clear (and confirm-mismatch callback) scheduled by
    /// `failWith(_:)`. Stored so `.onDisappear` can cancel it — a
    /// fire-and-forget delay outliving the view would mutate state and
    /// invoke parent callbacks after the screen is gone.
    @State private var clearTask: Task<Void, Never>? = nil

    /// In-flight PBKDF2 verification for `.verify` mode (the derivation
    /// runs off the main thread). Stored so `.onDisappear` can cancel it.
    @State private var verifyTask: Task<Void, Never>? = nil

    /// Countdown driver for the brute-force lockout — sleeps in 1-second
    /// beats until the persisted lockout window expires, then re-enables
    /// keyboard input. Stored so `.onDisappear` can cancel it.
    @State private var lockoutTask: Task<Void, Never>? = nil

    /// Seconds remaining in the active brute-force lockout window.
    /// `0` means input is allowed. Mirrors
    /// `PinCodeStorage.lockoutRemaining()` — the Keychain record is the
    /// source of truth; this is the UI-facing copy the countdown updates.
    @State private var lockoutRemaining: TimeInterval = 0

    /// Remaining-attempts count captured on a failed verify when the caller
    /// supplied `attemptsRemaining`. `nil` → the wrong line shows no counter.
    @State private var attemptsLeft: Int?

    /// Brief green success fill on the dots before `onComplete` fires — the
    /// handoff's `.dots.ok` state. Cleared on teardown.
    @State private var didSucceed: Bool = false

    /// Tracked task for the keyboard-dismiss → complete hop; cancelled on
    /// `.onDisappear` so `onComplete` never fires into a gone parent.
    @State private var completionTask: Task<Void, Never>?
    @State private var focusTask: Task<Void, Never>?
    @State private var biometricTask: Task<Void, Never>?
    @State private var isBiometricPromptActive: Bool = false
    @State private var isCompleting: Bool = false
    @State private var isVerifyingPin: Bool = false

    /// Monotonic focus request for the hidden UIKit text field that owns the
    /// real iOS number keyboard. Incrementing this asks UIKit for first
    /// responder once; no FocusState loop is involved.
    @State private var keyboardFocusRequest: Int = 0

    /// Allows this screen to ask the hidden native field for focus. We request
    /// focus on entry and on explicit taps only; UIKit owns the keyboard after
    /// that. Continuously forcing first responder makes the keyboard fight
    /// UIKit and is the source of visible input lag.
    @State private var keyboardFocusAllowed: Bool = true

    // MARK: - Body

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                passcodePrompt
                Spacer(minLength: 0)
            }

            nativeInputField
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { navigationControlsToolbar }
        .safeAreaInset(edge: .bottom) { biometricFallbackButton }
        .scrollDismissesKeyboard(.never)
        .contentShape(Rectangle())
        .onTapGesture { focusNativeKeyboard() }
        .uniHaptic(.error, trigger: errorTrigger)
        .onAppear { keyboardFocusAllowed = true }
        .task {
            guard case .verify = mode else {
                focusNativeKeyboard(after: .milliseconds(220))
                return
            }
            // Restore any persisted brute-force lockout before anything
            // else — the Keychain record survives app kill, so a user
            // who force-quits mid-lockout lands back in the countdown.
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
            // Skipped entirely when the caller declared this verify
            // passcode-only (`allowsBiometrics: false` — Security
            // gate / wallet removal / Reset, user direction
            // 2026-06-13).
            guard allowsBiometrics,
                  !isLockedOut,
                  biometricService.isAvailable,
                  PinCodePreference.isBiometricEnabled()
            else {
                focusNativeKeyboard(after: .milliseconds(220))
                return
            }
            await requestBiometricUnlock()
        }
        .onChange(of: lockoutRemaining) { _, remaining in
            if remaining > 0 {
                focusTask?.cancel()
            } else {
                focusNativeKeyboard(after: .milliseconds(220))
            }
        }
        .onDisappear {
            keyboardFocusAllowed = false
            focusTask?.cancel()
            biometricTask?.cancel()
            clearTask?.cancel()
            verifyTask?.cancel()
            lockoutTask?.cancel()
            completionTask?.cancel()
        }
    }

    // MARK: - Title + options

    /// Centered title + secure dots. The title follows the app locale; the
    /// dots/status stay LTR so passcode progress always reads left-to-right.
    private var passcodePrompt: some View {
        VStack(spacing: 0) {
            titleView
                .padding(.horizontal, 20)

            VStack(spacing: 0) {
                dotRow
                    .padding(.top, 22)
                    .padding(.vertical, 5)
                statusLine
                    .padding(.top, 6)
                    .padding(.horizontal, 20)
            }
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.locale, Locale(identifier: "en"))
        }
        .padding(.bottom, 24)
    }

    private var nativeInputField: some View {
        PasscodeNativeInputField(
            text: nativeDigitsBinding,
            isEnabled: canFocusNativeKeyboard,
            focusRequest: keyboardFocusRequest
        )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var biometricFallbackButton: some View {
        if shouldOfferBiometricUnlock {
            UniButton(
                title: biometricActionTitle,
                variant: .secondary,
                systemImage: biometricSymbol,
                isLoading: isBiometricPromptActive,
                isEnabled: !isBiometricPromptActive
            ) {
                startBiometricUnlock()
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ToolbarContentBuilder
    private var navigationControlsToolbar: some ToolbarContent {
        if showsNavigationControls {
            if mode == .verify, onForgotPin != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            UniHapticEngine.shared.play(.contextualImpact(.whisper))
                            onForgotPin?()
                        } label: {
                            Label("Forgot passcode?", systemImage: "questionmark.circle")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel(Text("Options"))
                }
            }
        }
    }

    /// Handoff title — centered, no subtitle, no lock icon.
    private var titleView: some View {
        Text(titleKey)
            .font(.system(size: 23, weight: .regular))
            .foregroundStyle(UniColors.Text.primary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var titleKey: LocalizedStringKey {
        switch mode {
        case .set:     return "Create Passcode"
        case .confirm: return "Confirm Passcode"
        case .verify:  return "Enter Passcode"
        }
    }

    // MARK: - Dot row

    /// Six dots, filled count = `digits.count`. Each dot is a native SF
    /// Symbol — `circle` when empty, `circle.fill` when typed — so the
    /// empty→filled change rides Apple's own symbol-replace animation
    /// (`.contentTransition(.symbolEffect(.replace))`). A `.regular` weight
    /// reads lighter than the old 2pt drawn ring. A horizontal shake plays on
    /// a wrong attempt (9pt — enough to register without feeling alarming).
    private var dotRow: some View {
        HStack(spacing: 20) {
            ForEach(0..<6, id: \.self) { index in
                let filled = index < digits.count
                Image(systemName: filled ? "circle.fill" : "circle")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(filled ? dotFillColor : dotRingColor)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .modifier(ShakeEffect(animatableData: CGFloat(shakeTrigger)))
        .animation(.spring(response: 0.3, dampingFraction: 0.4), value: shakeTrigger)
        .animation(.snappy(duration: 0.22), value: digits.count)
        .animation(.easeOut(duration: 0.18), value: didSucceed)
    }

    /// `true` while six wrong digits are still on screen — drives the red dots
    /// during the shake. Clears the instant the digits empty (retry) so the
    /// dots return to their normal gray rings even though the message lingers.
    private var dotsErrored: Bool { inlineError != nil && digits.count == 6 }

    /// Fill for a filled dot: ink normally, danger during a wrong attempt,
    /// green on the brief success flash (handoff `.dots` / `.err` / `.ok`).
    private var dotFillColor: Color {
        if didSucceed { return UniColors.PinLock.positive }
        if dotsErrored { return UniColors.PinLock.danger }
        return UniColors.Text.primary
    }

    /// Empty-dot tint: `dotEmpty` gray, danger during a wrong attempt.
    private var dotRingColor: Color {
        dotsErrored ? UniColors.PinLock.danger : UniColors.PinLock.dotEmpty
    }

    // MARK: - Brute-force lockout

    private var isLockedOut: Bool {
        lockoutRemaining > 0
    }

    private var canRequestNativeKeyboardFocus: Bool {
        UIApplication.shared.applicationState == .active
    }

    private var canFocusNativeKeyboard: Bool {
        keyboardFocusAllowed
            && !isCompleting
            && !isVerifyingPin
            && !isBiometricPromptActive
            && !isLockedOut
            && canRequestNativeKeyboardFocus
    }

    private var shouldOfferBiometricUnlock: Bool {
        guard allowsBiometrics else { return false }
        guard case .verify = mode else { return false }
        guard !isLockedOut else { return false }
        guard biometricService.isAvailable else { return false }
        return PinCodePreference.isBiometricEnabled()
    }

    private var biometricSymbol: String {
        switch biometricService.biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .none: return "lock.shield"
        }
    }

    private var biometricActionTitle: LocalizedStringKey {
        switch biometricService.biometryType {
        case .faceID: return "Use Face ID"
        case .touchID: return "Use Touch ID"
        case .opticID: return "Use Optic ID"
        case .none: return "Use biometrics"
        }
    }

    /// The single status line under the dots (handoff `.errtx`, height 20).
    /// One fixed-height slot so the prompt never jumps: it shows the active
    /// brute-force countdown (secondary), the wrong-passcode line with its
    /// live attempts counter (danger), or nothing.
    @ViewBuilder
    private var statusLine: some View {
        Group {
            if mode == .verify, isLockedOut {
                Text("Try again in \(lockoutCountdown)")
                    .foregroundStyle(UniColors.Text.secondary)
            } else if let error = inlineError {
                errorText(error)
                    .foregroundStyle(UniColors.PinLock.danger)
            } else {
                Text(verbatim: " ")
            }
        }
        .font(.system(size: 13.5, weight: .semibold))
        .multilineTextAlignment(.center)
        .frame(height: 20)
    }

    /// The wrong-passcode line. Appends the live "N attempts remaining" suffix
    /// when the caller (the app-unlock screen with Erase-Data armed) supplied
    /// a count via `attemptsRemaining`; otherwise the bare phrase. A confirm
    /// mismatch reads "Those don't match."
    private func errorText(_ error: InlineError) -> Text {
        switch error {
        case .mismatch:
            return Text("Those don’t match. Try again.")
        case .incorrect:
            guard let n = attemptsLeft else { return Text("Wrong passcode.") }
            let attempts = n == 1
                ? Text("1 attempt remaining")
                : Text("\(n) attempts remaining")
            return Text("Wrong passcode. \(attempts).")
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
        lockoutTask = Task { @MainActor in
            while !Task.isCancelled {
                let left = PinCodeStorage.lockoutRemaining()
                lockoutRemaining = left
                guard left > 0 else { return }
                try? await Task.sleep(for: .seconds(min(left, 1)))
                if Task.isCancelled { return }
            }
        }
    }

    // MARK: - Native keyboard input

    private var nativeDigitsBinding: Binding<String> {
        Binding(
            get: { digits },
            set: { applyNativeInput($0) }
        )
    }

    private func focusNativeKeyboard(after delay: Duration = .zero) {
        guard canFocusNativeKeyboard else { return }
        focusTask?.cancel()
        focusTask = Task { @MainActor in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            } else {
                await Task.yield()
            }
            guard canFocusNativeKeyboard else { return }
            keyboardFocusRequest &+= 1
        }
    }

    private func startBiometricUnlock() {
        UniHapticEngine.shared.play(.contextualImpact(.commit))
        biometricTask?.cancel()
        biometricTask = Task { @MainActor in
            await requestBiometricUnlock()
        }
    }

    @MainActor
    private func requestBiometricUnlock() async {
        guard shouldOfferBiometricUnlock else {
            focusNativeKeyboard(after: .milliseconds(180))
            return
        }
        guard !isBiometricPromptActive else { return }
        isBiometricPromptActive = true
        let result = await biometricService.authenticate(
            reason: "Unlock Aperture with Face ID."
        )
        guard !Task.isCancelled else {
            isBiometricPromptActive = false
            return
        }
        isBiometricPromptActive = false
        if case .success = result {
            completeAfterKeyboardDismiss("")
        } else {
            focusNativeKeyboard(after: .milliseconds(180))
        }
    }

    private func applyNativeInput(_ rawValue: String) {
        guard !isCompleting, !isVerifyingPin, !isLockedOut else { return }
        let next = Self.normalizedDigits(from: rawValue, limit: 6)
        guard next != digits else { return }
        inlineError = nil
        digits = next
        if digits.count == 6 {
            evaluate()
        }
    }

    private static func normalizedDigits(from rawValue: String, limit: Int) -> String {
        var output = ""
        output.reserveCapacity(limit)
        for character in rawValue {
            guard let value = character.wholeNumberValue else { continue }
            output.append(String(value))
            if output.count == limit { break }
        }
        return output
    }

    // MARK: - Mode evaluation

    private func evaluate() {
        switch mode {
        case .set:
            // Caller decides what "set complete" means — typically pushing
            // the confirm step.
            completeAfterKeyboardDismiss(digits)
        case .confirm(let expected):
            if digits == expected {
                flashSuccessThenComplete(digits)
            } else {
                failWith(.mismatch)
            }
        case .verify:
            verifyPin()
        }
    }

    /// Brief green dot flash (handoff `.dots.ok`) + success haptic, then hand
    /// off to the caller. Used on a correct passcode / confirm match; a
    /// biometric success skips it (no dots are involved). The hop is tracked
    /// so `onComplete` never fires into a parent after teardown.
    private func flashSuccessThenComplete(_ value: String) {
        completeAfterKeyboardDismiss(value, successFlash: true)
    }

    private func completeAfterKeyboardDismiss(_ value: String, successFlash: Bool = false) {
        guard !isCompleting else { return }
        isCompleting = true
        if successFlash {
            UniHapticEngine.shared.play(.success)
            withAnimation(.easeOut(duration: 0.14)) { didSucceed = true }
        }
        focusTask?.cancel()
        keyboardFocusAllowed = false
        KeyboardDismissal.dismiss()
        completionTask?.cancel()
        completionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(successFlash ? 220 : 180))
            guard !Task.isCancelled else { return }
            onComplete(value)
        }
    }

    /// `.verify`-mode evaluation with brute-force rate limiting.
    ///
    /// - The escalating lockout (`PinCodeStorage.lockoutRemaining()`) is
    ///   consulted before the attempt; an active window rejects the
    ///   entry without burning PBKDF2 cycles.
    /// - The 100k-iteration derivation runs off the main thread via the
    ///   async `PinCodeStorage.verify(_:)` — keyboard input stays responsive.
    /// - Wrong PIN → `recordFailure()` persists the incremented count +
    ///   timestamp to Keychain; success → `clearFailures()`.
    private func verifyPin() {
        guard PinCodeStorage.lockoutRemaining() <= 0 else {
            // Input is disabled during lockout; this guard covers any
            // race between expiry and a queued sixth digit.
            digits = ""
            refreshLockout()
            return
        }
        let candidate = digits
        isVerifyingPin = true
        focusTask?.cancel()
        verifyTask?.cancel()
        verifyTask = Task { @MainActor in
            let isValid = await PinCodeStorage.verify(candidate)
            guard !Task.isCancelled else {
                isVerifyingPin = false
                return
            }
            isVerifyingPin = false
            if isValid {
                PinCodeStorage.clearFailures()
                flashSuccessThenComplete("")
            } else {
                PinCodeStorage.recordFailure()
                // Notify the caller of a failed verify (app-unlock uses this
                // for the optional Erase-Data wipe). Fired BEFORE the shake so
                // an erase decision isn't delayed behind the clear animation.
                onFailedAttempt?()
                // Capture the live remaining-attempts count AFTER the caller
                // incremented it, so the wrong line reads the fresh value.
                attemptsLeft = attemptsRemaining?()
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
        clearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            digits = ""
            focusNativeKeyboard(after: .milliseconds(40))
            if case .confirm = mode, let onConfirmMismatch {
                try? await Task.sleep(for: .seconds(0.4))
                guard !Task.isCancelled else { return }
                onConfirmMismatch()
            }
        }
    }

    // MARK: - Types

    /// Which transient wrong-state the status line is showing. The copy lives
    /// in `errorText(_:)` so the wrong-passcode line can splice in the live
    /// "N attempts remaining" suffix.
    private enum InlineError: Equatable {
        case mismatch
        case incorrect
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
        let amplitude: CGFloat = 9
        let phase = animatableData * .pi * 4
        let x = sin(phase) * amplitude
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

// MARK: - Native passcode input

/// A hidden `UITextField` whose only job is to own the real iOS number
/// keyboard. This avoids the SwiftUI `FocusState` re-focus cycle that can
/// make the remote keyboard placeholder views fight their accessory/input
/// constraints while the lock overlay window is becoming key.
private struct PasscodeNativeInputField: UIViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    let focusRequest: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: .zero)
        field.delegate = context.coordinator
        field.keyboardType = .numberPad
        field.keyboardAppearance = .default
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.smartQuotesType = .no
        field.textContentType = nil
        field.inputAccessoryView = nil
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.textColor = .clear
        field.tintColor = .clear
        field.accessibilityElementsHidden = true
        field.isAccessibilityElement = false
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text

        if field.text != text {
            field.text = text
        }

        if field.isEnabled != isEnabled {
            field.isEnabled = isEnabled
        }

        guard isEnabled else {
            if field.isFirstResponder {
                field.resignFirstResponder()
            }
            return
        }

        guard context.coordinator.lastFocusRequest != focusRequest else { return }
        context.coordinator.lastFocusRequest = focusRequest

        DispatchQueue.main.async { [weak field] in
            guard let field, field.window != nil, field.isEnabled else { return }
            if !field.isFirstResponder {
                field.becomeFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ field: UITextField, coordinator: Coordinator) {
        field.removeTarget(coordinator, action: nil, for: .allEvents)
        field.delegate = nil
        if field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>
        var lastFocusRequest: Int = 0

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func editingChanged(_ sender: UITextField) {
            commit(sender.text ?? "", to: sender)
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            let current = textField.text ?? ""
            guard let swiftRange = Range(range, in: current) else { return false }
            let candidate = current.replacingCharacters(in: swiftRange, with: string)
            commit(candidate, to: textField)
            return false
        }

        private func commit(_ rawValue: String, to field: UITextField) {
            let normalized = Self.normalizedDigits(from: rawValue, limit: 6)
            if field.text != normalized {
                field.text = normalized
            }
            if text.wrappedValue != normalized {
                text.wrappedValue = normalized
            }
        }

        private static func normalizedDigits(from rawValue: String, limit: Int) -> String {
            var output = ""
            output.reserveCapacity(limit)
            for character in rawValue {
                guard let value = character.wholeNumberValue else { continue }
                output.append(String(value))
                if output.count == limit { break }
            }
            return output
        }
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
