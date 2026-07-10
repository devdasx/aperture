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
///   recorded in GRDB and an escalating lockout (1 s doubling to a
///   16-minute cap from the fifth failure) disables input with a
///   countdown under the dots — brute-force protection that survives
///   app kill. No wipe: the recovery path is the recovery phrase.
///   `.verify` is biometric-first by default; callers that must be
///   passcode-only (Security gate, wallet removal, Reset Aperture —
///   user direction 2026-06-13) pass `allowsBiometrics: false`.
///
/// **Design rationale (Rule #17 §H).** Every PIN entry in the app — first
/// setup, unlock, transaction confirmation, Settings change — uses this
/// one view. Users recognize the screen across contexts. Same dots, same
/// in-app keypad. That muscle memory is itself a security property:
/// a phishing surface that looks "almost right" reads as wrong.
struct PinCodeView: View {

    // MARK: - Public surface

    struct AccessContext: Equatable {
        enum Icon: Equatable {
            case aperture
            case system(String)
            case asset(chain: SupportedChain, symbol: String, contract: String?)
        }

        let title: String
        let icon: Icon

        static let unlockApp = AccessContext(title: "Unlock Aperture", icon: .aperture)
        static let setPasscode = AccessContext(title: "Set Passcode", icon: .system("lock"))
        static let confirmPasscode = AccessContext(title: "Confirm Passcode", icon: .system("checkmark.shield"))
        static let accessSecurity = AccessContext(title: "Access Security Settings", icon: .system("lock.shield"))
        static let changePasscode = AccessContext(title: "Change Passcode", icon: .system("key"))
        static let turnOffPasscode = AccessContext(title: "Turn Off Passcode", icon: .system("lock.slash"))
        static let resetAperture = AccessContext(title: "Reset Aperture", icon: .system("trash"))
        static let removeWallet = AccessContext(title: "Remove Wallet", icon: .system("wallet.bifold"))
        static let viewWalletSecrets = AccessContext(title: "View Wallet Secrets", icon: .system("key"))

        static func signTransaction(chain: SupportedChain, symbol: String, contract: String?) -> AccessContext {
            let cleanedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
            let displaySymbol: String
            if contract == nil, chain == .bitcoin, cleanedSymbol.caseInsensitiveCompare(chain.ticker) == .orderedSame {
                displaySymbol = chain.displayName
            } else {
                displaySymbol = cleanedSymbol.isEmpty ? chain.displayName : cleanedSymbol.uppercased()
            }
            return AccessContext(
                title: "Sign \(displaySymbol) Transaction",
                icon: .asset(chain: chain, symbol: displaySymbol, contract: contract)
            )
        }
    }

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
    /// pre-existing call site keeps the biometric-first behavior
    /// unchanged (auto-prompt on entry).
    ///
    /// `false` makes the verify **passcode-only**: the `.task`
    /// auto-prompt never fires, even when the device supports biometrics
    /// and the user has them enabled. The Forgot affordance is unaffected.
    ///
    /// Per user direction 2026-06-13, the passcode-only gates are:
    /// the Settings → Security entry gate, wallet removal, and Reset
    /// Aperture. Biometric-first remains the policy everywhere else
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
    /// Shows the app-lock-only principal pill in the navigation bar.
    /// In-flow authorization sheets intentionally leave this off: the
    /// presenting sheet already explains the action, and the passcode prompt
    /// should stay focused and dismissible.
    var showsAccessContextToolbar: Bool = false
    /// Shows the app-lock-only forgot-passcode option. A forgotten passcode
    /// is an app-entry recovery problem, not a mid-send or mid-settings
    /// action, so only `AppLockView` opts in.
    var showsForgotPasscodeOption: Bool = false
    /// Short, honest context shown in the nav bar so the user knows what the
    /// passcode unlocks or authorizes before typing it.
    var accessContext: AccessContext? = nil

    // MARK: - State

    /// Current digit buffer. Only modified by this view's keypad — never by
    /// parent state. Always 0...6 digits, all `0`–`9`.
    @State private var digits: String = ""

