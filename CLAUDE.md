# UniApp — Agent Rules

## Rule #1 — RETRACTED 2026-06-09 per user direction. Do not write to `SHIPPED.md`.

The original Rule #1 required every BIG edit to append a dated entry
to `SHIPPED.md`. **The user retired this requirement on 2026-06-09**:

> *"remove the rule that we should write everything to shipped, and
> from now stop writing things to shipped.md"*

Effective immediately:

- **Do NOT append new entries to `SHIPPED.md`.** Existing entries
  stay as historical record; nothing new gets written there.
- **Do NOT mention `SHIPPED.md` in commit messages, agent prompts,
  or end-of-turn summaries** as a place where the work is logged.
- The audit trail for changes is now the git commit log only —
  commits already follow conventional-commits format (`feat:`,
  `fix:`, `chore:`, etc.) per Rule #21 / common-git-workflow.md and
  carry enough detail in their bodies for any future agent to
  reconstruct intent.
- Subagents (jony-ive, translators, scanner, etc.) are also bound
  by this retraction. If a subagent's brief or its agent definition
  still mentions writing a SHIPPED entry, treat that as inert text
  — do not produce one.

The `MISTAKES.md` discipline (Rule #8) stays intact. That register
serves a different purpose (recurrence prevention) and the user did
not retract it.

---

## Rule #1 (original, RETRACTED) — Big changes get logged in `SHIPPED.md`. Small edits do not.

`SHIPPED.md` is the project's history of **meaningful** changes — the
file a future agent or human reads to understand "what has actually
been built." Drowning that history in single-line tweaks defeats its
purpose. **Big edits land here; small edits do not.** The discipline
of distinguishing the two is itself part of the rule.

### What counts as "BIG" (MUST log)

If the edit fits any of these, append a `SHIPPED.md` entry:

- **New feature surface** — a new screen, flow, sheet, or interactive
  surface the user can reach.
- **New component / token** — a new `UniButton` variant, a new
  `UniColors` role, a new `UniHaptic` case, a new SwiftData `@Model`,
  a new repository, a new networking adapter.
- **Architectural change** — schema migration, new module, new actor,
  refactor that touches ≥3 files or a public protocol.
- **Build / config change** — `project.yml`, signing, `Info.plist` keys,
  SPM dependency addition or removal, xcodegen options, `Assets.xcassets`
  catalog changes that introduce new assets (not just file rotations).
- **Security-touching change** — anything under
  `Brand/`, `Security/`, `Database/SeedVault*`, `Database/PinCode*`,
  Keychain access policy, biometric flow.
- **Rule / process change** — adding or amending a `CLAUDE.md` rule,
  changing the agent definitions, adding/removing a hook, updating the
  i18n closure chain.
- **Mistake correction** — landing the fix for an open `MISTAKES.md` entry
  (the SHIPPED entry is the audit trail that the mistake was addressed).
- **Multi-file structural fix** — a change spanning ≥3 files that aren't
  trivial mechanical reformatting.

### What counts as "SMALL" (do NOT log)

Single-purpose, single-surface edits that don't change the contract:

- One file, ≤ ~20 lines of real code change, with no new public API.
- Padding / spacing / radius tweaks within a single component.
- SF Symbol swap, copy refinement on an existing string, color-role
  swap from one existing role to another.
- A modifier reordering that produces the same semantic result.
- Reverting/iterating a previous SHIPPED entry's design without
  changing its identity (e.g. "take 2 → take 3" tuning of the same
  pill style). The original entry stays; the tuning does not get its
  own entry.
- Comment-only edits, docstring edits, log message edits.
- Test additions for an already-shipped feature (unless the test
  reveals a new behavior worth recording).

When in doubt: ask "would a future agent reading this entry six months
from now learn something they couldn't learn from the diff?" If yes,
log it. If the answer is "the diff says it all", don't.

### Bundling rule

When a session contains BOTH big and small edits, the **big edit's
SHIPPED entry is allowed to briefly mention the small tuning that
followed** (in a single line under "Follow-on tuning" or similar) so
the history stays threaded. Do NOT create a separate entry for the
small tuning; mention it inside the big entry's closing paragraph or
omit it entirely.

### Why this rule was tightened

Across 2026-06-07 the orchestrator added ~10 SHIPPED entries, many of
them documenting single-modifier tuning passes (toolbar pill take 1
→ 2 → 3 → 4, sheet padding 24 → 16). The user corrected:
*"small edits shouldn't be added to shipped.md. just big edits."*
The pre-correction text said *"even tiny edits, even comments"* — the
post-correction text (this) is the explicit reversal. SHIPPED.md is
the project's wall of plaques, not its commit log.

### What still counts as "something to log" (the inventory rewritten)

- New files created (Swift sources, asset catalogs, configs, docs) — IF
  the file is a new feature/component/token, not a one-off helper.
- New screens, views, components, models, design-system tokens — always.
- Build / install on Thuglife — only the install event is logged inside
  the big-change SHIPPED entry it accompanies (the
  `databaseSequenceNumber` is the receipt per Rule #22). No standalone
  "I installed" entries.
- New `// TODO:` markers — these go to `TODO.md` per Rule #5; not
  separately to SHIPPED.md.

### How to log

Append a new dated entry to the **top** of `SHIPPED.md` using this format:

```
## YYYY-MM-DD — <short title>

**Summary:** one-line description of what changed and why.

**Files added/modified/removed:**
- `path/to/file.swift` — what changed
- `path/to/other.md` — what changed

**Build / Run:**
- (only if a build, install, or launch happened) target device, configuration, outcome

**TODOs introduced:**
- file.swift:LN — what is stubbed
```

- One entry per logical change. If you make 5 unrelated edits in one turn,
  write 5 entries.
- Newest entries on top.
- Never rewrite or delete prior entries — `SHIPPED.md` is append-only history.
- If an entry needs correction, add a new entry that supersedes it (note the
  superseded date).

### Why
`SHIPPED.md` is the project's source of truth for "what has actually been done."
Other agents (and future-you) read it to avoid re-doing work, to find where a
feature lives, and to know what is real vs. still stubbed.

---

## Rule #2 — All design follows Jony Ive's language AND iOS 26 Liquid Glass

Every visual decision in UniApp — every screen, component, icon, animation,
spacing, color, type ramp, copy line, transition — must answer "yes" to two
questions:

1. **Would Jony Ive sign this?** (Honest, simple, restrained, materials-true.)
2. **Does this respect the iOS 26 Liquid Glass system?** (Translucent, layered,
   concentric, content-elevating, platform-native.)

This rule is non-negotiable. If a request conflicts with it (e.g. "add a flashy
shadow", "use 8 different fonts"), refuse politely and propose the on-system
alternative.

---

### Part A — Jony Ive's design language (the "why")

Synthesized from Ive's own writing (especially the introduction to *Designed by
Apple in California*, 2016), Dieter Rams' "less but better" lineage that Ive
explicitly cites, and his post-Apple LoveFrom work.

#### A.1 Core principles

1. **Care is the material.** "The product is the visible expression of the
   care, attention and obsession we have for it." Every pixel, every easing
   curve, every word in a button label is evidence of care or its absence.
   If the team would not be proud to ship it on a Sunday morning, do not ship it.
2. **Simplicity through reduction, not subtraction.** Simplicity is not the
   absence of complexity — it is the resolution of it. Strip until removing one
   more thing would break the experience. Ive: "Simplicity is not the absence
   of clutter; it is a quality of relationship."
3. **Honesty of materials and function.** A button looks tappable because it
   *is* tappable. A surface looks like glass because it *is* glass. Do not
   fake depth that has no purpose, do not put a "skeuomorphic" coin on a UI
   only because crypto is the subject. Don't lie to the user.
4. **The designer is invisible.** Ive: "One of the things that really irritates
   me in products is when I'm aware of designers wagging their tails in my
   face." No decorative flourishes that exist to make the designer look clever.
   The user must feel the **product**, not the **designer**.
5. **Form follows function — with obsession over the details.** Function
   determines form, but the form is then refined ruthlessly. A 1-point change
   in corner radius matters. A 4ms change in animation timing matters. A trailing
   space in a label matters.
6. **Less, but better. (Rams' rule, Ive's commitment.)** Fewer items, fewer
   colors, fewer weights, fewer accents — each one earning its place. When in
   doubt, remove it.
7. **Respect for the user's intelligence.** No "are you sure?" modals for
   reversible actions. No tutorials for self-evident UI. No tooltips on
   industry-standard icons. Trust the user.
8. **Time is the design's most precious budget.** Every tap, every scroll,
   every read-this-paragraph is a cost. Make the common path effortless;
   make the rare path findable; never make any path noisy.

#### A.2 What this means concretely for UniApp

- One **brand voice** in copy: calm, factual, short. No exclamation marks
  except where genuinely warranted (success of a real action). No emoji in UI
  text. No marketing-speak. ("Your portfolio at a glance" not "🚀 BLAZING-FAST
  wallet experience!!")
- One **primary type family**: SF Pro (rounded for marketing/onboarding hero
  copy, default SF Pro otherwise). No third-party display fonts.
- One **accent gradient** sitewide, plus neutral surfaces. Don't introduce a
  new color for every screen.
- **Concentric, intentional layout.** Padding and radii relate mathematically
  (see Part B.4). No "magic" 17-point gaps.
- **Animations serve meaning**, not delight-as-decoration. A morph happens
  because the *same thing* is changing state, not because morphs look cool.
- **No decorative iconography.** Every icon represents a real action, asset,
  or status. If you can't name what it does in three words, delete it.
- **Crypto is honest about risk.** APR is not "guaranteed", staking has
  slashing, networks have fees. UniApp will *say so*, plainly, where the user
  is about to act on that information. This is design, not just compliance.

---

### Part B — iOS 26 Liquid Glass system (the "how")

Apple's first fully unified design language across iOS, iPadOS, macOS, watchOS,
tvOS. UniApp is iOS 26+ only — we use it natively, not as an effect bolted on
to legacy UI.

#### B.1 The three behaviors of Liquid Glass

Every Liquid Glass surface must exhibit, simultaneously, all three:

1. **Translucency** — color and content from *behind* the surface bleed
   through, lightly blurred. The surface is informed by its surroundings.
2. **Specular highlights** — the surface reacts to *light* (system theme,
   ambient color, motion) with subtle bright reflections along its edges and
   curvature. This is what makes it feel like glass and not like a flat blur.
3. **Motion responsiveness** — the surface reacts to *interaction* (tap,
   drag, scroll, device tilt). Touch deforms it slightly; scrolls refract
   content; tilts shift the specular highlight.

If a surface has translucency but no specular highlight and no motion
response, **it is not Liquid Glass — it is a blur**. Use the system APIs (see
B.5) to get all three for free; do not hand-roll blur effects.

#### B.2 The three HIG pillars (Hierarchy, Harmony, Consistency)

| Pillar          | What it demands                                                                                                                                  |
|-----------------|--------------------------------------------------------------------------------------------------------------------------------------------------|
| **Hierarchy**   | Controls and chrome use Liquid Glass to *elevate* content. Content itself is opaque. Chrome adapts (hides on scroll, simplifies on focus).        |
| **Harmony**     | Concentric corners — children align radius with parent (see B.4). Glass shapes nest cleanly. Same component looks correct on iPhone / iPad / Mac.  |
| **Consistency** | Adopt platform conventions. Use system controls (`Button(.glass)`, `TabView`, `NavigationStack`) before building custom. Adapt across size classes. |

#### B.3 Layering & depth rules

iOS 26 uses **two clearly separated layers**:

1. **Content layer** — opaque, scrollable, owns the user's data. Cards,
   tokens, balances, charts, lists.
2. **Functional layer** — Liquid Glass chrome floating above content.
   Toolbars, tab bars, navigation bars, sheets, modals, floating action
   buttons, alerts.

Rules:
- Never stack glass on glass on glass. Maximum **two** glass layers in any
  visible region (e.g., a glass tab bar may sit above a glass card, but not
  above a glass card that sits on another glass card).
- Content scrolls **under** glass chrome — never beside it.
- Glass chrome **adapts on scroll** (HIG calls this `scrollEdgeEffect`); the
  edge becomes more translucent at rest, more opaque when content is under it.
- Drop shadows are **off by default** on glass. The specular highlight and
  refraction do the depth work. Add a faint shadow only if a glass element
  floats free with no edge contact.

#### B.4 Concentric corners — the math

> Child radius = parent radius − padding between them.

Example: a 24-pt rounded card containing a 16-pt internal padding around a
button → button radius = 24 − 16 = **8 pt**. This is not aesthetic — it is the
HIG rule that makes shapes nest visually. UniApp's design tokens encode this:
do **not** hard-code random radii in views.

#### B.5 The SwiftUI APIs (use these, not custom blurs)

All shipped on iOS 26 SDK. Always prefer these over hand-rolled materials.

```swift
// Single glass surface
.glassEffect()                                  // default capsule, regular variant
.glassEffect(.regular.tint(.accentColor).interactive(),
             in: .rect(cornerRadius: 16))       // tinted, interactive, custom shape

// Multiple glass surfaces in a region — REQUIRED for performance & morphing
GlassEffectContainer(spacing: 40) {
    HStack { ... }
}

// Merge sibling glass surfaces into one shape (e.g., two adjacent toolbar buttons)
.glassEffectUnion(id: "group1", namespace: ns)

// Morph between glass identities (e.g., FAB expanding to a card)
.glassEffectID("pencil", in: ns)

// First-class button styles
.buttonStyle(.glass)            // ambient action
.buttonStyle(.glassProminent)   // primary CTA
```

UIKit/WidgetKit parallels exist (`UIGlassEffect`, `UIGlassContainerEffect`,
`scrollEdgeEffect`, `widgetAccentedRenderingMode`) — use them in legacy
contexts only.

#### B.6 Required best practices

- Wrap multiple glass views in **`GlassEffectContainer`**. Standalone glass
  views break morphing and waste GPU.
- Apply `.glassEffect()` **after** layout modifiers (frame, padding, font).
- Use `.interactive()` **only** on elements that respond to input.
- Use `withAnimation { ... }` when toggling glass elements in/out so morphing
  engages.
- Test light + dark + tinted Home Screen + accessibility-increased contrast.
- **Accessibility floor**: text on glass must meet WCAG AA contrast against
  the *darkest plausible background* the glass might overlay.

#### B.7 Anti-patterns — forbidden in UniApp

- Custom `.blur(radius:)` materials masquerading as glass.
- More than two glass layers in any visible region.
- Glass applied to long-form content (paragraphs, lists, tables) — content is
  opaque.
- Drop shadows on glass except as noted in B.3.
- Skeuomorphic textures (brushed metal, leather, paper, "coin shine").
- Decorative micro-animations on every state change.
- Forcing concentric corners by hardcoded numbers — go through the design
  token system.
- Off-system fonts. Off-system icons (we use SF Symbols unless an asset is a
  brand mark or a real token logo).

---

### Part C — Swift 6.2 / iOS 26 implementation defaults

These are language-level defaults so the **code** matches the design ethos
(restrained, honest, modern).

- **Swift 6.2 Approachable Concurrency.** UI code is single-threaded on
  `@MainActor` by default. Background work is opted in explicitly via
  `@concurrent` or `Task.detached`. Never sprinkle `Task { @MainActor in ... }`
  inside views.
- **`@Observable`** macro for view models (not `ObservableObject`).
- **`Observations` async sequence** when streaming model changes to views.
- **`NavigationStack` + `NavigationPath`** for navigation (no UIKit pushes,
  no third-party routers).
- **App Intents** are the canonical surface for any feature that could be
  invoked from Siri / Spotlight / Shortcuts / interactive widgets. Every
  user-facing action gets an Intent.
- **SwiftData** for local persistence; **actor**-isolated repositories for
  anything multi-source. No raw `UserDefaults` for domain state.
- **Strict concurrency = complete.** No warnings ignored. No `@unchecked
  Sendable` without a comment explaining why and how it's safe.

---

### Part D — Workflow gate

Before any new screen, component, or visual change is committed:

1. **Sketch the intent in one sentence.** "Show the user their per-chain
   balances so they can tap one to drill in." If you can't, you don't have a
   design yet.
2. **Identify the layers.** Which surfaces are content (opaque)? Which are
   functional (glass)?
3. **Resolve concentric radii.** Use the design tokens; do not invent numbers.
4. **Check the three Liquid Glass behaviors.** Every glass surface must have
   translucency + specular + motion response (i.e., use the system APIs).
5. **Strip one thing.** Look at the design and remove the single least
   essential element. If the design still works, the removal is permanent.
   (Ive's rule of restraint.)
6. **Check the three pillars.** Hierarchy clear? Harmony with platform? Consistent
   across iPhone size classes?
7. **Honesty check.** Does any UI element overstate, mislead, or hide risk?
   (Especially for staking, swaps, fees, recovery.) If yes, fix the copy or
   the affordance before shipping.
8. **Log it in `SHIPPED.md`** per Rule #1.

---

## Rule #3 — Native-only. No third-party packages, no hand-rolled substitutes.

UniApp ships against the **latest iOS SDK (iOS 26+)** and the **latest Swift
toolchain (Swift 6.2+)**. Every capability the OS provides must be used through
its **native, system-provided API**. Reinventing what Apple already ships is
forbidden.

This rule is the *technical* enforcement of Rule #2: Liquid Glass is not
"a look we approximate" — it is a system service we *call*.

---

### Part A — What "native-only" means

1. **No Swift Package Manager dependencies, no CocoaPods, no Carthage** — at
   least until a real, demonstrable need arises that the iOS SDK cannot meet.
   When such a need *does* arise, it must be raised explicitly in chat and
   logged in `SHIPPED.md` with the justification. Default answer is "no".
2. **No third-party UI kits** (no SwiftUIX, no Pow, no SwiftfulUI, no
   Lottie-for-glass-effects, etc.). The SwiftUI in iOS 26 is sufficient and is
   what we build on.
3. **No third-party crypto/web3 SDKs *for the UI layer*.** Wallet logic
   (key generation, transaction signing, RPC) will be evaluated case-by-case
   later, but the **UI never** imports them — it consumes a local Swift
   protocol we own.
4. **No icon-pack libraries.** Use **SF Symbols** for all UI iconography. Real
   asset/brand marks (token logos, network logos) come in as bundled
   vector/PDF assets, not from an external symbol library.
5. **No font packages.** Use **San Francisco** (`Font.system`, including
   `.rounded` / `.serif` / `.monospaced` designs). The SF family covers every
   need we have.
6. **No hand-rolled approximations of system services.** If iOS 26 provides
   the thing, we call the thing. Concrete bans:

   | Banned approximation                              | Native API we must use instead                          |
   |---------------------------------------------------|---------------------------------------------------------|
   | `.background(.ultraThinMaterial)` blur as glass   | `.glassEffect()` / `GlassEffectContainer`               |
   | Hand-built capsule/rect "glass" CTA backgrounds   | `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)` |
   | Custom `TabView` look-alikes                       | SwiftUI `TabView` with Liquid Glass tab bar             |
   | UIKit navigation pushed manually                  | SwiftUI `NavigationStack` + `NavigationPath`            |
   | `ObservableObject` + `@Published`                  | `@Observable` macro                                     |
   | Custom focus / hover states                       | `.focusable()` / system focus effects                   |
   | Hand-rolled bottom sheets                         | `.sheet(...)` with `.presentationDetents`               |
   | Custom toast/banner libraries                     | `.alert(...)` / system notification surfaces            |
   | Custom haptics queues                             | `.sensoryFeedback(...)` modifier                        |
   | Custom keychain wrappers (UI layer)               | `Keychain` via Security framework (system) in domain layer; UI never sees it |
   | Custom theme switchers                            | `.preferredColorScheme` + system Dynamic Type / Accent  |
   | Custom date/number formatting                     | `Date.FormatStyle`, `Decimal.FormatStyle`, etc.         |
   | Custom internationalization                       | `String(localized:)` + `.xcstrings`                     |
   | Custom QR code generators (UI layer)              | `CIFilter.qrCodeGenerator()` via Core Image             |
   | Custom biometric prompts                          | `LocalAuthentication` framework                          |

7. **No JavaScript bridges, no React Native, no Flutter, no Capacitor, no
   web views for UI.** UniApp is a SwiftUI app, end of story.
8. **No code generation from Figma / "AI UI" tools that emits non-native
   components.** Generated SwiftUI is fine if it then maps 1:1 to system
   primitives.

### Part B — Allowed exceptions (rare, explicit)

The following are the *only* categories where a dependency could ever enter,
and even then only after explicit approval logged in `SHIPPED.md`:

- **Battle-tested cryptography primitives we cannot legally roll ourselves**
  (e.g., a vetted secp256k1 or BIP-39 library) — *only in the domain/data
  layer*, never linked into views.
- **Network-specific RPC SDKs** when an official, well-maintained one exists
  from the chain vendor (e.g., a Solana web3 Swift SDK) — again, domain layer
  only.
- **Apple-published OSS** (e.g., swift-collections, swift-algorithms,
  swift-syntax) — these are effectively part of the toolchain.

Every other "wouldn't it be easier with library X?" answer is **no**.

### Part C — Why this rule exists

- **Honesty (Rule #2 / Ive).** A button that *says* it's a Liquid Glass
  control but is actually a custom blur is a lie to the user.
- **Longevity.** When Apple iterates Liquid Glass next year, system controls
  evolve for free; custom approximations rot.
- **Accessibility.** System controls inherit Dynamic Type, VoiceOver, Reduce
  Motion, Increase Contrast, Smart Invert, Switch Control — all correctly,
  for free. Custom controls re-implement these badly or not at all.
- **Bundle weight & startup cost.** Zero third-party code = small binary,
  fast launch, smaller attack surface.
- **Security.** Every transitive dependency is a supply-chain risk. A crypto
  wallet does not get to be casual about this.
- **Performance.** System Liquid Glass uses Metal pipelines tuned by Apple;
  hand-rolled blurs are GPU-expensive and look wrong on ProMotion.

### Part D — Workflow gate (in addition to Rule #2's gate)

Before any new view or component is committed, also verify:

1. **Did I import a non-system package?** If yes, stop and justify in chat.
2. **For every visual primitive I built by hand, does iOS 26 already provide
   one?** If yes, replace it.
3. **For every behavior I scripted (sheets, hovers, focus, haptics,
   formatting, localization), did I use the system API?** If no, replace it.
4. **Does this build with zero `Package.swift` external dependencies?**

If any answer is "no" without a logged approval, the change does not ship.

---

### Part E — Retroactive fix obligation

This rule applies retroactively. Any code already in the repo that violates
it (e.g., the first cut of `OnboardingView` using `.ultraThinMaterial` and
hand-built `RoundedRectangle` button backgrounds) **must be refactored to
native APIs in the same session this rule is added**, and the refactor logged
in `SHIPPED.md`.

---

## Rule #4 — Unified color system only. No hardcoded colors. Ever.

Every color reference in UniApp **must** resolve to a role defined in
[`UniColors`](./UniApp/Sources/DesignSystem/UniColors.swift). Hardcoded colors
in feature code, regardless of form, are forbidden.

This rule guarantees: (1) light/dark/Smart-Invert/Increase-Contrast work
correctly on every screen, (2) a future brand re-skin touches **one file**,
(3) accessibility audits actually pass, (4) iOS 26 dynamic appearances
(tinted/clear/automatic) behave correctly across the app.

---

### Part A — What "hardcoded" means (banned)

The following are all hardcoded color usages and are not permitted in feature
code (anything outside `UniColors.swift` / `Assets.xcassets`):

| Banned form                                                  | Why it's banned                                     |
|--------------------------------------------------------------|------------------------------------------------------|
| `Color.red`, `Color.blue`, `Color.green`, `Color.gray` …     | SwiftUI's literal palette doesn't respect Increase Contrast and bypasses the design system |
| `Color.black`, `Color.white`                                 | Anchored to one appearance — wrong in the other     |
| `Color.white.opacity(0.62)` and friends                      | A custom alpha on a literal is still a literal      |
| `Color(red: 0.45, green: 0.78, blue: 1.0)`                   | Hex/RGB literal — bypasses semantic adaptation      |
| `Color(hex: "#007AFF")` (any hex helper)                     | Same problem; also encourages designers to ship hex |
| `Color(uiColor: .systemBlue)` **in a feature view**          | Allowed *only inside* `UniColors`; views reference a role, not a UIColor |
| `.background(.white)` / `.foregroundStyle(.black)`           | Literal usage at call site                          |
| `UIColor(red:…)` constructed at the SwiftUI boundary         | Same issue, UIKit form                              |
| `Gradient(colors: [.red, .blue])`                            | Literal colors inside gradients                     |
| Hex strings in asset catalog metadata for one-off colors     | Bypass the role layer; only `AccentColor.colorset` is allowed to define a brand color directly |

### Part B — The only allowed pattern

```swift
// ✅ Correct
.foregroundStyle(UniColors.Text.primary)
.background(UniColors.Background.secondary)
.tint(UniColors.Tint.accent)
RoundedRectangle(cornerRadius: UniRadius.xl)
    .fill(UniColors.Material.card)
```

```swift
// ❌ Forbidden
.foregroundStyle(.white)
.background(Color(red: 0.04, green: 0.04, blue: 0.06))
.tint(.blue)
RoundedRectangle(cornerRadius: 24).fill(.gray)
```

Three exceptions exist — and only these:

1. **Inside `UniColors.swift`.** This file is the *only* place that may import
   `UIKit` and reference `UIColor.*` / `Color(uiColor:)` / RGB literals.
   Adding a new role here is the correct way to express a new color need.
2. **Inside `Assets.xcassets`.** Brand assets (`AccentColor`, app icon, asset
   illustrations) may define their own color values — these are then exposed
   via a role in `UniColors`.
3. **`Color.clear`** is permitted everywhere — it's the absence of color, not a
   color choice.

### Part C — How to add a new color (the only correct workflow)

When a screen needs a color that doesn't yet exist as a role:

1. **Name the role first**, not the color. ("button label on destructive
   surface", not "white".)
2. **Pick the system semantic color** that fits in `UniColors.swift`. Prefer
   `Color(uiColor: .systemXxx)` so the value adapts automatically.
3. **Add the role to the appropriate sub-enum** (`Text` / `Icon` / `Background`
   / `Status` / etc.) with a one-line doc comment explaining when to use it.
4. **Reference it from the view** as `UniColors.<Category>.<role>`.
5. **Log the addition** in `SHIPPED.md` per Rule #1.

If a role is purely cosmetic-brand and has no system equivalent, define it via
an `Assets.xcassets` colorset with **both** light + dark appearance entries,
then expose it through `UniColors`.

### Part D — Opacity, gradients, overlays

- **Opacity on a role is allowed only inside `UniColors.swift`.** If you need
  a 15% tint of `systemRed`, that becomes a *new role* (`UniColors.Status.
  errorBackground`), not a `.opacity(0.15)` at the call site.
- **Gradients are color compositions** — they live in `UniColors` (or a future
  `UniGradients.swift` that itself references roles), never built inline with
  literals.
- **Overlays / blurs / glass tints** must take a `UniColors` role as input.
  `.glassEffect(.regular.tint(UniColors.Tint.accent))` is correct; `.tint(.blue)`
  is not.

### Part E — Enforcement / review checklist

Before any feature view is committed, audit it against this regex grep:

```
grep -nE 'Color\.(red|blue|green|orange|yellow|purple|pink|black|white|gray|grey|primary|secondary|accentColor)\b|Color\(red:|Color\(hex|Color\(\.system|UIColor\(|\.foregroundStyle\(\.|\.background\(\.|\.tint\(\.' \
  UniApp/Sources/Features
```

(That command lists every literal color usage in features. The expected output
is **empty**. Anything that appears must be moved into `UniColors` and
re-referenced.)

Additionally, every diff that touches a `.swift` file under `Sources/Features`
or `Sources/DesignSystem/Components` should be re-read to verify that *every*
color reference goes through `UniColors`.

### Part F — Retroactive applies

This rule applies retroactively to the entire codebase. If you find a literal
color in a file that exists today, fix it in the same session you notice it
and log the fix in `SHIPPED.md` (Rule #1).

---

## Rule #5 — Every `TODO` mirrored in `TODO.md`

Every `// TODO:` (and `// FIXME:` / `// XXX:`) comment that exists in the
codebase **must** have a corresponding, fully-described entry in
[`TODO.md`](./TODO.md). An inline marker is not enough — the register is the
canonical place to read what is stubbed, why, and what "done" looks like.

This rule complements Rule #1 (`SHIPPED.md` records *what is built*); Rule #5
makes `TODO.md` record *what is not yet built*.

---

### Part A — What goes in `TODO.md`

For every inline `TODO`/`FIXME`/`XXX`, add an entry containing:

- **Stable ID** — `T-001`, `T-002`, … assigned once and never reused.
- **Status** — `OPEN` / `IN-PROGRESS` / `BLOCKED` / `RESOLVED`.
- **Priority** — `P0` (blocks core flow) / `P1` / `P2` / `P3`.
- **Area** — feature/system the TODO belongs to.
- **File:line** — exact location of the inline marker (e.g.
  `UniApp/Sources/Features/Onboarding/OnboardingView.swift:88`).
- **Inline comment** — copy of the marker text, verbatim.
- **Context** — *why* this exists; what the stub stands in for; constraints.
- **What "done" looks like** — concrete acceptance criteria, ideally a
  numbered list of steps a future implementer can follow.
- **Honesty checks** (when relevant per Rule #2) — explicit notes about how
  the implementation must avoid misleading the user.
- **Depends on** — other TODO IDs or system pieces that must land first.

If the context fits on one line, the entry is too thin — go back and explain
why the stub exists.

### Part B — When to add an entry

1. **Whenever you write a new `// TODO:` comment**, add the entry in the same
   commit. Both must arrive together — never one without the other.
2. **Whenever you find an undocumented `// TODO:`** (e.g., from a prior session
   that pre-dates this rule), add the entry in the same session and reference
   it in `SHIPPED.md` per Rule #1.
3. **Whenever an implementation lands and removes a `// TODO:`**, move the
   register entry from the "Open" section to the "Resolved" section at the
   bottom of `TODO.md`. Stamp the resolution date and link the `SHIPPED.md`
   entry where the work was logged. **Do not delete the entry** — `TODO.md`
   is append-history-preserving like `SHIPPED.md`.

### Part C — IDs are stable

Once `T-007` is assigned, it stays `T-007` forever — even if the TODO is
resolved, even if it's reworded, even if the file moves. The next new entry
is the next-highest unused ID.

### Part D — Backlog entries are allowed (and encouraged)

Anticipated TODOs that don't yet have an inline marker (because the
view/file doesn't exist yet) belong in a `## Backlog` section of `TODO.md`.
They still get an ID and full body. When the relevant code is written, an
inline `// TODO: (T-XXX) ...` comment is added pointing back to the entry,
and the entry moves from `Backlog` to `Open`.

### Part E — Format of the inline marker

The inline comment must be **either**:

```swift
// TODO: short description of what is stubbed
```

— or, when explicit cross-reference is helpful:

```swift
// TODO: (T-002) Create new wallet flow — see TODO.md for full spec
```

The former is fine; the latter is preferred for any TODO with non-trivial
acceptance criteria, so a reader of the code can find the spec in one jump.

### Part F — Forbidden

- **No "silent stubs."** A function that returns `fatalError("unimplemented")`
  or empty `{}` without any marker is forbidden. If the work isn't done, say
  so with a `// TODO:` and an entry in `TODO.md`.
- **No TODOs without acceptance criteria.** "TODO: fix this later" is not a
  TODO; it's a bug. Either fix it now or describe what "fix" means in
  `TODO.md`.
- **No deletion of resolved entries.** They move to the "Resolved" section;
  they do not vanish.

### Part G — Audit command

Before any session ends, the following must produce identical inline marker
counts:

```
# Inline markers in code
grep -rnE '(TODO|FIXME|XXX)\b' UniApp/Sources/ | wc -l

# Entries in TODO.md "Open" + "Backlog" sections (excluding "Resolved")
awk '/^## Open/,/^## Resolved/' TODO.md | grep -cE '^### T-[0-9]+'
```

If the numbers diverge, a TODO has been written without an entry (or an
entry without a marker). Reconcile before proceeding.

---

## Rule #6 — All design work goes through the `jony-ive` agent

UniApp has a dedicated design subagent at
[`.claude/agents/jony-ive.md`](./.claude/agents/jony-ive.md).
It runs on the highest-capability Claude model available (Opus, configured
for maximum reasoning effort) and embodies fifteen-plus years of Apple
software design experience tuned to the Jony Ive lineage and iOS 26
Liquid Glass system.

**Whenever the user requests any of the following, the main agent must
delegate to `jony-ive` via the `Agent` tool — not attempt the work
inline:**

- New screen or flow (onboarding, wallet home, send, receive, swap,
  settings, asset detail, transaction detail, etc.)
- Redesign or visual refinement of an existing screen
- New component or modification of an existing component in
  `UniApp/Sources/DesignSystem/Components/`
- Token additions or changes (`UniColors`, `UniTypography`,
  `UniSpacing`, `UniRadius`)
- Layout adjustments, spacing changes, padding/margin work
- Color decisions of any kind (even adding a single role)
- Typography decisions (size, weight, family, leading)
- Iconography changes (SF Symbol selection, accent treatment)
- Motion / animation / transitions
- Empty / loading / error / offline state design
- Dark mode / light mode appearance work
- Accessibility surface review (VoiceOver labels, Dynamic Type, contrast)
- UI copy review (button labels, headlines, microcopy)
- Liquid Glass adoption / audit (`.glassEffect`, `GlassEffectContainer`,
  `.buttonStyle(.glass/.glassProminent)`, `glassEffectID` morphing)

### When *not* to invoke the designer

Do **not** spawn `jony-ive` for:

- Pure logic / state / networking changes that produce no visual change.
- Build / CI / xcodegen / signing issues.
- Domain-layer protocol design (use the architect-style reasoning inline
  or a different agent if added later).
- Dependency-management decisions (subject to Rule #3, no agent needed
  for a "no" answer).
- Documentation edits to `CLAUDE.md` / `SHIPPED.md` / `TODO.md` /
  `SUPPORTED_ASSETS.md` themselves.
- Bug fixes that restore an existing design without changing it.

If unsure, **delegate**. A small visual change going through the designer
is cheap insurance against drift; a visual change made inline that
violates Rules #2 / #3 / #4 is expensive to undo.

### How the delegation looks

```
Agent({
  description: "Design <thing> for <where>",
  subagent_type: "jony-ive",
  prompt: "<the design intent, with any constraints, screenshots, or
            references the user supplied — and a reminder that the agent
            must read CLAUDE.md before acting>"
})
```

The agent will:
1. Read `CLAUDE.md`, `TODO.md`, `SHIPPED.md`, and the relevant feature/
   design-system files.
2. Audit the existing surface against Rules #2 / #3 / #4.
3. Sketch the intent, identify layers, resolve metrics, pick colors from
   `UniColors`, compose from existing components.
4. Strip one element. Pass the seven checks.
5. Build and (when applicable) install to Thuglife.
6. Append to `SHIPPED.md` and `TODO.md`.

The main agent's job after delegation is to **verify** — read the diff
the designer produced, confirm Rules #1–#5 were followed (especially the
`SHIPPED.md` / `TODO.md` entries), and surface any deviation to the user.

### Why this rule exists

- **Taste consistency.** Every design decision flows through the same
  trained instinct. No accidental drift screen-to-screen.
- **Deep reasoning where it matters.** Visual decisions get the highest
  reasoning budget; logic/build work doesn't waste it.
- **Rule enforcement at the source.** The designer is briefed on every
  rule and refuses violations before they reach the codebase.
- **Accountability.** Every design entry in `SHIPPED.md` can be traced
  to the agent that produced it.

---

## Rule #7 — Real visuals only. Never hand-build icons, logos, or illustrations.

UniApp uses **real, designed visual assets** for everything iconographic or
illustrative. We do not invent icons. We do not approximate brand logos. We
do not compose `Canvas` / `Path` / `Shape` shapes to imitate what a designed
icon should look like.

This rule supersedes any prior tolerance for SwiftUI-primitive illustrations
in feature code. The "real" in "real visuals" means: designed by a person or
team — Apple, an open-source icon library, a token/network's official brand
assets, or commissioned/purchased artwork — and shipped as a bundled asset.

---

### Part A — What counts as a "real" visual

A visual is **real** when it was authored as a deliberate design artifact and
is published somewhere you can point to. The test: can you cite the source
URL and the license? If yes, it is real. If no — if it exists only because
SwiftUI primitives were composed to look like an icon — it is not real and
cannot ship in UniApp.

### Part B — Authoritative sources (priority order)

1. **SF Symbols** — Apple's official symbol library. Use for system
   iconography (toolbar items, action symbols, list-row leading icons,
   navigation back glyphs). These are real Apple designs and are the
   *first choice* anywhere SF Symbols covers the need.

2. **Official brand assets** for crypto tokens and networks — the official
   marks of Bitcoin, Ethereum, Solana, etc. Pull from authoritative,
   commercially-safe sources in this priority order:
   - **`github.com/trustwallet/assets` (MIT)** — the canonical brand-asset
     repository for self-custody wallet apps. Native-coin logos at
     `blockchains/<chain>/info/logo.png`; on-chain token logos at
     `blockchains/<chain>/assets/<contract-address>/logo.png`. **This is
     UniApp's default crypto-icon source** — covers every network in
     `SUPPORTED_ASSETS.md` and is updated with chain rebrands (e.g., POL).
   - The token's own published brand-assets page (use when an asset's
     visual identity has changed and Trust Wallet hasn't caught up).
   - The chain vendor's developer documentation.
   - `github.com/spothq/cryptocurrency-icons` (CC0) — fallback only for
     marks not yet in Trust Wallet's repo. (See `MISTAKES.md` M-001 for
     why this was demoted.)

3. **Established open-source icon sets** for non-system iconography that
   exceeds SF Symbols' coverage:
   - **Lucide** (`lucide.dev`) — ISC license.
   - **Phosphor Icons** (`phosphoricons.com`) — MIT.
   - **Heroicons** (`heroicons.com`) — MIT.
   - **Tabler Icons** (`tabler.io/icons`) — MIT.
   - **Iconoir** (`iconoir.com`) — MIT.

4. **Designed illustrations** for hero / onboarding / marketing surfaces:
   - **unDraw** (`undraw.co`) — MIT-style; recoloring allowed.
   - **Storyset by Freepik** — free with attribution or commercial license.
   - Commissioned / in-house illustration.

### Part C — What is forbidden

- Building an icon or illustration from `Shape`, `Path`, `Canvas`,
  `Rectangle`, `Circle`, `Capsule`, `Ellipse`, `RoundedRectangle`,
  `Polygon`, `Line`, or any combination thereof *with the intent to
  approximate a designed icon, brand mark, or illustration*.
- Hand-composing brand marks. A circle with a "B" inside is **not** a
  Bitcoin logo — use the real one.
- Imitating designed illustrations with gradients + masks + blend modes
  to suggest a scene.
- Sourcing visuals from any provider whose license is unclear or that
  requires per-use payment we have not paid for.

**Exception — structural shapes are not icons.** A `RoundedRectangle`
used as a card container, a `Capsule` used for a glass button, a `Circle`
used as a balance-avatar background — these are layout primitives, not
iconography. They are allowed and necessary.

**The line:** if a shape carries **meaning** as a symbol ("this represents
Bitcoin / security / a swap / a face / a chain"), it is an icon and must
be a real asset. If it carries only **structure** ("this is a rounded
surface that holds content"), it is a primitive and may be SwiftUI-built.

### Part D — How assets ship

1. Download the source SVG / PDF / PNG from the authoritative provider.
2. Add to `UniApp/Resources/Assets.xcassets/<Category>/<Name>.imageset/`
   with a `Contents.json` declaring `idiom: universal`, `scale: any`, and
   for SVG sources: `"preserves-vector-representation": true`.
3. Reference from views as `Image("<Name>")` (or `Image(.<name>)` with
   the generated symbol if you use the Asset Symbol generation).
4. Apply `.renderingMode(.template)` and tint via a `UniColors` role
   **only** when the asset is a monochrome glyph designed for tinting
   (Lucide, Phosphor, mono SF-equivalents). Multi-color brand logos
   (real coin marks, official network logos, illustrations) render
   as authored.
5. **Record the source URL and license** in
   `UniApp/Resources/Assets.xcassets/README.md` so every shipped pixel
   has auditable provenance. One line per asset: `<Name> — <URL> — <license>`.

### Part E — Workflow gate (in addition to Rules #2/#3/#4/#5/#6)

Before any visual element ships, the designer must answer:

1. Is this an icon, a logo, or an illustration? (Or is it a layout primitive?)
2. If yes — what is the source URL?
3. Is the license commercially compatible with shipping UniApp?
4. Is the asset bundled in `Assets.xcassets`?
5. Is its provenance recorded in `Assets.xcassets/README.md`?

If any answer is unsatisfactory, the asset cannot ship.

### Part F — Retroactive

The 10 onboarding illustrations currently in
`UniApp/Sources/Features/Onboarding/Illustrations/` were built from
SwiftUI primitives (`Shape`, `Canvas`, `Path`, gradients) and **violate
this rule**. They must be replaced with real, bundled visual assets — by
the `jony-ive` agent — in the same session this rule is introduced.

---

## Rule #8 — Every mistake logged in `MISTAKES.md`. Never repeat a logged mistake.

UniApp's quality discipline rests on two paired files:

- **`SHIPPED.md`** records *what was built* (Rule #1).
- **`MISTAKES.md`** records *what went wrong* — so it doesn't happen again.

Rule #8 makes the second file load-bearing.

---

### Part A — When to log a mistake

Log a mistake in `MISTAKES.md` immediately when **any** of the following
happens:

1. The user notices and corrects a wrong choice (wrong library, wrong
   source, wrong file location, wrong copy, wrong default).
2. You catch yourself having done something the rules in `CLAUDE.md`
   forbid, *after* having shipped it (a violation slipped through).
3. You produce work that the user pushes back on as not matching the
   project's taste / standards / conventions.
4. You repeat a question the user has already answered earlier in the
   session or in a prior session.
5. You make an assumption that turns out to be wrong and a fix would have
   been cheap if the assumption had been checked.
6. You burn build-and-redeploy cycles because of an oversight (forgot a
   file, wrong device id, wrong scheme, wrong signing).

If you are not sure whether something rises to the level of a mistake,
log it. The cost of a too-broad log is zero; the cost of a missing entry
is repeating the same error.

### Part B — What does NOT belong in `MISTAKES.md`

- Genuine technical roadblocks (a tool failed, a download 404'd) — those
  are circumstances, not mistakes.
- Decisions the user later changed their mind on. If you chose option A
  with sound reasoning and the user later asked for B, that is iteration,
  not a mistake.
- Style preferences that surfaced for the first time in this session and
  weren't yet known to you. The first time you learn a preference, save
  it to a **memory** (per the auto-memory instructions in the global
  config) — not to `MISTAKES.md`. Only if you *re-violate* the preference
  later does that become a mistake.

### Part C — Format of an entry

```
## M-XXX · <short title>

- **Date:** YYYY-MM-DD
- **Severity:** LOW / MEDIUM / HIGH
- **Status:** OPEN / CORRECTED / RECURRENCE-PREVENTED
- **Domain:** which area of the codebase / which subject this touches

### What I did
(verbatim or paraphrased — concrete enough that a reader recognizes the
shape of the mistake)

### Why it was wrong
(the principle, standard, or expectation that was violated)

### Root cause
(the missing knowledge or wrong assumption that produced the mistake)

### Lesson learned
(the principle to internalize — one sentence)

### Prevention (concrete)
(an explicit, mechanical check or default you will apply in future similar
situations)

### Detection (for future readers)
(how a reader of MISTAKES.md should recognize they are about to repeat
this mistake)
```

IDs are stable forever. `M-007` once assigned stays `M-007` even after
status changes to `RECURRENCE-PREVENTED`.

### Part D — Reading `MISTAKES.md`

`MISTAKES.md` is **mandatory reading at the start of any task** that
plausibly touches a domain a prior mistake covers. Concretely:

- Sourcing assets → re-read every entry tagged `assets` / `sourcing` /
  `licensing`.
- Choosing a library / framework / approach → re-read every entry tagged
  with the relevant domain.
- Writing or reviewing onboarding / wallet / settings / list-row code →
  re-read entries tagged with that domain.

The `jony-ive` agent's identity (`§0 — Operating mode`) requires reading
`MISTAKES.md` before any visual or interaction-design task.

### Part E — Status discipline

- **OPEN** — the mistake has been logged but the fix has not yet shipped.
- **CORRECTED** — the fix shipped (link the relevant `SHIPPED.md` entry
  by date and title at the end of the body).
- **RECURRENCE-PREVENTED** — at some later point you almost re-made the
  same mistake but caught it because you re-read `MISTAKES.md`. **Add a
  short note describing the near-miss** — these are gold: they prove the
  rule worked.

### Part F — Forbidden

- **Deleting an entry.** Even if the mistake is fully corrected and the
  source of the mistake (a library, a file, a habit) no longer exists.
  The historical record is the deterrent.
- **Editing an entry to hide what happened.** Fix typos, add status
  updates, link to the corrective `SHIPPED.md` entry — never rewrite the
  "What I did" section to make a mistake look less mistaken.
- **Logging the user's mistakes here.** This file is specifically for the
  agent's mistakes. If the user changes their mind or asks for something
  contradictory to a previous request, that is iteration; log nothing.

### Part G — Audit reminder

When you have a few minutes during a quiet moment in a session, scan
`MISTAKES.md` once and ask yourself: "Has anything I plan to do today
re-introduce one of these patterns?" If yes, change course before you
ship.

---

## Rule #9 — Full i18n. Every user-facing string is localizable. (AMENDED 2026-06-12: English keys only until app completion.)

> **Amendment 2026-06-12 (user direction — same direction that retired
> Rule #13):** the *authoring* contract below is unchanged — every
> user-facing string is a localizable literal, and every string in code
> gets a catalog entry. But the *translation fanout* is deferred: new
> catalog entries carry the **English source only**. The per-edit
> translator dispatch described in Parts D–F below is **suspended**;
> one full 50-language pass runs when the app is finished (see Rule #20
> as amended). Parts D–F remain as the spec for that final pass.

UniApp ships in **20 languages** from day one. Every string a user can see
must be a `String(localized:)` / `LocalizedStringKey` / `LocalizedStringResource`
reference — never a bare `String` literal in a `Text(...)`, `Button(...)`,
`Label(...)`, alert title, or anywhere else that renders.

A pair of **translator agents** keeps the `Localizable.xcstrings` String
Catalog in sync — per the 2026-06-12 amendment they run only in the final
app-completion pass, not after every edit.

---

### Part A — Supported languages (50 target + English source)

Source: **en** (English).

Targets (ISO 639-1 / BCP 47 codes — expanded 2026-06-04 from 20 → 50 per user direction to cover every iOS-supported localization):

**Tier 1 — Original 20** (translator-primary + translator-secondary classic split):

| Code      | Language             | Notes        |
|-----------|----------------------|--------------|
| es        | Spanish              |              |
| zh-Hans   | Chinese (Simplified) |              |
| zh-Hant   | Chinese (Traditional)|              |
| hi        | Hindi                |              |
| ar        | Arabic               | **RTL**      |
| pt-BR     | Portuguese (Brazil)  |              |
| bn        | Bengali              |              |
| ru        | Russian              |              |
| ja        | Japanese             |              |
| de        | German               |              |
| fr        | French               |              |
| ko        | Korean               |              |
| it        | Italian              |              |
| tr        | Turkish              |              |
| vi        | Vietnamese           |              |
| th        | Thai                 |              |
| id        | Indonesian           |              |
| fa        | Persian              | **RTL**      |
| pl        | Polish               |              |
| nl        | Dutch                |              |

**Tier 2 — Added 2026-06-04 (30 new)**:

| Code      | Language             | Notes        |
|-----------|----------------------|--------------|
| ur        | Urdu                 | **RTL**      |
| uk        | Ukrainian            |              |
| el        | Greek                |              |
| ro        | Romanian             |              |
| cs        | Czech                |              |
| hu        | Hungarian            |              |
| sv        | Swedish              |              |
| nb        | Norwegian (Bokmål)   |              |
| da        | Danish               |              |
| fi        | Finnish              |              |
| he        | Hebrew               | **RTL**      |
| ca        | Catalan              |              |
| hr        | Croatian             |              |
| sk        | Slovak               |              |
| sl        | Slovenian            |              |
| sr        | Serbian              |              |
| bg        | Bulgarian            |              |
| et        | Estonian             |              |
| lt        | Lithuanian           |              |
| lv        | Latvian              |              |
| is        | Icelandic            |              |
| ms        | Malay                |              |
| fil       | Filipino (Tagalog)   |              |
| sw        | Swahili              |              |
| af        | Afrikaans            |              |
| ta        | Tamil                |              |
| te        | Telugu               |              |
| ml        | Malayalam            |              |
| mr        | Marathi              |              |
| pa        | Punjabi (Gurmukhi)   |              |

RTL languages now: `ar`, `fa`, `ur`, `he` (4 total).

### Part B — Storage

Single source of truth: **`UniApp/Resources/Localizable.xcstrings`**
(Xcode String Catalog, iOS 17+). JSON under the hood — readable and writable
by tools. Plurals, variations, and source/state metadata included.

Never use legacy `.lproj/Localizable.strings` files. Never use a third-party
i18n SDK (Rule #3 — native-only).

### Part C — Authoring rule

When writing or editing a SwiftUI view:

```swift
// ✅ Correct
Text("Welcome to UniApp")                          // LocalizedStringKey auto-extracted
Button("Create new wallet") { … }                  // same
let title = String(localized: "Welcome to UniApp") // for use outside SwiftUI
LocalizedStringResource("error.network")           // for system surfaces (App Intents, etc.)

// ❌ Forbidden
Text(verbatim: "Welcome to UniApp")                // bypasses localization
Text("Welcome to UniApp" as String)                // bypasses localization
let title: String = "Welcome to UniApp"; Text(title) // unless title came from String(localized:)
```

Strings passed via component props (`UniButton(title:)`, `UniLargeTitle(text:)`)
are localized in the **component's body**, not at the call site. Components
must accept `LocalizedStringKey` (or `String(localized:)`-produced strings),
not bare `String`, when the value will render to the user.

Use **keys with namespaces** for non-trivial strings:
- `onboarding.welcome.title` → "Welcome to UniApp"
- `settings.appearance.system` → "Use system setting"
- `error.network.offline` → "You're offline. Check your connection."

Trivial UI literals can stay as the English source key itself
(`"Create new wallet"`), which is also what Xcode's auto-extraction emits.

### Part D — The two translator agents

Located in `.claude/agents/` (and mirrored to `~/.claude/agents/`):

- **`translator-primary`** — covers 25 languages: `es`, `zh-Hans`,
  `zh-Hant`, `hi`, `ar` (RTL), `pt-BR`, `bn`, `ru`, `ja`, `de`, `uk`,
  `el`, `ro`, `cs`, `hu`, `sv`, `nb`, `da`, `fi`, `he` (RTL), `ca`,
  `hr`, `sk`, `sl`, `sr`.
- **`translator-secondary`** — covers 25 languages: `fr`, `ko`, `it`,
  `tr`, `vi`, `th`, `id`, `fa` (RTL), `pl`, `nl`, `ur` (RTL), `bg`,
  `et`, `lt`, `lv`, `is`, `ms`, `fil`, `sw`, `af`, `ta`, `te`, `ml`,
  `mr`, `pa`.

Both run on `model: opus`, are designed to run **in background** (`run_in_background: true`
when spawned via the `Agent` tool), and pick up only strings whose
`extractionState` is `"new"` or `"stale"` in the String Catalog — they
never re-translate already-finalized entries unless explicitly told.

### Part E — Auto-trigger after edits

A `PostToolUse` hook configured in `.claude/settings.json` runs
`.claude/hooks/check-new-strings.sh` after every `Write` or `Edit` of a
`.swift` or `.xcstrings` file. The hook:

1. Greps the changed file(s) for **new localization references**
   (`Text("..."`, `Button("..."`, `String(localized:`, `LocalizedStringResource(`,
   etc.) that are not already present in `Localizable.xcstrings`.
2. If new strings are found, appends a marker line to
   `.claude/translation-queue.log` with the file path and detected keys
   plus a timestamp.
3. Emits a short reminder to the agent transcript: "🌐 New strings
   detected — spawn `translator-primary` + `translator-secondary` in
   background to translate."

The main agent reads `.claude/translation-queue.log` at the start of
every session (and after long edit bursts), and when it finds unprocessed
entries, spawns the two translator agents in parallel via the `Agent`
tool with `run_in_background: true`. When the agents complete, the
String Catalog is up to date and the queue log is truncated.

### Part F — Workflow for the main agent

1. Before suggesting a code change that adds user-facing strings, prefer
   to write them in the source language (English) directly in code as
   `Text("…")` — Xcode and the String Catalog handle extraction.
2. After committing the change, read `.claude/translation-queue.log`.
   If non-empty:
   ```
   Agent({
     subagent_type: "translator-primary",
     run_in_background: true,
     description: "Translate new strings to 10 languages (primary set)",
     prompt: "Read .claude/translation-queue.log + Localizable.xcstrings. Translate new entries to your 10 languages. Don't touch already-translated entries. Truncate your half of the queue on completion."
   })
   // and in the same message:
   Agent({
     subagent_type: "translator-secondary",
     run_in_background: true,
     description: "Translate new strings to 10 languages (secondary set)",
     prompt: "(same brief)"
   })
   ```
3. When notified that both agents have completed, audit the
   `Localizable.xcstrings` diff before considering the change shipped.

### Part G — Forbidden

- **Hardcoded user-facing strings.** A literal `"Welcome to UniApp"` in
  SwiftUI body code is acceptable *only if* the surrounding `Text` /
  `Button` / `Label` is the LocalizedStringKey-accepting initializer,
  which auto-localizes. `Text(verbatim:)` / `.init(stringLiteral:)` /
  `as String` casts that strip localization are forbidden.
- **Editing `Localizable.xcstrings` translations by hand from the main
  agent.** Translations come from the translator agents. The main agent
  may add new English source entries; it does not write target-language
  entries.
- **Skipping translation for any of the 20 supported languages.** If a
  language is genuinely unsupported by a translator agent for a given
  string (proper noun, brand name, untranslatable jargon), the entry's
  `extractionState` should be set to `"manual"` with a note in the
  catalog's comment field — not silently left empty.

### Part H — Reading

`MISTAKES.md` may eventually have entries tagged `i18n` — read those
before any localization work, per Rule #8 §D.

---

## Rule #10 — Unified haptic system. Every interactive surface fires through `UniHaptic`.

UniApp has a single, native haptic feedback system. Every button tap, every
toggle change, every commit / cancel / success / warning / error moment that
deserves a tactile beat fires through the `UniHaptic` API — never via raw
`UIImpactFeedbackGenerator()` or an inline `.sensoryFeedback(...)` call in
feature code.

The system rests on three pieces:

- **`UniHaptic` enum** — every *semantic* haptic event the app emits
  (selection, success, warning, error, soft/medium/firm impact, increase,
  decrease, start, stop, confirmation). Each case maps internally to the
  matching iOS 26 `SensoryFeedback` constant.
- **`.uniHaptic(_:trigger:)` View modifier** — the only allowed way to fire
  a haptic from a view. Internally wraps native `.sensoryFeedback(_:trigger:)`
  and short-circuits to no-op when the user has haptics disabled.
- **`@AppStorage("hapticFeedbackEnabled")`** — Bool, default `true`. Surfaced
  in `Settings` as a toggle row. When the user flips it off, the entire app
  goes silent on touch with one line of state change — no per-call audits
  needed.

---

### Part A — The semantic vocabulary

| `UniHaptic` case  | When to fire                                                                | Maps to                                              |
|-------------------|------------------------------------------------------------------------------|------------------------------------------------------|
| `.selection`      | Picker change, toggle on/off, list-row tap that opens detail, secondary CTA  | `.selection`                                         |
| `.softImpact`     | Lightweight tap acknowledgement                                              | `.impact(weight: .light)`                            |
| `.mediumImpact`   | Primary CTA tap that commits to a flow (Create new wallet → seed gen)        | `.impact(weight: .medium)`                           |
| `.firmImpact`     | Significant commit (sign transaction, confirm seed phrase)                   | `.impact(weight: .heavy)`                            |
| `.success`        | Wallet created, transaction confirmed, copy-to-clipboard succeeded            | `.success`                                           |
| `.warning`        | Destructive CTA tap (delete wallet, sign out), confirmation about-to-show    | `.warning`                                           |
| `.error`          | Failed transaction, validation failure, biometric refused                    | `.error`                                             |
| `.increase`       | Stepper up, slider up, swap-amount up                                        | `.increase`                                          |
| `.decrease`       | Stepper down, slider down, swap-amount down                                  | `.decrease`                                          |
| `.start`          | Animation start (rare), beginning a long-running flow                        | `.start`                                             |
| `.stop`           | Animation end, end-of-list reached                                           | `.stop`                                              |
| `.alignment`      | Snap to grid, snap to value (rare)                                           | `.alignment`                                         |
| `.levelChange`    | Network change in a picker, chain switch                                     | `.levelChange`                                       |

When in doubt: `.selection` is the cheap, polite default.

### Part B — The only authoring pattern

```swift
// ✅ Correct
SomeView()
    .uniHaptic(.selection, trigger: currentIndex)

// ✅ Correct — multiple haptics on one view, multiple triggers
SomeView()
    .uniHaptic(.selection, trigger: currentIndex)
    .uniHaptic(.success, trigger: completedAt)
```

Inside `UniButton`, the haptic fires automatically per the variant mapping
in Part E — no caller responsibility. For non-`UniButton` interactive
surfaces (sliders, custom gestures, sheet dismissals), use `.uniHaptic(...)`
on the view that owns the state change.

```swift
// ❌ Forbidden — raw UIKit haptic in feature code
UIImpactFeedbackGenerator(style: .medium).impactOccurred()

// ❌ Forbidden — inline native modifier in feature code
.sensoryFeedback(.selection, trigger: value)

// ❌ Forbidden — Core Haptics for cosmetic patterns
CHHapticEngine() // … only allowed for genuinely custom signature events,
                 //     and only after a UniHaptic case has been added first
```

### Part C — User preference

- Storage: `@AppStorage("hapticFeedbackEnabled")` (Bool, default `true`).
- Settings UI: a toggle row under the Settings sheet, with localized label.
- When the preference is `false`, `.uniHaptic(...)` resolves to a no-op
  (returns the underlying view unchanged); when it's `true`, it applies
  the corresponding `.sensoryFeedback(...)` modifier.
- The preference is read at the `View` level via `@AppStorage` inside the
  extension's implementing helper view, so flipping the toggle takes
  effect immediately for all subsequent interactions.
- iOS also has a system-level "System Haptics" preference and a "Reduce
  Motion" accessibility setting — `.sensoryFeedback(...)` already respects
  these. Our toggle is **in addition to** those, not a replacement.

### Part D — Forbidden

- `UIImpactFeedbackGenerator(...).impactOccurred()` anywhere except inside
  `UniHaptic`'s implementation file.
- `UINotificationFeedbackGenerator(...)` anywhere except inside `UniHaptic`'s
  implementation file.
- Inline `.sensoryFeedback(...)` in any file outside `UniHaptic`'s.
- `CHHapticEngine` for cosmetic micro-feedback (it's allowed only for
  bespoke, durable signature haptics like a wallet-creation seal — and
  only after a new `UniHaptic` case has been added for that signature).
- Haptics fired from background threads or actor contexts other than
  `@MainActor`.

### Part E — Default per-component bindings

These are the bindings shipped with `UniButton`:

| `UniButton.Variant` | Haptic fired on tap |
|---------------------|----------------------|
| `.primary`          | `.contextualImpact(.commit)` — committing to a flow |
| `.secondary`        | `.selection` — neutral acknowledgement |
| `.destructive`      | `.warning` — deliberate weight; user should feel they triggered something irreversible |
| `.tertiary`         | none — inline text links should feel as quiet as plain HTML links |
| `.toolbarPill`      | `.selection` — picker-class commit (opens a sheet / switches a context); nav-bar wallet switcher |
| `.actionCircle`     | `.contextualImpact(.commit)` — same weight as `.primary` (committing to a flow); Send / Receive / Swap on wallet home |

These bindings are the default; future components that need a different
haptic per state can override by composing `.uniHaptic(...)` themselves.

The `.toolbarPill` and `.actionCircle` variants were added 2026-06-08
alongside the Liquid Glass hit-test fix (see Rule #19 §D). Their
addition followed the protocol: name the meaning, wire the
`defaultHaptic`, wire the `VariantStyle`, document here, log in
`SHIPPED.md`.

### Part F — Workflow gate

Before any new interactive surface is committed:

1. Does this surface use `UniButton`? If yes, haptic is automatic — skip.
2. Is it a Toggle? Use `UniToggle`, not bare `Toggle` — the wrapper fires `.toggle` per the handoff. Bare `Toggle(isOn:)` is forbidden outside the DesignSystem layer (Part H).
3. If neither, did you apply `.uniHaptic(_:trigger:)` to the state change?
4. Did you pick a semantic case from the canonical vocabulary (Part G) — not just `.selection` reflexively?
5. Did you check the user preference path works (toggle off → silent)?

### Part G — The canonical vocabulary (2026-06-10 — design handoff)

The `/Users/thuglifex/Downloads/design_handoff_haptics/` package
defines **12 patterns in 4 groups** as Aperture's tactile language.
Every haptic the app fires must map to one of these. Adding a new
pattern requires updating this rule + adding a `UniHaptic` case.

**Feedback (3)** — touch acknowledgement:
- `tap`         → `.contextualImpact(.tap)`        → key presses, primary button presses
- `select`      → `.selection`                     → picker, segmented control, amount stepper
- `toggle`      → `.toggle`                        → on/off switches; rigid weight, fired by `UniToggle`

**Impact (3)** — physical collisions / weight:
- `impactLight`  → `.contextualImpact(.whisper)`   → sheet detent snap
- `impactMedium` → `.contextualImpact(.commit)`    → card commits, logo settles
- `impactHeavy`  → `.contextualImpact(.weighted)`  → big deliberate confirmations

**Outcome (3)** — result of an action:
- `success` → `.success`     → confirmed transaction, swap, refresh
- `warning` → `.warning`     → "read this before you continue" double-pulse
- `error`   → `.error`       → failed / rejected action; frustration-silenced after 3-in-10s (§J)

**Signature (3)** — Aperture's bespoke AHAP patterns; brand-only moments:
- `irisSettle` → `.signature(.irisSettle)` → splash → home, pull-to-refresh complete
- `sendWhoosh` → `.signature(.sendWhoosh)` → swipe-to-send release
- `countUp`    → `.countUp`                → per-digit ticker as balance hero animates

Plus the existing Aperture-specific signatures kept from the prior
catalog (`walletSealed`, `phraseRevealed`, `phraseRegenerated`,
`pinSealed`, `transactionSigned`, `transactionConfirmed`) — these
are wallet-creation / security moments the handoff doesn't cover.

### Part H — Forbidden (extended 2026-06-10)

The original Part D bans remain in force. Additions:

- **`Toggle(isOn:)` in feature code.** Use `UniToggle` — it fires
  the canonical `.toggle` haptic for free. Bare `Toggle` is allowed
  ONLY inside `UniToggle.swift` and inside DesignSystem-layer
  components that wrap it. Grep target for the audit:
  ```bash
  grep -rnE 'Toggle\(isOn:|Toggle\("' UniApp/Sources/Features/
  ```
  Expected: zero hits in feature code (every interactive Toggle is
  a `UniToggle`).
- **Custom haptic calls bypassing the vocabulary.** Every haptic
  fires through `UniHaptic` and lands on one of the 12 handoff
  patterns. Inventing a per-screen impact weight without naming a
  case is forbidden.

### Part I — Pull-to-refresh and splash → home

Two specific surfaces own `irisSettle`:

- **Splash → home transition** (UniAppApp.swift's `onSplashComplete`):
  `UniHapticEngine.shared.play(.signature(.irisSettle))` fires as
  `isShowingSplash` flips to false. Replaces the prior raw
  `UIImpactFeedbackGenerator(.medium).prepare()` warm-up — the
  prepared generator never actually fired the haptic; the
  signature plays correctly.
- **Pull-to-refresh complete** (WalletHomeView.swift's `runRefresh`):
  Same call at the END of refreshWallet — soft tick → medium tap
  marks the moment data has landed.

### Part J — Frustration silencing (existing — kept)

`UniHapticEngine` records every `.error` haptic timestamp. After
3 errors within 10 seconds, the next 2 errors fire silently. The
user has already received the signal; further buzzing reads as
mockery. State resets after 10s of no errors.

---

## Rule #11 — RTL is automatic. Layout direction is bound once, at the app root. Never per-screen.

UniApp supports two RTL languages today (`ar`, `fa`) and may add more. When
the user picks an RTL language in Settings, the entire app must flip to
right-to-left **live, without restart**. Conversely, when they pick an LTR
language, every screen flips back. This is achieved with one environment
binding at the app root — and every screen must be written so it Just Works
under that binding.

---

### Part A — The single binding

`UniAppApp.swift` applies, at the `WindowGroup`'s root view:

```swift
.environment(\.locale, LanguagePreference.locale(for: languageCode) ?? .current)
.environment(\.layoutDirection, LanguagePreference.layoutDirection(for: languageCode))
```

`LanguagePreference.layoutDirection(for:)` resolves the stored code to
`.leftToRight` or `.rightToLeft`. For `systemCode`, it defers to
`Locale.current.language.characterDirection` so iOS retains the choice
when the user picks "System".

This is the **only** place in the codebase that sets
`\.layoutDirection` for layout purposes. The single binding propagates
through SwiftUI's environment to every descendant view — current and
future. No screen needs to know it's in RTL; it just is.

### Part B — How to write a screen that respects this rule

**Use semantic edges, never absolute ones:**

| ✅ Allowed (semantic)            | ❌ Forbidden (absolute)         |
|----------------------------------|--------------------------------|
| `.leading` / `.trailing`         | `.left` / `.right`             |
| `.padding(.leading, …)`          | `.padding(.left, …)`           |
| `Alignment.leading`              | `Alignment.left`               |
| `HorizontalAlignment.leading`    | `HorizontalAlignment.left`     |
| `Edge.Set.leading`               | `Edge.Set.left`                |
| `HStack(alignment: .firstTextBaseline)` (no horizontal direction baked in) | manual `.offset(x: 16)` to push content left |

**Symbols and direction:**
- SF Symbols that represent direction (`chevron.right`, `arrow.right`,
  `arrow.up.right`, etc.) **automatically mirror in RTL** when used with
  default symbol rendering. Use them as-is.
- A symbol that should *not* mirror (a chart, a logo, the Bitcoin `B`,
  brand marks) — apply `.flipsForRightToLeftLayoutDirection(false)` to
  opt out of the auto-mirror.
- Custom `Path` / `Canvas` arrows (we do not have any per Rule #7) would
  need manual handling; we don't ship any, so this is moot.

**`HStack` ordering — DO NOT manually reorder:**
- An `HStack { Icon; Title; Spacer(); Chevron }` reads `Icon Title … Chevron`
  in LTR and `Chevron … Title Icon` in RTL. SwiftUI swaps the order
  automatically. **Never** reverse the children manually to "fix" RTL —
  that double-flips and breaks RTL.

**Text alignment:**
- `.multilineTextAlignment(.leading)` and `.trailing` honor reading
  direction. Use these, not `.left`/`.right`.

**RTL-aware per-text overrides (the only allowed local exception):**
- A `Text` that renders content **whose script is opposite of the
  surrounding flow** (e.g., a Persian self-name rendered inside the
  English picker row) may locally override `\.layoutDirection` so the
  text aligns correctly within its own row. This is rare and is the only
  exception to "no per-screen override." Example already in the codebase:
  the `LanguagePickerView` row that shows each language's native name.

### Part C — Forbidden

- **Setting `\.environment(\.layoutDirection, …)` anywhere other than
  `UniAppApp.swift`.** Allowed exceptions, each scoped to the smallest
  possible subtree:
  - Part B's per-`Text` override for a self-name rendered against the
    opposite-direction flow.
  - **Display-only English content (recovery phrase grid, derived
    addresses display, transaction hash readouts, anything the user
    READS but does not type)** must force LTR via `.environment(\.layoutDirection, .leftToRight)`
    scoped to the grid / row / cell subtree. Rationale: English BIP-39
    words / hex addresses / hashes have a strict ordinal reading order
    that the user transcribes. RTL would silently flip the grid (position
    1 to top-right, 2 to top-left) and the user would write the phrase
    down in the wrong order. The chrome around the grid (title, body,
    toolbar) stays in ambient direction so the screen still reads as
    Arabic / Hebrew where appropriate. This is the most common case in
    Aperture and the safest default for English-content display.
  - **Interactive text input controls** follow the **ambient app
    direction** by default — in an RTL app the empty placeholder is
    right-aligned and the cursor starts on the right (matching iOS
    Notes, Safari address bar, etc.). Once the user begins typing
    English BIP-39 words / private keys / addresses, the Unicode BiDi
    algorithm renders each English string as an LTR "island" inside the
    line's alignment — this is the iOS-native pattern and is what users
    expect. The `UniTextField` primitive's `TextDirection.Policy`
    (`.automatic` / `.forceLTR` / `.ambient`) selects between policies
    at the call site. The two transparent-`TextEditor` sites
    (`MnemonicEntryView` in `MnemonicImport.swift`, `WatchOnlyEntryView`
    in `WatchOnlyImport.swift`) do NOT force LTR — they follow ambient
    so the empty/placeholder state matches the user's locale. (Prior
    shipping forced LTR on the mnemonic editor; user feedback 2026-06-06
    on RTL device confirmed the forced-LTR placeholder broke the mental
    model of "typing into the field on the right side".) Per Rule #19's
    "one canonical primitive" principle, new text input surfaces use
    `UniTextField` and do NOT hand-roll `\.environment(\.layoutDirection, …)`
    overrides.
  - Rule #17 Part I — `PinCodeView`'s body root (PIN entry is LTR +
    English in every locale).
- **Using `.left`, `.right`, `.padding(.left:)`, `.padding(.right:)`,
  `Alignment.left`, `Alignment.right`** anywhere in feature code. Grep
  for these before any commit.
- **Manually reordering `HStack` children** based on a check for the
  user's language — SwiftUI does this for you.
- **Hardcoded `.offset(x: 16)` or `.offset(x: -16)`** for layout. Use
  `.padding(.leading, …)` / `.padding(.trailing, …)` instead.
- **Detecting layout direction in business logic** (`@Environment(\.layoutDirection)`
  reads to switch image names, copy strings, etc.). The view's *layout*
  flips; the *content* doesn't.

### Part D — Workflow gate (for every new screen)

1. **Imagine the screen in RTL.** Walk through it mentally: leading
   icons become trailing, chevrons flip, scroll indicators move. Does
   anything visually break?
2. **Grep your diff** for `\.left`, `\.right`, `Alignment.left`,
   `Alignment.right`, `.padding(.left`, `.padding(.right`. The expected
   count is **0**.
3. **Use `leading`/`trailing` everywhere semantic direction matters.**
4. **For arrows / chevrons / direction-bearing icons**, use SF Symbols
   that auto-mirror; do not manually flip.
5. **Test live:** with the app running, open Settings → Language →
   switch to Arabic or Persian. The current screen must flip
   immediately. Switch back to English. Repeat with the screen you just
   built.

### Part E — Testing checklist for every PR that adds a screen

- [ ] Screen renders correctly in LTR (English).
- [ ] Screen renders correctly in RTL (Arabic OR Persian — pick one).
- [ ] Language switch from LTR → RTL → LTR happens live (no restart).
- [ ] Direction-bearing icons mirror correctly.
- [ ] Brand marks and tickers (`UniApp`, `BTC`, `iPhone`, `Face ID`)
      do **not** mirror.
- [ ] Text alignment uses `leading` / `trailing`, never `left` / `right`.

### Part F — Why this rule exists

- **One source of truth.** Layout direction is a system concern. The
  user's language preference owns it; one binding propagates it.
- **No screen-by-screen RTL work.** As we add wallet home, send,
  receive, swap, settings sub-screens, etc., they inherit correctness
  for free — provided they obey Part B.
- **No restart.** The original Apple pattern (set in Info.plist or
  CFBundlePreferredLanguages) requires an app relaunch. Our binding
  flips live; that's a significantly better UX, and the technical cost
  is one line.

---

## Rule #12 — Every presentation surface applies `.uniAppEnvironment()`.

`.preferredColorScheme(_:)` does not propagate into modal presentations
(`.sheet`, `.fullScreenCover`, `.popover`) on iOS — those get their own
window-equivalent scope. Locale and layout direction do propagate as
standard environment values, but for consistency we treat all three
preferences as a single bundle.

There is **one** view modifier — `.uniAppEnvironment()` — that applies all
three: `themePreference`, `languagePreference` (`\.locale`), and the
derived `\.layoutDirection`. It must be applied at **every presentation
surface root**:

1. The `WindowGroup`'s top-level content view (only place in `UniAppApp.swift`).
2. The content view of every `.sheet { … }`.
3. The content view of every `.fullScreenCover { … }`.
4. The content view of every `.popover { … }`.
5. The content view of any future detached `UIWindow` (e.g., a CarPlay or
   widget host).

Without `.uniAppEnvironment()` on a sheet, switching dark/light mode while
the sheet is presented leaves the sheet stuck on the previous scheme — a
visible bug.

---

### Part A — The modifier (the only allowed pattern)

```swift
// File: UniApp/Sources/Settings/UniAppEnvironment.swift
extension View {
    func uniAppEnvironment() -> some View {
        modifier(UniAppEnvironmentModifier())
    }
}

struct UniAppEnvironmentModifier: ViewModifier {
    @AppStorage("themePreference")    private var themeRaw: String = ThemePreference.light.rawValue
    @AppStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode

    func body(content: Content) -> some View {
        content
            .preferredColorScheme((ThemePreference(rawValue: themeRaw) ?? .light).colorScheme)
            .environment(\.locale, LanguagePreference.locale(for: languageCode) ?? .current)
            .environment(\.layoutDirection, LanguagePreference.layoutDirection(for: languageCode))
    }
}
```

### Part B — Required call sites

```swift
// WindowGroup root
WindowGroup {
    OnboardingView()
        .uniAppEnvironment()
}

// Every sheet — REQUIRED
.sheet(isPresented: $isShowingSettings) {
    SettingsView()
        .uniAppEnvironment()
}
```

### Part C — Forbidden

- Calling `.preferredColorScheme(_:)`, `.environment(\.locale, …)`, or
  `.environment(\.layoutDirection, …)` directly in feature code. The
  `.uniAppEnvironment()` modifier is the only allowed surface for these.
  Exception: the per-`Text` `\.layoutDirection` override in
  `LanguagePickerView` for right-aligning native names (carryover from
  Rule #11 Part C).
- Reading `@AppStorage("themePreference")` / `@AppStorage("languagePreference")`
  in a feature view to manually re-apply the preferences. Use the modifier.
- Creating a sheet without `.uniAppEnvironment()` on its content view.

### Part D — Workflow gate

For every new screen that presents a sheet / fullScreenCover / popover:

1. Did you apply `.uniAppEnvironment()` to the presented content's root?
2. Test: while the new presentation is up, change appearance in Settings.
   Does the presentation update? If not, you missed step 1.
3. Same test for language switch (locale + layout direction propagation).

### Part E — Why this rule exists

- **One bug, one fix.** Rather than chase color-scheme-stuck bugs across
  every sheet site, we make the rule explicit and the modifier obvious.
- **Future-proof.** When iOS adds new presentation surfaces, the contract
  is already named: they need `.uniAppEnvironment()`.
- **Honest visibility of state.** Rule #1 keeps the truth in code, not in
  cached presentation contexts.

### Part F — Sheets must rebuild content on preference change

Even with `.uniAppEnvironment()` re-applied inside the sheet, iOS holds
on to the `UIHostingController`'s `semanticContentAttribute` from the
moment the sheet was presented. A mid-flight `\.layoutDirection` change
does NOT cause iOS to flip the host's layout-direction attribute — the
result is the bug observed on 2026-06-04: switching language from Arabic
back to English inside the open Settings sheet left Latin labels rendered
in a flipped/reversed state because the sheet's host was still locked to
RTL semantics.

The fix is a `.id(_:)` binding on the sheet's content view, keyed to the
relevant preferences. When the user changes language or appearance while
a sheet is open, the `.id()` value changes → SwiftUI throws away the
existing content view tree and rebuilds it from scratch → the new tree
inherits the *current* environment values from the start. The sheet
itself stays presented (the parent's `@State` is unaffected); only the
content is rebuilt.

### Part G — Required pattern (key ONLY on layout direction)

```swift
@AppStorage("languagePreference") private var languageCode: String = LanguagePreference.systemCode

/// Direction-only `.id` key. Theme changes and same-direction language
/// changes propagate through `.uniAppEnvironment()` without a rebuild,
/// so any pushed sub-picker (Appearance / Language / Currency)
/// preserves its navigation state across those changes. Only crossing
/// the LTR ↔ RTL boundary triggers the rebuild — the one case iOS's
/// locked `semanticContentAttribute` actually requires it.
private var sheetDirectionKey: String {
    LanguagePreference.layoutDirection(for: languageCode) == .rightToLeft ? "rtl" : "ltr"
}

// In the presenting view's body:
.sheet(isPresented: $isPresented) {
    SomeContentView()
        .id(sheetDirectionKey)     // ← rebuild ONLY when LTR/RTL flips
        .uniAppEnvironment()       // ← re-apply preferences inside the sheet
        .presentationDetents([.medium, .large])
}
```

The order matters slightly: `.id(_:)` first, `.uniAppEnvironment()`
second. This way the rebuilt content (if rebuild happens) immediately
picks up the new environment values.

**Why direction-only and not full preferences:** an earlier version of
this rule (and an earlier implementation in `OnboardingView`) keyed the
`.id` on `"\(languageCode)|\(themeRaw)"`. That worked for the RTL flip
bug but introduced a regression: every preference change — even Dark
vs Light, even English → Spanish — invalidated the sheet's view tree
and popped the user out of whatever sub-picker they were standing in.
The honest fix is to scope the rebuild to the *only* case where iOS
actually requires it: a direction flip. Everything else flows through
SwiftUI's reactive environment propagation.

**Preserved nav state across rebuilds (delivered 2026-06-04):** the
`NavigationPath` of any sheet whose content uses `.id(...)` MUST be
hoisted to the presenting view's `@State`. The picker views inside
the sheet use **value-based** `NavigationLink(value: Destination.x)`
plus a single `.navigationDestination(for: Destination.self) { … }`
on the root, so the path encodes the route, not the instantiated view.
On rebuild, the rebuilt `NavigationStack` reads the preserved path and
re-pushes the same destination. The user stays exactly where they
were — even across direction flips. Reset the path in the sheet's
`onDismiss` so the next presentation starts at root.

Same pattern applies to `.fullScreenCover { … }`, `.popover { … }`, and
any future presentation surface that hosts its content in a separate
`UIHostingController` / window-equivalent scope.

### Part H — Forbidden additions

- Skipping the `.id(_:)` on a sheet content. The `.uniAppEnvironment()`
  modifier alone is insufficient to fix the RTL/LTR flip bug.
- Using `.id(UUID())` or other unstable values — those rebuild *every*
  body evaluation, which is wasteful. The id MUST be derived from the
  preference values so it only changes when those values change.
- Reading `@AppStorage` for preferences inside the sheet's content
  closure to compute the id locally — read it on the *presenting* view
  so the parent's body knows when to invalidate the sheet content.

---

## Rule #13 — RETIRED 2026-06-12 per user direction. English keys only until the app is finished.

**The user retired the per-edit translation requirement on 2026-06-12**:

> *"remove the rule that push the agents to translate to all languages,
> and instead replace it with a rule to only add the english keys for
> all future new strings, and later on we'll translate them all to all
> languages once we finish the app."*

Effective immediately:

- **New user-facing strings get an ENGLISH catalog entry only.** The
  scanner + catalog-writer stages (Rule #20, stages 1–2) still run after
  string-bearing edits so `Localizable.xcstrings` never drifts from the
  code — but the entry carries just the English source `stringUnit`.
- **Do NOT dispatch `translator-primary` / `translator-secondary` /
  `aperture-i18n-translator-*` after edits.** No per-session translation
  fanout, no "translated entry for every language before the session
  ends" gate. Untranslated cells for new keys are EXPECTED state, not
  drift.
- **The 50-language catalog that already exists stays as-is.** Existing
  translations are not deleted; they keep working at runtime. New keys
  simply render their English source in every locale until the final
  pass.
- **One full translation pass happens at app completion**, on explicit
  user request — at that point the translator agents sweep every key
  whose non-English cells are missing/new/stale, exactly as they did
  for the 2026-06-12 backlog closures.
- The session-end audit (old Part D below) and the "no session ends
  with untranslated strings" gate are inert. The audit hook reports
  untranslated cells as informational only.
- Rule #9's authoring contract is UNCHANGED: every user-facing string
  is still a localizable `Text("...")` / `String(localized:)` literal
  (never `Text(verbatim:)` for UI copy). Only the translation *fanout*
  is deferred — never the localizability of the source.

---

## Rule #13 (original, RETIRED) — Translations run after every edit. No session ends with untranslated strings.

Whenever any agent (main, `jony-ive`, or anyone else) introduces a new
user-facing English string to `UniApp/Resources/Localizable.xcstrings`, or
edits an existing one (which sets the other-language entries' state to
`"stale"`), the two translator agents — `translator-primary` and
`translator-secondary` — **must run before the session is declared
complete**. The catalog must, by the end of every session, contain a
`"translated"` entry for **every** supported target language for **every**
source key.

This rule strengthens Rule #9: that rule defines the i18n contract;
this rule defines the execution discipline that enforces it.

---

### Part A — When the translators must run

Mandatory translator runs are triggered by any of these events within a
session:

1. A new source key is added to `Localizable.xcstrings` (manually by the
   main agent, automatically by Xcode auto-extraction from code, or by a
   subagent doing visual work).
2. An existing English source `value` is rewritten (e.g., Jony refines a
   slide title; this marks all other languages' entries as `"stale"`).
3. A string-bearing code edit lands and the PostToolUse hook
   (`.claude/hooks/check-new-strings.sh`) appends to
   `.claude/translation-queue.log`.
4. The catalog gains a removed key — *no* translator run needed; deletion
   doesn't require fanout.

### Part B — Who fires the translators (background, sequential)

The **main (orchestrating) agent** is responsible for firing the two
translator agents. Subagents (including `jony-ive`) do **not** fire
translators themselves — sequential coordination of two file-mutating
agents on a shared catalog is the orchestrator's job to avoid races.

**Updated 2026-06-04**: translator runs are now executed via
**`run_in_background: true`**, so the main agent does not block on
their completion. The catalog-file race is avoided by **chaining
sequentially**: `translator-secondary` is spawned only after
`translator-primary`'s completion notification arrives.

Required pattern:

```
// Turn N — main agent has just landed string edits. Spawn primary in background.
Agent({
  subagent_type: "translator-primary",
  description: "Translate new/stale strings — primary set",
  run_in_background: true,
  prompt: "..."
})
// Main agent responds to user immediately. translator-primary runs out-of-band.

// Turn N+1 — main agent is notified of translator-primary's completion.
//            Main agent now spawns translator-secondary in background.
Agent({
  subagent_type: "translator-secondary",
  description: "Translate new/stale strings — secondary set",
  run_in_background: true,
  prompt: "..."
})

// Turn N+2 — main agent is notified of translator-secondary's completion.
//            Now run the Part D audit and update SHIPPED.md / TODO.md /
//            MISTAKES.md as needed for the translation pass.
```

**Foreground is still allowed** for translator runs when the main agent
is at a natural pause and there's no other work to do — but the
user-facing pattern is background by default so the user is never
blocked on translation. The serialization rule (primary → secondary,
NEVER concurrent) is preserved either way: two file-mutating agents on
the same `Localizable.xcstrings` file would race; the chain is required.

**Why not parallel:** even when both agents only write to their assigned
languages, a parallel write race exists because each agent does a
read-modify-write of the entire JSON file. Whichever writes last
clobbers the other's diff. Sequential coordination is mandatory until
we move to a per-language file structure (deferred — `.xcstrings` is
the canonical iOS format, not for us to fragment).

### Part C — Subagent obligations

When `jony-ive` (or any subagent) introduces or modifies catalog strings
during its work, it MUST:

1. Mark new entries `extractionState: "new"`.
2. Mark edited entries (when their English source `value` changes)
   `extractionState: "stale"` on every existing non-English `localizations.<lang>` block.
3. Report back to the orchestrator in its final response: "I introduced
   N new source strings and modified M existing strings — translators
   must run before this session is complete."
4. **Not** invoke the translators itself.

### Part D — Session-end audit

Before any session is declared complete, the main agent runs this audit:

```bash
python3 -c "
import json
d = json.load(open('UniApp/Resources/Localizable.xcstrings'))
TARGETS = ['es','zh-Hans','zh-Hant','hi','ar','pt-BR','bn','ru','ja','de',
           'fr','ko','it','tr','vi','th','id','fa','pl','nl']
missing = []
for key, entry in d['strings'].items():
    if entry.get('shouldTranslate') is False:
        continue
    locs = entry.get('localizations', {})
    for lang in TARGETS:
        unit = locs.get(lang, {}).get('stringUnit', {})
        if unit.get('state') != 'translated' or not unit.get('value'):
            missing.append((key, lang))
print(f'Missing: {len(missing)}')
for k, l in missing[:50]:
    print(f'  {l}: {k!r}')
"
```

If the output is `Missing: 0`, the session can ship. If anything is
missing, fire the translator agents and re-run the audit.

### Part E — Forbidden

- **Declaring a session "done" with `"new"` or `"stale"` source keys
  still in the catalog.** This is a violation comparable to a build
  failure.
- **Subagent firing of translators.** Race risk on the catalog file.
- **Parallel firing of `translator-primary` and `translator-secondary`.**
  Race risk on the catalog file. They must run sequentially.
- **Skipping a language because "no users speak it yet."** If a language
  is supported (in `LanguagePreference.all`), every visible string must
  have a translated entry for it.

### Part F — Workflow

A typical session that touches strings now looks like:

1. User asks for a feature.
2. (If design work) Main delegates to `jony-ive`. `jony-ive` edits views and adds catalog entries marked `"new"`. Reports string-edit count back.
3. Main fires `translator-primary` (foreground, await).
4. Main fires `translator-secondary` (foreground, await).
5. Main runs the Part D audit.
6. If the audit is clean, main builds + installs + appends to `SHIPPED.md`.
7. If the audit is dirty, main loops to step 3 with the missing entries.

---

## Rule #14 — Search uses native iOS 26 default placement. Never override.

Every search field in UniApp is `.searchable(text:)` applied to a
`NavigationStack`'s content with **no `placement:` argument**. On iOS 26
iPhone, the platform default renders this as a floating Liquid Glass
container at the bottom of the screen — within thumb reach, in the new
design system. On iPad and macOS, the same code renders top-trailing
in the toolbar. The platform owns the placement decision based on the
device's size class; we do not override.

This rule was accepted by the user on 2026-06-04 after the design
shipped on `CurrencyPickerView` and `LanguagePickerView`. See
`SHIPPED.md` entry titled "Native iOS 26 Liquid Glass search on
Currency & Language pickers" for the design-research anchor and the
Apple-doc justification.

---

### Part A — The single binding (the canonical authoring pattern)

```swift
struct SomePickerView: View {
    @State private var searchText: String = ""

    var body: some View {
        List {
            // sentinel section (optional — stays visible regardless of query)
            Section { … }

            // filtered section
            Section {
                ForEach(filteredEntries) { entry in
                    Row(entry)
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: Text("Search"))
    }

    private var filteredEntries: [Entry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Entry.all }
        return Entry.all.filter { entry in
            entry.englishName.localizedStandardContains(query)
              || entry.localName.localizedStandardContains(query)
              || entry.code.localizedStandardContains(query)
        }
    }
}
```

The `prompt:` argument is optional — iOS supplies "Search" in the
user's locale automatically when omitted. We pass `Text("Search")` so
the prompt flows through our String Catalog (Rule #9) and the 20
target-language translations apply — Apple's auto-prompt is fine, but
the explicit catalog reference is auditable.

### Part B — The filter contract

- **Use `String.localizedStandardContains(_:)`.** This is Apple's
  locale-aware, case-folding, diacritic-folding comparison — `"us"`
  matches `"US Dollar"`, `"é"` matches `"Euro"` if the user's locale
  folds accents, `"ja"` matches `"Japanese Yen"` and `"日本円"` at the
  same time. Never use `String.contains(_:)` (case-sensitive, no
  folding) for human-text filtering.
- **Match against every human-relevant field on the row, not just the
  primary label.** For currencies: `englishName + code + symbol`. For
  languages: `nativeName + englishName + code`. For tokens (future):
  `displayName + symbol + tickerAliases`.
- **Trim the query** with `.trimmingCharacters(in: .whitespacesAndNewlines)`
  before filtering — stray spaces from soft-keyboard auto-suffix should
  not change results.

### Part C — Sentinel rows

Rows that represent a *sentinel* meaning, not an entry in the filtered
collection — the "System" row in `LanguagePickerView`, a future
"Recently used" or "All chains" section — live in their **own
`Section`** above the filtered section and stay visible regardless of
query. Filtering should never hide a sentinel: it's the user's
ever-available escape hatch back to default behavior.

### Part D — Forbidden

- **Hand-rolled search bars.** `HStack { Image(systemName: "magnifyingglass"); TextField(…) }`
  composed manually is a Rule #3 violation — the system provides
  `.searchable`, including focus management, dismiss behavior,
  cancel button, voice input, and the Liquid Glass treatment. Use it.
- **Specifying `placement:` in feature code.** The platform owns the
  decision. Override means the bottom-floating iPhone behavior breaks.
  Single allowed exception: `placement: .sidebar` if we ever build an
  iPad/Mac sidebar surface where Apple specifies that placement.
- **Case-sensitive filtering.** `String.contains(_:)` is wrong for
  human text. Always `localizedStandardContains(_:)`.
- **Filtering on a single field** when the row visibly displays more
  than one (e.g., filtering currencies on `code` only while the row
  shows `englishName`). The user sees the visible label and expects
  the filter to match it.

### Part E — Workflow gate

Before any new picker / list ships:

1. Did you apply `.searchable(text:)` on the `NavigationStack` content
   (not on a child view)?
2. Did you omit `placement:`?
3. Does your filter use `localizedStandardContains(_:)` against every
   human-readable field on the row?
4. Did you trim the query before comparing?
5. Are sentinel rows (if any) in a separate `Section` above the
   filtered section, unaffected by the query?
6. Did you provide a localized `prompt:` so the field's placeholder
   flows through the String Catalog (Rule #9)?

### Part F — Why this rule exists

- **One placement, one platform decision.** Apple iterates the search
  placement across iOS releases — bottom-floating in iOS 26 today,
  potentially something else in iOS 27. Letting the system decide
  means we inherit those iterations for free.
- **Accessibility for free.** `.searchable` propagates VoiceOver,
  Dynamic Type, focus management, and the system cancel-button affordance.
- **Locale-aware filtering matches user expectation.** A user typing
  in their own script (Arabic, Hindi, Thai) gets a filter that
  understands their writing system — `localizedStandardContains` is
  the canonical Apple comparison for human text.

---

## Rule #15 — Every sheet uses a native `NavigationStack` + `navigationTitle`. No manual content-top titles. No scroll on small sheets.

iOS sheets are *screens*, not dialogs. The native iOS 26 pattern is:
- A `NavigationStack` wraps the sheet content.
- The screen title lives in `.navigationTitle("...")`, **not** as a manually-placed `UniTitle` at the top of the content view.
- The title display mode is chosen for the detent: `.large` for `.large` / `.fraction(0.6)+` detents; `.inline` for `.medium` detents.
- When the user scrolls the content, the title compresses naturally into the nav bar — this is the system's behavior, free, with `.navigationBarTitleDisplayMode(.large)`.
- Primary action buttons (Save / Cancel / Done) typically live in the nav bar's `toolbar { ToolbarItem(...) }` slots — `topBarTrailing` for the primary, `topBarLeading` for cancel/close — OR at the bottom of the content as a `GlassEffectContainer` of `UniButton`s for high-stakes commits (Create wallet, Sign transaction). Per-sheet design call; the wrapping convention is non-negotiable.

Small sheets whose content fits the detent without overflow **must not** be wrapped in `ScrollView`. SwiftUI doesn't add scroll affordances unless you ask for them — but if a `ScrollView` is present, the user sees a scroll indicator on content that doesn't need it. Use a plain `VStack` for short sheets.

---

### Part A — The canonical pattern

```swift
.sheet(isPresented: $isShowing) {
    SomeSheetContent()
        .id(sheetDirectionKey)
        .uniAppEnvironment()
        .presentationDetents([.medium])           // or .large, or both
        .presentationDragIndicator(.visible)
        .presentationBackground(UniColors.Background.primary)
}

private struct SomeSheetContent: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // Plain VStack for short content — NO ScrollView
            VStack(alignment: .leading, spacing: UniSpacing.l) {
                UniBody(text: "Body copy here.")
                // ... inputs / rows / etc.
                Spacer()
            }
            .padding(.horizontal, UniSpacing.l)
            .navigationTitle("Optional passphrase")
            .navigationBarTitleDisplayMode(.inline)  // for .medium detent
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save(); dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
```

Notes:
- The `Button("Save")` uses native nav-bar text styling (it inherits accent color). Don't wrap in `.buttonStyle(.glass)` (M-002 territory).
- For long-form content (the screenshot-warning sheet's better-methods list, the disclosure sheet's 4 protection rows), use a `ScrollView` — but **with** `.navigationBarTitleDisplayMode(.large)` so the title compresses on scroll. This is the moment Rule #15 most clearly earns its keep: the scrolling sheet behaves like a real screen.

### Part B — Forbidden

- **Manual content-top titles** (a `UniLargeTitle` / `UniTitle` placed at the top of the content view). The native nav bar takes that role. The only allowed exception is if a sheet has **no nav bar by intent** (e.g., a stripped-down action sheet with system-managed chrome only) — and in that case it's not a sheet anymore in the conventional sense.
- **Wrapping short sheets in `ScrollView`**. Use `VStack` + (optionally) a trailing `Spacer()`.
- **Action buttons at the top of the content** above the title. The bar carries the primary actions, or they live at the bottom of the content. Never inline-with-title.
- **Inline `Text("Sheet Title").font(.largeTitle)`** anywhere inside a sheet's content body. That's a manual title — use `navigationTitle`.

### Part C — Workflow gate

For every new sheet:

1. Is the content wrapped in `NavigationStack`?
2. Does the title live in `.navigationTitle(...)` (not in the content body)?
3. Is the display mode appropriate for the detent? (`.inline` for `.medium`, `.large` for `.large`)
4. If the content fits the detent without overflow, did you avoid wrapping it in `ScrollView`?
5. Are action buttons in the `toolbar { … }` slots or in a `GlassEffectContainer` at the bottom?
6. Does the sheet still apply `.uniAppEnvironment()` + `.id(sheetDirectionKey)` per Rule #12 §G?
7. Does the sheet apply `.presentationBackground(UniColors.Background.primary)` for an opaque-white look in light mode (Rule #12 §F — sheets get their own scope; the parent's background doesn't reach them)?

### Part D — Why this rule exists

- **Native iOS feel.** Sheets-as-screens is the iOS 26 design language — Apple's Mail compose, Messages share, Settings detail, etc. all use NavigationStack + navigationTitle. UniApp sheets that ship with manual titles read as "an app trying to be iOS, not as iOS."
- **Scroll-title animation for free.** The title compresses into the nav bar on scroll without any code on our side. Trying to replicate this manually is wasted work and almost always reads off.
- **Accessibility for free.** `navigationTitle` is read by VoiceOver as the screen title; a manual `Text` title would need `.accessibilityAddTraits(.isHeader)` and still wouldn't trigger the screen-change announcement. The system pattern handles it.
- **Consistent toolbar action placement.** `ToolbarItem(placement: .topBarTrailing)` for "Save", `topBarLeading` for "Cancel" — every iOS user already knows this geometry. Our sheets inherit that learning.

---

## Rule #16 — Security surfaces convey safety deliberately. Every surface a user touches that involves custody, keys, recovery, signing, or biometrics must *feel* as safe as it is.

A crypto wallet's job is not merely to be secure — it is to **make the user
feel secure enough to take responsibility for their own keys.** Honesty
(Rule #2 §A.7) tells the user the truth; Rule #16 makes sure the truth
*reads* as reassurance, not as alarm or as marketing.

Every screen, sheet, modal, or surface that touches **custody** must visibly
communicate three things:
1. **What the user is protecting.** ("Your recovery phrase is your wallet.")
2. **How it is protected.** ("Generated on-device. Stored on-device. Aperture has no copy.")
3. **What the user can verify themselves.** ("Open source — read every line of how this works on GitHub.")

This rule applies whenever a reasonable user would ask "is this safe?" —
recovery-phrase screens, backup flows, send/receive sheets, sign-transaction
dialogs, biometric prompts, Settings rows that affect custody. It does NOT
apply to neutral surfaces (the language picker, the appearance toggle, the
onboarding marketing slides not involving keys).

---

### Part A — Required ingredients on a security surface

In priority order, every security-touching surface should carry at least three of the following six (more is better, up to the point of clutter):

1. **A clear security SF Symbol at hero size** — `lock.shield.fill`,
   `key.fill`, `checkmark.shield.fill`, `faceid`, `lock.iphone`, or
   `eye.slash.fill`. Tinted `UniColors.Brand.mark` (graphite/soft-white)
   for the standard case; tinted `UniColors.Status.successForeground`
   for confirmation moments; tinted `UniColors.Status.warningForeground`
   only for genuine warnings (T-013 Screenshot detection is the
   canonical warning). Avoid the alarming red (`Status.errorForeground`)
   except for true errors — overuse normalizes alarm and reduces signal.
2. **A plainly stated safety property** — one sentence that names the
   specific protection mechanism, not generic marketing. Good: "Your
   keys never leave your iPhone." Bad: "Industry-leading security."
3. **The user's role in the safety** — what THEY are doing to protect
   themselves. "Lock with Face ID." "Save your recovery phrase before
   continuing." Users feel safer when they see their own agency.
4. **Open-source verification anchor** — a tappable "Open source" badge
   or "View on GitHub" link on at least the first security-touching
   surface a user sees per session. The link goes to
   `https://github.com/devdasx/aperture`. Users feel safer when they
   can audit. The badge is restrained (small SF Symbol +
   `UniColors.Text.tertiary` text), not a marketing banner.
5. **A boundary statement of what we DON'T do** — the absence of
   surveillance/middleman is itself a safety feature. "Aperture can't
   see your funds." "No accounts. No servers. No analytics on your
   balances." These earn user trust because they're verifiable in the
   open-source code.
6. **An honest limit statement when the consequence is irreversible** —
   the user must hear the truth before they commit. "If you lose your
   recovery phrase, the funds are gone — there is no recovery."
   Restraint here matters: state the consequence once, plainly, and let
   the user feel the weight without alarm.

### Part B — Visual register for security surfaces

- **Color**: lean monochrome (brand graphite/soft-white) for the
  identity-and-protection sections. Status colors (`Status.successForeground`
  green, `Status.warningForeground` orange) used sparingly for genuine
  status moments only. **Red is reserved for real errors** — never
  decorative.
- **Typography**: `UniLargeTitle` for the safety property (it carries
  weight); `UniBody` for explanation; `UniFootnote` (`Text.tertiary`)
  for the open-source verification link. Restraint, not alarm.
- **Iconography**: SF Symbols only (Rule #7), used at hero size for the
  identity element and at row-leading size for sub-points. The iris
  brand mark (`ApertureIrisView`) may also appear on the first surface
  a user sees — it associates Aperture's identity with the safety
  property being stated.
- **Motion**: minimal. Liquid Glass on the chrome (sheet,
  `GlassEffectContainer` on CTAs). No bespoke micro-animations.
  `.symbolEffect(.bounce, options: .nonRepeating)` is allowed on the
  hero SF Symbol when the surface first appears — one beat,
  acknowledging the user is now in a security moment, no more.
- **Copy**: honest, brief, no marketing exclamation marks, no emoji in
  UI text. The voice of the LoveFrom-era Apple compliance copy —
  factual, restrained, respectful of the user's intelligence.

### Part C — Open-source verification anchor

Every session's **first security-touching surface** must carry the
open-source link, exposed via a `Button` with `Image(systemName: "lock.shield")`
+ localized text `"Open source"`. Tapping presents a Liquid Glass sheet
(per Rule #15) titled `"Open source"` containing:

- Brief explanation of why open source matters for a wallet (3-5
  sentences, honest, no marketing).
- A canonical GitHub URL: `https://github.com/devdasx/aperture`
- A `UniButton(.primary)` "View on GitHub" that opens the URL via
  SwiftUI `Link(_:destination:)` — native, no in-app browser.
- A small list of "what you can verify yourself in the code":
  - Key generation (BIP-39 entropy + checksum)
  - Seed derivation (PBKDF2-HMAC-SHA512)
  - Biometric protection (Face ID via LocalAuthentication when T-012 lands)
  - The fact that nothing is uploaded — no analytics, no telemetry, no servers

The sheet is reusable. Both onboarding's welcome slide AND every future
custody surface (send/receive/sign/Settings.security) can present it.
A single `OpenSourceSheet.swift` view; multiple call sites.

### Part D — Surfaces this rule applies to (and the audit per-surface)

| Surface                              | Required ingredients (Part A) | Notes                                                  |
|--------------------------------------|-------------------------------|--------------------------------------------------------|
| Onboarding slide 1 (Welcome)         | #2, #4 (open-source anchor)   | First surface a user sees — set the tone                |
| `CreateWalletDisclosureSheet`        | #1, #2, #3, #6                | Already does #2 + #6; needs hero icon + role statement |
| `RecoveryPhraseView`                 | #1, #2, #3, #4                | The most consequential surface in the app              |
| `PassphraseSheet`                    | #2, #3, #6                    | Honest about "not stored, cannot be recovered"         |
| `BackupVerifyView`                   | #1, #2, #3                    | Reinforces that user has earned their wallet           |
| `WalletReadyView`                    | #1, #5                        | Calm congratulation, anchor to "no servers"            |
| `ScreenshotWarningSheet`             | #1, #2, #6                    | Warning, not error — `Status.warningForeground`        |
| Future Settings → Security row       | #1, #2, #3, #4, #5            | The auditable home of safety affordances               |
| Future Send / Receive / Sign sheets  | #1, #2, #3                    | Restate self-custody at the moment of commitment       |

### Part E — Forbidden

- **Marketing-class safety claims.** "Industry-leading," "Bank-grade,"
  "Military-grade encryption," "World's safest" — all forbidden. They
  read as marketing, they're impossible to verify, and they erode
  trust. State what you actually do.
- **Decorative shields, locks, badges** that don't correspond to a real
  protection mechanism. If a `lock.shield.fill` is on screen, the user
  must be able to point to what it locks.
- **Hiding the consequence of irreversibility behind soft language.**
  "Be careful — you might lose access" is dishonest. "If you lose it,
  the funds are gone" is the honest form.
- **Alarming red as decoration.** Reserve `Status.errorForeground` for
  real errors. Reserve `Status.warningForeground` for real warnings
  (screenshot detection is the canonical example).
- **Pretending to be a server you're not.** "Aperture protects your
  funds in the cloud" — forbidden, because we don't, and saying we do
  would be the most damaging lie a wallet can tell.

### Part F — Workflow gate

Before any new security-touching surface is committed:

1. Which three (or more) of Part A's six ingredients does it carry?
2. Does it carry an open-source anchor — either directly, or by virtue
   of being a sub-screen of one that does?
3. Is every safety claim verifiable in the open-source code? (If a user
   reads `CLAUDE.md` Rule #16 §C, can they find the file that
   implements the claim?)
4. Is the visual register restrained — monochrome brand colors, no
   alarming red as decoration?
5. Does the copy land honest, brief, and verifiable?
6. Is the screen logged in `SHIPPED.md` per Rule #1 with a per-rule
   audit including Rule #16?

### Part G — Why this rule exists

Self-custody is a transfer of responsibility. The user must take that
responsibility on willingly — and that requires they feel safe taking
it on. A wallet that is *technically* secure but *visually* alarming or
confusing fails. A wallet that is *visually* reassuring but technically
weak fails worse. Rule #16 closes both gaps simultaneously: every
security surface communicates the truth of the protection (Rule #2's
honesty), in the visual register of Apple-class care, with the
open-source verification anchor so the user can trust the truth they're
being told.

---

## Rule #17 — One PIN component, one biometric service. Every PIN-required action goes through them.

Every surface in UniApp that asks the user for a PIN — first-time setup,
app-launch unlock, transaction confirmation, Settings → Security gating,
PIN change — uses the **same single `PinCodeView` component**, called with
a different `mode`. There is exactly one PIN UI in the app, ever. The same
applies to biometrics: there is exactly one `BiometricService` wrapper
around `LocalAuthentication`, and feature code never imports `LAContext`
directly.

The PIN itself is **optional, with honest warning** — the user can skip
it at first-time setup, and a sheet names the consequence ("Your wallet
is only protected by your iPhone's lock screen"). Users who skip can
enable PIN later via Settings.

This rule has the same shape as Rules #14 (one search modifier), #15
(one sheet-as-screen pattern), and #16 (one open-source anchor):
**name the canonical primitive, forbid the variants**.

---

### Part A — The canonical `PinCodeView` API

```swift
struct PinCodeView: View {
    enum Mode: Equatable {
        /// User is setting a new PIN. On success, calls `onComplete(pin)`
        /// with the freshly-entered PIN string (digits only).
        case set
        /// User is re-entering the PIN they just set. The expected PIN
        /// is captured in the associated value. On match, calls
        /// `onComplete(pin)`; on mismatch, the dots flash + clear and
        /// the view stays in confirm mode.
        case confirm(expected: String)
        /// User is unlocking an existing PIN. The view calls
        /// `PinCodeStorage.verify(pin)` internally; on success, calls
        /// `onComplete(pin)`; on failure, the dots flash + clear.
        case verify
    }

    let mode: Mode
    /// Fires with the PIN the user entered (or empty string for verify
    /// mode, since the storage layer holds the hash, not the plaintext).
    let onComplete: (String) -> Void
    /// Fires when the user taps the leading Cancel / X button.
    let onCancel: () -> Void
    /// Optional. For `.verify` mode, presents a "Forgot PIN?" affordance
    /// at the bottom of the keypad. Tapping invokes this closure (the
    /// caller decides what "forgot" means — typically a sheet explaining
    /// the user must reset the wallet via the recovery phrase).
    let onForgotPin: (() -> Void)?
}
```

The view itself owns:
- **Six dot indicators** at the top (filled / unfilled circles tied to
  the digit count of the current input).
- **A custom 12-button numeric keypad** (1–9, then 0, then Delete +
  biometric-trigger if biometrics are enabled and applicable). The keypad
  uses native SwiftUI buttons in a `LazyVGrid`, NOT `keyboardType(.numberPad)`
  with a hidden TextField — the system keyboard's number pad has retained
  digit buffers and is inappropriate for PIN entry.
- **Mode-specific localized titles**:
  - `.set` → "Set a PIN"
  - `.confirm` → "Confirm your PIN"
  - `.verify` → "Enter your PIN"
- **Mode-specific body copy** under the dots — see Part D.

PIN length is **6 digits**. Match Apple's iOS-passcode default. Don't ship
a "PIN length" preference; pick one, ship it.

### Part B — The canonical `BiometricService` API

```swift
/// Wraps `LocalAuthentication`. Feature code calls `authenticate(reason:)`
/// — never imports `LAContext` directly.
@MainActor
final class BiometricService: Sendable {
    enum BiometryType {
        case none, touchID, faceID, opticID
    }

    enum AuthError: Error {
        case unavailable      // device has no biometrics enrolled
        case userCancelled    // user tapped Cancel on the system prompt
        case authenticationFailed
        case systemError(Error)
    }

    /// Resolved at init time from `LAContext.biometryType`.
    var biometryType: BiometryType { get }
    /// `true` iff at least one biometry is enrolled.
    var isAvailable: Bool { get }

    /// Presents the system biometric prompt with the localized `reason`
    /// string. Returns `.success` if the user authenticated, `.failure`
    /// otherwise. Never throws — feature code shouldn't try/catch around
    /// biometrics; the failure modes are part of the UX.
    func authenticate(reason: LocalizedStringResource) async -> Result<Void, AuthError>
}
```

The reason string is passed through `LocalizedStringResource` so it flows
through the String Catalog (Rule #9). Apple's iOS prompt renders the reason
verbatim under the biometric glyph.

### Part C — The canonical `PinCodeStorage` API

```swift
/// Keychain-backed PIN storage. Stores a PBKDF2-SHA256 hash of the PIN,
/// never plaintext. Salt is generated once via `SecRandomCopyBytes` and
/// stored alongside the hash in the Keychain. iterations = 100,000
/// (OWASP 2023 PBKDF2-SHA256 minimum recommendation).
enum PinCodeStorage {
    /// `true` iff a PIN is currently set.
    static var hasPin: Bool { get }
    /// Set a new PIN. Overwrites any existing PIN. Returns `true` on
    /// successful Keychain write, `false` otherwise.
    @discardableResult static func setPin(_ pin: String) -> Bool
    /// Verify a candidate PIN against the stored hash. Returns `true`
    /// on match, `false` otherwise. Constant-time comparison — never
    /// short-circuits on first-byte mismatch (timing-attack resistant).
    static func verify(_ pin: String) -> Bool
    /// Remove the stored PIN. Used by Settings → Security → Disable PIN
    /// and by wallet-reset flows.
    static func clear()
}
```

**Why Keychain, not `UserDefaults` or `@AppStorage`:** Keychain encrypts
at-rest using the Secure Enclave when available. `UserDefaults` is plain
plist on disk. PIN material — even hashed — belongs in Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).

### Part D — Mode-specific copy (English source)

Each mode of `PinCodeView` shows a short body line under the dots:

- `.set` — "Choose a 6-digit PIN. You'll use it to unlock Aperture and confirm transactions."
- `.confirm` — "Enter the same PIN again."
- `.verify` — "Enter your PIN to continue."

All three strings live in `Localizable.xcstrings` and are translated for
all 50 languages.

### Part E — First-time setup flow (the only PIN flow during create-wallet)

After `BackupVerifyView` success — at the END of the create-wallet
sequence per the user's 2026-06-04 direction — push `PinSetupFlow`:

1. **Set step** — `PinCodeView(mode: .set)`. User enters 6 digits. On
   completion, push **Confirm step**.
2. **Confirm step** — `PinCodeView(mode: .confirm(expected: setPin))`.
   User re-enters. On match, save via `PinCodeStorage.setPin(_:)` and
   present the **biometric prompt**.
3. **Biometric prompt** — Call `BiometricService.authenticate(reason:
   "Enable Face ID to unlock Aperture")`. On success, set
   `@AppStorage("biometricEnabled") = true`. On failure (user cancel,
   no biometry, error) — silently leave `biometricEnabled = false`. No
   shame, no re-prompt; the user can enable it later in Settings.
4. **Skip path** — At any point during set or confirm, the user can tap
   "Skip" in the trailing toolbar. Show `PinSkipWarningSheet`:
   "Without a PIN, your wallet is only protected by your iPhone's lock
   screen. If your iPhone is unlocked, anyone with it can use your
   wallet." Two CTAs: "Set a PIN" (returns to PinCodeView) and "Skip
   anyway" (sets `pinEnabled = false`, advances to WalletReadyView).
5. After PIN + biometric resolution (or skip), push `WalletReadyView`.

### Part F — Forbidden

- **Building a second PIN UI** anywhere in the app. Settings → Change PIN,
  the app-launch lock screen, the send-transaction confirmation gate —
  all reuse `PinCodeView` with different `mode` values.
- **Storing the PIN as plaintext** anywhere — `@AppStorage`, `UserDefaults`,
  in-memory across app launches, file system. Only the salted PBKDF2
  hash, in Keychain.
- **Importing `LAContext` in feature code.** Only `BiometricService.swift`
  imports `LocalAuthentication`.
- **Auto-enabling biometrics without the user authenticating.** The
  biometric prompt must succeed (user actually authenticates with Face
  ID / Touch ID) before `biometricEnabled = true`. A user who taps
  "Don't Allow" or who has no Face ID enrolled keeps `biometricEnabled
  = false`.
- **Hiding the skip affordance.** Per the user's 2026-06-04 direction,
  PIN is optional. The toolbar's "Skip" must be visible from the moment
  the user lands on the set step.
- **Marketing the PIN as more security than it is.** A PIN protects
  against casual access while the phone is unlocked; it does NOT
  protect the recovery phrase, the seed, or funds in the
  cryptographic sense. The skip warning sheet states this honestly
  (Rule #2 §A.7 + Rule #16 §A.6).

### Part G — Workflow gate

For any new screen that asks for a PIN:

1. Does it instantiate `PinCodeView` with an appropriate `mode`?
2. Is biometrics handled through `BiometricService` (not raw `LAContext`)?
3. Is PIN material stored only via `PinCodeStorage` (Keychain + PBKDF2)?
4. If this is a brand-new "enter PIN" surface (not the create-wallet
   setup), does the user have a path to recover if they forget the PIN
   — typically by resetting the wallet via the recovery phrase?
5. Is the mode-specific copy in `Localizable.xcstrings`?

### Part H — Why this rule exists

- **One muscle memory.** Every PIN entry feels the same — same dots,
  same keypad geometry, same Face ID fallback button position. Users
  recognize the screen across contexts and feel safer because the
  affordance is consistent.
- **One audit surface.** Reviewers (and security-conscious users
  reading the open-source code) check `PinCodeView.swift`,
  `PinCodeStorage.swift`, `BiometricService.swift` — three files, the
  entirety of UniApp's local-auth posture. No hidden second
  implementation.
- **Optionality is honest.** A wallet that forces a weak PIN on a user
  who already has a strong iPhone passcode + Face ID adds friction
  without security. A wallet that warns the user about skipping but
  respects their choice respects them. The user's 2026-06-04 direction
  encodes this principle.

### Part I — Passcode keypad is LTR + English (scoped to the keypad subtree only)

Originally drafted from the user's 2026-06-04 direction ("even in RTL
languages, in the PIN code it should be LTR, and English only. but
for the alphabet it is okay if is translated to all languages.") as a
**whole-view** override. **Refined 2026-06-06** after Thuglife
Image #51 feedback: the title and body copy ("Set a passcode", "Choose
a 6-digit passcode. You'll use it to unlock Aperture and confirm
transactions.") are read-once descriptive text and benefit from
translation — they are NOT muscle memory. The keypad geometry is the
muscle memory. So the override scope tightens to **the keypad subtree
only** (dot row + 12-button keypad + inline error footnote + forgot
row). Title + body in the header follow the **ambient app locale**
and are translated to all 50 supported languages like any other UI
string.

**Why the keypad subtree IS forced.** Apple's own iOS lock-screen
passcode keypad is LTR with Western Arabic numerals in every locale.
Dialer apps, banking apps, Apple Pay — every passcode entry affordance
the user has ever touched is LTR with 0–9 in ASCII. Passcode entry is
a security gesture; muscle memory IS a security property (Rule #17
§H). A user who memorized "top-left, middle, top-right" for "1, 5, 3"
should be able to enter that passcode in any language without the
keypad reordering itself.

**Why the header is NOT forced.** A user opening the passcode screen
for the first time in Arabic wants to read "اختر رمزًا من ٦ أرقام"
(or whatever the locale-appropriate copy is) before tapping. Forcing
English on the title made the screen feel half-translated. The keypad
geometry, which is what they're about to memorize, stays the same in
every locale — that's the security-critical anchor.

**Implementation.** Wrap only the keypad-subtree group with the
overrides, NOT the body root:

```swift
var body: some View {
    VStack {
        header                                  // AMBIENT locale + direction
        VStack {                                // keypad-subtree group
            dotRow
            keypad
            inlineErrorRow
            forgotRow
        }
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.locale, Locale(identifier: "en"))
    }
}
```

- `\.layoutDirection = .leftToRight` on the keypad group flips dot-fill
  direction, keypad iteration order, and child layouts to L→R inside
  the group ONLY.
- `\.locale = Locale(identifier: "en")` on the keypad group forces
  `LocalizedStringKey` lookups *inside the group* (inline error
  footnote, "Forgot your passcode?") to the English catalog source.
- Title + body in the `header` use `LocalizedStringKey` and resolve
  via the ambient locale — they translate normally.
- Digit glyphs are `Text(verbatim: "1")` etc., so they render as
  ASCII U+0031–U+0039 in every locale (never Arabic-Indic numerals).

**Why on `PinCodeView`, not on the parent flow.** The override is the
view's contract: any caller anywhere in the app — Settings → Change
passcode, app-launch lock, transaction confirmation — gets the LTR +
English keypad automatically without having to remember to wrap the
call site. The parent flow's toolbar items ("Skip", "X close"), the
biometric-prompt step, AND the title + body copy follow normal
localization — only the keypad subtree is the carve-out.

**Forbidden.**
- Applying `.environment(\.locale, ...)` overrides at PinCodeView call
  sites. The override lives in `PinCodeView.swift` and only there.
- Applying `.environment(\.layoutDirection, ...)` on the parent flow
  to force RTL "back" inside the keypad group. The keypad's contract
  is LTR; honor it.
- Wrapping the WHOLE `PinCodeView` body with the overrides (the
  pre-2026-06-06 shape). Title + body must translate.
- Translating the digit glyphs. They are `Text(verbatim:)` and stay
  ASCII forever.

---

## Rule #18 — Every complex or unfamiliar surface ships with a guide sheet.

A crypto wallet asks the user to do things most users have never done before
— write down twelve random words, paste a hex string they were told never to
share, accept that there is no "forgot password". Aperture's design honesty
(Rule #2 §A.7) and security-surface care (Rule #16) demand that when a user
lands on such a surface, they have a way to ask "what is this?" and get a
calm, restrained, on-system answer — without leaving the screen, without
opening a browser, without reading marketing copy disguised as help.

Every surface that asks the user to do something they may not already know
how to do MUST carry a **guide sheet** — a single `UniSheet`-based modal
explaining what the thing is, what it looks like, how it's used, and what
Aperture's role in it is.

### Part A — When a guide sheet is required

A guide sheet is required if any of the following is true:

1. The surface asks the user to enter or read a cryptographic artifact
   (recovery phrase, private key, extended key, signing payload, address,
   contract data).
2. The surface presents an iOS or platform concept a first-time crypto user
   may not recognize (BIP-39, derivation path, HD account, gas, slippage,
   memo, network selection, watch-only).
3. The surface presents an Aperture concept introduced for the first time
   (PIN setup, biometric prompt, passphrase, recovery-phrase backup).
4. The surface presents a destructive or irreversible action whose name
   alone doesn't convey the consequence ("Reset wallet", "Remove account",
   "Skip backup").

If you find yourself writing copy that includes "if you don't know what
this means, …", that is the test failing — split that material into a
guide sheet.

### Part B — The canonical guide-sheet shape

A guide sheet is a `UniSheet`-based modal, presented from a small
`info.circle` button in the top-trailing toolbar of the host surface
(or from a `Button` in the surface's body when there is no toolbar).

Required structure, in order, top to bottom:

1. **Title** — a question or noun phrase the user would actually ask.
   Examples: "What's a recovery phrase?", "What's a private key?",
   "What does watch-only mean?", "Why does Aperture need a PIN?". Not
   "Recovery phrase 101", not "Help: Recovery phrases" — the form is a
   plain question.
2. **Hero SF Symbol** — one symbol at hero size, tinted
   `UniColors.Brand.mark`. Picks the same family as the host surface
   (e.g., `text.book.closed` for recovery-phrase guide; `key.horizontal`
   for private-key guide). One calm `.symbolEffect(.bounce, options: .nonRepeating)`
   on first appearance is allowed; no decorative animation beyond that.
3. **Body** — 3 to 5 short paragraphs (`UniBody`), each one focused on a
   single question:
   - **What it is.** One sentence. The technical noun in plain English.
   - **What it looks like.** A real-looking example, rendered in
     monospace inside a `UniCard`, **explicitly labeled as a public
     example** ("Example only — never type this as your real phrase").
   - **How you use it.** One or two sentences describing the user's
     gesture.
   - **What Aperture does with it.** One sentence anchoring the
     on-device, no-server property (Rule #16 §A.5).
4. **Single primary CTA** — `UniButton(title: "Got it", variant:
   .primary)`. No secondary "Learn more on the web" — the guide IS the
   learning, and Rule #3 forbids in-app browsers. If the user needs to
   audit further, the open-source anchor (Rule #16 §C) is one tap away
   from any security surface.

The guide sheet is presented intrinsic-height (`.intrinsicHeightSheet()`)
so it sizes to its content. Theme + locale propagate via
`.uniAppEnvironment()` per Rule #12; direction-key per Rule #12 §G.

### Part C — Surfaces in Aperture that require guide sheets

Required (audit + ship if missing):

| Surface                              | Guide sheet                          |
|--------------------------------------|--------------------------------------|
| `MnemonicEntryView` (Import)         | "What's a recovery phrase?"         |
| `PrivateKeyEntryView` (Import)       | "What's a private key?"             |
| `WatchOnlyEntryView` (Import)        | "What does watch-only mean?"        |
| `RecoveryPhraseView` (Create)        | "What's a recovery phrase?" (reused) |
| `PassphraseSheet` (Create/Import)    | "What's a passphrase?"              |
| `PinSetupFlow` first step            | "Why does Aperture need a PIN?"     |
| Future: Send / Receive / Sign sheets | per-surface, designed at landing time |

Not required (the surface is self-evident or carries no specialized
artifact): `ImportMethodSelectionView`, `ChainPickerView`,
`AppearancePickerView`, `LanguagePickerView`, `CurrencyPickerView`,
`OpenSourceSheet` (itself a guide).

### Part D — Voice and visual register

Same register as Rule #16 §B:

- Restrained, factual, no marketing exclamation marks, no emoji in UI
  text, no "industry-leading", no "blazing-fast".
- Lean monochrome (brand graphite/soft-white). Status colors only when
  a paragraph genuinely names a status. **No alarming red** on a guide
  sheet — guide sheets explain; warning sheets warn.
- Public-example block uses `UniCard` with monospace `UniBody`, prefixed
  by a `UniCaption(text: "Example only — never type this as your real
  phrase.", color: UniColors.Text.tertiary)` immediately above.
- The Aperture-role sentence ("Aperture only uses this on this iPhone
  to derive accounts. It never leaves your device.") is verbatim or
  near-verbatim across guide sheets — the user learns the property by
  repetition.

### Part E — Forbidden

- **Marketing copy disguised as education.** "Recovery phrases are the
  safest way to store crypto!" — forbidden. State the mechanism, not
  the promotion.
- **Tutorials longer than 5 paragraphs.** If the guide sheet can't fit
  the four questions in Part B §3 within ~5 short paragraphs, the
  feature is over-complex; simplify the feature, not the sheet.
- **In-app browsers, linked PDFs, or video walkthroughs.** Native-only
  (Rule #3). External links use SwiftUI `Link(_:destination:)` and open
  in the system browser — and only for the open-source anchor (Rule
  #16 §C), never for help docs.
- **Hiding the guide-sheet trigger.** The `info.circle` button is
  always visible on a surface that requires a guide sheet — never
  behind a long-press, never inside an "…" overflow menu.
- **Auto-presenting the guide on first visit.** The user opens the
  guide when the user wants the guide. Aperture does not interrupt.

### Part F — Workflow gate

Before any new feature surface is committed:

1. Does this surface qualify as "complex or unfamiliar" per Part A?
2. If yes, did you ship the guide sheet alongside it?
3. Is the trigger an `info.circle` toolbar button (or equivalent
   visible affordance), never hidden?
4. Does the guide sheet follow Part B's structure (title, hero,
   four-question body, one CTA)?
5. Does the example block carry the "Example only" caption?
6. Is the Aperture-role sentence present (on-device, no servers)?
7. Are new strings extracted to `Localizable.xcstrings` with
   `extractionState: "new"` per Rule #9?
8. Is the guide sheet logged in `SHIPPED.md` per Rule #1?

### Part G — Why this rule exists

A wallet that doesn't explain itself either confuses its users (bad UX)
or pretends they don't need explaining (insulting). A wallet that
explains itself with marketing copy ("the safest, fastest, most
secure!") lies. A wallet that explains itself with a calm, restrained
guide sheet — at the moment the user is about to do the unfamiliar
thing — respects the user, builds trust, and reduces the support
burden Aperture's open-source nature already keeps minimal. Rule #18
encodes the discipline.

---

## Rule #19 — Every CTA goes through `UniButton`. No hand-rolled button styling.

UniApp has one canonical primitive for actions the user *commits to*:
`UniButton`. The four variants — `.primary` / `.secondary` /
`.destructive` / `.tertiary` — cover every meaning a button can carry
in this app. A feature view that wants a CTA reaches for `UniButton`;
it does not recompose one from `RoundedRectangle` + `Text` +
`.buttonStyle(...)` inline, even when the inline version would "look
the same."

This rule is the action-surface counterpart to Rule #14 (one search
modifier), Rule #15 (one sheet-as-screen pattern), and Rule #17 (one
PIN component): **name the canonical primitive, forbid the variants**.

### Part A — The principle

`UniButton` owns three things that an inline button cannot reproduce
by copy-paste:

1. **Liquid Glass material** (Rule #2 §B.5) — `.glassProminent` for
   `.primary` / `.destructive`, `.glass` for `.secondary`, `.plain`
   for `.tertiary`. The translucency + specular + motion contract
   (Rule #3) is delivered by `buttonStyle(.glass*)`, not by a
   `.fill(UniColors.Tint.accent)`.
2. **The variant's semantic haptic** (Rule #10 §E) — fired
   declaratively via the internal trigger + `.uniHaptic(_:trigger:)`
   binding, gated by `@AppStorage("hapticFeedbackEnabled")`. Inline
   buttons have to remember to call `.uniHaptic(...)`, and they
   almost never do, and when they do they often double-fire.
3. **The disabled-state contract** — `isEnabled:` parameter, single
   `.opacity` rule, single tap-suppression rule. No per-screen
   "if `canContinue` else gray" branching at the call site.

A new variant is a system-level concern, not a feature-level one. If
a surface needs a shape `UniButton` doesn't yet express (e.g., a
`.primaryConsequential` for irreversible commits with a `.firmImpact`
haptic per Rule #10 §A), add the case to `UniButton.Variant`, wire
its `defaultHaptic` and `VariantStyle`, and document the addition in
Rule #10 §E + `SHIPPED.md`. Never invent the variant inline.

### Part B — Forbidden patterns

The following are CTA-shaped surfaces composed by hand and are not
permitted in feature code. Grep your diff against each.

| Forbidden                                                                 | Why                                                  |
|---------------------------------------------------------------------------|------------------------------------------------------|
| `Button { … } label: { Text(…).background(RoundedRectangle(…).fill(…)) }` | Hand-rolled background — bypasses Liquid Glass + haptic |
| `RoundedRectangle(…).fill(UniColors.Tint.accent)` as a button background  | Same — and reads as a solid fill, not as glass        |
| `RoundedRectangle(…).fill(UniColors.Tint.…)` behind any tap target        | Same                                                  |
| Inline `.buttonStyle(.glass)` / `.buttonStyle(.glassProminent)` in features | Bypasses `UniButton`'s haptic + isEnabled contract    |
| `.background(.ultraThinMaterial)` behind a `Text("Continue")`             | Rule #3 violation AND Rule #19 violation              |
| `.opacity(canContinue ? 1 : 0.5)` on a manually-composed button           | UniButton's `isEnabled:` handles this once, correctly |
| `canContinue ? UniColors.Tint.accent : UniColors.Background.secondary` as a fill | Disabled-state divergence — UniButton encodes it    |

Grep target for the audit:

```
grep -rnE 'RoundedRectangle.*fill.*UniColors\.Tint|RoundedRectangle.*fill.*Tint\.accent|\.buttonStyle\(\.glass' UniApp/Sources/Features/
```

Expected output: zero hits in feature code. `.buttonStyle(.glass)` /
`.glassProminent` may appear ONLY inside
`UniApp/Sources/DesignSystem/Components/UniButton.swift`.

### Part C — Allowed exceptions (non-CTA tappable affordances)

A **CTA** commits the user to a next state — submit, continue, sign,
import, delete. It is the primary action verb on a screen. CTAs go
through `UniButton`.

A **tappable affordance** is a row, cell, chip, or chrome item that
*navigates* or *selects* but does not commit. These remain legitimately
hand-composed:

- **`NavigationLink` content** — settings rows, picker rows, list
  cells. They route, they don't commit. Use `UniCard` /
  `UniFeatureRow` / list-row composition.
- **Selection chips inside a picker** — e.g., the `ChainPickerView`
  chain rows, the mnemonic suggestion strip chips. These are
  state-change affordances inside a screen, not the screen's commit
  button.
- **Toolbar items** — bare SF Symbols on a nav-bar trailing edge, per
  M-002/M-003. They use the system's `.toolbar` slots and intentionally
  inherit native nav-bar text styling.
- **Inline text links** — e.g., "View on GitHub" inside a body
  paragraph. Use `UniButton(variant: .tertiary)` when the link triggers
  an action; use SwiftUI `Link(_:destination:)` when it opens a URL.

The test: **if removing the surface breaks the user's path through the
flow, it is a CTA — `UniButton`.** If removing it merely removes an
optional shortcut or a navigation entry, it is an affordance — compose
normally.

### Part D — When to extend `UniButton`

If a new visual shape is genuinely needed:

1. State the meaning in one sentence. ("Irreversible commit — wallet
   reset, transaction sign." not "a more important-looking primary.")
2. Add the case to `UniButton.Variant`.
3. Wire its `defaultHaptic` per the Rule #10 §A vocabulary.
4. Wire its `VariantStyle` branch using only system APIs
   (`.buttonStyle(.glass*)` or `.buttonStyle(.plain)`).
5. **Wire its hit-test shape.** Every glass variant MUST apply
   `.contentShape(<the same shape `.buttonStyle(.glass*)` paints>)`
   to its label. The painted glass extends to the layout frame; the
   hit region does not — Apple's `Button` hit-tests the content's
   intrinsic bounds, not the layout-modifier frame. Without
   `.contentShape`, corners of the visible glass are dead zones (the
   2026-06-08 bug — see SHIPPED.md). The default shape is
   `Capsule()`; for circular `.actionCircle`-class variants it's
   `Circle()`; for `.rect(cornerRadius:)` glass it must match the
   same radius. `.tertiary` is exempt (no glass, label content IS
   the hit region).
6. Document the new variant + its haptic mapping in Rule #10 §E.
7. Log the addition in `SHIPPED.md`.

The current vocabulary (2026-06-08): `.primary` / `.secondary` /
`.destructive` / `.tertiary` / `.toolbarPill` / `.actionCircle`. Six
cases; each one named by meaning, not by shape.

### Part E — Workflow gate

Before any feature surface ships:

1. Every CTA is a `UniButton(...)` instance.
2. Disabled states use `isEnabled:` — never `.opacity(0.5)` on a
   composed button, never a ternary fill, never a `.disabled(...)`
   modifier outside `UniButton`.
3. Tap haptics are auto-fired by the variant — no `.uniHaptic(...)`
   modifier on the call site of a `UniButton` (it would double-fire,
   per the M-002 family of mistakes).
4. The grep in Part B returns zero hits in your diff.
5. **Hit-test invariant.** Every glass Button label (or `ShareLink`
   /  glass-effect surface that uses `.buttonStyle(...)`) carries
   `.contentShape(<the same shape the glass paints>)`. The
   canonical primitive `UniButton` does this internally for its
   variants; carve-outs (Part C: chips, keypad keys, `ShareLink`,
   etc.) apply `.contentShape` explicitly. Without this, the
   painted glass extends past the hit region and corner taps fall
   through (2026-06-08 bug). Grep:

   ```bash
   grep -rnE '\.glassEffect\(.*interactive|\.buttonStyle\(\.glass(Prominent)?\)' UniApp/Sources/Features/
   ```

   For every hit, the surrounding `Button` label MUST also carry
   a `.contentShape(...)` whose shape matches the `glassEffect`'s
   `in:` parameter (or `Capsule()` for unparameterized
   `.buttonStyle(.glass*)`).

### Part F — Why this rule exists

- **One commit gesture, one feel.** Every "Continue", every "Import",
  every "Confirm", every "Sign" lands in the user's hand with the same
  Liquid Glass material, the same shape, the same haptic. That
  sameness is the wallet's most felt trust signal.
- **One audit surface.** Reviewers (and open-source readers per Rule
  #16) read `UniButton.swift` and know they have read every CTA in the
  app. There is no hidden second implementation in some feature file.
- **One disabled-state rule.** A disabled CTA at reduced opacity with
  suppressed taps and a silent haptic — defined once, applied
  everywhere, never re-implemented incorrectly.

---

## Rule #20 — i18n loop (AMENDED 2026-06-12). Two background agents — scanner + catalog-writer — run after every editing turn that touches `.swift` or `.xcstrings`. Translators are DEFERRED until app completion.

**Amendment 2026-06-12 per user direction** (same direction that retired
Rule #13): *"only add the english keys for all future new strings, and
later on we'll translate them all to all languages once we finish the
app."* The chain shrinks from four stages to two. Stages 3–4 (the
translators) do NOT run per-turn anymore — they run ONCE, on explicit
user request, when the app is declared finished.

The original rationale stands for the surviving stages: the catalog must
never drift from the code (M-007 audit theater, M-009 self-sustaining
loop). A string in code with no catalog entry is still drift and still
gets closed every turn — in English.

### The agents (defined in `~/.claude/agents/aperture-i18n-*.md`)

Per-turn (the surviving chain):

1. **`aperture-i18n-scanner`** — scans every `.swift` file under `UniApp/Sources/`, finds string literals not yet in `Localizable.xcstrings`, writes findings to `.claude/i18n-missing.json`. Read-only on the catalog.
2. **`aperture-i18n-catalog-writer`** — reads `.claude/i18n-missing.json`, inserts each missing key into `Localizable.xcstrings` with an English source `stringUnit` ONLY. Truncates the JSON input + the legacy `.claude/translation-queue.log` on completion.

Deferred to app completion (do NOT dispatch per-turn):

3. **`aperture-i18n-translator-primary`** — 25 languages (`es zh-Hans zh-Hant hi ar pt-BR bn ru ja de uk el ro cs hu sv nb da fi he ca hr sk sl sr`).
4. **`aperture-i18n-translator-secondary`** — the other 25 (`fr ko it tr vi th id fa pl nl ur bg et lt lv is ms fil sw af ta te ml mr pa`). Runs after primary — never in parallel (shared catalog write target). When the final pass runs, use the proven anti-stall discipline: batches of ≤5 languages per agent run, one language per save, atomic writes, progress lines (see the 2026-06-12 backlog closure).

### When the loop runs

**Every turn** that creates or modifies a `.swift` file under `UniApp/Sources/` OR `Localizable.xcstrings` triggers the two-agent chain at the end of the turn, **before** the main agent declares the turn complete.

### How the main agent dispatches them

In sequence, both with `run_in_background: true`; the writer starts only after the scanner's completion notification arrives:

```
1. Agent(subagent_type: "aperture-i18n-scanner", run_in_background: true)
2. Agent(subagent_type: "aperture-i18n-catalog-writer", run_in_background: true)
```

Each prompt is short: "Honor your agent definition. Process the inputs. English source entries only — translators are deferred per Rule #20 (2026-06-12 amendment). Report back."

### Skip conditions

The chain skips when:
- The turn only modified `.md` files (`MISTAKES.md`, `SHIPPED.md`, `TODO.md`, `PROJECT_REPORT.md`, `CLAUDE.md`, `README.md`).
- The turn only modified `.claude/*` files (hooks, agent definitions, settings).
- The turn only ran builds / installs / device commands without code edits.

Any turn that edits a `.swift` file or `.xcstrings` file requires the chain. No exceptions: "I'll do it next session" is the M-007 anti-pattern and forbidden.

### Stop-hook complement

`.claude/hooks/audit-rules.sh` runs at every Stop event and prints drift to stderr + writes `.claude/rule-audit.log`. The `SessionStart` hook surfaces the log to the next session. **Drift now means only: strings in code missing from the catalog** (the Rule #9 metric). Untranslated non-English cells are informational, NOT drift — do not dispatch translators to close them. If a turn ends with catalog drift > 0 AND the two-stage chain wasn't run, the next session's main agent MUST diagnose this as an M-007 recurrence and dispatch the chain immediately.

### The final translation pass (app completion)

When the user says the app is finished and asks for translations: run stages 3–4 over every key whose non-English cells are missing/`new`/`stale`, then run the old Rule #13 Part D audit until it reports `Missing: 0` across all 50 languages. Until that day, English-only entries are the correct, expected state.

### Forbidden

- **Manually translating strings inline** instead of dispatching the agents (when the final pass runs). The specialized agents have the per-language register knowledge encoded in their definitions; the main agent has been wrong about translations 169 times in one day.
- **Dispatching the translator agents per-turn.** That is the retired Rule #13 behavior. English keys only until app completion.
- **Running primary + secondary translator in parallel** (final pass). The catalog is a shared write target. Sequential is the contract.
- **Skipping the chain on a turn that touched `.swift` files** because "the strings haven't changed." The scanner is the source of truth for what changed, not the main agent's memory.
- **Hand-editing existing non-English translations** while the deferral is in effect. The 50-language catalog that shipped through 2026-06-12 stays frozen until the final pass.

---

## Rule #21 — When the user tells you to finish without stopping, finish.

Some prompts carry an explicit "don't stop until this is done, build it production-ready, finish everything" instruction. When the user writes that — or any equivalent phrasing — the contract changes from "ship a credible slice this turn" to **"complete the entire scope before reporting back."**

### Part A — What "finish without stopping" looks like

The user has written, verbatim and on multiple occasions:

- *"do it as PLAN, plan everything, make it real 100% and professional work"*
- *"don't stop until you sure all of them works 100%"*
- *"start NOW, build all features you've told me about"*
- *"all chains/all tokens [from the spec] should be implemented in the app"*

Each of these is a **full-completion instruction**. The right shape of the answer is not "I shipped the foundation; T-XXX tracks the rest." The right shape is "every item in the spec is now wired, tested, and shipped — here is the per-item proof."

### Part B — The discipline

When you read a full-completion instruction in the user's prompt:

1. **Read every line of the source-of-truth spec** they pointed at (e.g. `SUPPORTED_ASSETS.md`, `TODO.md` entry, attached image, prior `SHIPPED.md` section). Count the items. Write the count in your plan so you and the user can both verify the scope was understood.
2. **Plan the work as a checklist of every item**, not as a "phase 1 / phase 2" deferral. If the user said "all 24 chains", the plan has 24 bullets, not 4. If the user said "all tokens in the file", the plan has every `(symbol, network)` pair the file lists.
3. **Implement every bullet**. Not the easy ones plus a TODO for the rest. The work isn't done until every bullet is shipped.
4. **Test mode / verification surfaces must also cover the full set**, not the subset you implemented first.
5. **No `// TODO:` comments in shipped code** for items the user told you to finish. If something genuinely can't ship this turn (third-party API down, missing spec data), surface it explicitly in your final reply — *"I could not ship X because Y; here is what's blocked"* — rather than burying it in a code comment.

### Part C — What this rule does NOT mean

- It does **not** mean every prompt is a full-completion prompt. Exploratory questions ("what do you think?", "should we add X?") still get a 2-3 sentence recommendation, not a 1000-line implementation. The rule activates only when the user's prompt carries the full-completion instruction.
- It does **not** override Rule #6 (delegate design to `jony-ive`). Full completion goes through the designer when the work is design — but the orchestrator's job is to make sure the designer also delivers the full set, not a slice.
- It does **not** override Rule #16 (security surfaces feel deliberate). When in doubt between speed and care on a custody surface, care wins.

### Part D — Detection

Before saying "done" on a turn that started with a full-completion instruction, re-read the user's original prompt and the source-of-truth spec. Count items implemented vs items listed. If the counts diverge, the turn is not done — keep working.

If you cannot finish in one turn for legitimate reasons (the user denied a tool, the build broke from an external cause, the prompt was genuinely ambiguous about scope), surface that to the user **before** declaring partial work shipped — give them the choice of whether to accept the partial.

This rule was added 2026-06-06 after the user reported (with `M-012`) that the Receive screen surfaced only 3 of 101 supported tokens from `SUPPORTED_ASSETS.md` despite the original ask being "implement all chains and tokens from this file." The full set was shippable; only the registry tables and per-chain token-balance adapters needed to land. Future me: when the spec is in front of you and the user says "finish it", you finish it.

---

## Rule #22 — Every editing turn ends with installing the build on the user's **Thuglife** device.

The user's primary verification surface is the iPhone called `Thuglife` (iPhone 17 Pro Max, identifier `4B521D49-9843-55CC-AFEC-19D4CF4353A6`). Saying "I'll let you verify on-device" without installing the build first is a partial completion — the user reads "edits shipped" and then has to do the install themselves, which is friction the rule exists to eliminate.

### Part A — The discipline

Every turn that edits a `.swift`, `.xcstrings`, `project.yml`, `Assets.xcassets/**`, or any other build-input file MUST end with:

1. **Run `xcrun devicectl list devices`** to see whether Thuglife is currently `connected`. If it's `unavailable` (offline, locked, not paired right now), surface that explicitly in the final reply ("Thuglife reported unavailable — install deferred until next session, or run `xcrun devicectl list devices` yourself") and skip steps 2–4. Do NOT fabricate a "build succeeded, install handed back to user" sentence; that's M-013-class drift.
2. **Build for device** using `xcodebuild -project UniApp.xcodeproj -scheme UniApp -configuration Debug -destination 'platform=iOS,id=4B521D49-9843-55CC-AFEC-19D4CF4353A6' -allowProvisioningUpdates -derivedDataPath build-device build`. The `-derivedDataPath build-device` flag keeps the device-build artifacts out of Xcode's shared DerivedData so the simulator and device builds don't fight each other; `build-device/` is in `.gitignore`.
3. **Install via `xcrun devicectl device install app --device 4B521D49-9843-55CC-AFEC-19D4CF4353A6 build-device/Build/Products/Debug-iphoneos/Aperture.app`.** Capture the returned `databaseSequenceNumber` and quote it in the SHIPPED.md entry — it's the receipt that the install actually landed.
4. **(Optional) Launch via `xcrun devicectl device process launch --device 4B521D49-9843-55CC-AFEC-19D4CF4353A6 com.thuglife.aperture`.** First-launch after a code-signature change can return the `FBSOpenApplicationServiceErrorDomain` profile-trust error; that's the normal iOS profile-acceptance gate, not a real failure. If it returns clean, great; if it returns the trust error, mention it in the final reply so the user knows to tap the app icon once to clear the trust prompt.

### Part B — What does NOT count as "installed"

- Building for simulator only. iPhone 17 simulator is fine for early diagnostic loops, but the simulator is not the verification surface. Real Liquid Glass on real ProMotion is the verification surface. **A simulator-only verification followed by "handed back to you" violates this rule.**
- Logging "BUILD SUCCEEDED" in SHIPPED.md without an `App installed:` block following it.
- Telling the user "you can install with `xcodebuild …`" rather than running the command yourself. The autonomous-execution principle from `~/.claude/CLAUDE.md` is explicit: "NEVER tell the user 'you should run X' — just run it."
- Treating a stale `unavailable` status as permission to skip. If it says `unavailable`, name the status; don't paper over it.

### Part C — Skip conditions (genuine, not lazy)

The install step is skipped when ANY of these is true (and the skip reason is named in the final reply):

- Thuglife is `unavailable` per `xcrun devicectl list devices`.
- The turn touched only `.md` files, `.claude/*` config, `MISTAKES.md`, `SHIPPED.md`, `TODO.md`, `PROJECT_REPORT.md`, `CLAUDE.md`, `README.md` — i.e. no build inputs were touched.
- The user explicitly said "don't install" / "don't build" / "skip the device this time" in their prompt.
- The build fails. In that case the orchestrator's job is to fix the build first (per `build-error-resolver`'s rationale) and then install; skipping the install while the build is red would be paving over an error.

### Part D — Why this rule exists

Repeatedly through 2026-06-06 and 2026-06-07 the orchestrator ended turns with phrases like *"Build green; on-device verification handed back to you on Thuglife"* — pushing verification onto the user even though `devicectl` was sitting right there and Thuglife was reachable. The user's 2026-06-07 correction names the pattern: "we have a rule that each time you finish editing should install the app on my device, why you don't install it." See `M-013` in `MISTAKES.md`.

The install step is also load-bearing for the SHIPPED.md per-rule audit (Rule #1): the `databaseSequenceNumber` is auditable evidence that the turn's edits actually reached the device. A turn that claims edits shipped but never installed is a turn whose claim of done is unverified.

---

## Rule #23 — REVERSED 2026-06-12 per user direction. Always commit AND push to GitHub after every editing turn. Never ask first.

**The user reversed this rule on 2026-06-12** (verbatim):

> *"always should be pushed to github, so edit the claude.md to push
> any new edits to github after each edit, and remove that it should
> ask me for it."*

This is a standing, durable authorization from the repository owner.
Effective immediately:

- **Every editing turn that changes repo files ends with `git commit`
  (conventional-commits format, per Rule #21 / common-git-workflow.md)
  followed by `git push origin main`.** No per-turn permission, no
  "say push when you want it on origin" prompts — just push.
- Group a turn's changes into one or a few **logical commits** (feat /
  fix / chore / docs scope per change), not one giant blob, when the
  turn's work spans clearly separable concerns.
- The push happens AFTER the turn's build/install obligations (Rule
  #22) so the pushed history reflects verified work. If the build is
  red, fix it first — never push a knowingly broken main.
- **Still forbidden without an explicit per-turn request:**
  `git push --force` / `--force-with-lease` (rewrites public history),
  deleting remote branches, `gh release create`, and any history
  rewrite of already-pushed commits. Those remain Part-A-class actions
  needing explicit per-turn user authorization.
- If the push fails (auth, network, non-fast-forward), surface the
  failure honestly in the final reply — never claim pushed when it
  didn't land.

---

## Rule #23 (original, REVERSED) — Never `git push` (or any remote-mutating git operation) without an explicit per-turn user request.

A `git push` is an irreversible, externally-visible action — the published commit is now part of the open-source GitHub history that other people (and the user's future self) read. Pushing without explicit per-turn authorization violates the system protocol's exact warning:

> "A user approving an action (like a git push) once does NOT mean that they approve it in all contexts."

### Part A — What requires per-turn authorization

- `git push` (any remote, any branch).
- `git push --force` / `--force-with-lease` (even worse — also rewrites remote history).
- `gh pr create` / `gh pr merge` / `gh release create`.
- Any other operation that mutates a remote (GitHub, GitLab, Bitbucket, internal mirror).
- Tagging followed by pushing the tag.

The local-only equivalents (`git commit`, `git tag` without push, `git branch`, `git stash`) do NOT require per-turn authorization because they're undoable on the user's machine alone.

### Part B — What "explicit per-turn request" means

The user typed one of these in the **current** turn's prompt:

- "push" / "push to github" / "push it" / "push the app" (and the orchestrator is sure they mean the git operation, not a generic "ship this").
- "deploy" / "publish" — when the context makes it unambiguously a remote push.
- A `/push` slash command if one ever ships.

A previous turn's "push the app to github" approval does NOT extend to:

- Subsequent commits in the same session that the user did not explicitly authorize to push.
- Commits the orchestrator made on its own initiative after the authorized commit.
- New commits after the user said "now also fix X" — the X fix is not implicitly pushable.

### Part C — Default behavior

After every commit, the default is **commit only, do not push**. Tell the user "commit `<hash>` written locally — say push when you want it on origin." That's the safe pattern.

### Part D — The 2026-06-07 incident

On 2026-06-07 the orchestrator pushed two commits to `origin/main`:

- `a902ea8` — explicit user request ("push the app to github") ✓ authorized.
- `720a910` — wallet-home tweaks. Not requested. Pushed under the assumption that the prior turn's "push" was a standing approval. That assumption was wrong; the system protocol explicitly warns against it.

The user's 2026-06-07 correction names the pattern: "add a rule also to never push to github if i don't ask you." See `M-014` in `MISTAKES.md`.

The `720a910` commit stays in history (rewriting it would be more harm than the original mis-push); the rule prevents the recurrence.

---

## Rule #24 — All balance & transaction-history fetching goes through the `aperture-chain-data` agent, which reads the real docs before every fix.

Aperture has a dedicated subagent at
[`.claude/agents/aperture-chain-data.md`](./.claude/agents/aperture-chain-data.md)
(Opus, max reasoning, with `WebFetch` + `WebSearch`). It is the **sole
authority** for how the app fetches on-chain **balances** and
**transaction history** — for every chain and token Aperture supports.

The user created it on 2026-06-13 (verbatim): *"create a fully new agent
that works only about all chains we've and tokens … let this agent read
on the internet all ethereum and EVM chains Docs, and all public node
docs, and all RPC docs, and he should always fix everything in real way
and never fix anything without reading docs on the internet for the
current fix he's doing … so always he will do only real & fast fix."*
The cause: repeated guessed balance/history fixes (e.g. sending ~40
contracts to a publicnode `eth_getLogs` call that caps the `address`
array at ~5, so received tokens showed in the balance but never in
history).

### When to delegate to `aperture-chain-data`

Delegate ANY work that touches how balances or history are fetched,
parsed, paginated, cached, scheduled, or sourced:

- The RPC layer: `RPCClient`, `RPCRegistry`, `RPCEndpoint`, `RateLimiter`.
- The chain adapters: `EVMChainAdapter`, `EVMTransactionAdapter`,
  `EVMTokenRegistry`, every per-chain `*TransactionAdapter` /
  `*ChainAdapter` / `*TokenRegistry`.
- The scanners: `RealRPCBalanceScanner`, `RealRPCTransactionScanner`.
- The scan pipeline in `WalletRefreshCoordinator` and the **app-level
  10-second auto-refresh poller** in `UniAppApp.swift`.
- Any "balance is wrong / missing", "transaction not showing", "history
  is slow", "fetch froze the app", or "add a chain/token to fetching"
  task.

### The agent's binding contract

1. **Reads the official docs online BEFORE any fix** — Ethereum JSON-RPC
   spec, publicnode docs, the specific RPC provider's docs, the chain's
   own RPC docs, ERC-20/token standard — for the exact call it changes.
   It cites the doc URL + the fact each fix relies on. **It never guesses
   an RPC method's behavior, a rate limit, a topic encoding, or a
   decimals value.**
2. **Validates live with `curl` before and after** (using the user's real
   address when given) and pastes the request/response in its report.
3. **Performance is part of correctness** — balances fan out in parallel
   (TaskGroup / promise.all), only-changed rows are written (no UI churn),
   heavy parses run off-main, the app never lags during refresh.
4. Does NOT run `xcodebuild` (the orchestrator builds + installs on
   Thuglife per Rule #22) and does NOT touch `Localizable.xcstrings` or
   `SHIPPED.md`.

### The orchestrator's job after delegation

Verify the diff, run the build + install (Rule #22), commit + push
(Rule #23), and confirm the agent cited real docs + a live test — never
accept a balance/history fix that was guessed.

### Why this rule exists

Balance and history are the wallet's most-used, most-trusted numbers, and
they sit on top of provider-specific RPC quirks (range caps, address-array
limits, required filters, per-chain endpoint shapes) that cannot be
reasoned about from memory. Binding this domain to one agent that is
*required* to read the docs and test live turns "plausible guess that
breaks in production" into "verified fact that ships correct and fast."

### Addendum (2026-06-13) — research is exhaustive and token-cost is irrelevant

Per the user (verbatim): *"it should read real RPCs docs on the internet,
and publicnode docs on the internet always, read github, developers
issues on the internet, on reddit, on stack, apple developer errors for
evm chains, etc.. and always it should read and don't care about claude
tokens or try to stop to save tokens — we don't need to save tokens, we
need to make real tests always."* The `aperture-chain-data` agent's §0
encodes this: it consults the official RPC/publicnode/chain docs **and**
the real-world developer record (GitHub issues + code search, Stack
Overflow / Ethereum StackExchange, Reddit ethdev, Apple Developer
forums for Swift/URLSession/SwiftData errors), searches the exact error
string verbatim, and runs as many live `curl` tests as it takes. It must
**never** shorten its research or skip a live test to save tokens —
correctness from real evidence is the only acceptable output.

---

## Rule #25 — Every change updates the LIVE app state. The user must never relaunch or navigate away to see it.

Anything implemented in Aperture — a balance, a transaction, a price, a
setting, a wallet add/remove/switch, a currency or language change, a
design state — **must reflect in the running app the instant it
happens.** The user must NEVER have to close-and-reopen the app, kill it,
or navigate to another screen and back to see a change. This binds **the
orchestrator AND every agent** (jony-ive, aperture-chain-data, the i18n
agents, and any future agent).

The user's direction (verbatim, 2026-06-13): *"everything implemented in
the app it should update the app state, so never we need to close the app
and reopen it to see the changes or move to another screen to see
changes… everything should always rebuild the app state."*

### What this requires

- **Reactive sources of truth.** UI reads from `@Query` (SwiftData),
  `@Observable` models, and `@AppStorage` so a write propagates to every
  observing view automatically. A value the UI shows must be backed by a
  reactive source — never a one-time snapshot captured in `onAppear` that
  goes stale.
- **Cross-context writes must become visible immediately.** When a
  background `@ModelActor` / actor repository writes, the main-context
  `@Query` must reflect it without a relaunch. SwiftData propagates
  *inserts* reliably but is unreliable for *scalar updates to already-
  materialized to-many children* — the exact trap behind the 2026-06-13
  "changed currency → \$0.00 until relaunch" bug (fixed by mutating the
  live `@Query` objects on the main context). When in doubt, write
  through the main context or force the observing view to re-read.
- **Memoized projections must be rebuilt on the change that affects
  them** — via `.task(id:)` / `.onChange` keyed on the real dependency
  (count, fingerprint, the observable's value), not only on first
  appear. A memo that only rebuilds in `onAppear` is a stale-until-
  navigate bug.
- **Presented surfaces follow Rule #12** (`.uniAppEnvironment()` + the
  direction `.id` key) so sheets/covers update with preference changes
  instead of sticking on the state captured at presentation.
- **App-level state** (the active wallet, the 10 s auto-refresh, the lock
  overlay) lives at the app root so it updates on every screen, never
  only the one that happened to spawn it (Rule #24's poller, Rule #17's
  lock).

### The workflow gate (orchestrator + every agent)

Before declaring any change done, answer: *"If the user is staring at the
screen when this fires, do they see it update — without touching
anything?"* If the only way to see the change is relaunch or navigate-
away-and-back, the change is **not done** — wire the reactive path (or
rebuild the affected projection) until the live update is automatic.

### Why this rule exists

A wallet whose numbers are right "after you reopen it" reads as broken and
untrustworthy. Live correctness is a core feature, not a nicety. This rule
elevates "the running app always tells the truth, right now" to a
standing requirement on every edit, by every actor.

---

## Rule #26 — Real fixes only. Never stop until the fix is verified working in the running app. (Orchestrator AND every agent.)

When the user reports something broken, the job is **not** to make a
plausible change and report "should be fixed now." The job is to find the
**actual root cause**, fix it, and **verify the fix works in the running
app on Thuglife** before declaring done. This binds the orchestrator AND
every agent (jony-ive, aperture-chain-data, the i18n agents, and any
future agent).

The user's direction (verbatim, 2026-06-13): *"always you need to make a
real fix and don't stop until you make it fully ready."* It follows two
earlier corrections in the same spirit — "always make a real test, never
guess a fix" (Rule #24) — and the repeated frustration that "Price
unavailable" was declared fixed and regressed.

### What "a real fix" requires

1. **Root cause, not symptom.** Trace the failure to the line that
   produces it. "Added a fallback" is not a fix if the fallback never
   triggers. When two similar things behave differently (USDT shows a
   price but BTC doesn't), **the divergence IS the clue** — find why one
   path works and the other doesn't.
2. **Verify the mechanism, not the vibe.** Where the domain allows a live
   test (a price fetch, an RPC call), run it (`curl`) and confirm the
   real value. Where it's UI/app state, build + install on Thuglife
   (Rule #22) and confirm the actual on-screen behavior changes. A fix
   you didn't watch work is a guess.
3. **Don't stop at the first edit.** If the reported behavior still
   reproduces after your change, you are NOT done. Re-diagnose, re-fix,
   re-verify until the user's exact scenario produces the right result.
4. **A regression of a previously-"fixed" bug is proof the first fix
   addressed a symptom.** Re-open the root-cause hunt from scratch; never
   re-apply a variant of a fix that already failed.

### Forbidden

- Declaring a bug fixed without verifying the user's exact reproduction
  no longer reproduces.
- "This should fix it" / "try it now" hand-offs that push verification
  onto the user.
- Papering over a symptom (a fallback, a default, a retry) when the root
  cause is reachable.
- Stopping mid-fix because it's hard. The contract is *"don't stop until
  fully ready."*

### Why this rule exists

Twice "Price unavailable" was declared fixed; twice it returned, because
each fix addressed a different code path than the one that produces the
message for native coins. A wallet that shows wrong/missing numbers — and
an agent that says "fixed" when it isn't — destroys trust faster than the
original bug. Real fix, verified live, every time.

---

## Rule #27 — Local-first. The SwiftData database is the single source of truth; the UI reads ONLY from it; the network is a writer.

Every value a screen displays — prices, balances, transactions, the
chart, addresses, UTXOs, tokens, chains/coins, settings, holdings,
historical closes, gas/fee suggestions, everything — is **read from the
local SwiftData store**, reactively (`@Query` / `@Observable`), never
from a network response held in a view. The network (RPC, price/FX APIs,
explorers) is a **writer**: a sync layer fetches and **persists to the
DB**, and the UI updates live off the DB (Rule #25). "Live" means the UI
re-renders the instant the DB changes — not the UI hitting the wire.

The user's direction (verbatim, 2026-06-13): *"the whole app … get its
data only from the database … never use live data from any rpc. so any
RPC, price APIs, etc.. should save the result in the database, and we got
it from database only, Live."*

### Part A — The three layers

1. **SYNC layer — the ONLY code allowed to touch the network.**
   The adapters + scanners + pricing engine + the `SyncCoordinator`
   (formalizing `WalletRefreshCoordinator`) fetch from the wire and
   write through the actor repositories into SwiftData. Every successful
   fetch **stamps freshness** (`SyncStatusRecord.lastSyncedAt` for its
   domain). Scheduled (foreground ~10 s poll + `BGTask` + on-appear),
   de-duplicated, backed off.
2. **STORE layer — the single source of truth.**
   SwiftData `@Model` + the actor repositories. Nothing else is
   authoritative.
3. **READ layer (UI) — reads only the store.**
   Views read via `@Query` / `@Observable`. **A view never imports or
   holds a network type** (`RPCClient`, `*ChainAdapter`,
   `*TransactionAdapter`, `TokenPricingEngine`, `CoinbasePriceService`,
   `CoinGeckoPriceService`, `FXRateService`, a raw `URLSession` for
   domain data). If a screen needs data, it reads the DB and (if stale)
   asks the SyncCoordinator to refresh — it never fetches inline.

### Part B — Freshness is honest (Rule #16)

Every synced domain carries a `lastSyncedAt`. Surfaces show a quiet,
honest stamp — "Updated 14:31 · Syncing…" — and offline shows the
last-known value + the stamp, never a blank and never a fabricated
number. A cached value must never silently masquerade as real-time.

### Part C — The carve-out: signing & broadcast still route through the DB

Some protocol actions are inherently real-time — a stale nonce / gas /
fee-rate / UTXO set loses funds or fails a transaction, and a broadcast
is a network submission, not a "read." These are handled so they STILL
go through the DB and never become a passive UI network-read:

1. **Just-in-time sync before read.** The signer reads nonce / gas /
   fee / UTXOs **only from DB rows**; immediately before signing, the
   SyncCoordinator does a blocking, targeted refresh of exactly those
   rows so the DB value is current at that instant.
2. **Outbox for broadcast.** The UI writes a **pending**
   `TransactionRecord` (+ `OutboxRecord`) to the DB; the SyncCoordinator's
   outbox broadcasts it and writes the resulting hash/status back. The
   UI watches the row go `pending → broadcast → confirmed` live.

The dApp browser's `eth_call` / `eth_sendTransaction` are the same: a
real-time request at the moment of the user's action, whose result is
persisted. No view holds the response.

### Part D — Settings & registries live in the store

- **Settings** are persisted as an `AppSettingsRecord` in SwiftData
  (migrated from the legacy `@AppStorage` keys), read via the store.
- **Chains / coins / tokens definitions** are seeded into the store
  (`ChainRecord` / `AssetRecord`) from the static registries on launch;
  the app reads the asset universe from the DB. The static registries
  become the seed source, not a parallel runtime source.

### Part E — Enforcement

Before any feature view ships, audit that it imports no network type and
fetches nothing inline. Grep target (expected empty in `Sources/Features`
read paths, except the documented Send/dApp carve-out sites):

```bash
grep -rnE 'RPCClient|TokenPricingEngine|Coinbase(Price|Historical)Service|CoinGeckoPriceService|FXRateService|EVMChainAdapter|EVMTransactionAdapter|RealRPC(Balance|Transaction)Scanner' \
  UniApp/Sources/Features --include=*.swift | grep -v 'WalletRefreshCoordinator\|SyncCoordinator'
```

Every hit must be either the SyncCoordinator wiring, a Send/dApp
carve-out site (Part C) that fetches only at action-time and persists
its result, OR the **currency-change live re-price**
(`WalletHomeView.repriceForCurrencyChange`) — a documented exception:
when the user switches currency, the prices are resolved off-main
through the pricing ladder (cache/DB-first) and then applied by
mutating the wallet's LIVE main-context `@Query` balance objects, so the
hero + rows re-denominate instantly with zero cross-context lag (the
2026-06-13 "JOD → USD showed \$0.00 until relaunch" fix). The fetch is
off-main and DB-cache-first; only the write is on-main, on the objects
the view already owns. Moving it to the background SyncCoordinator would
regress that live-update fix (Rule #26), so it stays in the view as a
named exception.

### Part F — Why this rule exists

A wallet whose numbers are right only "after you reopen it", or that
shows a cached value as if it were live, is untrustworthy. Making the DB
the one source of truth — fed by a writer-only sync layer, read live by
the UI, stamped with honest freshness — is what makes the app correct,
fast (no inline blocking fetches), offline-resilient, and honest, all at
once. It is the structural form of Rules #16, #24, #25, and #26.

---

## Rule #28 — Never block the main thread. Every action runs off-main, batches its writes, and parallelizes independent work.

The app must NEVER freeze, stutter, or drop a frame because of any
function or action. Scrolling, navigation, taps, and animations stay
responsive at all times — work happens in the background and the UI only
reacts to the result. Added 2026-06-14 after the user's direction
(verbatim): *"we'll update the whole app to use actions … in the
background so never the app will be slow because of any function or
action … and all actions should use promise.all and parallel actions so
it will be speeded up."* This generalizes the refresh-pipeline fix that
ended the pull-to-refresh freeze (off-main snapshot fetches + batched
writes) to **every** action in the app.

### Part A — The three obligations of any action

Every action (a refresh, a send, a scan, an import, a price/FX fetch, a
balance/history read, a search, an export, a QR/SVG/image decode, a
crypto/derivation step, a SwiftData read or write, a JSON parse, a file
read) MUST satisfy all three:

1. **Off the main thread.** Heavy work runs on a background executor —
   an `actor` / `@ModelActor` repository, a `nonisolated` async function,
   or `Task.detached` — NOT on `@MainActor`. The main actor is reserved
   for reading already-computed state and applying small UI updates.
   - SwiftData reads that build a snapshot create their OWN
     `ModelContext` and run off-main, returning `Sendable` values
     (the `WalletRefreshCoordinator.fetchAddressSnapshot` /
     `fetchBalanceRowSnapshot` pattern — 2026-06-14).
   - Repositories are `@ModelActor actor`s; the UI never holds a
     `ModelContext` for mutation.
   - **Forbidden:** `await MainActor.run { <heavy work> }`, a
     `@MainActor` helper that does a fetch/parse/format loop, heavy
     synchronous work in a `View` `body` / computed property / `onAppear`
     / `.task` before the first `await`.

2. **Writes are batched.** A logical operation commits to SwiftData
   ONCE (or a small bounded number of times), never once per record. Per
   `@ModelActor` save propagates to the main context and invalidates
   every observing `@Query` → a main-thread re-render PER SAVE; a loop of
   per-record saves is a UI-freezing storm (the 2026-06-14 pull-to-refresh
   bug). The pattern: mutation methods take a `save: Bool = true` flag
   (default preserves single-call callers); batch callers pass
   `save: false` and call a single `flush()` (guarded on
   `modelContext.hasChanges`) at the end of the operation.

3. **Independent work runs in parallel.** Operations that don't depend on
   each other run concurrently — `async let` for a fixed set, or
   `withTaskGroup` for a dynamic set ("promise.all"), never `await`ed one
   after another in a sequential loop. Dependent steps stay ordered;
   independent ones fan out. (E.g. the refresh runs the balance stream
   and the transaction-history scan as `async let` in parallel; the
   balance scanner fans out per-chain RPC via a TaskGroup.)

### Part B — The live-update contract still holds (Rules #25, #27)

Off-main + batched does NOT mean "stale." After the background work
flushes to the store, the UI updates LIVE off `@Query` / `@Observable`
(Rule #25) — the user never relaunches or navigates to see a result. The
DB stays the single source of truth (Rule #27); background actions are
writers, the UI is a reader. "Background" means *non-blocking*, not
*deferred-until-reopen*.

### Part C — The render path stays cheap (complements Rule #28)

Even off-main work surfaces through a main-thread re-render. So the body /
row render path must be cheap too:
- No per-call allocation of `RelativeDateTimeFormatter` / `NumberFormatter`
  / `DateFormatter` in hot paths — cache them (`static let` /
  `nonisolated(unsafe) static let`); `FormatStyle` values are `Sendable`,
  reuse a base style. (2026-06-14 Activity-list fix.)
- Expensive collection work (filter / sort / map / reduce / hash over
  balances, transactions, registries) is memoized into `@State`, rebuilt
  only on a real change trigger — never recomputed every body pass, and
  never inside a `.task(id:)` / `.onChange` KEY (the
  `WalletDataFingerprint`-per-body trap — 2026-06-14).
- Lists are lazy (`List` / `LazyVStack`); rows render from pre-resolved
  values, not live formatting during scroll.

### Part D — Workflow gate (every action, every PR)

Before any function that does work ships, answer:
1. Does any heavy step run on `@MainActor` (a fetch, parse, format loop,
   crypto, image decode, large reduce)? → move it off-main.
2. Does it `save()` more than once per logical operation? → batch +
   `flush()`.
3. Are there independent awaits run sequentially? → `async let` /
   TaskGroup them.
4. After it completes, does the UI update live off the store (Rule #25)?
5. Is the resulting main-thread re-render cheap (Part C)?

If any answer is wrong, it doesn't ship. When in doubt about whether work
is heavy enough to matter, move it off-main anyway — the main thread is
sacred.

### Part E — Why this rule exists

A wallet that stutters when it refreshes, scrolls, or computes feels
broken and untrustworthy regardless of how correct its numbers are. The
2026-06-14 investigation proved the cause is almost always main-thread
work: per-record SwiftData saves storming the UI, `@MainActor` fetches
blocking scroll, per-row formatter allocation, and per-body recomputation.
Fixing them one screen at a time is whack-a-mole; Rule #28 makes
"off-main, batched, parallel, cheap render" the default contract for every
action so the class of bug cannot return.

---

## Rule #29 — Drive to completion autonomously. Never stop to ask "go / continue / should I proceed".

When the user has given a task, **finish it** — do not pause mid-job to ask
for permission to keep going. Added 2026-06-14 on the user's direction
(verbatim): *"don't ask me to tell you go or continue again, always you
should go and continue your job till the end."* This is a standing,
durable instruction. It strengthens and generalizes Rule #21
(finish-without-stopping) and the global autonomous-execution principle.

### Part A — What is forbidden
- Ending a turn with "say **go** / **continue** / **yes** and I'll…",
  "want me to proceed?", "should I keep building?", or any equivalent
  permission-to-continue gate when the work the user asked for is not yet
  done.
- Checkpointing a large feature "here" and waiting for the user to
  re-authorize the obvious next step. The next step IS the job — take it.
- Using `AskUserQuestion` to ask whether to proceed/continue. (That tool
  is for genuine *branching product decisions* whose answer changes WHAT
  you build — never for "may I continue doing what you already asked".)

### Part B — What to do instead
- Keep working through every step until the task is genuinely complete —
  across as many internal steps, commits, builds, and installs as it takes.
- When one logical chunk lands, immediately start the next; commit + push
  per chunk (Rule #23) so progress is durable, and keep going.
- If you hit a context/turn limit mid-job, leave the work committed in a
  compiling state and CONTINUE in the next turn — do not convert the limit
  into a "tell me to continue" prompt.
- Report progress as you go (what landed, what's next), but as a STATEMENT
  of continued work, not a request for permission.

### Part C — The only legitimate reasons to pause
Pause ONLY for a true blocker the user alone can resolve, and when you do,
name it precisely and keep doing everything else that is NOT blocked:
1. A genuine branching product decision where the user's answer changes
   the deliverable (use `AskUserQuestion`, briefly, then proceed on the
   answer).
2. An irreversible / outward-facing action needing authorization that
   isn't already standing (e.g. `git push --force`, releases — per
   Rule #23 Part-A class).
3. A hard external blocker (a required device offline, a credential
   missing, a paid signup). State it; do all unblocked work meanwhile;
   resume the blocked part the instant it clears — without being asked.

Funds-safety note: "build it" still means build it — keep going. Where a
step can't be *verified* yet (e.g. a real test send needs the device),
build it, mark it honestly as unverified, and continue with the rest;
never stop the whole job for a verification gate.

### Part D — Why this rule exists
The user repeatedly had to type "go" / "continue" to resume work they had
already clearly authorized — friction that wastes their time and stalls
momentum. The job, once given, is the mandate to finish. Autonomy to
completion is the default; asking-to-continue is the exception that now
requires the Part-C justification.

---

## Project context

- iOS native, **Swift 6.2**, **iOS 26+**, SwiftUI, Liquid Glass design system
- xcodegen-managed project (`project.yml` → `UniApp.xcodeproj`)
- Bundle ID: `com.thuglife.uniapp`
- Supported assets: see [`SUPPORTED_ASSETS.md`](./SUPPORTED_ASSETS.md)
- Source of truth for assets: `/Users/thuglifex/Desktop/stabro_assets.csv`
- Design-first approach — UI is built with **zero functionality** and TODO
  markers until the design is approved screen-by-screen.
