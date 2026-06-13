import SwiftUI
import SwiftData

/// **The Send flow root.**
///
/// Replaces `SendPlaceholderView` as the `WalletHomeDestination.send`
/// destination. Because this view is *pushed onto the wallet-home's
/// `NavigationStack`*, it must NOT wrap its body in another
/// `NavigationStack` (M-004 — nested stacks break navigation). It's a
/// **flat state machine**: `@State step: Step` + `Group { switch }` +
/// `withAnimation` to advance, exactly the pattern `PinSetupFlow` uses.
///
/// **Flow:** asset picker → recipient → amount → review →
/// (swipe commits) → authorize → sending → sent. Back at each step pops
/// to the prior step (the flat machine pops one step; the asset-picker
/// step pops out of the flow entirely via the wallet-home back chevron).
///
/// **State (Rule #2 §C):** one `@Observable SendDraft` (not
/// `ObservableObject`) threaded through every screen. UI state only — no
/// signing / broadcast / RPC. The functional seams are `// TODO:
/// (T-061..T-066)`.
///
/// **Sheets (Rule #12 + #15):** the advanced + guide sheets carry
/// `.uniAppEnvironment()` + the direction key + an opaque presentation
/// background, and are native `NavigationStack` (advanced) / `UniSheet`
/// (guides) shapes.
struct SendFlowView: View {
    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @AppStorage("languagePreference") private var sheetLanguageCode: String = LanguagePreference.systemCode
    @Environment(\.dismiss) private var dismiss

    /// The flow's draft — one source of UI truth for every step.
    @State private var draft = SendDraft()
    /// The current step in the flat state machine.
    @State private var step: Step = .asset

    // Sheet presentation flags.
    @State private var activeSheet: ActiveSheet?
    @State private var isShowingScan: Bool = false

