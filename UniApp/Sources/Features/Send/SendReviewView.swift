import SwiftUI
import UniformTypeIdentifiers

/// Send · Step 5 — Review + real send. Shows the complete, validated
/// `SendDraft` honestly (asset, network, from, each recipient + amount,
/// total, fee + fiat, any memo/tag/OP_RETURN/reserve note), then commits
/// the transaction through the real signing + broadcast engine
/// (`SendExecutor`).
///
/// **The flow (Rule #16 — honest at every step).**
/// 1. **Review** — every figure is real; the primary action is a genuine
///    **Send** CTA.
/// 2. **Authenticate** — signing is a high-stakes commit (Rule #17). When
///    biometrics are enabled we present the system Face ID / Touch ID
///    prompt; on its absence or refusal we fall back to the canonical
///    `PinCodeView(mode: .verify)`. A wallet with no PIN and no biometrics
///    (Rule #17's optional-PIN path) goes straight through.
/// 3. **Passphrase** — a BIP-39 passphrase wallet (`hasPassphrase`) is
///    asked for its passphrase in a native sheet (Rule #15) before the
///    executor runs; without it the engine refuses with `.secretUnavailable`
///    rather than signing the wrong key.
/// 4. **Sending** — a calm progress state; the heavy sign/broadcast runs
///    off-main inside the executor (Rule #28).
/// 5. **Sent** — the REAL transaction hash (short form + copy + a "View on
///    explorer" link), `.success` haptic, and a Done that dismisses the
///    whole Send flow. The hash is never fabricated (Rule #16).
/// 6. **Failed** — the executor's typed `SigningError.userMessage` shown
///    verbatim, `.error` haptic, and a Retry back to Review. The copy makes
///    plain whether anything was sent (a pre-broadcast failure moved
///    nothing).
struct SendReviewView: View {
    let draft: SendDraft
    let currencyCode: String
    let assetUnitPrice: Decimal?
    let nativeUnitPrice: Decimal?
    /// The signing wallet's UUID — the executor needs this (the draft's
    /// `fromAddress` identifies the address, not the wallet).
    let walletId: UUID
    /// Whether the signing wallet has a BIP-39 passphrase. When `true`,
    /// the passphrase sheet is presented after auth and before the send.
    let walletHasPassphrase: Bool
    /// Close the whole Send flow (the sheet).
    let onClose: () -> Void

    @AppStorage("biometricEnabled") private var biometricEnabled: Bool = false

    /// The send state machine. `.review` is the resting state.
    @State private var phase: Phase = .review
    /// Drives the success haptic (set once when the send lands).
    @State private var sentAt: Date?
    /// Drives the error haptic (bumped on each failure).
    @State private var failedTrigger: Int = 0
    /// The PIN-fallback presentation (full-screen, the canonical surface).
    @State private var isShowingPinVerify: Bool = false
    /// The passphrase prompt presentation.
    @State private var isShowingPassphrase: Bool = false
    /// The collected passphrase, held only for the duration of the send.
    @State private var passphrase: String = ""
    /// The in-flight biometric authentication, cancellable on disappear.
    @State private var authTask: Task<Void, Never>?
    /// The in-flight send, cancellable on disappear.
    @State private var sendTask: Task<Void, Never>?

    private enum Phase: Equatable {
        case review
        /// Auth prompt is up (biometric or PIN) — the CTA shows a spinner.
        case authenticating
        /// Signing + broadcasting (off-main in the executor).
        case sending
        case sent(SendExecutor.SentTransaction)
        case failed(SigningError)
    }

    private var chain: SupportedChain { draft.chain }
    private var assetSymbol: String { draft.tokenSymbol ?? chain.ticker }

