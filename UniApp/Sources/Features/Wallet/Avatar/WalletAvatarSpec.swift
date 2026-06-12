import Foundation

/// The model that describes one wallet's identity avatar. A `WalletAvatarSpec`
/// is a pure value — gradient key, symbol type, glyph or monogram, and an
/// optional type badge. Every wallet-identity surface (tab bar, toolbar
/// pill, switcher sheet, list rows, context menu, hero preview) reads
/// the same `WalletAvatarSpec` through the same `WalletAvatar` view, so
/// the user's chosen identity reads identically across the app.
///
/// **Why a struct and not the WalletRecord directly.** The persistence
/// layer holds the spec as five primitive columns (gradient key + symbol
/// type + glyph name + monogram + badge raw). At render time we
/// rehydrate those columns into a `WalletAvatarSpec` so every consumer
/// can pass one well-formed value to `WalletAvatar(spec:)` — never a
/// loose bag of optional strings. The hydration also handles the
/// pre-migration backfill: when the persisted gradient is empty AND
/// the persisted symbol type is empty, we compute the deterministic
/// `auto(name)` default in one place.
///
/// **Why Codable / Sendable / Hashable.** Codable for parity with the
/// design handoff's JSON storage shape (the iOS bundle ships the same
/// shape the web prototype consumes). Sendable so the spec can cross
/// actor boundaries (WalletRepository's @ModelActor writes it; SwiftUI
/// views read it). Hashable so `.id(spec)` invalidates a parent view's
/// child when the spec changes — useful for the picker's live preview.
///
/// **Why no rasterized image is stored.** Per the design-handoff
/// brief: "Store per wallet `{gradient, symbolType, glyph|monogram,
/// badge?}`. Render from this — do **not** store rasterized images."
/// The avatar is recomposed at every render from the persisted shape
/// keys; that's how a future palette tweak or glyph refinement
/// propagates without re-saving any per-wallet PNG.
struct WalletAvatarSpec: Hashable, Sendable, Codable {
    /// Background gradient key, one of `WalletAvatarGradient.allCases`.
    /// Persisted as the gradient's `rawValue` (e.g. `"graphite"`).
    let gradient: WalletAvatarGradient
    /// Whether the disc's center renders an iris/Lucide glyph, a 1–2
    /// letter monogram, or a user-uploaded sanitized SVG. Persisted as
    /// the enum's rawValue (`"glyph"`, `"mono"`, or `"custom"`).
    let symbolType: WalletAvatarSymbolType
    /// When `symbolType == .glyph`, this names which glyph to draw
    /// (one of `WalletAvatarGlyph.allCases`). When `symbolType == .mono`
    /// or `.custom` this is nil.
    let glyph: WalletAvatarGlyph?
    /// When `symbolType == .mono`, the 1–2 character monogram to draw.
    /// Per the design handoff: the renderer caps at 2 characters, uses
    /// 46pt for 1, 34pt for 2. When `symbolType == .glyph` or `.custom`
    /// this is nil.
    let monogram: String?
    /// When `symbolType == .custom`, the sanitized SVG text the user
    /// uploaded — the output of `SVGSanitizer.sanitize(_:)`. Used as
    /// the source of truth; the on-disc rendering goes through a
    /// `WKWebView` snapshot cache (see `WalletCustomSvgRenderer`).
    /// Nil for `.glyph` and `.mono`.
    let customSvg: String?
    /// When `symbolType == .custom`, how to tint the rendered SVG.
    /// `.white` applies a brightness-0-invert-1 filter so the SVG
    /// reads as a white silhouette on the gradient disc (the design
    /// handoff's default, matching the v3 brief). `.original` leaves
    /// colors intact for users who want to preserve their brand
    /// palette on the disc.
    let customTint: CustomTint?
    /// Optional type badge in the bottom-right corner. Per the design
    /// handoff hard rule #4: derived from `WalletRecord.kind`, NOT
    /// user-selectable. A `created` or `importedMnemonic` wallet
    /// shows no badge; a `watchOnly` wallet shows the eye; a
    /// `importedKey` wallet shows the chip; future shared / multisig
    /// wallets will show the people glyph.
    let badge: WalletAvatarBadge?

    // MARK: - Symbol type

