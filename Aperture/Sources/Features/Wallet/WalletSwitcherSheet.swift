import SwiftUI

/// Sheet that lists all wallets so the user can switch the active one.
///
/// **Layout** matches Settings → Wallets (`WalletsListView`): avatar, name +
/// status pills, trailing balance, create/import entry rows.
///
/// **Tap** a wallet → set active + dismiss.  
/// **Long-press** a wallet → push `WalletDetailView` (same settings surface
/// as Settings → Wallets → wallet).
struct WalletSwitcherSheet: View {
    @StateObject private var walletRecordsObservation = WalletRecordsObservation()
    @StateObject private var portfolioObservation = WalletPortfolioSummariesObservation()
    @GRDBStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @GRDBStorage(CurrencyPreference.storageKey) private var currencyCode: String = CurrencyPreference.defaultCode
    @Environment(\.balancePrivacyEnabled) private var hideBalances
    @Environment(\.dismiss) private var dismiss

    /// Navigation into wallet settings (long-press).
    @State private var settingsPath: [UUID] = []

    private var wallets: [WalletRecord] {
        walletRecordsObservation.wallets.sorted {
            if $0.sortOrder == $1.sortOrder { return $0.createdAt < $1.createdAt }
            return $0.sortOrder < $1.sortOrder
        }
    }

    private func fiatBalance(for wallet: WalletRecord) -> Decimal {
        let key = WalletPortfolioSummaryRecord.makeLookupKey(
            walletId: wallet.id,
            currencyCode: currencyCode
        )
        return portfolioObservation.summaries.first(where: { $0.lookupKey == key })?.totalFiat ?? 0
    }

    let onSelect: () -> Void
    let onCreateNew: () -> Void
    let onImport: () -> Void

    var body: some View {
        NavigationStack(path: $settingsPath) {
            List {
                Section {
                    ForEach(wallets) { wallet in
                        walletRow(wallet)
                            .uniListRowSurface()
                    }
                } header: {
                    if !wallets.isEmpty {
                        Text("Wallets")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Text.tertiary)
                    }
                }

                Section {
                    Button {
                        onCreateNew()
                    } label: {
                        entryRow(systemImage: "plus", title: "Create new wallet")
                    }
                    .buttonStyle(.uniListRow)
                    .uniListRowSurface()

                    Button {
                        onImport()
                    } label: {
                        entryRow(systemImage: "square.and.arrow.down", title: "Import existing wallet")
                    }
                    .buttonStyle(.uniListRow)
                    .uniListRowSurface()
                }
            }
            .uniListPageChrome()
            .environment(\.defaultMinListRowHeight, UniListMetrics.minRowHeight)
            .task(id: currencyCode) {
                portfolioObservation.setCurrencyCode(currencyCode)
            }
            .navigationTitle("Wallets")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .regular))
                    }
                    .accessibilityLabel(Text("Close"))
                }
            }
            .navigationDestination(for: UUID.self) { walletId in
                WalletDetailView(walletId: walletId)
            }
        }
    }

    // MARK: - Rows (match `WalletsListView.walletRow`)

    private func walletRow(_ wallet: WalletRecord) -> some View {
        Button {
            selectWallet(wallet)
        } label: {
            // Single row: avatar | name + status pills | balance | chevron
            HStack(spacing: UniSpacing.s) {
                WalletAvatar(spec: wallet.avatarSpec, size: .row, walletId: wallet.id)

                HStack(spacing: UniSpacing.xs) {
                    Text(wallet.name)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                        .lineLimit(1)
                    if wallet.id.uuidString == activeWalletIdRaw {
                        walletStatusPill(
                            title: "Active",
                            foreground: UniColors.Feedback.Success.foreground,
                            background: UniColors.Feedback.Success.background
                        )
                    }
                    if wallet.requiresBackup {
                        walletStatusPill(
                            title: "Not backed up",
                            foreground: UniColors.Feedback.Warning.foreground,
                            background: UniColors.Feedback.Warning.background
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(
                    WalletFormatting.fiat(
                        fiatBalance(for: wallet),
                        currencyCode: currencyCode,
                        hidden: hideBalances
                    )
                )
                .font(UniTypography.footnote)
                .foregroundStyle(UniColors.Text.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .environment(\.layoutDirection, .leftToRight)

                Image(systemName: UniDirectionalSymbol.disclosure)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(UniColors.Icon.tertiary)
                    .accessibilityHidden(true)
            }
            .uniListRowHitTarget()
        }
        .buttonStyle(.uniListRow)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    UniHapticEngine.shared.play(.selection)
                    settingsPath.append(wallet.id)
                }
        )
        .contextMenu {
            Button {
                settingsPath.append(wallet.id)
            } label: {
                Label("Wallet settings", systemImage: "gearshape")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Double tap to switch. Long press for wallet settings."))
    }

    private func walletStatusPill(
        title: LocalizedStringKey,
        foreground: Color,
        background: Color
    ) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, UniSpacing.xs)
            .padding(.vertical, 2)
            .background(Capsule().fill(background))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityAddTraits(.isStaticText)
    }

    private func entryRow(systemImage: String, title: LocalizedStringKey) -> some View {
        HStack(spacing: UniSpacing.s) {
            SettingsIconTile(
                systemImage: systemImage,
                tint: .blue,
                compactTint: UniColors.Icon.accent
            )
            Text(title)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
            Spacer()
            Image(systemName: UniDirectionalSymbol.disclosure)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(UniColors.Icon.tertiary)
        }
        .uniListRowHitTarget()
    }

    private func selectWallet(_ wallet: WalletRecord) {
        ActiveWalletPointer.set(wallet.id)
        onSelect()
        UniHapticEngine.shared.play(.selection)
        dismiss()
    }
}
