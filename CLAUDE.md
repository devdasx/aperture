# UniApp — Agent Rules

## Rule #1 — Every change must be logged in `SHIPPED.md`

Any edit, addition, removal, file move, build, install, configuration change, or
deployment that happens in this project **MUST** be appended to `SHIPPED.md`
in the same session it occurs — no exceptions.

### What counts as "something to log"
- New files created (Swift sources, asset catalogs, configs, docs)
- Existing files modified (even tiny edits, even comments)
- Files deleted, moved, or renamed
- Build settings / `project.yml` / Xcode project changes
- Dependency additions or removals
- Signing / provisioning / team changes
- Builds run, devices targeted, app installs, launches
- Any new screen, view, component, model, or design-system token
- TODO markers added (so future agents see what's stubbed)

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

## Rule #9 — Full i18n. Every user-facing string is localizable. Translations stay in sync via two background agents.

UniApp ships in **20 languages** from day one. Every string a user can see
must be a `String(localized:)` / `LocalizedStringKey` / `LocalizedStringResource`
reference — never a bare `String` literal in a `Text(...)`, `Button(...)`,
`Label(...)`, alert title, or anywhere else that renders.

A pair of **translator agents** keeps the `Localizable.xcstrings` String
Catalog in sync after every edit that introduces a new string.

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
| `.primary`          | `.mediumImpact` — committing to a flow |
| `.secondary`        | `.selection` — neutral acknowledgement |
| `.destructive`      | `.warning` — deliberate weight; user should feel they triggered something irreversible |
| `.tertiary`         | none — inline text links should feel as quiet as plain HTML links |

These bindings are the default; future components that need a different
haptic per state can override by composing `.uniHaptic(...)` themselves.

### Part F — Workflow gate

Before any new interactive surface is committed:

1. Does this surface use `UniButton`? If yes, haptic is automatic — skip.
2. If no, did you apply `.uniHaptic(_:trigger:)` to the state change?
3. Did you pick a semantic case (not just `.selection` reflexively)?
4. Did you check the user preference path works (toggle off → silent)?
5. Did you log the new haptic-bearing surface in `SHIPPED.md` per Rule #1?

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
  `UniAppApp.swift`.** The only allowed exception is Part B's per-`Text`
  override for a self-name rendered against the opposite-direction flow
  (and that should be the smallest possible subtree).
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

## Rule #13 — Translations run after every edit. No session ends with untranslated strings.

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

## Project context

- iOS native, **Swift 6.2**, **iOS 26+**, SwiftUI, Liquid Glass design system
- xcodegen-managed project (`project.yml` → `UniApp.xcodeproj`)
- Bundle ID: `com.thuglife.uniapp`
- Supported assets: see [`SUPPORTED_ASSETS.md`](./SUPPORTED_ASSETS.md)
- Source of truth for assets: `/Users/thuglifex/Desktop/stabro_assets.csv`
- Design-first approach — UI is built with **zero functionality** and TODO
  markers until the design is approved screen-by-screen.
