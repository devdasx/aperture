import Foundation
import SwiftUI

/// Last-screen restoration across cold launches (2026-06-13, user
/// direction, verbatim): *"i close the app totally and reopen it after
/// 1 second, it asked for passcode and that's correct, but it doesn't
/// open the last screen and that's not correct. only if i left the app
/// for more than 2 minutes, it should navigate me to the main screen
/// when entering the passcode, if less than 2 minutes, it should keep
/// me in the same screen."*
///
/// **The contract.**
/// - Every real `.background` entry stamps "the user left the app at T"
///   (written by `AutoLockController.handleScenePhaseChange` — the same
///   place that arms the auto-lock, BEFORE its PIN gate, because
///   restoration is independent of the lock).
/// - The two restorable `NavigationStack` paths (wallet home, Settings)
///   are mirrored here continuously via `.onChange(of: navigationPath)`
///   on their owning views — cheap (a handful of enum cases encoded as
///   JSON) and it means a force-quit needs no last-moment save.
/// - The selected tab needs no mirroring: `MainTabView` already
///   persists it via `@GRDBStorage(MainTab.storageKey)`.
/// - On cold launch, `UniAppApp.init()` calls `resolveOnLaunch()`
///   exactly once, before the first view is constructed:
///   - elapsed `< 120s` → keep everything; the views consume the
///     persisted paths in their `init`s and the user lands back on the
///     screen they left (beneath the independent lock overlay window,
///     which sits above the content tree and needs no coordination).
///   - elapsed `≥ 120s` (or no stamp — fresh install / crash while
///     foregrounded) → clear both paths AND reset the selected tab to
///     the wallet tab, so the user starts at the main screen.
///
/// **Why GRDB app preferences, not Keychain.** This is small, non-secret UI
/// state. The destination enums carry only routing identity —
/// `SettingsDestination` (static cases + a wallet `UUID`) and
/// `WalletHomeDestination` (`AssetIdentity` = ticker symbol + chain,
/// transaction `UUID`s). No key material, no addresses, no balances.
/// Audited 2026-06-13; if a future destination ever carries sensitive
/// payload, exclude it from the Codable path or stop persisting that
/// stack.
///
/// **Composition with the Rule #12 §G root direction rebuild.** A
/// mid-session LTR↔RTL flip recreates `RootGate`'s subtree
/// (see `AppRoot.rootDirectionKey` in `UniAppApp.swift`); the freshly
/// created views re-consume the continuously-mirrored paths, so the
/// user stays on the screen where they flipped the language — the
/// Choose-language picker survives its own direction flip. No special
/// casing needed: the mirror always reflects the live paths.
@MainActor
enum ScreenRestoration {

    /// The user's 2-minute window, verbatim from the direction above.
    static let maxRestorationAge: TimeInterval = 120

    enum PreferenceKey {
        /// `Double` (`timeIntervalSince1970`) of the most recent real
        /// `.background` entry. Absent until the first backgrounding
        /// after install.
        static let leftAppAt = "restoration.leftAppAt"
        /// JSON-encoded `NavigationPath.CodableRepresentation` of the
        /// Settings tab's stack.
        static let settingsPath = "restoration.settingsPath"
        /// JSON-encoded `NavigationPath.CodableRepresentation` of the
        /// wallet home's stack.
        static let walletHomePath = "restoration.walletHomePath"
    }

    // MARK: - Stamping (called on every real `.background` entry)

    /// Record "the user left the app now". `.inactive` bounces (system
    /// prompts, Control Center, app-switcher peeks) deliberately do NOT
    /// stamp — same reasoning as the auto-lock contract: the user
    /// hasn't left. Force-quit from the switcher delivers `.background`
    /// before termination, so the stamp covers that path too.
    static func stampBackground(now: Date = Date()) {
        AppPreferenceStore.shared.set(now.timeIntervalSince1970, forKey: PreferenceKey.leftAppAt)
    }

    // MARK: - Cold-launch resolution (called once, from `UniAppApp.init()`)

    /// Decide restore-vs-reset for this process. Must run before any
    /// view is constructed — the restorable views read the persisted
    /// paths in their `init`s.
    static func resolveOnLaunch(now: Date = Date()) {
        let stamp = AppPreferenceStore.shared.double(PreferenceKey.leftAppAt, default: 0)
        guard stamp > 0 else {
            // Never backgrounded (fresh install) or the marker was
            // wiped — nothing trustworthy to restore.
            resetToMainScreen()
            return
        }
        let elapsed = now.timeIntervalSince1970 - stamp
        guard elapsed >= 0, elapsed < maxRestorationAge else {
            // ≥ 2 minutes away (or a clock that moved backwards —
            // distrust it): start at the main screen.
            resetToMainScreen()
            return
        }
        // < 2 minutes: leave the persisted tab + paths untouched.
        // `MainTabView` restores the tab via `@GRDBStorage`;
        // `WalletHomeView` / `SettingsView` consume their paths at init.
    }

