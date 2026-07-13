# Aperture localization audit

- **Catalog:** `/Users/thuglifex/Desktop/aperture/Aperture/Resources/Localizable.xcstrings`
- **Keys:** 2422
- **Findings:** 91
- **Generated:** 2026-07-12 09:57 UTC

## Summary

| Severity | Count |
|----------|------:|
| high | 1 |
| medium | 28 |
| low | 62 |

| Category | Count |
|----------|------:|
| `interpolation_in_ui` | 62 |
| `verbatim_bypass` | 28 |
| `process_locale_api` | 1 |

## interpolation_in_ui (62)

| Sev | Location | Key / detail |
|-----|----------|--------------|
| low | `Aperture/Sources/Diagnostics/DiagnosticsLogView.swift:24` | `\(entries.count) recent entries` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/ImportWallet/ImportWalletFlow.swift:414` | `About \(Text(title))` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/ImportWallet/WatchOnlyImport.swift:173` | `\(valid) valid · \(invalid) invalid` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/PinCode/PinCodeView.swift:482` | `Try again in \(lockoutCountdown)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/PinCode/PinCodeView.swift:508` | `\(n) attempts remaining` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/PinCode/PinCodeView.swift:509` | `Wrong passcode. \(attempts).` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Receive/ReceiveAddressRow.swift:24` | `Address \(spokenAddress)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Receive/ReceiveEVMAccountSearchSheet.swift:101` | `\(chain.displayName) accounts` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Receive/ReceiveEVMAccountSearchSheet.swift:110` | `Aperture derives account addresses locally, checks \(chain.displayName) nativ…` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Receive/ReceiveEVMAccountSearchSheet.swift:694` | `Checking \(request.candidates.count) accounts` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Receive/ReceiveEVMAccountSearchSheet.swift:697` | `\(request.chain.displayName) balances, history, and supported token balances …` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Receive/ReceiveEVMAccountSearchSheet.swift:806` | `Choose where Aperture should make Account \(result.accountIndex) the preferre…` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Receive/ReceiveEVMAccountSearchSheet.swift:895` | `Account \(result.accountIndex)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Receive/ReceiveEVMAccountSearchSheet.swift:920` | `\(hideBalances ? WalletFormatting.hiddenAmount : result.displayNativeBalance)…` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Receive/ReceiveNetworkFirstView.swift:65` | `Choose network for \(assetPrefill.symbol)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Receive/ReceiveNetworkFirstView.swift:144` | `Receive \(assetPrefill.symbol) on this network` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Receive/ReceiveNetworkPickerView.swift:51` | `Receive \(symbol) on this network` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Receive/ReceiveNetworkPickerView.swift:66` | `Choose network for \(symbol)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Receive/ReceiveSolanaAccountSearchSheet.swift:586` | `\(hideBalances ? WalletFormatting.hiddenAmount : result.displayNativeBalance)…` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Receive/ReceiveSolanaAccountSearchSheet.swift:736` | `Checking \(request.candidates.count) Solana addresses` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Send/SendAmountEntry.swift:380` | `Amounts (\(model.amounts.count))` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Send/SendDataSheets.swift:179` | `Detected: \(type)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Send/SendNetworkFirstView.swift:170` | `Choose network for \(assetPrefill.symbol)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Send/SendNetworkFirstView.swift:190` | `Send \(assetPrefill.symbol) on this network` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Send/SendNetworkPickerView.swift:60` | `Send \(symbol) on this network` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Send/SendNetworkPickerView.swift:75` | `Choose network for \(symbol)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Send/SendRecipientView.swift:424` | `Detected: \(type)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Settings/AddCustomTokenSheet.swift:118` | `Add on \(chain.displayName)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Settings/AddCustomTokenSheet.swift:247` | `Add a custom token on \(chain.displayName)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Settings/BitcoinPathSearchView.swift:173` | `This run checks \(targetCountLabel). Keep searches under \(BitcoinPathSearchR…` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Settings/ExportKeysFlow.swift:482` | `\(entry.chain.displayName) private key` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Settings/ResetApertureFlow.swift:216` | `Type \(Text(verbatim: confirmWord).foregroundColor(UniColors.Text.primary).bo…` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Settings/WalletBackupFlow.swift:837` | `Copy all \(words.count) words onto paper, in order, and store them somewhere …` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Settings/WalletDeleteSheet.swift:117` | `Remove \(walletName)?` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Settings/WalletsListView.swift:867` | `Balance filters use cached wallet totals in \(currencyCode).` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Settings/WalletsListView.swift:1130` | `\(chain.displayName) network` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/AllSupportedAssetsFilterSheet.swift:375` | `\(chain.displayName) network` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/AllSupportedAssetsView.swift:192` | `\(row.chain.displayName) details` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/AllSupportedAssetsView.swift:211` | `\(row.symbol) details` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/AssetDetailFilterSheet.swift:445` | `\(row.chain.displayName) network` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/AssetDetailView.swift:418` | `Total \(derived.displayName) balance` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/AssetDetailView.swift:579` | `View all \(rows.count) transactions` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/AssetNetworkDetailView.swift:290` | `Not held on \(chain.displayName)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/BalanceCardView.swift:158` | `Switch wallet, currently \(walletName)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/BalanceCardView.swift:274` | `Total balance \(value). Add crypto to get started.` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/BalanceCardView.swift:276` | `Total balance \(value)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/HoldingsTokenRow.swift:37` | `on \(chain.displayName)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/SolanaPathBalanceRow.swift:54` | `\(line.style.title), selected for send, \(WalletFormatting.native(line.amount…` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/TokenHoldingRow.swift:58` | `on \(chain.displayName)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/TransactionDetailView.swift:669` | `Copy \(field.label)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/TransactionDetailView.swift:734` | `Copy \(accessibilityName)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/TransactionDetailView.swift:871` | `Copy \(name)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/WalletActivityFilterSheet.swift:437` | `Filters by each transaction's value in \(currencyCode). Transactions with no …` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/WalletActivityFilterSheet.swift:656` | `\(chain.displayName) network` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/WalletHomeHeader.swift:119` | `Total balance \(WalletFormatting.fiat(totalFiat, currencyCode: currencyCode))` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/WalletHomeHeader.swift:135` | `Switch wallet, currently \(walletName)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/WalletHomeHeader.swift:157` | `^[\(chainCount) chain](inflect: true)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/WalletHomeHeader.swift:159` | `^[\(tokenCount) token](inflect: true)` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/WalletHomeHeader.swift:167` | `^[\(totalChainsSupported) chain](inflect: true) supported` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/WalletHomeView.swift:1417` | `\(row.chain.displayName) details` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/WalletHomeView.swift:1451` | `\(row.symbol) details` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |
| low | `Aperture/Sources/Features/Wallet/WalletHomeView.swift:2332` | `Switch wallet, currently \(activeWallet?.name ?? )` — Interpolated UI string; prefer String.apertureLocalized + String(format:) |

