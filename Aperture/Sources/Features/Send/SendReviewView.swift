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
    /// Live biometry type for the Send CTA Face ID / Touch ID glyph.
    @State private var biometricService = BiometricService()

    /// The send state machine. `.review` is the resting state.
    @State private var phase: Phase = .review
    /// Drives the success haptic (set once when the send lands).
    @State private var sentAt: Date?
    /// Drives the error haptic (bumped on each failure).
    @State private var failedTrigger: Int = 0
    /// The PIN-fallback presentation. Verify gates are native bottom sheets
    /// so the user can change their mind without leaving the send flow.
    @State private var isShowingPinVerify: Bool = false
    @State private var pinVerifyAutoPromptBiometrics: Bool = true
    @State private var didCompletePinVerify: Bool = false
    /// The passphrase prompt presentation.
    @State private var isShowingPassphrase: Bool = false
    /// Multi-recipient list sheet from the Review "To" row.
    @State private var isShowingRecipientsSheet: Bool = false
    /// Full “transactions cannot be reversed” education sheet.
    @State private var isShowingIrreversibleInfo: Bool = false
    /// Read-only selected-coins sheet (edit only on amount step).
    @State private var isShowingSelectedCoinsSheet: Bool = false
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
                    recipients: draft.recipients,
                    amountDecimals: draft.effectiveDecimals,
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
                Text("Review Transaction Details")
                    .font(UniTypography.headline)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .sheet(isPresented: $isShowingPinVerify, onDismiss: handlePinVerifyDismiss) {
            pinVerifySheet
        }
        .sheet(isPresented: $isShowingRecipientsSheet) {
            SendRecipientsSheet(
                recipients: draft.recipients,
                assetSymbol: assetSymbol,
                amountDecimals: draft.effectiveDecimals
            )
            .apertureEnvironment()
            .uniSheetDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingIrreversibleInfo) {
            SendIrreversibleTransactionSheet()
                .apertureEnvironment()
                .uniSheetDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(UniColors.Background.primary)
        }
        .sheet(isPresented: $isShowingSelectedCoinsSheet) {
            if let utxos = draft.selectedUTXOs, !utxos.isEmpty {
                SendReviewSelectedCoinsSheet(
                    utxos: utxos,
                    chain: chain,
                    hideBalances: hideBalances
                )
                .apertureEnvironment()
                .uniSheetDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(UniColors.Background.primary)
            }
        }
        .sheet(isPresented: $isShowingPassphrase) {
            SendPassphraseSheet(
                onSubmit: { entered in
                    passphrase = entered
                    isShowingPassphrase = false
                    // Session cache so refresh can dual-provision Solana paths
                    // without re-prompting (passphrase never persisted to disk).
                    Task {
                        await BIP39PassphraseSession.shared.remember(
                            walletId: walletId,
                            passphrase: entered
                        )
                        _ = await SolanaPathProvisioning.ensureBothAccountZeroPathsIfPossible(
                            walletId: walletId,
                            passphrase: entered
                        )
                    }
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
                networkRow
                divider
                detailRow("From", value: WalletFormatting.shortAddress(draft.fromAddress, prefix: 8, suffix: 6), mono: true)
                divider
                recipientRows
                divider
                feeRow
            }
        }
    }

    /// Network name + chain mark (logo).
    private var networkRow: some View {
        HStack(spacing: UniSpacing.s) {
            Text("Network")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            HStack(spacing: UniSpacing.s) {
                CoinMark(chain: chain, tokenSymbol: chain.ticker)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)
                Text(verbatim: chain.displayName)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(verbatim: "\(String.apertureLocalized("Network")), \(chain.displayName)")
        )
    }

    @ViewBuilder
    private var recipientRows: some View {
        if draft.recipients.count == 1, let r = draft.recipients.first {
            detailRow("To", value: r.name ?? WalletFormatting.shortAddress(r.address, prefix: 8, suffix: 6), mono: r.name == nil)
        } else {
            // Multi: count link → full address + amount sheet (same as sent).
            HStack(spacing: UniSpacing.s) {
                Text("To")
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.secondary)
                Spacer(minLength: UniSpacing.s)
                Button {
                    isShowingRecipientsSheet = true
                } label: {
                    Text(verbatim: recipientsCountLabel)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Button.text)
                        .multilineTextAlignment(.trailing)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Shows all recipient addresses and amounts"))
            }
            .padding(.horizontal, UniSpacing.m)
            .padding(.vertical, UniSpacing.s)
        }
    }

    private var recipientsCountLabel: String {
        String(
            format: String.apertureLocalized("%lld recipients"),
            Int64(draft.recipients.count)
        )
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
            }
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
    }

    // MARK: - Extras (memo / tag / comment / op_return / max)

    private var hasExtras: Bool {
        !extras.isEmpty || reviewSelectedUTXOs != nil
    }

    /// One extra row's content, resolved into a stable, order-preserving
    /// list so the card can interleave dividers without ViewBuilder
    /// statement gymnastics.
    private struct Extra: Identifiable {
        let id = UUID()
        let key: LocalizedStringKey
        let value: String
    }

    /// Extras that are plain label → value rows (coins is interactive).
    private var extras: [Extra] {
        var rows: [Extra] = []
        if let memo = memoSummary {
            rows.append(Extra(key: memoLabel, value: memo))
        }
        if let data = draft.opReturn, let text = String(data: data, encoding: .utf8), !text.isEmpty {
            rows.append(Extra(key: "OP_RETURN", value: text))
        }
        // RBF only meaningful on BTC/LTC (same gate as the amount menu +
        // signer). Surface the user's choice so review is honest.
        if chain == .bitcoin || chain == .litecoin {
            rows.append(Extra(
                key: "Replace-By-Fee (RBF)",
                value: draft.signalsRBF
                    ? String.apertureLocalized("On")
                    : String.apertureLocalized("Off")
            ))
        }
        if draft.isMaxSend {
            rows.append(Extra(key: "Amount", value: String.apertureLocalized("Sending the maximum")))
        }
        return rows
    }

    private var reviewSelectedUTXOs: [SelectedUTXO]? {
        guard chain.family == .bitcoin,
              let utxos = draft.selectedUTXOs, !utxos.isEmpty else { return nil }
        return utxos
    }

    private var extrasCard: some View {
        UniCard(padding: 0) {
            VStack(spacing: 0) {
                if let utxos = reviewSelectedUTXOs {
                    coinsDisclosureRow(count: utxos.count)
                    if !extras.isEmpty { divider }
                }
                ForEach(Array(extras.enumerated()), id: \.element.id) { offset, extra in
                    extraRow(extra.key, value: extra.value)
                    if offset < extras.count - 1 { divider }
                }
            }
        }
    }

    /// "Coins · N Selected ›" — text-button value opens a read-only sheet.
    /// Selection is only editable on the amount step options menu.
    private func coinsDisclosureRow(count: Int) -> some View {
        let label = String(
            format: String.apertureLocalized("%lld Selected"),
            Int64(count)
        )
        return HStack(spacing: UniSpacing.s) {
            Text("Coins")
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            Button {
                isShowingSelectedCoinsSheet = true
            } label: {
                HStack(spacing: 4) {
                    Text(verbatim: label)
                        .font(UniTypography.body)
                    Image(systemName: UniDirectionalSymbol.disclosure)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(UniColors.Button.text)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityHint(Text("Shows the coins used in this send. Selection can’t be changed here."))
        }
        .padding(.horizontal, UniSpacing.m)
        .padding(.vertical, UniSpacing.s)
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

    // MARK: - Finality note (Rule #16 — restate at the moment of commit)

    /// Compact warning: irreversible + tappable Learn more → full explanation.
    private var selfCustodyNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: UniSpacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(UniColors.Text.secondary)
                .accessibilityHidden(true)
            // Keep the warning short; details live behind Learn more.
            Text("Transaction cannot be reversed.")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                isShowingIrreversibleInfo = true
            } label: {
                Text("Learn more")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Button.text)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Explains why sent transactions cannot be reversed"))
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
                // Face ID / Touch ID on the CTA when send requires biometrics
                // — not only after tap; the icon sets the expectation.
                systemImage: sendCTASystemImage,
                isLoading: isWorking,
                isEnabled: !isWorking,
                action: beginSend
            )
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
        }
        .onAppear { biometricService.refresh() }
    }

    private var sendTitle: LocalizedStringKey {
        switch phase {
        case .authenticating: return "Confirming…"
        case .sending:        return "Sending…"
        default:              return "Send"
        }
    }

    /// Leading glyph on Send when Face ID (etc.) will gate the broadcast.
    /// Hidden while loading (spinner replaces the icon) and when send-auth
    /// is off or biometrics aren't available.
    private var sendCTASystemImage: String? {
        guard !isWorking else { return nil }
        guard showsBiometricOnSendCTA else { return nil }
        let name = biometricService.biometryType.systemImageName
        // Only show a concrete biometry symbol — not the generic lock fallback.
        switch biometricService.biometryType {
        case .faceID, .touchID, .opticID:
            return name
        case .none:
            return nil
        }
    }

    /// Master biometrics on + "Use Face ID for sending" + PIN set.
    private var showsBiometricOnSendCTA: Bool {
        biometricEnabled && requireForSend && PinCodeStorage.hasPin
    }

    // MARK: - PIN-fallback sheet

    private var pinVerifySheet: some View {
        SensitiveAuthPasscodeSheet(
            accessContext: .signTransaction(
                chain: chain,
                symbol: assetSymbol,
                contract: draft.tokenContract
            ),
            autoPromptBiometrics: pinVerifyAutoPromptBiometrics,
            // Always allow Face ID on the keypad when the user enabled it in
            // Security — never force passcode-only while biometrics are on.
            allowsBiometrics: biometricEnabled,
            onComplete: {
                didCompletePinVerify = true
                isShowingPinVerify = false
                afterAuthSuccess()
            },
            onCancel: {
                isShowingPinVerify = false
                phase = .review
            }
        )
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

        // "Use Face ID for sending" off → no per-send challenge (app unlock
        // already authenticated this session). On → Face ID first, passcode
        // fallback with Face ID still on the keypad.
        routeToAuthOrProceed()
    }

    /// Shared gate: Face ID first when send-auth is required, then passcode.
    private func routeToAuthOrProceed() {
        // No PIN, or user turned off "Use Face ID for sending" → proceed.
        // (When that toggle is off, do not force a passcode-only sheet.)
        guard PinCodeStorage.hasPin, requireForSend else {
            afterAuthSuccess()
            return
        }
        Task { @MainActor in
            // requireForSend is only meaningful while master biometrics are
            // on — always prefer Face ID; passcode sheet is the fallback.
            let gate = await SensitiveActionAuth.gatePreferringBiometric()
            switch gate {
            case .authorized:
                afterAuthSuccess()
            case .presentPasscode(let autoPrompt):
                didCompletePinVerify = false
                pinVerifyAutoPromptBiometrics = autoPrompt
                isShowingPinVerify = true
            }
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
    /// All recipients for this send. Multi-recipient chains show a count
    /// link that opens the full address + amount sheet.
    let recipients: [SendRecipientAmount]
    let amountDecimals: Int
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
    @State private var isShowingRecipientsSheet: Bool = false

    /// The live on-chain verdict, polled after the screen appears so the hero
    /// moves from "Confirming" to "Sent"/"Failed" the moment the chain reports
    /// back (Rule #25). Starts `.pending` — broadcast is not confirmation
    /// (Rule #16).
    @State private var status: TransactionConfirmation.Outcome = .pending
    /// Stamped when the poll resolves — drives the success / error haptic.
    @State private var resolvedAt: Date?

    private var isMultiRecipient: Bool { recipients.count > 1 }

    private var singleRecipientLabel: String {
        guard let r = recipients.first else { return "—" }
        return r.name ?? WalletFormatting.shortAddress(r.address, prefix: 8, suffix: 6)
    }

    private var recipientsCountLabel: String {
        String(
            format: String.apertureLocalized("%lld recipients"),
            Int64(recipients.count)
        )
    }

    /// Value shown on the Details "To" row and in the share screenshot.
    private var toDisplayValue: String {
        isMultiRecipient ? recipientsCountLabel : singleRecipientLabel
    }

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
        .uniListPageChrome()
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
        .sheet(isPresented: $isShowingRecipientsSheet) {
            SendRecipientsSheet(
                recipients: recipients,
                assetSymbol: assetSymbol,
                amountDecimals: amountDecimals,
                transactionAlreadySent: true
            )
            .apertureEnvironment()
            .uniSheetDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(UniColors.Background.primary)
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

    /// Probe the chain until confirmed/failed (or budget ends).
    /// Solana uses `getSignatureStatuses` first so indexing lag on
    /// `getTransaction` doesn't leave Confirming stuck (P1 #12).
    private func pollForConfirmation() async {
        guard !transaction.txHash.isEmpty else { return }
        let outcome = await TransactionConfirmation.awaitResolution(
            txHash: transaction.txHash,
            chain: transaction.chain,
            address: senderAddress,
            tokenContract: tokenContract
        )
        guard !Task.isCancelled else { return }
        status = outcome
        if outcome != .pending {
            resolvedAt = Date()
        }
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
            // Confirming is quieter than Sent/Failed (title2, medium weight)
            // so the spinner + amount still lead.
            Text(verbatim: heroTitleText)
                .font(isPending
                      ? Font.system(.title2, design: .default, weight: .medium)
                      : UniTypography.largeTitle)
                .foregroundStyle(isPending ? UniColors.Text.primary : UniColors.Copy.largeTitle)
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
                "Confirming can take a moment. You can safely leave this screen."
            )
        }
        return String.apertureLocalized(
            "Confirmed on the \(transaction.chain.displayName) network."
        )
    }

    private var heroAccessibilityLabel: String { heroTitleText }

    private var detailsSection: some View {
        Section {
            // Amount + local amount live in the hero — no need to repeat them.
            assetIdentityRow
            toRow
            if showsNetworkRow {
                detailRow("Network", value: transaction.chain.displayName)
            }
        } header: {
            Text("Details")
        }
    }

    /// Full coin/token name + mark. Native coins use the chain display
    /// name ("Bitcoin"); tokens resolve the catalog name when known.
    private var assetIdentityRow: some View {
        LabeledContent {
            HStack(spacing: UniSpacing.s) {
                CoinMark(
                    chain: transaction.chain,
                    tokenSymbol: assetSymbol,
                    contract: tokenContract
                )
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

                Text(verbatim: assetDisplayName)
                    .font(.body)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
            }
        } label: {
            Text(assetKind == "Coin" ? "Coin" : "Token")
                .foregroundStyle(UniColors.Text.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(assetKind), \(assetDisplayName)"))
    }

    /// Prefer catalog full name for tokens; chain display name for natives.
    private var assetDisplayName: String {
        if let contract = tokenContract, !contract.isEmpty {
            let chain = transaction.chain
            if let hit = AssetCatalog.allAssets.first(where: {
                $0.chain == chain
                    && $0.contract.compare(contract, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                return hit.name
            }
            if let hit = AssetCatalog.allAssets.first(where: {
                $0.chain == chain
                    && $0.symbol.caseInsensitiveCompare(assetSymbol) == .orderedSame
            }) {
                return hit.name
            }
            return assetSymbol
        }
        return transaction.chain.displayName
    }

    /// Network only when the chain hosts more than its native coin
    /// (EVM, Solana, TRON, TON jettons, etc.). Single-asset chains
    /// (Bitcoin family) already identify the network via the coin itself.
    private var showsNetworkRow: Bool {
        switch transaction.chain {
        case .bitcoin, .bitcoinCash, .litecoin, .dogecoin, .stellar:
            return false
        case .ethereum, .arbitrum, .base, .optimism, .scroll, .zkSync,
             .polygon, .bnbChain, .opBNB, .avalanche, .celo,
             .solana, .tron, .ton, .sui, .aptos, .near, .polkadot, .ripple:
            return true
        }
    }

    /// Single recipient: short address (or name). Multi: tappable count in
    /// text-button color that opens the full recipient list.
    @ViewBuilder
    private var toRow: some View {
        if isMultiRecipient {
            LabeledContent {
                Button {
                    isShowingRecipientsSheet = true
                } label: {
                    Text(verbatim: recipientsCountLabel)
                        .font(.body)
                        .foregroundStyle(UniColors.Button.text)
                        .multilineTextAlignment(.trailing)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Shows all recipient addresses and amounts"))
            } label: {
                Text("To")
                    .foregroundStyle(UniColors.Text.secondary)
            }
        } else {
            detailRow("To", value: singleRecipientLabel, mono: recipients.first?.name == nil)
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
                .foregroundStyle(UniColors.Text.secondary)
        }
    }

    private var copyButton: some View {
        Button {
            copyHash()
        } label: {
            UniCopySymbol(isCopied: didCopy)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.uniTactile)
        .foregroundStyle(didCopy ? UniColors.Feedback.Success.foreground : UniColors.Text.link)
        .uniCopySymbolAnimation(value: didCopy)
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
            assetDisplayName: assetDisplayName,
            assetSymbol: assetSymbol,
            recipient: toDisplayValue,
            network: transaction.chain.displayName,
            // Shorter hash in the share image (tighter than on-screen).
            hashText: WalletFormatting.shortAddress(transaction.txHash, prefix: 8, suffix: 6),
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
        withAnimation(.snappy(duration: 0.28)) { didCopy = true }
        copiedAt = Date()
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.28)) { didCopy = false }
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
                .foregroundStyle(UniColors.Text.secondary)
        }
    }

    private var statusText: String {
        if isFailed { return String.apertureLocalized("Failed") }
        if isPending { return String.apertureLocalized("Confirming") }
        return String.apertureLocalized("Sent")
    }
}

// MARK: - Selected coins (read-only on Review)

/// Lists the UTXOs that will fund this send. Not editable — change coins
/// from the amount screen options menu before Review.
private struct SendReviewSelectedCoinsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let utxos: [SelectedUTXO]
    let chain: SupportedChain
    let hideBalances: Bool

    private var totalSats: Int64 {
        utxos.reduce(Int64(0)) { $0 + $1.valueSats }
    }

    private var totalDisplay: String {
        let total = ComposeDecimal.toDisplay(Decimal(totalSats), decimals: chain.nativeDecimals)
        return "\(WalletFormatting.native(total, decimals: chain.nativeDecimals, hidden: hideBalances)) \(chain.ticker)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(utxos) { utxo in
                        coinRow(utxo)
                    }
                } header: {
                    Text("Selected coins")
                } footer: {
                    Text(verbatim: String(
                        format: String.apertureLocalized("Total %@. Coin selection can only be changed before Review."),
                        totalDisplay
                    ))
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                }
            }
            .uniListPageChrome()
            .navigationTitle(Text("Coins"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(UniColors.Button.text)
                }
            }
        }
    }

    private func coinRow(_ utxo: SelectedUTXO) -> some View {
        let amount = ComposeDecimal.toDisplay(Decimal(utxo.valueSats), decimals: chain.nativeDecimals)
        return HStack(alignment: .top, spacing: UniSpacing.s) {
            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: "\(WalletFormatting.native(amount, decimals: chain.nativeDecimals, hidden: hideBalances)) \(chain.ticker)")
                    .font(UniTypography.body.monospacedDigit())
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
                HStack(spacing: UniSpacing.xxs) {
                    Image(systemName: utxo.confirmed ? "checkmark.seal" : "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(
                            utxo.confirmed
                                ? UniColors.Feedback.Success.foreground
                                : UniColors.Feedback.Warning.foreground
                        )
                    Text(utxo.confirmed ? "Confirmed" : "Unconfirmed")
                        .font(UniTypography.caption2)
                        .foregroundStyle(UniColors.Text.tertiary)
                    Text(verbatim: "· \(shortTxid(utxo.txid)):\(utxo.vout)")
                        .font(UniTypography.caption2.monospaced())
                        .foregroundStyle(UniColors.Text.quaternary)
                        .environment(\.layoutDirection, .leftToRight)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, UniSpacing.xxs)
        .accessibilityElement(children: .combine)
    }

    private func shortTxid(_ txid: String) -> String {
        guard txid.count > 10 else { return txid }
        return "\(txid.prefix(6))…\(txid.suffix(4))"
    }
}

