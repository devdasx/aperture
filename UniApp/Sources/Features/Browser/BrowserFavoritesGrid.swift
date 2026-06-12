import SwiftUI

/// The 4-column dApp favorites grid on `BrowserHomeView`. Each tile
/// is the dApp's favicon over its display name — the mobile-Safari
/// start-page pattern, but bound to crypto-native destinations.
///
/// **Layers (Rule #2 §B.3).** Content layer. The grid is opaque —
/// it does not use Liquid Glass. Each tile reads as a calm card:
/// favicon + label, restrained spacing. The page color (under the
/// scrolling list) shows through between tiles.
///
/// **Why a `LazyVGrid` with 4 fixed columns.** 4 columns at
/// `UniSpacing.m` page padding leaves a 72-76pt tile width on an
/// iPhone 17 Pro Max — large enough for a real favicon to read,
/// small enough that 8 tiles fit on screen without scrolling.
/// `LazyVGrid` is the iOS-canonical primitive for this pattern; we
/// don't reinvent.
struct BrowserFavoritesGrid: View {
    let favorites: [BrowserFavorite]
    let onSelect: (BrowserFavorite) -> Void

    private static let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: UniSpacing.m),
        count: 4
    )

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: UniSpacing.m) {
            ForEach(favorites) { favorite in
                Button {
                    onSelect(favorite)
                } label: {
                    BrowserFavoriteTile(favorite: favorite)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: favorite.name))
                .accessibilityHint(Text("Open \(favorite.host)"))
            }
        }
    }
}

/// One tile in the grid — favicon over name.
private struct BrowserFavoriteTile: View {
    let favorite: BrowserFavorite

    var body: some View {
        VStack(spacing: UniSpacing.xs) {
            BrowserFaviconView(
                url: favorite.iconURL,
                fallbackLetter: favorite.name,
                size: .tile
            )
            Text(verbatim: favorite.name)
                .font(UniTypography.caption1)
                .foregroundStyle(UniColors.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UniSpacing.xs)
    }
}
