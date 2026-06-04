# UniApp — TODO Register

> Every `// TODO:` comment in the codebase has a matching entry here. See
> [`CLAUDE.md`](./CLAUDE.md) Rule #5 for the workflow.
>
> **IDs are stable.** When a TODO is resolved, move its entry to the
> "Resolved" section at the bottom and mark the date — never delete it.
> The corresponding inline `// TODO:` comment is removed only when the
> implementation lands.

---

## Legend

- **Status:** `OPEN` (not started) · `IN-PROGRESS` (work begun) · `BLOCKED` (waiting on prereq) · `RESOLVED` (shipped, moved below).
- **Priority:** `P0` (blocks core flow) · `P1` (next-up) · `P2` (later) · `P3` (nice-to-have).
- **Area:** which feature/system the TODO belongs to.

---

## Open

### T-002 · "Create new wallet" flow
- **Status:** IN-PROGRESS (Steps 1, 2, 3, 4 shipped 2026-06-04 — see `SHIPPED.md` entries titled "Create-wallet flow: disclosure + recovery-phrase display + skip-backup warning" and "Real BIP-39 mnemonic + word-count toggle + passphrase + backup-verify flow")
- **Priority:** P0
- **Area:** Onboarding · Wallet creation
- **File:** `UniApp/Sources/Features/Onboarding/OnboardingView.swift` (CTA wired to `isShowingCreateDisclosure`; previous inline `// TODO:` removed). Sub-step TODOs filed as T-010..T-016 + T-019 below.
- **Context:** Primary CTA on onboarding. This is the most critical flow in the entire app — getting a user from "nothing" to "self-custodial wallet ready to receive crypto". Must be irreversible-by-design (seed cannot be recovered if lost), with explicit consent and verification.
- **What "done" looks like:**
  1. **Step 1 — Disclosure:** ✅ SHIPPED 2026-06-04 (`CreateWalletDisclosureSheet`).
  2. **Step 2 — Generate seed:** ✅ SHIPPED 2026-06-04 — see **T-010** (now Resolved). Real BIP-39 mnemonic via `Security.SecRandomCopyBytes` + `CryptoKit.SHA256`, native implementation, no third-party SPM. Default 12 words; user can switch to 24 via the recovery-phrase toolbar menu.
  3. **Step 3 — Display:** ✅ SHIPPED 2026-06-04 (`RecoveryPhraseView`). Word-count-adaptive 2-column grid. Toolbar: bare `xmark` close (no glass pill, no `.circle`), bare `ellipsis` overflow Menu (no `.circle`) — see `MISTAKES.md` M-002 + M-003. Overflow menu hosts the word-count picker + the passphrase entry. Copy button with auto-expiring (60 s) clipboard. Screenshot detection → `ScreenshotWarningSheet` with "Generate new phrase" / "Keep my screenshot" CTAs (T-013 resolved). Screen-recording warning sheet re-specced as **T-014** (warn-after-the-fact pattern).
  4. **Step 4 — Verify:** ✅ SHIPPED 2026-06-04 (`BackupVerifyView`). 3 challenge cards, multiple-choice 2×2, retry-without-lockout. Real seed derivation from (mnemonic + passphrase) lands today via `BIP39.deriveSeed(words:passphrase:)` — PBKDF2-HMAC-SHA512, 2048 iterations, TREZOR vector validated. Keychain persistence is still **T-012**.
  5. **Step 5 — Biometric setup:** see **T-012**. Face ID / passcode + Keychain encryption.
  6. **Step 6 — Done:** placeholder `WalletReadyView` shipped 2026-06-04. Real wallet home destination remains **T-018**.
  - **Skip-backup branch:** ✅ SHIPPED 2026-06-04. `SkipBackupWarningSheet` over `RecoveryPhraseView`.
  - **Back-up-now branch:** ✅ SHIPPED 2026-06-04 — pushes `BackupVerifyView` then `WalletReadyView`. See **T-015** (now Resolved).
