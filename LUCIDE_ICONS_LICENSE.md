# Lucide Icons — License Attribution

Aperture's wallet-avatar glyph set (30 of the 31 cases in
`UniApp/Sources/Features/Wallet/Avatar/WalletAvatarGlyph.swift`) is ported
verbatim from the **Lucide** icon library — `lucide.dev` — per the
2026-06-09 wallet-avatar design handoff at
`/Users/thuglifex/Downloads/design_handoff_wallet_avatars/`. The icons
are reproduced unmodified (24×24 viewBox, `currentColor` stroke); the
SwiftUI port carries the same path commands as the upstream SVG, scaled
into the 100-unit avatar viewBox via `translate(28, 28) scale(1.833)`
per the handoff's reference engine.

The 31st case — the **iris** brand pinwheel — is Aperture's own mark
(ported from `aperture-icon.js` in the same handoff) and is NOT part of
Lucide.

Lucide is distributed under the **ISC license**, reproduced in full
below.

---

## ISC License

Copyright (c) 2024 Lucide Contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

---

## Source

- Upstream license: <https://github.com/lucide-icons/lucide/blob/main/LICENSE>
- Upstream project: <https://github.com/lucide-icons/lucide>
- Project home: <https://lucide.dev>

## Icons used

The following 30 Lucide icons are ported into
`WalletAvatarGlyph.swift`, in the order specified by `tokens.json`:

`wallet`, `wallet-minimal`, `piggy-bank`, `landmark`, `banknote`,
`coins`, `hand-coins`, `circle-dollar-sign`, `badge-dollar-sign`,
`bitcoin`, `gem`, `vault`, `shield`, `shield-check`, `key-round`,
`lock`, `credit-card`, `trending-up`, `chart-pie`, `chart-candlestick`,
`rocket`, `briefcase`, `target`, `zap`, `flame`, `sparkles`, `star`,
`globe`, `anchor`, `infinity`.

Each Swift enum case uses the camelCase form of the kebab-case Lucide
name (e.g. `wallet-minimal` → `walletMinimal`,
`circle-dollar-sign` → `circleDollarSign`).

## Aperture-side enforcement

Per [`CLAUDE.md`](./CLAUDE.md) Rule #7 §B priority 3, Lucide is one of
the named "established open-source icon sets" Aperture uses for
non-system iconography. This file is the per-asset provenance record
required by Rule #7 §D; a one-line summary also lives in
[`UniApp/Resources/Assets.xcassets/README.md`](./UniApp/Resources/Assets.xcassets/README.md).
