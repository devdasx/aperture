# Aperture — Bundled Asset Provenance

Per [`CLAUDE.md`](../../../CLAUDE.md) Rule #7, every iconographic or
illustrative asset that ships in Aperture must come from a real, designed
source — never composed from SwiftUI primitives. This file records the
source URL and license for every bundled image asset.

**Format:** `<asset-name> — <source URL> — <license>`

One line per asset. New assets MUST be added here in the same commit that
introduces them. If a license is unclear, the asset cannot ship.

---

## SF Symbols (not bundled — referenced via `Image(systemName:)`)

The onboarding sequence and most action iconography use **SF Symbols**,
which are Apple's official symbol library shipped with iOS. They are real
Apple designs; they live in the OS, not in this catalog. They are recorded
here so the provenance ledger is exhaustive.

- `sparkles` — Apple SF Symbols — Apple Symbols License
- `key.fill` — Apple SF Symbols — Apple Symbols License
- `faceid` — Apple SF Symbols — Apple Symbols License
- `list.number` — Apple SF Symbols — Apple Symbols License
- `arrow.down.to.line` — Apple SF Symbols — Apple Symbols License
- `paperplane.fill` — Apple SF Symbols — Apple Symbols License
- `arrow.left.arrow.right` — Apple SF Symbols — Apple Symbols License
- `eye.slash.fill` — Apple SF Symbols — Apple Symbols License
- `arrow.right.circle.fill` — Apple SF Symbols — Apple Symbols License

---

## Crypto/ — official chain & token marks (Trust Wallet, MIT)

All marks are pulled from `github.com/trustwallet/assets` (MIT) — the
canonical brand-asset repository for self-custody wallet apps. Native-coin
logos are addressed at `blockchains/<chain>/info/logo.png`; on-chain token
logos at `blockchains/<chain>/assets/<contract>/logo.png`. See
[`MISTAKES.md`](../../../MISTAKES.md) `M-001` for the history of why this
is now the project's default crypto-icon source (replacing
`spothq/cryptocurrency-icons`, which is now a fallback only).

Each asset lives in its own `.imageset` with the source PNG bound to the
`@3x` slot so iOS uses native resolution at @3x and downsamples cleanly
for @2x / @1x. Multi-color brand marks render as authored — no
`.renderingMode(.template)`.

### Native-chain marks (12)

- btc — https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/bitcoin/info/logo.png — MIT
- eth — https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/info/logo.png — MIT
- sol — https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/solana/info/logo.png — MIT
- xrp — https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ripple/info/logo.png — MIT
- bnb — https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/binance/info/logo.png — MIT
- avax — https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/avalanchec/info/logo.png — MIT
- trx — https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/tron/info/logo.png — MIT
- pol — https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/polygon/info/logo.png — MIT
- dot — https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/polkadot/info/logo.png — MIT
- near — https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/near/info/logo.png — MIT
- ton — https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ton/info/logo.png — MIT
- apt — https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/aptos/info/logo.png — MIT

### Stablecoin marks (Ethereum-bound)

- usdc — https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48/logo.png — MIT
- usdt — https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/0xdAC17F958D2ee523a2206206994597C13D831ec7/logo.png — MIT

### Slug notes (for future additions)

Trust Wallet's chain slug is not always the lowercase ticker:

- XRP → `ripple`
- AVAX (C-chain) → `avalanchec`
- BNB Beacon Chain → `binance` (BNB Smart Chain is `smartchain`)
- POL/MATIC → `polygon` (the chain; the token rebranded MATIC → POL)
- DOT → `polkadot`

When a chain is needed that isn't present in Trust Wallet's repo, fall
back to the token's official brand-assets page (priority 2 in Rule #7
Part B) before resorting to `spothq/cryptocurrency-icons`.

---

## AppIcon.appiconset/ — application icon (iOS 18+ light/dark/tinted variants)

The home-screen icon ships as three 1024×1024 PNG variants, all provided by
the app owner. The aperture/iris diaphragm mark — the literal visual rendering
of the product name "Aperture" — sits on a rounded-rect background in each
variant. iOS picks the variant based on the user's Home Screen appearance.
Refined geometry, matching the canonical `animated-logo.html` spec, sourced
from the owner's `logo 2/` package (2026-06-04):

