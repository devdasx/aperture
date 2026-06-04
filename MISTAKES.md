# UniApp — Mistakes Log

> Append-only learning register. Every avoidable mistake the agent makes lives
> here so it is never repeated. See [`CLAUDE.md`](./CLAUDE.md) Rule #8 for the
> workflow. Read this file **before** any task that touches a domain a prior
> mistake covers — sourcing assets, choosing libraries, naming, layout
> patterns, etc.

---

## Legend

- **Severity:** `LOW` (small inefficiency, easy to fix) · `MEDIUM` (user
  noticed and corrected) · `HIGH` (caused rework, lost trust, or shipped
  something we then had to remove).
- **Status:** `OPEN` (mistake recorded, fix not yet applied) ·
  `CORRECTED` (fix shipped) · `RECURRENCE-PREVENTED` (a follow-up was
  proposed *before* re-doing the same thing — the rule worked).
- **Domain:** the area future tasks might re-touch (e.g., `assets`,
  `licensing`, `routing`, `colors`, `concurrency`).

---

## M-002 · Close-X toolbar button shipped with a gray pill/circle background, repeating a fix already made earlier in the same session

- **Date:** 2026-06-04
- **Severity:** MEDIUM
- **Status:** CORRECTED — see SHIPPED entry titled "Bare toolbar SF Symbols + real BIP-39 seed derivation + clipboard + screenshot warning" (this session).
- **Domain:** `ios-26-toolbar-conventions`, `liquid-glass`, `iconography`

### What I did
On the **`RecoveryPhraseView`** (create-wallet flow), the toolbar's leading close button was implemented with `.buttonStyle(.glass)` — which on iOS 26 produces a **gray pill / circle background** behind the `xmark` symbol. Earlier in the **same session**, the orchestrator had explicitly directed that the X close button should be a **bare** `Image(systemName: "xmark")` with **no background** — and that fix was applied to other surfaces. The create-wallet flow shipped without inheriting that convention.

### Why it was wrong
1. **Repeat of an already-fixed problem.** Per Rule #8 §G, scanning `MISTAKES.md` (and the recent `SHIPPED.md` entries) before shipping new toolbar work should have caught this. The "X bare, not pilled" rule was a live conventions in the codebase.
2. **iOS 26 native pattern.** Apple's iOS 26 toolbars render close buttons as bare SF Symbols inheriting the navigation-bar tint. The system handles tap targets, hit-test bleed, and accessibility. A `.buttonStyle(.glass)` overlay duplicates and visually competes with the system chrome — it adds nothing and breaks the native feel.

