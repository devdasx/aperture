import SwiftUI
import UniformTypeIdentifiers

// MARK: - SwapReviewSummary

/// The assembled, honest review of a swap/bridge — what the user is about
/// to do, restated at the moment of commitment. `Hashable` + `Codable` so
/// it rides the sheet's `NavigationPath` across Rule #12 §G direction
/// rebuilds (the same contract as `SendDraft`).
///
/// It carries the live `SwapQuote` verbatim (which itself holds the EVM /
/// Solana execute seam — `evmTx` / `solanaTx`), so the executor can sign +
/// broadcast straight from this summary without re-quoting.
struct SwapReviewSummary: Hashable, Codable {
    let quote: SwapQuote
    /// The human from-amount the user entered (chain units).
    let fromAmount: Decimal
    /// Slippage tolerance used for this quote (bps).
    let slippageBps: Int

    var isCrossChain: Bool { quote.fromToken.chain != quote.toToken.chain }
}

// MARK: - SwapReviewView

/// Swap · Review + real swap. Restates the from/to assets, route, fees,
/// time, and minimum received, then commits the swap through the real
/// signing + broadcast engine (`SwapExecutor`) — exactly the shape of the
/// Send flow.
///
/// **The flow (Rule #16 — honest at every step).**
/// 1. **Review** — every figure is real; the primary action is a genuine
///    **Swap** (or **Bridge**, cross-chain) CTA.
/// 2. **Authenticate** — signing is a high-stakes commit (Rule #17). When
///    biometrics are enabled we present the system Face ID / Touch ID
///    prompt; on its absence or refusal we fall back to the canonical
///    `PinCodeView(mode: .verify)`. A wallet with no PIN and no biometrics
///    (Rule #17's optional-PIN path) goes straight through. The executor
///    ASSUMES auth already happened — `execute` is never called until the
///    gate passes.
/// 3. **Passphrase** — a BIP-39 passphrase wallet (`walletHasPassphrase`)
///    is asked for its passphrase in a native sheet (Rule #15) before the
///    executor runs; without it the engine refuses rather than signing the
///    wrong key.
/// 4. **In flight** — calm, honest, live phase status under the CTA
///    (Rule #25), driven by the executor's `onPhase` callback. Token swaps
///    surface approval steps; native-coin swaps skip them — whatever phase
///    arrives is reflected verbatim.
/// 5. **Result** — never fabricated (Rule #16):
///    - confirmed → a calm "Swapped" / "Bridged" with the received amount,
///      the REAL tx hash (short + copy + explorer link), and a note that the
///      received token was added.
///    - reverted (confirmed == false) → "submitted but reverted; nothing was
///      swapped" + the hash.
///    - pending (confirmed == nil) → "submitted — confirming may take a
///      moment" + the hash, NOT claimed as done.
///    - failure → the executor's honest `ExecError.message`; the user stays
///      on Review so they can retry.
struct SwapReviewView: View {
    let summary: SwapReviewSummary
    let currencyCode: String
    /// The signing wallet's UUID — the executor needs this.
    let walletId: UUID
    /// Whether the signing wallet has a BIP-39 passphrase. When `true`, the
    /// passphrase sheet is presented after auth and before the swap.
    let walletHasPassphrase: Bool
    /// Dismisses the whole Swap sheet.
    let onClose: () -> Void

    @AppStorage("biometricEnabled") private var biometricEnabled: Bool = false

    /// The swap state machine. `.review` is the resting state.
    @State private var phase: Phase = .review
    /// The live executor phase while signing/broadcasting (drives the status
    /// line under the CTA, Rule #25).
    @State private var execPhase: SwapExecutor.Phase = .preparing
    /// Drives the success haptic (set once when a confirmed swap lands).
    @State private var swappedAt: Date?
    /// Drives the error haptic (bumped on each failure).
    @State private var failedTrigger: Int = 0
    /// The PIN-fallback presentation (full-screen, the canonical surface).
    @State private var isShowingPinVerify: Bool = false
    /// The passphrase prompt presentation.
    @State private var isShowingPassphrase: Bool = false
    /// The collected passphrase, held only for the duration of the swap.
    @State private var passphrase: String = ""
    /// The in-flight biometric authentication, cancellable on disappear.
    @State private var authTask: Task<Void, Never>?
    /// The in-flight swap, cancellable on disappear.
    @State private var swapTask: Task<Void, Never>?

    private enum Phase: Equatable {
        case review
        /// Auth prompt is up (biometric or PIN) — the CTA shows a spinner.
        case authenticating
        /// Signing + broadcasting (off-main in the executor).
        case swapping
        case done(SwapExecutor.Executed)
        case failed(SwapExecutor.ExecError)
    }

    private var quote: SwapQuote { summary.quote }
    private var isBridge: Bool { summary.isCrossChain }

