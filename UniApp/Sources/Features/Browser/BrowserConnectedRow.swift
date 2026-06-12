import SwiftUI

/// One row in `BrowserHomeView`'s Connected section. Shows the
/// dApp's favicon + name + chain badge + relative connect time.
///
/// **Chain badge.** `UniBadge(kind: .info)` carries the chain's
/// display name. Reading the chain at a glance lets the user
/// verify which network the dApp is signing on — Rule #16 §A.5
/// (name the source).
///
/// **Transport tag.** Hidden in the standard row; reachable via
/// VoiceOver. The user doesn't need to think about
/// injected-vs-WalletConnect at the list level — they think about
/// "what dApps am I connected to."
struct BrowserConnectedRow: View {
    let session: BrowserSession

    var body: some View {
        HStack(spacing: UniSpacing.m) {
            BrowserFaviconView(
                url: session.dAppIcon,
                fallbackLetter: session.dAppName,
                size: .row
            )

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: session.dAppName)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)

                HStack(spacing: UniSpacing.xs) {
                    UniBadge(
                        text: LocalizedStringKey(session.chain.displayName),
                        kind: .info
                    )
                    Text(verbatim: session.dAppHost)
                        .font(UniTypography.footnote)
                        .foregroundStyle(UniColors.Text.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: UniSpacing.s)

            Text(verbatim: WalletFormatting.relativeTime(session.connectedAt))
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, UniSpacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(session.dAppName), \(session.chain.displayName), \(session.transport == .walletConnect ? "WalletConnect" : "in-app")"))
    }
}
