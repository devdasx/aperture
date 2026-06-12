import SwiftUI

/// One beat of the onboarding sequence. Ten beats.
///
/// Order is deliberate and narratively connected:
///   1. Identity (welcome)
///   2. Reach (one wallet, many chains)
///   3. Self-custody (keys on device)
///   4. Biometric protection (Face ID)
///   5. Recovery (the 24-word truth)
///   6. Receive (verb)
///   7. Send with real fees (verb + honesty)
///   8. Swap across chains (the differentiator)
///   9. Privacy (non-custodial promise)
///  10. Threshold — where the two CTAs live.
///
/// Per `CLAUDE.md` Rule #9, `title` and `body` are
/// `LocalizedStringResource`s. The literals below act as the
/// source-language (English) keys — `LocalizedStringResource`'s literal
/// initializer is extraction-compatible, so the String Catalog
/// (`Localizable.xcstrings`) keys are unchanged and existing
/// translations still match. `LocalizedStringResource` conforms to
/// `Sendable` natively (unlike `LocalizedStringKey`), so the
/// `static let all` array is concurrency-safe without `@unchecked`.
/// `OnboardingSlideView` renders through the `titleKey` / `bodyKey`
/// bridges below, which preserve the environment-locale-aware lookup —
/// when the user changes language in Settings, the slides re-render in
/// the new locale via SwiftUI's `.environment(\.locale, …)` chain.
struct OnboardingSlide: Identifiable, Sendable {
    let id: Int
    let illustration: OnboardingIllustration
    let title: LocalizedStringResource
    let body: LocalizedStringResource

    /// Bridges the stored resource back to a `LocalizedStringKey` for
    /// the design-system text components (`UniLargeTitle` et al.). The
    /// key string is identical to the catalog key, so `Text` resolves it
    /// through the SwiftUI environment locale exactly as before —
    /// in-app language switching keeps working live.
    var titleKey: LocalizedStringKey { LocalizedStringKey(title.key) }
    /// See `titleKey`.
    var bodyKey: LocalizedStringKey { LocalizedStringKey(body.key) }

    static let all: [OnboardingSlide] = [
        OnboardingSlide(
            id: 0,
            illustration: .wordmark,
            title: "Welcome to Aperture.",
            body: "A wallet built with the care a wallet should be built with."
        ),
        OnboardingSlide(
            id: 1,
            illustration: .constellation,
            title: "One wallet. Twenty-four networks.",
            body: "Bitcoin, Ethereum, Solana, and twenty-one more — held together in a single place."
        ),
        OnboardingSlide(
            id: 2,
            illustration: .vault,
            title: "Your keys never leave your iPhone.",
            body: "Generated on-device. Stored on-device. Aperture has no copy."
        ),
        OnboardingSlide(
            id: 3,
            illustration: .faceID,
            title: "Locked by Face ID.",
            body: "Every signature is gated by your biometrics. No password to forget."
        ),
        OnboardingSlide(
            id: 4,
            illustration: .recoveryPhrase,
            title: "A 24-word phrase is the only key.",
            body: "Write it down. Keep it offline. Lose it and the funds are gone — there is no recovery."
        ),
        OnboardingSlide(
            id: 5,
            illustration: .receive,
            title: "Receive on every chain.",
            body: "One address per network, shown plainly. No gimmicks."
        ),
        OnboardingSlide(
            id: 6,
            illustration: .send,
            title: "Send with the real fee shown.",
            body: "The network fee is displayed before you sign. No surprises after."
        ),
        OnboardingSlide(
            id: 7,
            illustration: .swap,
            title: "Swap across chains in one flow.",
            body: "Move value between networks without leaving the wallet."
        ),
        OnboardingSlide(
            id: 8,
            illustration: .privacy,
            title: "Aperture can't see your funds.",
            body: "Balances are read from public chains on your device. Nothing flows to us."
        ),
        OnboardingSlide(
            id: 9,
            illustration: .threshold,
            title: "Start when you're ready.",
            body: "Create a new wallet, or bring one you already have."
        )
    ]

    static var last: OnboardingSlide { all[all.count - 1] }
    static var lastIndex: Int { all.count - 1 }
}