    var body: some View {
        Group {
            switch phase {
            case .authenticating, .swapping:
                SwapInFlightView(
                    summary: summary,
                    isBridge: isBridge,
                    isAuthenticating: phase == .authenticating,
                    execPhase: execPhase
                )
            case .done(let executed):
                SwapDoneView(
                    summary: summary,
                    executed: executed,
                    isBridge: isBridge,
                    currencyCode: currencyCode,
                    onDone: onClose
                )
            case .failed(let error):
                SwapFailedView(error: error, onRetry: resetToReview, onClose: onClose)
            default:
                reviewContent
            }
        }
        .uniHaptic(.success, trigger: swappedAt)
        .uniHaptic(.error, trigger: failedTrigger)
        .onDisappear {
            authTask?.cancel()
            swapTask?.cancel()
            // Drop the passphrase from memory the moment the flow ends.
            passphrase = ""
        }
    }

    // MARK: - Review content (resting + in-flight states)

    private var reviewContent: some View {
        ScrollView {
            VStack(spacing: UniSpacing.l) {
                assetsCard
                SwapQuotePanel(
                    quote: quote,
                    isCrossChain: isBridge,
                    currencyCode: currencyCode
                )
                selfCustodyNote
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.m)
            .padding(.bottom, UniSpacing.xxxl + UniSpacing.xl)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(isWorking)
        .background(UniColors.Background.primary)
        .safeAreaInset(edge: .bottom) { actionBar }
        .navigationTitle(isBridge ? "Review bridge" : "Review swap")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isWorking)
        .fullScreenCover(isPresented: $isShowingPinVerify) {
            pinVerifyCover
        }
        .sheet(isPresented: $isShowingPassphrase) {
            SwapPassphraseSheet(
                onSubmit: { entered in
                    passphrase = entered
                    isShowingPassphrase = false
                    startSwap()
                },
                onCancel: {
                    isShowingPassphrase = false
                    phase = .review
                }
            )
            .uniAppEnvironment()
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
    }

    private var isWorking: Bool {
        phase == .authenticating || phase == .swapping
    }

    // MARK: - Assets card (from → to)

    private var assetsCard: some View {
        UniCard {
            VStack(spacing: UniSpacing.s) {
                assetRow(
                    label: "You pay",
                    token: quote.fromToken,
                    amount: summary.fromAmount,
                    emphasized: true
                )
                HStack {
                    Image(systemName: isBridge ? "arrow.left.arrow.right" : "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.secondary)
                    Spacer()
                }
                .padding(.leading, UniSpacing.xs)
                assetRow(
                    label: "You receive (estimated)",
                    token: quote.toToken,
                    amount: quote.toAmount,
                    emphasized: true
                )
            }
        }
    }

    private func assetRow(label: LocalizedStringKey, token: SwapToken, amount: Decimal, emphasized: Bool) -> some View {
        HStack(spacing: UniSpacing.s) {
            CoinMark(
                chain: token.chain,
                tokenSymbol: token.symbol,
                contract: token.isNative ? nil : token.address,
                customIconURL: token.logoURI
            )
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
                Text(verbatim: token.chain.displayName)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
            }
            Spacer(minLength: UniSpacing.s)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: WalletFormatting.native(amount, decimals: token.decimals))
                    .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(verbatim: token.symbol)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
            }
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    // MARK: - Self-custody note (Rule #16 — restate at the moment of commit)

    private var selfCustodyNote: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: "lock.shield")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .accessibilityHidden(true)
            Text(isBridge
                 ? "Aperture signs this on your iPhone and broadcasts it to the network. A bridge moves funds across chains and can't be reversed once it's sent."
                 : "Aperture signs this on your iPhone and broadcasts it to the network. Once it's sent, the swap can't be reversed.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UniSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Fill.quaternary)
        )
    }

    // MARK: - Action bar (real Swap / Bridge CTA)

    /// The resting Review CTA — the entry to the whole flow. Once tapped,
    /// `beginSwap` advances `phase` to `.authenticating` / `.swapping`, which
    /// routes the body to `SwapInFlightView`; the working/loading states live
    /// there now, not here (so this bar only ever renders at rest).
    private var actionBar: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            UniButton(
                title: isBridge ? "Bridge" : "Swap",
                variant: .primary,
                action: beginSwap
            )
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.xs)
        }
    }

    // MARK: - PIN-fallback cover

    private var pinVerifyCover: some View {
        PinCodeView(
            mode: .verify,
            onComplete: { _ in
                isShowingPinVerify = false
                afterAuthSuccess()
            },
            onCancel: {
                isShowingPinVerify = false
                phase = .review
            },
            onForgotPin: {
                // A forgotten PIN can't be reset (Rule #16). Cancel the swap
                // and return the user to Review; the forgot path lives in the
                // lock screen, not mid-swap.
                isShowingPinVerify = false
                phase = .review
            }
        )
        .background(UniColors.Background.primary.ignoresSafeArea())
        .uniAppEnvironment()
    }

    // MARK: - Flow

    /// Entry point from the Swap CTA. Decides the auth path: biometric → PIN
    /// fallback → (no PIN, no biometric) straight through. The executor is
    /// never called until this gate passes (Rule #17).
    private func beginSwap() {
        guard phase == .review else { return }
        // The commit haptic fires from `UniButton(.primary)` itself (Rule #10
        // §E → `.contextualImpact(.commit)`); adding another here would
        // double-fire (M-002 family). The `.success` / `.error` beats on
        // landing fire via the body's `.uniHaptic(...)` triggers.
        phase = .authenticating

        if biometricEnabled {
            authTask?.cancel()
            authTask = Task { @MainActor in
                let outcome = await BiometricService().authenticate(
                    reason: LocalizedStringResource("Confirm to swap.")
                )
                guard !Task.isCancelled else { return }
                switch outcome {
                case .success:
                    afterAuthSuccess()
                case .failure(.unavailable),
                     .failure(.userCancelled),
                     .failure(.authenticationFailed),
                     .failure(.systemError):
                    routeToPinOrProceed()
                }
            }
        } else {
            routeToPinOrProceed()
        }
    }

    /// After a biometric failure / when biometrics are off: require the PIN
    /// if one exists, otherwise (Rule #17 optional-PIN) proceed.
    private func routeToPinOrProceed() {
        if PinCodeStorage.hasPin {
            isShowingPinVerify = true
        } else {
            afterAuthSuccess()
        }
    }

    /// Auth has succeeded. Collect the passphrase if the wallet needs one,
    /// otherwise start the swap.
    private func afterAuthSuccess() {
        if walletHasPassphrase {
            isShowingPassphrase = true
        } else {
            startSwap()
        }
    }

    /// Run the real swap through the executor (off-main heavy work inside it;
    /// this method only awaits and applies the result, Rule #28).
    private func startSwap() {
        execPhase = .preparing
        phase = .swapping
        swapTask?.cancel()
        swapTask = Task { @MainActor in
            let pass = walletHasPassphrase ? passphrase : nil
            let result = await SwapExecutor().execute(
                summary: summary,
                walletId: walletId,
                passphrase: pass,
                onPhase: { p in
                    withAnimation(.easeInOut(duration: 0.2)) { execPhase = p }
                }
            )
            // Drop the passphrase from memory immediately after the swap.
            passphrase = ""
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let executed):
                if executed.confirmed == true { swappedAt = Date() }
                withAnimation(.smooth(duration: 0.35)) { phase = .done(executed) }
            case .failure(let error):
                failedTrigger += 1
                withAnimation(.smooth(duration: 0.35)) { phase = .failed(error) }
            }
        }
    }

    private func resetToReview() {
        withAnimation(.smooth(duration: 0.3)) { phase = .review }
    }
}

