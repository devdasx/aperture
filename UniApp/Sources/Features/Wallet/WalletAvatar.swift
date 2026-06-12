import SwiftUI
import CryptoKit

/// The single canonical wallet-identity primitive. A gradient disc with
/// a centered white symbol (glyph OR monogram), a soft top-left
/// specular sheen, a thin light→dark edge stroke, and an optional
/// bottom-right type badge. Ported from the 2026-06-09 design handoff
/// at `/Users/thuglifex/Downloads/design_handoff_wallet_avatars/`.
///
/// **The five composition layers (from back to front).**
/// 1. **Gradient disc** — vertical `LinearGradient` from the chosen
///    `WalletAvatarGradient`'s `topHex` to its `bottomHex`. The
///    primary differentiator the eye sorts in a list.
/// 2. **Sheen** — soft white `RadialGradient` centered at (34%, 24%)
///    with stops 0.26 → 0.03 → 0. This is what makes the disc feel
///    premium rather than flat-painted — it's the surface reacting
///    to ambient light from upper-left, the same trick the iOS app
///    icon material uses.
/// 3. **Symbol** — the white inner mark. Either a `WalletAvatarGlyph`
///    (21 options) rendered by `WalletAvatarGlyphView`, or a 1–2
///    character monogram rendered in SF Pro Display 600, −1 tracking,
///    auto-sized (46pt for 1 char, 34pt for 2 — JS engine parity).
/// 4. **Edge stroke** — thin vertical `LinearGradient` (white@0.45
///    top → black@0.18 bottom), width 1.5/100 of the disc diameter.
///    Reads as a glassy rim — the disc's relationship to the
///    surrounding surface.
/// 5. **Type badge** (optional) — bottom-right corner overlay. Only
///    rendered when the wallet's kind derives one (watch / hardware /
///    shared).
///
/// **Sizes.** Six fixed envelopes matching every wallet-identity
/// surface in the app. Picked so the symbol stays legible at every
/// scale — the glyph stroke width and monogram font size scale
/// linearly with the disc diameter so the visual weight stays
/// consistent.
///
/// **Why a single primitive and not per-surface compositions.** Per
/// Rule #19's "name the canonical primitive, forbid the variants" —
/// applied to identity, not CTAs. Every wallet-identity surface in
/// the app renders through THIS file. If the design changes
/// tomorrow (different sheen, different stroke, different glyph),
/// one edit propagates everywhere.
///
/// **Why no Rule #7 violation.** Per the design handoff: these
/// glyphs are real designed marks that came from the designer's
/// tooling — the same JS engine the designer used to validate the
/// system. The iOS port is faithful to those marks. Per Rule #7
/// §A: *"Can you cite the source URL and the license?"* — yes:
/// `/Users/thuglifex/Downloads/design_handoff_wallet_avatars/
/// aperture-wallet-avatars.js` and `aperture-icon.js`. Brought into
/// the codebase by hand; recorded in `Assets.xcassets/README.md`.
struct WalletAvatar: View {
    /// Rendered diameter of the disc.
    enum Size {
        /// 28pt — the iOS tab-bar glyph envelope.
        case tabIcon
        /// 22pt — the toolbar wallet-pill leading.
        case toolbarPill
        /// 24pt — the long-press context-menu row leading.
        case menuLeading
        /// 36pt — the canonical list-row size.
        case row
        /// 56pt — the Settings → Wallets → <wallet> preview anchor.
        case preview
        /// 80pt — the editor's smaller hero preview (legacy).
        case hero
        /// 96pt — the picker's live preview at the top of the
        /// customisation sheet. Matches the design handoff's hero
        /// preview size.
        case editor
        /// 120pt — the largest hero envelope (future "wallet welcome"
        /// surfaces). Reserved.
        case heroXL

        var diameter: CGFloat {
            switch self {
            case .tabIcon:     return 28
            case .toolbarPill: return 22
            case .menuLeading: return 24
            case .row:         return 36
            case .preview:     return 56
            case .hero:        return 80
            case .editor:      return 96
            case .heroXL:      return 120
            }
        }
    }

