import SwiftUI
import SwiftData

/// **The Send v2 flow root.** Supersedes `SendFlowView` as the
/// `WalletHomeDestination.send` destination. Rebuilt from the
/// `design_handoff_send_v2` spec in the bloom/glass material.
///
/// Pushed onto the wallet-home `NavigationStack`, so it does NOT wrap its
/// body in another `NavigationStack` (M-004 — nested stacks break
/// navigation). A **flat state machine**: `@State step: Step` +
/// `Group { switch }` + `withAnimation`, the pattern `PinSetupFlow` and
/// the v1 flow both use.
///
/// **Flow (handoff):**
/// - A: asset → A1 recipient → (A2 resolved / A3 poisoning) →
/// - B: B1 amount → B2 review+simulation → (B3 whale) → authorize →
/// - C: C1 sending → C2 sent  (C3 speed-up sheet from the pending state)
///
/// **State (Rule #2 §C):** one `@Observable SendV2Model` threaded through
/// every screen, with the named domain seams (`resolveRecipient`,
/// `estimateFees`, `simulate`, `detectPoisoning`, `send`, `speedUp`,
/// `cancel`). Realistic placeholder data behind the seams (T-061..T-069).
///
/// **Sheets (Rule #12 + #15):** the v1 advanced power-sheets + the v2 fee /
/// asset-picker / guide sheets carry `.uniAppEnvironment()` + the
/// direction key + an opaque presentation background.
struct SendV2FlowView: View {
    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @AppStorage("languagePreference") private var sheetLanguageCode: String = LanguagePreference.systemCode
    @Environment(\.dismiss) private var dismiss

    @State private var model = SendV2Model()
    @State private var step: Step = .asset

    @State private var activeSheet: ActiveSheet?
    @State private var isShowingScan: Bool = false