// MARK: - In-flight state

/// The live execution surface — what the swap is *doing*, rendered as the
/// real on-chain sequence rather than a one-line status (Rule #25). It owns
/// the entire working window: the moment the user authenticates, through
/// signing, broadcasting, and on-chain confirmation. It never fabricates a
/// timer (Rule #16) — every step's state is read straight from the live
/// `execPhase` the executor reports.
///
/// **The shape.** A distilled from→to header with a calm directional pulse,
/// then a vertical step *rail* — Apple's pattern for an ordered, in-progress
/// sequence (Apple Pay setup, Find My, device setup). Steps render
/// pending → active → done with a filling connector; the active one carries
/// a live spinner and emphasis, completed ones settle to a check, later ones
/// stay dim. No CTA: the steps *are* the surface, and a broadcast can't be
/// cancelled — the screen is non-dismissable mid-swap (back button hidden).
///
/// **Step set (honest to the chain).** A token swap needs an ERC-20 approval
/// before the router can move it, so it shows **Approve → Sign → Submit →
/// Confirm**; a native-coin swap has no approval and shows **Sign → Submit →
/// Confirm**. The live phase maps onto exactly one active step.
private struct SwapInFlightView: View {
    let summary: SwapReviewSummary
    let isBridge: Bool
    /// `true` while the Face ID / passcode gate is up, before any executor
    /// phase has begun. Drives the leading "Confirm on your iPhone" state.
    let isAuthenticating: Bool
    let execPhase: SwapExecutor.Phase

    private var quote: SwapQuote { summary.quote }
    /// A native-coin swap skips the approval step (no ERC-20 allowance).
    private var needsApproval: Bool { !quote.fromToken.isNative }

    /// The ordered steps for this swap — approval only when the from-token
    /// is an ERC-20.
    private var steps: [SwapInFlightStep] {
        needsApproval ? [.approve, .sign, .submit, .confirm] : [.sign, .submit, .confirm]
    }

