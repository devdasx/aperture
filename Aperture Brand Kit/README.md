# Aperture — Brand Kit

The complete Aperture identity: the six-blade iris mark, wordmark lockups, app icons, social assets,
and the full motion (Lottie) system. Monochrome by conviction — **black on light, white on dark** — with
one gradient reserved for the app-icon tile (`#2A2C32 → #08090C`).

```
Aperture Brand Kit/
├─ logos/
│  ├─ svg/        Vector masters (source of truth — scale infinitely)
│  ├─ png/        Rasters — light/ dark/ tinted, plus favicon-16/32
│  └─ lockup/     Horizontal wordmark lockups (PNG)
├─ social/
│  └─ twitter/    Profile pic + header (PNG @1x/@2x + SVG)
├─ lottie/        25 motion files — 8 animations × 3 treatments (+1 splash variant)
├─ refresh-interactive/   Live pull-to-refresh (real timer, spins → success check)
└─ splash/        App-launch splash (HTML preview + shutter/black/white JSON)
```

## 1 · Logos (`logos/`)
The mark is a solid six-blade iris ("Iris Solid"). **Vectors in `svg/` are the source of truth.**

- **Marks** — `mark-black.svg`, `mark-white.svg` (flat mark, transparent).
- **App icons** — `icon-light.svg`, `icon-dark.svg`, `icon-tinted.svg` (iris on the squircle tile).
- **Wordmark lockups** — `wordmark-horizontal-{light,dark}.svg`, `wordmark-stacked-{light,dark}.svg`.
- **Circle logo** — `logo-circle.svg` (iris in a dark disc — the in-app logo).
- **Empty-state marks** — `mark-empty-{dashed,ghost,open,plus,soft,twotone}.svg`.
- **Action glyphs** — `icon-{send,receive,swap}.svg` and `…-aperture.svg` variants.
- **PNG** — `png/light/`, `png/dark/`, `png/tinted/` at every size + `favicon-16/32`.

**Rules:** keep clear space = ¼ of the mark's width; 28px digital minimum. Never recolor the blades,
rotate/crop the iris, or add shadows/glows. The squircle tile is mandatory for the app icon; only the
flat mark may stand alone.

## 2 · Motion / Lottie (`lottie/`)
Eight animations from the iris mark — each a standalone Lottie `.json`, **512×512, 60fps**, ready for
iOS, Android, Web (lottie-web), React Native, or Flutter.

| Animation | Behaviour | Type |
|---|---|---|
| `splash` | Iris blooms in with an overshoot settle | one-shot ~1.4s |
| `refresh` | Clean snappy single-speed spin | loop ~0.9s |
| `loading` | Spin with a rotating comet highlight | loop ~1.1s |
| `sending` | Slow spin with two orbiting transmit nodes | loop ~1.5s |
| `success` | Blooms, dims, then a checkmark draws on | one-shot ~1.3s |
| `empty` | Calm muted breathe-and-sway | loop ~3.0s |
| `onboarding` | Blades ripple in one by one | loop ~2.1s |
| `error` | Sharp shake & contract as an X draws over | one-shot ~1.1s |

Each ships in **three treatments**: `-black` (light-mode UI), `-white` (dark-mode UI), `-tile` (white
mark on the black gradient squircle — launch tile). `splash-logo.json` is the bare-logo splash variant.

```js
lottie.loadAnimation({ container: el, renderer:'svg', loop:true, autoplay:true,
  path:'lottie/loading-white.json' });   // loop:false for splash / success / error
```

## 3 · Interactive refresh (`refresh-interactive/`)
A production-ready **pull-to-refresh** built from the iris: it spins continuously while loading, then
**spins down and morphs into a success check** only on real completion (driven by a real timer, not a
fixed loop). Open `Aperture Refresh Lottie.html` to preview; `aperture-refresh*.json` +
`refresh-check-*.json` are the raw Lotties; `aperture-haptics.js` maps the haptic beats.

## 4 · Splash (`splash/`)
The app-launch splash. `Aperture Splash.html` previews it; `splash-shutter.json` (camera-shutter open),
`splash-black.json`, and `splash-white.json` are the raw Lotties.

## Social (`social/twitter/`)
Ready-to-upload X/Twitter **profile** (400×400) and **header** (1500×500) in PNG (@1x/@2x) and SVG.

## Color
```
Aperture Black #0B0D11 · Pure Black #000000 · Ink 900 #161719 · Graphite #3A3A3C
White #FFFFFF · Cloud #F5F5F7 · App-icon tile gradient #2A2C32 → #08090C
Positive (success only) #179A5B
```
Type: system SF (placeholder until a licensed brand face is chosen).

## Re-tinting
All marks are monochrome. To add a colorway, edit the fill color in the SVG/JSON — the geometry matches
the approved "Iris Solid" mark exactly across every file.
