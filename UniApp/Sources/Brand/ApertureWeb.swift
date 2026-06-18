import Foundation

/// Canonical aperturex.io web destinations — the legal + support pages.
///
/// Centralized so every surface that links out (the onboarding legal footer
/// and Settings → About) opens the EXACT same live URL with no duplicated
/// string literals to drift. The pages live on the site, not bundled, so they
/// stay current without shipping an app update; each opens in the system
/// browser via `@Environment(\.openURL)`.
enum ApertureWeb {
    static let terms = "https://aperturex.io/terms"
    static let privacy = "https://aperturex.io/privacy"
    static let privacyChoices = "https://aperturex.io/privacy-choices"
    static let support = "https://aperturex.io/support"

    /// The legal-footer destinations as ready-to-open `URL`s. Force-unwrap is
    /// safe: these are fixed, compile-time-known valid absolute URLs.
    static let termsURL = URL(string: terms)!
    static let privacyURL = URL(string: privacy)!
}
