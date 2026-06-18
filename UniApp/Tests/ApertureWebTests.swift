import Testing
import Foundation
@testable import Aperture

/// Contract tests for `ApertureWeb` — the shared aperturex.io legal/support
/// destinations the onboarding footer (T-004/T-005) and Settings → About both
/// open. A typo'd URL would crash the `…URL!` force-unwraps at launch, so this
/// guards them: every value is a well-formed absolute HTTPS aperturex.io URL.
@Suite("ApertureWeb legal/support URLs")
struct ApertureWebTests {

    private static let all = [
        ApertureWeb.terms, ApertureWeb.privacy,
        ApertureWeb.privacyChoices, ApertureWeb.support,
    ]

    @Test("every destination is a valid HTTPS aperturex.io URL")
    func destinationsAreValidHTTPS() {
        for string in Self.all {
            let url = try? #require(URL(string: string))
            #expect(url?.scheme == "https")
            #expect(url?.host == "aperturex.io")
        }
    }

    @Test("the force-unwrapped footer URLs resolve and match their strings")
    func footerURLsResolve() {
        #expect(ApertureWeb.termsURL.absoluteString == ApertureWeb.terms)
        #expect(ApertureWeb.privacyURL.absoluteString == ApertureWeb.privacy)
    }

    @Test("destinations are distinct (no copy-paste collision)")
    func destinationsAreDistinct() {
        #expect(Set(Self.all).count == Self.all.count)
    }
}
