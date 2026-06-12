import SwiftUI
import SwiftData
import OSLog
// WebKit + TipKit are imported ONLY for `resetAll()`'s factory wipe:
// the dApp browser persists cookies/storage in the default
// `WKWebsiteDataStore`, and TipKit persists "shown once" counters in
// its own datastore — both must go for the reset to equal a first
// install.
import WebKit
import TipKit

/// Settings → Advanced. The diagnostic + reset surface. Three rows:
/// 1. **Database stats** — read-only counts (wallets, addresses,
///    transactions, balances, cached prices).
/// 2. **Clear price cache** — wipes `CachedPriceRecord`; the next
///    refresh repopulates from Coinbase.
/// 3. **Reset Aperture** — the nuclear hatch. Wipes SwiftData,
///    every `SeedVault` + `MnemonicVault` Keychain item, and every
///    `@AppStorage` key. Authorized by the user's passcode — or, when
///    no passcode is set, a native destructive confirmation. No typed
///    confirmation, ever (user direction 2026-06-13). The sheet itself
///    lives in `ResetApertureSheet.swift`; `resetAll()` here is run
///    only once that sheet reports the wipe authorized.
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
                onAuthorized: {
                    // The sheet has already verified the passcode (or
                    // taken the no-passcode destructive confirmation).
                    // Dismiss the sheet first so the wipe runs against
                    // a clean presentation stack, then perform it.
                    isShowingResetSheet = false
                    Task { await resetAll() }
                }
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

    /// The factory wipe. After this returns, the app's persistent
    /// state must be indistinguishable from a first install (user
    /// direction 2026-06-13): every SwiftData table empty, every
    /// Aperture Keychain item gone, the full `UserDefaults` domain
    /// removed, the dApp browser's website data cleared, the TipKit
    /// datastore reset, and the token-logo disk cache deleted.
    /// `RootGate` observes the wallet count flip to zero and routes
    /// back to onboarding; the next launch's
    /// `ApertureDatabase.bootstrap()` recreates the singleton rows
    /// with first-install values.
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
        // longer exist. `deleteAllWallets()` is the custody gate: it
        // refuses the in-memory fallback store, drops every wallet
        // row (with cascades) plus the primitive-keyed chart
        // snapshots, and clears the Keychain wallet manifest so the
        // next launch can't "restore" the nuked wallets.
        do {
            try await repo.deleteAllWallets()
        } catch {
            isShowingResetSheet = false
            isShowingResetError = true
            return
        }
        // Structural wipe of EVERY model in `ApertureSchemaV1.models`:
        // browser history + bookmarks, the custom-token registry, all
        // three price tables (`CachedPriceRecord`,
        // `HistoricalPriceRecord`, `PriceSnapshotRecord`), the
        // per-wallet chart timelines, the biometric enrollment
        // snapshot, and the `AppMetadataRecord` singleton (its
        // `firstLaunchAt` describes the previous owner; bootstrap
        // recreates it next launch). Enumerating the schema's model
        // list means a table added tomorrow is wiped automatically —
        // no per-table call site to forget. `ResetCompletenessTests`
        // pins the contract. The wallets are already gone at this
        // point, so a failure here is logged and the reset continues
        // rather than stranding a half-reset device.
        do {
            try FactoryReset.wipeAllModels(in: modelContext)
        } catch {
            log.error("Reset Aperture: structural model wipe failed: \(String(describing: error), privacy: .public)")
        }
        // Keychain — per-wallet seed / mnemonic / imported-key
        // material. Idempotent: missing items are success.
        for id in ids {
            try? SeedVault.deleteSeed(for: id)
            try? MnemonicVault.deleteMnemonic(for: id)
            try? MnemonicVault.deletePrivateKey(for: id)
        }
        // Keychain — PIN hash + salt + failed-attempt record.
        PinCodeStorage.clear()
        // dApp-browser website data: cookies, local/session storage,
        // IndexedDB, on-disk caches. `BrowserWebView` runs on the
        // persistent `WKWebsiteDataStore.default()`, so a previous
        // owner's dApp logins would otherwise survive the reset.
        await WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
        // Foundation-level network residue outside WKWebView (favicon
        // fetches, any URLSession-cached response or cookie).
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        // Token-logo disk cache (Caches/AperturePaint/CoinMarks).
        await CoinMarkCache.shared.clearAll()
        // TipKit datastore — the "shown once" counters (e.g.
        // `WalletTabSwitcherTip`). A first install shows first-time
        // tips again, so the reset must too. Apple's contract wants
        // `resetDatastore()` before `configure(_:)`; since configure
        // already ran in `UniAppApp.init()`, this is best-effort: on
        // success we reconfigure so TipKit stays coherent for the
        // rest of the session, on failure we log honestly (the
        // datastore still dies with the sandbox on a real uninstall).
        do {
            try Tips.resetDatastore()
            try Tips.configure([
                .displayFrequency(.immediate),
                .datastoreLocation(.applicationDefault)
            ])
        } catch {
            log.error("Reset Aperture: TipKit datastore reset failed (tip state persists until reinstall): \(String(describing: error), privacy: .public)")
        }
        // Wipe every @AppStorage key. `removePersistentDomain` removes
        // ALL keys under the app's standard domain — active-wallet
        // pointer, selected tab, theme/language/currency, pin/biometric
        // flags, `ScreenRestoration`'s stamps and paths (every store in
        // the app uses the standard domain; no custom suites exist —
        // audited 2026-06-13). It also removes `FreshInstallGuard`'s
        // install marker, so the NEXT launch re-runs the fresh-install
        // Keychain purge — a second, idempotent sweep behind this one.
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        log.notice("Reset Aperture completed: \(ids.count, privacy: .public) wallets purged, all SwiftData tables wiped, PIN cleared, web data cleared, defaults wiped.")
        // The RootGate's @Query will observe the wallet count flip
        // to zero and route the user back to onboarding automatically.
        // `isShowingResetSheet` was already cleared by the sheet's
        // `onAuthorized` callback before this ran.
    }
}
