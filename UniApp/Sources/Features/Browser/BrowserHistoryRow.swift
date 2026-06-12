import SwiftUI

/// One row in `BrowserHomeView`'s Recent section. Shows the dApp's
/// favicon + the page title + the host + a relative timestamp.
///
/// **Why title AND host.** The title is the human identity
/// ("Uniswap Interface"); the host is the canonical destination
/// (`app.uniswap.org`). Per Rule #16 §A.5 ("name your source") we
/// always show the host so the user can verify where they'll land.
/// A phishing dApp that copies Uniswap's title can't fake the host
/// — the host comes from the URL the user actually visited.
///
/// **Relative timestamp.** `WalletFormatting.relativeTime(_:)`
/// produces "4m", "2h", "yesterday", "Mar 12" — the same shape
/// the activity rows use. Consistent ramp across the app.
struct BrowserHistoryRow: View {
    let record: BrowserHistoryRecord

    var body: some View {
        HStack(spacing: UniSpacing.m) {
            BrowserFaviconView(
                url: record.iconURL.flatMap(URL.init(string:)),
                fallbackLetter: titleFallback,
                size: .row
            )

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                Text(verbatim: displayTitle)
                    .font(UniTypography.body)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)

                Text(verbatim: record.host)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: UniSpacing.s)

            Text(verbatim: WalletFormatting.relativeTime(record.lastVisitedAt))
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, UniSpacing.xxs)
    }

    /// Falls back to the host when the page didn't report a title.
    private var displayTitle: String {
        record.title.isEmpty ? record.host : record.title
    }

    /// First letter source for the favicon chip fallback. Prefer
    /// the title; if empty, use the host.
    private var titleFallback: String {
        let source = displayTitle
        return source
    }
}
