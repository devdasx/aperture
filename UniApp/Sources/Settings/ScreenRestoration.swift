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
///   persists it via `@AppStorage(MainTab.storageKey)`.
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
/// **Why `UserDefaults`, not Keychain.** This is small, non-secret UI
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

    private enum Key {
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
        UserDefaults.standard.set(
            now.timeIntervalSince1970,
            forKey: Key.leftAppAt
        )
    }

    // MARK: - Cold-launch resolution (called once, from `UniAppApp.init()`)

    /// Decide restore-vs-reset for this process. Must run before any
    /// view is constructed — the restorable views read the persisted
    /// paths in their `init`s.
    static func resolveOnLaunch(now: Date = Date()) {
        let defaults = UserDefaults.standard
        guard let stamp = defaults.object(forKey: Key.leftAppAt) as? Double else {
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
        // `MainTabView` restores the tab via `@AppStorage`;
        // `WalletHomeView` / `SettingsView` consume their paths at init.
    }

    /// The ≥-2-minutes (or no-stamp) outcome: forget both stacks and
    /// land the user on the wallet tab — "the main screen".
    private static func resetToMainScreen() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Key.settingsPath)
        defaults.removeObject(forKey: Key.walletHomePath)
        defaults.set(MainTab.wallet.rawValue, forKey: MainTab.storageKey)
    }

    // MARK: - Path mirroring (called from `.onChange(of: navigationPath)`)

    static func saveSettingsPath(_ path: NavigationPath) {
        save(path, forKey: Key.settingsPath)
    }

    static func saveWalletHomePath(_ path: NavigationPath) {
        save(path, forKey: Key.walletHomePath)
    }

    // MARK: - Path consumption (called from the owning views' `init`s)

    static func restoredSettingsPath() -> NavigationPath {
        restore(forKey: Key.settingsPath)
    }

    static func restoredWalletHomePath() -> NavigationPath {
        restore(forKey: Key.walletHomePath)
    }

    // MARK: - Codec

    private static func save(_ path: NavigationPath, forKey key: String) {
        guard let codable = path.codable,
              let data = try? JSONEncoder().encode(codable)
        else {
            // The path contains an entry that isn't Codable (a
            // view-destination push or a future non-Codable value
            // type). Restoring a stale earlier snapshot would land the
            // user somewhere they were NOT — clear instead, so the
            // worst case degrades to "starts at the stack root".
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func restore(forKey key: String) -> NavigationPath {
        guard let data = UserDefaults.standard.data(forKey: key),
              let codable = try? JSONDecoder().decode(
                  NavigationPath.CodableRepresentation.self,
                  from: data
              )
        else { return NavigationPath() }
        return NavigationPath(codable)
    }
}