    /// Whether the avatar renders an iris/Lucide glyph, a monogram, or
    /// a user-uploaded sanitized SVG.
    enum WalletAvatarSymbolType: String, Hashable, Sendable, Codable {
        case glyph
        case mono
        case custom
    }

    // MARK: - Custom tint
    //
    // The Upload tab's tint sub-toggle. Mirrors the v3 brief's
    // `customTint='white'|'original'` field. Stored on the spec so
    // the renderer can pick the right filter without re-reading the
    // wallet record.

    enum CustomTint: String, Hashable, Sendable, Codable {
        /// Apply a `brightness(0) invert(1)` CSS filter so the SVG
        /// renders as a clean white silhouette on the gradient. The
        /// default and matches the JS reference engine.
        case white
        /// Keep the source SVG's original colors. Useful for users
        /// whose brand mark IS the identity (the color carries
        /// meaning, not the silhouette).
        case original
    }

    /// Convenience initializer for `.glyph` / `.mono` specs — the two
    /// historical symbol types that predate the v3 Upload tab. Lets
    /// older call sites and `auto(name)` continue to construct specs
    /// without naming every field. `customSvg` and `customTint` are
    /// always nil.
    init(
        gradient: WalletAvatarGradient,
        symbolType: WalletAvatarSymbolType,
        glyph: WalletAvatarGlyph?,
        monogram: String?,
        badge: WalletAvatarBadge?
    ) {
        self.gradient = gradient
        self.symbolType = symbolType
        self.glyph = glyph
        self.monogram = monogram
        self.customSvg = nil
        self.customTint = nil
        self.badge = badge
    }

    /// Full initializer used by `hydrate(...)` and the Upload-tab
    /// commit path. Carries every field including the v3 custom-SVG
    /// pair.
    init(
        gradient: WalletAvatarGradient,
        symbolType: WalletAvatarSymbolType,
        glyph: WalletAvatarGlyph?,
        monogram: String?,
        customSvg: String?,
        customTint: CustomTint?,
        badge: WalletAvatarBadge?
    ) {
        self.gradient = gradient
        self.symbolType = symbolType
        self.glyph = glyph
        self.monogram = monogram
        self.customSvg = customSvg
        self.customTint = customTint
        self.badge = badge
    }

    // MARK: - Hydration from primitive columns

