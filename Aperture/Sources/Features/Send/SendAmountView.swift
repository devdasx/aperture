import SwiftUI

/// Send · Step 4 — the amount / compose screen. A calm, large amount entry
/// with a crypto⇄fiat toggle and a MAX button; the live network fee row;
/// honest per-chain reserve / activation notes; and an advanced-options
/// menu (the dots) that surfaces ONLY what the chain supports — driven
/// entirely by `ChainComposeCapability`. Continue builds the validated
/// `SendDraft` and pushes Review.
///
/// **Layers (Rule #2 §B.3).** Content layer: the amount hero, the fee row,
/// reserve notes, multi-recipient list — opaque on `Background.primary`.
/// Functional layer (Liquid Glass via system APIs only): the parent nav
/// bar with its trailing options `Menu`, and the bottom Review CTA
/// (`UniButton(.primary)` → `.glassProminent`) in its own
/// `GlassEffectContainer`. Two glass layers max; content scrolls under the
/// CTA.
///
/// **Local-first (Rule #27).** Token balances come from GRDB observation
/// (`token_balances`). Per-address **account-state** (XRP OwnerCount,
/// Stellar subentries, NEAR locked, DOT frozen) is read from
/// `chain_account_states` when a scanner has written it; until then the
/// model uses empty defaults and MAX under-deducts only until the next
/// successful balance scan (M-001). Static reserve **banners** are
/// education copy; spendable math uses live `AccountState` when present.
/// Live fee + UTXO set are action-time network reads.
///
/// **RTL (Rule #11).** Layout is semantic; the amount, the asset symbol,
/// and any address are LTR-locked because they're transcribable artifacts.
struct SendAmountView: View {
    @Environment(\.balancePrivacyEnabled) private var hideBalances

    let chain: SupportedChain
    let token: SendTokenDescriptor?
    let fromAddress: String
    let recipients: [SendRecipientEntry]
    /// Proceed to Review with the assembled draft.
    let onReview: (SendDraft) -> Void

    @StateObject private var walletRecordsObservation = WalletRecordsObservation()
    @StateObject private var activeBalancesObservation = ActiveWalletBalancesObservation()
    @GRDBStorage("activeWalletId") private var activeWalletIdRaw: String = ""

    @State private var model: SendComposeModel
    @State private var isShowingFeeSheet = false
    @State private var isShowingUTXOSheet = false
    @State private var isShowingOpReturnSheet = false
    @State private var isShowingMemoSheet = false
    @State private var isShowingTagSheet = false
    @State private var isShowingCommentSheet = false
    @State private var isShowingGasSheet = false
    /// One polite `.selection` beat for the ambient affordances (MAX,
    /// unit toggle) that aren't `UniButton`s (Rule #10 §B).
    @State private var selectionTapCount = 0
    /// Skips the FIRST run of the debounced fee task so the fee loads once
    /// immediately on appear (the unconditional `.task`) and thereafter
    /// only on material change — no double-fetch on entry (FIX 7).
    @State private var didInitialFeeLoad = false
    /// Direction key for the compose sheets (Rule #12 §G / #15): rebuild
    /// the sheet content only when crossing the LTR ↔ RTL boundary, the one
    /// case iOS's locked `semanticContentAttribute` requires it.
    @GRDBStorage("languagePreference") private var sheetLanguageCode: String = LanguagePreference.systemCode
    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: sheetLanguageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    private var currencyCode: String {
        AppPreferenceStore.shared.string(CurrencyPreference.storageKey, default: CurrencyPreference.defaultCode)
    }

    private var allWallets: [WalletRecord] {
        walletRecordsObservation.wallets
    }