    /// Animation hook for the dot row. Bumped when the user enters a
    /// mismatching PIN; drives the shake animation.
    @State private var shakeTrigger: Int = 0

    /// Transient inline-error state. `nil` when there's no error; non-nil
    /// after a `.confirm` mismatch or a `.verify` mismatch; cleared as
    /// soon as the user types again.
    @State private var inlineError: InlineError? = nil

    /// Haptic trigger for error events. Digit entry uses a lightweight
    /// contextual tap directly from the keypad.
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
    /// keypad input. Stored so `.onDisappear` can cancel it.
    @State private var lockoutTask: Task<Void, Never>? = nil

    /// Seconds remaining in the active brute-force lockout window.
    /// `0` means input is allowed. Mirrors
    /// `PinCodeStorage.lockoutRemaining()` — the GRDB record is the
    /// source of truth; this is the UI-facing copy the countdown updates.
    @State private var lockoutRemaining: TimeInterval = 0

    /// Remaining-attempts count captured on a failed verify when the caller
    /// supplied `attemptsRemaining`. `nil` → the wrong line shows no counter.
    @State private var attemptsLeft: Int?

    /// Brief green success fill on the dots before `onComplete` fires — the
    /// handoff's `.dots.ok` state. Cleared on teardown.
    @State private var didSucceed: Bool = false

