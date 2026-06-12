import SwiftUI

/// The 31 wallet-avatar glyphs from the 2026-06-09 v3 design handoff
/// (`tokens.json`: `iris` + 30 Lucide icons curated for crypto/finance).
/// Each Lucide case is ported verbatim from the handoff's
/// `aperture-wallet-avatars.js → LUCIDE` table — every `<path d="..."/>`,
/// `<circle .../>`, `<rect .../>`, `<line .../>` element re-authored as
/// SwiftUI `Path` commands with the same anchor points the Lucide source
/// SVGs use. The iris case stays Aperture's own brand pinwheel (ported
/// from `aperture-icon.js`).
///
/// **The 24 → 100 transform.** Lucide icons live in a 24×24 viewBox with
/// `currentColor` stroke + `stroke-width="2"` + `stroke-linecap="round"` +
/// `stroke-linejoin="round"`. The handoff engine wraps each one with
/// `transform="translate(28, 28) scale(1.833)"` so the 24-unit drawing
/// occupies (28...72, 28...72) inside the 100-unit avatar disc — a
/// centered 44pt × 44pt block. The renderer below applies the same
/// transform via `CGAffineTransform`, then strokes at width 2 (in the
/// 24-unit space) so the painted stroke is `2 × 1.833 ≈ 3.67` units in
/// the 100-unit space, matching the JS reference's painted weight.
///
/// **Iris stays special.** The iris is rendered against the 100-unit
/// coordinate space directly (no 24-unit translate), with six wedges
/// at alternating 0.80 / 0.96 opacity plus thin centerlines at 0.32
/// opacity — same as the prototype. See `drawIris(...)`.
///
/// **Why a native SwiftUI port and not bundled SVG assets.** Per Rule
/// #3 (native-only): bundling SVGs and routing them through an
/// `Image` rasterizer adds indirection without a win — SwiftUI `Path`
/// gives us crisp scaling at every avatar size (28 → 120), native
/// `Color.white` strokes that respect Liquid Glass blending, and
/// Color-mode swap in the picker grid (`GlyphCellRender` strokes the
/// same paths in `UniColors.Text.primary` instead of white). One source
/// of truth, two render targets.
///
/// **Lucide attribution + license.** The 30 Lucide icons are
/// distributed under ISC. The full license text and per-icon
/// provenance live at the repo root in `LUCIDE_ICONS_LICENSE.md`, with
/// a one-line summary in `Assets.xcassets/README.md` — per Rule #7 §B
/// priority 3 and §D's per-asset provenance requirement.
///
/// **Glyph-name retirement (2026-06-09 v3).** The pre-v3 cuts of this
/// enum carried 20 geometric marks (`dot`, `ring`, `rings`, `dots`,
/// `bars`, `hex`, `diamond`, `triangle`, `square`, `bolt`, `heart`,
/// `leaf`, `moon`, `key`, `flame`, `anchor`, `infinity`, `star`,
/// `globe`, `shield`). Some of those names survive in the v3 cut
/// (`flame`, `star`, `globe`, `shield`, `anchor`, `infinity`) but the
/// *paths* behind every case — including the surviving names — now
/// come from Lucide, not the prior hand-built geometric forms. Pre-v3
/// wallets whose `avatarGlyph` raw value is a retired value (`dot`,
/// `ring`, `rings`, `dots`, `bars`, `hex`, `diamond`, `triangle`,
/// `square`, `bolt`, `heart`, `leaf`, `moon`, `key`) decode through
/// `WalletAvatarGlyph(rawValue:)` as `nil`, and `WalletAvatarSpec.
/// hydrate(...)` falls through the existing "no resolvable glyph"
/// branch into a `.mono` avatar on the wallet's initial — never blank,
/// never crashing. See `WalletAvatarSpec.swift` for the hydrate path.
enum WalletAvatarGlyph: String, Hashable, Sendable, Codable, CaseIterable {
    /// The Aperture iris brand mark. 6-blade pinwheel with 0.18 twist,
    /// from `aperture-icon.js`. Always first and the default for the
    /// `randomDefault()` / `auto(name)` paths. The only glyph that's
    /// an Aperture brand asset; the other 30 are Lucide.
    case iris

    // MARK: - 30 Lucide icons (v3 tokens.json order)
    //
    // The kebab-case Lucide name is mapped to camelCase for Swift
    // (e.g. `wallet-minimal` → `walletMinimal`). The raw values match
    // the camelCase names so the SwiftData column stores
    // `"walletMinimal"` and the JS engine's kebab-case keys can be
    // round-tripped by the picker if needed.

    case wallet
    case walletMinimal
    case piggyBank
    case landmark
    case banknote
    case coins
    case handCoins
    case circleDollarSign
    case badgeDollarSign
    case bitcoin
    case gem
    case vault
    case shield
    case shieldCheck
    case keyRound
    case lock
    case creditCard
    case trendingUp
    case chartPie
    case chartCandlestick
    case rocket
    case briefcase
    case target
    case zap
    case flame
    case sparkles
    case star
    case globe
    case anchor
    case infinity
}

// MARK: - Renderer

/// Renders one wallet-avatar glyph at a given size, stroked white. The
/// renderer is its own `View` (not a `Shape`) because the `iris` mark
/// uses multiple paths with per-blade opacities — not a single Path
/// that can be cleanly stroked or filled. For every Lucide case the
/// renderer composes the icon's paths in 24-unit space, applies the
/// 28-translate × 1.833-scale to land in the 100-disc, and strokes at
/// width 2 (24-unit) — matching the JS engine's painted weight.
struct WalletAvatarGlyphView: View {
    let glyph: WalletAvatarGlyph
    /// Avatar diameter in points. The glyph viewBox is 100×100 and
    /// renders centered inside this size.
    let size: CGFloat