    /// Build a spec from the SwiftData-persisted primitive columns plus
    /// the wallet's name (used for the auto(name) fallback if the
    /// persisted columns are empty — fresh-install / pre-migration row)
    /// and kind (used to derive the type badge).
    ///
    /// **Empty-column fallback path.** A pre-migration wallet row has
    /// every avatar column at its empty default (the schema defaults
    /// to empty strings on additive columns at decode-time even though
    /// the Swift-level `init` has named defaults — `M-008` documents
    /// the underlying SwiftData decode-vs-init asymmetry). When ALL
    /// avatar columns are empty we compute `auto(name)` to land a
    /// deterministic, on-brand identity — the design handoff's hard
    /// rule #3: *"New wallets default via deterministic auto(name)
    /// (never blank)."* The same fallback applies to a fresh-install
    /// row whose creator forgot to plumb the avatar fields.
    static func hydrate(
        gradient gradientRaw: String,
        symbolType symbolTypeRaw: String,
        glyph glyphRaw: String?,
        monogram monogramRaw: String?,
        customSvg customSvgRaw: String?,
        customTint customTintRaw: String?,
        badge badgeRaw: String?,
        walletName: String,
        walletKind: WalletKind
    ) -> WalletAvatarSpec {
        // `badgeRaw` is read intentionally — kept on the hydrate API
        // so a future "user-overridable badge" can drop into the
        // decoder without a call-site signature change. Today the
        // badge is derived from the wallet kind, per the hard rule.
        _ = badgeRaw

        // Decode the persisted columns. Each decode returns nil on an
        // unknown rawValue — defensive against a future palette /
        // glyph set rev that drops a key. The `auto(name)` fallback
        // covers a row whose gradient or symbol type came back nil.
        //
        // **Pre-v3 glyph-name retirement (2026-06-09).** The v3
        // wallet-avatar glyph set replaces the prior 20 geometric
        // marks with 30 Lucide icons. Some pre-v3 raw values (`dot`,
        // `ring`, `rings`, `dots`, `bars`, `hex`, `diamond`,
        // `triangle`, `square`, `bolt`, `heart`, `leaf`, `moon`,
        // `key`) are not in the v3 enum. `WalletAvatarGlyph(rawValue:)`
        // returns nil for those, and the no-resolvable-glyph branch
        // below falls back to a `.mono` avatar on the wallet's
        // initial. Never blank, never crashing. See
        // `WalletAvatarGlyph.swift` for the full retired list.
        let parsedGradient = WalletAvatarGradient(rawValue: gradientRaw)
        let parsedSymbolType = WalletAvatarSymbolType(rawValue: symbolTypeRaw)
        let parsedGlyph: WalletAvatarGlyph? = glyphRaw.flatMap { raw in
            raw.isEmpty ? nil : WalletAvatarGlyph(rawValue: raw)
        }
        let parsedMonogram: String? = monogramRaw.flatMap { raw in
            raw.isEmpty ? nil : raw
        }
        let parsedCustomSvg: String? = customSvgRaw.flatMap { raw in
            raw.isEmpty ? nil : raw
        }
        let parsedCustomTint: CustomTint = customTintRaw
            .flatMap { CustomTint(rawValue: $0) }
            ?? .white

        // Derive the type badge from the wallet's kind. Per the hard
        // rule, this is NEVER user-selectable.
        let derivedBadge = WalletAvatarBadge.derive(from: walletKind)

        // If the persisted gradient AND symbol type both resolve, we
        // have a real user-picked spec. Honor it.
        if let gradient = parsedGradient, let symbolType = parsedSymbolType {
            switch symbolType {
            case .glyph:
                // If the persisted glyph is nil (unknown rawValue,
                // including retired pre-v3 names), fall back to mono
                // on the wallet's initial — a defensive recovery that
                // preserves the user's chosen gradient even if the
                // glyph column got corrupted OR was a retired name.
                if let glyph = parsedGlyph {
                    return WalletAvatarSpec(
                        gradient: gradient,
                        symbolType: .glyph,
                        glyph: glyph,
                        monogram: nil,
                        customSvg: nil,
                        customTint: nil,
                        badge: derivedBadge
                    )
                } else {
                    return WalletAvatarSpec(
                        gradient: gradient,
                        symbolType: .mono,
                        glyph: nil,
                        monogram: monogramFromName(walletName),
                        customSvg: nil,
                        customTint: nil,
                        badge: derivedBadge
                    )
                }
            case .mono:
                return WalletAvatarSpec(
                    gradient: gradient,
                    symbolType: .mono,
                    glyph: nil,
                    monogram: parsedMonogram ?? monogramFromName(walletName),
                    customSvg: nil,
                    customTint: nil,
                    badge: derivedBadge
                )
            case .custom:
                // The Upload tab's persisted shape. We require a
                // non-empty sanitized SVG to honor `.custom` — without
                // it the renderer has nothing to draw and would fall
                // through to a blank disc. Mono-on-initial is the
                // safe recovery (same shape as the glyph branch when
                // the glyph column resolves to nil).
                if let svg = parsedCustomSvg {
                    return WalletAvatarSpec(
                        gradient: gradient,
                        symbolType: .custom,
                        glyph: nil,
                        monogram: nil,
                        customSvg: svg,
                        customTint: parsedCustomTint,
                        badge: derivedBadge
                    )
                } else {
                    return WalletAvatarSpec(
                        gradient: gradient,
                        symbolType: .mono,
                        glyph: nil,
                        monogram: monogramFromName(walletName),
                        customSvg: nil,
                        customTint: nil,
                        badge: derivedBadge
                    )
                }
            }
        }

        // Otherwise: empty / pre-migration row. Auto(name) gives us a
        // deterministic, on-brand identity from the wallet's name.
        let auto = WalletAvatarSpec.auto(name: walletName)
        return WalletAvatarSpec(
            gradient: auto.gradient,
            symbolType: auto.symbolType,
            glyph: auto.glyph,
            monogram: auto.monogram,
            customSvg: nil,
            customTint: nil,
            badge: derivedBadge
        )
    }

    // MARK: - Deterministic auto(name)