- `icon-light.png` — ceramic light icon for light home screens, from `logo 2/light-mode/png/1024/icon.png` — Proprietary, provided by app owner
- `icon-dark.png` — space-gray icon for dark home screens, from `logo 2/dark-mode/png/1024/icon.png` — Proprietary, provided by app owner
- `icon-tinted.png` — marine `#0A84FF` icon source iOS retints, from `logo 2/accent/png/1024/icon.png` — Proprietary, provided by app owner

## AppIcon.appiconset — full app icon tiles

Replaced 2026-06-07 with the new "Aperture — Brand Identity Kit" — solid
six-blade "Iris Solid" mark filling ~60% of a 1024px superellipse tile.

- `icon-light.png` — Aperture Blue gradient tile, white iris (1024×1024).
  Source: brand kit `png/light/icon-1024.png` (provided by app owner).
- `icon-dark.png` — near-black (Ink) tile, white iris (1024×1024). Source:
  brand kit `png/dark/icon-1024.png` (provided by app owner).
- `icon-tinted.png` — monochrome glyph for iOS tinted-home-screen mode
  (1024×1024). Source: brand kit `png/tinted/icon-1024.png` (provided by
  app owner).

License: Proprietary — provided by app owner.

## Splash/ — launch-screen colorsets (2026-06-07 design handoff)

Splash-only colorsets per `/Users/thuglifex/Downloads/design_handoff_splash_screen/README.md`.
The launch screen is a monochrome brand surface with a radial-gradient
lift at center-upper; these roles are not used anywhere else in the app.
Surfaced via `UniColors.Splash.*` for token-only access at the call
site (Rule #4).

- `SplashLift` — radial gradient inner stop (`#FFFFFF` light / `#1A1C21`
  dark).
- `SplashBase` — radial gradient outer stop (`#EEF0F4` light /
  `#000000` dark).
- `SplashMark` — iris + wordmark tint (`#0B0D11` Ink light / `#FFFFFF`
  Cloud dark).
- `SplashGlow` — halo behind the mark (ink @ 8% light / white @ 14%
  dark).
- `SplashLoaderTrack` — track of the determinate loader (ink @ 10%
  light / white @ 16% dark).
- `SplashTagline` — tagline copy color (ink @ 50% light / white @ 50%
  dark).

Source: design handoff spec verbatim. License: Proprietary — provided
by app owner.

## Brand/ — flat brand mark (template SVGs)

The flat six-blade "Iris Solid" mark, without a tile, in three brand
colorways. Used by `ApertureIrisView` and any future surface that needs
the mark on a transparent background.

- `Mark/mark-black.svg` — Ink black mark (rendered against light
  backgrounds via `.luminosity` light variant).
- `Mark/mark-white.svg` — Cloud white mark (rendered against dark
  backgrounds via `.luminosity` dark variant).
Source: brand kit `svg/mark-{black,white}.svg`. License: Proprietary
— provided by app owner. (The blue mark variant was removed in brand
kit v2; the brand color is monochrome black/white per the design
handoff.)

## Wordmark/ — brand wordmark (template SVGs)

Replaced 2026-06-07 with the new horizontal wordmark (mark + "Aperture"
typesetting).

- `mark-aperture/wordmark-horizontal-light.svg` — light-mode variant (Ink
  mark + Ink text on transparent background).
- `mark-aperture/wordmark-horizontal-dark.svg` — dark-mode variant (Cloud
  mark + Cloud text on transparent background).

Source: brand kit `svg/wordmark-horizontal-{light,dark}.svg`. License:
Proprietary — provided by app owner.

## Onboarding/ — slide-specific glyphs (none yet bundled)

Currently empty. All ten onboarding slide visuals resolve to SF Symbols
(see top of this file) or to coin marks from `Crypto/` above. If a future
slide needs a glyph that SF Symbols does not cover, source from Lucide
(ISC), Phosphor (MIT), Heroicons (MIT), Tabler (MIT), or Iconoir (MIT)
and add the asset + provenance line here.
