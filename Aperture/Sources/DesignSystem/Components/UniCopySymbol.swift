import SwiftUI

/// Native SF Symbol **copy → checkmark** morph (`contentTransition` +
/// `symbolEffect(.replace)`). Use whenever a control flips between
/// `doc.on.doc` and `checkmark` after a copy so it matches system apps.
struct UniCopySymbol: View {
    /// `true` shows the checkmark; `false` shows the copy glyph.
    var isCopied: Bool
    var pointSize: CGFloat = 16
    var weight: Font.Weight = .regular

    var body: some View {
        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
            .font(.system(size: pointSize, weight: weight))
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}

extension View {
    /// Animate a copy/checkmark symbol swap with the platform replace morph.
    /// Wrap the state flip that drives `UniCopySymbol(isCopied:)` (or any
    /// `Image(systemName:)` pair) so the transition actually runs.
    func uniCopySymbolAnimation<V: Equatable>(value: V) -> some View {
        animation(.snappy(duration: 0.28), value: value)
    }
}