- **Honesty checks (Rule #2 §A.2):**
  - No "your wallet is ready in 30 seconds!" copy. State the truth: you are about to take responsibility for your own keys.
  - No optional skip on "verify your seed" — verification is mandatory when the user opts into "Back up now".
- **Depends on:** T-007 (NavigationStack), T-008 (domain-layer wallet/keychain protocol), T-012, T-018, T-019.

### T-003 · "I already have a wallet" import flow
- **Status:** OPEN
- **Priority:** P0
- **Area:** Onboarding · Wallet import
- **File:** `UniApp/Sources/Features/Onboarding/OnboardingView.swift:93`
- **Inline comment:** `// TODO: (T-003) navigate to "Import wallet" flow (seed phrase / private key / iCloud encrypted backup)`
- **Context:** Secondary CTA. Three import paths are supported per the supported-assets manifest's underlying chains:
  1. **Seed phrase** (BIP-39, 12 or 24 words) — primary case.
  2. **Private key** (single chain, advanced users).
  3. **iCloud encrypted backup** (CloudKit-encrypted file restored from prior UniApp install).
- **What "done" looks like:**
  1. Picker screen ("How would you like to import?") with three options as `UniCard` rows.
  2. Each path has its own screen with validation:
     - Seed phrase: paste-safe input (no autocorrect, no spell-check, no clipboard auto-suggest); detect 12 vs 24 words; validate BIP-39 wordlist before allowing "Continue".
     - Private key: hex / base58 detection per chain; warn the user that single-key import is chain-scoped, not multi-chain.
     - iCloud backup: list available backups via CloudKit, require Face ID + the original backup password.
  3. Once imported, derive addresses for every supported network listed in `SUPPORTED_ASSETS.md` (24 networks) and surface them to the wallet home.
- **Honesty checks:** clipboard handling must never log or persist pasted secret data. Display "Never share this phrase with anyone — UniApp will never ask you for it" prominently on the seed-phrase screen.
- **Depends on:** T-007, domain-layer crypto provider, CloudKit container setup.

### T-004 · Present Terms of Service modal
- **Status:** OPEN
- **Priority:** P2
- **Area:** Onboarding · Legal
- **File:** `UniApp/Sources/Features/Onboarding/OnboardingView.swift:106`
- **Inline comment:** `// TODO: (T-004) present Terms of Service`
- **Context:** The legal footer on onboarding ("By continuing, you agree to our Terms and Privacy") needs the "Terms" link to actually present the Terms of Service. Tapping the link should open the document in a system `.sheet(...)` with `.presentationDetents([.medium, .large])` — native sheet, per Rule #3.
- **What "done" looks like:**
  1. Tapping "Terms" presents a sheet showing the ToS markdown.
  2. ToS content lives in `UniApp/Resources/Legal/Terms.md` (bundled, not fetched from network — offline-safe).
  3. Sheet has a "Done" trailing toolbar item to dismiss.
  4. Accessibility: VoiceOver reads the title on present; Dynamic Type respected.
- **Depends on:** Final ToS copy from legal (not yet written — placeholder OK for now).

### T-005 · Present Privacy Policy modal
- **Status:** OPEN
- **Priority:** P2
- **Area:** Onboarding · Legal
- **File:** `UniApp/Sources/Features/Onboarding/OnboardingView.swift:115`
- **Inline comment:** `// TODO: (T-005) present Privacy Policy`
- **Context:** Mirror of T-004 for the Privacy Policy link.
- **What "done" looks like:** identical mechanism to T-004, with `UniApp/Resources/Legal/Privacy.md`. Must clearly state UniApp's non-custodial nature: we never see your keys, your seed, your balances, your transactions — they exist only on your device and on public blockchains.
- **Depends on:** Privacy policy copy.

---

## Backlog (anticipated TODOs not yet placed inline)

These are known gaps that will become inline TODOs as soon as the relevant
view scaffolding lands. They are *not* yet in code — listed here so we don't
forget them when we get there.

### T-001 · Returning-user entry: skip onboarding to wallet setup choice
- **Status:** OPEN (no inline marker — onboarding has no Skip control anymore)
- **Priority:** P1
- **Area:** Onboarding · Routing
- **File:** *(no inline anchor; lives in this register until the relevant code exists)*
- **Context:** As of the 2026-06-04 onboarding redesign (ten beats, swipe-only navigation, two CTAs on the final slide), the `Skip` control has been removed. The user navigates exclusively by swiping. The remaining open question — what happens for returning users who have already completed onboarding once — is what this entry now tracks. The earlier "Skip jumps to final slide" mechanism is gone; this is its successor concept. (Prior semantics preserved in `SHIPPED.md` history.)
- **What "done" looks like:**
  1. A `hasSeenOnboarding` flag is persisted via `@AppStorage` (or SwiftData once it lands).
  2. On second-and-later launches, `UniAppApp` routes past `OnboardingView` to a future `WalletSetupChoiceView` (create new / import seed / restore from iCloud encrypted backup) instead of replaying onboarding.
  3. There remains a documented way to view onboarding again from Settings (e.g., "Show introduction") for users who want to revisit it — but it is not the default path for returning users.
- **Depends on:** T-007 (NavigationStack), a future `WalletSetupChoiceView`, a persistence layer for `hasSeenOnboarding`.

### T-007 · NavigationStack root + routing
- **Status:** OPEN (no inline TODO yet — to add when we wire navigation)
- **Priority:** P0
- **Area:** App shell · Routing
- **Context:** Currently `UniAppApp` shows `OnboardingView` directly. The next screen we add will need a navigation host. Adopt `NavigationStack` with a `NavigationPath` driven by an `@Observable RootRouter`.
- **What "done" looks like:** `UniAppApp` hosts `RootView` which owns the `NavigationStack`; routes are enum-typed so destinations are exhaustively switched.

### T-008 · Domain-layer wallet / keychain protocol
- **Status:** OPEN
- **Priority:** P0
- **Area:** Domain · Wallet
- **Context:** UI must never import a crypto SDK directly (Rule #3, Part A.3). Define a `WalletService` protocol that the UI consumes, with a concrete implementation living in the domain/data layer. Initial surface: generate seed, import seed, derive addresses, sign tx, fetch balance.

### T-011 · Seed verification view (Step 4 of T-002)
- **Status:** IN-PROGRESS (UI flow shipped 2026-06-04 as `BackupVerifyView`. Real PBKDF2-HMAC-SHA512 seed derivation also shipped 2026-06-04 — verify now consumes mnemonic + passphrase and computes the real 64-byte BIP-39 seed in memory. Keychain persistence still lands with T-012.)
- **Priority:** P0
- **Area:** Onboarding · Create-wallet flow Step 4
- **File:** `UniApp/Sources/Features/CreateWallet/BackupVerifyView.swift`; `UniApp/Sources/Brand/BIP39Seed.swift`; `UniApp/Sources/Features/CreateWallet/CreateWalletState.swift` (`deriveSeed()` method).
- **Context:** After the user sees the words, they prove they wrote them down. Pattern: 3 challenge cards at random positions, each with a 2×2 grid of 4 choices (correct word + 3 random distractors from the BIP-39 wordlist). Retry-without-lockout. On success, derive the seed honestly — the passphrase entered in `PassphraseSheet` is consumed in PBKDF2 so it is not silently dropped on the floor.
- **What "done" looks like:**
  1. ✅ SHIPPED — UI: 3 challenge cards, 2×2 choice grid, retry on wrong picks, `UniHaptic.success` / `.error` feedback. Continue button disabled until all 3 selected.
  2. ✅ SHIPPED — `BIP39.deriveSeed(words:passphrase:)` per spec §6 (PBKDF2-HMAC-SHA512, 2048 iterations, 64-byte output). Pure CryptoKit `HMAC<SHA512>` loop, no `CommonCrypto` bridge, no SPM. TREZOR test vector validated.
  3. Outstanding — when T-012 lands, the seed must persist to Keychain with `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` rather than living only in memory on `CreateWalletState`.
- **Depends on:** T-012 (Keychain persistence), T-008 (domain protocol).

### T-012 · Biometric setup + Keychain encryption (Step 5 of T-002)
- **Status:** OPEN
- **Priority:** P0
- **Area:** Onboarding · Create-wallet flow Step 5
- **File:** future `UniApp/Sources/Features/CreateWallet/BiometricSetupView.swift`; pushed via `RecoveryPhraseDestination.biometric`.
- **Context:** After seed verification, prompt Face ID / passcode (`LocalAuthentication` framework — Rule #3 Part A.6) and encrypt the seed into the Keychain with `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`.
- **What "done" looks like:**
  1. `WalletService.persistSeed(_ words: [String]) async throws` — caller provides the verified phrase; service encrypts + stores.
  2. The user sees a single Face ID prompt; on success, navigate to T-018 (wallet home).
  3. On Face ID refusal, fall back to device passcode; on passcode unavailable, surface an honest "Your iPhone needs a passcode to protect your wallet" message + a "Set up passcode" deep link.
- **Depends on:** T-010, T-008.

### T-014 · Screen-recording / mirroring warning sheet on `RecoveryPhraseView`
- **Status:** RE-SPECCED 2026-06-04 — mirrors the screenshot pattern shipped under T-013 today: warn-after-the-fact, do not blank the words.
- **Priority:** P1 (raise to P0 once T-012 lands and a real seed sits behind a real wallet)
- **Area:** Security · Create-wallet flow Step 3
- **File:** future addition to `UniApp/Sources/Features/CreateWallet/RecoveryPhraseView.swift` and a new `ScreenRecordingWarningSheet.swift`.
- **Context:** Mirroring/recording is harder to undo than a screenshot — the recipient may already have a recording running on AirPlay, QuickTime, or a screen-sharing call. The earlier T-014 spec called for *blanking* the words while capture was active; the user direction on 2026-06-04 dropped the blanking pattern in favour of warn-after-the-fact for screenshots, and the same design ethos applies here: do not steal control from the user — name the risk + offer a fresh phrase. The implementation hook is `UIScreen.capturedDidChangeNotification`, fired on every `isCaptured` transition; we react on the *false → true* edge.
- **What "done" looks like:**
  1. Observe `UIScreen.capturedDidChangeNotification`. On a transition into the captured state, present a sheet titled "Capture in progress".
  2. Body copy names the risk plainly: anyone watching the recording / AirPlay / mirror has access to the phrase right now.
  3. Two CTAs in the same shape as `ScreenshotWarningSheet`: "Generate new phrase" (regenerates entropy + clears passphrase, sheet dismisses) and "I'll stop capture and continue" (sheet dismisses; the user manages their own session).
  4. Apply `.presentationBackground(UniColors.Background.primary)` for the same opaque sheet surface as the screenshot / passphrase sheets.
  5. All copy flows through the String Catalog (Rule #9).
- **Depends on:** T-013 (shipped today — establishes the warning-sheet pattern).

### T-019 · BIP-39 passphrase persistence at unlock (alongside Keychain seed)
- **Status:** OPEN
- **Priority:** P1
- **Area:** Domain · Wallet · Security
- **File:** future addition to the domain layer (`WalletService`); the UI surface already exists in `PassphraseSheet.swift` and `CreateWalletState.passphrase`.
- **Context:** Today the passphrase entered in `PassphraseSheet` is held in memory on `CreateWalletState` for the lifetime of the create-wallet cover. It is **never** written to disk by design — BIP-39 defines the passphrase as a memorised "25th word" that the user is responsible for. When T-012 lands, the seed-derivation step will combine mnemonic + passphrase via PBKDF2-HMAC-SHA512 to produce the 64-byte BIP-39 seed at the moment of derivation; the passphrase itself remains transient.
- **What "done" looks like:**
  1. The domain-layer seed derivation accepts `(mnemonic: [String], passphrase: String)` and produces the BIP-39 seed via PBKDF2-HMAC-SHA512 with 2048 iterations, salt `"mnemonic" + passphrase` (UTF-8 NFKD).
  2. After derivation, the passphrase is **not** persisted. On subsequent unlocks the user is prompted to re-enter it.
  3. If the user opted not to set a passphrase, the derivation runs with `passphrase = ""` — also per BIP-39 spec.
- **Honesty checks:** the prompt copy must continue to state plainly that the passphrase is not stored and cannot be recovered. The fallback for a forgotten passphrase is the same as a forgotten mnemonic: there is none.
- **Depends on:** T-008, T-012.

### T-016 · Settings row: "Back up your recovery phrase" (post-skip recovery)
- **Status:** OPEN
- **Priority:** P1
- **Area:** Settings · Wallet recovery
- **File:** future addition to `UniApp/Sources/Features/Settings/SettingsView.swift`; reads `@AppStorage("hasUnbackedupWallet")`.
- **Context:** When the user skips backup during create-wallet (the new branch shipped 2026-06-04), `hasUnbackedupWallet` is set to `true`. Settings must surface a prominent row offering to back up later — restraint-styled, but visually distinct (warning tone) — that re-enters the backup flow when tapped.
- **What "done" looks like:**
  1. While `hasUnbackedupWallet == true`, a new top section in `SettingsView` shows a single row titled "Back up your recovery phrase" with a `key.fill` leading symbol in `UniColors.Status.warningForeground`.
  2. Tapping it re-presents `RecoveryPhraseFlow` (or its T-015 successor) for the existing wallet.
  3. Once the user completes the backup flow, `hasUnbackedupWallet` is reset to `false` and the row disappears.
- **Depends on:** T-010, T-015, T-018.

### T-018 · Wallet home destination (Step 6 of T-002)
- **Status:** OPEN (placeholder `WalletReadyView` shipped 2026-06-04 as a stand-in terminal screen — see `SHIPPED.md` entry titled "Real BIP-39 mnemonic + word-count toggle + passphrase + backup-verify flow")
- **Priority:** P0
- **Area:** Wallet · Home
- **Context:** The destination after a successful create-or-import flow. Out of scope per user direction on 2026-06-04 ("for now do this job, plan it well — but don't create the main screen of the wallet"). The current `WalletReadyView` (`UniApp/Sources/Features/CreateWallet/WalletReadyView.swift`) is a one-screen placeholder ("Your wallet is ready.") that dismisses the create-wallet cover and clears the unbacked-up flag; it is **not** the real home and must be replaced by a proper wallet home in a future design pass.
- **What "done" looks like:** TBD when the wallet-home design pass is requested. `WalletReadyView` is removed at that point and the cover dismisses straight into the real home.

---

## Resolved

### T-020 · Localized currency display names via `Locale.localizedString(forCurrencyCode:)` — RESOLVED 2026-06-04
- **Status:** RESOLVED
- **Priority:** P2
- **Area:** Settings · Localization · Currency picker
- **Resolved by:** `SHIPPED.md` entry titled "Flags + locale-resolved language & currency names + disclosure-sheet headline promoted to nav title" (2026-06-04).
- **Original context:** The currency picker listed 136 ISO-4217 fiats with hardcoded English names ("Egyptian Pound", "South African Rand", "Bolivian Boliviano"). When the user picked a non-English UI language, those names stayed in English — a Rule #9 honesty gap.
- **How it shipped:**
  1. `CurrencyPickerView` now reads `@Environment(\.locale)` and resolves each row's primary label at render time via `currentLocale.localizedString(forCurrencyCode: currency.code) ?? currency.englishName`.
  2. The search filter matches the locale-resolved name in addition to `englishName`, `code`, and `symbol` — so a French-locale user typing "dollar américain" finds USD via `String.localizedStandardContains`.
  3. `SupportedCurrency.englishName` is preserved as a stable audit field and a last-resort fallback if iOS returns `nil` for an obscure code.
  4. Symbols stay literal (universal across locales).
  5. Zero catalog changes — `Locale.localizedString(forCurrencyCode:)` is built into iOS for every BCP-47 the user might pick.
- **Honesty achieved:** the picker stops showing English to a user who chose Japanese. iOS does the translation; we were just not asking.

### T-013 · Screenshot detection on `RecoveryPhraseView` — RESOLVED 2026-06-04
- **Status:** RESOLVED
- **Priority:** P1
- **Area:** Security · Create-wallet flow Step 3
- **Resolved by:** `SHIPPED.md` entry titled "Bare toolbar SF Symbols + real BIP-39 seed derivation + clipboard + screenshot warning" (2026-06-04).
- **Original context:** A screenshot of the recovery phrase is a security incident — the words sync to iCloud, appear in the photo library and Recents, and can be read by anyone with the unlocked phone. The original spec called for a transient warning banner that did not block the user.
- **How it shipped (different from the original spec — by user direction on 2026-06-04, warn-after-the-fact with a real recovery action, not just a banner):**
  1. `RecoveryPhraseView.swift` subscribes to `UIApplication.userDidTakeScreenshotNotification` via `.onReceive(...)`. On every screenshot, `isShowingScreenshotWarning = true`.
  2. The screenshot is **not blocked**. The view does not blank the words while shown — honesty: we cannot un-take a screenshot, so theatre would just confuse the user.
  3. `ScreenshotWarningSheet.swift` is a new sheet with: a title ("Screenshot detected"), a body paragraph naming the actual risks (iCloud sync, photo library, Recents, unlocked-phone access), a `UniCard` of 3 better-method rows (paper offline, hardware key, metal stamp), and two CTAs — "Generate new phrase" (regenerates entropy + clears passphrase, invalidating the screenshot the user just took) and "Keep my screenshot" (accepts the risk, dismisses the sheet).
  4. Background: opaque `UniColors.Background.primary` via `.presentationBackground(...)` — same material treatment as `PassphraseSheet`. Detents: `[.medium, .large]`.
  5. All copy flows through `Localizable.xcstrings` (Rule #9). 9 of the 12 new strings introduced in this session belong to this feature.

### T-015 · "Back up now" flow — RESOLVED 2026-06-04
- **Status:** RESOLVED
- **Priority:** P1
- **Area:** Onboarding · Create-wallet flow (branch from Step 3)
- **Resolved by:** `SHIPPED.md` entry titled "Real BIP-39 mnemonic + word-count toggle + passphrase + backup-verify flow" (2026-06-04).
- **Original context:** "Back up now" was a stub that simply dismissed the cover. The proper sequence is: continue to verify (T-011) → wallet-ready terminal (T-018 placeholder).
- **How it shipped:**
  1. The `onBackUpNow` callback on `RecoveryPhraseView` now pushes `RecoveryPhraseDestination.verify` onto the cover's `NavigationStack`.
  2. `BackupVerifyView` performs the 3-position multiple-choice verification. On success, the user is pushed to `WalletReadyView`, which on "Done" dismisses the cover and clears `hasUnbackedupWallet`.
  3. The skip-warning sheet's "Back up now" CTA also routes into verify, consistent with the recovery view's primary CTA.
  4. Future biometric setup (T-012) will insert between verify and wallet-ready; the routing change is mechanical at that point.

### T-010 · Real BIP-39 seed generation — RESOLVED 2026-06-04
- **Status:** RESOLVED
- **Priority:** P0
- **Area:** Domain · Wallet · Create-wallet flow Step 2
- **Resolved by:** `SHIPPED.md` entry titled "Real BIP-39 mnemonic + word-count toggle + passphrase + backup-verify flow" (2026-06-04).
- **Original context:** The recovery-phrase display was reading from `MockRecoveryPhrase.words` — a static list of 12 hardcoded BIP-39 English wordlist entries, identical for every install.
- **How it shipped:**
  1. `UniApp/Sources/Brand/BIP39.swift` implements the BIP-39 spec directly: `Security.SecRandomCopyBytes` for entropy, `CryptoKit.SHA256` for the checksum, hand-written bit-packing for the 11-bit groups. No third-party SPM (Rule #3).
  2. `UniApp/Sources/Brand/BIP39Wordlist.swift` bundles the canonical 2048-word English wordlist, sourced from `github.com/bitcoin/bips/blob/master/bip-0039/english.txt`. SHA-256 verified: `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`.
  3. `BIP39WordCount` enum covers 12 (128-bit entropy + 4-bit checksum) and 24 (256-bit + 8-bit) lengths.
  4. Test vectors validated in debug-mode smoke-check (`_bip39SmokeCheck`): all-zero 128-bit entropy → "abandon … about"; all-zero 256-bit entropy → "abandon … art".
  5. `MockRecoveryPhrase.swift` deleted. `CreateWalletState` (new `@Observable` flow model) drives mnemonic generation via `BIP39.generateMnemonic(wordCount:)` and is shared across `RecoveryPhraseView`, `PassphraseSheet`, and `BackupVerifyView`.

### T-009 · Region & currency picker — RESOLVED 2026-06-04 (superseded by Currency picker)
- **Status:** RESOLVED
- **Priority:** P2
- **Area:** Settings · Localization
- **Resolved by:** `SHIPPED.md` entry titled "Rule #12 dark/light propagation fix + Currency picker (replaces Region & currency) + Coinbase price provenance" (2026-06-04).
- **Original context:** The "Region & currency" row in Settings routed to an inline `RegionPlaceholderView`. The original spec called for two orthogonal preferences (fiat currency + number-formatting locale).
- **How it shipped (and the scope change):**
  1. The user explicitly asked to "remove the region and currency, and keep only the currencies." Number-formatting locale was dropped — the user's selected Language already drives the formatter via `\.locale`, which is the honest default. We do not need a separate knob.
  2. The Settings row renamed to **Currency**, leading `dollarsign.circle`, trailing `<symbol> · <code>` (e.g., `$ · USD`).
  3. Tapping pushes `CurrencyPickerView` — `insetGrouped` list of `CurrencyPreference.all` (20 fiats), each row showing glyph + English name + ISO-4217 code + selection checkmark.
  4. Selection writes through `@AppStorage("currencyPreference")` (key declared in `CurrencyPreference.storageKey`); `PriceService` reads the same key. Default: `USD`.
  5. The inline `RegionPlaceholderView` and its TODO marker were removed; the `Region & currency` catalog entry was removed by the orchestrator.

### T-006 · User-configurable theme preference (light / dark / system) — RESOLVED 2026-06-04
- **Status:** RESOLVED
- **Priority:** P2
- **Area:** Design system · Settings
- **Resolved by:** `SHIPPED.md` entry titled "Settings sheet + i18n migration: gear icon, Language / Appearance / Region / About, LocalizedStringKey across the design system" (2026-06-04).
- **Original context:** Currently the app forces `.preferredColorScheme(.light)`. Once a Settings screen exists, the user must be able to switch between Light / Dark / System.
- **How it shipped:**
  1. `ThemePreference` enum (`system`, `light`, `dark`) persisted via `@AppStorage("themePreference")`.
  2. `UniAppApp` reads the preference and binds it to `.preferredColorScheme(_:)`. Default is `.light` for a fresh install; `.system` resolves to `nil`.
  3. `AppearancePickerView` (in `UniApp/Sources/Features/Settings/`) exposes the three options as a `List` of `Button` rows with leading SF Symbol and trailing checkmark.
  4. Switching mode animates via SwiftUI's native appearance transition — no hand-rolled motion.
