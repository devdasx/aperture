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
            case .done(let executed):
                SwapDoneView(
                    executed: executed,
                    isBridge: isBridge,
                    receivedAmount: WalletFormatting.native(quote.toAmount, decimals: quote.toToken.decimals),
                    receivedSymbol: quote.toToken.symbol,
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

    private var actionBar: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            VStack(spacing: UniSpacing.xs) {
                if isWorking, let status = statusLine {
                    Text(status)
                        .font(UniTypography.footnote.monospacedDigit())
                        .foregroundStyle(UniColors.Text.secondary)
                        .transition(.opacity)
                }
                UniButton(
                    title: ctaTitle,
                    variant: .primary,
                    isLoading: isWorking,
                    isEnabled: !isWorking,
                    action: beginSwap
                )
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.xs)
        }
    }

    /// Honest CTA label: "Swap" same-chain, "Bridge" cross-chain (Rule #16).
    private var ctaTitle: LocalizedStringKey {
        switch phase {
        case .authenticating:
            return "Confirming…"
        case .swapping:
            return isBridge ? "Bridging…" : "Swapping…"
        default:
            return isBridge ? "Bridge" : "Swap"
        }
    }

    /// The live, honest status under the CTA while the swap is in flight
    /// (Rule #25). Mirrors whatever executor phase has arrived.
    private var statusLine: LocalizedStringKey? {
        guard phase == .swapping else { return nil }
        switch execPhase {
        case .preparing:         return "Preparing…"
        case .checkingApproval:  return "Checking approval…"
        case .approving:         return "Approving \(quote.fromToken.symbol)…"
        case .confirmingApproval: return "Waiting for approval…"
        case .signing:           return "Signing…"
        case .broadcasting:      return "Submitting…"
        case .confirming:        return "Confirming…"
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

// MARK: - Done state

/// The honest result surface for a broadcast swap. Three faces, never
/// fabricated (Rule #16):
/// - `confirmed == true`  → "Swapped" / "Bridged" with the received amount.
/// - `confirmed == false` → submitted but reverted; nothing was swapped.
/// - `confirmed == nil`   → submitted; confirming may take a moment.
/// All three show the REAL tx hash (short + copy + a "View on explorer"
/// link). The received-token note appears only on a confirmed swap (the
/// executor auto-adds it only on success).
private struct SwapDoneView: View {
    let executed: SwapExecutor.Executed
    let isBridge: Bool
    let receivedAmount: String
    let receivedSymbol: String
    let onDone: () -> Void

    @State private var didCopy: Bool = false
    @State private var copiedAt: Date?
    @State private var copyResetTask: Task<Void, Never>?

    private var isConfirmed: Bool { executed.confirmed == true }
    private var isReverted: Bool { executed.confirmed == false }
    private var isPending: Bool { executed.confirmed == nil }

    private var explorerURL: URL? {
        TransactionExplorer.url(for: executed.txHash, chain: executed.chain)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: UniSpacing.l) {
                    hero
                    if isConfirmed { receivedNote }
                    hashCard
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.xl)
                .padding(.bottom, UniSpacing.xxl)
            }
            .scrollIndicators(.hidden)
        }
        .background(UniColors.Background.primary)
        .safeAreaInset(edge: .bottom) { doneBar }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .uniHaptic(.success, trigger: copiedAt)
        .onDisappear { copyResetTask?.cancel() }
    }

    private var hero: some View {
        VStack(spacing: UniSpacing.s) {
            Image(systemName: heroSymbol)
                .font(.system(size: 56, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(heroColor)
                .symbolEffect(.bounce, options: .nonRepeating)
                .accessibilityHidden(true)
            UniLargeTitle(text: heroTitle, alignment: .center)
            if isConfirmed {
                Text(verbatim: "\(receivedAmount) \(receivedSymbol)")
                    .font(UniTypography.title3.monospacedDigit())
                    .foregroundStyle(UniColors.Text.secondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
            UniBody(text: heroBody, alignment: .center, color: UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var heroSymbol: String {
        if isReverted { return "exclamationmark.triangle" }
        if isPending { return "clock" }
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
            return "Submitted to the \(executed.chain.displayName) network. Confirming on-chain may take a moment — check the explorer for the final result."
        }
        return isBridge
            ? "Your funds are on their way. A bridge can take a few minutes to arrive on the destination network."
            : "Broadcast to the \(executed.chain.displayName) network and confirmed on-chain."
    }

    /// Only shown on a confirmed swap — the executor auto-adds the received
    /// token to your tokens on success (Rule #16 — honest about what landed).
    private var receivedNote: some View {
        Label {
            Text("\(receivedSymbol) was added to your tokens.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
        } icon: {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(UniColors.Status.successForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UniSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(UniColors.Fill.quaternary)
        )
    }

    private var hashCard: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                Text("Transaction")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                HStack(spacing: UniSpacing.s) {
                    Text(verbatim: WalletFormatting.shortAddress(executed.txHash, prefix: 10, suffix: 8))
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(UniColors.Text.primary)
                        .environment(\.layoutDirection, .leftToRight)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: UniSpacing.s)
                    copyButton
                }
                if let explorerURL {
                    Link(destination: explorerURL) {
                        HStack(spacing: UniSpacing.xs) {
                            Image(systemName: "safari")
                                .font(.system(size: 14, weight: .semibold))
                            Text("View on explorer")
                                .font(UniTypography.subheadlineEmphasized)
                        }
                        .foregroundStyle(UniColors.Text.link)
                        .padding(.top, UniSpacing.xxs)
                        .contentShape(Rectangle())
                    }
                }
            }
        }
    }

    private var copyButton: some View {
        Button {
            copyHash()
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(didCopy ? UniColors.Status.successForeground : UniColors.Text.link)
        .accessibilityLabel(Text("Copy transaction hash"))
    }

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
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: UniSpacing.l) {
                    hero
                    messageCard
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.xl)
                .padding(.bottom, UniSpacing.xxl)
            }
            .scrollIndicators(.hidden)
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

    private var messageCard: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            Text(verbatim: error.message)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
            if nothingWasSwapped {
                Label {
                    Text("Nothing was swapped — your funds didn't move.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                } icon: {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(UniColors.Status.successForeground)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UniSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(nothingWasSwapped ? UniColors.Fill.quaternary : UniColors.Status.warningBackground)
        )
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