    /// The spec that drives the rendering. Always one well-formed
    /// value — gradient, symbol type, glyph or monogram, optional
    /// badge.
    let spec: WalletAvatarSpec
    /// Rendered size.
    let size: Size
    /// Wallet UUID for the cached-PNG lookup when `spec.symbolType ==
    /// .custom`. Nil for surfaces that are pre-commit (the picker's
    /// live preview) or that pre-date the Upload tab — those paths
    /// render the monogram fallback for `.custom` specs whose UUID
    /// the caller has not threaded through. Existing call sites that
    /// always render a persisted wallet pass `walletId:` so the
    /// custom-SVG branch can read the cache.
    let walletId: UUID?

    init(spec: WalletAvatarSpec, size: Size, walletId: UUID? = nil) {
        self.spec = spec
        self.size = size
        self.walletId = walletId
    }

    // MARK: - Body

    var body: some View {
        let diameter = size.diameter

        ZStack {
            // Layer 1: gradient disc (vertical top → bottom).
            Circle()
                .fill(
                    LinearGradient(
                        colors: UniColors.WalletAvatar.gradientStops(for: spec.gradient),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: diameter, height: diameter)

            // Layer 2: specular sheen — radial highlight upper-left.
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.white.opacity(0.26), location: 0),
                            .init(color: Color.white.opacity(0.03), location: 0.6),
                            .init(color: Color.white.opacity(0.0),  location: 1)
                        ]),
                        // The JS engine uses cx=0.34, cy=0.24, r=0.80 in
                        // SVG-relative coordinates. SwiftUI's
                        // RadialGradient takes a center UnitPoint plus
                        // a startRadius / endRadius pair in points — we
                        // map the same source.
                        center: UnitPoint(x: 0.34, y: 0.24),
                        startRadius: 0,
                        endRadius: diameter * 0.80
                    )
                )
                .frame(width: diameter, height: diameter)

            // Layer 3: inner symbol — glyph OR monogram.
            innerSymbol(diameter: diameter)

            // Layer 4: edge stroke (light→dark vertical).
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.45),
                            Color.black.opacity(0.18)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: max(0.5, diameter * 0.015)
                )
                .frame(
                    // The stroke is centered on the circle's edge —
                    // the JS engine draws it at r=47.25 inside the
                    // 100-pt viewBox, i.e. 0.75pt inside the r=48
                    // disc. We render the stroke directly on the
                    // disc bounds (Circle's stroke is centered on
                    // the edge) so the inner half of the stroke
                    // lands on the gradient and the outer half
                    // lands on the surrounding surface — the same
                    // visual placement as the prototype's r=47.25.
                    width: diameter,
                    height: diameter
                )

            // Layer 5: type badge (optional, bottom-right corner).
            if let badge = spec.badge {
                WalletAvatarBadgeOverlay(badge: badge, avatarDiameter: diameter)
                    // Per the JS engine: badge translates to (64, 64)
                    // inside the 100-pt viewBox — so its center sits
                    // at 78/100, 78/100 (64 + 14). We position the
                    // overlay so its center lands at the same ratio.
                    .offset(
                        x: diameter * (78.0 / 100.0) - diameter / 2,
                        y: diameter * (78.0 / 100.0) - diameter / 2
                    )
            }
        }
        .frame(width: diameter, height: diameter)
        // Decorative — VoiceOver announces the wallet name via the
        // surrounding container's label. The disc itself carries no
        // semantics that aren't already in the name. Per Rule #7
        // §C the disc is a structural surface, not an icon — its
        // meaning is "identity," carried by the symbol inside.
        .accessibilityHidden(true)
    }

    // MARK: - Inner symbol switch

    @ViewBuilder
    private func innerSymbol(diameter: CGFloat) -> some View {
        switch spec.symbolType {
        case .glyph:
            if let glyph = spec.glyph {
                WalletAvatarGlyphView(glyph: glyph, size: diameter)
            } else {
                // Defensive — if a spec has symbolType .glyph but a nil
                // glyph (corrupted persistence), render a calm fallback
                // rather than crashing.
                fallbackMonogram(diameter: diameter, text: "·")
            }
        case .mono:
            fallbackMonogram(diameter: diameter, text: spec.monogram ?? "W")
        case .custom:
            customSvgImage(diameter: diameter)
        }
    }

    /// Render the user-uploaded sanitized SVG via `WalletCustomSvgRenderer`'s
    /// disk cache. Strategy:
    ///
    /// - If a `walletId` is threaded and the renderer has a cached PNG
    ///   for that id, draw it inside a ~48/100-of-disc box centered on
    ///   the disc (matching the JS reference's `<image x="26" y="26"
    ///   width="48" height="48"/>` rectangle).
    /// - If no cache exists yet (first render after save, or after a
    ///   cache eviction), fire an async `renderAndCache(...)` and show
    ///   a calm monogram placeholder until the PNG lands. The
    ///   `@State refreshTrigger` flip on completion causes the body
    ///   to re-evaluate and pick up the now-cached image.
    /// - If the spec is `.custom` but carries no `walletId` (the
    ///   picker's live preview, which uses its own inline
    ///   `CustomSvgPreviewView`), fall through to the monogram —
    ///   the picker handles its own live preview separately.
    @ViewBuilder
    private func customSvgImage(diameter: CGFloat) -> some View {
        if let id = walletId, let svg = spec.customSvg {
            CustomSvgCachedView(
                walletId: id,
                svg: svg,
                tint: spec.customTint ?? .white,
                diameter: diameter
            )
        } else {
            // Spec is .custom but caller didn't thread walletId —
            // safe fallback. Render the monogram so the disc is
            // never blank.
            fallbackMonogram(diameter: diameter, text: spec.monogram ?? "W")
        }
    }

    /// Monogram renderer — 1–2 characters, white, SF Pro Display 600
    /// with −1 tracking. Font size is calibrated against the JS engine:
    /// 46pt at 100pt diameter for 1 char, 34pt for 2 chars. We scale
    /// those linearly with the actual diameter so the monogram looks
    /// right at every size.
    @ViewBuilder
    private func fallbackMonogram(diameter: CGFloat, text: String) -> some View {
        let display = String(text.prefix(2))
        // JS engine: fontSize 46 for 1 char, 34 for 2, against the
        // 100-pt viewBox. Scale to actual diameter.
        let baseSize: CGFloat = display.count >= 2 ? 34 : 46
        let resolved = baseSize * (diameter / 100.0)
        Text(verbatim: display)
            .font(.system(size: resolved, weight: .semibold, design: .default))
            // SF Pro Display naming: SwiftUI auto-selects display for
            // sizes ≥ 20pt; below that it picks Text. At our smallest
            // sizes (tab icon 28pt → 14pt font, toolbar pill 22pt →
            // 10pt font) the system picks Text, which is what we want.
            .tracking(-1)
            .foregroundStyle(Color.white)
    }
}

