import SwiftUI
import SwiftData

/// **Send screen — asset-first bottom sheet.** The twin of `ReceiveView`,
/// rebuilt step by step from our own Receive design (no external handoff):
/// "what are you sending?" first, "on which network?" second (for
/// tokens), then compose (amount + recipient — the next increment).
///
/// **Navigation contract (mirrors Receive):**
/// - Step 1 (asset list) → close sheet (swipe-down + system close).
/// - Step 2 (network picker, tokens only) → back chevron pops to Step 1.
/// - Step 3 (compose) → back chevron pops to Step 2 (token) or Step 1
///   (native, which skips the network picker).
///
/// Steps 1 and 2 are fully real: the asset list is the live local-first
/// asset universe filtered to the wallet's chains, and the network picker
/// lists the real networks the wallet can sign from. Step 3 (compose) is
/// the seam where the next increment — amount entry + recipient — lands.
struct SendView: View {
    @Query(sort: \WalletRecord.sortOrder) private var allWallets: [WalletRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""

    /// The sheet's own NavigationPath — lives on the sheet root so it can
    /// rebuild via `.id(sheetDirectionKey)` (Rule #12 §G) without losing
    /// the user's position.
    @Binding var navigationPath: NavigationPath

    /// Dismisses the whole Send sheet — the honest Review "Done" action
    /// while signing/broadcast is the next increment.
    @Environment(\.dismiss) private var dismiss

    /// The chain the user tapped that has no derived address on the active
    /// wallet — drives the honest "no address" alert instead of a dead tap.
    @State private var missingAddressChain: SupportedChain?
    @State private var isShowingMissingAddressAlert: Bool = false

    /// Real holdings snapshot (balances + per-(chain,symbol) tx counts),
    /// rebuilt off the render path when balances change (Rule #28). Drives
    /// the balance display + the high→low sort in both pickers.
    @State private var holdings: AssetPickerHoldings = .empty

    /// Real recent-recipients snapshot (outgoing-tx counterparties + send
    /// counts), rebuilt off the render path alongside holdings. Drives the
    /// recipient step's recent list + first-send check.
    @State private var recents: RecentRecipientsIndex = .empty

    private var currencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey) ?? CurrencyPreference.defaultCode
    }

    /// Cheap change-detector for the holdings rebuild — wallet id + the
    /// balance-row count + the newest balance timestamp (so a value
    /// refresh re-sorts).
    private var holdingsKey: String {
        guard let wallet = activeWallet else { return "none" }
        var rows = 0
        var newest = Date.distantPast
        for address in wallet.addresses {
            rows += address.balances.count
            for bal in address.balances where bal.updatedAt > newest { newest = bal.updatedAt }
        }
        return "\(wallet.id.uuidString)|\(rows)|\(newest.timeIntervalSince1970)"
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            SendAssetListView(
                availableChains: availableChains,
                holdings: holdings,
                currencyCode: currencyCode,
                onSelectNative: { chain in
                    guard let address = address(for: chain) else {
                        presentMissingAddress(chain)
                        return
                    }
                    // Native coin: the network IS the chain — skip the
                    // network picker and go straight to the recipient step.
                    navigationPath.append(
                        SendDestination.recipient(chain: chain, tokenSymbol: nil, fromAddress: address)
                    )
                },
                onSelectToken: { asset in
                    navigationPath.append(SendDestination.networkPicker(asset))
                }
            )
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SendDestination.self) { destination in
                switch destination {
                case let .networkPicker(asset):
                    SendNetworkPickerView(
                        token: asset,
                        holdings: holdings,
                        currencyCode: currencyCode,
                        onSelectNetwork: { chain in
                            guard let address = address(for: chain) else {
                                presentMissingAddress(chain)
                                return
                            }
                            let symbol: String? = {
                                if case let .token(symbol, _, _) = asset { return symbol }
                                return nil
                            }()
                            navigationPath.append(
                                SendDestination.recipient(chain: chain, tokenSymbol: symbol, fromAddress: address)
                            )
                        }
                    )
                case let .recipient(chain, tokenSymbol, fromAddress):
                    SendRecipientView(
                        chain: chain,
                        tokenSymbol: tokenSymbol,
                        fromAddress: fromAddress,
                        recents: recents,
                        onContinue: { recipients in
                            navigationPath.append(
                                SendDestination.amount(
                                    chain: chain, tokenSymbol: tokenSymbol, fromAddress: fromAddress,
                                    recipients: recipients
                                )
                            )
                        }
                    )
                case let .amount(chain, tokenSymbol, fromAddress, recipients):
                    SendAmountView(
                        chain: chain,
                        tokenSymbol: tokenSymbol,
                        fromAddress: fromAddress,
                        recipients: recipients,
                        onReview: { draft in
                            navigationPath.append(SendDestination.review(draft))
                        }
                    )
                case let .review(draft):
                    SendReviewLoader(
                        draft: draft,
                        walletId: activeWallet?.id ?? UUID(),
                        walletHasPassphrase: activeWallet?.hasPassphrase ?? false,
                        onClose: closeFlow
                    )
                }
            }
        }
        .onChange(of: activeWalletIdRaw) { _, _ in
            // Wallet switched under us — reset to step 1 so we never carry
            // a from-address from the prior wallet.
            navigationPath = NavigationPath()
        }
        .task(id: activeWalletHealKey) {
            healActiveWalletIdIfNeeded()
        }
        .task(id: holdingsKey) {
            holdings = AssetPickerHoldings(wallet: activeWallet)
            recents = RecentRecipientsIndex(wallet: activeWallet)
        }
        .alert(
            Text("No address for this network"),
            isPresented: $isShowingMissingAddressAlert,
            presenting: missingAddressChain
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { chain in
            Text("This wallet has no \(chain.displayName) address yet, so there's nothing to send from on this network. Aperture may still be deriving your accounts — try again in a moment.")
        }
    }

    private func presentMissingAddress(_ chain: SupportedChain) {
        missingAddressChain = chain
        isShowingMissingAddressAlert = true
    }

    /// Close the entire Send flow (dismiss the sheet). The Send sheet's
    /// `onDismiss` resets the path, so the next presentation starts at
    /// Step 1.
    private func closeFlow() {
        dismiss()
    }

    // MARK: - Derived (mirrors ReceiveView)

    private var activeWallet: WalletRecord? {
        if let uuid = UUID(uuidString: activeWalletIdRaw),
           let match = allWallets.first(where: { $0.id == uuid }) {
            return match
        }
        return allWallets.first
    }

    private var activeWalletHealKey: String {
        "\(activeWalletIdRaw)|\(allWallets.count)"
    }

    private func healActiveWalletIdIfNeeded() {
        guard let first = allWallets.first else { return }
        let resolves = UUID(uuidString: activeWalletIdRaw)
            .map { id in allWallets.contains(where: { $0.id == id }) } ?? false
        if !resolves {
            activeWalletIdRaw = first.id.uuidString
        }
    }

    /// All chains the active wallet has a derived (non-empty) address for,
    /// in canonical `SupportedChain` order.
    private var availableChains: [SupportedChain] {
        guard let wallet = activeWallet else { return [] }
        let chains: [SupportedChain] = wallet.addresses.compactMap { record in
            guard !record.address.isEmpty else { return nil }
            return SupportedChain(rawValue: record.chainRaw)
        }
        let set = Set(chains)
        return SupportedChain.allCases.filter { set.contains($0) }
    }

    private func address(for chain: SupportedChain) -> String? {
        guard let wallet = activeWallet else { return nil }
        return wallet.addresses.first(where: {
            $0.chainRaw == chain.rawValue && !$0.address.isEmpty
        })?.address
    }
}

