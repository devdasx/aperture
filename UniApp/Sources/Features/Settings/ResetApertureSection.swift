import SwiftUI
import SwiftData
import OSLog
// WebKit + TipKit are imported ONLY for `resetAll()`'s factory wipe: the dApp
// browser persists cookies/storage in the default `WKWebsiteDataStore`, and
// TipKit persists "shown once" counters in its own datastore — both must go
// for the reset to equal a first install.
import WebKit
import TipKit

/// The **Reset Aperture** section — the app's nuclear hatch. Moved out of the
/// removed Advanced screen to live directly on the Settings screen (2026-06-19,
/// user direction). Renders the destructive row + its honest footer, gates the
/// wipe behind `ResetApertureSheet` (passcode verify, or a native destructive
/// confirmation when no passcode is set), and runs the factory wipe once the
/// sheet reports it authorized.
///
/// A self-contained `View` whose body IS a `Section`, so `SettingsView` embeds
/// it inside its `List` with one line. Owns its own `@Query wallets` (for the
/// Keychain id sweep), reset state, sheet, and alert — nothing leaks into the
/// parent.
struct ResetApertureSection: View {
    @Query private var wallets: [WalletRecord]
    @Environment(\.modelContext) private var modelContext
    @AppStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode
    @State private var isShowingResetSheet: Bool = false
    @State private var isShowingResetError: Bool = false

    /// Rule #12 §G direction-only key for sheet content rebuild
    /// (`"ltr"` / `"rtl"`).
    private var sheetDirectionKey: String {
        LanguagePreference.layoutDirection(for: languageCode) == .rightToLeft ? "rtl" : "ltr"
    }

    var body: some View {
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
        .sheet(isPresented: $isShowingResetSheet) {
            ResetApertureSheet(
                onAuthorized: {
                    // The sheet has already verified the passcode (or taken the
                    // no-passcode destructive confirmation). Dismiss first so the
                    // wipe runs against a clean presentation stack, then perform it.
                    isShowingResetSheet = false
                    Task { await resetAll() }
                }
            )
            .id(sheetDirectionKey)
            .uniAppEnvironment()
            .uniSheetDetents([.large])
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

    /// The factory wipe. After this returns, the app's persistent state must be
    /// indistinguishable from a first install (user direction 2026-06-13):
    /// every SwiftData table empty, every Aperture Keychain item gone, the full
    /// `UserDefaults` domain removed, the dApp browser's website data cleared,
    /// the TipKit datastore reset, and the token-logo disk cache deleted.
    /// `RootGate` observes the wallet count flip to zero and routes back to
    /// onboarding; the next launch's `ApertureDatabase.bootstrap()` recreates
    /// the singleton rows with first-install values.
    @MainActor
    private func resetAll() async {
        let log = Logger(subsystem: "com.thuglife.aperture", category: "reset")
        let repo = WalletRepository(modelContainer: modelContext.container)
        // Collect all wallet ids up front so we can wipe Keychain items even
        // after the SwiftData rows are gone.
        let ids: [UUID] = wallets.map { $0.id }
        // Database first: if this throws, nothing has been destroyed yet — the
        // user keeps a fully working app and can retry. Wiping Keychain before
        // the database would, on a database failure, leave wallet records
        // pointing at seeds that no longer exist. `deleteAllWallets()` is the
        // custody gate: it refuses the in-memory fallback store, drops every
        // wallet row (with cascades) plus the primitive-keyed chart snapshots,
        // and clears the Keychain wallet manifest so the next launch can't
        // "restore" the nuked wallets.
        do {
            try await repo.deleteAllWallets()
        } catch {
            isShowingResetSheet = false
            isShowingResetError = true
            return
        }
        // Structural wipe of EVERY model in `ApertureSchemaV1.models`. The
        // wallets are already gone, so a failure here is logged and the reset
        // continues rather than stranding a half-reset device.
        do {
            try FactoryReset.wipeAllModels(in: modelContext)
        } catch {
            log.error("Reset Aperture: structural model wipe failed: \(String(describing: error), privacy: .public)")
        }
        // Keychain — per-wallet seed / mnemonic / imported-key material.
        // Idempotent: missing items are success.
        for id in ids {
            try? SeedVault.deleteSeed(for: id)
            try? MnemonicVault.deleteMnemonic(for: id)
            try? MnemonicVault.deletePrivateKey(for: id)
        }
        // Keychain — PIN hash + salt + failed-attempt record.
        PinCodeStorage.clear()
        // dApp-browser website data: cookies, local/session storage, IndexedDB,
        // on-disk caches (the persistent default `WKWebsiteDataStore`).
        await WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
        // Foundation-level network residue outside WKWebView.
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        // Token-logo disk cache (Caches/AperturePaint/CoinMarks).
        await CoinMarkCache.shared.clearAll()
        // TipKit datastore — the "shown once" counters. Best-effort: reset then
        // reconfigure so TipKit stays coherent for the rest of the session.
        do {
            try Tips.resetDatastore()
            try Tips.configure([
                .displayFrequency(.immediate),
                .datastoreLocation(.applicationDefault)
            ])
        } catch {
            log.error("Reset Aperture: TipKit datastore reset failed (tip state persists until reinstall): \(String(describing: error), privacy: .public)")
        }
        // Wipe every @AppStorage key — `removePersistentDomain` removes ALL keys
        // under the app's standard domain (active-wallet pointer, tab, theme/
        // language/currency, pin/biometric flags, ScreenRestoration stamps, and
        // FreshInstallGuard's install marker — so the NEXT launch re-runs the
        // fresh-install Keychain purge as a second, idempotent sweep).
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        log.notice("Reset Aperture completed: \(ids.count, privacy: .public) wallets purged, all SwiftData tables wiped, PIN cleared, web data cleared, defaults wiped.")
        // The RootGate's @Query observes the wallet count flip to zero and
        // routes back to onboarding automatically.
    }
}