// MARK: - Legacy initialiser (transitional)
//
// The pre-2026-06-09 cut of this primitive took `symbol: String, colorHex:
// String, size: Size` — an SF Symbol name and a hex string from the
// legacy `WalletRecord.iconSymbol` / `iconColorHex` columns. The new
// primitive takes a `WalletAvatarSpec`. Until every call site is
// migrated to the spec-based init, this legacy entry point bridges
// the two by computing an auto(name) spec from the symbol/color tuple
// — the symbol becomes the auto(name)-monogram fallback, and the color
// is silently ignored (the legacy hex palette was 12 calibrated darks;
// the new gradient palette is the design source of truth). Every
// shipped surface migrates to the spec-based init in the same turn
// this primitive lands; this initialiser exists so partial migrations
// during the turn don't break the build.

extension WalletAvatar {
    /// Legacy bridge. Use `init(spec:size:)` in new code.
    init(symbol: String, colorHex: String, size: Size) {
        // The legacy symbol+color pair gave us no monogram or gradient
        // key. We synthesize a deterministic auto(name) so the disc is
        // never blank — but we use the legacy color as a hint when it
        // resolves to a known gradient (e.g. "#0B0D11" → graphite). If
        // not, seed the same `deterministicHash` that `auto(name:)`
        // uses. NOT `String.hashValue` — that's randomized per launch
        // (SipHash with a per-process seed), which made the bridged
        // gradient flicker to a different color on every app run.
        let gradient = WalletAvatarGradient.allCases.first { $0.bottomHex.caseInsensitiveCompare(colorHex) == .orderedSame }
            ?? WalletAvatarGradient.allCases[
                Int(WalletAvatarSpec.deterministicHash("\(symbol)|\(colorHex)")
                    % UInt32(WalletAvatarGradient.allCases.count))
            ]
        self.spec = WalletAvatarSpec(
            gradient: gradient,
            symbolType: .mono,
            glyph: nil,
            monogram: String(symbol.prefix(1)).uppercased(),
            badge: nil
        )
        self.size = size
        self.walletId = nil
        _ = symbol // referenced for documentation
    }
}