// MARK: - Destinations

/// Step transitions inside the Send sheet. Hashable + Codable so the
/// NavigationPath persists across Rule #12 §G direction-flip rebuilds.
enum SendDestination: Hashable, Codable {
    case networkPicker(SendAsset)
    case recipient(chain: SupportedChain, tokenSymbol: String?, fromAddress: String)
    case amount(chain: SupportedChain, tokenSymbol: String?, fromAddress: String, recipients: [SendRecipientEntry])
    /// Step 5 — review the assembled, validated draft (`SendDraft` is
    /// Codable + Hashable, so it rides the path across Rule #12 §G rebuilds).
    case review(SendDraft)
}

// MARK: - Review loader

/// Resolves the asset + native unit prices (off-main, cache-first through
/// the shared pricing ladder, Rule #27) so the Review screen can show the
/// fiat values of the amount and the fee, then renders `SendReviewView`.
/// Prices aren't carried on the draft (they're display-only), so they're
/// resolved fresh here.
private struct SendReviewLoader: View {
    let draft: SendDraft
    /// The signing wallet's UUID — the executor needs it (the draft's
    /// `fromAddress` identifies the address, not the wallet). Resolved from
    /// the active wallet at the `.review` case in `SendView`.
    let walletId: UUID
    /// Whether the signing wallet has a BIP-39 passphrase (drives the
    /// passphrase prompt before the send).
    let walletHasPassphrase: Bool
    let onClose: () -> Void

    @State private var assetPrice: Decimal?
    @State private var nativePrice: Decimal?

    private var currencyCode: String {
        UserDefaults.standard.string(forKey: CurrencyPreference.storageKey) ?? CurrencyPreference.defaultCode
    }

    var body: some View {
        SendReviewView(
            draft: draft,
            currencyCode: currencyCode,
            assetUnitPrice: assetPrice,
            nativeUnitPrice: nativePrice,
            walletId: walletId,
            walletHasPassphrase: walletHasPassphrase,
            onClose: onClose
        )
        .task { await resolvePrices() }
    }

    private func resolvePrices() async {
        let assetSym = (draft.tokenSymbol ?? draft.chain.ticker).uppercased()
        let nativeSym = draft.chain.ticker.uppercased()
        let symbols = Array(Set([assetSym, nativeSym]))
        let prices = await TokenPricingEngine.shared.unitPrices(
            symbols: symbols, currencyCode: currencyCode.uppercased()
        )
        guard !Task.isCancelled else { return }
        assetPrice = prices[assetSym]?.amount
        nativePrice = prices[nativeSym]?.amount
    }
}
