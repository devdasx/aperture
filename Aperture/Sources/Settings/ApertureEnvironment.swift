import SwiftUI

/// The canonical app-environment modifier. Applies the user's persisted
/// preferences for color scheme, locale, and layout direction to a view tree.
///
/// **Apply at every presentation surface root** — `WindowGroup` content, every
/// `.sheet(...)` content view, every `.fullScreenCover(...)`, every
/// `.popover(...)`, every standalone `UIWindow` if we ever add one. Without
/// this on a sheet's content, the sheet inherits the system's color scheme
/// instead of the user's preference (because `.preferredColorScheme(_:)` is
/// scoped to the presenting window — sheets get their own scope).
///
/// Also publishes `ApertureAppearanceTrait` into UIKit trait overrides and
/// `ApertureAppearanceResolution` so Cloud / Midnight / Dark palette tokens
/// resolve correctly. Midnight and Dark both use system dark interface style;
/// the custom trait is the only discriminator.
///
/// See `CLAUDE.md` Rule #12 for the full contract.
struct ApertureEnvironmentModifier: ViewModifier {
    @GRDBStorage("themePreference") private var themeRaw: String = ThemePreference.defaultRaw
    @GRDBStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode
    @GRDBStorage(HideBalancesPreference.hideBalanceOnHomeKey) private var hideBalances: Bool = false

    private var theme: ThemePreference {
        ThemePreference.stored(themeRaw)
    }

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(theme.colorScheme)
            .environment(\.apertureAppearance, theme.apertureAppearance)
            .environment(\.locale, LanguagePreference.locale(for: languageCode) ?? .current)
            .environment(\.layoutDirection, LanguagePreference.layoutDirection(for: languageCode))
            .environment(\.balancePrivacyEnabled, hideBalances)
            // Fallback floor only — modern List + custom row backgrounds often
            // ignore this; real height comes from `uniListRowSurface()` /
            // `uniListRowHitTarget` (see UniListMetrics docs).
            .environment(\.defaultMinListRowHeight, UniListMetrics.minRowHeight)
            // Publish process-level resolution immediately (before the
            // zero-size UIKit bridge attaches) so the first frame of
            // UniColors already sees Midnight vs Dark correctly.
            .onAppear {
                ApertureAppearanceResolution.current = theme.apertureAppearance
                ApertureAppearanceSync.apply(theme)
            }
            .onChange(of: themeRaw) { _, _ in
                ApertureAppearanceResolution.current = theme.apertureAppearance
                ApertureAppearanceSync.apply(theme)
            }
            .background {
                ApertureAppearanceTraitBridge(theme: theme)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    /// Applies `themePreference` + `languagePreference` (locale + layout
    /// direction) to this view. Required on every presentation surface root
    /// per `CLAUDE.md` Rule #12.
    func apertureEnvironment() -> some View {
        modifier(ApertureEnvironmentModifier())
    }

    /// Shared inset-grouped list chrome: hide system list fill and paint the
    /// Aperture page floor. Row height floor is set globally by
    /// `apertureEnvironment()`; this re-asserts it for lists presented
    /// outside that root. Do not also force `frame(minHeight:)` on row labels.
    /// Pair with `listRowBackground(UniColors.List.rowBackground)` on each row
    /// so cards follow Midnight (#212229) vs Dark (#1C1C1E).
    ///
    /// Also applies `.labeledContentStyle(.uniDetail)` so receipt-style
    /// keys (Coin, To, Hash, Network fee, …) render gray secondary text
    /// instead of primary black across every inset-grouped list.
    func uniListPageChrome() -> some View {
        self
            .listStyle(.insetGrouped)
            .labeledContentStyle(.uniDetail)
            .environment(\.defaultMinListRowHeight, UniListMetrics.minRowHeight)
            .scrollContentBackground(.hidden)
            .background(UniColors.Background.primary)
    }
}