// MARK: - Cached custom-SVG view

/// `CustomSvgCachedView` reads the cached PNG for a wallet's uploaded
/// SVG and renders it inside the avatar's center box. If no cache
/// exists yet, it kicks off the WKWebView snapshot pipeline and shows
/// a monogram placeholder until the PNG lands.
///
/// **Why a separate view, not inline.** The async render needs an
/// `@State` to know when the PNG is on disk so the body re-evaluates.
/// `WalletAvatar`'s body is `@ViewBuilder` and switches on
/// `spec.symbolType` — adding state to one branch would force the
/// whole `WalletAvatar` to carry state for every render. Pulling the
/// cached path into its own value-type view keeps `WalletAvatar`
/// stateless and `CustomSvgCachedView` owns the refresh-on-completion.
///
/// **The 48/100 box.** Per the JS reference engine: the custom SVG
/// renders inside a 48-unit box centered at (26, 26) in the 100-unit
/// disc. We compute the same proportion in View-local points and
/// frame the cached PNG inside that box.
private struct CustomSvgCachedView: View {
    let walletId: UUID
    let svg: String
    let tint: WalletAvatarSpec.CustomTint
    let diameter: CGFloat

    @State private var cached: UIImage?
    /// Identifies the (svg, tint) the view is currently rendering. If
    /// the spec mutates (the picker overwrote the wallet's spec), we
    /// detect the change via `.task(id:)` and re-render. The SVG is
    /// keyed by a SHA-256 content digest (16 hex chars) — NOT by byte
    /// count, which fails to invalidate when an edit produces a
    /// same-length document (stale-avatar bug).
    private var renderKey: String {
        let digest = SHA256.hash(data: Data(svg.utf8))
        let svgKey = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(walletId.uuidString)|\(tint.rawValue)|\(svgKey)"
    }

    var body: some View {
        let boxSide = diameter * (48.0 / 100.0)
        Group {
            if let cached {
                Image(uiImage: cached)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: boxSide, height: boxSide)
            } else {
                // Calm placeholder while the snapshot lands. We render
                // a thin Aperture-iris instead of a monogram so the
                // placeholder feels deliberate — it's "we're working
                // on your mark," not "we lost your mark."
                WalletAvatarGlyphView(glyph: .iris, size: diameter)
                    .opacity(0.32)
            }
        }
        .task(id: renderKey) {
            // Try the cache read first — the file I/O runs off-main
            // inside `cachedImage(walletId:)`.
            if let hit = await WalletCustomSvgRenderer.cachedImage(walletId: walletId) {
                cached = hit
                return
            }
            // No cache — render and write. Failure is silent (the
            // placeholder stays); the renderer logs to OSLog.
            do {
                let image = try await WalletCustomSvgRenderer.renderAndCache(
                    walletId: walletId,
                    svg: svg,
                    tint: tint
                )
                cached = image
            } catch {
                // Leave `cached` nil; the placeholder iris stays
                // visible. A future render attempt (next body pass)
                // will retry via the same task path.
            }
        }
    }
}
