import SwiftUI
import SwiftData

/// Sheet that lists all the user's wallets so they can switch the
/// active one. Two extra rows at the bottom — "Create new wallet" and
/// "Import existing wallet" — route to the same covers `OnboardingView`
/// uses, but presented from the wallet-home parent so the user can
/// add a wallet without leaving the main surface.
///
/// **Per Rule #15:** `NavigationStack`-rooted, `navigationTitle("Wallets")`,
/// `.large` detent because this is a navigation experience (it could
/// push to a wallet-detail screen later, T-042).
struct WalletSwitcherSheet: View {
    @Query(sort: \WalletRecord.sortOrder) private var wallets: [WalletRecord]
    @AppStorage("activeWalletId") private var activeWalletIdRaw: String = ""
    @Environment(\.dismiss) private var dismiss

    /// Fired when the user picks an existing wallet (after writing the
    /// id to `@AppStorage`). The wallet-home reads `activeWalletIdRaw`
    /// reactively so this is mostly for haptic feedback at the call site.
    let onSelect: () -> Void

    /// Fired when the user taps "Create new wallet". The parent
    /// dismisses this sheet and presents the existing
    /// `RecoveryPhraseFlow` cover.
    let onCreateNew: () -> Void

    /// Fired when the user taps "Import existing wallet". The parent
    /// dismisses this sheet and presents the existing
    /// `ImportWalletFlow` cover.
    let onImport: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(wallets) { wallet in
                        walletRow(wallet)
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
                        addRow(systemImage: "plus", title: "Create new wallet")
                    }
                    .buttonStyle(.plain)

                    Button {
                        onImport()
                    } label: {
                        addRow(systemImage: "square.and.arrow.down", title: "Import existing wallet")
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Wallets")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel(Text("Close"))
                }
            }
        }
    }

    private func walletRow(_ wallet: WalletRecord) -> some View {
        Button {
            activeWalletIdRaw = wallet.id.uuidString
            onSelect()
            dismiss()
        } label: {
            HStack(spacing: UniSpacing.s) {
                // 2026-06-09 — the wallet's customisable
                // `WalletAvatar` replaces the prior kind-glyph
                // swatch. Each wallet's identity reads here
                // exactly as it reads in the tab bar and the
                // toolbar pill — same color, same SF Symbol,
                // same size.
                WalletAvatar(
                    symbol: wallet.iconSymbol.isEmpty ? WalletAvatarDefaults.symbol : wallet.iconSymbol,
                    colorHex: wallet.iconColorHex.isEmpty ? WalletAvatarDefaults.colorHex : wallet.iconColorHex,
                    size: .row
                )

                VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                    Text(wallet.name)
                        .font(UniTypography.body)
                        .foregroundStyle(UniColors.Text.primary)
                    Text(walletKindLabel(wallet.kind))
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                }

                Spacer(minLength: UniSpacing.s)

                if wallet.id.uuidString == activeWalletIdRaw {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(UniColors.Icon.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, UniSpacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func addRow(systemImage: String, title: LocalizedStringKey) -> some View {
        HStack(spacing: UniSpacing.s) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(UniColors.Icon.accent)
                .frame(width: 28, alignment: .center)
            Text(title)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Icon.tertiary)
        }
        .padding(.vertical, UniSpacing.xxs)
        .contentShape(Rectangle())
    }

    private func walletKindLabel(_ kind: WalletKind) -> LocalizedStringKey {
        switch kind {
        case .created:          return "Created on this iPhone"
        case .importedMnemonic: return "Imported from recovery phrase"
        case .importedKey:      return "Imported from private key"
        case .watchOnly:        return "Watch-only"
        }
    }
}