// MARK: - Why transactions cannot be reversed

/// Education sheet opened from Review’s “Learn more” finality note.
private struct SendIrreversibleTransactionSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.l) {
                    intro
                    section(
                        title: "Once it’s on the network, it’s final",
                        body: "When you tap Send, Aperture signs the transaction on this iPhone and broadcasts it to the blockchain. Miners or validators include it in a block. After that, the ledger is shared by thousands of independent computers — not by Aperture, not by a bank, and not by a support desk that can “undo” a payment."
                    )
                    section(
                        title: "There is no chargeback",
                        body: "Unlike a card payment or bank transfer, crypto has no issuer that can reverse a transfer if you mistype an address, send the wrong asset, or are tricked by a scam. The only way funds move again is if the receiving address signs a new transaction sending them back — and only if that person chooses to."
                    )
                    section(
                        title: "Why the protocol works this way",
                        body: "Blockchains are designed so that history is extremely hard to rewrite. That permanence is what makes the network trustworthy: no one can silently change who owns what. The trade-off is that mistakes and fraud cannot be rolled back by the app or the network."
                    )
                    section(
                        title: "What you should double-check",
                        body: "Before you send, confirm the network, the full recipient address (or name you resolved), the amount, and any memo or destination tag exchanges require. Aperture shows you these details on this Review screen so you can catch errors while you still control the keys."
                    )
                    section(
                        title: "Self-custody",
                        body: "You hold the keys. Aperture never has a recovery path for a completed send. If something looks wrong, stop and go back — after Send, the transaction is out of this device’s control."
                    )
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.m)
                .padding(.bottom, UniSpacing.xxxl)
            }
            .background(UniColors.Background.primary)
            .navigationTitle(Text("Why it’s final"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(UniColors.Button.text)
                }
            }
        }
    }

    private var intro: some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(UniColors.Feedback.Warning.foreground)
                .accessibilityHidden(true)
            Text("Transaction cannot be reversed.")
                .font(UniTypography.title3)
                .foregroundStyle(UniColors.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: UniSpacing.xs) {
            Text(title)
                .font(UniTypography.headline)
                .foregroundStyle(UniColors.Text.primary)
            Text(body)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Multi-recipient list (review + sent)

/// Sheet listing every destination address and its amount for a multi-
/// recipient send. Opened from the tappable "To · N recipients" row on
/// both Review and Sent.
private struct SendRecipientsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.balancePrivacyEnabled) private var hideBalances

    let recipients: [SendRecipientAmount]
    let assetSymbol: String
    let amountDecimals: Int
    /// When `true` (post-broadcast success surface), each row notes that
    /// the payment was already included in the sent transaction.
    var transactionAlreadySent: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(recipients.enumerated()), id: \.element.id) { offset, recipient in
                        recipientRow(index: offset + 1, recipient: recipient)
                    }
                }
            }
            .uniListPageChrome()
            .navigationTitle(Text("Recipients"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(UniColors.Button.text)
                }
            }
        }
    }

    private func recipientRow(index: Int, recipient: SendRecipientAmount) -> some View {
        HStack(alignment: .top, spacing: UniSpacing.s) {
            Text(verbatim: "\(index)")
                .font(UniTypography.callout)
                .foregroundStyle(UniColors.Text.secondary)
                .frame(minWidth: 20, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                if let name = recipient.name, !name.isEmpty {
                    Text(verbatim: name)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                        .lineLimit(1)
                }
                Text(verbatim: recipient.address)
                    .font(.footnote.monospaced())
                    .foregroundStyle(UniColors.Text.secondary)
                    .environment(\.layoutDirection, .leftToRight)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if transactionAlreadySent {
                    Text("Transaction sent")
                        .font(UniTypography.caption1)
                        .foregroundStyle(UniColors.Feedback.Success.foreground)
                }
            }

            Spacer(minLength: UniSpacing.s)

            Text(verbatim: amountText(for: recipient))
                .font(UniTypography.callout.monospacedDigit())
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, UniSpacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(index: index, recipient: recipient))
    }

    private func amountText(for recipient: SendRecipientAmount) -> String {
        let formatted = WalletFormatting.native(
            recipient.amount,
            decimals: amountDecimals,
            hidden: hideBalances
        )
        return "\(formatted) \(assetSymbol)"
    }

    private func accessibilityLabel(index: Int, recipient: SendRecipientAmount) -> String {
        let nameOrAddress = recipient.name ?? recipient.address
        var label = "\(index). \(nameOrAddress), \(amountText(for: recipient))"
        if transactionAlreadySent {
            label += ", \(String.apertureLocalized("Transaction sent"))"
        }
        return label
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
    /// Full coin/token name for the details list (e.g. "Bitcoin", "Solana").
    let assetDisplayName: String
    let assetSymbol: String
    let recipient: String
    let network: String
    let hashText: String
    let appStoreText: String
}