    init(
        chain: SupportedChain,
        token: SendTokenDescriptor?,
        fromAddress: String,
        recipients: [SendRecipientEntry],
        onReview: @escaping (SendDraft) -> Void
    ) {
        self.chain = chain
        self.token = token
        self.fromAddress = fromAddress
        self.recipients = recipients
        self.onReview = onReview
        let code = AppPreferenceStore.shared.string(CurrencyPreference.storageKey, default: CurrencyPreference.defaultCode)
        _model = State(initialValue: SendComposeModel(
            chain: chain, tokenSymbol: token?.symbol,
            tokenContract: token?.contract,
            tokenDecimals: token?.decimals,
            fromAddress: fromAddress,
            recipients: recipients,
            currencyCode: code
        ))
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.l) {
                    if model.isMultiRecipient {
                        SendAmountMultiList(model: model, selectionTapCount: $selectionTapCount)
                    } else {
                        SendAmountHero(
                            model: model,
                            selectionTapCount: $selectionTapCount,
                            onReview: reviewDraft,
                            spendPathTitle: solanaSpendPathTitle
                        )
                        .frame(minHeight: max(0, proxy.size.height - UniSpacing.m), alignment: .top)
                    }

                    // The network fee is intentionally NOT shown in the compose
                    // body (per user direction). It lives ONLY in the options
                    // menu (dots → "Edit network fee", which opens the fee
                    // sheet), and is restated at confirmation on the Review
                    // screen. The fee is still FETCHED below (`loadFee` /
                    // `feeRefreshKey` / `recomputeUTXOFee`) so the sheet,
                    // validation, and Review have it — it's just not rendered
                    // here. Honest (Rule #16): discoverable in the menu, shown
                    // at the moment of commitment in Review.

                    if let reserve = reserveNote {
                        reserveBanner(reserve)
                    }

                    if let blocking = model.blockingError, model.totalCrypto > 0 {
                        blockingBanner(blocking)
                    }
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.top, UniSpacing.m)
                .padding(.bottom, model.isMultiRecipient ? UniSpacing.xxxl + UniSpacing.xl : 0)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
        .background(UniColors.Background.primary)
        .uniHaptic(.selection, trigger: selectionTapCount)
        .uniBottomActionBar {
            if model.isMultiRecipient {
                reviewBar
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                CoinTitleBar(chain: chain, tokenSymbol: token?.symbol, verb: "Send")
            }
            ToolbarItem(placement: .topBarTrailing) { optionsMenu }
        }
        .task(id: balancesKey) { resolveBalances() }
        .task(id: activeWalletScopeKey) { syncObservationScopes() }
        .task { await resolvePrices() }
        .task { await model.loadFee() }
        .task { await model.loadUTXOs(walletId: activeWallet?.id) }
        // P0-006: live recipient probe (activation / dest-tag / memo required).
        // Send-only — never on receive. Memo/tag entry stays on Send UI.
        .task(id: recipientProbeKey) {
            await probeRecipientAccount()
        }
        // Re-fetch the fee when a material input changes (recipient count,
        // or — for UTXO chains — the selected coins / amount that drive the
        // vsize-dependent fee). The unconditional `.task { loadFee() }`
        // above already loaded the fee once on appear, so the FIRST run of
        // this debounced task is skipped (FIX 7) — it only fires on a real
        // change thereafter.
        .task(id: feeRefreshKey) {
            guard didInitialFeeLoad else {
                didInitialFeeLoad = true
                // Still derive the vsize-dependent UTXO fee on first appear
                // once the coins/amount are known (off-main, Rule #28).
                if model.capability.supportsUTXO { await model.recomputeUTXOFee() }
                return
            }
            // Debounce a touch so rapid typing doesn't spam the network.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await model.loadFee()
            // UTXO: re-derive the real vsize-dependent fee + MAX from the
            // selected coins + amount via `selectCoins` (off-main) (FIX 3).
            if model.capability.supportsUTXO { await model.recomputeUTXOFee() }
        }
        // Keep MAX tracking the live fee on every chain (not only UTXO):
        // when worst-case fee changes (tier, custom, quote, UTXO recompute)
        // while MAX is armed, re-subtract fee from residual so the amount
        // never paints red. Keyed on Decimal because FeeChoice isn't Equatable.
        .onChange(of: model.resolvedFee?.worstCaseTotalNative) { _, _ in
            if model.isMaxSend { model.engageMax() }
        }
        .onChange(of: model.resolvedFee?.estimatedTotalNative) { _, _ in
            if model.isMaxSend { model.engageMax() }
        }
        .sheets(
            model: model,
            directionKey: sheetDirectionKey,
            isShowingFeeSheet: $isShowingFeeSheet,
            isShowingUTXOSheet: $isShowingUTXOSheet,
            isShowingOpReturnSheet: $isShowingOpReturnSheet,
            isShowingMemoSheet: $isShowingMemoSheet,
            isShowingTagSheet: $isShowingTagSheet,
            isShowingCommentSheet: $isShowingCommentSheet,
            isShowingGasSheet: $isShowingGasSheet
        )
    }

    // MARK: - Reserve / activation banner (honest)

    private var reserveNote: String? {
        // P0-006 honesty banners — activation / required tag or memo first.
        if model.recipientNeedsActivation {
            switch chain {
            case .tron:
                return String.apertureLocalized("This recipient isn't activated yet — sending will cost about 1.1 TRX extra to create the account.")
            case .stellar:
                return String.apertureLocalized("This Stellar account is new — the first payment uses create_account and must meet the minimum starting balance.")
            case .ripple:
                return String.apertureLocalized("This XRP account is new — the first payment must cover the base reserve to open it.")
            default:
                break
            }
        }
        if model.recipientRequiresDestinationTag, chain == .ripple {
            return String.apertureLocalized("This recipient requires a destination tag. Add it from the options menu or go back to the recipient step — without it the deposit can be lost.")
        }
        if model.recipientRequiresMemo, chain == .stellar {
            return String.apertureLocalized("This recipient requires a memo. Add it from the options menu or go back to the recipient step — without it the deposit can be lost.")
        }
        // Standing reserve education. When GRDB account-state is populated
        // (M-001), surface live OwnerCount / subentries so Max matches the banner.
        let state = model.accountState
        switch chain {
        case .ripple:
            if state.ownerCount > 0 {
                let locked = 1 + Decimal(state.ownerCount) * Decimal(string: "0.2")!
                return String(
                    format: String.apertureLocalized(
                        "XRP locks about %@ XRP as reserve (%lld owned objects × 0.2 + 1 base). That amount can’t be sent while the account stays open."
                    ),
                    NSDecimalNumber(decimal: locked).stringValue,
                    Int64(state.ownerCount)
                )
            }
            return String.apertureLocalized("XRP keeps a 1 XRP base reserve (plus 0.2 XRP per object) locked to keep your account open. Available/Max update after a balance scan fills account state.")
        case .stellar:
            if state.subentryCount > 0 || state.numSponsoring > 0 {
                return String.apertureLocalized("Stellar keeps a minimum balance reserved from your live subentries so the account stays active. Available/Max use that reserve.")
            }
            return String.apertureLocalized("Stellar keeps a minimum balance (from 1 XLM) reserved to keep your account active.")
        case .polkadot:
            return String.apertureLocalized("Polkadot needs 0.01 DOT to remain — dropping below it would close the account and lose the funds.")
        case .solana:
            return String.apertureLocalized("Solana keeps ~0.00089 SOL as the rent-exempt minimum so the account stays on-chain.")
        case .near:
            if state.storageUsageBytes > 0 || state.locked > 0 {
                return String.apertureLocalized("NEAR locks storage stake and any locked balance so they can’t be sent. Available/Max use your last scanned account state.")
            }
            return String.apertureLocalized("NEAR keeps a small amount locked for account storage; it can't be sent.")
        default:
            return nil
        }
    }

    private func reserveBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: UniSpacing.xs) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(UniColors.Icon.secondary)
            Text(verbatim: text)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UniSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.row, style: .continuous)
                .fill(UniColors.Fill.quaternary)
        )
    }

    private func blockingBanner(_ error: SendValidationError) -> some View {
        HStack(alignment: .top, spacing: UniSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(UniColors.Feedback.Warning.foreground)
            Text(verbatim: blockingMessage(for: error))
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UniSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.row, style: .continuous)
                .fill(UniColors.Feedback.Warning.background)
        )
    }

    private func blockingMessage(for error: SendValidationError) -> String {
        switch error {
        case .insufficientNativeForFee(let feeNeeded, let nativeAvailable):
            let needed = nativeAmountText(feeNeeded)
            let available = nativeAmountText(nativeAvailable)
            return String.apertureLocalized("Network fee needs \(needed). Available: \(available).")
        default:
            return error.message
        }
    }

    private func nativeAmountText(_ amount: Decimal) -> String {
        var text = "\(WalletFormatting.native(amount, decimals: chain.nativeDecimals, hidden: hideBalances)) \(chain.ticker)"
        if let price = model.nativeUnitPrice, price > 0 {
            text += " (\(WalletFormatting.fiat(amount * price, currencyCode: model.currencyCode, hidden: hideBalances)))"
        }
        return text
    }

    // MARK: - Options menu (the dots — gated by capability)

    private var optionsMenu: some View {
        Menu {
            Button {
                isShowingFeeSheet = true
            } label: {
                Label("Edit network fee", systemImage: "fuelpump")
            }

            if model.capability.supportsUTXO {
                Button {
                    isShowingUTXOSheet = true
                } label: {
                    Label("Select coins", systemImage: "bitcoinsign.circle")
                }
            }

            if model.capability.opReturnMaxBytes != nil {
                Button {
                    isShowingOpReturnSheet = true
                } label: {
                    Label(model.hasOpReturn ? "Edit OP_RETURN data" : "Add OP_RETURN data",
                          systemImage: "doc.text")
                }
            }

            // BIP-125 RBF — BTC/LTC only. Toggle writes model.signalsRBF,
            // which the draft + BitcoinTransactionSigner honor 1:1.
            if model.supportsRBF {
                Toggle(isOn: rbfBinding) {
                    Label("Replace-By-Fee (RBF)", systemImage: "arrow.triangle.2.circlepath")
                }
            }

            advancedMemoButton

            if model.chain.family == .evm {
                Button {
                    isShowingGasSheet = true
                } label: {
                    Label("Advanced gas", systemImage: "gauge.with.dots.needle.50percent")
                }
            }
        } label: {
            // Three dots only — no ring (FIX 6). Weight/size balanced with
            // the nav back chevron.
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .regular))
        }
        .accessibilityLabel(Text("More options"))
    }

    /// Binding into the @Observable compose model (State-held).
    private var rbfBinding: Binding<Bool> {
        Binding(
            get: { model.signalsRBF },
            set: { model.signalsRBF = $0 }
        )
    }

    @ViewBuilder
    private var advancedMemoButton: some View {
        switch model.capability.memoKind {
        case .destinationTag:
            Button { isShowingTagSheet = true } label: {
                Label(model.hasMemoValue ? "Edit destination tag" : "Add destination tag",
                      systemImage: "number")
            }
        case .tonComment:
            Button { isShowingCommentSheet = true } label: {
                Label(model.hasMemoValue ? "Edit comment" : "Add comment",
                      systemImage: "text.bubble")
            }
        case .nearFtMemo:
            // NEP-141 FT memo is for TOKEN transfers only — native NEAR
            // carries no memo (matrix: `.nearFtMemo` = "tokens only").
            // Show the option ONLY for a token send; native NEAR shows
            // nothing and carries no memo into the draft.
            if model.isToken {
                Button { isShowingMemoSheet = true } label: {
                    Label(model.hasMemoValue ? "Edit memo" : "Add a memo",
                          systemImage: "text.bubble")
                }
            }
        case .textMemo, .splMemo, .stellarMemo:
            Button { isShowingMemoSheet = true } label: {
                Label(model.hasMemoValue ? "Edit memo" : "Add a memo",
                      systemImage: "text.bubble")
            }
        case .none:
            EmptyView()
        }
    }

    // MARK: - Review CTA (functional layer)

    private var reviewBar: some View {
        GlassEffectContainer(spacing: UniSpacing.s) {
            reviewButton
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
        }
    }

    private var reviewButton: some View {
        UniButton(
            title: "Review",
            variant: .primary,
            isEnabled: model.canReview,
            action: reviewDraft
        )
    }

    private func reviewDraft() {
        guard let draft = model.makeDraft() else { return }
        onReview(draft)
    }

    // MARK: - Local-first reads (off the render path)

    private var activeWallet: WalletRecord? {
        ActiveWalletResolver.resolve(rawID: activeWalletIdRaw, wallets: allWallets)
    }

    /// When Solana dual-path is present, the send-from path title (Phantom /
    /// Trust Wallet) so Available is not confused with the home total.
    private var solanaSpendPathTitle: String? {
        guard chain == .solana, let wallet = activeWallet else { return nil }
        let lines = SolanaPathBalanceBreakdown.nativeLines(
            addresses: wallet.addresses,
            balances: activeBalancesObservation.balances,
            fallbackCurrencyCode: currencyCode
        )
        guard SolanaPathBalanceBreakdown.isDualPath(lines) else { return nil }
        return SolanaPathBalanceBreakdown.style(
            forAddress: fromAddress,
            walletAddresses: wallet.addresses
        )?.title
            ?? lines.first(where: \.isPreferred)?.style.title
            ?? lines.first?.style.title
    }

    private var balancesKey: String {
        guard let wallet = activeWallet else { return "none" }
        return "\(wallet.id.uuidString)|\(chain.rawValue)|\(activeBalancesObservation.revision)"
    }

    private var activeWalletScopeKey: String {
        "\(activeWalletIdRaw)|\(walletRecordsObservation.revision)"
    }

    /// Primary recipient address drives activation / tag / memo probes.
    private var recipientProbeKey: String {
        let primary = recipients.first?.address
            ?? model.amounts.first?.address
            ?? ""
        return "\(chain.rawValue)|\(primary)"
    }

    private func syncObservationScopes() {
        let scopedWalletId = activeWallet?.id ?? UUID(uuidString: activeWalletIdRaw)
        activeBalancesObservation.setWalletId(scopedWalletId)
    }

    /// Re-fetch / re-derive the fee when a material input changes. For
    /// account-model chains it's just the recipient count (amount doesn't
    /// change the fee). For UTXO chains the vsize-dependent fee + MAX also
    /// depend on the SELECTED COINS, the AMOUNT, the BYTE-FEE RATE and the
    /// TIER (FIX 3 + BUG 1 · fix #2) — fold all four in so changing coins /
    /// amount / TIER / the CUSTOM sat-vB re-derives the fee via
    /// `selectCoins`. The model's `utxoFeeKey` already fingerprints exactly
    /// these (cycle-free via `rawTotalCrypto`), so reuse it instead of a
    /// narrower key that omitted the rate — the old key never re-ran
    /// `recomputeUTXOFee` when the user changed only the custom rate, so the
    /// custom rate never drove the resolved vsize fee.
    private var feeRefreshKey: String {
        if model.capability.supportsUTXO {
            return "\(model.amounts.count)|\(model.utxoFeeKey)"
        }
        return "\(model.amounts.count)"
    }

    /// Balances from GRDB `token_balances`; account-state from
    /// `chain_account_states` when present (M-001 — not always empty).
    ///
    /// **Solana dual-path:** spendable balance is scoped to `fromAddress`
    /// only (the selected Phantom/Trust path). Summing every path made Max
    /// / validation allow more than the signing address holds, so Solana
    /// preflight failed with Token/System `custom program error: 0x1`
    /// (insufficient funds) even though the home total looked fine.
    private func resolveBalances() {
        guard let wallet = activeWallet else { return }
        let selectedToken = token
        let symbolUpper = (selectedToken?.symbol ?? chain.ticker).uppercased()
        var native: Decimal = 0
        var tokenBalance: Decimal?
        let chainAddresses = wallet.addresses.filter { $0.chainRaw == chain.rawValue }
        let fromTrimmed = fromAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let addressIds: Set<UUID> = {
            // Prefer the exact send-from row when present.
            if !fromTrimmed.isEmpty,
               let match = chainAddresses.first(where: {
                   $0.address == fromTrimmed
                       || (chain.family == .evm
                           && $0.address.caseInsensitiveCompare(fromTrimmed) == .orderedSame)
               }) {
                return [match.id]
            }
            // Fallback: preferred, then any chain row (legacy single-address).
            if let preferred = chainAddresses.first(where: \.isReceivePreferred) {
                return [preferred.id]
            }
            return Set(chainAddresses.map(\.id))
        }()
        for bal in activeBalancesObservation.balances {
            guard let addressId = bal.addressId ?? bal.address?.id,
                  addressIds.contains(addressId) else { continue }
            let amount = WalletFormatting.decimalAmount(rawBalance: bal.rawBalance, decimals: bal.decimals)
            if bal.tokenContract == nil && bal.tokenSymbol.uppercased() == chain.ticker.uppercased() {
                native += amount
            }
            if let selectedToken,
               bal.tokenSymbol.uppercased() == symbolUpper,
               tokenContractMatches(bal.tokenContract, selectedToken.contract, chain: selectedToken.chain) {
                tokenBalance = (tokenBalance ?? 0) + amount
            }
        }

        // Preferred fromAddress first; repository falls back to any chain row.
        let snapshot = (try? ChainAccountStateRepository(database: .shared).load(
            walletId: wallet.id,
            chain: chain,
            preferredAddress: fromAddress
        )) ?? .empty
        let state = snapshot.toComposeAccountState(
            nativeBalanceDisplay: native,
            decimals: chain.nativeDecimals
        )
        model.setBalances(native: native, token: tokenBalance, state: state)
    }

    private func tokenContractMatches(_ stored: String?, _ selected: String, chain: SupportedChain) -> Bool {
        guard let stored else { return false }
        if chain.family == .evm {
            return stored.caseInsensitiveCompare(selected) == .orderedSame
        }
        return stored == selected
    }

    /// Resolve the asset + native unit prices through the shared pricing
    /// ladder (cache-first, off-main), then apply on the main actor.
    private func resolvePrices() async {
        let assetSym = (token?.symbol ?? chain.ticker).uppercased()
        let nativeSym = chain.ticker.uppercased()
        let symbols = Array(Set([assetSym, nativeSym]))
        let prices = await TokenPricingEngine.shared.unitPrices(
            symbols: symbols, currencyCode: currencyCode.uppercased()
        )
        guard !Task.isCancelled else { return }
        model.setPrices(
            asset: prices[assetSym]?.amount,
            native: prices[nativeSym]?.amount
        )
    }

    /// P0-006: probe recipient account and set compose flags for real.
    private func probeRecipientAccount() async {
        let address = recipients.first?.address
            ?? model.amounts.first?.address
            ?? ""
        guard !address.isEmpty else {
            model.setRecipientAccountProbe(.none)
            return
        }
        let result = await SendRecipientAccountProbe.probe(
            chain: chain,
            recipientAddress: address
        )
        guard !Task.isCancelled else { return }
        model.setRecipientAccountProbe(result)
    }
}

