import SwiftUI

/// The unified "rectangle" surface — a rounded container for grouping content.
/// Uses native system fill (`secondarySystemBackground`) and adapts to light/dark.
///
/// Use for content surfaces (asset rows, balance cards, list groups).
/// For chrome/interactive surfaces, use `.glassEffect(...)` instead (Rule #3).
struct UniCard<Content: View>: View {
    var padding: CGFloat = UniSpacing.m
    var cornerRadius: CGFloat = UniRadius.xl
    var fill: Color = UniColors.Material.card
    var stroke: Color? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay {
                if let stroke {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(stroke, lineWidth: 1)
                }
            }
    }
}