    /// The ≥-2-minutes (or no-stamp) outcome: forget both stacks and
    /// land the user on the wallet tab — "the main screen".
    private static func resetToMainScreen() {
        AppPreferenceStore.shared.remove(PreferenceKey.settingsPath)
        AppPreferenceStore.shared.remove(PreferenceKey.walletHomePath)
        AppPreferenceStore.shared.set(MainTab.wallet.rawValue, forKey: MainTab.storageKey)
    }

    /// Immediate in-session version of `resetToMainScreen()`. Use this
    /// after a wallet is actually created/imported/restored so the user
    /// always lands on the Wallet home, no matter which tab or pushed
    /// Settings screen opened the flow.
    static func routeToMainScreenNow() {
        resetToMainScreen()
        TabReselectSignal.shared.walletReselectToken &+= 1
    }

    // MARK: - Path mirroring (called from `.onChange(of: navigationPath)`)

    /// Mirror the Settings stack as a typed `[SettingsDestination]` (not
    /// the opaque `NavigationPath`) so `restoredSettingsStack()` can
    /// inspect it and refuse to re-open the auth-gated Security screen on
    /// cold launch — same pattern as `saveWalletHomeStack`.
    static func saveSettingsStack(_ stack: [SettingsDestination]) {
        guard let data = try? JSONEncoder().encode(stack) else {
            AppPreferenceStore.shared.remove(PreferenceKey.settingsPath)
            return
        }
        AppPreferenceStore.shared.set(data, forKey: PreferenceKey.settingsPath)
    }

    /// Mirror the wallet-home stack. Stored as a typed
    /// `[WalletHomeDestination]` (not the opaque `NavigationPath`) so
    /// `restoredWalletHomeStack()` can inspect it and refuse to
    /// re-open transient screens — see that method and
    /// `WalletHomeDestination.isColdLaunchRestorable`.
    static func saveWalletHomeStack(_ stack: [WalletHomeDestination]) {
        guard let data = try? JSONEncoder().encode(stack) else {
            // Shouldn't happen (every case is Codable), but if it does,
            // clear rather than restore a stale snapshot.
            AppPreferenceStore.shared.remove(PreferenceKey.walletHomePath)
            return
        }
        AppPreferenceStore.shared.set(data, forKey: PreferenceKey.walletHomePath)
    }

    // MARK: - Path consumption (called from the owning views' `init`s)

    /// The Settings stack to seed on a fresh launch, **truncated at the
    /// first non-`isColdLaunchRestorable` destination** (2026-06-17). The
    /// Security screen is PIN / Face-ID-gated, so restoring straight back
    /// into it would skip the auth challenge (the bug the user reported);
    /// truncating means the user lands on the Settings root and re-enters
    /// Security with a fresh prompt. A decode failure (e.g. a
    /// pre-2026-06-17 `NavigationPath`-format blob still in the preference store
    /// on the first launch after the update) degrades safely to root.
    static func restoredSettingsStack() -> [SettingsDestination] {
        guard let data = AppPreferenceStore.shared.data(PreferenceKey.settingsPath),
              !data.isEmpty,
              let stack = try? JSONDecoder().decode([SettingsDestination].self, from: data)
        else { return [] }
        return Array(stack.prefix(while: { $0.isColdLaunchRestorable }))
    }

    /// The wallet-home stack to seed on a fresh launch, **truncated at
    /// the first non-`isColdLaunchRestorable` destination** (2026-06-14
    /// bug fix). This guarantees the app never auto-opens onto the
    /// Activity list or a Send flow that lingered in the mirror —
    /// it lands on home, or on the asset the user was actually reading.
    /// A decode failure (e.g. the pre-2026-06-14 `NavigationPath`-format
    /// blob still in the preference store on the first launch after the
    /// update) degrades safely to "start at root".
    static func restoredWalletHomeStack() -> [WalletHomeDestination] {
        guard let data = AppPreferenceStore.shared.data(PreferenceKey.walletHomePath),
              !data.isEmpty,
              let stack = try? JSONDecoder().decode([WalletHomeDestination].self, from: data)
        else { return [] }
        return Array(stack.prefix(while: { $0.isColdLaunchRestorable }))
    }

}
