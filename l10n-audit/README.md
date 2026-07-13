# L10n audit

Each agent owns languages listed in agentXX/langs.json.
Write fixes ONLY to agentXX/fixes.jsonl (one JSON object per line):
{"key":"...","lang":"ar","old":"...","new":"...","reason":"..."}

Rules:
1. Brand name Aperture/APERTURE must stay Latin Aperture (never translate).
2. Preserve ALL placeholders exactly (%@, %lld, \(name), etc.).
3. Native-speaker quality: natural UI wording for a crypto wallet.
4. Do not leave English for user-facing copy unless proper noun/tech term.
5. Do not invent features; match English meaning.
6. Keep formal/polite wallet tone appropriate to language.
7. Do NOT edit Localizable.xcstrings directly.
