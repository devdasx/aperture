import SwiftUI
import UIKit
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
    @Environment(\.balancePrivacyEnabled) private var hideBalances

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

    @GRDBStorage("biometricEnabled") private var biometricEnabled: Bool = false
    @GRDBStorage(PinCodePreference.requireBiometricForSendKey) private var requireForSend: Bool = true

    /// The send state machine. `.review` is the resting state.
    @State private var phase: Phase = .review
    /// Drives the success haptic (set once when the send lands).
    @State private var sentAt: Date?
    /// Drives the error haptic (bumped on each failure).
    @State private var failedTrigger: Int = 0
    /// The PIN-fallback presentation. Verify gates are native bottom sheets
    /// so the user can change their mind without leaving the send flow.
    @State private var isShowingPinVerify: Bool = false
    @State private var didCompletePinVerify: Bool = false
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
    private var localAmountText: String? {
        guard let price = assetUnitPrice, price > 0 else { return nil }
        return WalletFormatting.fiat(draft.totalAmount * price, currencyCode: currencyCode, hidden: hideBalances)
    }

    var body: some View {
        Group {
            switch phase {
            case .sent(let tx):
                SendSentView(
                    transaction: tx,
                    amount: WalletFormatting.native(draft.totalAmount, decimals: draft.effectiveDecimals, hidden: hideBalances),
                    localAmount: localAmountText,
                    assetSymbol: assetSymbol,
                    tokenContract: draft.tokenContract,
                    assetKind: draft.tokenSymbol == nil ? "Coin" : "Token",
                    recipient: draft.recipients.first?.name
                        ?? WalletFormatting.shortAddress(draft.recipients.first?.address ?? "", prefix: 8, suffix: 6),
                    senderAddress: draft.fromAddress,
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
        .uniBottomActionBar { actionBar }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isWorking)
        .toolbar {
            ToolbarItem(placement: .principal) {
                CoinTitleBar(chain: chain, tokenSymbol: draft.tokenSymbol, verb: "Review")
            }
        }
        .sheet(isPresented: $isShowingPinVerify, onDismiss: handlePinVerifyDismiss) {
            pinVerifySheet
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
            .apertureEnvironment()
            .uniSheetDetents([.medium])
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
            Text(verbatim: "\(WalletFormatting.native(draft.totalAmount, decimals: draft.effectiveDecimals, hidden: hideBalances)) \(assetSymbol)")
                .font(.system(size: 40, weight: .semibold, design: .default).monospacedDigit())
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let price = assetUnitPrice, price > 0 {
                Text(verbatim: WalletFormatting.fiat(draft.totalAmount * price, currencyCode: currencyCode, hidden: hideBalances))
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
            detailRow("Total", value: "\(WalletFormatting.native(draft.totalAmount, decimals: draft.effectiveDecimals, hidden: hideBalances)) \(assetSymbol)", mono: true)
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
            Text(verbatim: "\(WalletFormatting.native(r.amount, decimals: draft.effectiveDecimals, hidden: hideBalances)) \(assetSymbol)")
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
                Text(verbatim: "\(WalletFormatting.native(draft.fee.estimatedTotalNative, decimals: 8, hidden: hideBalances)) \(chain.ticker)")
                    .font(UniTypography.callout.monospacedDigit())
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
                if let price = nativeUnitPrice, price > 0 {
                    Text(verbatim: WalletFormatting.fiat(draft.fee.estimatedTotalNative * price, currencyCode: currencyCode, hidden: hideBalances))
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
        }
    }

    private var sendTitle: LocalizedStringKey {
        switch phase {
        case .authenticating: return "Confirming…"
        case .sending:        return "Sending…"
        default:              return "Send"
        }
    }

    // MARK: - PIN-fallback sheet

    private var pinVerifySheet: some View {
        NavigationStack {
            PinCodeView(
                mode: .verify,
                onComplete: { _ in
                    didCompletePinVerify = true
                    isShowingPinVerify = false
                    afterAuthSuccess()
                },
                onCancel: {
                    isShowingPinVerify = false
                    phase = .review
                },
                // Face ID auto-prompts here only when the user kept "Require
                // Face ID for sending" on; off → passcode-only (no biometric).
                allowsBiometrics: requireForSend,
                showsNavigationControls: false,
                accessContext: .signTransaction(
                    chain: chain,
                    symbol: assetSymbol,
                    contract: draft.tokenContract
                )
            )
        }
        .background(UniColors.Background.primary.ignoresSafeArea())
        .apertureEnvironment()
        .uniSheetDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(UniColors.Background.primary)
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

        // Unified auth: route through the ONE passcode screen. It auto-prompts
        // Face ID only when the in-app biometric toggle AND "Require Face ID
        // for sending" are both on — `pinVerifyCover` passes
        // `allowsBiometrics: requireForSend`, and the screen itself gates on
        // `biometricEnabled`. No raw OS Face ID prompt (2026-06-21 direction).
        routeToPinOrProceed()
    }

    /// After a biometric failure / when biometrics are off: require the
    /// PIN if one exists, otherwise (Rule #17 optional-PIN) proceed.
    private func routeToPinOrProceed() {
        if PinCodeStorage.hasPin {
            didCompletePinVerify = false
            isShowingPinVerify = true
        } else {
            afterAuthSuccess()
        }
    }

    private func handlePinVerifyDismiss() {
        guard !didCompletePinVerify, phase == .authenticating else { return }
        phase = .review
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    let transaction: SendExecutor.SentTransaction
    let amount: String
    let localAmount: String?
    let assetSymbol: String
    let tokenContract: String?
    let assetKind: String
    let recipient: String
    /// The sender's address — needed so the confirmation poll can resolve
    /// status on the chains whose tx lookup is address-scoped (TON, NEAR,
    /// XRPL, Stellar). Harmless for the chains that resolve by hash alone.
    let senderAddress: String
    let onDone: () -> Void

    @State private var didCopy: Bool = false
    @State private var copiedAt: Date?
    @State private var copyResetTask: Task<Void, Never>?
    @State private var isRenderingShareImage: Bool = false
    @State private var screenshotShareItem: SendSentScreenshotShareItem?
    @State private var screenshotShareFailed: Bool = false

    /// The live on-chain verdict, polled after the screen appears so the hero
    /// moves from "Confirming" to "Sent"/"Failed" the moment the chain reports
    /// back (Rule #25). Starts `.pending` — broadcast is not confirmation
    /// (Rule #16).
    @State private var status: TransactionConfirmation.Outcome = .pending
    /// Stamped when the poll resolves — drives the success / error haptic.
    @State private var resolvedAt: Date?

    private var explorerURL: URL? {
        TransactionExplorer.url(for: transaction.txHash, chain: transaction.chain)
    }

    private var isConfirmed: Bool { status == .confirmed }
    private var isFailed: Bool { status == .failed }
    private var isPending: Bool { status == .pending }

    var body: some View {
        List {
            Section {
                // Full-width row so the hero centers in the list, not just
                // within its intrinsic content width (List's default).
                hero
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, UniSpacing.l)
                    .padding(.top, UniSpacing.xl)
                    .padding(.bottom, UniSpacing.s)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            detailsSection
            transactionSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        // Native scroll clearance: inset the List (not an overlay). Overlay
        // Done bars never shrink list content size, so Share/Explorer sat
        // under the button and felt unscrollable.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            doneBar
                .frame(maxWidth: .infinity)
                .background(UniColors.Background.primary.opacity(0.001))
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .uniHaptic(.success, trigger: copiedAt)
        .uniHaptic(.success, trigger: isConfirmed ? resolvedAt : nil)
        .uniHaptic(.error, trigger: isFailed ? resolvedAt : nil)
        .task(id: transaction.txHash) { await pollForConfirmation() }
        .onDisappear { copyResetTask?.cancel() }
        .sheet(item: $screenshotShareItem) { item in
            SendSentScreenshotShareSheet(item: item)
        }
        .alert("Screenshot unavailable", isPresented: $screenshotShareFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Aperture couldn't prepare this receipt screenshot. Try again.")
        }
        .overlay {
            if isRenderingShareImage {
                ZStack {
                    UniColors.Background.primary.opacity(0.28)
                        .ignoresSafeArea()
                    ProgressView()
                        .controlSize(.large)
                        .tint(UniColors.Text.primary)
                }
                .transition(.opacity)
            }
        }
    }

    /// Probe the chain in a loop until confirmed/failed (or budget ends).
    /// Updates `status` on every tick so the hero stays on **Confirming**
    /// live, then flips to Sent/Failed (Rule #25 / #16).
    private func pollForConfirmation() async {
        guard !transaction.txHash.isEmpty else { return }
        // First probe quickly — Solana often finalizes in <2s; EVM shortly after.
        let firstDelay: Duration = transaction.chain == .solana ? .seconds(1) : .seconds(2)
        let interval: Duration = transaction.chain == .solana ? .seconds(2) : .seconds(5)
        let maxAttempts = 60
        var attempt = 0
        while attempt < maxAttempts {
            if Task.isCancelled { return }
            try? await Task.sleep(for: attempt == 0 ? firstDelay : interval)
            if Task.isCancelled { return }
            let outcome = await TransactionConfirmation.probe(
                txHash: transaction.txHash,
                chain: transaction.chain,
                address: senderAddress,
                tokenContract: tokenContract
            )
            status = outcome
            if outcome != .pending {
                resolvedAt = Date()
                return
            }
            attempt += 1
        }
        // Budget exhausted — stay on Confirming (honest, not a fake success).
        status = .pending
    }

    /// Hero stack. List rows hug content width unless expanded — without
    /// full-width + centered stack, icon/title/body sit slightly leading.
    private var hero: some View {
        VStack(spacing: UniSpacing.s) {
            Group {
                if isPending {
                    ProgressView()
                        .controlSize(.large)
                        .tint(heroColor)
                        .frame(width: 56, height: 56)
                } else {
                    Image(systemName: heroSymbol)
                        .font(.system(size: 56, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(heroColor)
                        .symbolEffect(.bounce, options: .nonRepeating)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)

            // Verbatim + full width so localization can't lag behind the
            // status machine and the title centers in the row.
            Text(verbatim: heroTitleText)
                .font(UniTypography.largeTitle)
                .foregroundStyle(UniColors.Copy.largeTitle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Text(verbatim: "\(amount) \(assetSymbol)")
                .font(UniTypography.title3.monospacedDigit())
                .foregroundStyle(UniColors.Text.secondary)
                .environment(\.layoutDirection, .leftToRight)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Text(verbatim: localAmount ?? "Local amount unavailable")
                .font(UniTypography.callout.monospacedDigit())
                .foregroundStyle(UniColors.Text.tertiary)
                .environment(\.layoutDirection, .leftToRight)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Text(verbatim: heroBodyText)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heroAccessibilityLabel)
    }

    private var heroSymbol: String {
        if isFailed { return "xmark.circle.fill" }
        return "checkmark.circle.fill"
    }

    private var heroColor: Color {
        if isFailed { return UniColors.Feedback.Warning.foreground }
        if isPending { return UniColors.Brand.mark }
        return UniColors.Feedback.Success.foreground
    }

    private var heroTitleText: String {
        if isFailed { return String.apertureLocalized("Failed") }
        if isPending { return String.apertureLocalized("Confirming") }
        return String.apertureLocalized("Sent")
    }

    private var heroBodyText: String {
        if isFailed {
            return String.apertureLocalized(
                "The transaction failed. If it reached the network, gas or fees may still have been spent."
            )
        }
        if isPending {
            return String.apertureLocalized(
                "Broadcast to the \(transaction.chain.displayName) network. Confirming may take a moment — you can safely leave this screen."
            )
        }
        return String.apertureLocalized(
            "Confirmed on the \(transaction.chain.displayName) network."
        )
    }

    private var heroAccessibilityLabel: String { heroTitleText }

    private var detailsSection: some View {
        Section {
            if assetKind == "Coin" {
                detailRow("Coin", value: assetSymbol)
            } else {
                detailRow("Token", value: assetSymbol)
            }
            detailRow("Amount", value: "\(amount) \(assetSymbol)", mono: true)
            detailRow("Local amount", value: localAmount ?? "Unavailable", mono: localAmount != nil)
            detailRow("To", value: recipient, mono: true)
            detailRow("Network", value: transaction.chain.displayName)
        } header: {
            Text("Details")
        }
    }

    private var transactionSection: some View {
        Section {
            transactionHashRow
            Button {
                shareScreenshot()
            } label: {
                Label(
                    isRenderingShareImage ? "Preparing Screenshot" : "Share Screenshot",
                    systemImage: "photo.on.rectangle.angled"
                )
                .foregroundStyle(UniColors.Text.link)
            }
            .disabled(isRenderingShareImage)
            .accessibilityLabel(Text("Share screenshot"))

            if let explorerURL {
                Link(destination: explorerURL) {
                    Label("View on Explorer", systemImage: "safari")
                        .foregroundStyle(UniColors.Text.link)
                }
            }
        } header: {
            Text("Transaction")
        }
    }

    private var transactionHashRow: some View {
        LabeledContent {
            HStack(spacing: UniSpacing.s) {
                Text(verbatim: WalletFormatting.shortAddress(transaction.txHash, prefix: 10, suffix: 8))
                    .font(.body.monospaced())
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
                    .lineLimit(1)
                    .truncationMode(.middle)
                copyButton
            }
        } label: {
            Text("Hash")
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
        .foregroundStyle(didCopy ? UniColors.Feedback.Success.foreground : UniColors.Text.link)
        .accessibilityLabel(Text("Copy transaction hash"))
    }

    private var doneBar: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            UniButton(title: "Done", variant: .primary, action: onDone)
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.s)
        }
    }

    @MainActor
    private func shareScreenshot() {
        guard !isRenderingShareImage else { return }
        ReceiptScreenshotFlash.play()
        isRenderingShareImage = true
        defer { isRenderingShareImage = false }

        let receipt = SendSentScreenshotReceipt(
            chain: transaction.chain,
            tokenSymbol: assetSymbol,
            tokenContract: tokenContract,
            statusText: statusText,
            status: status,
            primaryAmount: "\(amount) \(assetSymbol)",
            localAmount: localAmount ?? "Local amount unavailable",
            assetKind: assetKind,
            assetSymbol: assetSymbol,
            recipient: recipient,
            network: transaction.chain.displayName,
            hashText: WalletFormatting.shortAddress(transaction.txHash, prefix: 12, suffix: 10),
            appStoreText: ApertureWeb.appStoreDisplay
        )
        let renderer = ImageRenderer(
            content: SendSentScreenshotView(receipt: receipt)
                .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = displayScale
        guard let image = renderer.uiImage else {
            screenshotShareFailed = true
            return
        }
        screenshotShareItem = SendSentScreenshotShareItem(
            image: image,
            message: shareMessage,
            appStoreURL: URL(string: ApertureWeb.appStore)
        )
    }

    /// Share copy tracks the live on-chain status — never claims "Sent"
    /// while the receipt is still confirming (Rule #16).
    private var shareMessage: String {
        switch status {
        case .confirmed:
            return String.apertureLocalized("Sent with Aperture. A clean self-custody wallet for crypto you control.")
        case .failed:
            return String.apertureLocalized("Transaction failed. Shared from Aperture.")
        case .pending:
            return String.apertureLocalized("Confirming on-chain with Aperture. A clean self-custody wallet for crypto you control.")
        }
    }

    private func copyHash() {
        SafePasteboard.setItems(
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

    private func detailRow(_ key: LocalizedStringKey, value: String, mono: Bool = false) -> some View {
        LabeledContent {
            Text(verbatim: value)
                .font(mono ? .body.monospacedDigit() : .body)
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
                .lineLimit(1)
                .truncationMode(.middle)
        } label: {
            Text(key)
        }
    }

    private var statusText: String {
        if isFailed { return String.apertureLocalized("Failed") }
        if isPending { return String.apertureLocalized("Confirming") }
        return String.apertureLocalized("Sent")
    }
}

@MainActor
enum ReceiptScreenshotFlash {
    static func play() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        else { return }

        let flash = UIView(frame: window.bounds)
        flash.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        flash.backgroundColor = .white
        flash.alpha = 0
        flash.isUserInteractionEnabled = false
        window.addSubview(flash)

        UIView.animate(
            withDuration: 0.08,
            delay: 0,
            options: [.allowUserInteraction, .curveEaseOut]
        ) {
            flash.alpha = UIAccessibility.isReduceTransparencyEnabled ? 0.72 : 0.9
        } completion: { _ in
            UIView.animate(
                withDuration: UIAccessibility.isReduceMotionEnabled ? 0.12 : 0.28,
                delay: 0.03,
                options: [.allowUserInteraction, .curveEaseIn]
            ) {
                flash.alpha = 0
            } completion: { _ in
                flash.removeFromSuperview()
            }
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

private struct SendSentScreenshotReceipt {
    let chain: SupportedChain
    let tokenSymbol: String
    let tokenContract: String?
    let statusText: String
    let status: TransactionConfirmation.Outcome
    let primaryAmount: String
    let localAmount: String
    let assetKind: String
    let assetSymbol: String
    let recipient: String
    let network: String
    let hashText: String
    let appStoreText: String
}

private struct SendSentScreenshotView: View {
    let receipt: SendSentScreenshotReceipt

    var body: some View {
        VStack(spacing: 20) {
            brandHeader

            VStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    CoinMark(
                        chain: receipt.chain,
                        tokenSymbol: receipt.tokenSymbol,
                        contract: receipt.tokenContract
                    )
                    .frame(width: 72, height: 72)

                    Image(systemName: statusSymbol)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(statusForeground)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(statusBackground))
                }

                Text(verbatim: receipt.statusText)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(UniColors.Text.primary)

                Text(verbatim: receipt.primaryAmount)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(UniColors.Text.primary)
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                    .environment(\.layoutDirection, .leftToRight)

                Text(verbatim: receipt.localAmount)
                    .font(.system(size: 20, weight: .regular).monospacedDigit())
                    .foregroundStyle(UniColors.Text.secondary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .environment(\.layoutDirection, .leftToRight)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

            VStack(spacing: 0) {
                screenshotRow(receipt.assetKind, value: receipt.assetSymbol)
                Divider()
                screenshotRow("Amount", value: receipt.primaryAmount, monospaced: true)
                Divider()
                screenshotRow("Local amount", value: receipt.localAmount, monospaced: true)
                Divider()
                screenshotRow("To", value: receipt.recipient, monospaced: true)
                Divider()
                screenshotRow("Network", value: receipt.network)
                Divider()
                screenshotRow("Transaction", value: receipt.hashText, monospaced: true)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(UniColors.Card.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(UniColors.Separator.regular.opacity(0.5), lineWidth: 1)
            )

            marketingFooter
        }
        .padding(24)
        .frame(width: 430)
        .background(
            LinearGradient(
                colors: [
                    UniColors.Background.primary,
                    UniColors.Card.background.opacity(0.92)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            ApertureAppLogo(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Aperture")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(UniColors.Text.primary)
                Text("Self-custody crypto wallet")
                    .font(.caption)
                    .foregroundStyle(UniColors.Text.secondary)
            }
            Spacer(minLength: 12)
            statusPill
        }
    }

    private var statusPill: some View {
        Text(verbatim: receipt.statusText)
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusForeground)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(statusBackground))
    }

    private var marketingFooter: some View {
        HStack(alignment: .center, spacing: 10) {
            ApertureAppLogo(size: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: footerHeadline)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(UniColors.Text.primary)
                Text("A cleaner wallet for crypto you control.")
                    .font(.caption2)
                    .foregroundStyle(UniColors.Text.secondary)
                Text(verbatim: receipt.appStoreText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(UniColors.Text.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var footerHeadline: String {
        switch receipt.status {
        case .confirmed:
            return String.apertureLocalized("Sent with Aperture")
        case .failed:
            return String.apertureLocalized("Failed · Aperture")
        case .pending:
            return String.apertureLocalized("Confirming · Aperture")
        }
    }

    private func screenshotRow(
        _ label: String,
        value: String,
        monospaced: Bool = false
    ) -> some View {
        LabeledContent {
            Text(verbatim: value)
                .font(monospaced ? .body.monospacedDigit() : .body)
                .foregroundStyle(UniColors.Text.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .environment(\.layoutDirection, .leftToRight)
        } label: {
            Text(verbatim: label)
                .foregroundStyle(UniColors.Text.secondary)
        }
        .padding(.vertical, 10)
    }

    private var statusSymbol: String {
        switch receipt.status {
        case .confirmed:
            return "checkmark"
        case .pending:
            return "clock"
        case .failed:
            return "xmark"
        }
    }

    private var statusForeground: Color {
        switch receipt.status {
        case .confirmed:
            return UniColors.Feedback.Success.foreground
        case .pending:
            return UniColors.Feedback.Warning.foreground
        case .failed:
            return UniColors.Feedback.Error.foreground
        }
    }

    private var statusBackground: Color {
        switch receipt.status {
        case .confirmed:
            return UniColors.Feedback.Success.background
        case .pending:
            return UniColors.Feedback.Warning.background
        case .failed:
            return UniColors.Feedback.Error.background
        }
    }
}

private struct SendSentScreenshotShareItem: Identifiable {
    let id = UUID()
    let image: UIImage
    let message: String
    let appStoreURL: URL?
}

private struct SendSentScreenshotShareSheet: UIViewControllerRepresentable {
    let item: SendSentScreenshotShareItem

    func makeUIViewController(context: Context) -> UIActivityViewController {
        var items: [Any] = [item.image, item.message]
        if let appStoreURL = item.appStoreURL {
            items.append(appStoreURL)
        }
        return UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Failed state

/// The honest failure surface. Shows the executor's typed error message
/// verbatim (Rule #16 — name what happened), and — for a pre-broadcast
/// failure — makes plain that nothing was sent. Retry returns to Review.
private struct SendFailedView: View {
    let error: SigningError
    let onRetry: () -> Void
    let onClose: () -> Void

    /// `true` when we can honestly say nothing was broadcast. Every
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
                    ApertureErrorSupportSection(report: errorReport)
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.xl)
                .padding(.bottom, UniSpacing.xxl)
            }
            .scrollIndicators(.hidden)
        }
        .background(UniColors.Background.primary)
        .uniBottomActionBar { actionBar }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    private var hero: some View {
        VStack(spacing: UniSpacing.s) {
            Image(systemName: isRefusal ? "lock.shield" : "exclamationmark.triangle")
                .font(.system(size: 52, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isRefusal ? UniColors.Brand.mark : UniColors.Feedback.Error.foreground)
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

    private var failureTitleText: String {
        isRefusal ? "Can't send" : "Send failed"
    }

    private var errorReport: ApertureErrorReport {
        ApertureErrorReport(
            context: "Send transaction",
            title: failureTitleText,
            message: error.userMessage,
            error: error,
            recoverySuggestion: nothingWasSent
                ? "Nothing was broadcast from this device. Review the transaction and try again."
                : "Check the transaction on an explorer before retrying.",
            metadata: [
                "nothingWasSent": "\(nothingWasSent)",
                "retryable": "\(canRetry)"
            ]
        )
    }

    private var messageCard: some View {
        VStack(alignment: .leading, spacing: UniSpacing.s) {
            Text(verbatim: error.userMessage)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
            if nothingWasSent {
                Label {
                    Text("Nothing was broadcast from this device.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                } icon: {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(UniColors.Feedback.Success.foreground)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UniSpacing.m)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.card, style: .continuous)
                .fill(nothingWasSent ? UniColors.Fill.quaternary : UniColors.Feedback.Error.background)
        )
        // No stroke — keep the surface soft like other inset groups.
    }

    private var actionBar: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            // Retry-only when the failure is retryable; otherwise a single Done
            // exits the flow. No secondary Close under Try again.
            UniButton(
                title: canRetry ? "Try again" : "Done",
                variant: .primary,
                action: canRetry ? onRetry : onClose
            )
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
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
                    Button("Cancel") { onCancel() }.tint(UniColors.Button.text)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign") { onSubmit(passphrase) }.tint(UniColors.Button.text)
                        .fontWeight(.semibold)
                        .disabled(passphrase.isEmpty)
                }
            }
        }
    }
}
