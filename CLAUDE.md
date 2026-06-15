# Aperture

Native iOS 26 / Swift 6.2 / SwiftUI self-custody wallet. xcodegen
(`project.yml` → `UniApp.xcodeproj`). Test device: iPhone **Thuglife**
(`4B521D49-9843-55CC-AFEC-19D4CF4353A6`).

## How to work

Just fix things directly and fast. No design/data sub-agents, no workflows,
no multi-agent ceremony for small jobs. Read the code, make the change, build
only when it actually helps — not as ritual. Don't ask "go / continue" for
work already requested.

## The one kept rule — translation (runs in the background, non-blocking)

After editing `.swift` or `.xcstrings` under `UniApp/`, run the i18n loop in
the **background** so the user can keep chatting:

1. `aperture-i18n-scanner` (`run_in_background: true`) → finds user-facing
   strings missing from `UniApp/Resources/Localizable.xcstrings`, writes
   `.claude/i18n-missing.json`.
2. `aperture-i18n-catalog-writer` (`run_in_background: true`, after the
   scanner) → adds each with an **English source only**.

Non-English translation is deferred until the app is finished (one final pass
with `translator-primary` + `translator-secondary`). Never block the user on
translation.