    var body: some View {
        Canvas { context, _ in
            // The avatar disc is `size × size`. The glyph is authored
            // either at 100×100 (iris) or at 24×24 with a Lucide
            // translate(28,28) scale(1.833) wrapper. In both cases the
            // outer-most scale into the View's local frame is
            // `size / 100` — so we apply that single scale factor and
            // let the per-glyph affine handle the rest.
            let outerScale = size / 100.0

            switch glyph {
            case .iris:
                drawIris(in: context, scale: outerScale)
            default:
                drawLucide(glyph: glyph, in: context, scale: outerScale)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: Lucide renderer

    /// Stroke the Lucide icon's paths in white inside the avatar disc.
    /// The icon's source paths are in 24-unit space; we apply the
    /// `translate(28, 28) scale(1.833)` wrapper FIRST, then the
    /// outer-scale (`size / 100`) to land in the View's local frame.
    /// Stroke width is 2 in 24-unit space — which becomes
    /// `2 × 1.833 × (size / 100)` painted — i.e. ≈ 3.67 × (size / 100)
    /// in View-local points. At a 96pt avatar that's ≈ 3.52pt; at a
    /// 28pt tab icon ≈ 1.03pt. Same visual weight at every size.
    private func drawLucide(
        glyph: WalletAvatarGlyph,
        in context: GraphicsContext,
        scale outerScale: CGFloat
    ) {
        // Combined affine: (translate by 28 in 100-space, then scale by
        // 1.833 from 24-space into 100-space), then outerScale into
        // View-local points. Composed in one transform.
        let inner = CGAffineTransform.identity
            .scaledBy(x: outerScale, y: outerScale) // 100 → View
            .translatedBy(x: 28, y: 28)             // 100-space translate
            .scaledBy(x: 1.833, y: 1.833)           // 24 → 100

        // Stroke width: the source SVG sets stroke-width="2" in
        // 24-unit space. The combined transform scales it
        // `1.833 × outerScale`. CGContext stroke width is in the
        // CURRENT (composed) coordinate space — but our renderer
        // strokes AFTER applying `.applying(transform)` to the Path,
        // which means the stroke is painted in View-local points. We
        // pre-compute the painted width so it matches the JS reference.
        let lineWidth: CGFloat = 2.0 * 1.833 * outerScale

        // Each Lucide entry produces an array of Path / fill flag
        // pairs. Most icons are stroke-only single-path; a handful
        // (vault, key-round, banknote, gem) carry a filled inner
        // circle ("dot") that we render as a separate filled path.
        // The renderer below honors both.
        let segments = glyph.lucidePaths()
        for segment in segments {
            let transformed = segment.path.applying(inner)
            switch segment.style {
            case .stroke:
                context.stroke(
                    transformed,
                    with: .color(.white),
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            case .fill:
                context.fill(transformed, with: .color(.white))
            }
        }
    }

    // MARK: Iris renderer (Aperture brand pinwheel)

    /// 6-blade iris with 0.18 twist — port of `aperture-icon.js`'s
    /// `iris(C, R, N, twist, color)`. In the JS engine the iris is
    /// drawn at C=500, R=300 inside a 1000-unit design space and then
    /// scaled into the avatar. Here we scale into 100 directly: C=50,
    /// R=30. The 60%-of-tile ratio (R = 0.30 × tileSize) matches the
    /// engine's tile-fill ratio.
    private func drawIris(in context: GraphicsContext, scale: CGFloat) {
        let bladeCount = 6
        let twist: Double = 0.18
        let centerX: Double = 50
        let centerY: Double = 50
        let outerR: Double = 30
        let innerR = outerR * 0.42
        let step = (2 * .pi) / Double(bladeCount)

        for k in 0..<bladeCount {
            let angle = Double(k) * step - .pi / 2
            let p1 = polar(cx: centerX, cy: centerY, r: outerR, a: angle)
            let p3 = polar(cx: centerX, cy: centerY, r: innerR, a: angle + step + twist)
            let opacity: Double = (k % 2 == 0) ? 0.80 : 0.96

            var path = Path()
            path.move(to: CGPoint(x: p1.x, y: p1.y))
            path.addArc(
                center: CGPoint(x: centerX, y: centerY),
                radius: outerR,
                startAngle: .radians(angle),
                endAngle: .radians(angle + step),
                clockwise: false
            )
            path.addLine(to: CGPoint(x: p3.x, y: p3.y))
            path.closeSubpath()
            let scaled = path.applying(.init(scaleX: scale, y: scale))
            context.fill(scaled, with: .color(.white.opacity(opacity)))
        }

        // Centerline strokes — one per blade at 0.32 opacity, width 2.8% of R.
        let centerlineWidth = (outerR * 0.028) * scale
        for k in 0..<bladeCount {
            let angle = Double(k) * step - .pi / 2
            let p1 = polar(cx: centerX, cy: centerY, r: outerR, a: angle)
            let p3 = polar(cx: centerX, cy: centerY, r: innerR, a: angle + twist)
            var path = Path()
            path.move(to: CGPoint(x: p1.x, y: p1.y))
            path.addLine(to: CGPoint(x: p3.x, y: p3.y))
            let scaled = path.applying(.init(scaleX: scale, y: scale))
            context.stroke(
                scaled,
                with: .color(.white.opacity(0.32)),
                style: StrokeStyle(
                    lineWidth: centerlineWidth,
                    lineCap: .round
                )
            )
        }
    }

    private func polar(cx: Double, cy: Double, r: Double, a: Double) -> CGPoint {
        CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
    }
}

// MARK: - Lucide path tables (24-unit space)
//
// Each Lucide icon decomposes into one or more `LucideSegment`s. A
// segment carries a SwiftUI `Path` (authored in 24-unit space, matching
// the upstream Lucide SVG verbatim) plus a render style — `.stroke`
// (the vast majority) or `.fill` (the small filled-circle "dot"
// children in `vault`, `key-round`, `banknote`, `gem`, etc.).

/// One drawable element inside a Lucide icon's 24-unit composition.
/// `Sendable` (Path and the Style enum are both Sendable value types)
/// so the segments can live in the nonisolated static path cache.
struct LucideSegment: Sendable {
    enum Style: Sendable { case stroke, fill }
    let path: Path
    let style: Style
}

extension WalletAvatarGlyph {

    /// Pre-resolved path tables, one entry per glyph case. The path
    /// builders are pure and deterministic — same case, same segments,
    /// forever — so there is no reason to re-allocate ~30 `Path`
    /// values inside `Canvas` on every frame (the pre-cache shape made
    /// every avatar body pass rebuild its glyph's full path list).
    /// `static let` initialization is lazy and thread-safe: the table
    /// is built exactly once, on first access.
    private static let pathCache: [WalletAvatarGlyph: [LucideSegment]] = {
        var cache = [WalletAvatarGlyph: [LucideSegment]](
            minimumCapacity: WalletAvatarGlyph.allCases.count
        )
        for glyph in WalletAvatarGlyph.allCases {
            cache[glyph] = glyph.buildLucidePaths()
        }
        return cache
    }()

    /// `.coins` small-coin arc angles. Constant trigonometry — the
    /// inputs are literals — hoisted out of the path builder as stored
    /// constants so they are computed once, not per build.
    private static let coinsArcStartAngle: Double = atan2(17.736 - 13.996, 13.744 - 10.004)
    private static let coinsArcEndAngle: Double = atan2(10.256 - 13.996, 6.264 - 10.004)

    /// The Lucide path data for this glyph, authored in 24-unit space.
    /// Cached — returns the pre-built segment list from `pathCache`
    /// (see above); the actual geometry lives in `buildLucidePaths()`.
    /// For `.iris` this returns an empty array (the iris is handled by
    /// `drawIris(...)`, not the Lucide pipeline).
    /// File-package access for the in-target picker view's
    /// `GlyphCellRender` — Swift's access control doesn't have a
    /// per-target "internal-but-only-to-our-renderers" tier, so we
    /// expose this `internal` and rely on the convention that no
    /// other file calls it. The picker file is the sole consumer.
    internal func lucidePaths() -> [LucideSegment] {
        Self.pathCache[self] ?? []
    }

    /// Build the segment list for this glyph. Called exactly once per
    /// case, from the `pathCache` initializer — every render-time
    /// consumer goes through `lucidePaths()`. Each Lucide case's
    /// returned segments mirror the upstream SVG: every
    /// `<path d="..."/>` becomes one stroke segment, every
    /// `<circle ... fill="currentColor"/>` becomes one fill segment,
    /// every `<rect .../>` becomes one stroke segment (rounded if `rx`
    /// is non-zero), every `<line .../>` becomes one stroke segment.
    private func buildLucidePaths() -> [LucideSegment] {
        switch self {
        case .iris:
            return []

        case .wallet:
            // `<path d="M19 7V4a1 1 0 0 0-1-1H5a2 2 0 0 0 0 4h15a1 1 0 0 1 1 1v4h-3a2 2 0 0 0 0 4h3a1 1 0 0 0 1-1v-2a1 1 0 0 0-1-1"/>`
            // `<path d="M3 5v14a2 2 0 0 0 2 2h15a1 1 0 0 0 1-1v-4"/>`
            var a = Path()
            a.move(to: CGPoint(x: 19, y: 7))
            a.addLine(to: CGPoint(x: 19, y: 4))
            // a 1 1 0 0 0 -1 -1  → arc with rx=ry=1, from (19,4) to (18,3)
            a.addArc(tangent1End: CGPoint(x: 19, y: 3), tangent2End: CGPoint(x: 18, y: 3), radius: 1)
            a.addLine(to: CGPoint(x: 5, y: 3))
            // a 2 2 0 0 0 0 4 → arc r=2 from (5,3) to (5,7)
            a.addArc(tangent1End: CGPoint(x: 3, y: 3), tangent2End: CGPoint(x: 3, y: 5), radius: 2)
            a.addArc(tangent1End: CGPoint(x: 3, y: 7), tangent2End: CGPoint(x: 5, y: 7), radius: 2)
            a.addLine(to: CGPoint(x: 20, y: 7))
            // a 1 1 0 0 1 1 1 → arc r=1 from (20,7) to (21,8)
            a.addArc(tangent1End: CGPoint(x: 21, y: 7), tangent2End: CGPoint(x: 21, y: 8), radius: 1)
            a.addLine(to: CGPoint(x: 21, y: 12))
            a.addLine(to: CGPoint(x: 18, y: 12))
            // a 2 2 0 0 0 0 4
            a.addArc(tangent1End: CGPoint(x: 16, y: 12), tangent2End: CGPoint(x: 16, y: 14), radius: 2)
            a.addArc(tangent1End: CGPoint(x: 16, y: 16), tangent2End: CGPoint(x: 18, y: 16), radius: 2)
            a.addLine(to: CGPoint(x: 21, y: 16))
            // a 1 1 0 0 0 1 -1
            a.addArc(tangent1End: CGPoint(x: 22, y: 16), tangent2End: CGPoint(x: 22, y: 15), radius: 1)
            a.addLine(to: CGPoint(x: 22, y: 13))
            // a 1 1 0 0 0 -1 -1
            a.addArc(tangent1End: CGPoint(x: 22, y: 12), tangent2End: CGPoint(x: 21, y: 12), radius: 1)

            var b = Path()
            b.move(to: CGPoint(x: 3, y: 5))
            b.addLine(to: CGPoint(x: 3, y: 19))
            // a 2 2 0 0 0 2 2
            b.addArc(tangent1End: CGPoint(x: 3, y: 21), tangent2End: CGPoint(x: 5, y: 21), radius: 2)
            b.addLine(to: CGPoint(x: 20, y: 21))
            // a 1 1 0 0 0 1 -1
            b.addArc(tangent1End: CGPoint(x: 21, y: 21), tangent2End: CGPoint(x: 21, y: 20), radius: 1)
            b.addLine(to: CGPoint(x: 21, y: 16))

            return [
                LucideSegment(path: a, style: .stroke),
                LucideSegment(path: b, style: .stroke)
            ]

        case .walletMinimal:
            // `<path d="M17 14h.01"/>`  — a degenerate dot (round-capped line)
            // `<path d="M7 7h12a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h14"/>`
            var dot = Path()
            dot.move(to: CGPoint(x: 17, y: 14))
            dot.addLine(to: CGPoint(x: 17.01, y: 14))

            var body = Path()
            body.move(to: CGPoint(x: 7, y: 7))
            body.addLine(to: CGPoint(x: 19, y: 7))
            // a 2 2 0 0 1 2 2 → arc r=2 from (19,7) to (21,9)
            body.addArc(tangent1End: CGPoint(x: 21, y: 7), tangent2End: CGPoint(x: 21, y: 9), radius: 2)
            body.addLine(to: CGPoint(x: 21, y: 19))
            // a 2 2 0 0 1 -2 2
            body.addArc(tangent1End: CGPoint(x: 21, y: 21), tangent2End: CGPoint(x: 19, y: 21), radius: 2)
            body.addLine(to: CGPoint(x: 5, y: 21))
            // a 2 2 0 0 1 -2 -2
            body.addArc(tangent1End: CGPoint(x: 3, y: 21), tangent2End: CGPoint(x: 3, y: 19), radius: 2)
            body.addLine(to: CGPoint(x: 3, y: 5))
            // a 2 2 0 0 1 2 -2
            body.addArc(tangent1End: CGPoint(x: 3, y: 3), tangent2End: CGPoint(x: 5, y: 3), radius: 2)
            body.addLine(to: CGPoint(x: 19, y: 3))
            return [
                LucideSegment(path: dot, style: .stroke),
                LucideSegment(path: body, style: .stroke)
            ]

        case .piggyBank:
            // `<path d="M11 17h3v2a1 1 0 0 0 1 1h2a1 1 0 0 0 1-1v-3a3.16 3.16 0 0 0 2-2h1a1 1 0 0 0 1-1v-2a1 1 0 0 0-1-1h-1a5 5 0 0 0-2-4V3a4 4 0 0 0-3.2 1.6l-.3.4H11a6 6 0 0 0-6 6v1a5 5 0 0 0 2 4v3a1 1 0 0 0 1 1h2a1 1 0 0 0 1-1z"/>`
            // `<path d="M16 10h.01"/>`
            // `<path d="M2 8v1a2 2 0 0 0 2 2h1"/>`
            var body = Path()
            body.move(to: CGPoint(x: 11, y: 17))
            body.addLine(to: CGPoint(x: 14, y: 17))
            body.addLine(to: CGPoint(x: 14, y: 19))
            body.addArc(tangent1End: CGPoint(x: 14, y: 20), tangent2End: CGPoint(x: 15, y: 20), radius: 1)
            body.addLine(to: CGPoint(x: 17, y: 20))
            body.addArc(tangent1End: CGPoint(x: 18, y: 20), tangent2End: CGPoint(x: 18, y: 19), radius: 1)
            body.addLine(to: CGPoint(x: 18, y: 16))
            // a 3.16 3.16 0 0 0 2 -2 (rel from (18,16) → (20,14))
            body.addArc(tangent1End: CGPoint(x: 20, y: 16), tangent2End: CGPoint(x: 20, y: 14), radius: 3.16)
            body.addLine(to: CGPoint(x: 21, y: 14))
            body.addArc(tangent1End: CGPoint(x: 22, y: 14), tangent2End: CGPoint(x: 22, y: 13), radius: 1)
            body.addLine(to: CGPoint(x: 22, y: 11))
            body.addArc(tangent1End: CGPoint(x: 22, y: 10), tangent2End: CGPoint(x: 21, y: 10), radius: 1)
            body.addLine(to: CGPoint(x: 20, y: 10))
            // a 5 5 0 0 0 -2 -4 (from (20,10) → (18,6))
            body.addArc(tangent1End: CGPoint(x: 20, y: 6), tangent2End: CGPoint(x: 18, y: 6), radius: 5)
            body.addLine(to: CGPoint(x: 18, y: 3))
            // a 4 4 0 0 0 -3.2 1.6 (from (18,3) → (14.8,4.6))
            body.addArc(tangent1End: CGPoint(x: 14.8, y: 3), tangent2End: CGPoint(x: 14.8, y: 4.6), radius: 4)
            body.addLine(to: CGPoint(x: 14.5, y: 5))
            body.addLine(to: CGPoint(x: 11, y: 5))
            // a 6 6 0 0 0 -6 6 (from (11,5) → (5,11))
            body.addArc(tangent1End: CGPoint(x: 5, y: 5), tangent2End: CGPoint(x: 5, y: 11), radius: 6)
            body.addLine(to: CGPoint(x: 5, y: 12))
            // a 5 5 0 0 0 2 4 (from (5,12) → (7,16))
            body.addArc(tangent1End: CGPoint(x: 5, y: 16), tangent2End: CGPoint(x: 7, y: 16), radius: 5)
            body.addLine(to: CGPoint(x: 7, y: 19))
            body.addArc(tangent1End: CGPoint(x: 7, y: 20), tangent2End: CGPoint(x: 8, y: 20), radius: 1)
            body.addLine(to: CGPoint(x: 10, y: 20))
            body.addArc(tangent1End: CGPoint(x: 11, y: 20), tangent2End: CGPoint(x: 11, y: 19), radius: 1)
            body.closeSubpath()

            var eye = Path()
            eye.move(to: CGPoint(x: 16, y: 10))
            eye.addLine(to: CGPoint(x: 16.01, y: 10))

            var tail = Path()
            tail.move(to: CGPoint(x: 2, y: 8))
            tail.addLine(to: CGPoint(x: 2, y: 9))
            tail.addArc(tangent1End: CGPoint(x: 2, y: 11), tangent2End: CGPoint(x: 4, y: 11), radius: 2)
            tail.addLine(to: CGPoint(x: 5, y: 11))
            return [
                LucideSegment(path: body, style: .stroke),
                LucideSegment(path: eye, style: .stroke),
                LucideSegment(path: tail, style: .stroke)
            ]

        case .landmark:
            // 6 stroke paths: 4 columns + roof + base.
            // `<path d="M10 18v-7"/>` `<path d="M14 18v-7"/>`
            // `<path d="M18 18v-7"/>` `<path d="M6 18v-7"/>`
            // `<path d="M11.119 2.205a2 2 0 0 1 1.762 0l7.84 3.846A.5.5 0 0 1 20.5 7h-17a.5.5 0 0 1-.22-.949z"/>`
            // `<path d="M3 22h18"/>`
            var col1 = Path(); col1.move(to: CGPoint(x: 10, y: 18)); col1.addLine(to: CGPoint(x: 10, y: 11))
            var col2 = Path(); col2.move(to: CGPoint(x: 14, y: 18)); col2.addLine(to: CGPoint(x: 14, y: 11))
            var col3 = Path(); col3.move(to: CGPoint(x: 18, y: 18)); col3.addLine(to: CGPoint(x: 18, y: 11))
            var col4 = Path(); col4.move(to: CGPoint(x: 6, y: 18));  col4.addLine(to: CGPoint(x: 6, y: 11))

            var roof = Path()
            roof.move(to: CGPoint(x: 11.119, y: 2.205))
            // a 2 2 0 0 1 1.762 0 (rel) → (12.881, 2.205)
            roof.addArc(tangent1End: CGPoint(x: 12, y: 2.205), tangent2End: CGPoint(x: 12.881, y: 2.205), radius: 2)
            // l 7.84 3.846 → (20.721, 6.051)
            roof.addLine(to: CGPoint(x: 20.721, y: 6.051))
            // A.5.5 0 0 1 20.5 7 — absolute arc to (20.5, 7)
            roof.addArc(tangent1End: CGPoint(x: 21, y: 6.5), tangent2End: CGPoint(x: 20.5, y: 7), radius: 0.5)
            // h -17 → (3.5, 7)
            roof.addLine(to: CGPoint(x: 3.5, y: 7))
            // a .5 .5 0 0 1 -.22 -.949
            roof.addArc(tangent1End: CGPoint(x: 3, y: 7), tangent2End: CGPoint(x: 3.28, y: 6.051), radius: 0.5)
            roof.closeSubpath()

            var base = Path()
            base.move(to: CGPoint(x: 3, y: 22))
            base.addLine(to: CGPoint(x: 21, y: 22))
            return [
                LucideSegment(path: col1, style: .stroke),
                LucideSegment(path: col2, style: .stroke),
                LucideSegment(path: col3, style: .stroke),
                LucideSegment(path: col4, style: .stroke),
                LucideSegment(path: roof, style: .stroke),
                LucideSegment(path: base, style: .stroke)
            ]

        case .banknote:
            // `<rect width="20" height="12" x="2" y="6" rx="2"/>`
            // `<circle cx="12" cy="12" r="2"/>`
            // `<path d="M6 12h.01M18 12h.01"/>`
            var rect = Path()
            rect.addRoundedRect(in: CGRect(x: 2, y: 6, width: 20, height: 12), cornerSize: CGSize(width: 2, height: 2))
            var center = Path()
            center.addEllipse(in: CGRect(x: 10, y: 10, width: 4, height: 4))
            var dots = Path()
            dots.move(to: CGPoint(x: 6, y: 12));  dots.addLine(to: CGPoint(x: 6.01, y: 12))
            dots.move(to: CGPoint(x: 18, y: 12)); dots.addLine(to: CGPoint(x: 18.01, y: 12))
            return [
                LucideSegment(path: rect, style: .stroke),
                LucideSegment(path: center, style: .stroke),
                LucideSegment(path: dots, style: .stroke)
            ]

        case .coins:
            // `<path d="M13.744 17.736a6 6 0 1 1-7.48-7.48"/>`
            // `<path d="M15 6h1v4"/>`
            // `<path d="m6.134 14.768.866-.5 2 3.464"/>`
            // `<circle cx="16" cy="8" r="6"/>`
            var smallArc = Path()
            smallArc.move(to: CGPoint(x: 13.744, y: 17.736))
            // a 6 6 0 1 1 -7.48 -7.48  → big-arc semi-circle to (6.264, 10.256)
            smallArc.addArc(
                center: CGPoint(x: 10.004, y: 13.996),
                radius: 6,
                startAngle: .radians(Self.coinsArcStartAngle),
                endAngle: .radians(Self.coinsArcEndAngle),
                clockwise: false
            )

            var l = Path()
            l.move(to: CGPoint(x: 15, y: 6))
            l.addLine(to: CGPoint(x: 16, y: 6))
            l.addLine(to: CGPoint(x: 16, y: 10))

            var tick = Path()
            tick.move(to: CGPoint(x: 6.134, y: 14.768))
            tick.addLine(to: CGPoint(x: 7, y: 14.268))
            tick.addLine(to: CGPoint(x: 9, y: 17.732))

            var bigCircle = Path()
            bigCircle.addEllipse(in: CGRect(x: 10, y: 2, width: 12, height: 12))

            return [
                LucideSegment(path: smallArc, style: .stroke),
                LucideSegment(path: l, style: .stroke),
                LucideSegment(path: tick, style: .stroke),
                LucideSegment(path: bigCircle, style: .stroke)
            ]

        case .handCoins:
            // `<path d="M11 15h2a2 2 0 1 0 0-4h-3c-.6 0-1.1.2-1.4.6L3 17"/>`
            // `<path d="m7 21 1.6-1.4c.3-.4.8-.6 1.4-.6h4c1.1 0 2.1-.4 2.8-1.2l4.6-4.4a2 2 0 0 0-2.75-2.91l-4.2 3.9"/>`
            // `<path d="m2 16 6 6"/>`
            // `<circle cx="16" cy="9" r="2.9"/>`
            // `<circle cx="6" cy="5" r="3"/>`
            var top = Path()
            top.move(to: CGPoint(x: 11, y: 15))
            top.addLine(to: CGPoint(x: 13, y: 15))
            // a 2 2 0 1 0 0 -4 → arc r=2 from (13,15) to (13,11)
            top.addArc(tangent1End: CGPoint(x: 15, y: 15), tangent2End: CGPoint(x: 15, y: 13), radius: 2)
            top.addArc(tangent1End: CGPoint(x: 15, y: 11), tangent2End: CGPoint(x: 13, y: 11), radius: 2)
            top.addLine(to: CGPoint(x: 10, y: 11))
            // c -.6 0 -1.1 .2 -1.4 .6 (rel) → end (8.6, 11.6)
            top.addCurve(
                to: CGPoint(x: 8.6, y: 11.6),
                control1: CGPoint(x: 9.4, y: 11),
                control2: CGPoint(x: 8.9, y: 11.2)
            )
            top.addLine(to: CGPoint(x: 3, y: 17))

            var bottom = Path()
            bottom.move(to: CGPoint(x: 7, y: 21))
            bottom.addLine(to: CGPoint(x: 8.6, y: 19.6))
            bottom.addCurve(
                to: CGPoint(x: 10, y: 19),
                control1: CGPoint(x: 8.9, y: 19.2),
                control2: CGPoint(x: 9.4, y: 19)
            )
            bottom.addLine(to: CGPoint(x: 14, y: 19))
            bottom.addCurve(
                to: CGPoint(x: 16.8, y: 17.8),
                control1: CGPoint(x: 15.1, y: 19),
                control2: CGPoint(x: 16.1, y: 18.6)
            )
            bottom.addLine(to: CGPoint(x: 21.4, y: 13.4))
            bottom.addArc(tangent1End: CGPoint(x: 22.4, y: 12.4), tangent2End: CGPoint(x: 21.4, y: 10.49), radius: 2)
            // The Lucide path uses a single 'a' that ends at (18.65, 10.49); from (21.4, 13.4) we model it with two arcs giving the same endpoint.
            bottom.addArc(tangent1End: CGPoint(x: 20.4, y: 9.49), tangent2End: CGPoint(x: 18.65, y: 10.49), radius: 2)
            bottom.addLine(to: CGPoint(x: 14.45, y: 14.39))

            var wrist = Path()
            wrist.move(to: CGPoint(x: 2, y: 16))
            wrist.addLine(to: CGPoint(x: 8, y: 22))

            var coinTop = Path()
            coinTop.addEllipse(in: CGRect(x: 16 - 2.9, y: 9 - 2.9, width: 5.8, height: 5.8))
            var coinBottom = Path()
            coinBottom.addEllipse(in: CGRect(x: 3, y: 2, width: 6, height: 6))

            return [
                LucideSegment(path: top, style: .stroke),
                LucideSegment(path: bottom, style: .stroke),
                LucideSegment(path: wrist, style: .stroke),
                LucideSegment(path: coinTop, style: .stroke),
                LucideSegment(path: coinBottom, style: .stroke)
            ]

        case .circleDollarSign:
            // `<circle cx="12" cy="12" r="10"/>`
            // `<path d="M16 8h-6a2 2 0 1 0 0 4h4a2 2 0 1 1 0 4H8"/>`
            // `<path d="M12 18V6"/>`
            var circle = Path()
            circle.addEllipse(in: CGRect(x: 2, y: 2, width: 20, height: 20))

            var s = Path()
            s.move(to: CGPoint(x: 16, y: 8))
            s.addLine(to: CGPoint(x: 10, y: 8))
            s.addArc(tangent1End: CGPoint(x: 8, y: 8),  tangent2End: CGPoint(x: 8, y: 10), radius: 2)
            s.addArc(tangent1End: CGPoint(x: 8, y: 12), tangent2End: CGPoint(x: 10, y: 12), radius: 2)
            s.addLine(to: CGPoint(x: 14, y: 12))
            s.addArc(tangent1End: CGPoint(x: 16, y: 12), tangent2End: CGPoint(x: 16, y: 14), radius: 2)
            s.addArc(tangent1End: CGPoint(x: 16, y: 16), tangent2End: CGPoint(x: 14, y: 16), radius: 2)
            s.addLine(to: CGPoint(x: 8, y: 16))

            var bar = Path()
            bar.move(to: CGPoint(x: 12, y: 18))
            bar.addLine(to: CGPoint(x: 12, y: 6))

            return [
                LucideSegment(path: circle, style: .stroke),
                LucideSegment(path: s, style: .stroke),
                LucideSegment(path: bar, style: .stroke)
            ]

        case .badgeDollarSign:
            // `<path d="M3.85 8.62a4 4 0 0 1 4.78-4.77 4 4 0 0 1 6.74 0 4 4 0 0 1 4.78 4.78 4 4 0 0 1 0 6.74 4 4 0 0 1-4.77 4.78 4 4 0 0 1-6.75 0 4 4 0 0 1-4.78-4.77 4 4 0 0 1 0-6.76Z"/>`
            // (S badge outline — 8-curve scallop). Same inner S + bar
            // as `circleDollarSign` underneath.
            var badge = Path()
            badge.move(to: CGPoint(x: 3.85, y: 8.62))
            badge.addArc(tangent1End: CGPoint(x: 3.85, y: 3.85), tangent2End: CGPoint(x: 8.63, y: 3.85), radius: 4)
            badge.addArc(tangent1End: CGPoint(x: 12, y: 0.85),   tangent2End: CGPoint(x: 15.37, y: 3.85), radius: 4)
            badge.addArc(tangent1End: CGPoint(x: 20.15, y: 3.85), tangent2End: CGPoint(x: 20.15, y: 8.63), radius: 4)
            badge.addArc(tangent1End: CGPoint(x: 23.15, y: 12),  tangent2End: CGPoint(x: 20.15, y: 15.37), radius: 4)
            badge.addArc(tangent1End: CGPoint(x: 20.15, y: 20.15), tangent2End: CGPoint(x: 15.38, y: 20.15), radius: 4)
            badge.addArc(tangent1End: CGPoint(x: 12, y: 23.15),  tangent2End: CGPoint(x: 8.63, y: 20.15), radius: 4)
            badge.addArc(tangent1End: CGPoint(x: 3.85, y: 20.15), tangent2End: CGPoint(x: 3.85, y: 15.38), radius: 4)
            badge.addArc(tangent1End: CGPoint(x: 0.85, y: 12),   tangent2End: CGPoint(x: 3.85, y: 8.62), radius: 4)
            badge.closeSubpath()

            var s = Path()
            s.move(to: CGPoint(x: 16, y: 8))
            s.addLine(to: CGPoint(x: 10, y: 8))
            s.addArc(tangent1End: CGPoint(x: 8, y: 8),  tangent2End: CGPoint(x: 8, y: 10), radius: 2)
            s.addArc(tangent1End: CGPoint(x: 8, y: 12), tangent2End: CGPoint(x: 10, y: 12), radius: 2)
            s.addLine(to: CGPoint(x: 14, y: 12))
            s.addArc(tangent1End: CGPoint(x: 16, y: 12), tangent2End: CGPoint(x: 16, y: 14), radius: 2)
            s.addArc(tangent1End: CGPoint(x: 16, y: 16), tangent2End: CGPoint(x: 14, y: 16), radius: 2)
            s.addLine(to: CGPoint(x: 8, y: 16))

            var bar = Path()
            bar.move(to: CGPoint(x: 12, y: 18))
            bar.addLine(to: CGPoint(x: 12, y: 6))

            return [
                LucideSegment(path: badge, style: .stroke),
                LucideSegment(path: s, style: .stroke),
                LucideSegment(path: bar, style: .stroke)
            ]

        case .bitcoin:
            // `<path d="M11.767 19.089c4.924.868 6.14-6.025 1.216-6.894m-1.216 6.894L5.86 18.047m5.908 1.042-.347 1.97m1.563-8.864c4.924.869 6.14-6.025 1.215-6.893m-1.215 6.893-3.94-.694m5.155-6.2L8.29 4.26m5.908 1.042.348-1.97M7.48 20.364l3.126-17.727"/>`
            // The Bitcoin "B" Lucide mark is a stack of relative curve
            // commands. We port each `c` + `l` + `m` verbatim.
            var path = Path()
            // M 11.767 19.089
            path.move(to: CGPoint(x: 11.767, y: 19.089))
            // c 4.924 .868 6.14 -6.025 1.216 -6.894
            // start (11.767, 19.089) → end (12.983, 12.195)
            path.addCurve(
                to: CGPoint(x: 12.983, y: 12.195),
                control1: CGPoint(x: 16.691, y: 19.957),
                control2: CGPoint(x: 17.907, y: 13.064)
            )
            // m -1.216 6.894 → move-to (11.767, 19.089)
            path.move(to: CGPoint(x: 11.767, y: 19.089))
            // L 5.86 18.047
            path.addLine(to: CGPoint(x: 5.86, y: 18.047))
            // m 5.908 1.042 → move (11.768, 19.089)
            path.move(to: CGPoint(x: 11.768, y: 19.089))
            // l -.347 1.97 → line to (11.421, 21.059)
            path.addLine(to: CGPoint(x: 11.421, y: 21.059))
            // m 1.563 -8.864 → move-to (12.984, 12.195)
            path.move(to: CGPoint(x: 12.984, y: 12.195))
            // c 4.924 .869 6.14 -6.025 1.215 -6.893
            // end (14.199, 5.302)
            path.addCurve(
                to: CGPoint(x: 14.199, y: 5.302),
                control1: CGPoint(x: 17.908, y: 13.064),
                control2: CGPoint(x: 19.124, y: 6.170)
            )
            // m -1.215 6.893 → move (12.984, 12.195)
            path.move(to: CGPoint(x: 12.984, y: 12.195))
            // l -3.94 -.694 → (9.044, 11.501)
            path.addLine(to: CGPoint(x: 9.044, y: 11.501))
            // m 5.155 -6.2 → (14.199, 5.301)
            path.move(to: CGPoint(x: 14.199, y: 5.301))
            // L 8.29 4.26
            path.addLine(to: CGPoint(x: 8.29, y: 4.26))
            // m 5.908 1.042 → (14.198, 5.302)
            path.move(to: CGPoint(x: 14.198, y: 5.302))
            // l .348 -1.97 → (14.546, 3.332)
            path.addLine(to: CGPoint(x: 14.546, y: 3.332))
            // M 7.48 20.364 l 3.126 -17.727
            path.move(to: CGPoint(x: 7.48, y: 20.364))
            path.addLine(to: CGPoint(x: 10.606, y: 2.637))
            return [LucideSegment(path: path, style: .stroke)]

        case .gem:
            // `<path d="M10.5 3 8 9l4 13 4-13-2.5-6"/>`
            // `<path d="M17 3a2 2 0 0 1 1.6.8l3 4a2 2 0 0 1 .013 2.382l-7.99 10.986a2 2 0 0 1-3.247 0l-7.99-10.986A2 2 0 0 1 2.4 7.8l2.998-3.997A2 2 0 0 1 7 3z"/>`
            // `<path d="M2 9h20"/>`
            var inner = Path()
            inner.move(to: CGPoint(x: 10.5, y: 3))
            inner.addLine(to: CGPoint(x: 8, y: 9))
            inner.addLine(to: CGPoint(x: 12, y: 22))
            inner.addLine(to: CGPoint(x: 16, y: 9))
            inner.addLine(to: CGPoint(x: 13.5, y: 3))

            var outer = Path()
            outer.move(to: CGPoint(x: 17, y: 3))
            outer.addArc(tangent1End: CGPoint(x: 18.6, y: 3),  tangent2End: CGPoint(x: 18.6, y: 3.8), radius: 2)
            outer.addLine(to: CGPoint(x: 21.6, y: 7.8))
            outer.addArc(tangent1End: CGPoint(x: 22.6, y: 9),  tangent2End: CGPoint(x: 21.613, y: 10.182), radius: 2)
            outer.addLine(to: CGPoint(x: 13.623, y: 21.168))
            outer.addArc(tangent1End: CGPoint(x: 12, y: 22),   tangent2End: CGPoint(x: 10.377, y: 21.168), radius: 2)
            outer.addLine(to: CGPoint(x: 2.387, y: 10.182))
            outer.addArc(tangent1End: CGPoint(x: 1.4, y: 9),   tangent2End: CGPoint(x: 2.4, y: 7.8), radius: 2)
            outer.addLine(to: CGPoint(x: 5.398, y: 3.803))
            outer.addArc(tangent1End: CGPoint(x: 5.398, y: 3), tangent2End: CGPoint(x: 7, y: 3), radius: 2)
            outer.closeSubpath()

            var line = Path()
            line.move(to: CGPoint(x: 2, y: 9))
            line.addLine(to: CGPoint(x: 22, y: 9))

            return [
                LucideSegment(path: inner, style: .stroke),
                LucideSegment(path: outer, style: .stroke),
                LucideSegment(path: line, style: .stroke)
            ]

        case .vault:
            // `<rect width="18" height="18" x="3" y="3" rx="2"/>`
            // 4 corner-dots (`<circle r=".5" fill="currentColor"/>`) and 4 short connecting lines.
            // `<circle cx="12" cy="12" r="2"/>` (center)
            var rect = Path()
            rect.addRoundedRect(in: CGRect(x: 3, y: 3, width: 18, height: 18), cornerSize: CGSize(width: 2, height: 2))

            // 4 filled corner-dots — radius 0.5 (so width=1, height=1)
            var dotTL = Path(); dotTL.addEllipse(in: CGRect(x: 7,   y: 7,   width: 1, height: 1))
            var dotTR = Path(); dotTR.addEllipse(in: CGRect(x: 16,  y: 7,   width: 1, height: 1))
            var dotBL = Path(); dotBL.addEllipse(in: CGRect(x: 7,   y: 16,  width: 1, height: 1))
            var dotBR = Path(); dotBR.addEllipse(in: CGRect(x: 16,  y: 16,  width: 1, height: 1))

            // 4 connecting line segments (radial spokes)
            var s1 = Path(); s1.move(to: CGPoint(x: 7.9, y: 7.9));   s1.addLine(to: CGPoint(x: 10.6, y: 10.6))
            var s2 = Path(); s2.move(to: CGPoint(x: 13.4, y: 10.6)); s2.addLine(to: CGPoint(x: 16.1, y: 7.9))
            var s3 = Path(); s3.move(to: CGPoint(x: 7.9, y: 16.1));  s3.addLine(to: CGPoint(x: 10.6, y: 13.4))
            var s4 = Path(); s4.move(to: CGPoint(x: 13.4, y: 13.4)); s4.addLine(to: CGPoint(x: 16.1, y: 16.1))

            var center = Path()
            center.addEllipse(in: CGRect(x: 10, y: 10, width: 4, height: 4))

            return [
                LucideSegment(path: rect, style: .stroke),
                LucideSegment(path: dotTL, style: .fill),
                LucideSegment(path: dotTR, style: .fill),
                LucideSegment(path: dotBL, style: .fill),
                LucideSegment(path: dotBR, style: .fill),
                LucideSegment(path: s1, style: .stroke),
                LucideSegment(path: s2, style: .stroke),
                LucideSegment(path: s3, style: .stroke),
                LucideSegment(path: s4, style: .stroke),
                LucideSegment(path: center, style: .stroke)
            ]

        case .shield:
            // `<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/>`
            var p = Path()
            // M 20 13
            p.move(to: CGPoint(x: 20, y: 13))
            // c 0 5 -3.5 7.5 -7.66 8.95
            p.addCurve(
                to: CGPoint(x: 12.34, y: 21.95),
                control1: CGPoint(x: 20, y: 18),
                control2: CGPoint(x: 16.5, y: 20.5)
            )
            // a 1 1 0 0 1 -.67 -.01
            p.addArc(tangent1End: CGPoint(x: 11.67, y: 21.95), tangent2End: CGPoint(x: 11.67, y: 21.94), radius: 1)
            // C 7.5 20.5 4 18 4 13
            p.addCurve(
                to: CGPoint(x: 4, y: 13),
                control1: CGPoint(x: 7.5, y: 20.5),
                control2: CGPoint(x: 4, y: 18)
            )
            // V 6
            p.addLine(to: CGPoint(x: 4, y: 6))
            // a 1 1 0 0 1 1 -1
            p.addArc(tangent1End: CGPoint(x: 4, y: 5), tangent2End: CGPoint(x: 5, y: 5), radius: 1)
            // c 2 0 4.5 -1.2 6.24 -2.72
            p.addCurve(
                to: CGPoint(x: 11.24, y: 2.28),
                control1: CGPoint(x: 7, y: 5),
                control2: CGPoint(x: 9.5, y: 3.8)
            )
            // a 1.17 1.17 0 0 1 1.52 0
            p.addArc(tangent1End: CGPoint(x: 12, y: 2.28), tangent2End: CGPoint(x: 12.76, y: 2.28), radius: 1.17)
            // C 14.51 3.81 17 5 19 5
            p.addCurve(
                to: CGPoint(x: 19, y: 5),
                control1: CGPoint(x: 14.51, y: 3.81),
                control2: CGPoint(x: 17, y: 5)
            )
            // a 1 1 0 0 1 1 1
            p.addArc(tangent1End: CGPoint(x: 20, y: 5), tangent2End: CGPoint(x: 20, y: 6), radius: 1)
            // Z
            p.closeSubpath()
            return [LucideSegment(path: p, style: .stroke)]

        case .shieldCheck:
            // shield outline + checkmark m9 12 l2 2 l4 -4
            var shield = Path()
            shield.move(to: CGPoint(x: 20, y: 13))
            shield.addCurve(
                to: CGPoint(x: 12.34, y: 21.95),
                control1: CGPoint(x: 20, y: 18),
                control2: CGPoint(x: 16.5, y: 20.5)
            )
            shield.addArc(tangent1End: CGPoint(x: 11.67, y: 21.95), tangent2End: CGPoint(x: 11.67, y: 21.94), radius: 1)
            shield.addCurve(
                to: CGPoint(x: 4, y: 13),
                control1: CGPoint(x: 7.5, y: 20.5),
                control2: CGPoint(x: 4, y: 18)
            )
            shield.addLine(to: CGPoint(x: 4, y: 6))
            shield.addArc(tangent1End: CGPoint(x: 4, y: 5), tangent2End: CGPoint(x: 5, y: 5), radius: 1)
            shield.addCurve(
                to: CGPoint(x: 11.24, y: 2.28),
                control1: CGPoint(x: 7, y: 5),
                control2: CGPoint(x: 9.5, y: 3.8)
            )
            shield.addArc(tangent1End: CGPoint(x: 12, y: 2.28), tangent2End: CGPoint(x: 12.76, y: 2.28), radius: 1.17)
            shield.addCurve(
                to: CGPoint(x: 19, y: 5),
                control1: CGPoint(x: 14.51, y: 3.81),
                control2: CGPoint(x: 17, y: 5)
            )
            shield.addArc(tangent1End: CGPoint(x: 20, y: 5), tangent2End: CGPoint(x: 20, y: 6), radius: 1)
            shield.closeSubpath()

            var check = Path()
            check.move(to: CGPoint(x: 9, y: 12))
            check.addLine(to: CGPoint(x: 11, y: 14))
            check.addLine(to: CGPoint(x: 15, y: 10))
            return [
                LucideSegment(path: shield, style: .stroke),
                LucideSegment(path: check, style: .stroke)
            ]

        case .keyRound:
            // `<path d="M2.586 17.414A2 2 0 0 0 2 18.828V21a1 1 0 0 0 1 1h3a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h1a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h.172a2 2 0 0 0 1.414-.586l.814-.814a6.5 6.5 0 1 0-4-4z"/>`
            // `<circle cx="16.5" cy="7.5" r=".5" fill="currentColor"/>`
            var p = Path()
            p.move(to: CGPoint(x: 2.586, y: 17.414))
            // A 2 2 0 0 0 2 18.828
            p.addArc(tangent1End: CGPoint(x: 2, y: 17.414), tangent2End: CGPoint(x: 2, y: 18.828), radius: 2)
            p.addLine(to: CGPoint(x: 2, y: 21))
            p.addArc(tangent1End: CGPoint(x: 2, y: 22), tangent2End: CGPoint(x: 3, y: 22), radius: 1)
            p.addLine(to: CGPoint(x: 6, y: 22))
            p.addArc(tangent1End: CGPoint(x: 7, y: 22), tangent2End: CGPoint(x: 7, y: 21), radius: 1)
            p.addLine(to: CGPoint(x: 7, y: 20))
            p.addArc(tangent1End: CGPoint(x: 7, y: 19), tangent2End: CGPoint(x: 8, y: 19), radius: 1)
            p.addLine(to: CGPoint(x: 9, y: 19))
            p.addArc(tangent1End: CGPoint(x: 10, y: 19), tangent2End: CGPoint(x: 10, y: 18), radius: 1)
            p.addLine(to: CGPoint(x: 10, y: 17))
            p.addArc(tangent1End: CGPoint(x: 10, y: 16), tangent2End: CGPoint(x: 11, y: 16), radius: 1)
            p.addLine(to: CGPoint(x: 11.172, y: 16))
            p.addArc(tangent1End: CGPoint(x: 12.586, y: 16), tangent2End: CGPoint(x: 12.586, y: 15.414), radius: 2)
            p.addLine(to: CGPoint(x: 13.4, y: 14.6))
            // a 6.5 6.5 0 1 0 -4 -4  → big-arc back to start. The Lucide
            // upstream uses a single arc with large-arc=1 sweep=0 from
            // (13.4, 14.6) to (9.4, 10.6). We model it as two arcs
            // through the antipode (3.4, 5.65) so the visible bell
            // matches.
            p.addArc(tangent1End: CGPoint(x: 18.4, y: 9.6), tangent2End: CGPoint(x: 14.4, y: 5.6), radius: 6.5)
            p.addArc(tangent1End: CGPoint(x: 10.4, y: 1.6), tangent2End: CGPoint(x: 4.9, y: 5.65), radius: 6.5)
            p.addArc(tangent1End: CGPoint(x: 5.4, y: 14.6), tangent2End: CGPoint(x: 9.4, y: 10.6), radius: 6.5)
            p.closeSubpath()

            var dot = Path()
            dot.addEllipse(in: CGRect(x: 16, y: 7, width: 1, height: 1))

            return [
                LucideSegment(path: p, style: .stroke),
                LucideSegment(path: dot, style: .fill)
            ]

        case .lock:
            // `<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/>`
            // `<path d="M7 11V7a5 5 0 0 1 10 0v4"/>`
            var body = Path()
            body.addRoundedRect(in: CGRect(x: 3, y: 11, width: 18, height: 11), cornerSize: CGSize(width: 2, height: 2))

            var shackle = Path()
            shackle.move(to: CGPoint(x: 7, y: 11))
            shackle.addLine(to: CGPoint(x: 7, y: 7))
            // a 5 5 0 0 1 10 0 → arc r=5 from (7,7) to (17,7)
            shackle.addArc(tangent1End: CGPoint(x: 7, y: 2), tangent2End: CGPoint(x: 12, y: 2), radius: 5)
            shackle.addArc(tangent1End: CGPoint(x: 17, y: 2), tangent2End: CGPoint(x: 17, y: 7), radius: 5)
            shackle.addLine(to: CGPoint(x: 17, y: 11))

            return [
                LucideSegment(path: body, style: .stroke),
                LucideSegment(path: shackle, style: .stroke)
            ]

        case .creditCard:
            // `<rect width="20" height="14" x="2" y="5" rx="2"/>`
            // `<line x1="2" x2="22" y1="10" y2="10"/>`
            var rect = Path()
            rect.addRoundedRect(in: CGRect(x: 2, y: 5, width: 20, height: 14), cornerSize: CGSize(width: 2, height: 2))
            var stripe = Path()
            stripe.move(to: CGPoint(x: 2, y: 10))
            stripe.addLine(to: CGPoint(x: 22, y: 10))
            return [
                LucideSegment(path: rect, style: .stroke),
                LucideSegment(path: stripe, style: .stroke)
            ]

        case .trendingUp:
            // `<path d="M16 7h6v6"/>`  `<path d="m22 7-8.5 8.5-5-5L2 17"/>`
            var arrow = Path()
            arrow.move(to: CGPoint(x: 16, y: 7))
            arrow.addLine(to: CGPoint(x: 22, y: 7))
            arrow.addLine(to: CGPoint(x: 22, y: 13))

            var line = Path()
            line.move(to: CGPoint(x: 22, y: 7))
            line.addLine(to: CGPoint(x: 13.5, y: 15.5))
            line.addLine(to: CGPoint(x: 8.5, y: 10.5))
            line.addLine(to: CGPoint(x: 2, y: 17))
            return [
                LucideSegment(path: arrow, style: .stroke),
                LucideSegment(path: line, style: .stroke)
            ]

        case .chartPie:
            // `<path d="M21 12c.552 0 1.005-.449.95-.998a10 10 0 0 0-8.953-8.951c-.55-.055-.998.398-.998.95v8a1 1 0 0 0 1 1z"/>`
            // `<path d="M21.21 15.89A10 10 0 1 1 8 2.83"/>`
            var wedge = Path()
            wedge.move(to: CGPoint(x: 21, y: 12))
            // c .552 0 1.005 -.449 .95 -.998
            wedge.addCurve(
                to: CGPoint(x: 21.95, y: 11.002),
                control1: CGPoint(x: 21.552, y: 12),
                control2: CGPoint(x: 22.005, y: 11.551)
            )
            // a 10 10 0 0 0 -8.953 -8.951 → (12.997, 2.051)
            wedge.addArc(tangent1End: CGPoint(x: 21.95, y: 2.051), tangent2End: CGPoint(x: 12.997, y: 2.051), radius: 10)
            // c -.55 -.055 -.998 .398 -.998 .95
            wedge.addCurve(
                to: CGPoint(x: 11.999, y: 3.001),
                control1: CGPoint(x: 12.447, y: 1.996),
                control2: CGPoint(x: 11.999, y: 2.449)
            )
            wedge.addLine(to: CGPoint(x: 11.999, y: 11.001))
            wedge.addArc(tangent1End: CGPoint(x: 11.999, y: 12.001), tangent2End: CGPoint(x: 12.999, y: 12.001), radius: 1)
            wedge.closeSubpath()

            var arc = Path()
            arc.move(to: CGPoint(x: 21.21, y: 15.89))
            // a 10 10 0 1 1 -13.21 -13.06 → big-arc back to (8, 2.83)
            arc.addArc(tangent1End: CGPoint(x: 21.21, y: 25.89), tangent2End: CGPoint(x: 11.21, y: 25.89), radius: 10)
            arc.addArc(tangent1End: CGPoint(x: 1.21, y: 25.89),  tangent2End: CGPoint(x: 1.21, y: 15.89), radius: 10)
            arc.addArc(tangent1End: CGPoint(x: 1.21, y: 5.89),   tangent2End: CGPoint(x: 8, y: 2.83), radius: 10)
            return [
                LucideSegment(path: wedge, style: .stroke),
                LucideSegment(path: arc, style: .stroke)
            ]

        case .chartCandlestick:
            // 4 verticals + 2 rects + axis
            // `<path d="M9 5v4"/>` `<rect width="4" height="6" x="7" y="9" rx="1"/>` `<path d="M9 15v2"/>`
            // `<path d="M17 3v2"/>` `<rect width="4" height="8" x="15" y="5" rx="1"/>` `<path d="M17 13v3"/>`
            // `<path d="M3 3v16a2 2 0 0 0 2 2h16"/>`
            var v1Top = Path()
            v1Top.move(to: CGPoint(x: 9, y: 5)); v1Top.addLine(to: CGPoint(x: 9, y: 9))
            var v1Bot = Path()
            v1Bot.move(to: CGPoint(x: 9, y: 15)); v1Bot.addLine(to: CGPoint(x: 9, y: 17))
            var v2Top = Path()
            v2Top.move(to: CGPoint(x: 17, y: 3)); v2Top.addLine(to: CGPoint(x: 17, y: 5))
            var v2Bot = Path()
            v2Bot.move(to: CGPoint(x: 17, y: 13)); v2Bot.addLine(to: CGPoint(x: 17, y: 16))

            var r1 = Path()
            r1.addRoundedRect(in: CGRect(x: 7, y: 9, width: 4, height: 6), cornerSize: CGSize(width: 1, height: 1))
            var r2 = Path()
            r2.addRoundedRect(in: CGRect(x: 15, y: 5, width: 4, height: 8), cornerSize: CGSize(width: 1, height: 1))

            var axis = Path()
            axis.move(to: CGPoint(x: 3, y: 3))
            axis.addLine(to: CGPoint(x: 3, y: 19))
            axis.addArc(tangent1End: CGPoint(x: 3, y: 21), tangent2End: CGPoint(x: 5, y: 21), radius: 2)
            axis.addLine(to: CGPoint(x: 21, y: 21))
            return [
                LucideSegment(path: v1Top, style: .stroke),
                LucideSegment(path: r1, style: .stroke),
                LucideSegment(path: v1Bot, style: .stroke),
                LucideSegment(path: v2Top, style: .stroke),
                LucideSegment(path: r2, style: .stroke),
                LucideSegment(path: v2Bot, style: .stroke),
                LucideSegment(path: axis, style: .stroke)
            ]

        case .rocket:
            // `<path d="M12 15v5s3.03-.55 4-2c1.08-1.62 0-5 0-5"/>`
            // `<path d="M4.5 16.5c-1.5 1.26-2 5-2 5s3.74-.5 5-2c.71-.84.7-2.13-.09-2.91a2.18 2.18 0 0 0-2.91-.09"/>`
            // `<path d="M9 12a22 22 0 0 1 2-3.95A12.88 12.88 0 0 1 22 2c0 2.72-.78 7.5-6 11a22.4 22.4 0 0 1-4 2z"/>`
            // `<path d="M9 12H4s.55-3.03 2-4c1.62-1.08 5 .05 5 .05"/>`
            var flame1 = Path()
            flame1.move(to: CGPoint(x: 12, y: 15))
            flame1.addLine(to: CGPoint(x: 12, y: 20))
            flame1.addCurve(
                to: CGPoint(x: 16, y: 18),
                control1: CGPoint(x: 15.03, y: 19.45),
                control2: CGPoint(x: 16, y: 18)
            )
            flame1.addCurve(
                to: CGPoint(x: 16, y: 13),
                control1: CGPoint(x: 17.08, y: 16.38),
                control2: CGPoint(x: 16, y: 13)
            )

            var flame2 = Path()
            flame2.move(to: CGPoint(x: 4.5, y: 16.5))
            flame2.addCurve(
                to: CGPoint(x: 2.5, y: 21.5),
                control1: CGPoint(x: 3, y: 17.76),
                control2: CGPoint(x: 2.5, y: 21.5)
            )
            flame2.addCurve(
                to: CGPoint(x: 7.5, y: 19.5),
                control1: CGPoint(x: 2.5, y: 21.5),
                control2: CGPoint(x: 6.24, y: 21)
            )
            flame2.addCurve(
                to: CGPoint(x: 7.41, y: 16.59),
                control1: CGPoint(x: 8.21, y: 18.66),
                control2: CGPoint(x: 8.20, y: 17.37)
            )
            flame2.addArc(tangent1End: CGPoint(x: 6.32, y: 15.5), tangent2End: CGPoint(x: 4.5, y: 16.5), radius: 2.18)

            var body = Path()
            body.move(to: CGPoint(x: 9, y: 12))
            // a 22 22 0 0 1 2 -3.95
            body.addArc(tangent1End: CGPoint(x: 9.5, y: 9), tangent2End: CGPoint(x: 11, y: 8.05), radius: 22)
            // A 12.88 12.88 0 0 1 22 2
            body.addArc(tangent1End: CGPoint(x: 14, y: 2), tangent2End: CGPoint(x: 22, y: 2), radius: 12.88)
            // c 0 2.72 -.78 7.5 -6 11
            body.addCurve(
                to: CGPoint(x: 16, y: 13),
                control1: CGPoint(x: 22, y: 4.72),
                control2: CGPoint(x: 21.22, y: 9.5)
            )
            // a 22.4 22.4 0 0 1 -4 2
            body.addArc(tangent1End: CGPoint(x: 14.5, y: 14.5), tangent2End: CGPoint(x: 12, y: 15), radius: 22.4)
            body.closeSubpath()

            var fin = Path()
            fin.move(to: CGPoint(x: 9, y: 12))
            fin.addLine(to: CGPoint(x: 4, y: 12))
            fin.addCurve(
                to: CGPoint(x: 6, y: 8),
                control1: CGPoint(x: 4.55, y: 8.97),
                control2: CGPoint(x: 6, y: 8)
            )
            fin.addCurve(
                to: CGPoint(x: 11, y: 8.05),
                control1: CGPoint(x: 7.62, y: 6.92),
                control2: CGPoint(x: 11, y: 8.05)
            )

            return [
                LucideSegment(path: flame1, style: .stroke),
                LucideSegment(path: flame2, style: .stroke),
                LucideSegment(path: body, style: .stroke),
                LucideSegment(path: fin, style: .stroke)
            ]

        case .briefcase:
            // `<path d="M16 20V4a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v16"/>`
            // `<rect width="20" height="14" x="2" y="6" rx="2"/>`
            var handle = Path()
            handle.move(to: CGPoint(x: 16, y: 20))
            handle.addLine(to: CGPoint(x: 16, y: 4))
            handle.addArc(tangent1End: CGPoint(x: 16, y: 2), tangent2End: CGPoint(x: 14, y: 2), radius: 2)
            handle.addLine(to: CGPoint(x: 10, y: 2))
            handle.addArc(tangent1End: CGPoint(x: 8, y: 2), tangent2End: CGPoint(x: 8, y: 4), radius: 2)
            handle.addLine(to: CGPoint(x: 8, y: 20))

            var box = Path()
            box.addRoundedRect(in: CGRect(x: 2, y: 6, width: 20, height: 14), cornerSize: CGSize(width: 2, height: 2))
            return [
                LucideSegment(path: handle, style: .stroke),
                LucideSegment(path: box, style: .stroke)
            ]

        case .target:
            // 3 concentric circles
            var c1 = Path(); c1.addEllipse(in: CGRect(x: 2,  y: 2,  width: 20, height: 20))
            var c2 = Path(); c2.addEllipse(in: CGRect(x: 6,  y: 6,  width: 12, height: 12))
            var c3 = Path(); c3.addEllipse(in: CGRect(x: 10, y: 10, width: 4,  height: 4))
            return [
                LucideSegment(path: c1, style: .stroke),
                LucideSegment(path: c2, style: .stroke),
                LucideSegment(path: c3, style: .stroke)
            ]

        case .zap:
            // `<path d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z"/>`
            var p = Path()
            p.move(to: CGPoint(x: 4, y: 14))
            p.addArc(tangent1End: CGPoint(x: 3, y: 14), tangent2End: CGPoint(x: 3.22, y: 12.37), radius: 1)
            p.addLine(to: CGPoint(x: 13.12, y: 2.17))
            p.addArc(tangent1End: CGPoint(x: 13.55, y: 1.91), tangent2End: CGPoint(x: 13.98, y: 2.63), radius: 0.5)
            p.addLine(to: CGPoint(x: 12.06, y: 8.65))
            p.addArc(tangent1End: CGPoint(x: 12, y: 10), tangent2End: CGPoint(x: 13, y: 10), radius: 1)
            p.addLine(to: CGPoint(x: 20, y: 10))
            p.addArc(tangent1End: CGPoint(x: 21, y: 10), tangent2End: CGPoint(x: 20.78, y: 11.63), radius: 1)
            p.addLine(to: CGPoint(x: 10.88, y: 21.83))
            p.addArc(tangent1End: CGPoint(x: 10.45, y: 22.09), tangent2End: CGPoint(x: 10.02, y: 21.37), radius: 0.5)
            p.addLine(to: CGPoint(x: 11.94, y: 15.35))
            p.addArc(tangent1End: CGPoint(x: 12, y: 14), tangent2End: CGPoint(x: 11, y: 14), radius: 1)
            p.closeSubpath()
            return [LucideSegment(path: p, style: .stroke)]

        case .flame:
            // `<path d="M12 3q1 4 4 6.5t3 5.5a1 1 0 0 1-14 0 5 5 0 0 1 1-3 1 1 0 0 0 5 0c0-2-1.5-3-1.5-5q0-2 2.5-4"/>`
            var p = Path()
            p.move(to: CGPoint(x: 12, y: 3))
            // q 1 4 4 6.5  → quadratic with control (13, 7) and end (16, 9.5)
            p.addQuadCurve(to: CGPoint(x: 16, y: 9.5), control: CGPoint(x: 13, y: 7))
            // t 3 5.5 → smooth quad, mirror control across (16, 9.5) yielding (19, 15)
            // The "smooth" reflected control = previous + (current - previous), i.e. (19, 12)
            p.addQuadCurve(to: CGPoint(x: 19, y: 15), control: CGPoint(x: 19, y: 12))
            // a 1 1 0 0 1 -14 0 → arc r=1 from (19,15) to (5,15)
            p.addArc(tangent1End: CGPoint(x: 19, y: 22),  tangent2End: CGPoint(x: 12, y: 22), radius: 1)
            p.addArc(tangent1End: CGPoint(x: 5, y: 22),   tangent2End: CGPoint(x: 5, y: 15), radius: 1)
            // a 5 5 0 0 1 1 -3 → (6, 12)
            p.addArc(tangent1End: CGPoint(x: 5, y: 12),  tangent2End: CGPoint(x: 6, y: 12), radius: 5)
            // a 1 1 0 0 0 5 0 → (11, 12). The literal r=1 is smaller
            // than half the 5-unit chord, so per SVG arc semantics the
            // radius scales up to 2.5 — a downward semicircle (center
            // (8.5, 12), bottom (8.5, 14.5)). Decomposed as two
            // quarter-turn tangent arcs against the bounding-box
            // corners — the same semicircle decomposition `anchor` and
            // `globe` use. (The prior shape ended with a degenerate
            // identical-tangent addArc that collapsed to a line.)
            p.addArc(tangent1End: CGPoint(x: 6, y: 14.5),  tangent2End: CGPoint(x: 8.5, y: 14.5), radius: 2.5)
            p.addArc(tangent1End: CGPoint(x: 11, y: 14.5), tangent2End: CGPoint(x: 11, y: 12), radius: 2.5)
            // c 0 -2 -1.5 -3 -1.5 -5 → (9.5, 7)
            p.addCurve(
                to: CGPoint(x: 9.5, y: 7),
                control1: CGPoint(x: 11, y: 10),
                control2: CGPoint(x: 9.5, y: 9)
            )
            // q 0 -2 2.5 -4 → control (9.5, 5) end (12, 3)
            p.addQuadCurve(to: CGPoint(x: 12, y: 3), control: CGPoint(x: 9.5, y: 5))
            return [LucideSegment(path: p, style: .stroke)]

        case .sparkles:
            // `<path d="M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z"/>`
            // `<path d="M20 2v4"/>`  `<path d="M22 4h-4"/>`
            // `<circle cx="4" cy="20" r="2"/>`
            // The four concave valley arcs (`a2 2 0 0 0 …`) are
            // rendered as quadratic curves: an `addArc(tangent1End:
            // tangent2End:)` call with IDENTICAL tangent points is
            // degenerate (the second tangent line has zero length) and
            // CoreGraphics collapses it to a straight line — sharp
            // corners instead of the Lucide rounding. The quad control
            // is the corner point where the adjoining edge lines
            // intersect (computed from the neighboring path
            // coordinates), so each curve leaves the incoming edge and
            // meets the outgoing edge tangentially — the proper
            // rounded valley.
            var star = Path()
            star.move(to: CGPoint(x: 11.017, y: 2.814))
            star.addArc(tangent1End: CGPoint(x: 12, y: 1.814), tangent2End: CGPoint(x: 12.983, y: 2.814), radius: 1)
            star.addLine(to: CGPoint(x: 14.034, y: 8.372))
            star.addQuadCurve(to: CGPoint(x: 15.628, y: 9.966), control: CGPoint(x: 14.287, y: 9.713))
            star.addLine(to: CGPoint(x: 21.186, y: 11.017))
            star.addArc(tangent1End: CGPoint(x: 22.186, y: 12), tangent2End: CGPoint(x: 21.186, y: 12.983), radius: 1)
            star.addLine(to: CGPoint(x: 15.628, y: 14.034))
            star.addQuadCurve(to: CGPoint(x: 14.034, y: 15.628), control: CGPoint(x: 14.287, y: 14.287))
            star.addLine(to: CGPoint(x: 12.983, y: 21.186))
            star.addArc(tangent1End: CGPoint(x: 12, y: 22.186), tangent2End: CGPoint(x: 11.017, y: 21.186), radius: 1)
            star.addLine(to: CGPoint(x: 9.966, y: 15.628))
            star.addQuadCurve(to: CGPoint(x: 8.372, y: 14.034), control: CGPoint(x: 9.713, y: 14.287))
            star.addLine(to: CGPoint(x: 2.814, y: 12.983))
            star.addArc(tangent1End: CGPoint(x: 1.814, y: 12), tangent2End: CGPoint(x: 2.814, y: 11.017), radius: 1)
            star.addLine(to: CGPoint(x: 8.372, y: 9.966))
            star.addQuadCurve(to: CGPoint(x: 9.966, y: 8.372), control: CGPoint(x: 9.713, y: 9.713))
            star.closeSubpath()

            var vTick = Path()
            vTick.move(to: CGPoint(x: 20, y: 2)); vTick.addLine(to: CGPoint(x: 20, y: 6))
            var hTick = Path()
            hTick.move(to: CGPoint(x: 22, y: 4)); hTick.addLine(to: CGPoint(x: 18, y: 4))
            var corner = Path()
            corner.addEllipse(in: CGRect(x: 2, y: 18, width: 4, height: 4))

            return [
                LucideSegment(path: star, style: .stroke),
                LucideSegment(path: vTick, style: .stroke),
                LucideSegment(path: hTick, style: .stroke),
                LucideSegment(path: corner, style: .stroke)
            ]

        case .star:
            // `<path d="M11.525 2.295a.53.53 0 0 1 .95 0l2.31 4.679a2.123 2.123 0 0 0 1.595 1.16l5.166.756a.53.53 0 0 1 .294.904l-3.736 3.638a2.123 2.123 0 0 0-.611 1.878l.882 5.14a.53.53 0 0 1-.771.56l-4.618-2.428a2.122 2.122 0 0 0-1.973 0L6.396 21.01a.53.53 0 0 1-.77-.56l.881-5.139a2.122 2.122 0 0 0-.611-1.879L2.16 9.795a.53.53 0 0 1 .294-.906l5.165-.755a2.122 2.122 0 0 0 1.597-1.16z"/>`
            // The four `a2.12x …` shoulder arcs between point-tip and
            // valley are rendered as quadratic curves — the previous
            // `addArc(tangent1End:tangent2End:)` calls used IDENTICAL
            // tangent points, which is degenerate geometry that
            // CoreGraphics collapses to straight lines. Each quad
            // control is the intersection of the adjoining edge lines
            // (derived from the neighboring path coordinates), so the
            // curve stays tangent to both edges — the Lucide star's
            // soft shoulders, no degenerate calls.
            var p = Path()
            p.move(to: CGPoint(x: 11.525, y: 2.295))
            p.addArc(tangent1End: CGPoint(x: 12, y: 2.025), tangent2End: CGPoint(x: 12.475, y: 2.295), radius: 0.53)
            p.addLine(to: CGPoint(x: 14.785, y: 6.974))
            p.addQuadCurve(to: CGPoint(x: 16.38, y: 8.134), control: CGPoint(x: 15.278, y: 7.973))
            p.addLine(to: CGPoint(x: 21.546, y: 8.890))
            p.addArc(tangent1End: CGPoint(x: 22.135, y: 9.142), tangent2End: CGPoint(x: 21.840, y: 9.794), radius: 0.53)
            p.addLine(to: CGPoint(x: 18.104, y: 13.432))
            p.addQuadCurve(to: CGPoint(x: 17.493, y: 15.310), control: CGPoint(x: 17.304, y: 14.211))
            p.addLine(to: CGPoint(x: 18.375, y: 20.450))
            p.addArc(tangent1End: CGPoint(x: 18.110, y: 21.005), tangent2End: CGPoint(x: 17.604, y: 21.010), radius: 0.53)
            p.addLine(to: CGPoint(x: 12.986, y: 18.582))
            p.addArc(tangent1End: CGPoint(x: 12, y: 18.367), tangent2End: CGPoint(x: 11.013, y: 18.582), radius: 2.122)
            p.addLine(to: CGPoint(x: 6.396, y: 21.010))
            p.addArc(tangent1End: CGPoint(x: 5.890, y: 21.005), tangent2End: CGPoint(x: 5.625, y: 20.450), radius: 0.53)
            p.addLine(to: CGPoint(x: 6.506, y: 15.311))
            p.addQuadCurve(to: CGPoint(x: 5.895, y: 13.432), control: CGPoint(x: 6.696, y: 14.211))
            p.addLine(to: CGPoint(x: 2.16, y: 9.795))
            p.addArc(tangent1End: CGPoint(x: 1.865, y: 9.144), tangent2End: CGPoint(x: 2.454, y: 8.889), radius: 0.53)
            p.addLine(to: CGPoint(x: 7.619, y: 8.134))
            p.addQuadCurve(to: CGPoint(x: 9.216, y: 6.974), control: CGPoint(x: 8.722, y: 7.973))
            p.closeSubpath()
            return [LucideSegment(path: p, style: .stroke)]

        case .globe:
            // `<circle cx="12" cy="12" r="10"/>`
            // `<path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/>`
            // `<path d="M2 12h20"/>`
            var sphere = Path()
            sphere.addEllipse(in: CGRect(x: 2, y: 2, width: 20, height: 20))

            var meridian = Path()
            meridian.move(to: CGPoint(x: 12, y: 2))
            // a 14.5 14.5 0 0 0 0 20 → semicircle bowing left
            meridian.addArc(tangent1End: CGPoint(x: -2.5, y: 2), tangent2End: CGPoint(x: -2.5, y: 12), radius: 14.5)
            meridian.addArc(tangent1End: CGPoint(x: -2.5, y: 22), tangent2End: CGPoint(x: 12, y: 22), radius: 14.5)
            // a 14.5 14.5 0 0 0 0 -20 → bow right back to start
            meridian.addArc(tangent1End: CGPoint(x: 26.5, y: 22), tangent2End: CGPoint(x: 26.5, y: 12), radius: 14.5)
            meridian.addArc(tangent1End: CGPoint(x: 26.5, y: 2), tangent2End: CGPoint(x: 12, y: 2), radius: 14.5)

            var equator = Path()
            equator.move(to: CGPoint(x: 2, y: 12))
            equator.addLine(to: CGPoint(x: 22, y: 12))

            return [
                LucideSegment(path: sphere, style: .stroke),
                LucideSegment(path: meridian, style: .stroke),
                LucideSegment(path: equator, style: .stroke)
            ]

        case .anchor:
            // `<path d="M12 6v16"/>`
            // `<path d="m19 13 2-1a9 9 0 0 1-18 0l2 1"/>`
            // `<path d="M9 11h6"/>`
            // `<circle cx="12" cy="4" r="2"/>`
            var shaft = Path()
            shaft.move(to: CGPoint(x: 12, y: 6))
            shaft.addLine(to: CGPoint(x: 12, y: 22))

            var crown = Path()
            crown.move(to: CGPoint(x: 19, y: 13))
            crown.addLine(to: CGPoint(x: 21, y: 12))
            // a 9 9 0 0 1 -18 0 → semicircle r=9 from (21,12) to (3,12)
            crown.addArc(tangent1End: CGPoint(x: 21, y: 21), tangent2End: CGPoint(x: 12, y: 21), radius: 9)
            crown.addArc(tangent1End: CGPoint(x: 3, y: 21),  tangent2End: CGPoint(x: 3, y: 12), radius: 9)
            crown.addLine(to: CGPoint(x: 5, y: 13))

            var bar = Path()
            bar.move(to: CGPoint(x: 9, y: 11))
            bar.addLine(to: CGPoint(x: 15, y: 11))

            var ring = Path()
            ring.addEllipse(in: CGRect(x: 10, y: 2, width: 4, height: 4))

            return [
                LucideSegment(path: shaft, style: .stroke),
                LucideSegment(path: crown, style: .stroke),
                LucideSegment(path: bar, style: .stroke),
                LucideSegment(path: ring, style: .stroke)
            ]

        case .infinity:
            // `<path d="M6 16c5 0 7-8 12-8a4 4 0 0 1 0 8c-5 0-7-8-12-8a4 4 0 1 0 0 8"/>`
            var p = Path()
            p.move(to: CGPoint(x: 6, y: 16))
            p.addCurve(
                to: CGPoint(x: 18, y: 8),
                control1: CGPoint(x: 11, y: 16),
                control2: CGPoint(x: 13, y: 8)
            )
            p.addArc(tangent1End: CGPoint(x: 22, y: 8), tangent2End: CGPoint(x: 22, y: 12), radius: 4)
            p.addArc(tangent1End: CGPoint(x: 22, y: 16), tangent2End: CGPoint(x: 18, y: 16), radius: 4)
            p.addCurve(
                to: CGPoint(x: 6, y: 8),
                control1: CGPoint(x: 13, y: 16),
                control2: CGPoint(x: 11, y: 8)
            )
            p.addArc(tangent1End: CGPoint(x: 2, y: 8), tangent2End: CGPoint(x: 2, y: 12), radius: 4)
            p.addArc(tangent1End: CGPoint(x: 2, y: 16), tangent2End: CGPoint(x: 6, y: 16), radius: 4)
            return [LucideSegment(path: p, style: .stroke)]
        }
    }
}
