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
        // The complete wipe lives in `FactoryReset.performFullWipe` — the
        // single source of truth shared with the Erase-Data-after-failed-
        // passcodes path (`AppLockView`). It throws only if the critical
        // SwiftData wallet deletion fails, in which case NOTHING was
        // destroyed and the user keeps a fully working app. `RootGate`
        // observes the wallet count flip to zero and routes to onboarding.
        do {
            try await FactoryReset.performFullWipe(modelContext: modelContext)
        } catch {
            isShowingResetSheet = false
            isShowingResetError = true
        }
    }
}