### Root cause
**Defaulting to `.buttonStyle(.glass)` for any toolbar button** under the (flawed) reasoning that "functional chrome should be Liquid Glass." For full-width / floating CTAs (like the onboarding "Create new wallet"), `.buttonStyle(.glass)` / `.glassProminent` is correct. **For toolbar items (close button, options menu, back chevron), it is wrong** — those surfaces are *inside* the nav bar, which already carries the system Liquid Glass treatment. Adding another glass background creates a double-chrome look (the gray pill you can see in the user's screenshot).

### Lesson learned
**iOS 26 toolbar items are bare SF Symbols.** The system nav bar IS the Liquid Glass surface. Toolbar buttons should be `Image(systemName: "…")` with a tint, never wrapped in `.buttonStyle(.glass)` or `.glassProminent`. The pattern is the same as iOS Settings, Mail, Messages — bare glyphs inheriting the bar tint.

### Prevention (concrete)
- When writing a `.toolbar { … }` block: never apply `.buttonStyle(.glass)` to a `ToolbarItem` button's label. The button gets a bare `Image(systemName: …)` and an `.accessibilityLabel(…)`.
- Use SF Symbol names **without** the `.circle` / `.circle.fill` / `.fill.circle` suffix for toolbar glyphs. `xmark`, not `xmark.circle.fill`. `ellipsis`, not `ellipsis.circle`.
- For tint, inherit from the navigation bar (no explicit `.foregroundStyle` needed in most cases). If you must override, use `UniColors.Icon.secondary` or `UniColors.Text.primary`, never `.buttonStyle(.glass)`.

### Detection (for future readers)
If a future task involves "add a button to a `.toolbar { ToolbarItem(…) }` block" — **stop and re-read this entry**. The default `Button { … } label: { Image(systemName: "x") }` with no further style is the right pattern. If you reach for `.buttonStyle(.glass)` on a toolbar item, you're about to repeat this mistake.

---

## M-003 · Options-menu icon shipped as `ellipsis.circle` (3 dots inside a circle) instead of bare `ellipsis` (3 dots, no chrome)

- **Date:** 2026-06-04
- **Severity:** LOW
- **Status:** CORRECTED — same SHIPPED entry as M-002.
- **Domain:** `ios-26-toolbar-conventions`, `iconography`

### What I did
On the `RecoveryPhraseView` toolbar, the overflow Menu was rendered with `Image(systemName: "ellipsis.circle")` — the 3-dots-in-a-circle variant. Combined with the (now-corrected) toolbar-button glass background from `M-002`, this produced a double-chrome look: gray circle (from the glass button background) + gray circle (from the `.circle` SF Symbol variant) stacked on top of each other.

### Why it was wrong
Same root as `M-002`: defaulting to "buttoned" SF Symbol variants (`.circle`, `.circle.fill`) when the iOS 26 toolbar convention is **bare glyphs**. Apple's own apps (Mail, Notes, Reminders, Photos) use bare `ellipsis` in toolbar overflow menus, not `ellipsis.circle`.

### Root cause
SF Symbols offers `.circle` variants because they're useful in some contexts (large-iconed CTAs inside content). I selected `.circle` reflexively as "the icon for an options button." The toolbar context has its own chrome and doesn't need the symbol to also carry a frame.

### Lesson learned
**SF Symbol `.circle` / `.circle.fill` variants belong inside content surfaces (large hero icons, list-row leading marks, illustration heroes). The toolbar belongs to the bare-glyph form.** When picking an SF Symbol for a toolbar item:
- `xmark` (close) — never `xmark.circle` / `xmark.circle.fill`
- `ellipsis` (menu) — never `ellipsis.circle`
- `gearshape` (settings) — never `gearshape.circle`
- `magnifyingglass` (search) — never `magnifyingglass.circle`
- `chevron.left` / `chevron.right` (nav) — never the `.circle` versions
- `arrow.up` / `arrow.down` — never the `.circle` versions

Use `.circle` ONLY when the symbol is a content-layer hero — slide illustrations, big-icon empty states, status disclosure cards.

### Prevention (concrete)
- Before placing an SF Symbol in a `ToolbarItem`, check: is the bare form (no `.circle`) available? If yes, use it.
- If a future change needs the `.circle` form *inside* the toolbar specifically (rare; can't think of a legitimate case), justify in a one-line code comment.

### Detection
When selecting an SF Symbol for a `.toolbar { ToolbarItem { … Image(systemName: ???) } }` — if the name ends in `.circle` or `.circle.fill`, you are about to repeat this mistake. Drop the suffix and re-evaluate.

---

## M-001 · Sourced crypto logos from `spothq/cryptocurrency-icons` instead of `trustwallet/assets`

- **Date:** 2026-06-04
- **Severity:** MEDIUM
- **Status:** CORRECTED (replacement shipped in the same session — see `SHIPPED.md` entry titled "Replace crypto icons with Trust Wallet's authoritative source + CTAs on every slide")
- **Domain:** `assets`, `crypto-iconography`, `sourcing`

### What I did
When implementing Rule #7's retroactive replacement of the 10 onboarding
illustrations, I downloaded crypto logos from
`github.com/spothq/cryptocurrency-icons` (CC0 SVGs). This covered BTC, ETH,
SOL, USDC, USDT, XRP, TRX, BNB, AVAX, MATIC, DOT, LTC — but **failed to find
NEAR** (the repo doesn't ship a NEAR SVG), and I worked around the gap by
substituting LTC and documenting the substitution. I did not consult
Trust Wallet's `github.com/trustwallet/assets` repository, which is the
**canonical source of brand assets for crypto wallet apps**.

### Why it was wrong
Trust Wallet's `assets` repository is:
1. **Authoritative for the use case.** Trust Wallet is itself a major
   self-custody wallet (the use case we're building). Its asset repo is
   maintained as the brand-asset standard for that ecosystem and is what
   every comparable wallet (Rainbow, Phantom, etc.) defaults to.
2. **More comprehensive.** It includes NEAR, TON, APT, and dozens of other
   chains/tokens that smaller repos like spothq miss — including every
   network in our own `SUPPORTED_ASSETS.md` (24 networks, 100+ tokens).
3. **More current.** Officially updated when chains rebrand (e.g., MATIC →
   POL, the Polygon rebrand).
4. **Per-chain asset addressing.** Tokens are addressed by their on-chain
   contract address, which matches our `SUPPORTED_ASSETS.md` data model.
   That makes future expansion mechanical instead of guesswork.

I should have consulted Trust Wallet first by default.

### Root cause
I reached for the *first* MIT/CC0 crypto-icon repo I knew about
(`spothq/cryptocurrency-icons`) instead of asking "what does the
crypto-wallet community actually use as the brand-asset source of truth?".
A 30-second search would have surfaced `trustwallet/assets`.

### Lesson learned
**For any domain with a canonical community standard, find the standard
before reaching for a generic alternative.** "Open-source and permissively
licensed" is not the only quality bar — *authoritativeness for the use
case* is at least as important. For crypto-wallet brand assets, that
standard is `trustwallet/assets`.

### Prevention (concrete)
- **Default crypto-icon source from now on:**
  `https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/<chain>/info/logo.png` for native-coin marks (BTC, ETH, SOL, …)
  `…/blockchains/<chain>/assets/<contract>/logo.png` for token marks (USDC, USDT, …)
- **Before downloading any third-party visual asset**, ask: is there a
  community-canonical source for this domain? Check for it, then choose.
- **Add `trustwallet/assets` to Rule #7's Part B as the primary source for
  crypto-token logos**, ahead of `spothq/cryptocurrency-icons`. (Done in the
  same session this mistake was logged.)

### Detection (for future readers)
If a future task involves "find a logo / icon / brand mark for a chain or
token", and the first impulse is to reach for `spothq` or a similar
generic icon repo, **stop and read this entry first.** Default to Trust
Wallet's `assets` repo unless the chain genuinely isn't there — and even
then, check the chain's own brand-assets page before going generic.
