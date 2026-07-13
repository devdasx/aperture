import SwiftUI

/// A simple feature/benefit row — leading SF Symbol, title, optional detail.
/// Used in onboarding, settings explanations, empty states.
///
/// Both `title` and `detail` accept `LocalizedStringKey` so every call site
/// flows through the String Catalog (Rule #9).
struct UniFeatureRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    var detail: LocalizedStringKey? = nil
    var tint: Color = UniColors.FeatureRow.icon

    var body: some View {
        HStack(alignment: .top, spacing: UniSpacing.m) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(tint)
                .frame(
                    width: UniListMetrics.iconSlot,
                    height: UniListMetrics.iconSlot,
                    alignment: .center
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: UniSpacing.xxs) {
                UniBody(text: title)

                if let detail {
                    UniSubtitle(text: detail)
                }
            }
        }
    }
}

/// Metrics for inset-grouped `List` cells app-wide.
///
/// **What List actually honors (UICollectionView-backed, iOS 16–26):**
/// - `defaultMinListRowHeight` — often ignored with custom `listRowBackground`
/// - `frame(minHeight:)` on `NavigationLink` — often ignored
/// - **`listRowInsets` vertical** — always applied; this is the reliable height
///
/// **Contract:** `uniListRowSurface()` sets vertical insets + card fill.
/// Target row height ≈ `iconSlot` + 2×`contentVertical` (28 + 16 + 16 = 60).
enum UniListMetrics {
    /// Approximate single-line card height (icon + vertical insets) ≈ 60pt.
    static let minRowHeight: CGFloat = 60
    /// Horizontal list row inset.
    static let contentHorizontal: CGFloat = 16
    /// Vertical list row inset — **primary height control** for every surface row.
    /// With a 28pt icon slot: 16 + 28 + 16 = 60pt card height.
    static let contentVertical: CGFloat = 16
    /// Leading icon slot (must include height so content isn’t text-only).
    static let iconSlot: CGFloat = 28
}

extension View {
    /// Full-width hit area for the row label. Height comes from
    /// `uniListRowSurface()` insets, not from a minHeight on the link.
    func uniListRowHitTarget(alignment: Alignment = .leading) -> some View {
        frame(maxWidth: .infinity, minHeight: UniListMetrics.iconSlot, alignment: alignment)
            .contentShape(Rectangle())
    }

    /// Zero all system list cell insets (pair with native content padding).
    func uniListRowCellInsets() -> some View {
        listRowInsets(EdgeInsets())
    }

    /// Content padding when `uniListRowCellInsets()` zeroed everything.
    func uniListRowNativeContentPadding() -> some View {
        padding(.horizontal, UniListMetrics.contentHorizontal)
            .padding(.vertical, UniListMetrics.contentVertical)
    }

    /// Explicit list row insets used by `uniListRowSurface`.
    func uniListRowEdgeInsets() -> some View {
        listRowInsets(
            EdgeInsets(
                top: UniListMetrics.contentVertical,
                leading: UniListMetrics.contentHorizontal,
                bottom: UniListMetrics.contentVertical,
                trailing: UniListMetrics.contentHorizontal
            )
        )
    }

    /// Card background + **vertical insets that set real row height**.
    /// Prefer this over bare `listRowBackground(UniColors.List.rowBackground)`.
    func uniListRowSurface(
        _ background: Color = UniColors.List.rowBackground
    ) -> some View {
        self
            .uniListRowEdgeInsets()
            .listRowBackground(background)
    }
}

/// Full-row press chrome for `List` buttons.
/// Pair the Button with `.uniListRowSurface()` on the list row.
struct UniListRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .uniListRowHitTarget()
            .background {
                UniColors.List.rowPressed
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .background {
                UniHapticPressProbe(
                    isPressed: configuration.isPressed,
                    haptic: .selection
                )
            }
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == UniListRowButtonStyle {
    static var uniListRow: UniListRowButtonStyle { UniListRowButtonStyle() }
}