    var body: some View {
        Group {
            switch phase {
            case .sent(let tx):
                SendSentView(
                    transaction: tx,
                    amount: WalletFormatting.native(draft.totalAmount, decimals: draft.effectiveDecimals),
                    assetSymbol: assetSymbol,
                    recipient: draft.recipients.first?.name
                        ?? WalletFormatting.shortAddress(draft.recipients.first?.address ?? "", prefix: 8, suffix: 6),
                    onDone: onClose
                )
            case .failed(let error):
                SendFailedView(error: error, onRetry: resetToReview, onClose: onClose)
            default:
                reviewContent
            }
        }
        .uniHaptic(.success, trigger: sentAt)
        .uniHaptic(.error, trigger: failedTrigger)
        .onDisappear {
            authTask?.cancel()
            sendTask?.cancel()
            // Drop the passphrase from memory the moment the flow ends.
            passphrase = ""
        }
    }

    // MARK: - Review content (resting + in-flight states)

    private var reviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                amountHero
                detailsCard
                if hasExtras { extrasCard }
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
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isWorking)
        .toolbar {
            ToolbarItem(placement: .principal) {
                CoinTitleBar(chain: chain, tokenSymbol: draft.tokenSymbol, verb: "Review")
            }
        }
        .fullScreenCover(isPresented: $isShowingPinVerify) {
            pinVerifyCover
        }
        .sheet(isPresented: $isShowingPassphrase) {
            SendPassphraseSheet(
                onSubmit: { entered in
                    passphrase = entered
                    isShowingPassphrase = false
                    startSend()
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
        phase == .authenticating || phase == .sending
    }

    // MARK: - Amount hero

    private var amountHero: some View {
        VStack(spacing: UniSpacing.xs) {
            Text(verbatim: "\(WalletFormatting.native(draft.totalAmount, decimals: draft.effectiveDecimals)) \(assetSymbol)")
                .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let price = assetUnitPrice, price > 0 {
                Text(verbatim: WalletFormatting.fiat(draft.totalAmount * price, currencyCode: currencyCode))
                    .font(UniTypography.callout.monospacedDigit())
                    .foregroundStyle(UniColors.Text.tertiary)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UniSpacing.m)
    }

    // MARK: - Details

    private var detailsCard: some View {
        UniCard(padding: 0) {
            VStack(spacing: 0) {
                detailRow("Network", value: chain.displayName)
                divider
                detailRow("From", value: WalletFormatting.shortAddress(draft.fromAddress, prefix: 8, suffix: 6), mono: true)
                divider
                recipientRows
                divider
                feeRow
            }
        }
    }

    @ViewBuilder
    private var recipientRows: some View {
        if draft.recipients.count == 1, let r = draft.recipients.first {
            detailRow("To", value: r.name ?? WalletFormatting.shortAddress(r.address, prefix: 8, suffix: 6), mono: r.name == nil)
        } else {
            ForEach(Array(draft.recipients.enumerated()), id: \.offset) { offset, r in
                multiRecipientRow(index: offset + 1, recipient: r)
                if offset < draft.recipients.count - 1 { divider }
            }
            divider
            detailRow("Total", value: "\(WalletFormatting.native(draft.totalAmount, decimals: draft.effectiveDecimals)) \(assetSymbol)", mono: true)
        }
    }

    private func multiRecipientRow(index: Int, recipient r: SendRecipientAmount) -> some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Text(verbatim: "\(index)")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
                .frame(width: 20, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: r.name ?? WalletFormatting.shortAddress(r.address, prefix: 8, suffix: 6))
                    .font(UniTypography.body.monospaced())
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: UniSpacing.s)
            Text(verbatim: "\(WalletFormatting.native(r.amount, decimals: draft.effectiveDecimals)) \(assetSymbol)")
                .font(UniTypography.callout.monospacedDigit())
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
    }

    private var feeRow: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Text("Network fee")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: "\(WalletFormatting.native(draft.fee.estimatedTotalNative, decimals: 8)) \(chain.ticker)")
                    .font(UniTypography.callout.monospacedDigit())
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
                if let price = nativeUnitPrice, price > 0 {
                    Text(verbatim: WalletFormatting.fiat(draft.fee.estimatedTotalNative * price, currencyCode: currencyCode))
                        .font(UniTypography.caption1.monospacedDigit())
                        .foregroundStyle(UniColors.Text.tertiary)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Text(verbatim: draft.fee.tier.label)
                    .font(UniTypography.caption2)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
    }

    // MARK: - Extras (memo / tag / comment / op_return / max)

    private var hasExtras: Bool { !extras.isEmpty }

    /// One extra row's content, resolved into a stable, order-preserving
    /// list so the card can interleave dividers without ViewBuilder
    /// statement gymnastics.
    private struct Extra: Identifiable {
        let id = UUID()
        let key: LocalizedStringKey
        let value: String
    }

    private var extras: [Extra] {
        var rows: [Extra] = []
        if let memo = memoSummary {
            rows.append(Extra(key: memoLabel, value: memo))
        }
        if let data = draft.opReturn, let text = String(data: data, encoding: .utf8), !text.isEmpty {
            rows.append(Extra(key: "OP_RETURN", value: text))
        }
        if let utxos = draft.selectedUTXOs, !utxos.isEmpty, chain.family == .bitcoin {
            rows.append(Extra(key: "Coins", value: String(localized: "\(utxos.count) selected")))
        }
        if draft.isMaxSend {
            rows.append(Extra(key: "Amount", value: String(localized: "Sending the maximum")))
        }
        return rows
    }

    private var extrasCard: some View {
        UniCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(extras.enumerated()), id: \.element.id) { offset, extra in
                    extraRow(extra.key, value: extra.value)
                    if offset < extras.count - 1 { divider }
                }
            }
        }
    }

    private var memoLabel: LocalizedStringKey {
        switch draft.chain.family {
        case .ripple: return "Destination tag"
        case .ton:    return "Comment"
        default:      return "Memo"
        }
    }

    private var memoSummary: String? {
        switch draft.memo {
        case .none: return nil
        case .destinationTag(let t): return String(t)
        case .tonComment(let s), .splMemo(let s), .text(let s):
            return s.isEmpty ? nil : s
        case .stellarMemo(let m):
            switch m {
            case .text(let s): return s.isEmpty ? nil : s
            case .id(let i): return String(i)
            case .hashHex(let h): return h.isEmpty ? nil : h
            }
        }
    }

    // MARK: - Self-custody note (Rule #16 — restate at the moment of commit)

    private var selfCustodyNote: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: "lock.shield")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(UniColors.Icon.secondary)
                .accessibilityHidden(true)
            Text("Aperture signs this on your iPhone and broadcasts it to the network. Once it's sent, it can't be reversed.")
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

    // MARK: - Action bar (real Send CTA)

    private var actionBar: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            UniButton(
                title: sendTitle,
                variant: .primary,
                isLoading: isWorking,
                isEnabled: !isWorking,
                action: beginSend
            )
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.xs)
        }
    }

    private var sendTitle: LocalizedStringKey {
        switch phase {
        case .authenticating: return "Confirming…"
        case .sending:        return "Sending…"
        default:              return "Send"
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
                // A forgotten PIN can't be reset (Rule #16). Cancel the
                // send and return the user to Review; the forgot path
                // lives in the lock screen, not mid-send.
                isShowingPinVerify = false
                phase = .review
            }
        )
        .background(UniColors.Background.primary.ignoresSafeArea())
        .uniAppEnvironment()
    }

    // MARK: - Flow

    /// Entry point from the Send CTA. Decides the auth path: biometric →
    /// PIN fallback → (no PIN, no biometric) straight through.
    private func beginSend() {
        guard phase == .review else { return }
        // The commit haptic fires from `UniButton(.primary)` itself
        // (Rule #10 §E → `.contextualImpact(.commit)`); adding another
        // here would double-fire (M-002 family). The `.success` /
        // `.error` beats on landing are fired via the body's
        // `.uniHaptic(...)` triggers below.
        phase = .authenticating

        if biometricEnabled {
            authTask?.cancel()
            authTask = Task { @MainActor in
                let outcome = await BiometricService().authenticate(
                    reason: LocalizedStringResource("Confirm to send this transaction.")
                )
                guard !Task.isCancelled else { return }
                switch outcome {
                case .success:
                    afterAuthSuccess()
                case .failure(.unavailable):
                    // Biometrics unexpectedly unavailable — fall back to
                    // the PIN if one is set, otherwise proceed (Rule #17
                    // optional-PIN).
                    routeToPinOrProceed()
                case .failure(.userCancelled), .failure(.authenticationFailed):
                    routeToPinOrProceed()
                case .failure(.systemError):
                    routeToPinOrProceed()
                }
            }
        } else {
            routeToPinOrProceed()
        }
    }

    /// After a biometric failure / when biometrics are off: require the
    /// PIN if one exists, otherwise (Rule #17 optional-PIN) proceed.
    private func routeToPinOrProceed() {
        if PinCodeStorage.hasPin {
            isShowingPinVerify = true
        } else {
            afterAuthSuccess()
        }
    }

    /// Auth has succeeded. Collect the passphrase if the wallet needs one,
    /// otherwise start the send.
    private func afterAuthSuccess() {
        if walletHasPassphrase {
            isShowingPassphrase = true
        } else {
            startSend()
        }
    }

    /// Run the real send through the executor (off-main heavy work inside
    /// it; this method only awaits and applies the result, Rule #28).
    private func startSend() {
        phase = .sending
        sendTask?.cancel()
        sendTask = Task { @MainActor in
            let pass = walletHasPassphrase ? passphrase : nil
            let result = await SendExecutor().execute(
                draft: draft, walletId: walletId, passphrase: pass
            )
            // Drop the passphrase from memory immediately after the send.
            passphrase = ""
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let tx):
                sentAt = Date()
                withAnimation(.smooth(duration: 0.35)) { phase = .sent(tx) }
            case .failure(let error):
                failedTrigger += 1
                withAnimation(.smooth(duration: 0.35)) { phase = .failed(error) }
            }
        }
    }

    private func resetToReview() {
        withAnimation(.smooth(duration: 0.3)) { phase = .review }
    }

    // MARK: - Row primitives

    private var divider: some View {
        UniDivider().padding(.leading, UniSpacing.m)
    }

    private func detailRow(_ key: LocalizedStringKey, value: String, mono: Bool = false) -> some View {
        HStack(spacing: UniSpacing.s) {
            Text(key)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            Text(verbatim: value)
                .font(mono ? UniTypography.body.monospaced() : UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
    }

    private func extraRow(_ key: LocalizedStringKey, value: String) -> some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Text(key)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            Text(verbatim: value)
                .font(UniTypography.callout)
                .foregroundStyle(UniColors.Text.primary)
                .multilineTextAlignment(.trailing)
                .environment(\.layoutDirection, .leftToRight)
                .lineLimit(3)
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
    }
}

