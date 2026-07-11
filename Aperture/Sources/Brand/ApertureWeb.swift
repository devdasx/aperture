import Foundation

/// Canonical aperturex.io web destinations — the legal + support pages.
///
/// Centralized so every surface that links out (the onboarding legal footer
/// and Settings → About) opens the EXACT same live URL with no duplicated
/// string literals to drift. The pages live on the site, not bundled, so they
/// stay current without shipping an app update; each opens through
/// `@Environment(\.openURL)`.
enum ApertureWeb {
    static let terms = "https://aperturex.io/terms"
    static let privacy = "https://aperturex.io/privacy"
    static let privacyChoices = "https://aperturex.io/privacy-choices"
    static let support = "https://aperturex.io/support"

    /// The App Store numeric ID for Aperture. The single source of truth
    /// for every "download the app" affordance (today: the Activity PDF
    /// export's QR; future: share/invite flows).
    static let appStoreID = "6780187283"
    /// Canonical App Store listing URL, built from `appStoreID`.
    static let appStore = "https://apps.apple.com/app/id\(appStoreID)"
    /// Host + path shown as the QR's human-readable caption (no scheme,
    /// to keep it compact on the page).
    static let appStoreDisplay = "apps.apple.com/app/id\(appStoreID)"

    /// The legal-footer destinations as ready-to-open `URL`s. Force-unwrap is
    /// safe: these are fixed, compile-time-known valid absolute URLs.
    static let termsURL = URL(string: terms)!
    static let privacyURL = URL(string: privacy)!
}
