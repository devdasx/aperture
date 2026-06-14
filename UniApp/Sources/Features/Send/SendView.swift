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
                        onContinue: { toAddress, toName in
                            navigationPath.append(
                                SendDestination.amount(
                                    chain: chain, tokenSymbol: tokenSymbol, fromAddress: fromAddress,
                                    toAddress: toAddress, toName: toName
                                )
                            )
                        }
                    )
                case let .amount(chain, tokenSymbol, fromAddress, toAddress, toName):
                    SendAmountPlaceholderView(
                        chain: chain,
                        tokenSymbol: tokenSymbol,
                        fromAddress: fromAddress,
                        toAddress: toAddress,
                        toName: toName
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
    case amount(chain: SupportedChain, tokenSymbol: String?, fromAddress: String, toAddress: String, toName: String?)
}

// MARK: - Amount seam (next increment)

/// Step 4 seam — where amount entry will land next. Shows the now-real
/// selection: asset, network, the wallet's sending address, and the
/// validated/resolved recipient from Step 3. Honest about being the next
/// step (Rule #16): it never implies a send is possible yet.
private struct SendAmountPlaceholderView: View {
    let chain: SupportedChain
    let tokenSymbol: String?
    let fromAddress: String
    let toAddress: String
    let toName: String?

    private var assetLabel: String { tokenSymbol ?? chain.ticker }

    var body: some View {
        List {
            Section {
                row("Asset", assetLabel)
                row("Network", chain.displayName)
                row("To", toName ?? shortened(toAddress))
                if toName != nil { row("Address", shortened(toAddress)) }
                row("From", shortened(fromAddress))
            } header: {
                UniCaption(text: "You're sending", color: UniColors.Text.tertiary)
            }

            Section {
                VStack(spacing: UniSpacing.s) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(UniColors.Icon.tertiary)
                    UniBody(
                        text: "Amount entry is the next step we'll build.",
                        alignment: .center,
                        color: UniColors.Text.secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, UniSpacing.l)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Send \(assetLabel)"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ key: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: UniSpacing.s) {
            Text(key)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.secondary)
            Spacer(minLength: UniSpacing.s)
            Text(verbatim: value)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
                .environment(\.layoutDirection, .leftToRight)
        }
        .listRowBackground(UniColors.Background.secondary)
    }

    private func shortened(_ address: String) -> String {
        guard address.count > 16 else { return address }
        return "\(address.prefix(8))…\(address.suffix(6))"
    }
}