// MARK: - Sent state

/// The honest success surface. Shows the REAL transaction hash (short
/// form), a copy affordance, and a "View on explorer" link to the chain's
/// canonical explorer for this hash (Rule #16 — the hash is real and the
/// user can verify it on a third-party surface they trust).
private struct SendSentView: View {
    let transaction: SendExecutor.SentTransaction
    let amount: String
    let assetSymbol: String
    let recipient: String
    let onDone: () -> Void

    @State private var didCopy: Bool = false
    @State private var copiedAt: Date?
    @State private var copyResetTask: Task<Void, Never>?

    private var explorerURL: URL? {
        TransactionExplorer.url(for: transaction.txHash, chain: transaction.chain)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: UniSpacing.l) {
                    hero
                    summaryCard
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
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Status.successForeground)
                .symbolEffect(.bounce, options: .nonRepeating)
                .accessibilityHidden(true)
            UniLargeTitle(text: "Sent", alignment: .center)
            Text(verbatim: "\(amount) \(assetSymbol)")
                .font(UniTypography.title3.monospacedDigit())
                .foregroundStyle(UniColors.Text.secondary)
                .environment(\.layoutDirection, .leftToRight)
            UniBody(
                text: "Broadcast to the \(transaction.chain.displayName) network. It'll confirm on-chain in a moment.",
                alignment: .center,
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summaryCard: some View {
        UniCard(padding: 0) {
            VStack(spacing: 0) {
                row("To", value: recipient, mono: true)
                UniDivider().padding(.leading, UniSpacing.m)
                row("Network", value: transaction.chain.displayName)
            }
        }
    }

    private var hashCard: some View {
        UniCard {
            VStack(alignment: .leading, spacing: UniSpacing.s) {
                Text("Transaction")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                HStack(spacing: UniSpacing.s) {
                    Text(verbatim: WalletFormatting.shortAddress(transaction.txHash, prefix: 10, suffix: 8))
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
            [[UTType.plainText.identifier: transaction.txHash]],
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

    private func row(_ key: LocalizedStringKey, value: String, mono: Bool = false) -> some View {
        HStack(spacing: UniSpacing.s) {
            Text(key)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            Text(verbatim: value)
                .font(mono ? UniTypography.body.monospaced() : UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
    }
}

// MARK: - Failed state

/// The honest failure surface. Shows the executor's typed error message
/// verbatim (Rule #16 — name what happened), and — for a pre-broadcast
/// failure — makes plain that nothing was sent. Retry returns to Review.
private struct SendFailedView: View {
    let error: SigningError
    let onRetry: () -> Void
    let onClose: () -> Void

    /// `true` when we can honestly say the funds did NOT move. Every
    /// pre-broadcast failure qualifies (the executor only reaches broadcast
    /// after a clean sign), AND a definitive node rejection
    /// (`.broadcastFailed` — a structured decode/validation/nonce/fee
    /// error) means the tx never relayed. ONLY `.broadcastAmbiguous`
    /// (transport failure or an unparseable response — the request left
    /// the device but no accept/reject came back) leaves the outcome
    /// unknown, so we must NOT claim the funds are safe there; its
    /// `userMessage` already tells the user to check the explorer (Rule #16).
    private var nothingWasSent: Bool {
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
                .foregroundStyle(isRefusal ? UniColors.Brand.mark : UniColors.Status.errorForeground)
                .accessibilityHidden(true)
            UniLargeTitle(text: failureTitle, alignment: .center)
        }
    }

    /// Custody refusals (watch-only, secret unavailable, key mismatch) read
    /// as a calm boundary, not an alarm — they're the wallet protecting the
    /// user, not a system error. Brand mark + a measured title.
    private var isRefusal: Bool {
        switch error {
        case .walletCannotSign, .secretUnavailable, .keyAddressMismatch,
             .invalidMnemonic, .invalidPrivateKey, .noWallet:
            return true
        default:
            return false
        }
    }

    private var failureTitle: LocalizedStringKey {
        isRefusal ? "Can't send" : "Send failed"
    }

    private var messageCard: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            Text(verbatim: error.userMessage)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
            if nothingWasSent {
                Label {
                    Text("Nothing was sent — your funds didn't move.")
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
                .fill(nothingWasSent ? UniColors.Fill.quaternary : UniColors.Status.errorBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .stroke(nothingWasSent ? Color.clear : UniColors.Status.errorStroke, lineWidth: 1)
        )
    }

    private var actionBar: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            VStack(spacing: UniSpacing.xs) {
                if canRetry {
                    UniButton(title: "Try again", variant: .primary, action: onRetry)
                }
                UniButton(title: canRetry ? "Close" : "Done", variant: canRetry ? .tertiary : .primary, action: onClose)
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.xs)
        }
    }

    /// A custody refusal won't change by retrying (a watch-only wallet
    /// stays watch-only); those surfaces offer only a way out. Build /
    /// network / broadcast failures are retryable.
    private var canRetry: Bool {
        switch error {
        case .walletCannotSign, .secretUnavailable, .keyAddressMismatch,
             .invalidMnemonic, .invalidPrivateKey, .unsupportedCoin,
             .chainNotWired, .noWallet:
            return false
        default:
            return true
        }
    }
}

// MARK: - Passphrase sheet

/// Collects the BIP-39 passphrase for a passphrase-protected wallet before
/// the send (Rule #15 native sheet; Rule #17 — the executor refuses without
/// it rather than signing the wrong key). Secure entry; the value is held
/// only for the duration of the send and dropped after.
private struct SendPassphraseSheet: View {
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
