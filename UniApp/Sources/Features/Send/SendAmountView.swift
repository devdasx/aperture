import SwiftUI
import SwiftData

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
/// **Local-first (Rule #27).** Balances + the reserve account-state come
/// from the SwiftData store via `@Query`, resolved off the render path in
/// `.task` (Rule #28). The live fee + UTXO set are the action-time network
/// reads the model owns (the Send carve-out). Prices flow through the same
/// `TokenPricingEngine` ladder the wallet home uses, cache-first.
///
/// **RTL (Rule #11).** Layout is semantic; the amount, the asset symbol,
/// and any address are LTR-locked because they're transcribable artifacts.
struct SendAmountView: View {
    let chain: SupportedChain
    let tokenSymbol: String?
    let fromAddress: String
    let recipients: [SendRecipientEntry]
    /// Proceed to Review with the assembled draft.
    let onReview: (SendDraft) -> Void

    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""

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
    @FocusState private var amountFocused: Bool

    /// Direction key for the compose sheets (Rule #12 §G / #15): rebuild
    /// the sheet content only when crossing the LTR ↔ RTL boundary, the one
    /// case iOS's locked `semanticContentAttribute` requires it.
    @AppStorage("languagePreference") private var sheetLanguageCode: String = LanguagePreference.systemCode
    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: sheetLanguageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    private var currencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey) ?? CurrencyPreference.defaultCode
    }

    init(
        chain: SupportedChain,
        tokenSymbol: String?,
        fromAddress: String,
        recipients: [SendRecipientEntry],
        onReview: @escaping (SendDraft) -> Void
    ) {
        self.chain = chain
        self.tokenSymbol = tokenSymbol
        self.fromAddress = fromAddress
        self.recipients = recipients
        self.onReview = onReview
        let catalog = AssetCatalog.allAssets.first { $0.symbol == tokenSymbol && $0.chain == chain }
            ?? AssetCatalog.allAssets.first { $0.symbol == tokenSymbol }
        let code = UserDefaults.standard.string(forKey: CurrencyPreference.storageKey) ?? CurrencyPreference.defaultCode
        _model = State(initialValue: SendComposeModel(
            chain: chain, tokenSymbol: tokenSymbol,
            tokenContract: catalog?.contract,
            tokenDecimals: catalog?.decimals,
            fromAddress: fromAddress,
            recipients: recipients,
            currencyCode: code
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                if model.isMultiRecipient {
                    SendAmountMultiList(model: model, selectionTapCount: $selectionTapCount)
                } else {
                    SendAmountHero(
                        model: model,
                        amountFocused: $amountFocused,
                        selectionTapCount: $selectionTapCount
                    )
                }

                feeRow

                if let reserve = reserveNote {
                    reserveBanner(reserve)
                }

                if let blocking = model.blockingError, model.totalCrypto > 0 {
                    blockingBanner(blocking)
                }
            }
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.m)
            .padding(.bottom, UniSpacing.xxxl + UniSpacing.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
        .background(UniColors.Background.primary)
        .uniHaptic(.selection, trigger: selectionTapCount)
        .safeAreaInset(edge: .bottom) { reviewBar }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                CoinTitleBar(chain: chain, tokenSymbol: tokenSymbol, verb: "Send")
            }
            ToolbarItem(placement: .topBarTrailing) { optionsMenu }
        }
        .task(id: balancesKey) { resolveBalances() }
        .task { await resolvePrices() }
        .task { await model.loadFee() }
        .task { await model.loadUTXOs() }
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
        // Keep MAX tracking the live fee: when the resolved worst-case fee
        // changes (tier switch, rate refresh) while MAX is engaged, re-run
        // `engageMax()` so the field always reflects the current tier's
        // worst-case reservation (FIX 2). Keyed on the Decimal because
        // `FeeChoice` isn't `Equatable`.
        .onChange(of: model.resolvedFee?.worstCaseTotalNative) { _, _ in
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

    // MARK: - Fee row (content layer; tap opens the fee sheet)

    private var feeRow: some View {
        Button { isShowingFeeSheet = true } label: {
            UniCard {
                HStack(spacing: UniSpacing.s) {
                    Image(systemName: "fuelpump.fill")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(UniColors.Icon.secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Network fee")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.primary)
                        feeSubtitle
                    }
                    Spacer(minLength: UniSpacing.s)
                    feeValue
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.tertiary)
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var feeSubtitle: some View {
        switch model.feeState {
        case .idle, .loading:
            Text("Fetching the current rate…")
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.tertiary)
        case .failed(let message):
            Text(verbatim: message)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Status.warningForeground)
        case .loaded:
            if let note = model.feeQuote?.note {
                Text(verbatim: note)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
                    .lineLimit(2)
            } else {
                Text(verbatim: model.selectedTier.label)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }
        }
    }

    @ViewBuilder
    private var feeValue: some View {
        if model.feeState == .loading || model.feeState == .idle {
            ProgressView().controlSize(.small)
        } else if let fee = model.resolvedFee {
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: "\(WalletFormatting.native(fee.estimatedTotalNative, decimals: 8)) \(chain.ticker)")
                    .font(UniTypography.callout.monospacedDigit())
                    .foregroundStyle(UniColors.Text.primary)
                    .environment(\.layoutDirection, .leftToRight)
                if let fiat = model.feeFiat {
                    Text(verbatim: WalletFormatting.fiat(fiat, currencyCode: currencyCode))
                        .font(UniTypography.caption1.monospacedDigit())
                        .foregroundStyle(UniColors.Text.tertiary)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
    }

    // MARK: - Reserve / activation banner (honest)

    private var reserveNote: String? {
        // Standing reserve (XRP, Stellar, Polkadot ED, Solana rent, NEAR).
        switch chain {
        case .ripple:
            return String(localized: "XRP keeps a 1 XRP base reserve (plus 0.2 XRP per object) locked to keep your account open.")
        case .stellar:
            return String(localized: "Stellar keeps a minimum balance (from 1 XLM) reserved to keep your account active.")
        case .polkadot:
            return String(localized: "Polkadot needs 0.01 DOT to remain — dropping below it would close the account and lose the funds.")
        case .solana:
            return String(localized: "Solana keeps ~0.00089 SOL as the rent-exempt minimum so the account stays on-chain.")
        case .near:
            return String(localized: "NEAR keeps a small amount locked for account storage; it can't be sent.")
        case .tron where model.recipientNeedsActivation:
            return String(localized: "This recipient isn't activated yet — sending will cost about 1.1 TRX extra to create the account.")
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
                .foregroundStyle(UniColors.Status.warningForeground)
            Text(verbatim: error.message)
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UniSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: UniRadius.row, style: .continuous)
                .fill(UniColors.Status.warningBackground)
        )
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

            advancedMemoButton

            if model.chain.family == .evm {
                Button {
                    isShowingGasSheet = true
                } label: {
                    Label("Advanced gas", systemImage: "gauge.with.dots.needle.50percent")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17, weight: .regular))
        }
        .accessibilityLabel(Text("More options"))
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
        case .textMemo, .cosmosMemo, .splMemo, .stellarMemo:
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
            UniButton(
                title: "Review",
                variant: .primary,
                isEnabled: model.canReview,
                action: {
                    guard let draft = model.makeDraft() else { return }
                    onReview(draft)
                }
            )
            .padding(.horizontal, UniSpacing.l)
            .padding(.top, UniSpacing.s)
            .padding(.bottom, UniSpacing.xs)
        }
    }

    // MARK: - Local-first reads (off the render path)

    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw),
           let match = allWallets.first(where: { $0.id == uuid }) { return match }
        return allWallets.first
    }

    private var balancesKey: String {
        guard let wallet = activeWallet else { return "none" }
        var rows = 0
        var newest = Date.distantPast
        for address in wallet.addresses where address.chainRaw == chain.rawValue {
            rows += address.balances.count
            for b in address.balances where b.updatedAt > newest { newest = b.updatedAt }
        }
        return "\(wallet.id.uuidString)|\(chain.rawValue)|\(rows)|\(newest.timeIntervalSince1970)"
    }

    /// Re-fetch / re-derive the fee when a material input changes. For
    /// account-model chains it's just the recipient count (amount doesn't
    /// change the fee). For UTXO chains the vsize-dependent fee + MAX also
    /// depend on the SELECTED COINS and the AMOUNT (FIX 3) — fold both in
    /// so changing coins/amount re-derives the fee via `selectCoins`.
    private var feeRefreshKey: String {
        if model.capability.supportsUTXO {
            let coins = (model.selectedUTXOs ?? model.availableUTXOs)
                .map(\.id).sorted().joined(separator: ",")
            let amount = SendComposeModel.plainString(
                model.totalCrypto, decimals: model.effectiveDecimals)
            return "\(model.amounts.count)|\(coins)|\(amount)"
        }
        return "\(model.amounts.count)"
    }

    /// Read the native + token balance for THIS chain from the active
    /// wallet's address rows, plus the reserve account state.
    private func resolveBalances() {
        guard let wallet = activeWallet else { return }
        let symbolUpper = (tokenSymbol ?? chain.ticker).uppercased()
        var native: Decimal = 0
        var token: Decimal?
        let state = SendAmountMath.AccountState()
        for address in wallet.addresses where address.chainRaw == chain.rawValue {
            for bal in address.balances {
                let amount = WalletFormatting.decimalAmount(rawBalance: bal.rawBalance, decimals: bal.decimals)
                if bal.tokenContract == nil && bal.tokenSymbol.uppercased() == chain.ticker.uppercased() {
                    native += amount
                }
                if tokenSymbol != nil, bal.tokenSymbol.uppercased() == symbolUpper, bal.tokenContract != nil {
                    token = (token ?? 0) + amount
                }
            }
        }
        model.setBalances(native: native, token: token, state: state)
    }

    /// Resolve the asset + native unit prices through the shared pricing
    /// ladder (cache-first, off-main), then apply on the main actor.
    private func resolvePrices() async {
        let assetSym = (tokenSymbol ?? chain.ticker).uppercased()
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
}

