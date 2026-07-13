#!/usr/bin/env python3
"""Merge agent fixes.jsonl patches into Localizable.xcstrings and emit report."""

from __future__ import annotations

import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CATALOG = ROOT.parent / "Aperture" / "Resources" / "Localizable.xcstrings"
PLACEHOLDER_RE = re.compile(
    r"%@|%lld|%ld|%d|%f|%\.?\d*f|%\d+\$@|%\d+\$d|%\d+\$lld|"
    r"\\?\(%[a-zA-Z0-9_.]+\)|%\w+|\{[0-9]+\}"
)


def placeholders(s: str) -> list[str]:
    return sorted(PLACEHOLDER_RE.findall(s or ""))


def main() -> int:
    data = json.loads(CATALOG.read_text())
    strings = data["strings"]

    applied: Counter[str] = Counter()
    skipped: list[dict] = []
    applied_rows: list[dict] = []
    seen: set[tuple[str, str]] = set()

    for agent_dir in sorted(ROOT.glob("agent*")):
        fixes_path = agent_dir / "fixes.jsonl"
        if not fixes_path.exists():
            skipped.append({"agent": agent_dir.name, "reason": "no fixes.jsonl"})
            continue
        for line_no, line in enumerate(fixes_path.read_text().splitlines(), 1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                skipped.append(
                    {
                        "agent": agent_dir.name,
                        "line": line_no,
                        "reason": f"invalid json: {exc}",
                    }
                )
                continue
            key = row.get("key")
            lang = row.get("lang")
            new = row.get("new")
            old = row.get("old")
            if not key or not lang or new is None:
                skipped.append(
                    {
                        "agent": agent_dir.name,
                        "line": line_no,
                        "reason": "missing key/lang/new",
                    }
                )
                continue
            if (key, lang) in seen:
                skipped.append(
                    {
                        "agent": agent_dir.name,
                        "key": key,
                        "lang": lang,
                        "reason": "duplicate fix",
                    }
                )
                continue
            seen.add((key, lang))
            entry = strings.get(key)
            if entry is None:
                skipped.append(
                    {
                        "agent": agent_dir.name,
                        "key": key,
                        "lang": lang,
                        "reason": "key not found",
                    }
                )
                continue
            locs = entry.setdefault("localizations", {})
            loc = locs.setdefault(lang, {})
            unit = loc.setdefault("stringUnit", {"state": "translated"})
            current = unit.get("value")
            if old is not None and current is not None and current != old:
                # Still apply if new is better and current != new
                if current == new:
                    skipped.append(
                        {
                            "agent": agent_dir.name,
                            "key": key,
                            "lang": lang,
                            "reason": "already_equal_new",
                        }
                    )
                    continue
                # stale old — apply only if new differs from current
            if current == new:
                skipped.append(
                    {
                        "agent": agent_dir.name,
                        "key": key,
                        "lang": lang,
                        "reason": "no_change",
                    }
                )
                continue
            # placeholder safety vs English
            en_val = (
                ((locs.get("en") or {}).get("stringUnit") or {}).get("value") or key
            )
            if placeholders(en_val) != placeholders(new):
                skipped.append(
                    {
                        "agent": agent_dir.name,
                        "key": key,
                        "lang": lang,
                        "reason": "placeholder_mismatch_with_en",
                        "en_ph": placeholders(en_val),
                        "new_ph": placeholders(new),
                    }
                )
                continue
            # brand safety
            if ("Aperture" in en_val or "Aperture" in key) and (
                "Aperture" not in new and "APERTURE" not in new
            ):
                skipped.append(
                    {
                        "agent": agent_dir.name,
                        "key": key,
                        "lang": lang,
                        "reason": "would_drop_brand",
                    }
                )
                continue
            unit["value"] = new
            unit["state"] = "translated"
            applied[lang] += 1
            applied_rows.append(
                {
                    "agent": agent_dir.name,
                    "key": key,
                    "lang": lang,
                    "old": current,
                    "new": new,
                    "reason": row.get("reason"),
                }
            )

    CATALOG.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")

    report = {
        "total_applied": sum(applied.values()),
        "per_language": dict(sorted(applied.items(), key=lambda x: (-x[1], x[0]))),
        "skipped_count": len(skipped),
        "agents": sorted(p.name for p in ROOT.glob("agent*")),
    }
    (ROOT / "merge_report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    (ROOT / "applied_fixes.jsonl").write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in applied_rows) + ("\n" if applied_rows else "")
    )
    (ROOT / "skipped_fixes.jsonl").write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in skipped) + ("\n" if skipped else "")
    )

    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
