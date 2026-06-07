import SwiftUI

/// "Hi from Aperture." — the welcome-slide iris Easter egg sheet.
/// Presented only by an explicit tap on the iris (`WordmarkIllustration`);
/// never auto-presents (per Rule #18 §E — guide sheets don't interrupt,
/// and this is a sibling pattern). Restrained voice, one understated
/// joke, no marketing claims (Rule #2 §A.7).
struct HelloSheet: View {
    let onDismiss: () -> Void

    var body: some View {
        UniSheet(title: "Hi from Aperture.") {
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                hero
                bodyBlock
            }
        } actions: {
            UniButton(title: "Got it", variant: .primary) {
                onDismiss()
            }
        }
    }

    private var hero: some View {
        HStack {
            Spacer()
            Image(systemName: "aperture")
                .font(.system(size: 56, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(UniColors.Brand.mark)
                .symbolEffect(.bounce, options: .nonRepeating)
                .accessibilityHidden(true)
            Spacer()
        }
    }

    private var bodyBlock: some View {
        VStack(alignment: .leading, spacing: UniSpacing.m) {
            UniBody(
                text: "Hello. You found the iris.",
                color: UniColors.Text.primary
            )
            .fixedSize(horizontal: false, vertical: true)
            UniBody(
                text: "Aperture is a wallet, and only a wallet. It lives on this iPhone, your keys live on this iPhone, and that is the entire arrangement.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
            UniBody(
                text: "No accounts. No servers. No analytics watching your balances. No support team to impersonate.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
            UniBody(
                text: "Open source means we can't lie about any of this — every line of code lives where you can read it. Built with care, and a little stubbornness about doing only the right things.",
                color: UniColors.Text.secondary
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