// MARK: - Sheets dispatch

private extension View {
    /// Attaches all seven compose sheets in one place so the screen body
    /// stays readable. Each sheet is a native `NavigationStack` (Rule #15),
    /// carries `.id(directionKey)` BEFORE `.uniAppEnvironment()` so a
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
                SendFeeSheet(model: model).id(directionKey).uniAppEnvironment()
            }
            .sheet(isPresented: isShowingUTXOSheet) {
                SendUTXOSheet(model: model).id(directionKey).uniAppEnvironment()
            }
            .sheet(isPresented: isShowingOpReturnSheet) {
                SendOpReturnSheet(model: model).id(directionKey).uniAppEnvironment()
            }
            .sheet(isPresented: isShowingMemoSheet) {
                SendMemoSheet(model: model).id(directionKey).uniAppEnvironment()
            }
            .sheet(isPresented: isShowingTagSheet) {
                SendDestinationTagSheet(model: model).id(directionKey).uniAppEnvironment()
            }
            .sheet(isPresented: isShowingCommentSheet) {
                SendCommentSheet(model: model).id(directionKey).uniAppEnvironment()
            }
            .sheet(isPresented: isShowingGasSheet) {
                SendGasSheet(model: model).id(directionKey).uniAppEnvironment()
            }
    }
}
