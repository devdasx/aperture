import SwiftUI

/// The unified "rectangle" surface — a rounded container for grouping content.
/// Uses native system fill (`secondarySystemBackground`) and adapts to
/// light/dark.
///
/// Use for content surfaces (asset rows, balance cards, list groups). For
/// chrome/interactive surfaces, use `.glassEffect(...)` instead (Rule #3).
///
/// **iOS 26 concentric corners.** The card declares its corner radius as
/// the **container shape** via `.containerShape(.rect(cornerRadius:))`, so
/// any descendant `ConcentricRectangle()` inside the content closure
/// auto-resolves to the right inset radius without hand-computing
/// `nested(parent:padding:)`. The pattern at the call site:
///
/// ```swift
/// UniCard {
///     // ...some text rows...
///     ConcentricRectangle()        // inherits the card's radius − padding
///         .fill(UniColors.Material.elevated)
///         .frame(height: 44)
/// }
/// ```
///
/// **Default radius.** `UniRadius.card` (18 pt) — tuned 2026-06-07 against
/// iOS 26's own card surfaces (Wallet, Apple Cash, Maps Place cards). The
/// prior default was `UniRadius.xl` (24 pt), which read slightly toy-like
/// at the wallet-home scale. The new default applies to every existing
/// consumer that uses the parameterless `cornerRadius:` default;
/// surfaces that want the hero curvature explicitly pass `UniRadius.hero`.
struct UniCard<Content: View>: View {
    var padding: CGFloat = UniSpacing.m
    var cornerRadius: CGFloat = UniRadius.card
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
            // iOS 26 concentric corners — descendant `ConcentricRectangle()`
            // shapes inherit this radius automatically. The
            // `.continuous` style matches the visible background above so
            // children read as cleanly nested.
            .containerShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