    /// The Gmail/GitHub-style deterministic default. Hash the wallet's
    /// name → pick a gradient (hash % 12), monogram = first character
    /// uppercased (or `"W"` if the name is empty). Per the design
    /// handoff:
    ///
    /// > "Must be deterministic (same name → same icon)."
    ///
    /// **Why the same hash function as the JS prototype.** The brief's
    /// `WALLETAV.auto(name)` uses a 31-multiplier integer accumulator
    /// over `name.charCodeAt(i)` with 32-bit unsigned overflow. We
    /// implement the same — UInt32 hash, same shape — so a wallet
    /// named "Spending" lands the same gradient color in the iOS app
    /// as it did in the web prototype the designer used to validate
    /// the system. Reproducibility across surfaces matters more than
    /// hash quality for a 12-bucket modulo.
    static func auto(name: String) -> WalletAvatarSpec {
        // 2026-06-09 — symbol changed from monogram to `.iris`. The
        // user direction: *"default icon for any new created wallet
        // for all users, same icon, but always different color"*.
        // The brand's iris pinwheel IS the identity; per-name gradient
        // gives a deterministic-but-varied color so a backfill on
        // pre-migration rows is stable (a wallet named "Spending" gets
        // the same gradient across devices and across re-runs). The
        // NEW-wallet creation paths use `randomDefault()` instead so
        // each new wallet's gradient is genuinely random.
        let h = deterministicHash(name.isEmpty ? "Wallet" : name)
        let gradient = WalletAvatarGradient.allCases[Int(h % UInt32(WalletAvatarGradient.allCases.count))]
        return WalletAvatarSpec(
            gradient: gradient,
            symbolType: .glyph,
            glyph: .iris,
            monogram: nil,
            badge: nil
        )
    }

    /// New-wallet default identity: iris glyph + a **randomly-picked**
    /// gradient. Called from `WalletAvatarDefaults.spec(forName:kind:)`
    /// (used by `WalletRecord.init` when no avatar fields are
    /// supplied), so every freshly-created wallet lands a different
    /// color from the 12 curated gradients — and the user direction
    /// of *"same icon, but always different color (Random color)"* is
    /// satisfied for create / import flows.
    ///
    /// **Why not call this from `auto(name:)`.** Several surfaces use
    /// `auto(name:)` as a fallback when the active wallet is briefly
    /// nil (cold-launch frame between SwiftData open and the first
    /// `@Query` snapshot). If those calls were random, the tab icon
    /// would flash a different color on every body recompute. Keeping
    /// `auto(name:)` deterministic and adding `randomDefault()`
    /// exclusively for the new-wallet write paths preserves stability
    /// on the read side and gives the genuine randomness the user
    /// asked for on the write side.
    static func randomDefault() -> WalletAvatarSpec {
        let gradient = WalletAvatarGradient.allCases.randomElement() ?? .graphite
        return WalletAvatarSpec(
            gradient: gradient,
            symbolType: .glyph,
            glyph: .iris,
            monogram: nil,
            badge: nil
        )
    }

    /// First character of the name, uppercased. Empty / whitespace
    /// names fall back to `"W"` so the avatar is never blank.
    private static func monogramFromName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "W" }
        return String(first).uppercased()
    }

    /// 31-multiplier accumulator hash with 32-bit unsigned overflow.
    /// Reproducibility matters more than avalanche / collision
    /// properties for a 12-bucket modulo.
    ///
    /// Folds the FULL 21-bit `Unicode.Scalar.value` (a `UInt32`) into
    /// the accumulator. An earlier cut masked with `& 0xFFFF` to mimic
    /// the JS prototype's `charCodeAt` — but that truncated every
    /// supplementary-plane scalar (emoji, rare CJK) to its low 16 bits,
    /// colliding distinct names like "💰" and "💸" onto the same
    /// bucket. For BMP text (ASCII, Latin, most scripts) `scalar.value`
    /// equals the UTF-16 code unit, so JS-prototype gradient parity is
    /// preserved for every realistic wallet name; only supplementary-
    /// plane names diverge — and those never matched JS anyway (JS
    /// iterates the surrogate PAIR; the masked scalar did not).
    ///
    /// `internal` (not private): `WalletAvatar`'s legacy
    /// symbol+colorHex bridge seeds the same hash so its gradient is
    /// stable across launches.
    static func deterministicHash(_ str: String) -> UInt32 {
        var h: UInt32 = 0
        for scalar in str.unicodeScalars {
            h = h &* 31 &+ scalar.value
        }
        return h
    }
}

