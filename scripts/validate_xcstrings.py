#!/usr/bin/env python3
"""
Validate Aperture Localizable.xcstrings for Xcode-breaking issues.

Checks
------
1. **Format specifier integrity** — every language's argument *types* (by
   position index) must match English. Catches the Xcode error:
   `The format specifiers “%@” and “%lld” do not match “%lld” and “%@”`.

2. **Corrupt keys** — catalog keys that embed Swift interpolations like
   `\\(foo)` are never valid runtime keys (extraction accidents).

3. **Broken positional syntax** — e.g. `%1$1$lld`.

Exit codes
----------
* 0 — clean
* 1 — validation failures
* 2 — IO / usage error

Usage
-----
    python3 scripts/validate_xcstrings.py
    python3 scripts/validate_xcstrings.py --fix   # auto-repair type order via positionals
    python3 scripts/validate_xcstrings.py --json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CATALOG = ROOT / "Aperture" / "Resources" / "Localizable.xcstrings"

SPEC_RE = re.compile(
    r"%(?:(\d+)\$)?([+\-#0 ]*\d*(?:\.\d+)?)(ll[duxXo]|l[duxXo]|hh?[diouxX]|[diouxXeEfFgGaAcsp@])"
)
CORRUPT_KEY_RE = re.compile(r"\\\(|\\\w+\.|\$\{")


def find_specs(s: str) -> list[re.Match[str]]:
    out: list[re.Match[str]] = []
    i = 0
    text = s or ""
    while i < len(text):
        if text[i] == "%" and i + 1 < len(text) and text[i + 1] == "%":
            i += 2
            continue
        m = SPEC_RE.match(text, i)
        if m:
            out.append(m)
            i = m.end()
        else:
            i += 1
    return out


def arg_types(s: str) -> list[str]:
    by: dict[int, str] = {}
    auto = 1
    for m in find_specs(s):
        pos = int(m.group(1)) if m.group(1) else None
        typ = m.group(3)
        if pos is None:
            by[auto] = typ
            auto += 1
        else:
            by[pos] = typ
    return [by[i] for i in sorted(by)]


def to_positional(s: str, en_types: list[str]) -> str:
    """Rewrite conversions so argument types match en_types by position."""
    specs = find_specs(s)
    if not specs or not en_types:
        return s

    # Unique-type remap (handles natural word-order swaps)
    if len(specs) == len(en_types) and len(set(en_types)) == len(en_types):
        pieces: list[str] = []
        last = 0
        for m in specs:
            pieces.append(s[last : m.start()])
            flags = m.group(2) or ""
            typ = m.group(3)
            matches = [i + 1 for i, t in enumerate(en_types) if t == typ]
            if len(matches) == 1:
                pos = matches[0]
                typ = en_types[pos - 1]
            else:
                # fall through to appearance index below
                pos = None
            if pos is None:
                # use sequential from appearance — fixed in second branch
                pass
            else:
                pieces.append(f"%{pos}${flags}{typ}")
                last = m.end()
                continue
            # shouldn't reach if unique types
            pieces.append(m.group(0))
            last = m.end()
        pieces.append(s[last:])
        candidate = "".join(pieces)
        if arg_types(candidate) == en_types:
            return candidate

    # Appearance-order force (last resort)
    if len(specs) == len(en_types):
        pieces = []
        last = 0
        for idx, m in enumerate(specs):
            pieces.append(s[last : m.start()])
            flags = m.group(2) or ""
            pieces.append(f"%{idx + 1}${flags}{en_types[idx]}")
            last = m.end()
        pieces.append(s[last:])
        return "".join(pieces)

    return s


def validate(catalog: dict) -> list[dict]:
    issues: list[dict] = []
    strings = catalog.get("strings") or {}
    for key, entry in strings.items():
        if CORRUPT_KEY_RE.search(key):
            issues.append(
                {
                    "kind": "corrupt_key",
                    "key": key,
                    "message": "Key embeds Swift interpolation / invalid runtime key",
                }
            )
        locs = entry.get("localizations") or {}
        en = ((locs.get("en") or {}).get("stringUnit") or {}).get("value") or key
        et = arg_types(en)
        if re.search(r"%\d+\$\d+\$", en or ""):
            issues.append(
                {
                    "kind": "broken_positional",
                    "key": key,
                    "lang": "en",
                    "message": f"Broken positional syntax in English: {en!r}",
                }
            )
        for lang, loc in locs.items():
            val = (loc.get("stringUnit") or {}).get("value")
            if val is None:
                continue
            if re.search(r"%\d+\$\d+\$", val):
                issues.append(
                    {
                        "kind": "broken_positional",
                        "key": key,
                        "lang": lang,
                        "message": f"Broken positional syntax: {val!r}",
                    }
                )
            if et and arg_types(val) != et:
                issues.append(
                    {
                        "kind": "format_mismatch",
                        "key": key,
                        "lang": lang,
                        "message": (
                            f"Format types {arg_types(val)} do not match English {et}"
                        ),
                        "en": en,
                        "value": val,
                    }
                )
    return issues


def fix(catalog: dict) -> int:
    """Auto-repair format_mismatch + remove corrupt keys. Returns fix count."""
    strings = catalog.setdefault("strings", {})
    fixed = 0
    # Remove corrupt keys
    for key in list(strings.keys()):
        if CORRUPT_KEY_RE.search(key):
            del strings[key]
            fixed += 1
    for key, entry in strings.items():
        locs = entry.get("localizations") or {}
        en_unit = (locs.get("en") or {}).get("stringUnit") or {}
        en = en_unit.get("value") or key
        et = arg_types(en)
        if not et:
            continue
        # Normalize EN multi-arg to positional
        if len(et) >= 2 and en_unit.get("value") is not None:
            en_pos = to_positional(en, et)
            # Prefer explicit positions while keeping unique-type remap result
            if arg_types(en_pos) == et and en_pos != en:
                # Only rewrite EN if it gains positionals
                if not any(m.group(1) for m in find_specs(en)) and any(
                    m.group(1) for m in find_specs(en_pos)
                ):
                    en_unit["value"] = en_pos
                    en = en_pos
                    fixed += 1
            et = arg_types(en)
        for lang, loc in locs.items():
            unit = loc.get("stringUnit") or {}
            val = unit.get("value")
            if not val or lang == "en":
                continue
            if arg_types(val) != et:
                new = to_positional(val, et)
                if arg_types(new) != et:
                    new = en  # never leave a crashy mismatch
                unit["value"] = new
                unit["state"] = "translated"
                fixed += 1
    return fixed


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    p.add_argument("--fix", action="store_true", help="Auto-repair mismatches")
    p.add_argument("--json", action="store_true", help="JSON report on stdout")
    args = p.parse_args(argv)

    if not args.catalog.is_file():
        print(f"error: catalog not found: {args.catalog}", file=sys.stderr)
        return 2

    data = json.loads(args.catalog.read_text(encoding="utf-8"))
    if args.fix:
        n = fix(data)
        args.catalog.write_text(
            json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(f"Applied {n} repairs to {args.catalog}", file=sys.stderr)

    issues = validate(data)
    if args.json:
        print(json.dumps({"issue_count": len(issues), "issues": issues}, indent=2, ensure_ascii=False))
    else:
        if not issues:
            print(f"OK — {args.catalog} ({len(data.get('strings') or {})} keys)")
        else:
            print(f"FAIL — {len(issues)} issue(s) in {args.catalog}")
            by_kind: dict[str, int] = {}
            for i in issues:
                by_kind[i["kind"]] = by_kind.get(i["kind"], 0) + 1
            for k, n in sorted(by_kind.items()):
                print(f"  {k}: {n}")
            for i in issues[:40]:
                loc = f"{i.get('lang', '')}".strip()
                prefix = f"[{i['kind']}]"
                if loc:
                    prefix += f" {loc}"
                print(f"{prefix} {i['key'][:70]!r}")
                print(f"    {i['message'][:160]}")
            if len(issues) > 40:
                print(f"  … {len(issues) - 40} more")
            print("\nHint: python3 scripts/validate_xcstrings.py --fix")

    return 1 if issues else 0


if __name__ == "__main__":
    sys.exit(main())