## process_locale_api (1)

| Sev | Location | Key / detail |
|-----|----------|--------------|
| high | `Aperture/Sources/Features/Settings/LanguagePickerView.swift:98` | `Use iOS system language` — String(localized:) ignores in-app language; use apertureLocalized |

## verbatim_bypass (28)

| Sev | Location | Key / detail |
|-----|----------|--------------|
| medium | `Aperture/Sources/Features/Database/DatabaseRecoveryView.swift:150` | `Store: \(incident?.storePath ?? AppDatabase.shared.storeURL.path)` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/ImportWallet/ImportGuideSheets.swift:41` | `abandon abandon abandon abandon abandon abandon abandon abandon abandon aband…` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/ImportWallet/ImportGuideSheets.swift:186` | `bc1qexample…example…example` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Onboarding/OnboardingSettingsView.swift:213` | `Coinbase` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Send/SendAmountEntry.swift:542` | `\(index + 1). \(name)` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Send/SendAmountEntry.swift:555` | `\(index + 1).` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Send/SendAmountEntry.swift:587` | `≈ \(value)` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Send/SendDataSheets.swift:456` | `\(count) / \(max) bytes` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Send/SendFeeSheet.swift:157` | `\(WalletFormatting.native(choice.estimatedTotalNative, decimals: 8, hidden: h…` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Send/SendRecipientView.swift:402` | `\(stellarMemoByteCount) / 28 bytes` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Send/SendReviewView.swift:186` | `\(WalletFormatting.native(draft.totalAmount, decimals: draft.effectiveDecimal…` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Send/SendReviewView.swift:248` | `\(WalletFormatting.native(r.amount, decimals: draft.effectiveDecimals, hidden…` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Send/SendReviewView.swift:264` | `\(WalletFormatting.native(draft.fee.estimatedTotalNative, decimals: 8, hidden…` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Send/SendReviewView.swift:691` | `\(amount) \(assetSymbol)` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Send/SendUTXOSheet.swift:120` | `\(WalletFormatting.native(displayAmount(utxo), decimals: model.chain.nativeDe…` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Send/SendUTXOSheet.swift:131` | `· \(shortTxid(utxo.txid)):\(utxo.vout)` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Settings/CurrencyPickerView.swift:121` | `\(currency.code) · \(currency.symbol)` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Settings/CurrencyPickerView.swift:139` | `\(localizedName) — \(currency.code)` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Settings/CustomTokensListView.swift:298` | `\(WalletFormatting.native(amount, decimals: 6, hidden: hideBalances)) \(token…` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Settings/ResetApertureFlow.swift:469` | `care@aperturex.io` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Wallet/AllSupportedAssetsView.swift:409` | `\(row.symbol), \(row.name), on \(row.chain.displayName)` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Wallet/AssetDetailView.swift:428` | `\(amount) \(identity.symbol)` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Wallet/AssetPickerRows.swift:48` | `\(fullName), \(ticker)` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Wallet/AssetRouteTemplatesSection.swift:76` | `\(template.displayName), \(template.subtitle)` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Wallet/BiometricReenrollmentBanner.swift:28` | `Re-enable \(biometricService.biometryType.displayName).` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Wallet/BiometricReenrollmentBanner.swift:32` | `Your \(biometricService.biometryType.displayName) enrollment changed. Authent…` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Wallet/BiometricReenrollmentBanner.swift:57` | `Re-enable \(biometricService.biometryType.displayName)` — Text(verbatim:) shows raw string; will not translate |
| medium | `Aperture/Sources/Features/Wallet/SolanaPathBalanceRow.swift:37` | `\(WalletFormatting.native(line.amount, decimals: 6, hidden: hidden)) \(symbol)` — Text(verbatim:) shows raw string; will not translate |
