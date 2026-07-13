# Mark · Refresh — Lottie Animation Kit

A refresh / pull-to-refresh animation built 1:1 from the brand mark (`mark-source.svg`).
The mark is treated as a camera aperture: it spins while loading, and on completion the
aperture irises shut, turns green, and a check draws inside it.

**Designed display size: 70 × 70 px.** The comp is authored at 70 × 70 and everything is
pure vector — it scales to any size with no quality loss, but 70 px is the intended default.

---

## 1. What's in this folder

| File | Use on |
|---|---|
| `mark-refresh-light.json` | Light surfaces — ink `#0B0D11`, success `#16A34A` |
| `mark-refresh-dark.json` | Dark surfaces — ink `#FFFFFF`, success `#22C55E` |
| `mark-refresh-midnight.json` | Midnight / deep-blue surfaces — ink `#D7E2F6`, success `#22C55E` |
| `mark-source.svg` | The original mark the animation was rebuilt from (reference only) |

All three variants are identical in geometry and timing — only colors differ.
The check is white in all variants. Frame 0 of every file is a pixel-exact match
of `mark-source.svg` (recolored per variant), including the 96 / 80 % blade fills
and 32 % hairlines.

## 2. Quick preview

Drag any `.json` onto **lottiefiles.com/preview** (or the LottieFiles plugin for
Figma / After Effects / VS Code). Pressing play runs the **complete 3.5 s sequence** —
wind-up, spin, aperture close, green, check. Nothing extra to configure.

## 3. Format facts

- Lottie / Bodymovin v5 (works with lottie-web, lottie-ios, lottie-android, dotLottie players)
- 60 fps · 210 frames · 3.50 s total
- Comp size 70 × 70 px · keep the container square (1:1) — never crop or stretch
- Pure vector shape layers. No masks, mattes, images, expressions, or text layers
- Transparent background

## 4. Timeline

```
frame   0        20            66                  124                       210
        |--------|-------------|-------------------|-------------------------|
        WIND-UP   SPIN-UP       LOOP                SUCCESS
        tilts -14° accelerates   constant speed      aperture closes while
        (anticipa- into a full   360° / 0.97 s       decelerating → seals into
        tion)      turn + blade  SEAMLESS — repeat   a green disc → white check
                   highlight     [66,124] forever    draws on → holds
                   wave
```

Named markers are embedded in the file: `windup`, `spin-up`, `loop`, `success`.

**The loop is velocity-matched at both seams** (frame 66 and 124 have identical pose
AND identical angular velocity), so repeating `[66, 124]` is invisible — no stutter,
no rewind. Do not loop any other range.

## 5. How to wire the refresh pattern

Three states:

1. **Refresh starts** → play frames `0 → 66` once (wind-up + spin-up)
2. **Still loading** → loop frames `66 → 124` until your data arrives
3. **Done** → play frames `124 → 210` once (close → green → check), hold the last frame

If you only need an indeterminate spinner (no success state), use states 1–2 and
simply fade the whole thing out when done.

### Web — lottie-web

```html
<div id="refresh" style="width:70px;height:70px"></div>
```
```js
const anim = lottie.loadAnimation({
  container: document.getElementById('refresh'),
  path: 'mark-refresh-light.json',
  renderer: 'svg', loop: false, autoplay: false
});

// 1) refresh starts
anim.playSegments([0, 66], true);
const off = anim.addEventListener('complete', () => {
  off(); anim.loop = true;
  anim.playSegments([66, 124], true);      // 2) seamless loop while loading
});

// 3) when your fetch resolves:
function refreshDone() {
  anim.loop = false;
  anim.playSegments([124, 210], true);     // close → green → check, holds on end
}
```

### iOS — lottie-ios 4

```swift
let refresh = LottieAnimationView(name: "mark-refresh-light")
refresh.frame.size = CGSize(width: 70, height: 70)

// 1) + 2)
refresh.play(fromFrame: 0, toFrame: 66, loopMode: .playOnce) { _ in
  refresh.play(fromFrame: 66, toFrame: 124, loopMode: .loop)
}
// 3)
refresh.play(fromFrame: 124, toFrame: 210, loopMode: .playOnce)
```

### Android — Lottie Compose

```kotlin
val composition by rememberLottieComposition(
  LottieCompositionSpec.Asset("mark-refresh-light.json"))

// 2) while loading
LottieAnimation(composition,
  clipSpec = LottieClipSpec.Frame(66, 124),
  iterations = LottieConstants.IterateForever)

// 3) on completion switch to
//    clipSpec = LottieClipSpec.Frame(124, 210), iterations = 1
```

### React Native — lottie-react-native

```jsx
<LottieView ref={ref} source={require('./mark-refresh-light.json')}
  style={{ width: 70, height: 70 }} loop={false} autoPlay={false} />

// 1) ref.current.play(0, 66)   → onAnimationFinish: ref.current.play(66, 124) with loop
// 3) ref.current.play(124, 210)
```

## 6. Sizing rules

- Default: **70 × 70 px** container, animation fills it
- Vector — any size works. Sensible range 16 – 512 px; below 16 px the hairlines vanish
- Always 1:1 aspect ratio. Never crop, letterbox, or add padding inside the container
- Don't rasterize to GIF/PNG sequences unless a platform truly can't play Lottie

## 7. Editing notes (After Effects)

Import via the LottieFiles or Bodymovin plugin. One shape layer, `mark`, groups named:
`blade-01…06` (aperture blades), `spoke-01…06` (hairlines), `seal-disc`, `check`.
Timeline markers match section 4. If you retime or recolor, re-export and keep the
marker names — engineering keys off the frame numbers above.

## 8. Do / Don't

- **Do** pick the variant by surface, not by OS theme name alone — contrast is what matters
- **Do** respect `prefers-reduced-motion`: show frame 0 (rest) while loading and the final
  frame (green check) on completion instead of playing motion
- **Don't** change playback speed in code (`setSpeed`) — timing was designed at 1×;
  if you need it faster/slower, ask for a re-export
- **Don't** loop the full file as a spinner — loop `[66, 124]` only
- **Don't** tint the file at runtime; use the provided variants so success green stays correct

## 9. Provenance / QA

- Geometry generated mathematically from `mark-source.svg` — arcs converted to cubic
  beziers (max deviation < 0.005 px at 1024 scale); fills, opacities, hairline weights verbatim
- Frame 0 ≡ rest mark. Frame 210 ≡ green disc + check (safe to hold indefinitely)
- Loop seam verified: pose and angular velocity identical at frames 66 and 124
- File size ≈ 20 KB per variant, no external assets
