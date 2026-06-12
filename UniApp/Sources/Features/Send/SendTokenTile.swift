import SwiftUI

/// The token tile used on the Review screen and the recipient chrome — a
/// circular `CoinMark` with a small chain badge composited at the
/// bottom-right (the handoff: "network badge 18–22px on the token tile's
/// bottom-right with a 2.5px surface ring").
///
/// **Why a dedicated component.** The badge ring must match the surface
/// the tile sits on so the badge reads as "punched through" the tile.
/// The ring color is the screen background (`UniColors.Background.primary`
/// by default), passed in so the same tile composites correctly on a card
/// (`Background.secondary`) too.
///
/// **Rule #7.** Both marks are real designed assets — the `CoinMark`
/// resolves the Trust Wallet brand mark (bundled or cached), and the
/// chain badge resolves the network's bundled logo. No hand-built icons;
/// the only shapes here are the structural ring + disc (layout, not
/// meaning).
struct SendTokenTile: View {
    let asset: SendAsset
    var size: CGFloat = 58
    /// The color of the badge's surface ring — set to the color of the
    /// surface the tile sits on so the badge reads as punched through.
    var ringColor: Color = UniColors.Background.primary

    /// Whether to show the chain badge. Native sends on a chain whose
    /// coin IS the network don't need a redundant badge; token sends and
    /// native sends where the badge clarifies the network show it.
    private var showsBadge: Bool {
        switch asset {
        case .native:
            // The native coin mark already names the chain; the badge
            // would be redundant. Show it only for tokens.
            return false
        case .token:
            return true
        }
    }

    private var badgeSize: CGFloat {
        // ~0.36 of the tile, clamped to the handoff's 18–22pt band.
        min(22, max(18, size * 0.36))
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            coinMark
                .frame(width: size, height: size)

            if showsBadge {
                networkBadge
                    .frame(width: badgeSize, height: badgeSize)
                    // Surface ring: a slightly larger disc of the
                    // background color behind the badge so it reads as
                    // sitting on top of the tile, not bleeding into it.
                    .background(
                        Circle()
                            .fill(ringColor)
                            .frame(width: badgeSize + 5, height: badgeSize + 5)
                    )
                    // Nudge so the badge overlaps the tile's corner.
                    .offset(x: 3, y: 3)
            }
        }
    }

    @ViewBuilder
    private var coinMark: some View {
        switch asset {
        case .native(let chain):
            CoinMark(chain: chain, tokenSymbol: chain.ticker)
        case let .token(symbol, _, network, contract):
            CoinMark(chain: network, tokenSymbol: symbol, contract: contract)
        }
    }

    @ViewBuilder
    private var networkBadge: some View {
        let chain = asset.network
        if let assetName = chain.logoAssetName {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            // Structural fallback (layout, not an icon) — the chain's
            // first ticker letter on a neutral disc.
            Circle()
                .fill(UniColors.Background.tertiary)
                .overlay {
                    Text(verbatim: String(chain.ticker.prefix(1)))
                        .font(.system(size: badgeSize * 0.5, weight: .semibold))
                        .foregroundStyle(UniColors.Text.secondary)
                }
                .accessibilityHidden(true)
        }
    }
}
