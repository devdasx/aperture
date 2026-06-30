import SwiftUI

// MARK: - UniListEmptyState

/// Canonical empty-state row for native inset grouped lists.
///
/// `UniEmptyState` owns the visual language; this wrapper owns the
/// list-row contract: clear row background, hidden separator, and optional
/// minimum height so filtered screens do not collapse into a blank sliver.
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