private struct SendSentScreenshotView: View {
    let receipt: SendSentScreenshotReceipt

    /// Inset-grouped list geometry (matches on-screen receipt Lists).
    private let listCorner: CGFloat = 12
    private let rowHorizontal: CGFloat = 16
    private let rowVertical: CGFloat = 12
    private let separatorInset: CGFloat = 16

    var body: some View {
        VStack(spacing: 20) {
            brandHeader

            VStack(spacing: 10) {
                // Token / chain mark only — status lives in the app-bar pill
                // ("Sent") so a second green check is redundant.
                CoinMark(
                    chain: receipt.chain,
                    tokenSymbol: receipt.tokenSymbol,
                    contract: receipt.tokenContract
                )
                .frame(width: 72, height: 72)

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

            // Real inset-grouped list chrome (not a stroked card). Amount /
            // local amount stay in the hero only.
            VStack(spacing: 0) {
                assetScreenshotRow
                listSeparator
                screenshotRow(
                    String.apertureLocalized("To"),
                    value: receipt.recipient,
                    monospaced: true
                )
                listSeparator
                networkScreenshotRow
                listSeparator
                screenshotRow(
                    String.apertureLocalized("Hash"),
                    value: receipt.hashText,
                    monospaced: true,
                    valueFontSize: 14
                )
            }
            .background(
                RoundedRectangle(cornerRadius: listCorner, style: .continuous)
                    .fill(UniColors.List.rowBackground)
            )
            .clipShape(RoundedRectangle(cornerRadius: listCorner, style: .continuous))

            marketingFooter
        }
        .padding(24)
        .frame(width: 430)
        .background(UniColors.Background.primary)
    }

    /// Coin / Token label + mark + full name (matches live Details).
    private var assetScreenshotRow: some View {
        HStack(spacing: 10) {
            Text(LocalizedStringKey(receipt.assetKind))
                .font(.body)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                CoinMark(
                    chain: receipt.chain,
                    tokenSymbol: receipt.tokenSymbol,
                    contract: receipt.tokenContract
                )
                .frame(width: 26, height: 26)
                Text(verbatim: receipt.assetDisplayName)
                    .font(.body)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, rowHorizontal)
        .padding(.vertical, rowVertical)
        .frame(minHeight: 44)
    }

    private var networkScreenshotRow: some View {
        HStack(spacing: 10) {
            Text("Network")
                .font(.body)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                CoinMark(chain: receipt.chain, tokenSymbol: receipt.chain.ticker)
                    .frame(width: 22, height: 22)
                Text(verbatim: receipt.network)
                    .font(.body)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, rowHorizontal)
        .padding(.vertical, rowVertical)
        .frame(minHeight: 44)
    }

    private var listSeparator: some View {
        Rectangle()
            .fill(UniColors.Separator.regular.opacity(0.55))
            .frame(height: 1 / 3)
            .padding(.leading, separatorInset)
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            ApertureAppLogo(size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Aperture")
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
        monospaced: Bool = false,
        valueFontSize: CGFloat = 17
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(verbatim: label)
                .font(.body)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: 12)
            Text(verbatim: value)
                .font(
                    monospaced
                        ? .system(size: valueFontSize, weight: .regular, design: .monospaced)
                        : .system(size: valueFontSize, weight: .regular)
                )
                .foregroundStyle(UniColors.Text.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .environment(\.layoutDirection, .leftToRight)
        }
        .padding(.horizontal, rowHorizontal)
        .padding(.vertical, rowVertical)
        .frame(minHeight: 44)
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
    /// Marketing link as text only — never as `URL` activity item (that
    /// steals the share-sheet preview and shows the App Store app icon).
    let appStoreURL: URL?
}

private struct SendSentScreenshotShareSheet: UIViewControllerRepresentable {
    let item: SendSentScreenshotShareItem

    func makeUIViewController(context: Context) -> UIActivityViewController {
        var items: [Any] = []
        if let data = item.image.pngData() {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Aperture-Sent-\(item.id.uuidString).png")
            do {
                try data.write(to: url, options: .atomic)
                items.append(url)
            } catch {
                items.append(item.image)
            }
        } else {
            items.append(item.image)
        }
        items.append(item.message)
        if let appStoreURL = item.appStoreURL {
            items.append(appStoreURL.absoluteString)
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
