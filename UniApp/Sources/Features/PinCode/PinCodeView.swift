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
///   `.verify` is Face ID-first by default; callers that must be
///   passcode-only (Security gate, wallet removal, Reset Aperture —
///   user direction 2026-06-13) pass `allowsBiometrics: false`.
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
    /// unchanged (auto-prompt on entry + biometric keypad key).
    ///
    /// `false` makes the verify **passcode-only**: the `.task`
    /// auto-prompt never fires and the keypad's biometric key is not
    /// rendered, even when the device supports biometrics and the
    /// user has them enabled. The Forgot affordance is unaffected.
    ///
    /// Per user direction 2026-06-13, the passcode-only gates are:
    /// the Settings → Security entry gate, wallet removal, and Reset
    /// Aperture. Face ID-first remains the policy everywhere else
    /// (app unlock, secret reveals, transaction signing, dApps).
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

    /// Drives the ⋯ → "Forgot passcode?" native action sheet (handoff: the
    /// forgot affordance moved out of the body into the options sheet).
    @State private var isShowingOptions: Bool = false

    /// Remaining-attempts count captured on a failed verify when the caller
    /// supplied `attemptsRemaining`. `nil` → the wrong line shows no counter.
    @State private var attemptsLeft: Int?

    /// Brief green success fill on the dots before `onComplete` fires — the
    /// handoff's `.dots.ok` state. Cleared on teardown.
    @State private var didSucceed: Bool = false

    /// Tracked task for the success-flash → complete hop; cancelled on
    /// `.onDisappear` so `onComplete` never fires into a gone parent.
    @State private var successTask: Task<Void, Never>?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Title stays in the BODY (the handoff has no nav-bar title here)
            // and follows the AMBIENT app locale — "Enter / Create / Confirm
            // Passcode" is read-once descriptive text that benefits from
            // translation. 25/600, no subtitle, no lock icon (handoff).
            Spacer(minLength: 0).frame(height: 44)
            titleView
                .padding(.horizontal, 20)
            // Dots + status line + keypad are forced LTR + English so the dots
            // fill L→R, the grid geometry stays 1-2-3 / 4-5-6 / 7-8-9 in every
            // locale, and the digit glyphs render as ASCII 0–9 (not
            // Arabic-Indic) — the universal-passcode-gesture guarantee.
            VStack(spacing: 0) {
                dotRow
                    .padding(.top, 22)
                statusLine
                    .padding(.top, 6)
                    .padding(.horizontal, 20)
                Spacer(minLength: 20)
                // The keypad spans the FULL screen width — no horizontal
                // padding (handoff: edge-to-edge dialer). Only the title /
                // dots / status above are inset.
                keypad
                    .disabled(isLockedOut)
                    .opacity(isLockedOut ? 0.4 : 1)
                    .animation(.easeInOut(duration: 0.2), value: isLockedOut)
                    .padding(.bottom, 6)
            }
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.locale, Locale(identifier: "en"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) { optionsButton }
        .uniHaptic(.contextualImpact(.tap), trigger: keypressTrigger)
        .uniHaptic(.error, trigger: errorTrigger)
        .confirmationDialog(
            "Can’t unlock? You can restore access with your recovery phrase.",
            isPresented: $isShowingOptions,
            titleVisibility: .visible
        ) {
            Button("Forgot passcode?") { onForgotPin?() }
            Button("Cancel", role: .cancel) { }
        }
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
            // Skipped entirely when the caller declared this verify
            // passcode-only (`allowsBiometrics: false` — Security
            // gate / wallet removal / Reset, user direction
            // 2026-06-13).
            guard allowsBiometrics,
                  !isLockedOut,
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
            successTask?.cancel()
        }
    }

    // MARK: - Title + options

    /// Handoff title — 25/600, centered, no subtitle, no lock icon.
    private var titleView: some View {
        Text(titleKey)
            .font(.system(size: 25, weight: .semibold))
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

    /// The ⋯ options chip (handoff `.optbar`), pinned top-trailing. Verify
    /// mode only, and only when the caller wired a forgot-passcode recovery
    /// path — it opens the native action sheet carrying "Forgot passcode?"
    /// (moved out of the screen body per the handoff). A flat circular chip,
    /// NOT a liquid-glass nav button: the lock screen owns no nav bar (it's a
    /// detached full-screen surface), so this is an in-view control exactly
    /// as the handoff draws it.
    @ViewBuilder
    private var optionsButton: some View {
        if mode == .verify, onForgotPin != nil {
            Button {
                UniHapticEngine.shared.play(.contextualImpact(.whisper))
                isShowingOptions = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(UniColors.Text.primary)
                    .frame(width: 38, height: 38)
                    .background(UniColors.Fill.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Options"))
            .padding(.top, 8)
            .padding(.trailing, 14)
        }
    }

    // MARK: - Dot row

    /// Six dots, filled count = `digits.count`. Animates a horizontal
    /// shake on mismatch. The shake amplitude is small (8 pt) — enough
    /// to register without feeling alarming.
    private var dotRow: some View {
        HStack(spacing: 20) {
            ForEach(0..<6, id: \.self) { index in
                let filled = index < digits.count
                Circle()
                    .fill(filled ? dotFillColor : Color.clear)
                    .frame(width: 14, height: 14)
                    .overlay {
                        // Empty dot = a 2pt inner ring; filled = solid, no ring.
                        Circle()
                            .strokeBorder(dotRingColor, lineWidth: 2)
                            .opacity(filled ? 0 : 1)
                    }
            }
        }
        .modifier(ShakeEffect(animatableData: CGFloat(shakeTrigger)))
        .animation(.spring(response: 0.3, dampingFraction: 0.4), value: shakeTrigger)
        .animation(.easeOut(duration: 0.18), value: digits.count)
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

    /// Empty-dot ring: 2pt `dotEmpty`, danger during a wrong attempt.
    private var dotRingColor: Color {
        dotsErrored ? UniColors.PinLock.danger : UniColors.PinLock.dotEmpty
    }

    // MARK: - Brute-force lockout

    private var isLockedOut: Bool {
        lockoutRemaining > 0
    }

    /// The single status line under the dots (handoff `.errtx`, height 20).
    /// One fixed-height slot so the keypad never jumps: it shows the active
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
            return Text("Wrong passcode. ") + attempts + Text(verbatim: ".")
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

    // MARK: - Keypad (flat iOS-dialer style — handoff)

    /// 12 keys in a 3-column grid — digits 1–9, then Face ID / 0 / delete.
    /// The handoff keypad has NO key backgrounds (Apple's lock-screen dialer
    /// style): each key is a bare digit + ITU letters over a transparent
    /// field, with a circular press-dim that fades in on touch
    /// (`DialerKeyStyle`). Pinned to the bottom of the screen.
    private var keypad: some View {
        LazyVGrid(columns: keypadColumns, spacing: 26) {
            ForEach(1...9, id: \.self) { digit in
                digitKey(String(digit))
            }
            biometricKey
            digitKey("0")
            deleteKey
        }
    }

    private var keypadColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 0),
            GridItem(.flexible(), spacing: 0),
            GridItem(.flexible(), spacing: 0)
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
            VStack(spacing: 3) {
                Text(verbatim: digit)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(UniColors.Text.primary)
                // ITU letters under the digit (uppercase, .16em tracking).
                // Empty but height-reserved for 1 and 0 so every digit sits
                // on the same baseline.
                Text(verbatim: letterRow.isEmpty ? " " : letterRow)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.8)
                    .foregroundStyle(UniColors.Text.secondary)
                    .opacity(letterRow.isEmpty ? 0 : 1)
                    .frame(height: 12)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(DialerKeyStyle())
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
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(UniColors.Text.primary)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DialerFnKeyStyle())
            .accessibilityLabel(Text(biometricAccessibilityKey))
        } else {
            // Empty placeholder — same dimensions so the grid math stays.
            Color.clear.frame(maxWidth: .infinity, minHeight: 64)
        }
    }

    @ViewBuilder
    private var deleteKey: some View {
        Button {
            handleDeleteTap()
        } label: {
            // Filled rounded backspace with the knocked-out X (handoff
            // "filled gray rounded-X glyph"), in the muted delete gray.
            Image(systemName: "delete.left.fill")
                .font(.system(size: 27, weight: .regular))
                .foregroundStyle(UniColors.PinLock.delete)
                .frame(maxWidth: .infinity, minHeight: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(DialerFnKeyStyle())
        .accessibilityLabel(Text("Delete last digit"))
    }

    // MARK: - Biometric symbol resolution

    private var shouldShowBiometricKey: Bool {
        // Caller-declared passcode-only verify (Security gate, wallet
        // removal, Reset) never renders the biometric key — the grid
        // shows the empty placeholder instead.
        guard allowsBiometrics else { return false }
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
        // Defense in depth — the biometric key isn't rendered when the
        // caller declared this verify passcode-only, so this path is
        // unreachable; the guard keeps it that way if the keypad ever
        // changes shape.
        guard allowsBiometrics else { return }
        // Medium impact as the scan begins (handoff haptics table).
        UniHapticEngine.shared.play(.contextualImpact(.commit))
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
        UniHapticEngine.shared.play(.success)
        withAnimation(.easeOut(duration: 0.18)) { didSucceed = true }
        successTask?.cancel()
        successTask = Task {
            try? await Task.sleep(for: .milliseconds(160))
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

// MARK: - Keypad key styles (flat iOS-dialer — handoff)

/// Flat dialer DIGIT key: no background; a 62pt circular press-dim fades in
/// under the label on touch (handoff `.key::before`) — fast in (0.04s), gentle
/// out (0.18s). The label keeps its full-width tap target.
private struct DialerKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(UniColors.PinLock.keyPress)
                    .frame(width: 62, height: 62)
                    .opacity(configuration.isPressed ? 1 : 0)
                    .animation(
                        .easeOut(duration: configuration.isPressed ? 0.04 : 0.18),
                        value: configuration.isPressed
                    )
            )
    }
}

/// Flat dialer FUNCTION key (Face ID / delete): no press circle — it dims to
/// 0.4 on touch, matching the handoff's `.key.fn:active{opacity:.4}`.
private struct DialerFnKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.4 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
