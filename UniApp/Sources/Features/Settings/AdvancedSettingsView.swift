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
    @AppStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode
    @State private var isShowingResetSheet: Bool = false
    @State private var isClearingCache: Bool = false
    @State private var lastClearMessage: String?
    @State private var isShowingResetError: Bool = false

    /// Rule #12 §G direction-only key for sheet content rebuild.
    /// `"ltr"` or `"rtl"`. Identical pattern to `OnboardingView`.
    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: languageCode) == .rightToLeft ? "rtl" : "ltr"
    }

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
            .id(sheetDirectionKey)
            .uniAppEnvironment()
            .presentationDetents([.large])
            .presentationBackground(UniColors.Background.primary)
        }
        .alert(
            Text("Couldn't reset Aperture"),
            isPresented: $isShowingResetError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The local database couldn't be deleted. Nothing was removed — your wallets, seeds, and preferences are untouched. Try again.")
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

    @MainActor
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

    @MainActor
    private func resetAll() async {
        let log = Logger(subsystem: "com.thuglife.aperture", category: "reset")
        let repo = WalletRepository(modelContainer: modelContext.container)
        // Collect all wallet ids up front so we can wipe Keychain
        // items even after the SwiftData rows are gone.
        let ids: [UUID] = wallets.map { $0.id }
        // Database first: if this throws, nothing has been destroyed
        // yet — the user keeps a fully working app and can retry.
        // Wiping Keychain before the database would, on a database
        // failure, leave wallet records pointing at seeds that no
        // longer exist.
        do {
            try await repo.deleteAllWallets()
        } catch {
            isShowingResetSheet = false
            isShowingResetError = true
            return
        }
        // Wipe the user-data stores `deleteAllWallets()` deliberately
        // leaves behind (its scope is WalletRecord + cascades only):
        // dApp browser history + bookmarks (privacy-sensitive), the
        // user-added custom-token registry, the price cache, and the
        // previous owner's biometric enrollment snapshot. Without
        // this, the next person who creates a wallet on the device
        // inherits the prior owner's browsing history, bookmarks,
        // and token list. `AppMetadataRecord` (schema version) is app
        // metadata, not user data — it stays. The wallets are already
        // gone at this point, so a failure here is logged and the
        // reset continues rather than stranding a half-reset device.
        do {
            try modelContext.delete(model: BrowserHistoryRecord.self)
            try modelContext.delete(model: BrowserBookmarkRecord.self)
            try modelContext.delete(model: CustomTokenRecord.self)
            try modelContext.delete(model: CachedPriceRecord.self)
            try modelContext.delete(model: BiometricEnrollmentRecord.self)
            try modelContext.save()
        } catch {
            log.error("Reset Aperture: auxiliary user-data wipe failed: \(String(describing: error), privacy: .public)")
        }
        for id in ids {
            try? SeedVault.deleteSeed(for: id)
            try? MnemonicVault.deleteMnemonic(for: id)
        }
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
