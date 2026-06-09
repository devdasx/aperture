import SwiftUI

/// Placeholder destination for the Browser tab. Aperture's Browser
/// surface — an in-wallet dApp browser with on-device wallet-connect
/// signing — lands in a later turn. For v1 of the four-tab shell
/// (2026-06-09 SHIPPED) the surface is a calm "Coming next" copy so
/// the tab is reachable, present in the tab bar, and honest about
/// what it does today.
///
/// **Visual register (Rule #2 + Rule #16 §E).** Identical to
/// `SwapPlaceholderView` and `SendPlaceholderView` — same
/// `ComingNextSurface` primitive, same hero SF Symbol size, same calm
/// secondary-tone body paragraph. Restraint over decoration.
/// Browser will eventually be custody-adjacent (signing dApp
/// transactions), so the placeholder copy explicitly names the
/// "no servers" property that the real surface will have to honor
/// when it lands — setting the user's expectation now.
///
/// **Symbol choice.** `globe` reads as "the web" universally without
/// borrowing Apple's own `safari.fill` mark (which would imply
/// launching Safari rather than browsing in-app). The hero glyph
/// at 72pt in `.hierarchical` rendering matches the Swap / Send
/// placeholders verbatim.
///
/// **Coming next vs Coming soon.** The placeholder primitive
/// (`ComingNextSurface`) names the affordance as "coming next" —
/// not "coming soon." Aperture's promise to ship the rest is
/// concrete; "next" is more honest than "soon" because "soon" has
/// no shape.
struct BrowserPlaceholderView: View {
    var body: some View {
        ComingNextSurface(
            systemImage: "globe",
            title: "Browser",
            message: "Browser is coming next. Aperture will open dApps in-wallet and sign their requests on your iPhone — no centralized wallet-connect relay in the middle."
        )
        .navigationTitle("Browser")
        .navigationBarTitleDisplayMode(.large)
    }
}