    /// Index of the currently-active step, or `nil` before the sequence
    /// begins (during `.authenticating`, or `.preparing` before approval).
    /// Steps before it render done; the rest pending.
    private var activeIndex: Int? {
        if isAuthenticating { return nil }
        switch execPhase {
        case .preparing:
            // Preparing precedes the first real step — nothing active yet.
            return nil
        case .checkingApproval, .approving, .confirmingApproval:
            return steps.firstIndex(of: .approve)
        case .signing:
            return steps.firstIndex(of: .sign)
        case .broadcasting:
            return steps.firstIndex(of: .submit)
        case .confirming:
            return steps.firstIndex(of: .confirm)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: UniSpacing.xl) {
                header
                authBanner
                rail
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.xl)
            .padding(.bottom, UniSpacing.xxl)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
        .background(UniColors.Background.primary)
        .navigationTitle(isBridge ? "Bridging" : "Swapping")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: Header — from → to with a calm directional pulse

    private var header: some View {
        VStack(spacing: UniSpacing.s) {
            tokenLine(
                token: quote.fromToken,
                amount: summary.fromAmount,
                caption: "You pay"
            )
            DirectionalPulse(isBridge: isBridge)
                .frame(height: 24)
            tokenLine(
                token: quote.toToken,
                amount: quote.toAmount,
                caption: "You receive (estimated)"
            )
        }
        .padding(UniSpacing.l)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Fill.quaternary)
        )
    }

    private func tokenLine(token: SwapToken, amount: Decimal, caption: LocalizedStringKey) -> some View {
        HStack(spacing: UniSpacing.s) {
            CoinMark(
                chain: token.chain,
                tokenSymbol: token.symbol,
                contract: token.isNative ? nil : token.address,
                customIconURL: token.logoURI
            )
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(caption)
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
                Text(verbatim: token.chain.displayName)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
            }
            Spacer(minLength: UniSpacing.s)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: WalletFormatting.native(amount, decimals: token.decimals))
                    .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(verbatim: token.symbol)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
            }
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    // MARK: Auth banner — the pre-step "Confirm on your iPhone" state

    @ViewBuilder private var authBanner: some View {
        if isAuthenticating {
            HStack(spacing: UniSpacing.s) {
                Image(systemName: "faceid")
                    .font(.system(size: 20, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(UniColors.Brand.mark)
                    .symbolEffect(.pulse, options: .repeating)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirm on your iPhone")
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(UniColors.Text.primary)
                    Text("Authenticate to sign this \(isBridge ? "bridge" : "swap").")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(UniSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                    .fill(UniColors.Fill.quaternary)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: Step rail — the heart

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                StepRow(
                    step: step,
                    state: state(for: index),
                    isLast: index == steps.count - 1,
                    fromSymbol: quote.fromToken.symbol,
                    chainName: quote.fromToken.chain.displayName,
                    isBridge: isBridge
                )
            }
        }
    }

    private func state(for index: Int) -> StepRow.State {
        guard let activeIndex else { return .pending }
        if index < activeIndex { return .done }
        if index == activeIndex { return .active }
        return .pending
    }
}

// MARK: - Step row

/// A single row in the swap step rail: a leading status node + a filling
/// rail segment to the next step, with the step's title + honest sub-copy.
/// Three states animate between each other (`withAnimation` is applied by
/// the parent's `execPhase` update): pending (dim, hollow) → active (live
/// spinner, emphasized, tinted) → done (settled check).
private struct StepRow: View {
    enum State { case pending, active, done }

    let step: SwapInFlightStep
    let state: State
    let isLast: Bool
    let fromSymbol: String
    let chainName: String
    let isBridge: Bool

    var body: some View {
        HStack(alignment: .top, spacing: UniSpacing.m) {
            railColumn
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(state == .active ? UniTypography.bodyEmphasized : UniTypography.body)
                    .foregroundStyle(titleColor)
                Text(step.subtitle(fromSymbol: fromSymbol, chainName: chainName, isBridge: isBridge))
                    .font(UniTypography.footnote)
                    .foregroundStyle(subtitleColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : UniSpacing.l)
            .opacity(state == .pending ? 0.5 : 1)
            Spacer(minLength: 0)
        }
        .animation(.smooth(duration: 0.3), value: state)
    }

    // The leading column: status node + connecting rail to the next row.
    private var railColumn: some View {
        VStack(spacing: 0) {
            node
            if !isLast {
                // The connector fills (accent) once this step is done; it's
                // dim while this step is pending/active.
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(state == .done ? UniColors.Tint.accent : UniColors.Separator.regular)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .animation(.smooth(duration: 0.3), value: state)
            }
        }
        .frame(width: 28)
    }

    @ViewBuilder private var node: some View {
        ZStack {
            switch state {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26, weight: .regular))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(UniColors.Icon.onTint, UniColors.Tint.accent)
                    .symbolEffect(.bounce, options: .nonRepeating)
            case .active:
                Circle()
                    .stroke(UniColors.Tint.accent, lineWidth: 2)
                    .frame(width: 26, height: 26)
                ProgressView()
                    .controlSize(.small)
                    .tint(UniColors.Tint.accent)
            case .pending:
                Circle()
                    .stroke(UniColors.Separator.regular, lineWidth: 2)
                    .frame(width: 26, height: 26)
                Image(systemName: step.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UniColors.Icon.tertiary)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var titleColor: Color {
        switch state {
        case .active: return UniColors.Text.primary
        case .done:   return UniColors.Text.primary
        case .pending: return UniColors.Text.secondary
        }
    }

    private var subtitleColor: Color {
        state == .active ? UniColors.Text.secondary : UniColors.Text.tertiary
    }
}

/// The step vocabulary — one definition referenced by both `SwapInFlightView`
/// (which builds the ordered list and maps the live phase onto it) and
/// `StepRow` (which renders one). One real on-chain action per case, with
/// honest copy that names the actual mechanism rather than a fabricated stage.
private enum SwapInFlightStep: Hashable {
    case approve, sign, submit, confirm

    var title: LocalizedStringKey {
        switch self {
        case .approve: return "Approve"
        case .sign:    return "Sign"
        case .submit:  return "Submit"
        case .confirm: return "Confirm"
        }
    }

    func subtitle(fromSymbol: String, chainName: String, isBridge: Bool) -> LocalizedStringKey {
        switch self {
        case .approve: return "Letting the router move your \(fromSymbol)"
        case .sign:    return "Signing on your iPhone"
        case .submit:  return "Broadcasting to \(chainName)"
        case .confirm:
            return isBridge
                ? "Bridging — waiting for on-chain confirmation"
                : "Waiting for on-chain confirmation"
        }
    }

    var icon: String {
        switch self {
        case .approve: return "checkmark.shield"
        case .sign:    return "signature"
        case .submit:  return "paperplane"
        case .confirm: return "checkmark.seal"
        }
    }
}

// MARK: - Directional pulse

/// A calm, repeating directional cue between the from/to tokens — a gentle
/// breath along the arrow's axis (down for a swap, left↔right for a bridge).
/// Materials-true, restrained: opacity + a small offset, nothing flashy. It
/// honestly says "movement is happening" without faking progress.
private struct DirectionalPulse: View {
    let isBridge: Bool
    @State private var animate = false

    var body: some View {
        Image(systemName: isBridge ? "arrow.left.arrow.right" : "arrow.down")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(UniColors.Tint.accent)
            .opacity(animate ? 1 : 0.4)
            .offset(
                x: isBridge ? (animate ? 3 : -3) : 0,
                y: isBridge ? 0 : (animate ? 3 : -3)
            )
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    animate = true
                }
            }
    }
}

// MARK: - Done state (the swap receipt)

/// The honest result surface for a broadcast swap — a full, detailed
/// receipt the user can read like a wallet register, not a sparse
/// placeholder. Three faces, never fabricated (Rule #16):
/// - `confirmed == true`  → "Swapped" / "Bridged" with the received amount.
/// - `confirmed == false` → submitted but reverted; nothing was swapped.
/// - `confirmed == nil`   → submitted; confirming may take a moment.
///
/// **The shape (a native register).** A status hero ABOVE a native
/// inset-grouped `List` (Rule #3 — the Settings.app grouped register):
/// a transfer section (from→to + max slippage + network), a quote section
/// (the verbatim provider breakdown), a transaction section (hash + copy +
/// explorer + timestamp). On a confirmed swap a quiet "added to your tokens"
/// section appears. The detail sections show on ALL three faces — for a
/// reverted/pending result they honestly read as "this is what you
/// submitted", with the hero making the unsettled status plain.
///
/// **Restraint (Rule #2 / #4 / #16).** Lean monochrome; status green only
/// for a genuinely confirmed result, status orange only for a genuine
/// revert, brand mark (never alarming red) for pending. Liquid Glass on the
/// Done CTA via the system `UniButton`; opaque native `List` rows for the
/// content register (content is opaque, chrome is glass — B.3).
private struct SwapDoneView: View {
    let summary: SwapReviewSummary
    let executed: SwapExecutor.Executed
    let isBridge: Bool
    let currencyCode: String
    let onDone: () -> Void

    /// The moment this receipt was assembled — the swap's completion time
    /// (captured once when the view first appears). Honest: it stamps when
    /// the result landed, not a fabricated on-chain timestamp.
    @State private var completedAt = Date()
    @State private var didCopy: Bool = false
    @State private var copiedAt: Date?
    @State private var copyResetTask: Task<Void, Never>?

    private var quote: SwapQuote { summary.quote }

    private var isConfirmed: Bool { executed.confirmed == true }
    private var isReverted: Bool { executed.confirmed == false }
    private var isPending: Bool { executed.confirmed == nil }

    private var explorerURL: URL? {
        TransactionExplorer.url(for: executed.txHash, chain: executed.chain)
    }

    var body: some View {
        // The status hero sits ABOVE a native inset-grouped List (the
        // Settings.app register the user expects), with the Done CTA pinned
        // at the bottom. Content is the opaque List; chrome is the glass CTA
        // (Rule #2 §B.3). The List IS the on-system content pattern
        // (Rule #3 — system controls before custom).
        VStack(spacing: 0) {
            hero
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.l)
            detailList
        }
        .background(UniColors.Background.primary)
        .safeAreaInset(edge: .bottom) { doneBar }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .uniHaptic(.success, trigger: copiedAt)
        .onDisappear { copyResetTask?.cancel() }
    }

    // MARK: - Detail list (native inset-grouped register)

    /// Every breakdown row, as native grouped-`List` sections: the from→to
    /// transfer, the verbatim quote breakdown, the tx hash / time /
    /// explorer, and — on a confirmed swap — the received-token note. The
    /// figures are identical to the prior card register; only the surface is
    /// now native iOS.
    private var detailList: some View {
        List {
            transferSection
            quoteSection
            transactionListSection
            if isConfirmed { receivedSection }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .scrollIndicators(.hidden)
    }

    private var navTitle: LocalizedStringKey {
        if isReverted { return "Receipt" }
        if isPending { return isBridge ? "Bridge submitted" : "Swap submitted" }
        return "Receipt"
    }

    // MARK: - Status hero

    private var hero: some View {
        VStack(spacing: UniSpacing.xs) {
            Image(systemName: heroSymbol)
                .font(.system(size: 54, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(heroColor)
                .symbolEffect(.bounce, options: .nonRepeating)
                .accessibilityHidden(true)
                .padding(.bottom, UniSpacing.xxs)
            UniLargeTitle(text: heroTitle, alignment: .center)
            if isConfirmed {
                Text(verbatim: "+\(WalletFormatting.native(quote.toAmount, decimals: quote.toToken.decimals)) \(quote.toToken.symbol)")
                    .font(.system(.title2, design: .rounded, weight: .semibold).monospacedDigit())
                    .foregroundStyle(UniColors.Status.successForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .environment(\.layoutDirection, .leftToRight)
                    .padding(.top, UniSpacing.xxs)
            }
            UniBody(text: heroBody, alignment: .center, color: UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, UniSpacing.xxs)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, UniSpacing.xs)
    }

    private var heroSymbol: String {
        if isReverted { return "xmark.circle.fill" }
        if isPending { return "clock.badge.checkmark" }
        return "checkmark.circle.fill"
    }

    private var heroColor: Color {
        if isReverted { return UniColors.Status.warningForeground }
        if isPending { return UniColors.Brand.mark }
        return UniColors.Status.successForeground
    }

    private var heroTitle: LocalizedStringKey {
        if isReverted { return isBridge ? "Bridge reverted" : "Swap reverted" }
        if isPending { return "Submitted" }
        return isBridge ? "Bridged" : "Swapped"
    }

    private var heroBody: LocalizedStringKey {
        if isReverted {
            return "The transaction was submitted but reverted on-chain. Nothing was swapped — your funds didn't move."
        }
        if isPending {
            return "Submitted to the \(executed.chain.displayName) network. Confirming may take a moment — check the explorer for the final result."
        }
        return isBridge
            ? "Your funds are on their way. A bridge can take a few minutes to arrive on the destination network."
            : "Broadcast to \(executed.chain.displayName) and confirmed on-chain."
    }

    // MARK: - Detail section (the swap, restated honestly) — list sections

    /// On a confirmed swap this section reports what happened; on a
    /// reverted/pending result it honestly reads as "this is what you
    /// submitted" (Rule #16 — the figures are the user's, not a claim it
    /// settled).
    private var detailLabel: LocalizedStringKey {
        if isConfirmed { return isBridge ? "Bridge" : "Swap" }
        return isBridge ? "Bridge you submitted" : "Swap you submitted"
    }

    /// The from → to transfer + slippage/network rows, as one grouped
    /// section.
    private var transferSection: some View {
        Section {
            transferRow(
                token: quote.fromToken,
                amount: summary.fromAmount,
                caption: "You paid",
                signPrefix: "−"
            )
            .listRowBackground(UniColors.Background.secondary)
            transferRow(
                token: quote.toToken,
                amount: quote.toAmount,
                caption: isConfirmed ? "You received" : "You receive (estimated)",
                signPrefix: "+"
            )
            .listRowBackground(UniColors.Background.secondary)
            listRow(label: "Max slippage", value: SwapComposeModel.slippageLabel(bps: summary.slippageBps))
            listRow(label: "Network", value: executed.chain.displayName)
        } header: {
            sectionHeader(detailLabel)
        }
    }

    /// The verbatim provider breakdown, as its own grouped section of plain
    /// label/value rows (the same figures `SwapQuotePanel` shows on the
    /// compose/review surfaces, now native list rows here).
    private var quoteSection: some View {
        Section {
            listRow(label: isBridge ? "Bridge" : "Route", value: routeText)
            listRow(label: "Rate", value: rateText)
            if let impact = quote.priceImpact {
                priceImpactRow(impact)
            }
            listRow(label: isBridge ? "Estimated time" : "Time", value: durationText)
            ForEach(quote.fees) { fee in
                // Fee names can be dynamic provider strings — verbatim label.
                listRowVerbatim(label: feeLabelText(fee), value: feeValueText(fee))
            }
            if quote.gasCostUSD > 0 && !hasExplicitGasFee {
                listRow(label: "Network fee",
                        value: "≈ \(WalletFormatting.fiat(quote.gasCostUSD, currencyCode: currencyCode))")
            }
            listRow(label: "Minimum received",
                    value: "\(WalletFormatting.native(quote.toAmountMin, decimals: quote.toToken.decimals)) \(quote.toToken.symbol)")
        } header: {
            sectionHeader("Quote")
        }
    }

    private func transferRow(token: SwapToken, amount: Decimal, caption: LocalizedStringKey, signPrefix: String) -> some View {
        HStack(spacing: UniSpacing.s) {
            CoinMark(
                chain: token.chain,
                tokenSymbol: token.symbol,
                contract: token.isNative ? nil : token.address,
                customIconURL: token.logoURI
            )
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(caption)
                    .font(UniTypography.caption1)
                    .foregroundStyle(UniColors.Text.tertiary)
                Text(verbatim: token.chain.displayName)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
            }
            Spacer(minLength: UniSpacing.s)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: "\(signPrefix)\(WalletFormatting.native(amount, decimals: token.decimals))")
                    .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(verbatim: token.symbol)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
            }
            .environment(\.layoutDirection, .leftToRight)
        }
    }

    // MARK: - Quote-breakdown derived text (mirrors SwapQuotePanel, honest)

    /// Price impact above this fraction reads as a real warning (1%).
    private static let highImpactThreshold = Decimal(0.01)

    private func priceImpactRow(_ impact: Decimal) -> some View {
        let isHigh = impact >= Self.highImpactThreshold
        let pct = impact * 100
        return HStack(alignment: .firstTextBaseline, spacing: UniSpacing.s) {
            Text("Price impact")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            HStack(spacing: UniSpacing.xxs) {
                if isHigh {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                }
                Text(verbatim: "\(WalletFormatting.native(pct, decimals: 2))%")
                    .monospacedDigit()
            }
            .font(UniTypography.body)
            .foregroundStyle(isHigh ? UniColors.Status.warningForeground : UniColors.Text.primary)
            .environment(\.layoutDirection, .leftToRight)
        }
        .listRowBackground(UniColors.Background.secondary)
    }

    private var rateText: String {
        let formatted = WalletFormatting.native(quote.rate, decimals: min(quote.toToken.decimals, 6))
        return "1 \(quote.fromToken.symbol) = \(formatted) \(quote.toToken.symbol)"
    }

    private var routeText: String {
        if isBridge {
            let name = quote.bridgeName ?? quote.toolName
            return "via \(name.capitalized)"
        }
        return "via \(quote.toolName.capitalized)"
    }

    private var durationText: String {
        let seconds = quote.estimatedDurationSeconds
        if seconds < 60 { return "~\(max(seconds, 1))s" }
        let minutes = (seconds + 30) / 60
        return "~\(minutes) min"
    }

    private func feeLabelText(_ fee: SwapFee) -> String {
        switch fee.kind {
        case .gas:         return String(localized: "Network fee")
        case .bridge:      return fee.name.isEmpty ? String(localized: "Bridge fee") : fee.name
        case .protocolFee: return fee.name.isEmpty ? String(localized: "Protocol fee") : fee.name
        }
    }

    private func feeValueText(_ fee: SwapFee) -> String {
        if fee.amountUSD > 0 {
            return "≈ \(WalletFormatting.fiat(fee.amountUSD, currencyCode: currencyCode))"
        }
        if let human = fee.amountDecimal, human > 0 {
            let suffix = fee.tokenSymbol.isEmpty ? "" : " \(fee.tokenSymbol)"
            return "\(WalletFormatting.native(human, decimals: WalletFormatting.maxDisplayFractionDigits))\(suffix)"
        }
        return "—"
    }

    private var hasExplicitGasFee: Bool {
        quote.fees.contains { $0.kind == .gas }
    }

    // MARK: - Transaction section — list

    private var transactionListSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: UniSpacing.s) {
                Text("Hash")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.secondary)
                Spacer(minLength: UniSpacing.s)
                Text(verbatim: WalletFormatting.shortAddress(executed.txHash, prefix: 8, suffix: 6))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
                    .lineLimit(1)
                    .truncationMode(.middle)
                copyButton
            }
            .listRowBackground(UniColors.Background.secondary)

            listRow(label: "Time", value: timestampText)

            if let explorerURL {
                Link(destination: explorerURL) {
                    HStack(spacing: UniSpacing.xs) {
                        Text("View on explorer")
                            .font(UniTypography.body)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(UniColors.Text.link)
                    .contentShape(Rectangle())
                }
                .listRowBackground(UniColors.Background.secondary)
            }
        } header: {
            sectionHeader("Transaction")
        }
    }

    /// Today → time only; otherwise a compact date + time. `Date.FormatStyle`
    /// (Rule #3 — no hand-rolled formatting).
    private var timestampText: String {
        if Calendar.current.isDateInToday(completedAt) {
            return completedAt.formatted(date: .omitted, time: .shortened)
        }
        return completedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var copyButton: some View {
        Button {
            copyHash()
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(didCopy ? UniColors.Status.successForeground : UniColors.Text.link)
        .accessibilityLabel(Text("Copy transaction hash"))
    }

    // MARK: - Received-token note (confirmed only) — list section

    /// Only on a confirmed swap — the executor auto-adds the received token
    /// to your tokens on success (Rule #16 — honest about what landed).
    private var receivedSection: some View {
        Section {
            Label {
                Text("\(quote.toToken.symbol) was added to your tokens.")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.secondary)
            } icon: {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(UniColors.Status.successForeground)
            }
            .listRowBackground(UniColors.Background.secondary)
        }
    }

    // MARK: - List row + header primitives

    /// A plain grouped-list label → value row, on the secondary row fill.
    /// Values are monospaced-digit + LTR-locked (Rule #11 §C — figures).
    private func listRow(label: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UniSpacing.s) {
            Text(label)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            Text(verbatim: value)
                .font(UniTypography.body.monospacedDigit())
                .foregroundStyle(UniColors.Text.primary)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
                .environment(\.layoutDirection, .leftToRight)
        }
        .listRowBackground(UniColors.Background.secondary)
    }

    /// Same as `listRow`, but the label is a verbatim runtime `String`
    /// (provider fee names) rather than a localizable literal key.
    private func listRowVerbatim(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: UniSpacing.s) {
            Text(verbatim: label)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            Text(verbatim: value)
                .font(UniTypography.body.monospacedDigit())
                .foregroundStyle(UniColors.Text.primary)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
                .environment(\.layoutDirection, .leftToRight)
        }
        .listRowBackground(UniColors.Background.secondary)
    }

    private func sectionHeader(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(UniTypography.footnote)
            .foregroundStyle(UniColors.Text.tertiary)
            .textCase(.uppercase)
    }

    // MARK: - Done bar

    private var doneBar: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            UniButton(title: "Done", variant: .primary, action: onDone)
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.s)
                .padding(.bottom, UniSpacing.xs)
        }
    }

    private func copyHash() {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: executed.txHash]],
            options: [.expirationDate: Date().addingTimeInterval(120)]
        )
        withAnimation(.easeInOut(duration: 0.2)) { didCopy = true }
        copiedAt = Date()
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { didCopy = false }
        }
    }
}

