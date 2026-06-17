import SwiftUI

/// Horizontal category chips for the Browser dApp directory (2026-06-17).
/// Tapping a chip filters the directory below; "All" shows everything.
///
/// **Native iOS 26 Liquid Glass (2026-06-17).** The chips are no longer a
/// custom `Capsule().fill(...)` — they're the system's own Liquid Glass
/// material via `.glassEffect(_:in:)`, blended together inside a single
/// `GlassEffectContainer` so adjacent chips share one glass surface (the
/// same register the system uses for floating control clusters). The
/// selected chip carries an accent `tint`; the rest are clear, interactive
/// glass. No hand-rolled fills — the platform paints the material.
struct BrowserCategoryChips: View {
    @Binding var selected: BrowserDAppCategory

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: UniSpacing.xs) {
                HStack(spacing: UniSpacing.xs) {
                    ForEach(BrowserDAppCategory.allCases) { category in
                        chip(category)
                    }
                }
            }
            .padding(.horizontal, UniSpacing.m)
            .padding(.vertical, UniSpacing.xs)
        }
        .scrollClipDisabled()
    }

    private func chip(_ category: BrowserDAppCategory) -> some View {
        let isOn = category == selected
        return Button {
            withAnimation(.snappy(duration: 0.2)) { selected = category }
        } label: {
            HStack(spacing: UniSpacing.xxs) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(category.label)
                    .font(UniTypography.footnote.weight(.semibold))
            }
            .padding(.horizontal, UniSpacing.s)
            .padding(.vertical, UniSpacing.xs)
            .foregroundStyle(isOn ? UniColors.Button.primaryLabel : UniColors.Text.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(isOn ? UniColors.Tint.accent : nil).interactive(),
            in: Capsule()
        )
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// One row in the dApp directory list — favicon, name, host. Tapping opens
/// the dApp in `BrowserSessionView`.
struct BrowserDAppRow: View {
    let dapp: BrowserDApp

    var body: some View {
        HStack(spacing: UniSpacing.s) {
            BrowserFaviconView(
                url: dapp.faviconURL,
                fallbackLetter: dapp.name,
                size: .row
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: dapp.name)
                    .font(UniTypography.bodyEmphasized)
                    .foregroundStyle(UniColors.Text.primary)
                    .lineLimit(1)
                Text(verbatim: dapp.host)
                    .font(UniTypography.footnote)
                    .foregroundStyle(UniColors.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: UniSpacing.s)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(UniColors.Icon.tertiary)
        }
        .padding(.vertical, UniSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(dapp.name), \(dapp.host)"))
    }
}
