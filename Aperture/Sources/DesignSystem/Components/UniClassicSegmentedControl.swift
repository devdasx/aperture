import SwiftUI

/// Shared height for classic segment + sibling controls (e.g. filter circle).
enum UniClassicSegmentedMetrics {
    /// Total control height (track + inset) — match filter button to this.
    static let height: CGFloat = 36
    static let trackInset: CGFloat = 3
}

/// Pre–iOS 26 **classic** segmented control: soft track + white sliding
/// capsule behind the selected label (UISegmentedControl legacy look).
///
/// Use when `.pickerStyle(.segmented)` resolves to Liquid Glass / iOS 26
/// chrome and the product needs the older pill-on-track design.
struct UniClassicSegmentedControl<Selection: Hashable>: View {
    @Binding var selection: Selection
    let options: [(value: Selection, title: LocalizedStringKey)]
    @Namespace private var segmentNamespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = selection == option.value
                Button {
                    guard selection != option.value else { return }
                    withAnimation(.snappy(duration: 0.28)) {
                        selection = option.value
                    }
                } label: {
                    Text(option.title)
                        .font(UniTypography.subheadlineEmphasized)
                        .foregroundStyle(
                            isSelected
                                ? UniColors.Text.primary
                                : UniColors.Text.secondary
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .background {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(UniColors.List.rowBackground)
                            .shadow(color: Color.black.opacity(0.06), radius: 1.5, y: 0.5)
                            .matchedGeometryEffect(id: "classicSegmentThumb", in: segmentNamespace)
                    }
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(UniClassicSegmentedMetrics.trackInset)
        .frame(height: UniClassicSegmentedMetrics.height)
        .background {
            Capsule(style: .continuous)
                .fill(UniColors.Fill.tertiary)
        }
        .accessibilityElement(children: .contain)
    }
}