// MARK: - Failed state

/// The honest failure surface. Shows the executor's typed `ExecError.message`
/// verbatim (Rule #16 — name what happened, already a user-facing sentence),
/// and makes plain whether anything was swapped. The user stays in the flow
/// and can retry from Review.
private struct SwapFailedView: View {
    let error: SwapExecutor.ExecError
    let onRetry: () -> Void
    let onClose: () -> Void

    /// `true` when we can honestly say nothing was swapped. Every failure but
    /// an ambiguous broadcast qualifies (the executor only reaches broadcast
    /// after a clean sign, and a definitive node rejection never relayed).
    /// `.broadcastAmbiguous` left the device but got no accept/reject, so we
    /// must NOT claim the funds are safe there.
    private var nothingWasSwapped: Bool {
        if case .broadcastAmbiguous = error { return false }
        return true
    }

    var body: some View {
        // Hero above a native inset-grouped List carrying the honest failure
        // copy, CTA bar pinned at the bottom (Rule #2 §B.3 — opaque content,
        // glass chrome; Rule #3 — system List).
        VStack(spacing: 0) {
            hero
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.xl)
            messageList
        }
        .background(UniColors.Background.primary)
        .safeAreaInset(edge: .bottom) { actionBar }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    private var hero: some View {
        VStack(spacing: UniSpacing.s) {
            Image(systemName: isRefusal ? "lock.shield" : "exclamationmark.triangle")
                .font(.system(size: 52, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isRefusal ? UniColors.Brand.mark : UniColors.Status.warningForeground)
                .accessibilityHidden(true)
            UniLargeTitle(text: failureTitle, alignment: .center)
        }
    }

    /// A custody / quote-state refusal reads as a calm boundary, not an alarm
    /// — it's the wallet protecting the user. Brand mark + a measured title.
    private var isRefusal: Bool {
        switch error {
        case .noWallet, .quoteExpired, .missingExecutionData, .unsupported:
            return true
        default:
            return false
        }
    }

    private var failureTitle: LocalizedStringKey {
        isRefusal ? "Can't swap" : "Swap failed"
    }

    private var messageList: some View {
        List {
            Section {
                Text(verbatim: error.message)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(UniColors.Background.secondary)
                if nothingWasSwapped {
                    Label {
                        Text("Nothing was swapped — your funds didn't move.")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Text.secondary)
                    } icon: {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(UniColors.Status.successForeground)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(UniColors.Background.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .scrollIndicators(.hidden)
    }

    private var actionBar: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            VStack(spacing: UniSpacing.xs) {
                UniButton(title: "Try again", variant: .primary, action: onRetry)
                UniButton(title: "Close", variant: .tertiary, action: onClose)
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.xs)
        }
    }
}

// MARK: - Passphrase sheet

/// Collects the BIP-39 passphrase for a passphrase-protected wallet before
/// the swap (Rule #15 native sheet; Rule #17 — the executor refuses without
/// it rather than signing the wrong key). Secure entry; the value is held
/// only for the duration of the swap and dropped after.
private struct SwapPassphraseSheet: View {
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var passphrase: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                VStack(alignment: .leading, spacing: UniSpacing.s) {
                    Image(systemName: "key.horizontal")
                        .font(.system(size: 40, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(UniColors.Brand.mark)
                        .accessibilityHidden(true)
                    UniBody(
                        text: "This wallet has a passphrase. Enter it to sign — it never leaves this iPhone, and Aperture can't recover it for you.",
                        color: UniColors.Text.secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                UniTextField(
                    placeholder: "Passphrase",
                    text: $passphrase,
                    isSecure: true
                )
                Spacer()
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.m)
            .navigationTitle("Passphrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign") { onSubmit(passphrase) }
                        .fontWeight(.semibold)
                        .disabled(passphrase.isEmpty)
                }
            }
        }
    }
}
