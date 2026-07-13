import SwiftUI

// MARK: - UniListEmptyState

/// Canonical empty-state row for native inset grouped lists.
///
/// `UniEmptyState` owns the visual language; this wrapper owns the
/// list-row contract: clear row background, hidden separator, and optional
/// minimum height so filtered screens do not collapse into a blank sliver.
///
/// Use this for every empty list section in the wallet (holdings, activity,
/// filters, search) so empty surfaces stay one family.
struct UniListEmptyState: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var mark: UniEmptyState.Mark = .iris
    var minHeight: CGFloat = 220

    var body: some View {
        UniEmptyState(title: title, detail: detail, mark: mark)
            .frame(maxWidth: .infinity)
            .frame(minHeight: minHeight)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
    }
}

/// Empty body hosted inside a wallet home **card** that already paints
/// `UniColors.List.rowBackground` (holdings chrome + activity card).
/// Same mark, title, and detail as `UniEmptyState` / `UniListEmptyState`
/// — only the outer surface is omitted so the parent card stays single.
struct UniCardEmptyState: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    var mark: UniEmptyState.Mark = .iris
    var minHeight: CGFloat = 220

    var body: some View {
        UniEmptyState(
            title: title,
            detail: detail,
            mark: mark,
            paintsSurface: false
        )
        .frame(maxWidth: .infinity)
        .frame(minHeight: minHeight)
    }
}