    /// Rule #12 §G direction-only key for sheet rebuilds.
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
                SendRecipientView(
                    draft: draft,
                    onContinue: { advance(to: .amount) },
                    onScan: { isShowingScan = true },
                    onOpenGuide: { activeSheet = .recipientGuide }
                )
            case .amount:
                SendAmountView(
                    draft: draft,
                    onReview: { advance(to: .review) }
                )
            case .review:
                SendReviewView(
                    draft: draft,
                    onEditFee: { presentAdvancedSheet() },
                    onCommit: { advance(to: .authorize) },
                    onOpenFeeGuide: { activeSheet = .networkFeeGuide }
                )
            case .authorize:
                SendAuthorizeView(
                    draft: draft,
                    onAuthorized: { advance(to: .sending) },
                    onCancel: { advance(to: .review) }
                )
            case .sending:
                SendingView(networkName: draft.network?.displayName ?? "")
                    .task {
                        // `// TODO: (T-066)` real broadcast drives this.
                        // For the design, advance to Sent after a beat.
                        try? await Task.sleep(for: .seconds(1.8))
                        draft.outcome = .sent
                        advance(to: .sent)
                    }
            case .sent:
                SentView(
                    amountText: amountText,
                    recipientDisplay: draft.recipientDisplay,
                    onDone: { dismiss() },
                    onViewExplorer: { /* `// TODO: (T-066)` open explorer URL */ }
                )
            case .failed:
                SendFailedView(
                    onRetry: { advance(to: .review) },
                    onDone: { dismiss() }
                )
            }
        }
        // Hide the wallet-home back chevron / nav bar on the terminal dark
        // screens so they read full-bleed (the handoff's dark moment).
        .toolbar(step.hidesNavBar ? .hidden : .automatic, for: .navigationBar)
        .navigationBarBackButtonHidden(step != .asset && step != .recipient)
        .animation(.easeInOut(duration: 0.28), value: step)
        .onAppear {
            // Fresh draft each time the flow is entered.
            if step == .asset && draft.asset == nil { draft.reset() }
            // Feed the draft the wallet's REAL held balances from the
            // database (Rule #27 §D — Send reads from the store, not
            // SendMockData). Snapshotting on entry is right: a balance
            // doesn't change mid-compose, and the home screen's refresh
            // has already populated the DB.
            draft.heldAssets = heldAssets
        }
        // Custom leading back for the in-flow steps (amount / review /
        // authorize) so the user can step back without leaving the flow.
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
        // QR scan (design stub — real scanner wires the camera).
        .sheet(isPresented: $isShowingScan) {
            scanPlaceholder
                .id(sheetDirectionKey)
                .uniAppEnvironment()
                .presentationDetents([.medium])
                .presentationBackground(UniColors.Background.primary)
        }
        // Advanced + guide sheets.
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
            SendAdvancedEVMSheet(
                draft: draft,
                chain: chain,
                onDone: { activeSheet = nil }
            )
            .presentationDetents([.large])
        case .advancedSolana:
            SendAdvancedSolanaSheet(
                draft: draft,
                onDone: { activeSheet = nil }
            )
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

    /// Pick the advanced sheet shaped by the selected network's family
    /// (Rule: never show controls a chain doesn't have). Long-tail chains
    /// don't reach here — the Review fee row hides the Edit affordance for
    /// them via `SendAdvancedParams.hasAdvancedSheet(for:)`.
    private func presentAdvancedSheet() {
        guard let network = draft.network else { return }
        switch network.family {
        case .bitcoin:
            activeSheet = .advancedBitcoin
        case .evm:
            activeSheet = .advancedEVM(network)
        case .ed25519 where network == .solana:
            activeSheet = .advancedSolana
        default:
            break
        }
    }

    // MARK: - Scan placeholder

    private var scanPlaceholder: some View {
        NavigationStack {
            VStack(spacing: UniSpacing.m) {
                Spacer()
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(UniColors.Icon.tertiary)
                UniBody(
                    text: "Scanning lands with the real Send flow. For now, paste or pick a recent recipient.",
                    alignment: .center,
                    color: UniColors.Text.secondary
                )
                .padding(.horizontal, UniSpacing.l)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(UniColors.Background.primary)
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isShowingScan = false }
                }
            }
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

    /// Chains the active wallet has a derived address for, in canonical
    /// order — the same resolver `ReceiveView` uses, so Send coverage
    /// matches Receive coverage exactly.
    private var availableChains: [SupportedChain] {
        guard let wallet = activeWallet else { return [] }
        let chains: [SupportedChain] = wallet.addresses.compactMap { record in
            guard !record.address.isEmpty else { return nil }
            return SupportedChain(rawValue: record.chainRaw)
        }
        let set = Set(chains)
        return SupportedChain.allCases.filter { set.contains($0) }
    }

    /// The active wallet's held balances, read from the database
    /// (`TokenBalanceRecord` via the wallet → addresses → balances
    /// relationship), flattened to the Sendable `SendHeldAsset` the
    /// draft consumes. Both the amount AND the implied fiat rate come
    /// from the persisted rows — no `SendMockData` (Rule #27 §D / T-061).
    private var heldAssets: [SendHeldAsset] {
        guard let wallet = activeWallet else { return [] }
        var out: [SendHeldAsset] = []
        for address in wallet.addresses {
            guard let chain = SupportedChain(rawValue: address.chainRaw) else { continue }
            for bal in address.balances where !bal.rawBalance.isEmpty && bal.rawBalance != "0" {
                let amount = WalletFormatting.decimalAmount(
                    rawBalance: bal.rawBalance,
                    decimals: bal.decimals
                )
                guard amount > 0 else { continue }
                let rate: Decimal? = bal.fiatValueCached > 0 ? (bal.fiatValueCached / amount) : nil
                out.append(SendHeldAsset(
                    network: chain,
                    symbol: bal.tokenSymbol,
                    contract: bal.tokenContract,
                    amount: amount,
                    fiatRate: rate
                ))
            }
        }
        return out
    }
}

// MARK: - Step

extension SendFlowView {
    /// The linear steps of the flow. `previous` powers the in-flow back
    /// button; `hidesNavBar` / `showsInFlowBack` shape the chrome per
    /// step.
    enum Step: Hashable {
        case asset, recipient, amount, review, authorize, sending, sent, failed

        /// The step a back tap returns to (nil = no in-flow back).
        var previous: Step? {
            switch self {
            case .asset:     return nil
            case .recipient: return nil   // back chevron pops out of the flow
            case .amount:    return .recipient
            case .review:    return .amount
            case .authorize: return .review
            case .sending, .sent, .failed: return nil
            }
        }

        /// Whether to show the custom in-flow back chevron (amount /
        /// review / authorize). The asset + recipient steps use the
        /// wallet-home's native back chevron to pop out of the flow.
        var showsInFlowBack: Bool {
            switch self {
            case .amount, .review: return true
            default:               return false
            }
        }

        /// Terminal dark screens hide the nav bar for the full-bleed
        /// moment.
        var hidesNavBar: Bool {
            switch self {
            case .sending, .sent, .failed: return true
            default:                       return false
            }
        }
    }

    /// Sheets the flow can present.
    enum ActiveSheet: Identifiable, Hashable {
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
