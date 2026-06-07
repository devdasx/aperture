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

### T-024 · Bitcoin family key derivation (secp256k1 + BIP-32 + BIP-44 + base58check)
- **Status:** RESOLVED — 2026-06-06 (Trust Wallet Core via WalletCore SPM; see SHIPPED.md entry titled "Trust Wallet Core key derivation for all 24 chains + max-parallel scan pipeline").
- **Priority:** P1
- **Area:** Brand · Cryptography · Import Wallet
- **File:** `UniApp/Sources/Features/ImportWallet/KeyImportService.swift:79` (StubKeyImportService — `deriveAddress(fromPrivateKey:on:)` for Bitcoin-family chains, `deriveAddresses(fromExtendedKey:on:)`).
- **Inline comment:** `// TODO: (T-024) Replace stub with real secp256k1 + BIP-32 derivation for Bitcoin family chains.`
- **Context:** The Import Wallet flow (shipped 2026-06-05, stub-first per jony-ive design audit) returns mock addresses for Bitcoin-family chains. Real implementation needs: (a) Bitcoin WIF parsing (base58check decode → 32-byte private key + compressed/uncompressed flag), (b) secp256k1 public-key derivation (CryptoKit's `P256K` on iOS 18+, or vetted dependency under Rule #3 Part B exception), (c) double-SHA-256 + RIPEMD-160 for legacy P2PKH addresses, (d) BIP-32 child derivation from xpub/ypub/zpub for the watch-only extended-key path (m/0/0..N receive + m/1/0..N change), (e) bech32 encoding for native segwit (zpub → bc1q… addresses).
- **What "done" looks like:**
  1. `BitcoinKeyParser` (`Brand/BitcoinKeyParser.swift`) — `static func parseWIF(_:) -> (privateKey: Data, compressed: Bool)?` + `static func derivePublicKey(_:compressed:) -> Data` + `static func address(fromPublicKey:network:) -> String`.
  2. `ExtendedKeyDerivation` — `static func deriveReceiveAddresses(xpub: String, count: Int) -> [String]` covering xpub (P2PKH), ypub (P2SH-wrapped segwit), zpub (native segwit / bc1q).
  3. `StubKeyImportService` swaps to a `BitcoinKeyImportService` for `.bitcoin`/`.bitcoinCash`/`.litecoin`/`.dogecoin` cases, retaining the protocol contract.
  4. Test vectors validated against the BIP-32 / BIP-44 spec appendix.
- **Honesty checks (Rule #2 §A.7):** The review step must show the real derived address — no stub marker. If derivation fails the UI must say so explicitly ("Could not parse this WIF"); no silent fallback to a fake address.
- **Depends on:** Rule #3 Part B exception decision (use pure-Swift secp256k1 vs vetted Swift package) — documented at implementation time.

---

### T-025 · EVM key derivation (secp256k1 + keccak256 + EIP-55)
- **Status:** RESOLVED — 2026-06-06 (Trust Wallet Core via WalletCore SPM; see SHIPPED.md entry titled "Trust Wallet Core key derivation for all 24 chains + max-parallel scan pipeline").
- **Priority:** P1
- **Area:** Brand · Cryptography · Import Wallet
- **File:** `UniApp/Sources/Features/ImportWallet/KeyImportService.swift:79` (StubKeyImportService — `deriveAddress(fromPrivateKey:on:)` for `.evm` family).
- **Inline comment:** `// TODO: (T-025) Replace stub with real secp256k1 + keccak256 EVM address derivation.`
- **Context:** EVM private keys are 32-byte hex (with or without `0x` prefix). Address = `keccak256(uncompressedPublicKey).suffix(20)` rendered as `0x…` with EIP-55 checksum casing. Single parser covers Ethereum + every EVM L1/L2 (Arbitrum, Base, Optimism, Scroll, zkSync, Polygon, BNB, opBNB, Avalanche, Celo, Kava EVM).
- **What "done" looks like:**
  1. `EVMKeyParser` (`Brand/EVMKeyParser.swift`) — `static func parsePrivateKey(_:) -> Data?` + `static func derivePublicKey(_:) -> Data` (uncompressed secp256k1 pub) + `static func address(fromPublicKey:) -> String` (lowercased 0x-prefixed).
  2. `EIP55.checksumAddress(_:) -> String` — mixed-case checksum per EIP-55.
  3. Swap into `KeyImportService` for the EVM-family branch.
  4. Validated against EIP-55 reference vectors (e.g. `0x52908400098527886E0F7030069857D2E4169EE7`).
- **Honesty checks:** EIP-55 casing must be correct — bad casing reads as "not your address" to anyone scanning.
- **Depends on:** A secp256k1 implementation (shared with T-024) and a keccak256 implementation (pure Swift, ~100 lines, no dependency required).

---

### T-026 · Solana key derivation (ed25519 + base58)
- **Status:** RESOLVED — 2026-06-06 (see SHIPPED.md entry "Review wallet screen: real ed25519 derivation + real RPC balances + honest 'Derivation pending' surface for stub chains"). `Brand/Base58.swift`, `Brand/SLIP0010.swift`, `Brand/Ed25519Derivation.swift` ship the real derivation; `KeyImportService.deriveAddresses(fromSeed:)` now returns the real Solana address at `m/44'/501'/0'/0'`.
- **Priority:** P1
- **Area:** Brand · Cryptography · Import Wallet
- **File:** `UniApp/Sources/Features/ImportWallet/KeyImportService.swift:79` (StubKeyImportService — Solana branch of `deriveAddress(fromPrivateKey:on:)`).
- **Inline comment:** `// TODO: (T-026) Replace stub with real ed25519 (Curve25519) + base58 Solana address derivation.`
- **Context:** Solana keys: 64-byte expanded ed25519 secret key (base58-encoded, ~88 chars) OR 32-byte seed. Public key = ed25519(seed); address = base58(publicKey). CryptoKit ships `Curve25519.Signing.PrivateKey` (Apple-shipped ed25519 — no dependency needed). Base58 encoding is a ~50-line pure-Swift implementation.
- **What "done" looks like:**
  1. `Base58.encode(_:) -> String` + `Base58.decode(_:) -> Data?` (`Brand/Base58.swift`).
  2. `SolanaKeyParser` — `static func parseSecretKey(_:) -> Curve25519.Signing.PrivateKey?` + `static func address(fromPrivateKey:) -> String`.
  3. Swap into `KeyImportService` for `.solana`.
- **Honesty checks:** Address validation against base58 + length (32-byte decoded). Reject any non-base58 character with a clear "Not a Solana address" message.
- **Depends on:** Base58 (shared with T-027 XRP + T-028 Cosmos).

---

### T-027 · XRP key derivation (secp256k1 OR ed25519 + base58check with XRP alphabet)
- **Status:** RESOLVED — 2026-06-06 (Trust Wallet Core via WalletCore SPM; see SHIPPED.md entry titled "Trust Wallet Core key derivation for all 24 chains + max-parallel scan pipeline").
- **Priority:** P2
- **Area:** Brand · Cryptography · Import Wallet
- **File:** `UniApp/Sources/Features/ImportWallet/KeyImportService.swift:79` (XRP branch).
- **Inline comment:** `// TODO: (T-027) Replace stub with real XRP family seed parsing + address derivation.`
- **Context:** XRP family seeds are base58check-encoded with the XRP alphabet (different from Bitcoin base58 — `r` is allowed, `0` and capital `O` are not). Seed yields private key (secp256k1 by default, ed25519 if the seed has the ed25519 prefix byte `0xED`). Address = base58check(accountID) with type byte 0.
- **What "done" looks like:**
  1. `XRPBase58` (XRP's specific alphabet).
  2. `XRPKeyParser` — parse `s...` seed, derive account ID, format `r...` address.
  3. Swap into `KeyImportService` for `.ripple`.
- **Honesty checks:** XRP addresses include a 4-byte checksum that must be verified — reject silently-wrong addresses.
- **Depends on:** secp256k1 (T-024 dependency) and ed25519 (Curve25519, Apple-shipped).

---

### T-028 · Cosmos / Kava key derivation (secp256k1 + bech32 with chain-specific HRP)
- **Status:** RESOLVED — 2026-06-06 (Trust Wallet Core via WalletCore SPM; see SHIPPED.md entry titled "Trust Wallet Core key derivation for all 24 chains + max-parallel scan pipeline").
- **Priority:** P2
- **Area:** Brand · Cryptography · Import Wallet
- **File:** `UniApp/Sources/Features/ImportWallet/KeyImportService.swift:79` (Cosmos branch).
- **Inline comment:** `// TODO: (T-028) Replace stub with real secp256k1 + bech32 Cosmos address derivation.`
- **Context:** Cosmos SDK chains use secp256k1 keys and bech32 addresses with per-chain HRP (`kava` → `kava1…`). Address = bech32(HRP, RIPEMD-160(SHA-256(compressedPublicKey))).
- **What "done" looks like:**
  1. `Bech32` (`Brand/Bech32.swift`) — encode/decode per BIP-173. ~80 lines pure Swift.
  2. `CosmosKeyParser` — given a private key and a chain's HRP, derive the bech32 address.
  3. Swap into `KeyImportService` for `.kava`.
- **Honesty checks:** HRP must match the chain. A `kava1…` address on a `cosmos…`-expecting view is a different account.
- **Depends on:** secp256k1 (T-024).

---

### T-029 · NEAR key derivation (ed25519 + named accounts)
- **Status:** PARTIAL — 2026-06-06 (see SHIPPED.md entry "Review wallet screen: real ed25519 derivation + real RPC balances + honest 'Derivation pending' surface for stub chains"). Implicit-account derivation ships via `Ed25519Derivation.nearImplicitAccount(seed:)` at `m/44'/397'/0'`. Named-account resolution (`alice.near` ↔ implicit account) remains OPEN — it requires an on-chain registration lookup and is not derivable from the seed.
- **Priority:** P2
- **Area:** Brand · Cryptography · Import Wallet
- **File:** `UniApp/Sources/Features/ImportWallet/KeyImportService.swift:79` (NEAR branch).
- **Inline comment:** `// TODO: (T-029) Replace stub with real ed25519 NEAR account derivation.`
- **Context:** NEAR keys are ed25519 (Apple-shipped Curve25519). Accounts have two forms: (a) the canonical 64-hex-char `implicit account ID` derived from the public key, and (b) human-readable `.near` named accounts that map to the implicit account via NEAR's on-chain naming. Watch-only must accept both forms.
- **What "done" looks like:**
  1. `NEARKeyParser` — derive `implicit account ID` from ed25519 public key.
  2. Address validation accepting both implicit and named (`*.near`) forms.
- **Honesty checks:** A named account points to an implicit account that the user may not own — surface the mapping when known, but never claim ownership.
- **Depends on:** ed25519 (Curve25519, Apple-shipped).

---

### T-030 · TON key derivation (ed25519 + TON address)
- **Status:** RESOLVED — 2026-06-06 (Trust Wallet Core via WalletCore SPM; see SHIPPED.md entry titled "Trust Wallet Core key derivation for all 24 chains + max-parallel scan pipeline").
- **Priority:** P2
- **Area:** Brand · Cryptography · Import Wallet
- **File:** `UniApp/Sources/Features/ImportWallet/KeyImportService.swift:79` (TON branch).
- **Inline comment:** `// TODO: (T-030) Replace stub with real ed25519 + TON address derivation.`
- **Context:** TON keys are ed25519. Addresses are 256-bit hashes of the smart-contract code + initial data, rendered as `EQ…` (bounceable) or `UQ…` (non-bounceable), base64url-encoded with a 2-byte tag + CRC-16. Watch-only import accepts either form.
- **What "done" looks like:**
  1. `TONAddress.encode(workchain:hash:bounceable:) -> String` + parser.
  2. `TONKeyParser` — derive the standard wallet contract's address from an ed25519 public key (TON wallet v4 R2 by default).
- **Honesty checks:** The same key derives different addresses per wallet contract version; the review step must name which contract version the displayed address corresponds to.
- **Depends on:** ed25519 (Curve25519). CRC-16 (~30 lines pure Swift).

---

### T-032 · Expand `KnownLeakedSeeds` blocklist
- **Status:** OPEN
- **Priority:** P2
- **Area:** Brand · Security · Import Wallet
- **File:** `UniApp/Sources/Brand/KnownLeakedSeeds.swift` (extend the two `Set<String>` constants)
- **Inline comment:** `// TODO: (T-032) Expand the blocklist over time as new tutorial seeds surface.`
- **Context:** The v1 blocklist (shipped 2026-06-05) covers BIP-39 spec test vectors, Hardhat default, Anvil default, Ganache default, and one well-documented demo seed. Many more leaked seeds exist in the wild — every YouTube wallet-tutorial seed, every PoC exploit seed, every "Trezor recovery test" seed. Expansion is a community effort and should not gate the v1 ship.
- **What "done" looks like:**
  1. Reach at least 30 well-documented leaked mnemonics + 20 leaked private keys.
  2. Each entry has a source URL or canonical reference in a code comment so future agents can audit.
  3. Add a CI test that asserts `KnownLeakedSeeds.isLeaked(mnemonic:)` returns true for at least the top-50 most-googled crypto-tutorial mnemonics (test vectors stored in `Tests/Fixtures/`).
- **Honesty checks:** the list is constant code; never a remote feed (Rule #3); no telemetry on which seeds users try.
- **Depends on:** none.

---

### T-033 · Settings → Security → "Reset import warnings"
- **Status:** RESOLVED 2026-06-06 — see SHIPPED entry "Full Settings — Wallets / Security / Preferences / Privacy / Help & About / Advanced". Shipped in `SecuritySettingsView`: conditional row visible only when `@AppStorage("hideImportKeyWarning") == true`, tap flips it back to `false`.
- **Priority:** P3
- **Area:** Features · Settings · Import Wallet
- **File:** `UniApp/Sources/Features/Settings/SettingsView.swift` (add a row under a future Security section, or as a row in the existing list)
- **Inline comment:** N/A (no inline marker yet — backlog until Settings → Security ships per T-022).
- **Context:** Once a user taps "Don't show this warning again" on `ImportSecurityWarningSheet`, `@AppStorage("hideImportKeyWarning")` is set to true. There needs to be a way to un-suppress it for users who changed their mind. Lives naturally in Settings → Security.
- **What "done" looks like:**
  1. A Settings row labeled "Reset import warnings" appears only when `@AppStorage("hideImportKeyWarning") == true`.
  2. Tapping the row sets the value to false and fires `UniHaptic.success`.
  3. After reset, the warning sheet appears again on the next Import Wallet → Recovery phrase / Private key tap.
- **Depends on:** T-022 (Settings → Security section landing).

---

### T-034 · `WatchOnlyEntryView` guide sheet — "What does watch-only mean?" — RESOLVED 2026-06-05
- **Status:** RESOLVED — see SHIPPED entry titled "Import-flow comprehensive redesign: header + chain principal + example caption + WatchOnly guide".
- **Priority:** P2
- **Area:** Features · Import Wallet · Rule #18 audit
- **File:** `UniApp/Sources/Features/ImportWallet/WatchOnlyImport.swift` (add `info.circle` toolbar item + `WatchOnlyGuideSheet` view in `ImportGuideSheets.swift`).
- **Inline comment:** `// TODO: (T-034) Add WatchOnlyGuideSheet per Rule #18 Part C audit.`
- **Context:** Per Rule #18 Part C, every entry surface that asks the user for a cryptographic artifact needs a guide sheet. Watch-only is the only Import method without one today.
- **What "done" looks like:**
  1. New `WatchOnlyGuideSheet` in `ImportGuideSheets.swift` mirroring `RecoveryPhraseGuideSheet`'s shape (hero `eye.fill`, 4-paragraph body: what watch-only is, what it looks like (a bech32 address example), how to use it, what Aperture does with it).
  2. `info.circle` toolbar button on `WatchOnlyEntryView` triggers it.
  3. New English source strings added to `Localizable.xcstrings` (~6 strings); translator agent dispatched per Rule #13.
- **Depends on:** none.

---

### T-035 · `PinSetupFlow` guide sheet — "Why does Aperture need a PIN?"
- **Status:** OPEN
- **Priority:** P2
- **Area:** Features · PIN · Rule #18 audit
- **File:** `UniApp/Sources/Features/PinCode/PinSetupFlow.swift` (add `info.circle` to `.set` step toolbar + new `PinSetupGuideSheet` view).
- **Inline comment:** `// TODO: (T-035) Add PinSetupGuideSheet per Rule #18 Part C audit.`
- **Context:** Per Rule #18 Part C, PIN-setup first step needs a guide explaining why a PIN matters and what Aperture does with it. Builds trust by making the protection mechanism transparent (Rule #16 §A.2).
- **What "done" looks like:**
  1. New `PinSetupGuideSheet` (hero `lock.shield.fill`, paragraphs: what a PIN is in Aperture's context, what it protects, where it's stored — Keychain hash, never plaintext — and that it's optional with honest skip available).
  2. `info.circle` toolbar button on `.set` step triggers the sheet.
  3. New English strings + translator dispatch per Rule #13.
- **Depends on:** none.

---

### T-036 · `PassphraseSheet` guide — "What's a passphrase?"
- **Status:** OPEN
- **Priority:** P2
- **Area:** Features · Create Wallet · Import Wallet · Rule #18 audit
- **File:** `UniApp/Sources/Features/CreateWallet/PassphraseSheet.swift` + new `PassphraseGuideSheet` view.
- **Inline comment:** `// TODO: (T-036) Add PassphraseGuideSheet per Rule #18 Part C audit.`
- **Context:** Passphrase is the most-misunderstood BIP-39 concept — many users confuse it with a wallet password. Guide sheet explains the "25th word" mechanism honestly: a memorised string that combines with the recovery phrase to derive a different wallet. State the irreversibility (we cannot recover or guess it).
- **What "done" looks like:**
  1. New `PassphraseGuideSheet` (hero `key.viewfinder`, paragraphs: what it is, what it looks like (example: an arbitrary memorable string), how it changes which wallet you get, what Aperture does — does NOT store it).
  2. `info.circle` toolbar button on `PassphraseSheet` triggers.
  3. The new disclosure-style passphrase entry in `MnemonicEntryView` (shipped 2026-06-05) also gets an `info.circle` inline (or links to the same sheet).
  4. New strings + translator dispatch.
- **Depends on:** none.

---

### T-037 · Bitcoin family balance scanner (Esplora REST)
- **Status:** OPEN
- **Priority:** P1
- **Area:** Wallet · Balance Scanner · Phase 2
- **File:** `UniApp/Sources/Wallet/BalanceScanner.swift` (new `BitcoinFamilyBalanceScanner` next to `StubBalanceScanner`).
- **Inline comment:** `// TODO: (T-037) Real Bitcoin family balance + history via mempool.space Esplora REST.`
- **Context:** Phase-1 ships `StubBalanceScanner` returning deterministic mock data. Phase 2 replaces the per-family output for `.bitcoin / .bitcoinCash / .litecoin / .dogecoin`. Endpoints: `mempool.space/api/address/<addr>` for BTC; equivalent Esplora deployments for the siblings (or chain-vendor explorers). Pure `URLSession` + JSON-RPC / REST — Rule #3.
- **What "done" looks like:**
  1. `BitcoinFamilyBalanceScanner` implementing `BalanceScanner` for the four BTC-family chains.
  2. `nativeBalance` = confirmed `funded_txo_sum - spent_txo_sum` in chain base unit (BTC).
  3. `isUsed = chain_stats.tx_count > 0 || mempool_stats.tx_count > 0`.
  4. Fiat conversion via Coinbase or similar public price feed (already used by `CurrencyPreference`).
  5. 5-second timeout, retry once on network failure.
  6. Tested against one funded + one fresh address per chain.
- **Honesty checks:** review-screen footer names `mempool.space` (and siblings) by host so the user knows where the read goes (Rule #16). No Aperture servers.
- **Depends on:** T-024 (real Bitcoin BIP-32 derivation — `StubKeyImportService` mock addresses aren't on-chain; the scanner needs real addresses).

---

### T-038 · EVM family balance scanner (`eth_getBalance` + `eth_getTransactionCount`)
- **Status:** OPEN
- **Priority:** P1
- **Area:** Wallet · Balance Scanner · Phase 2
- **File:** `UniApp/Sources/Wallet/BalanceScanner.swift` (new `EVMFamilyBalanceScanner`).
- **Inline comment:** `// TODO: (T-038) Real EVM family balance + history via JSON-RPC.`
- **Context:** One scanner covers all 12 EVM chains (Ethereum, Arbitrum, Base, Optimism, Scroll, zkSync Era, Polygon, BNB Chain, opBNB, Avalanche, Celo, Kava EVM) via per-chain public RPC endpoints (Ankr, PublicNode, chain-vendor). JSON-RPC calls: `eth_getBalance` (latest) + `eth_getTransactionCount` (latest) per address.
- **What "done" looks like:**
  1. `EVMFamilyBalanceScanner` implementing `BalanceScanner` for the 12 EVM chains.
  2. Per-chain endpoint table in code (no remote config — Rule #3).
  3. Parallel fan-out via `withThrowingTaskGroup`.
  4. `isUsed = (nonce > 0 || balance > 0)`.
  5. Wei → native conversion (1e18 divisor for most, 1e8 for some L2s — verify per chain).
- **Honesty checks:** Footer names the RPC providers (Ankr / PublicNode / etc.).
- **Depends on:** T-025 (real EVM address derivation).

---

### T-039 · Solana balance scanner
- **Status:** OPEN
- **Priority:** P1
- **Area:** Wallet · Balance Scanner · Phase 2
- **File:** `UniApp/Sources/Wallet/BalanceScanner.swift` (new `SolanaBalanceScanner`).
- **Inline comment:** `// TODO: (T-039) Real Solana balance + signature history via JSON-RPC.`
- **Context:** `getBalance` (lamports → SOL) + `getSignaturesForAddress` (first page only — presence of any signature ⇒ `isUsed = true`). Endpoint: `api.mainnet-beta.solana.com` (Solana Foundation, public, rate-limited).
- **What "done" looks like:** API as above. Lamports → SOL via 1e9 divisor.
- **Depends on:** T-026 (real Solana address derivation).

---

### T-040 · Long-tail family scanners (XRP / Cosmos / NEAR / TON / Aptos / Sui / Stellar / Polkadot / TRON)
- **Status:** OPEN
- **Priority:** P2
- **Area:** Wallet · Balance Scanner · Phase 2
- **File:** `UniApp/Sources/Wallet/BalanceScanner.swift` (per-family scanners in subfiles).
- **Inline comment:** `// TODO: (T-040) Real long-tail balance scanners.`
- **Context:** One implementation per chain family. XRPL JSON-RPC, Cosmos REST (LCD), NEAR JSON-RPC, TON HTTP API v2, Aptos REST, Sui JSON-RPC, Horizon (Stellar), Subscan or substrate-RPC (Polkadot), TronGrid (TRON).
- **What "done" looks like:** Each family ~80-120 lines, file-per-family. Tested against one funded + one fresh address per chain.
- **Depends on:** T-027 (XRP), T-028 (Cosmos), T-029 (NEAR), T-030 (TON), T-031 (Aptos/Sui/Stellar/Polkadot/TRON).

---

### T-041 · BGTaskScheduler background balance refresh
- **Status:** OPEN
- **Priority:** P3
- **Area:** Wallet · Balance Scanner · Background Fetch
- **File:** new `UniApp/Sources/Wallet/BackgroundBalanceRefresher.swift`.
- **Inline comment:** `// TODO: (T-041) Background balance refresh via BGTaskScheduler.`
- **Context:** Apple's `BGAppRefreshTask`, ~once per hour budget. Out of Phase-1 scope. When implemented, runs all enabled scanners and writes results to a `BalanceCache` actor; review screens read cache on next foreground.
- **What "done" looks like:**
  1. Registered via `Info.plist` `BGTaskSchedulerPermittedIdentifiers`.
  2. Battery-budget-aware (skip if `ProcessInfo.processInfo.isLowPowerModeEnabled == true`).
  3. User preference toggle in Settings → Privacy.
  4. Honors `@AppStorage("hideImportKeyWarning")`-style opt-out preference: `@AppStorage("backgroundBalanceRefresh")` Bool, default true.
- **Honesty checks:** Settings copy plainly names that background refresh pings public RPC providers on Aperture's behalf — and the user can turn it off.
- **Depends on:** T-037..T-040.

---

### T-031 · Aptos / Sui / Stellar / Polkadot / TRON key derivation (mixed families)
- **Status:** RESOLVED — 2026-06-06 (Trust Wallet Core via WalletCore SPM; see SHIPPED.md entry titled "Trust Wallet Core key derivation for all 24 chains + max-parallel scan pipeline").
- **Priority:** P3
- **Area:** Brand · Cryptography · Import Wallet
- **File:** `UniApp/Sources/Features/ImportWallet/KeyImportService.swift:79` (Aptos/Sui/Stellar/Polkadot/TRON branches).
- **Inline comment:** `// TODO: (T-031) Replace stub with real per-chain key derivation for Aptos / Sui / Stellar / Polkadot / TRON.`
- **Context:** Five remaining chains, three families:
  - **Aptos / Sui** — ed25519 (Curve25519). Address = first 32 bytes of `SHA-3(publicKey ‖ scheme_id)`. Aptos uses scheme_id 0, Sui uses BLAKE2b.
  - **Stellar** — ed25519. Address = StrKey-encoded public key (base32 + CRC-16). `GA…` prefix.
  - **Polkadot** — sr25519 (Schnorrkel) OR ed25519. Address = SS58-encoded public key (base58 with network prefix byte + checksum). sr25519 requires a dedicated implementation — not Apple-shipped.
  - **TRON** — secp256k1 + keccak256 (same crypto as EVM) but TRON's address encoding is base58check with a `0x41` version byte. Address starts with `T…`.
- **What "done" looks like:**
  1. Per-chain parser file in `Brand/` for each.
  2. Swap into `KeyImportService` per case.
  3. Polkadot may ship in watch-only-first mode if sr25519 implementation is deferred — explicitly state this in the UI.
- **Honesty checks:** Different chains' encodings produce visually-similar addresses. The chain logo + name in the review step must be unmistakable.
- **Depends on:** ed25519 (Apple-shipped), secp256k1 (T-024), BLAKE2b (pure Swift, ~150 lines).

---

### T-042 · Settings → Wallets (list + rename + reorder + delete)
- **Status:** RESOLVED 2026-06-06 — see SHIPPED entry "Full Settings — Wallets / Security / Preferences / Privacy / Help & About / Advanced". Shipped via `WalletsListView` (list + drag-reorder + add-wallet entry rows + conditional searchable) and `WalletDetailView` (rename + view-phrase-when-available + delete with typed-name confirm). `WalletRepository` extended with `allWalletIds()` + `deleteAllWallets()`.
- **Priority:** P1
- **Area:** Features · Settings · Multi-wallet
- **File:** future `UniApp/Sources/Features/Settings/WalletsListView.swift` + new row in `SettingsView`.
- **Inline comment:** N/A (will land when the screen does).
- **Context:** SwiftData (`WalletRecord`) now persists every wallet the user creates or imports per the 2026-06-06 database landing. Settings needs a surface to list, rename (`WalletRepository.renameWallet`), reorder (drag → update `sortOrder`), and delete (`WalletRepository.deleteWallet` + `SeedVault.deleteSeed`) those wallets — the multi-wallet UX entry point that the schema was built for.
- **What "done" looks like:**
  1. New row in `SettingsView` ("Wallets · N") leading `wallet.bifold` (or equivalent SF Symbol), trailing chevron + count.
  2. `WalletsListView` — `@Query` of `WalletRecord` sorted by `sortOrder`, `insetGrouped` list; row shows name + kind + masked id; swipe-to-delete with two-tap confirm (Rule #16 honest irreversibility); drag-handle reorders.
  3. Tap row → push `WalletDetailView` (rename field + show backup status + delete button).
  4. Delete cascades: `WalletRepository.deleteWallet(id:)` removes the SwiftData row (cascading addresses/transactions/balances), then `SeedVault.deleteSeed(for:)` removes the Keychain item. Both wrapped in a single `do { try await ... }` so a Keychain failure surfaces as a footnote.
- **Honesty checks (Rule #16):** delete confirmation names the consequence plainly ("This deletes the wallet from this iPhone. The recovery phrase is still yours.").
- **Depends on:** T-018 (wallet home — to know what the multi-wallet UX should switch *between*).

---

### T-043 · Tests for persistence layer (SwiftData + SeedVault + BiometricEnrollmentTracker)
- **Status:** OPEN
- **Priority:** P1
- **Area:** Database · Security · Testing
- **File:** future `UniApp/Tests/` (no test target yet — needs xcodegen scheme + Swift Testing import).
- **Inline comment:** N/A.
- **Context:** Common testing rule (`~/.claude/rules/common-testing.md`) requires 80% coverage; the database layer landed 2026-06-06 with zero tests. This entry tracks the catch-up.
- **What "done" looks like:**
  1. Swift Testing target added via `xcodegen` (`@Test`, `#expect`).
  2. `WalletRepositoryTests` — in-memory `ModelConfiguration(isStoredInMemoryOnly: true)` fixture, asserts insert/rename/delete/sortOrder behavior, asserts cascade deletion (deleting a wallet removes its addresses/transactions/balances).
  3. `SeedVaultTests` — assert round-trip seed → AES-GCM → seed, assert wrong-key tamper rejection, assert `noSuchWallet` on missing items, assert delete idempotency. Use a UUID-namespaced Keychain service so tests don't collide with the app's items.
  4. `BiometricEnrollmentTrackerTests` — assert snapshot capture, assert mismatch detection sets `requiresBiometricReenrollment`, assert acknowledge clears the flag. (Biometric domain state itself isn't mockable on simulator — these tests inject a synthetic snapshot via a test-only seam.)
  5. CI coverage target ≥ 80% on `Database/` and `Security/` directories per global rule.
- **Depends on:** none.

---

### T-044 · Background balance sync writing to SwiftData
- **Status:** OPEN
- **Priority:** P2
- **Area:** Wallet · Background sync · Phase 2
- **File:** consumer of T-037..T-040 scanners + `TransactionRepository.upsertBalance` / `upsertTransaction`.
- **Inline comment:** N/A (lands when the scanners do).
- **Context:** The `TransactionRepository` actor is built and exposes upsert methods; T-041 (BGTaskScheduler background refresh) and T-037..T-040 (per-family scanners) need a coordinator that drives them and writes to the repository. The wallet screen reads from the repository via `@Query`, so the path is one-way (scanner → DB → view) — no glue needed in feature views beyond the `@Query`.
- **What "done" looks like:**
  1. `BalanceSyncCoordinator` (`Wallet/BalanceSyncCoordinator.swift`) — actor that takes a list of `WalletAddressRecord.id`s + the appropriate per-family scanner + the `TransactionRepository`, fans out scans in parallel via `withThrowingTaskGroup`, upserts results.
  2. Foreground trigger: call from the wallet screen's `.task { ... }` modifier so the first appear refreshes balances opportunistically.
  3. Background trigger: invoked by `BGAppRefreshTask` (T-041).
  4. Coalescing: per-address debounce so a foreground refresh + a near-simultaneous background refresh don't double-fetch.
- **Depends on:** T-037..T-041 (scanners + BGTaskScheduler).

---

### T-045 · Optional CloudKit mirror for SwiftData store
- **Status:** OPEN
- **Priority:** P3 (defer until user demand)
- **Area:** Database · Sync
- **File:** `ApertureDatabase.swift` — switch `cloudKitDatabase: .none` to `.private(...)`.
- **Inline comment:** N/A.
- **Context:** SwiftData supports first-party CloudKit mirroring (`ModelConfiguration(cloudKitDatabase: .private(...))`). Today we use `.none` so the wallet metadata is iPhone-local matching Aperture's posture. A future user opt-in could enable cross-device sync of wallet *metadata* (names, addresses, txns) — but **NEVER** of seed material (Keychain ACL is `ThisDeviceOnly`; CloudKit Keychain sync is a separate user choice via Settings → iCloud Keychain). Surfacing this would require Settings → Wallets → "Sync wallet list across devices" toggle + clear copy explaining the boundary ("addresses sync; recovery phrases do not — they live on each device").
- **What "done" looks like:**
  1. CloudKit container provisioned + entitlement enabled.
  2. Per-record `cloudKitDatabase` opt-in path (some `@Model` types might stay local-only).
  3. Settings row with honest copy.
  4. Schema additions tracked under a new schema version (`ApertureSchemaV2`).
- **Honesty checks (Rule #16):** the toggle copy must state plainly that the seed (Keychain) does NOT sync via this toggle — that's a separate iOS-Keychain-iCloud concern.
- **Depends on:** T-042 (Settings → Wallets surface exists first).

---

### T-046 · Re-enter backup flow against the *specific* unbacked wallet
- **Status:** OPEN
- **Priority:** P1
- **Area:** Features · Wallet home · Backup recovery
- **File:** `UniApp/Sources/Features/Wallet/WalletHomeView.swift` (`banners` view — inline `// TODO: (T-046)` placed at the `BackupRequiredBanner`'s `onBackUpNow` callback).
- **Inline comment:** `// TODO: (T-046) Re-enter the backup flow against this specific wallet rather than the default create flow.`
- **Context:** Today the wallet-home's `BackupRequiredBanner` taps simply present the default `RecoveryPhraseFlow` cover, which creates *a new* wallet — not what the user wants. The user wants to verify the *existing* unbacked wallet's mnemonic. Needs a variant of `RecoveryPhraseFlow` (or a new `BackupExistingWalletFlow`) that reads the active wallet's seed from `SeedVault.loadSeed(for:)`, reconstructs the mnemonic from the stored seed (BIP-39 reverse derivation isn't trivial — the seed alone doesn't reveal the mnemonic, so this needs to be handled at create time by storing the mnemonic separately in a second Keychain item OR by skipping seed-only persistence for unbacked wallets and instead persisting the mnemonic until verification clears the flag).
- **What "done" looks like:**
  1. Decide the seed-vs-mnemonic-storage policy for unbacked wallets.
  2. Implement `BackupExistingWalletFlow` (or extend `RecoveryPhraseFlow` with a `mode: .new | .verifyExisting(walletId:)` parameter).
  3. On verify success, call `WalletRepository.markBackupComplete(id:)` so the banner disappears.
- **Honesty checks (Rule #16):** if the seed-vs-mnemonic decision is "store the mnemonic until verified, then delete it", the user must be told plainly at skip time that "your phrase is stored locally and encrypted on this iPhone until you back it up — backing up deletes the local copy." A user expecting "skip means we never store the phrase" deserves the truth.
- **Depends on:** T-016 (Settings → Wallets "back up your recovery phrase" row — adjacent surface).

---

### T-047 · Receive screen — chain selection + QR code + share sheet
- **Status:** OPEN (placeholder `ReceivePlaceholderView` shipped 2026-06-06)
- **Priority:** P0
- **Area:** Features · Wallet · Send / Receive
- **File:** future `UniApp/Sources/Features/Wallet/Receive/ReceiveView.swift` (+ chain picker, address card, QR view).
- **Inline comment:** N/A (placeholder is calm copy only).
- **Context:** Receive needs: (1) chain picker per wallet's available addresses, (2) selected chain's address rendered as a copyable text + QR code (CoreImage's `CIFilter.qrCodeGenerator()` per Rule #3 — native-only, no SPM), (3) share sheet via `UIActivityViewController` / SwiftUI `ShareLink`, (4) optional "request specific amount" affordance (chain-specific URI generation: `bitcoin:`, `ethereum:`, `solana:`, etc.).
- **What "done" looks like:**
  1. Chain picker (Rule #14 native `.searchable` if > ~8 chains visible).
  2. Address card: QR code centered, monospaced address below, "Copy address" `UniButton(.secondary)`.
  3. ShareLink with a chain-specific URI when present, falling back to the bare address.
  4. Per Rule #18: `info.circle` toolbar item → "What's an address?" guide sheet explaining that addresses are public and safe to share.
- **Honesty checks (Rule #16):** the QR code is generated on-device. The address is the user's. Aperture sends nothing.
- **Depends on:** none (the persisted addresses already exist in `WalletAddressRecord`).

---

### T-048 · Send screen — recipient + amount + fee + confirm + sign + broadcast
- **Status:** OPEN (placeholder `SendPlaceholderView` shipped 2026-06-06)
- **Priority:** P0
- **Area:** Features · Wallet · Send / Receive
- **File:** future `UniApp/Sources/Features/Wallet/Send/`.
- **Context:** The complete flow: pick token → enter recipient → enter amount (with max button + fee estimate) → confirm → biometric/PIN gate → sign locally via the per-chain key derivation (T-024..T-031) → broadcast via per-chain RPC (T-037..T-040 shape, write side). Watch-only wallets cannot send (the wallet-home already disables the action; the Send screen never reaches signing on a watch-only).
- **What "done" looks like:**
  1. Recipient field with address validation per chain (clipboard-paste, QR-scan via `AVCaptureSession`).
  2. Amount field with max-button + per-chain fee estimate.
  3. Confirm screen with all parameters laid out plainly (Rule #16 — honest about what the user is about to commit to).
  4. PIN/biometric gate before signing (`PinCodeView(mode: .verify)` per Rule #17).
  5. Broadcast + tx-hash returned → optimistic `TransactionRecord` insert with `status: .pending`.
- **Honesty checks (Rule #16):** the confirm screen names the destination, amount in native + fiat, fee in native + fiat, and the chain — never abstract. "You are sending 0.1 ETH to 0x… on Ethereum. Network fee 0.0003 ETH ($0.65). This cannot be undone."
- **Depends on:** T-024..T-031 (per-chain signing), T-037..T-040 (per-chain broadcast endpoints — same RPCs the scanners use, write side), Rule #17 PIN/biometric gate.

---

### T-049 · `UniButton` circular icon-only variant (or `UniIconButton` companion)
- **Status:** OPEN
- **Priority:** P2
- **Area:** Design system · Components
- **File:** `UniApp/Sources/DesignSystem/Components/UniButton.swift` or new `UniIconButton.swift`.
- **Inline comment:** N/A (the current inline `Button { ... }.buttonStyle(.glassProminent)` in `WalletActionRegion` is the unhonored Rule #19 surface).
- **Context:** Rule #19 wants every CTA through `UniButton`. The current `UniButton` is text-label-only — circular glyph-only CTAs (the wallet-home action region's three round Send/Receive/Swap buttons, future floating actions on per-screen layouts) can't be expressed by it. Today's `WalletActionRegion` uses raw `Button { ... }.buttonStyle(.glassProminent)` calls as a scoped exception; making this a system primitive removes the exception.
- **What "done" looks like:**
  1. Either add a `UniButton.Style.icon(systemName: String, size: CGFloat)` variant OR introduce a companion `UniIconButton(systemImage:variant:action:)` with the four variants.
  2. Migrate `WalletActionRegion` to the new primitive.
  3. Document in `CLAUDE.md` Rule #19 §C as the canonical way to build circular glyph-only CTAs.
  4. Per the variant's default haptic (Rule #10 §E), the icon button inherits its variant's haptic too.
- **Depends on:** none.

---

### T-050 · Real per-chain decimals in the scan / persistence pipeline
- **Status:** OPEN
- **Priority:** P1
- **Area:** Wallet · Balance pipeline · Database
- **File:** `UniApp/Sources/Features/Wallet/WalletRefreshCoordinator.swift` (currently stores `decimals: 0` and `rawBalance` as a decimal-string).
- **Inline comment:** Documented in the coordinator's per-address `scan` method.
- **Context:** v1 stores the stub scanner's `nativeBalance` (already in chain base units, as a `Decimal`) as a decimal-string with `decimals: 0` so `WalletFormatting.decimalAmount` round-trips identity. This is a slight schema misuse — the `TokenBalanceRecord.rawBalance` documented contract is "the chain's base-unit integer" (satoshis for BTC, wei for ETH). When real per-family scanners land (T-037..T-040) they'll return on-chain raw integer values, and the persistence pipeline needs to know each chain's native decimals (8 / 18 / 9 / 6 / etc.).
- **What "done" looks like:**
  1. Add `SupportedChain.nativeDecimals: Int` (Bitcoin family = 8, EVM = 18, Solana = 9, Polkadot = 10, TRON = 6, NEAR = 24, …).
  2. Update `WalletRefreshCoordinator.scan` to call into the real per-family scanner and persist with the chain's real decimals.
  3. The wallet-home's `AssetRow` already calls `WalletFormatting.decimalAmount(rawBalance:decimals:)` correctly — no read-side change needed.
- **Depends on:** T-037..T-040 (real per-chain scanners landing).

---

### T-051 · Transaction detail — block explorer link + contract data decoding
- **Status:** OPEN (placeholder `TransactionDetailView` shipped 2026-06-06)
- **Priority:** P3
- **Area:** Features · Wallet · Transaction detail
- **File:** `UniApp/Sources/Features/Wallet/TransactionDetailView.swift` (currently a read-only summary).
- **Inline comment:** N/A.
- **Context:** Today's detail surface lists hash / block / fee / counterparty / when / status. Two natural extensions: (1) a "View on \(explorer)" `Link` that opens the chain-appropriate block-explorer URL in Safari (mempool.space for BTC, etherscan/arbiscan/basescan/etc for EVM, solscan for SOL, …); (2) contract-call data decoding for EVM tx that interact with known contracts (ERC-20 transfer → "Sent 100 USDC to 0x…").
- **What "done" looks like:**
  1. `SupportedChain.explorerURL(forTxHash:)` returning a URL or nil.
  2. `UniButton(.tertiary)` "View on \(host)" that opens via SwiftUI `Link` (no in-app browser per Rule #3).
  3. EVM contract data decoding for the top-N stablecoins (ERC-20 `transfer(address,uint256)`); other contracts fall back to "Contract interaction."
- **Honesty checks (Rule #16):** the explorer hostname is named in the link copy ("View on etherscan.io") so the user knows where the click goes (Rule #16 §A.5).
- **Depends on:** none.

---

### T-052 · `AppLockView` — auto-trigger biometric prompt on appear when biometric is enabled
- **Status:** OPEN
- **Priority:** P1
- **Area:** Security · App lock
- **File:** `UniApp/Sources/Features/Wallet/AppLockView.swift`.
- **Inline comment:** N/A.
- **Context:** Today's `AppLockView` shows the PIN keypad and exposes the biometric trigger button. When biometric is enabled, the user expects the Face ID prompt to fire automatically on appear (matching iOS lock-screen behavior) so unlock is one glance rather than a tap. Easy add — `.task { if biometricEnabled { await trigger } }` calling `BiometricService.authenticate(reason:)` and on success calling `lockController.unlock()`.
- **What "done" looks like:**
  1. On `AppLockView` appear, if `@AppStorage("biometricEnabled") == true` and `BiometricService.isAvailable`, invoke `authenticate` automatically.
  2. On success: `lockController.unlock()` + capture new snapshot.
  3. On failure (user cancelled / failed): leave the PIN keypad available as fallback. No retry storm.
  4. If biometric is disabled or unavailable, PIN-only path remains the unchanged default.
- **Depends on:** none.

---

### T-053 · EVM family: full 12-chain RPC registry + adapter coverage
- **Status:** OPEN (Ethereum-only Phase 1 shipped 2026-06-06 — `docs/RPC-ARCHITECTURE.md` Phases 0+1)
- **Priority:** P1
- **Area:** Networking · EVM · Phase 2
- **File:** `UniApp/Sources/Networking/RPCRegistry.swift` (add 11 entries) + `UniApp/Sources/Features/Wallet/WalletRefreshCoordinator.swift` (broaden the `.ethereum`-only gate to all EVM chains)
- **Context:** Phase 1 wires Ethereum end-to-end via `RPCClient` + `EVMChainAdapter`. The other 11 EVM chains use the same adapter — they just need registry entries. Per `docs/RPC-ARCHITECTURE.md` §2.2.1, publicnode is the primary for: arbitrum, base, optimism, polygon, bnbChain, opBNB, avalanche, celo, scroll, zkSync, kavaEvm. Each entry needs ≥ 1 alternative-provider fallback (Ankr / chain-vendor RPC) and ideally a third fallback.
- **What "done" looks like:**
  1. 11 new `SupportedChain → [RPCEndpoint]` entries in `RPCRegistry.catalog`.
  2. `WalletRefreshCoordinator.scan` gate widened from `address.chain == .ethereum` to `address.chain.family == .evm` (or equivalent — needs `SupportedChain.family` accessor if not present).
  3. Validated on Thuglife against a real test address on each chain with known on-chain balance.
- **Depends on:** none (Phase 1 foundation is shipped).

---

### T-054 · Bitcoin family adapter (mempool.space REST + Esplora siblings)
- **Status:** OPEN
- **Priority:** P1
- **Area:** Networking · Bitcoin family · Phase 3
- **File:** new `UniApp/Sources/Networking/BitcoinFamilyAdapter.swift` + REST registry entries
- **Context:** Per `docs/RPC-ARCHITECTURE.md` §3.2, mempool.space is the canonical REST pattern for Bitcoin. BCH/LTC/DOGE use Esplora-shaped siblings (blockchain.info, bch.loping.net, dogechain.info). REST not JSON-RPC — `RPCClient.callREST` already handles it.
- **What "done" looks like:**
  1. New adapter mirroring `EVMChainAdapter`'s shape: `fetchNativeBalance(address) -> Decimal`, `fetchAccountSummary -> (balance, isUsed)`.
  2. Registry entries for `.bitcoin / .bitcoinCash / .litecoin / .dogecoin` with primary `mempool.space` + ≥ 1 fallback per chain.
  3. Coordinator gate extended.
- **Depends on:** T-053 (so the EVM path is stable before we open a second family).

---

### T-055 · Solana / XRP / Stellar adapters
- **Status:** OPEN
- **Priority:** P2
- **Area:** Networking · Long-tail L1 · Phase 4
- **File:** new `Networking/SolanaChainAdapter.swift`, `Networking/XRPChainAdapter.swift`, `Networking/StellarChainAdapter.swift`
- **Context:** Solana → JSON-RPC against `api.mainnet-beta.solana.com` (`getBalance` for native, `getTokenAccountsByOwner` for SPL). XRP → JSON-RPC against `s1.ripple.com:51234` (`account_info`). Stellar → REST against `horizon.stellar.org` (`/accounts/{id}`).
- **What "done" looks like:** three adapter files + registry entries + coordinator gates. Real-address validation on each chain.
- **Depends on:** T-054 (REST path proven).

---

### T-056 · NEAR / TON / TRON / Polkadot / Aptos / Sui / Cosmos adapters
- **Status:** OPEN
- **Priority:** P2-P3
- **Area:** Networking · Long-tail L1 · Phase 5
- **File:** one adapter file per chain (~7 files).
- **Context:** Per `docs/RPC-ARCHITECTURE.md` §2.2.1 list. Each chain ~80-120 lines.
- **What "done" looks like:** each chain returns a real balance on its row in the wallet home. Registry entries with ≥ 2 fallbacks per chain.
- **Depends on:** T-055.

---

### T-057 · Per-chain transaction history (logs / explorer REST)
- **Status:** OPEN
- **Priority:** P1
- **Area:** Networking · Transaction history · Phase 6
- **File:** extend each chain adapter with `fetchRecentTransactions(address, limit: Int) -> [TxRecord]`. `TransactionRepository.upsertTransaction(...)` already exists.
- **Context:** Phase 1-5 deliver real balances. Phase 6 delivers real transaction history. EVM: `eth_getLogs` on ERC-20 `Transfer(address,address,uint256)` topic filtered by address. Bitcoin family: `mempool.space/api/address/{addr}/txs`. Solana: `getSignaturesForAddress`. Each chain has its own pagination model.
- **What "done" looks like:** the wallet home's "Recent activity" section populates from real on-chain data per chain. Honest "loaded from <provider>" footnote per row.
- **Depends on:** T-053..T-056 (balance path stable).

---

### T-058 · UI polish — "Last synced via X" footers + retry button
- **Status:** OPEN
- **Priority:** P2
- **Area:** Wallet home · Honesty surfaces
- **File:** `UniApp/Sources/Features/Wallet/WalletHomeHeader.swift`, new per-chain row footer.
- **Context:** Per `docs/RPC-ARCHITECTURE.md` §7, every chain row should name the provider that served the read. Currently the header's roll-up just says "Last synced 2m ago" — should add "via publicnode.com." When `RPCError.allEndpointsFailed`, show a tap-to-retry chain-row footer.
- **What "done" looks like:** every chain row shows provider attribution. Failed chains have an obvious retry path.
- **Depends on:** T-053..T-056.

---

### T-059 · Settings → About → Network providers
- **Status:** OPEN
- **Priority:** P3
- **Area:** Settings · Privacy · Transparency
- **File:** new `Features/Settings/NetworkProvidersView.swift`.
- **Context:** Per `docs/RPC-ARCHITECTURE.md` §7, the user should be able to see every chain's primary + fallback providers in honest order. Settings → About → Network providers lists them.
- **What "done" looks like:** scrollable list of all 24 chains, each with primary + fallbacks named, in priority order.
- **Depends on:** T-053..T-056 (the registry is populated).

---

### T-060 · Receive screen v2 — amount entry, memo / destination tag, brightness boost, save-as-image

- **Status:** OPEN
- **Priority:** P2
- **Area:** Features/Receive
- **Inline marker:** none yet (file: `UniApp/Sources/Features/Receive/ReceiveView.swift` — body's `actionRow` is the natural insertion point; a TODO marker will be added when v2 work starts).
- **Context:** Receive v1 ships (SHIPPED.md 2026-06-06) with the
  v1 contract — *show the address; share the address; warn about
  the network*. v2 closes the bonus features intentionally
  deferred there.
- **What "done" looks like:**
  1. **Amount field**: optional decimal entry with the chain's
     native ticker label. When the user enters a value, the
     screen's QR payload switches from the bare address to a
     chain-URI: `bitcoin:bc1q…?amount=0.001` /
     `ethereum:0x…?value=<wei>` / `solana:<addr>?amount=<lamports>`.
     Pure URI encoding — no third-party package.
  2. **Memo / destination tag**: only surfaced when
     `chain ∈ {.ripple, .stellar, .ton}`. For other chains the
     field is hidden (memos there are address-prefix nonsense
     and would confuse the user). The memo is encoded into the
     payment URI per each chain's convention.
  3. **Brightness boost**: on `.onAppear` push
     `UIScreen.main.brightness` to 1.0; restore on `.onDisappear`.
     Store the original brightness in `@State` so the restore is
     honest. Gated on a user preference
     (`@AppStorage("autoBrightnessOnReceive")`, default `true`).
  4. **Save QR as image**: trailing `UniButton(.secondary)` "Save
     image" that renders the `ReceiveQRCard` body to a UIImage
     via `ImageRenderer` and writes via `PHPhotoLibrary` with
     prior auth. Requires `NSPhotoLibraryAddUsageDescription`
     Info.plist key (`INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription`
     in `project.yml`).
- **Honesty checks:** the amount field must never display the
  user's address-amount combo as if the funds had already
  arrived. The amount is the *request* — copy in v2 should read
  "Request 0.001 BTC" rather than "Amount: 0.001 BTC".
- **Depends on:** none.

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
- **Status:** SPLIT 2026-06-04. The PIN-side + biometric-toggle half **shipped** under Rule #17 (see `SHIPPED.md` entry titled "Unified PIN + Face ID per Rule #17 — PinCodeView, BiometricService, PinCodeStorage, PinSetupFlow"). The seed-encryption-by-PIN-derived-key half remains **OPEN**.
- **Priority:** P0
- **Area:** Onboarding · Create-wallet flow Step 5
- **File:** future addition wiring `PinCodeStorage`'s derived key into a `WalletService.persistSeed(_:)` Keychain write.
- **Context (shipped half):** `BiometricService` (`UniApp/Sources/Security/BiometricService.swift`) wraps `LocalAuthentication` with a single `authenticate(reason:)` async API per Rule #17 §B — feature code never imports `LAContext` directly. `PinCodeStorage` (`UniApp/Sources/Security/PinCodeStorage.swift`) holds a PBKDF2-HMAC-SHA256 hash (100,000 iterations, 16-byte random salt, constant-time compare) in Keychain under `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. `PinSetupFlow` invites the user post-`BackupVerifyView` to set a 6-digit PIN and (optionally) enable biometrics. Skip is honest via `PinSkipWarningSheet`.
- **What "done" looks like (remaining half — seed encryption):**
  1. `WalletService.persistSeed(_ words: [String]) async throws` — derives a Keychain-stored encryption key from the user's PIN (when set) or directly from device-class protection (when no PIN), encrypts the 64-byte BIP-39 seed via AES-GCM, and writes the ciphertext to Keychain.
  2. On every subsequent app launch, the unlock flow runs `PinCodeView(mode: .verify)` (when `pinEnabled == true`) or the biometric prompt (when `biometricEnabled == true`), then unwraps the seed for the session.
  3. On Face ID refusal, fall back to PIN verify. On no-PIN, no-biometric path, the seed unlocks via device-passcode-protected Keychain item access.
- **Depends on:** T-010 (shipped), T-008 (domain protocol still open). Closely related to T-019 (passphrase storage adopts the same PBKDF2-derived key when it lands).

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

### T-022 · Settings → Security section (Change PIN / Disable PIN / Toggle biometrics)
- **Status:** RESOLVED 2026-06-06 — see SHIPPED entry "Full Settings — Wallets / Security / Preferences / Privacy / Help & About / Advanced". Shipped via `SecuritySettingsView` (PIN enable/change/disable via `Menu`-driven row + `PinChangeFlow` + `PinDisableVerifyFlow`), biometric toggle (only when PIN enabled + `BiometricService.isAvailable`), auto-lock duration via `AutoLockPickerView` (5 options), reset import warnings row, plus the **auto-lock screen itself** via `AppLockView` + `AutoLockController` (ScenePhase-observed, cold-launch-locked when PIN enabled, configurable threshold). Resolves T-023 (App-launch lock screen) at the same time.
- **Priority:** P1
- **Area:** Settings · Security
- **Context:** Rule #17 establishes one PIN UI (`PinCodeView`), one biometric service (`BiometricService`), and one storage layer (`PinCodeStorage`). The create-wallet flow now uses them once. The next surface that needs them is **Settings → Security** so a user who skipped PIN setup at create-wallet can enable it later, and a user who set one can change or disable it. Per Rule #17 §F, every PIN-required surface reuses `PinCodeView` with a different `mode`; no second PIN UI is built.
- **What "done" looks like:**
  1. New row group in `SettingsView` under a "Security" section header: "PIN" (toggle row showing on/off state + chevron to enter the PIN management screen) and "Face ID" / "Touch ID" / "Optic ID" (toggle row, only shown when `BiometricService.isAvailable`).
  2. Tapping the PIN row pushes a `SecurityPinManagementView` that exposes three actions depending on `PinCodePreference.isPinEnabled()`:
     - If PIN is enabled: "Change PIN" (verify current → set new → confirm new), "Disable PIN" (verify current → `PinCodeStorage.clear()` + `pinEnabled = false` + also flip `biometricEnabled = false` since biometric is a per-PIN convenience).
     - If PIN is disabled: "Enable PIN" (set → confirm → invite biometric prompt — same `PinSetupFlow`-style sequence).
  3. The biometric toggle row directly flips `biometricEnabled`; flipping to `true` invokes `BiometricService.authenticate(reason:)` and refuses the flip if authentication fails.
  4. All copy flows through `Localizable.xcstrings` (Rule #9).
- **Honesty checks (Rule #2 §A.7 + Rule #16):** "Disable PIN" must name the consequence ("Without a PIN, your wallet is only protected by your iPhone's lock screen") — reuses `PinSkipWarningSheet`'s shape. Biometric toggle to `false` is silent (the user is reducing convenience, not security).
- **Depends on:** Settings surface for a "Security" section; T-012's seed-encryption half is independent.

### T-023 · App-launch lock screen — `PinCodeView(mode: .verify)` when `pinEnabled == true`
- **Status:** RESOLVED 2026-06-06 — see SHIPPED entry "Full Settings — Wallets / Security / Preferences / Privacy / Help & About / Advanced". Shipped via `AppLockView` + `AutoLockController`. Cold-launch policy: locked iff PIN is enabled. Background-return policy: locked when `(now - backgroundedAt) ≥ AutoLockPreference.resolvedDuration(raw)` (5 user-selectable options). Reuses `PinCodeView(mode: .verify)` per Rule #17 § H. "Forgot PIN?" presents a Rule #16-honest sheet explaining there is no PIN reset; recovery requires reinstalling + importing from the recovery phrase. **T-052 tracks the open follow-up: auto-trigger the biometric prompt on `AppLockView` appear when biometric is enabled.**
- **Priority:** P1
- **Area:** App shell · Security
- **Context:** Once the user has set a PIN, every cold launch / foreground-from-background transition must gate the wallet home behind `PinCodeView(mode: .verify)` (or the biometric trigger when `biometricEnabled == true`). This is the second muscle-memory surface for the PIN per Rule #17 §H — same dots, same keypad, same Face ID fallback position as the create-wallet PIN. **Reuses `PinCodeView` — no second implementation built.**
- **What "done" looks like:**
  1. `UniAppApp` (or a `RootRouter`) reads `PinCodePreference.isPinEnabled()` at scene-active time. When `true`, present `PinCodeView(mode: .verify)` as a `.fullScreenCover` over the wallet home until the user authenticates.
  2. If `biometricEnabled == true` and `BiometricService.isAvailable == true`, automatically invoke `BiometricService.authenticate(reason: "Unlock Aperture with Face ID.")` on present; the user can still fall back to PIN entry by tapping a digit.
  3. The `onForgotPin` closure passed to `PinCodeView` presents a "Reset wallet via recovery phrase" path — losing the PIN is recoverable only by restoring from the BIP-39 mnemonic, never by Aperture (Rule #16 §A.6 honest limit).
  4. Foreground-from-background re-presents the lock if the app was backgrounded for more than N seconds (TBD design — 30s is the iOS default for many wallet apps).
- **Honesty checks:** the "Forgot PIN?" sheet must clearly state the trade-off — recovery via mnemonic re-imports the wallet, it does not "reset the PIN."
- **Depends on:** T-018 (wallet home destination), T-012's seed-encryption half (so the unlock has something meaningful to unlock).

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
