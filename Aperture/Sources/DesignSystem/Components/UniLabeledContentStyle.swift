import SwiftUI

/// Detail-list `LabeledContent` style: **secondary (gray) labels**, primary
/// values. Used app-wide for receipt-style rows (Coin / To / Hash / Network
/// fee, Settings key-value rows, transaction detail, send confirmation).
///
/// Reuses the system automatic layout so List separators, multi-line
/// content, and trailing alignment stay platform-native; only the label
/// color is re-skinned to `UniColors.Text.secondary`.
struct UniLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            configuration.content
        } label: {
            configuration.label
                .foregroundStyle(UniColors.Text.secondary)
        }
        // Avoid recursion when this style is the environment default.
        .labeledContentStyle(.automatic)
    }
}

extension LabeledContentStyle where Self == UniLabeledContentStyle {
    /// Aperture detail rows: gray key, primary value.
    static var uniDetail: UniLabeledContentStyle { UniLabeledContentStyle() }
}