// MARK: - Sheets dispatch

private extension View {
    /// Attaches all seven compose sheets in one place so the screen body
    /// stays readable. Each sheet is a native `NavigationStack` (Rule #15),
    /// carries `.id(directionKey)` BEFORE `.apertureEnvironment()` so a
    /// live LTR ↔ RTL switch rebuilds the sheet content (Rule #12 §G /
    /// #15 — FIX 8), then re-applies the theme/locale/direction
    /// preferences (Rule #12). Inside, each uses `UniButton` /
    /// `UniTextField` (Rules #19 / #4).
    func sheets(
        model: SendComposeModel,
        directionKey: String,
        isShowingFeeSheet: Binding<Bool>,
        isShowingUTXOSheet: Binding<Bool>,
        isShowingOpReturnSheet: Binding<Bool>,
        isShowingMemoSheet: Binding<Bool>,
        isShowingTagSheet: Binding<Bool>,
        isShowingCommentSheet: Binding<Bool>,
        isShowingGasSheet: Binding<Bool>
    ) -> some View {
        self
            .sheet(isPresented: isShowingFeeSheet) {
                SendFeeSheet(model: model).id(directionKey).apertureEnvironment()
            }
            .sheet(isPresented: isShowingUTXOSheet) {
                SendUTXOSheet(model: model).id(directionKey).apertureEnvironment()
            }
            .sheet(isPresented: isShowingOpReturnSheet) {
                SendOpReturnSheet(model: model).id(directionKey).apertureEnvironment()
            }
            .sheet(isPresented: isShowingMemoSheet) {
                SendMemoSheet(model: model).id(directionKey).apertureEnvironment()
            }
            .sheet(isPresented: isShowingTagSheet) {
                SendDestinationTagSheet(model: model).id(directionKey).apertureEnvironment()
            }
            .sheet(isPresented: isShowingCommentSheet) {
                SendCommentSheet(model: model).id(directionKey).apertureEnvironment()
            }
            .sheet(isPresented: isShowingGasSheet) {
                SendGasSheet(model: model).id(directionKey).apertureEnvironment()
            }
    }
}
