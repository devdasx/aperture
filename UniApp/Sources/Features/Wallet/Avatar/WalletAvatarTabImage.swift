import SwiftUI
import UIKit
import CryptoKit

/// `WalletAvatarTabImage` is the iOS-26 tab-bar-safe wrapper around
/// `WalletAvatar`. It exists for one reason: **SwiftUI `TabView` icons
/// are rendered as template images by default** — the system takes the
/// alpha channel of whatever you hand it, throws away the colors, and
/// fills with the unselected-tab gray or the selected-tab tint. That
/// behavior is correct for SF Symbols (the system needs the freedom to
/// re-tint per-state and per-appearance) but wrong for an identity
/// disc whose entire visual identity IS the gradient.
///
/// On 2026-06-09 (Thuglife `databaseSequenceNumber 8588`) the bug
/// surfaced live: the user picked a green disc + monogram `W`. The
/// toolbar pill rendered correctly (green disc + W). The bottom tab
/// rendered only a gray `W` — the gradient had been stripped to alpha
/// and re-filled with the unselected-tab tint. The `M-017`-ish failure
/// mode was indistinguishable from a state-propagation regression
/// until we looked at how UITabBar treats label images.
///
/// **The fix.** Render the SwiftUI `WalletAvatar` to a `UIImage` via
/// `ImageRenderer`, mark the image `.alwaysOriginal`, then wrap it in
/// SwiftUI's `Image(uiImage:).renderingMode(.original)`. iOS sees an
/// explicitly-original image and renders it as-is — gradient, sheen,
/// edge stroke, badge, all preserved.
///
/// **Rule #3 (native-only).** `ImageRenderer` is Apple's SwiftUI-to-
/// `UIImage` bridge (iOS 16+). `withRenderingMode(.alwaysOriginal)` is
/// the documented UIKit way to opt out of template tinting. No
/// third-party introspection, no private API.
///
/// **Re-render cadence.** `body` re-evaluates every time the caller's
/// view body recomputes — which for `MainTabView.walletTabLabel` is
/// when the `@Query` snapshot changes (a wallet rename, an avatar
/// edit, a swap of the active wallet) AND on every unrelated parent
/// body pass. The `ImageRenderer` call is synchronous and runs on
/// `@MainActor` (SwiftUI views are main-actor-isolated).
///
/// **Caching.** A small static `NSCache` keyed on the spec's CONTENT
/// (gradient / symbol / glyph / monogram / tint / badge / SVG digest /
/// wallet id) plus the requested size and the environment's
/// `displayScale`. Unrelated body passes hit the cache; only a real
/// identity change (different key) pays the `ImageRenderer` cost.
/// The scale comes from `@Environment(\.displayScale)` — the per-scene
/// value — not the deprecated `UIScreen.main.scale`.
struct WalletAvatarTabImage: View {
    /// The fully-hydrated spec to render. The wrapper does not derive
    /// the badge — pass a `WalletAvatarSpec` whose `badge` field is
    /// already resolved (see `WalletRecord.avatarSpec` for the
    /// canonical hydration path).
    let spec: WalletAvatarSpec

    /// The intended display size in points. iOS 26 tab-bar icons
    /// honor a 28pt envelope by default; `WalletAvatar.size.tabIcon`
    /// matches that. The renderer uses the device's UIScreen scale to
    /// produce a Retina-crisp output.
    let size: CGFloat

    /// Wallet UUID, forwarded into `WalletAvatar`'s `walletId:` so the
    /// `.custom` SVG branch can resolve the cached PNG. Nil when
    /// there's no active wallet (cold-launch frame before
    /// `ensureActiveWalletSet()` lands one) — `WalletAvatar` falls
    /// through to the iris glyph in that case.
    let walletId: UUID?

    init(spec: WalletAvatarSpec, size: CGFloat = 28, walletId: UUID? = nil) {
        self.spec = spec
        self.size = size
        self.walletId = walletId
    }

    /// Per-scene display scale — replaces the deprecated
    /// `UIScreen.main.scale` and tracks the actual scene the view is
    /// rendered into (relevant on Stage Manager / external displays).
    @Environment(\.displayScale) private var displayScale

    /// Process-wide memo of rendered tab images. `NSCache` evicts
    /// under memory pressure on its own; the count limit is a
    /// belt-and-braces bound (a user with N wallets × a couple of
    /// scales is still tiny). `@MainActor` because every reader is a
    /// main-actor view body.
    @MainActor
    private static let renderCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 64
        return cache
    }()

    /// Deterministic content key. Built from the spec's FIELDS (not
    /// `Hashable.hashValue`, which is per-launch randomized and can
    /// collide) so two different identities can never share a cache
    /// slot. The custom SVG contributes a SHA-256 digest prefix —
    /// same-length edits still produce a distinct key.
    private var cacheKey: NSString {
        var parts: [String] = [
            spec.gradient.rawValue,
            spec.symbolType.rawValue,
            spec.glyph?.rawValue ?? "-",
            spec.monogram ?? "-",
            spec.customTint?.rawValue ?? "-",
            spec.badge?.rawValue ?? "-",
            walletId?.uuidString ?? "-",
            "\(size)",
            "\(displayScale)"
        ]
        if let svg = spec.customSvg {
            let digest = SHA256.hash(data: Data(svg.utf8))
            parts.append(digest.prefix(8).map { String(format: "%02x", $0) }.joined())
        }
        return parts.joined(separator: "|") as NSString
    }

    var body: some View {
        // `.imageScale(.large)` is the only honest public-API knob iOS
        // gives us for tab-icon prominence (verified 2026-06-09 against
        // the HIG, `UITabBarAppearance`, and the iOS 26 Liquid Glass
        // tab-bar surface). It nudges the displayed envelope up by
        // about 15% over the default — not the doubling the caller
        // might intuitively expect from passing `size: 60`, because
        // `UITabBar` clamps every tab icon to the system envelope.
        // The `size:` parameter still controls the SOURCE bitmap
        // resolution, so a higher value yields a crisper render at
        // whatever the system clamp finally allows.
        Image(uiImage: rendered())
            .renderingMode(.original)
            .imageScale(.large)
    }

    /// Snapshot the SwiftUI `WalletAvatar` into a `UIImage` and mark
    /// it `.alwaysOriginal` so UITabBar will skip its template-image
    /// pipeline. Cache-first: identical (spec content, size, scale)
    /// requests return the memoized image without re-running
    /// `ImageRenderer`. `ImageRenderer.uiImage` is nullable (returns
    /// `nil` on rendering failure — e.g., zero-size frame); we fall
    /// back to an empty `UIImage` so the tab still occupies its slot
    /// rather than collapsing the bar's layout — and we do NOT cache
    /// that failure fallback, so the next pass retries the render.
    @MainActor
    private func rendered() -> UIImage {
        let key = cacheKey
        if let hit = Self.renderCache.object(forKey: key) {
            return hit
        }
        let renderer = ImageRenderer(
            content: WalletAvatar(spec: spec, size: .tabIcon, walletId: walletId)
                .frame(width: size, height: size)
        )
        renderer.scale = displayScale
        guard let rendered = renderer.uiImage else { return UIImage() }
        let image = rendered.withRenderingMode(.alwaysOriginal)
        Self.renderCache.setObject(image, forKey: key)
        return image
    }
}