    /// Tracked task for the success/complete hop; cancelled on `.onDisappear`
    /// so `onComplete` never fires into a gone parent.
    @State private var completionTask: Task<Void, Never>?
    @State private var biometricTask: Task<Void, Never>?
    @State private var isBiometricPromptActive: Bool = false
    @State private var isCompleting: Bool = false
    @State private var isVerifyingPin: Bool = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            passcodePrompt
            Spacer(minLength: 0)
            keypad
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            accessContextToolbar
            navigationControlsToolbar
        }
        .uniHaptic(.error, trigger: errorTrigger)
        .task {
            guard case .verify = mode else {
                return
            }
            // Restore any persisted brute-force lockout before anything
            // else — the GRDB record survives app kill, so a user
            // who force-quits mid-lockout lands back in the countdown.
            refreshLockout()
            // Auto-fire biometrics on `.verify` entry when
            // the user has biometrics enabled. Matches iOS's own
            // pattern (Settings → Touch ID & Passcode prompts biometric
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
                return
            }
            await requestBiometricUnlock()
        }
        .onDisappear {
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
            markView
                .padding(.bottom, 20)

            titleView
                .padding(.horizontal, 20)

            if showsSubtitle {
                Text(subtitleKey)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(UniColors.Text.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .padding(.horizontal, 24)
            }

            VStack(spacing: 0) {
                dotRow
                    .padding(.top, 26)
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

    private var resolvedAccessContext: AccessContext {
        if let accessContext { return accessContext }
        switch mode {
        case .set:
            return .setPasscode
        case .confirm:
            return .confirmPasscode
        case .verify:
            return .unlockApp
        }
    }

    @ToolbarContentBuilder
    private var accessContextToolbar: some ToolbarContent {
        if showsAccessContextToolbar {
            ToolbarItem(placement: .principal) {
                PasscodeAccessPill(context: resolvedAccessContext)
            }
        }
    }

    @ToolbarContentBuilder
    private var navigationControlsToolbar: some ToolbarContent {
        if showsNavigationControls {
            if showsForgotPasscodeOption, mode == .verify, onForgotPin != nil {
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

    private var markView: some View {
        ApertureAppLogo(size: 92, irisScale: 0.66)
    }

    /// Handoff title — centered, with a short mode-specific subtitle.
    private var titleView: some View {
        Text(titleKey)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(UniColors.Text.primary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var titleKey: LocalizedStringKey {
        switch mode {
        case .set:
            return accessContext == .changePasscode ? "Enter new passcode" : "Turn on passcode"
        case .confirm:
            return accessContext == .changePasscode ? "Confirm new passcode" : "Confirm passcode"
        case .verify:
            return "Enter passcode"
        }
    }

    private var showsSubtitle: Bool {
        switch mode {
        case .set, .confirm:
            return true
        case .verify:
            return false
        }
    }

    private var subtitleKey: LocalizedStringKey {
        switch mode {
        case .set:
            return accessContext == .changePasscode
                ? "Enter a new 6-digit passcode for this device."
                : "Enter a 6-digit passcode for this device."
        case .confirm:
            return accessContext == .changePasscode
                ? "Re-enter your new 6-digit passcode."
                : "Re-enter your 6-digit passcode."
        case .verify:
            return "Enter your 6-digit passcode."
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

    private var canAcceptKeypadInput: Bool {
        !isCompleting
            && !isVerifyingPin
            && !isBiometricPromptActive
            && !isLockedOut
    }

    private var shouldOfferBiometricUnlock: Bool {
        guard allowsBiometrics else { return false }
        guard case .verify = mode else { return false }
        guard !isLockedOut else { return false }
        guard biometricService.isAvailable else { return false }
        return PinCodePreference.isBiometricEnabled()
    }

    private var biometricSymbol: String {
        biometricService.biometryType.systemImageName
    }

    private var biometricActionTitle: String {
        biometricService.biometryType.unlockActionTitle
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
    /// so the GRDB record stays the single source of truth.
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

    // MARK: - Keypad input

    private var keypad: some View {
        UniNumberKeypad(
            isEnabled: canAcceptKeypadInput,
            leadingKey: shouldOfferBiometricUnlock
                ? .systemImage(
                    name: biometricSymbol,
                    label: biometricActionTitle,
                    isLoading: isBiometricPromptActive
                )
                : .empty,
            isLeadingKeyEnabled: shouldOfferBiometricUnlock && !isBiometricPromptActive,
            canDelete: !digits.isEmpty,
            onDigit: appendDigit,
            onDelete: deleteDigit,
            onLeadingKey: startBiometricUnlock
        )
        .padding(.horizontal, 36)
        .padding(.bottom, 28)
    }

    private func appendDigit(_ digit: Int) {
        guard canAcceptKeypadInput, digits.count < 6 else { return }
        UniHapticEngine.shared.play(.contextualImpact(.tap))
        inlineError = nil
        digits.append(String(digit))
        if digits.count == 6 {
            evaluate()
        }
    }

    private func deleteDigit() {
        guard canAcceptKeypadInput, !digits.isEmpty else { return }
        UniHapticEngine.shared.play(.contextualImpact(.tap))
        inlineError = nil
        digits.removeLast()
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
            return
        }
        guard !isBiometricPromptActive else { return }
        isBiometricPromptActive = true
        let result = await biometricService.authenticate(
            reason: biometricService.biometryType.unlockReason
        )
        guard !Task.isCancelled else {
            isBiometricPromptActive = false
            return
        }
        isBiometricPromptActive = false
        if case .success = result {
            completeAfterInputSettles("")
        }
    }

    // MARK: - Mode evaluation

    private func evaluate() {
        switch mode {
        case .set:
            // Caller decides what "set complete" means — typically pushing
            // the confirm step.
            completeAfterInputSettles(digits)
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
        completeAfterInputSettles(value, successFlash: true)
    }

    private func completeAfterInputSettles(_ value: String, successFlash: Bool = false) {
        guard !isCompleting else { return }
        isCompleting = true
        if successFlash {
            UniHapticEngine.shared.play(.success)
            withAnimation(.easeOut(duration: 0.14)) { didSucceed = true }
        }
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
    ///   async `PinCodeStorage.verify(_:)` — keypad input stays responsive.
    /// - Wrong PIN → `recordFailure()` persists the incremented count +
    ///   timestamp to GRDB; success → `clearFailures()`.
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

private struct PasscodeAccessPill: View {
    let context: PinCodeView.AccessContext

    var body: some View {
        HStack(spacing: 7) {
            icon

            Text(verbatim: context.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .foregroundStyle(UniColors.Text.primary)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .glassEffect(.regular, in: Capsule(style: .continuous))
        .contentShape(Capsule(style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch context.icon {
        case .aperture:
            ApertureIrisView()
                .frame(width: 18, height: 18)
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(UniColors.Text.primary)
                .frame(width: 18, height: 18)
        case .asset(let chain, let symbol, let contract):
            CoinMark(chain: chain, tokenSymbol: symbol, contract: contract)
                .frame(width: 20, height: 20)
        }
    }
}

// MARK: - Unified number keypad

struct UniNumberKeypad: View {
    enum LeadingKey {
        case empty
        case decimal(String)
        case systemImage(name: String, label: String, isLoading: Bool = false)
    }

    let isEnabled: Bool
    let leadingKey: LeadingKey
    let isLeadingKeyEnabled: Bool
    var showsDigitLetters: Bool = true
    let canDelete: Bool
    let onDigit: (Int) -> Void
    let onDelete: () -> Void
    let onLeadingKey: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            digitRow([1, 2, 3])
            digitRow([4, 5, 6])
            digitRow([7, 8, 9])

            HStack(spacing: 0) {
                leadingButton
                digitButton(0)
                deleteButton
            }
        }
        .frame(maxWidth: 560)
    }

    private func digitRow(_ digits: [Int]) -> some View {
        HStack(spacing: 0) {
            ForEach(digits, id: \.self) { digit in
                digitButton(digit)
            }
        }
    }

    private func digitButton(_ digit: Int) -> some View {
        Button {
            onDigit(digit)
        } label: {
            VStack(spacing: 2) {
                Text(verbatim: String(digit))
                    .font(.system(size: 31, weight: .regular, design: .rounded))
                    .foregroundStyle(UniColors.Text.primary)
                    .monospacedDigit()

                Text(verbatim: letters(for: digit))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .kerning(1.4)
                    .foregroundStyle(UniColors.Text.secondary)
                    .frame(height: 11)
                    .opacity(showsDigitLetters && !letters(for: digit).isEmpty ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(UniNumberKeyButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel(Text(verbatim: String(digit)))
    }

    private func letters(for digit: Int) -> String {
        switch digit {
        case 2: return "ABC"
        case 3: return "DEF"
        case 4: return "GHI"
        case 5: return "JKL"
        case 6: return "MNO"
        case 7: return "PQRS"
        case 8: return "TUV"
        case 9: return "WXYZ"
        default: return ""
        }
    }

    @ViewBuilder
    private var leadingButton: some View {
        switch leadingKey {
        case .empty:
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: UniNumberKeyButtonStyle.keyHeight)
                .accessibilityHidden(true)
        case .decimal(let label):
            Button {
                onLeadingKey()
            } label: {
                Text(verbatim: label)
                    .font(.system(size: 31, weight: .regular, design: .rounded))
                    .foregroundStyle(isEnabled && isLeadingKeyEnabled ? UniColors.Text.primary : UniColors.Text.tertiary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(UniNumberKeyButtonStyle())
            .disabled(!isEnabled || !isLeadingKeyEnabled)
            .accessibilityLabel(Text("Decimal separator"))
        case .systemImage(let name, let label, let isLoading):
            Button {
                onLeadingKey()
            } label: {
                Group {
                    if isLoading {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(UniColors.Text.tertiary)
                    } else {
                        Image(systemName: name)
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(UniColors.Text.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(UniNumberKeyButtonStyle())
            .disabled(!isEnabled || !isLeadingKeyEnabled || isLoading)
            .accessibilityLabel(Text(verbatim: label))
        }
    }

    private var deleteButton: some View {
        Button {
            onDelete()
        } label: {
            Image(systemName: "delete.left")
                .font(.system(size: 27, weight: .regular))
                .foregroundStyle(canDelete && isEnabled ? UniColors.Text.primary : UniColors.Text.tertiary)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(UniNumberKeyButtonStyle())
        .disabled(!isEnabled || !canDelete)
        .accessibilityLabel(Text("Delete"))
    }
}

struct UniNumberKeyButtonStyle: ButtonStyle {
    static let keyHeight: CGFloat = 72

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(height: Self.keyHeight)
            .contentShape(Circle())
            .background {
                Circle()
                    .fill(UniColors.PinLock.keyPress)
                    .frame(width: 68, height: 68)
                    .opacity(configuration.isPressed ? 1 : 0)
                    .scaleEffect(configuration.isPressed ? 1 : 0.72)
            }
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
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
