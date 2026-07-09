import Foundation
import SwiftUI

/// Navigation-state mirroring for live app rebuilds.
///
/// **The contract.**
/// - A cold launch always starts from the Wallet tab root. If the app was
///   fully closed, it must never reopen the last pushed screen or tab.
/// - The wallet-home and Settings `NavigationStack` paths are still mirrored
///   continuously so deliberate in-process rebuilds, such as an LTR/RTL
///   language-direction flip, can re-seed the same screen.
/// - `UniAppApp.init()` calls `resolveOnLaunch()` before the first view is
///   constructed; that call clears both mirrored paths and resets the selected
///   tab to Wallet.
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
/// **Composition with the Rule #12 §G root direction rebuild.** After launch,
/// a mid-session LTR↔RTL flip recreates `RootGate`'s subtree
/// (see `AppRoot.rootDirectionKey` in `UniAppApp.swift`); the freshly created
/// views re-consume the continuously-mirrored paths, so the user stays on the
/// screen where they flipped the language. Cold launch is the only time the
/// mirror is forcibly cleared.
@MainActor
enum ScreenRestoration {

    enum PreferenceKey {
        /// JSON-encoded `NavigationPath.CodableRepresentation` of the
        /// Settings tab's stack.
        static let settingsPath = "restoration.settingsPath"
        /// JSON-encoded `NavigationPath.CodableRepresentation` of the
        /// wallet home's stack.
        static let walletHomePath = "restoration.walletHomePath"
    }

    // MARK: - Cold-launch resolution (called once, from `UniAppApp.init()`)

    /// Clear any previous process' navigation state. Must run before any
    /// view is constructed — `WalletHomeView` and `SettingsView` read the
    /// mirrored paths in their `init`s.
    static func resolveOnLaunch() {
        resetToMainScreen()
    }

    /// Forget both stacks and land the user on the wallet tab — "the main
    /// screen".
    private static func resetToMainScreen() {
        AppPreferenceStore.shared.remove(PreferenceKey.settingsPath)
        AppPreferenceStore.shared.remove(PreferenceKey.walletHomePath)
        AppPreferenceStore.shared.set("", forKey: "settingsDeepLink")
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