    private var draft: SendDraft { model.draft }

    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: sheetLanguageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    var body: some View {
        Group {
            switch step {
            case .asset:
                SendAssetPickerView(
                    availableChains: availableChains,
                    onSelect: { asset in
                        draft.asset = asset
                        advance(to: .recipient)
                    },
                    onCancel: { dismiss() }
                )
            case .recipient:
                SendV2RecipientView(
                    model: model,
                    onResolved: { handleRecipientResolved() },
                    onScan: { isShowingScan = true },
                    onPaste: { value in handlePaste(value) },
                    onOpenGuide: { activeSheet = .recipientGuide }
                )
            case .poisoning:
                if let poison = model.recipientState.poison {
                    SendV2PoisoningView(
                        match: poison,
                        onUseSaved: {
                            draft.recipientInput = poison.savedAddress
                            Task { await model.resolveRecipient(poison.savedAddress); routeAfterResolve() }
                        },
                        onContinueAnyway: {
                            // Deliberate override: treat the pasted address
                            // as a plain resolved recipient.
                            model.recipientState = .resolved(
                                .init(name: nil, address: poison.pastedAddress,
                                      network: draft.network ?? .ethereum,
                                      isFirstSend: true, ensVerified: false)
                            )
                            advance(to: .amount)
                        },
                        onBack: { advance(to: .recipient) }
                    )
                }
            case .resolved:
                SendV2ResolvedView(
                    model: model,
                    onContinue: { advance(to: .amount) },
                    onTestSend: { startTestSend() },
                    onBack: { advance(to: .recipient) }
                )
            case .amount:
                SendV2AmountView(
                    model: model,
                    onReview: { advance(to: .review) },
                    onOpenAssetPicker: { activeSheet = .assetPicker }
                )
            case .review:
                SendV2ReviewView(
                    model: model,
                    onEditFee: { activeSheet = .feeSpeed },
                    onCommit: { handleCommit() },
                    onOpenFeeGuide: { activeSheet = .networkFeeGuide }
                )
            case .whale:
                SendV2WhaleCheckView(
                    model: model,
                    onConfirm: { advance(to: .authorize) },
                    onChangeAmount: { advance(to: .amount) }
                )
            case .authorize:
                SendAuthorizeView(
                    draft: draft,
                    onAuthorized: { advance(to: .sending) },
                    onCancel: { advance(to: .review) }
                )
            case .sending:
                SendV2SendingView(model: model)
                    .task {
                        await model.send()
                        if model.lifecycle == .confirmed {
                            draft.outcome = .sent
                            advance(to: .sent)
                        }
                    }
            case .sent:
                SendV2SentView(
                    model: model,
                    amountText: amountText,
                    recipientDisplay: draft.recipientDisplay,
                    onDone: { dismiss() },
                    onShareReceipt: { activeSheet = .shareReceipt },
                    onViewExplorer: { activeSheet = .explorer }
                )
            }
        }
        .toolbar(step.hidesNavBar ? .hidden : .automatic, for: .navigationBar)
        .navigationBarBackButtonHidden(step != .asset)
        .animation(.easeInOut(duration: 0.28), value: step)
        .onAppear {
            if step == .asset && draft.asset == nil { draft.reset() }
            draft.heldAssets = heldAssets
            _ = model.estimateFees()
        }
        .toolbar {
            if step.showsInFlowBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        stepBack()
                    } label: {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 17, weight: .semibold))
                            .accessibilityLabel(Text("Back"))
                    }
                }
            }
        }
        // QR scanner (Flow D2).
        .fullScreenCover(isPresented: $isShowingScan) {
            SendV2ScannerView(
                onDetected: { detected in
                    isShowingScan = false
                    draft.recipientInput = detected
                    Task { await model.resolveRecipient(detected); routeAfterResolve() }
                },
                onCancel: { isShowingScan = false }
            )
            .id(sheetDirectionKey)
            .uniAppEnvironment()
        }
        // Advanced + v2 sheets.
        .sheet(item: $activeSheet) { sheet in
            sheetContent(sheet)
                .id(sheetDirectionKey)
                .uniAppEnvironment()
                .presentationBackground(UniColors.Background.primary)
        }
    }

    // MARK: - Sheet content

    @ViewBuilder
    private func sheetContent(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .assetPicker:
            SendV2AssetChainPickerSheet(
                model: model,
                availableChains: availableChains,
                onSelect: { asset in
                    draft.asset = asset
                    _ = model.estimateFees()
                    activeSheet = nil
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        case .feeSpeed:
            SendV2FeeSpeedSheet(
                model: model,
                onAdvanced: { presentAdvancedSheet() },
                onApply: { activeSheet = nil }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case .speedUp:
            SendV2SpeedUpSheet(
                model: model,
                onClose: { activeSheet = nil }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        case .shareReceipt:
            SendV2ShareReceiptSheet(
                model: model,
                amountText: amountText,
                recipientDisplay: draft.recipientDisplay,
                onClose: { activeSheet = nil }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        case .explorer:
            SendV2ExplorerSheet(
                model: model,
                onClose: { activeSheet = nil }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        case .advancedBitcoin:
            SendAdvancedBitcoinSheet(
                draft: draft,
                onDone: { activeSheet = nil },
                onOpenCoinControl: { activeSheet = .bitcoinCoinControl },
                onOpenUTXOGuide: { activeSheet = .utxoGuide },
                onOpenRBFGuide: { activeSheet = .rbfGuide }
            )
            .presentationDetents([.large])
        case .bitcoinCoinControl:
            SendAdvancedBitcoinCoinControlSheet(
                draft: draft,
                onApply: { activeSheet = .advancedBitcoin },
                onCancel: { activeSheet = .advancedBitcoin }
            )
            .presentationDetents([.large])
        case let .advancedEVM(chain):
            SendAdvancedEVMSheet(draft: draft, chain: chain, onDone: { activeSheet = .feeSpeed })
                .presentationDetents([.large])
        case .advancedSolana:
            SendAdvancedSolanaSheet(draft: draft, onDone: { activeSheet = .feeSpeed })
                .presentationDetents([.large])
        case .recipientGuide:
            SendRecipientGuideSheet(onDismiss: { activeSheet = nil })
                .intrinsicHeightSheet()
        case .networkFeeGuide:
            SendNetworkFeeGuideSheet(onDismiss: { activeSheet = nil })
                .intrinsicHeightSheet()
        case .rbfGuide:
            SendRBFGuideSheet(onDismiss: { activeSheet = nil })
                .intrinsicHeightSheet()
        case .utxoGuide:
            SendUTXOGuideSheet(onDismiss: { activeSheet = nil })
                .intrinsicHeightSheet()
        }
    }

    private func presentAdvancedSheet() {
        guard let network = draft.network else { return }
        switch network.family {
        case .bitcoin: activeSheet = .advancedBitcoin
        case .evm:     activeSheet = .advancedEVM(network)
        case .ed25519 where network == .solana: activeSheet = .advancedSolana
        default: break
        }
    }

    // MARK: - Routing

    /// Called when the recipient screen reports a resolution finished.
    private func handleRecipientResolved() {
        routeAfterResolve()
    }

    private func routeAfterResolve() {
        switch model.recipientState {
        case .poisoned:
            advance(to: .poisoning)
        case .resolved(let r):
            // Show the resolved + first-time notice screen when it's a
            // first send or an ENS resolution; otherwise jump to amount.
            if r.isFirstSend || r.name != nil {
                advance(to: .resolved)
            } else {
                advance(to: .amount)
            }
        default:
            break  // stay on recipient (invalid / resolving)
        }
    }

    private func handlePaste(_ value: String) {
        draft.recipientInput = value
        model.pasteValidation = model.validatePaste(value)
        Task {
            await model.resolveRecipient(value)
            // Don't auto-advance on paste — the recipient screen shows the
            // validation card; the user taps Continue (or the poisoning
            // guard intercepts).
            if case .poisoned = model.recipientState { advance(to: .poisoning) }
        }
    }

    private func startTestSend() {
        // Flow I — prefill a small test amount (1 unit of display currency
        // converted at the asset rate) and jump to Amount. The "remaining"
        // story (I2/I3) is design-stubbed via the prefill.
        draft.isShowingFiat = false
        let rate = draft.unitFiatRate
        if rate > 0 {
            let oneUnit = (Decimal(1) / rate)
            draft.amountInput = WalletFormatting.native(oneUnit, decimals: draft.asset?.decimals ?? 8)
        }
        advance(to: .amount)
    }

    private func handleCommit() {
        if model.isWhaleSend {
            advance(to: .whale)
        } else {
            advance(to: .authorize)
        }
    }

    // MARK: - Step machine

    private func advance(to next: Step) {
        withAnimation(.easeInOut(duration: 0.28)) { step = next }
    }

    private func stepBack() {
        guard let previous = step.previous else { return }
        advance(to: previous)
    }

    // MARK: - Derived

    private var amountText: String {
        "\(WalletFormatting.native(draft.cryptoAmount, decimals: draft.asset?.decimals ?? 8)) \(draft.unitTicker)"
    }

    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw),
           let match = allWallets.first(where: { $0.id == uuid }) {
            return match
        }
        return allWallets.first
    }

    private var availableChains: [SupportedChain] {
        guard let wallet = activeWallet else { return [] }
        let chains: [SupportedChain] = wallet.addresses.compactMap { record in
            guard !record.address.isEmpty else { return nil }
            return SupportedChain(rawValue: record.chainRaw)
        }
        let set = Set(chains)
        return SupportedChain.allCases.filter { set.contains($0) }
    }

    private var heldAssets: [SendHeldAsset] {
        guard let wallet = activeWallet else { return [] }
        var out: [SendHeldAsset] = []
        for address in wallet.addresses {
            guard let chain = SupportedChain(rawValue: address.chainRaw) else { continue }
            for bal in address.balances where !bal.rawBalance.isEmpty && bal.rawBalance != "0" {
                let amount = WalletFormatting.decimalAmount(rawBalance: bal.rawBalance, decimals: bal.decimals)
                guard amount > 0 else { continue }
                let rate: Decimal? = bal.fiatValueCached > 0 ? (bal.fiatValueCached / amount) : nil
                out.append(SendHeldAsset(network: chain, symbol: bal.tokenSymbol, contract: bal.tokenContract, amount: amount, fiatRate: rate))
            }
        }
        return out
    }
}

// MARK: - Step + sheets

extension SendV2FlowView {
    enum Step: Hashable {
        case asset, recipient, poisoning, resolved, amount, review, whale, authorize, sending, sent

        var previous: Step? {
            switch self {
            case .asset, .recipient, .poisoning, .resolved: return nil
            case .amount:    return .recipient
            case .review:    return .amount
            case .whale:     return .review
            case .authorize: return .review
            case .sending, .sent: return nil
            }
        }

        var showsInFlowBack: Bool {
            switch self {
            case .amount, .review: return true
            default: return false
            }
        }

        var hidesNavBar: Bool {
            switch self {
            case .recipient, .poisoning, .resolved, .amount, .sending, .sent: return true
            default: return false
            }
        }
    }

    enum ActiveSheet: Identifiable, Hashable {
        case assetPicker
        case feeSpeed
        case speedUp
        case shareReceipt
        case explorer
        case advancedBitcoin
        case bitcoinCoinControl
        case advancedEVM(SupportedChain)
        case advancedSolana
        case recipientGuide
        case networkFeeGuide
        case rbfGuide
        case utxoGuide

        var id: String {
            switch self {
            case .assetPicker:        return "assetPicker"
            case .feeSpeed:           return "feeSpeed"
            case .speedUp:            return "speedUp"
            case .shareReceipt:       return "shareReceipt"
            case .explorer:           return "explorer"
            case .advancedBitcoin:    return "advancedBitcoin"
            case .bitcoinCoinControl: return "bitcoinCoinControl"
            case .advancedEVM(let c): return "advancedEVM.\(c.rawValue)"
            case .advancedSolana:     return "advancedSolana"
            case .recipientGuide:     return "recipientGuide"
            case .networkFeeGuide:    return "networkFeeGuide"
            case .rbfGuide:           return "rbfGuide"
            case .utxoGuide:          return "utxoGuide"
            }
        }
    }
}
