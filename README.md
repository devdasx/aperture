# Aperture

A self-custody crypto wallet for iPhone. Open source. Audit it. Run it. Verify what your wallet actually does.

> **Why open source matters for a wallet.** Your recovery phrase is the only thing standing between you and your funds. The code that handles it should be code you can read. Every line of Aperture is in this repository. Every change is in the commit history. Nothing is hidden — and the parts that matter most (key generation, seed derivation, biometric protection) are the parts most worth auditing.

---

## What Aperture is

- **Self-custody.** Your keys never leave your iPhone. There are no Aperture accounts, no Aperture servers, no Aperture database of your balances. We can't see your funds, even if we wanted to.
- **Multi-chain.** Bitcoin, Ethereum, Solana, and 21 more — supported networks listed in [`SUPPORTED_ASSETS.md`](./SUPPORTED_ASSETS.md). Real BIP-39 mnemonics, real BIP-39 seed derivation with optional passphrase, locked behind Face ID.
- **iOS-native.** SwiftUI, iOS 26+, Swift 6.2. Liquid Glass design system, no third-party UI libraries, no JavaScript bridges, no React Native. Built the way Apple builds iOS apps.
- **Localized everywhere.** 50 target languages (and growing), 136 fiat currencies. Right-to-left layouts for Arabic, Persian, Urdu, Hebrew flip live without restart.
- **Restraint.** Designed in the Jony Ive lineage: honest, simple, materials-first. No marketing exclamation marks, no emoji in UI text, no decorative animations.

## Why this matters for your security

1. **You can read the code that generates your recovery phrase.** It's [BIP-39](https://github.com/bitcoin/bips/blob/master/bip-0039/bip-0039.mediawiki) implemented from spec in [`UniApp/Sources/Brand/BIP39.swift`](./UniApp/Sources/Brand/BIP39.swift) using only Apple's native `SecRandomCopyBytes` (entropy) and `CryptoKit.SHA256` (checksum). The English wordlist in [`BIP39Wordlist.swift`](./UniApp/Sources/Brand/BIP39Wordlist.swift) is the canonical 2048-word list from `bitcoin/bips` — its SHA-256 hash matches the canonical `2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda`. The BIP-39 spec's test vector validates inside `#if DEBUG`.
2. **You can read the code that derives your seed.** PBKDF2-HMAC-SHA512 (2048 iterations, 64 bytes) per BIP-39 §6, implemented via CryptoKit's `HMAC<SHA512>` in [`BIP39Seed.swift`](./UniApp/Sources/Brand/BIP39Seed.swift). The TREZOR test vector (`"abandon × 11 + about"` + `"TREZOR"` passphrase → `c55257c3...3b04`) validates.
3. **You can read the rules the app is built against.** [`CLAUDE.md`](./CLAUDE.md) is the project's constitution — 15 binding rules covering native-only APIs, the Jony Ive design language, unified colors, accessibility, i18n, presentation environments, RTL layout, real-visuals-only iconography, the haptic system, sheet conventions, and the design-delegation discipline. Every change in [`SHIPPED.md`](./SHIPPED.md) cites the rules it honors.
4. **You can read what we've shipped and what's stubbed.** Every change since day one is in [`SHIPPED.md`](./SHIPPED.md) (append-only). Every `// TODO:` has a tracked entry in [`TODO.md`](./TODO.md) with acceptance criteria, dependencies, and honesty checks. Every mistake we've made and corrected is in [`MISTAKES.md`](./MISTAKES.md) so we don't repeat them.
5. **No analytics, no telemetry, no servers.** Aperture is a wallet, not a product. We have no measurement infrastructure, no error reporting back to us, no SDK chains. The only network calls are to public chain RPCs and to Coinbase's public price API for fiat conversion display.

## Audit it yourself

```bash
git clone https://github.com/devdasx/aperture.git
cd aperture
brew install xcodegen      # if you don't already have it
xcodegen generate
open UniApp.xcodeproj
# build for your own device — see Setup below
```

## Setup

**Requirements:** Xcode 26+, iOS 26+ deployment target, an Apple Developer account for device install, [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project UniApp.xcodeproj -scheme UniApp -configuration Debug \
    -destination 'platform=iOS,name=<YourDeviceName>' \
    -allowProvisioningUpdates build
```

Edit your dev team in [`project.yml`](./project.yml) (`DEVELOPMENT_TEAM`) before building for device.

## Architecture

```
UniApp/
├── Sources/
│   ├── App/                  — @main entry, app-environment wiring
│   ├── Brand/                — Aperture identity (iris, BIP-39, splash motion)
│   ├── DesignSystem/         — UniColors, UniTypography, UniSpacing, UniRadius
│   │   └── Components/       — UniButton, UniCard, UniText, UniBadge, UniDivider, …
│   ├── Settings/             — Theme / Language / Currency / Haptic preferences
│   ├── Pricing/              — PriceService protocol + CoinbasePriceService
│   └── Features/
│       ├── Onboarding/       — 10-beat onboarding sequence
│       ├── Splash/           — Cold-launch iris animation
│       ├── Settings/         — Settings sheet + pickers
│       └── CreateWallet/     — Disclosure → mnemonic → backup verification
└── Resources/
    ├── Assets.xcassets/      — Icons, brand colors, crypto logos
    └── Localizable.xcstrings — Single source of truth for 51 languages
```

## Tech stack

- **Swift 6.2** with Approachable Concurrency (strict concurrency = complete)
- **SwiftUI** on iOS 26+
- **Liquid Glass** design system (native iOS 26 APIs only)
- **CryptoKit** for SHA-256 / HMAC-SHA512
- **Security framework** for `SecRandomCopyBytes` (entropy)
- **LocalAuthentication** for Face ID / Touch ID (planned — T-012)
- **No third-party Swift packages.** Zero SPM dependencies.

## License

[MIT](./LICENSE) — verify, fork, audit, redistribute.

## Status

In active development. The onboarding + create-wallet flow is shipped. Wallet home, transactions, and Keychain seed persistence are tracked in [`TODO.md`](./TODO.md) (`T-012`, `T-018`).

---

*Made with [Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass).*
