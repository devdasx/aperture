# Localization QA Report — Full Catalog Pass

Date: 2026-07-12

## Summary

| Metric | Value |
|--------|------:|
| Catalog | `Aperture/Resources/Localizable.xcstrings` |
| Source | English (`en`) |
| Target languages | **50** |
| Keys per language | **~2,425** |
| Parallel QA agents | **10** (5 languages each) |
| **Total keys fixed** | **4403** |
| Agent proposals | 4,404 |
| Merge rejects (safety) | 5 (4 false PH on curly quotes later applied; 1 orphan key) |

## Native-speaker standard

Each agent judged strings with: *If a native speaker reads this in their language in a crypto wallet, will they understand correctly?*

Hard rules enforced on merge:
1. Brand **Aperture** / **APERTURE** must remain Latin
2. Placeholders must match English (`%@`, `%lld`, `%1$@`, `\(...)` …)
3. No invented features; meaning must match English
4. No churn on already-correct strings

## Fixes by agent

| Agent | Languages | Fixes |
|------:|-----------|------:|
| agent01 | af, ar, bg, bn, ca | **525** |
| agent02 | cs, da, de, el, es | **434** |
| agent03 | et, fa, fi, fil, fr | **449** |
| agent04 | he, hi, hr, hu, id | **421** |
| agent05 | is, it, ja, ko, lt | **346** |
| agent06 | lv, ml, mr, ms, nb | **721** |
| agent07 | nl, pa, pl, pt-BR, ro | **349** |
| agent08 | ru, sk, sl, sr, sv | **542** |
| agent09 | sw, ta, te, th, tr | **507** |
| agent10 | uk, ur, vi, zh-Hans, zh-Hant | **109** |
| **All** | 50 | **4403** |

## Full per-language fix counts

| # | Code | Language | Agent | Keys fixed |
|--:|------|----------|------:|-----------:|
| 1 | `af` | Afrikaans | agent01 | **143** |
| 2 | `ar` | Arabic | agent01 | **5** |
| 3 | `bg` | Bulgarian | agent01 | **122** |
| 4 | `bn` | Bengali | agent01 | **141** |
| 5 | `ca` | Catalan | agent01 | **114** |
| 6 | `cs` | Czech | agent02 | **152** |
| 7 | `da` | Danish | agent02 | **121** |
| 8 | `de` | German | agent02 | **9** |
| 9 | `el` | Greek | agent02 | **143** |
| 10 | `es` | Spanish | agent02 | **9** |
| 11 | `et` | Estonian | agent03 | **146** |
| 12 | `fa` | Persian | agent03 | **20** |
| 13 | `fi` | Finnish | agent03 | **145** |
| 14 | `fil` | Filipino | agent03 | **128** |
| 15 | `fr` | French | agent03 | **10** |
| 16 | `he` | Hebrew | agent04 | **39** |
| 17 | `hi` | Hindi | agent04 | **35** |
| 18 | `hr` | Croatian | agent04 | **148** |
| 19 | `hu` | Hungarian | agent04 | **151** |
| 20 | `id` | Indonesian | agent04 | **48** |
| 21 | `is` | Icelandic | agent05 | **153** |
| 22 | `it` | Italian | agent05 | **39** |
| 23 | `ja` | Japanese | agent05 | **4** |
| 24 | `ko` | Korean | agent05 | **6** |
| 25 | `lt` | Lithuanian | agent05 | **144** |
| 26 | `lv` | Latvian | agent06 | **145** |
| 27 | `ml` | Malayalam | agent06 | **149** |
| 28 | `mr` | Marathi | agent06 | **148** |
| 29 | `ms` | Malay | agent06 | **139** |
| 30 | `nb` | Norwegian Bokmål | agent06 | **140** |
| 31 | `nl` | Dutch | agent07 | **25** |
| 32 | `pa` | Punjabi | agent07 | **147** |
| 33 | `pl` | Polish | agent07 | **24** |
| 34 | `pt-BR` | Portuguese (Brazil) | agent07 | **14** |
| 35 | `ro` | Romanian | agent07 | **139** |
| 36 | `ru` | Russian | agent08 | **2** |
| 37 | `sk` | Slovak | agent08 | **140** |
| 38 | `sl` | Slovenian | agent08 | **146** |
| 39 | `sr` | Serbian | agent08 | **136** |
| 40 | `sv` | Swedish | agent08 | **118** |
| 41 | `sw` | Swahili | agent09 | **145** |
| 42 | `ta` | Tamil | agent09 | **147** |
| 43 | `te` | Telugu | agent09 | **148** |
| 44 | `th` | Thai | agent09 | **36** |
| 45 | `tr` | Turkish | agent09 | **31** |
| 46 | `uk` | Ukrainian | agent10 | **33** |
| 47 | `ur` | Urdu | agent10 | **39** |
| 48 | `vi` | Vietnamese | agent10 | **33** |
| 49 | `zh-Hans` | Chinese Simplified | agent10 | **2** |
| 50 | `zh-Hant` | Chinese Traditional | agent10 | **2** |
| | | **TOTAL** | | **4403** |

## Top languages by volume fixed

1. **Icelandic** (`is`): **153** keys
1. **Czech** (`cs`): **152** keys
1. **Hungarian** (`hu`): **151** keys
1. **Malayalam** (`ml`): **149** keys
1. **Croatian** (`hr`): **148** keys
1. **Marathi** (`mr`): **148** keys
1. **Telugu** (`te`): **148** keys
1. **Punjabi** (`pa`): **147** keys
1. **Tamil** (`ta`): **147** keys
1. **Estonian** (`et`): **146** keys
1. **Slovenian** (`sl`): **146** keys
1. **Finnish** (`fi`): **145** keys
1. **Latvian** (`lv`): **145** keys
1. **Swahili** (`sw`): **145** keys
1. **Lithuanian** (`lt`): **144** keys

## Issue classes fixed

| Class | Examples |
|-------|----------|
| Untranslated English leftovers | Send/fee/errors/security/market labels left in EN |
| Missing a11y formats | `%@, selected for send, %@ %@` |
| Wrong language bleed | German in Norwegian; Russian in Ukrainian; Arabic in Urdu; Spanish in Italian |
| Brand mistakes | Optical words, Kipenyo, double Aperture |
| Placeholder corruption | Serbian `__ПХ`, broken `%lld` |
| Wrong sense | Token→chip/symbol; Lock→padlock; crypto→encryption |
| Fee/ETA chips | `~ next block`, `~ faster/slower` |
| Asset blurbs | Network description paragraphs |

## Intentionally unchanged

- Pure format templates and Swift interpolations
- Filenames / product APIs (Coinbase, SF Symbols, CloudKit, `aperture-custom-tokens.csv`)
- Standard crypto loanwords (Nonce, Hash, RBF, xpub, …) where natural
- Valid cognates identical to English (Status, Filter, Token in some langs)

## Artifacts

- `l10n-audit/agent01` … `agent10` — `fixes.jsonl` + `report.json`
- `l10n-audit/applied_fixes.jsonl` — merge log
- `l10n-audit/merge_report.json`
- `l10n-audit/FULL_REPORT.md` — this report
