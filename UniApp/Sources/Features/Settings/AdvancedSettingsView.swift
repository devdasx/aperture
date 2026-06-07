import SwiftUI
import SwiftData
import OSLog

/// Settings → Advanced. The diagnostic + reset surface. Three rows:
/// 1. **Database stats** — read-only counts (wallets, addresses,
///    transactions, balances, cached prices).
/// 2. **Clear price cache** — wipes `CachedPriceRecord`; the next
///    refresh repopulates from Coinbase.
/// 3. **Reset Aperture** — the nuclear hatch. Wipes SwiftData,
///    every `SeedVault` + `MnemonicVault` Keychain item, and every
///    `@AppStorage` key. Requires typed wallet-name confirm.
struct AdvancedSettingsView: View {
    @Query private var wallets: [WalletRecord]
    @Query private var addresses: [WalletAddressRecord]
    @Query private var transactions: [TransactionRecord]
    @Query private var balances: [TokenBalanceRecord]
    @Query private var prices: [CachedPriceRecord]
    @Query private var metadataRows: [AppMetadataRecord]

    @Environment(\.modelContext) private var modelContext
    @State private var isShowingResetSheet: Bool = false
    @State private var isClearingCache: Bool = false
    @State private var lastClearMessage: String?

    var body: some View {
        List {
            Section {
                statRow(label: "Wallets",      value: wallets.count)
                statRow(label: "Addresses",    value: addresses.count)
                statRow(label: "Transactions", value: transactions.count)
                statRow(label: "Balances",     value: balances.count)
                statRow(label: "Cached prices", value: prices.count)
                if let meta = metadataRows.first {
                    statRow(label: "Schema version", value: meta.schemaVersion)
                }
            } header: {
                Text("Local database").font(UniTypography.footnote).foregroundStyle(UniColors.Text.tertiary)
            } footer: {
                Text("All data lives on this iPhone. Aperture has no servers.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.tertiary)
            }

            Section {
                Button {
                    Task { await clearPriceCache() }
                } label: {
                    HStack(spacing: UniSpacing.s) {
                        Image(systemName: "trash.slash")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(UniColors.Icon.accent)
                            .frame(width: 28)
                        Text("Clear price cache")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Text.primary)
                        Spacer()
                        if isClearingCache {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.vertical, UniSpacing.xxs)
                }
                .buttonStyle(.plain)
                .listRowBackground(UniColors.Background.secondary)
            } footer: {
                if let lastClearMessage {
                    Text(LocalizedStringKey(lastClearMessage))
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Status.successForeground)
                } else {
                    Text("Wipes the on-disk price cache. The next refresh fetches fresh prices from Coinbase.")
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Button {
                    isShowingResetSheet = true
                } label: {
                    HStack(spacing: UniSpacing.s) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(UniColors.Status.errorForeground)
                            .frame(width: 28)
                        Text("Reset Aperture")
                            .font(UniTypography.body)
                            .foregroundStyle(UniColors.Status.errorForeground)
                        Spacer()
                    }
                    .padding(.vertical, UniSpacing.xxs)
                }
                .buttonStyle(.plain)
                .listRowBackground(UniColors.Background.secondary)
            } footer: {
                Text("Deletes every wallet, every encrypted seed, every cached balance, every preference. This cannot be undone — back up any recovery phrases first.")
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Status.errorForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Advanced"))
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $isShowingResetSheet) {
            ResetApertureSheet(
                onConfirm: { Task { await resetAll() } }
            )
            .uniAppEnvironment()
            .presentationDetents([.large])
            .presentationBackground(UniColors.Background.primary)
        }
    }

    private func statRow(label: LocalizedStringKey, value: Int) -> some View {
        HStack {
            Text(label).font(UniTypography.body).foregroundStyle(UniColors.Text.primary)
            Spacer()
            Text("\(value)").font(UniTypography.monoBody).foregroundStyle(UniColors.Text.secondary)
        }
        .padding(.vertical, UniSpacing.xxs)
        .listRowBackground(UniColors.Background.secondary)
    }

    private func clearPriceCache() async {
        isClearingCache = true
        let repo = PriceCacheRepository(modelContainer: modelContext.container)
        do {
            try await repo.clearAll()
            lastClearMessage = String.apertureLocalized("Cache cleared.")
        } catch {
            lastClearMessage = String.apertureLocalized("Couldn't clear cache.")
        }
        isClearingCache = false
    }

    private func resetAll() async {
        let log = Logger(subsystem: "com.thuglife.aperture", category: "reset")
        let repo = WalletRepository(modelContainer: modelContext.container)
        // Collect all wallet ids up front so we can wipe Keychain
        // items even after the SwiftData rows are gone.
        let ids: [UUID] = wallets.map { $0.id }
        for id in ids {
            try? SeedVault.deleteSeed(for: id)
            try? MnemonicVault.deleteMnemonic(for: id)
        }
        try? await repo.deleteAllWallets()
        // Wipe PIN + biometric state.
        PinCodeStorage.clear()
        // Wipe every @AppStorage key. UserDefaults' removePersistentDomain
        // removes ALL keys under the app's domain — this is the nuclear
        // option the row's footer warned about.
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        log.notice("Reset Aperture completed: \(ids.count, privacy: .public) wallets purged, PIN cleared, defaults wiped.")
        // The RootGate's @Query will observe the wallet count flip
        // to zero and route the user back to onboarding automatically.
        isShowingResetSheet = false
    }
}

// MARK: - Reset confirmation

private struct ResetApertureSheet: View {
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed: String = ""

    private static let phrase = "RESET APERTURE"

    private var matches: Bool {
        typed.trimmingCharacters(in: .whitespaces).uppercased() == Self.phrase
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: UniSpacing.l) {
                    hero
                    UniBody(
                        text: "This deletes every wallet on this iPhone, every encrypted seed, every cached balance, every preference. The recovery phrases you wrote down still work — you can import any wallet back if you have its phrase.",
                        color: UniColors.Text.secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    UniBody(
                        text: "If you don't have your recovery phrases written down, any wallet you didn't back up will be lost.",
                        color: UniColors.Status.errorForeground
                    )
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: UniSpacing.xs) {
                        Text("Type RESET APERTURE to confirm:")
                            .font(UniTypography.footnote)
                            .foregroundStyle(UniColors.Text.tertiary)
                        UniTextField(
                            placeholder: "RESET APERTURE",
                            text: $typed,
                            directionPolicy: .forceLTR
                        )
                    }
                }
                .padding(UniSpacing.l)
            }
            .background(UniColors.Background.primary.ignoresSafeArea())
            .navigationTitle(Text("Reset Aperture"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel(Text("Cancel"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                GlassEffectContainer(spacing: UniSpacing.s) {
                    UniButton(
                        title: "Delete everything",
                        variant: .destructive,
                        isEnabled: matches
                    ) {
                        onConfirm()
                    }
                }
                .padding(.horizontal, UniSpacing.l)
                .padding(.bottom, UniSpacing.l)
            }
        }
    }

    private var hero: some View {
        Image(systemName: "trash.fill")
            .font(.system(size: 56, weight: .light))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(UniColors.Status.errorForeground)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityHidden(true)
    }
}
