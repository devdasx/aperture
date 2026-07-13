#!/usr/bin/env python3
"""
Aperture localization auditor
=============================

Finds user-facing strings that are missing from (or incomplete in)
``Localizable.xcstrings``, and hardcoded UI literals that never go through
the localization pipeline.

What it checks
--------------
1. **Missing catalog keys** — code calls ``apertureLocalized`` /
   ``String(localized:)`` / ``Text("…")`` (as a key) with a string that is
   **not** present in the catalog.
2. **Hardcoded UI** — string literals in UI-facing APIs that look like
   natural language but are **not** catalog keys (won't translate).
3. **Verbatim bypass** — ``Text(verbatim: "…")`` with natural-language
   content (skips localization on purpose; often a bug for UI copy).
4. **Process-locale API** — ``String(localized:)`` without
   ``apertureLocalized`` / bundle override (won't honor Settings → Language).
5. **Incomplete languages** — catalog keys missing a translation for one or
   more of the app's 51 languages.
6. **Orphan catalog keys** (optional) — keys never referenced from Swift.
7. **Placeholder integrity** — ``%@`` / ``%lld`` / etc. mismatch between
   English and a given language (optional deep check).

Designed for Aperture's model
-----------------------------
* English source string **is** the catalog key (String Catalog style).
* In-app language must use ``String.apertureLocalized`` /
  ``apertureLocalizedKey`` (not process ``String(localized:)`` alone).
* Brand name ``Aperture`` is intentionally untranslated.

Usage
-----
From the repository root::

    python3 scripts/find_unlocalized_strings.py
    python3 scripts/find_unlocalized_strings.py --format md -o l10n-audit/scan-report.md
    python3 scripts/find_unlocalized_strings.py --format json --fail-on missing,hardcoded
    python3 scripts/find_unlocalized_strings.py --lang ar --incomplete-only
    python3 scripts/find_unlocalized_strings.py --include-orphans --include-tests

Exit codes
----------
* ``0`` — no findings at or above the configured fail threshold
* ``1`` — findings that match ``--fail-on``
* ``2`` — usage / IO error
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Iterator, Sequence

# ---------------------------------------------------------------------------
# Paths / defaults
# ---------------------------------------------------------------------------

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CATALOG = ROOT / "Aperture" / "Resources" / "Localizable.xcstrings"
DEFAULT_SOURCES = (
    ROOT / "Aperture" / "Sources",
)
DEFAULT_TESTS = ROOT / "Aperture" / "Tests"

APP_LANGS: tuple[str, ...] = (
    "af", "ar", "bg", "bn", "ca", "cs", "da", "de", "el", "en", "es", "et",
    "fa", "fi", "fil", "fr", "he", "hi", "hr", "hu", "id", "is", "it", "ja",
    "ko", "lt", "lv", "ml", "mr", "ms", "nb", "nl", "pa", "pl", "pt-BR", "ro",
    "ru", "sk", "sl", "sr", "sv", "sw", "ta", "te", "th", "tr", "uk", "ur",
    "vi", "zh-Hans", "zh-Hant",
)

SEVERITY_ORDER = {"critical": 0, "high": 1, "medium": 2, "low": 3, "info": 4}

# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class SourceHit:
    """A string literal extracted from Swift source."""

    path: str
    line: int
    column: int
    text: str
    kind: str  # e.g. text, aperture_localized, string_localized, verbatim, label…
    raw: str  # surrounding snippet
    has_interpolation: bool = False


@dataclass
class Finding:
    severity: str
    category: str
    message: str
    key: str = ""
    path: str = ""
    line: int = 0
    lang: str = ""
    suggestion: str = ""
    extra: dict = field(default_factory=dict)

    def sort_key(self) -> tuple:
        return (
            SEVERITY_ORDER.get(self.severity, 99),
            self.category,
            self.path,
            self.line,
            self.key[:80],
        )


# ---------------------------------------------------------------------------
# Catalog
# ---------------------------------------------------------------------------


class StringCatalog:
    def __init__(self, path: Path) -> None:
        self.path = path
        raw = json.loads(path.read_text(encoding="utf-8"))
        self.version = raw.get("version") or raw.get("sourceLanguage") or "unknown"
        self.source_language = raw.get("sourceLanguage", "en")
        self.strings: dict[str, dict] = raw.get("strings") or {}

    @property
    def keys(self) -> set[str]:
        return set(self.strings.keys())

    def en_value(self, key: str) -> str | None:
        entry = self.strings.get(key) or {}
        locs = entry.get("localizations") or {}
        en = (locs.get("en") or {}).get("stringUnit") or {}
        val = en.get("value")
        if val is not None:
            return val
        # Empty entry still "exists" as a key (extraction stub)
        if key in self.strings:
            return key
        return None

    def value(self, key: str, lang: str) -> str | None:
        entry = self.strings.get(key) or {}
        locs = entry.get("localizations") or {}
        unit = (locs.get(lang) or {}).get("stringUnit") or {}
        return unit.get("value")

    def missing_languages(self, key: str, langs: Sequence[str]) -> list[str]:
        missing: list[str] = []
        for lang in langs:
            val = self.value(key, lang)
            if val is None or (isinstance(val, str) and val.strip() == ""):
                missing.append(lang)
        return missing

    def has_key(self, key: str) -> bool:
        return key in self.strings


# ---------------------------------------------------------------------------
# Swift scanning
# ---------------------------------------------------------------------------

# Strip Swift line/block comments for safer literal extraction (best-effort).
_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)
_LINE_COMMENT_RE = re.compile(r"//.*?$", re.MULTILINE)
# String literal: "..." with escapes; exclude raw #""# for simplicity first pass.
_STRING_LIT_RE = re.compile(
    r'"(?:\\.|[^"\\])*"',
    re.DOTALL,
)
# Multiline """..."""
_TRIPLE_STRING_RE = re.compile(
    r'"""(?:\\.|[^"\\]|"(?!""))*?"""',
    re.DOTALL,
)

# UI / localization call patterns (applied around a literal's position).
# Order matters for classification when multiple match.
_CONTEXT_RULES: list[tuple[str, re.Pattern[str]]] = [
    # Strong localization APIs (keys expected in catalog)
    ("aperture_localized", re.compile(
        r"""String\s*\.\s*apertureLocalized(?:Key)?\s*\(\s*$"""
    )),
    ("aperture_localized", re.compile(
        r"""(?:^|[^.\w])apertureLocalized(?:Key)?\s*\(\s*$"""
    )),
    ("string_localized", re.compile(
        r"""String\s*\(\s*localized\s*:\s*$"""
    )),
    ("ns_localized", re.compile(
        r"""NSLocalizedString\s*\(\s*$"""
    )),
    ("localized_resource", re.compile(
        r"""LocalizedStringResource\s*\(\s*$"""
    )),
    ("localized_key_type", re.compile(
        r"""LocalizedStringKey\s*\(\s*$"""
    )),
    # SwiftUI Text — key path when no interpolation
    ("text", re.compile(
        r"""(?:^|[^.\w])Text\s*\(\s*$"""
    )),
    ("text_verbatim", re.compile(
        r"""Text\s*\(\s*verbatim\s*:\s*$"""
    )),
    ("label", re.compile(
        r"""(?:^|[^.\w])Label\s*\(\s*$"""
    )),
    ("button", re.compile(
        r"""(?:^|[^.\w])Button\s*\(\s*$"""
    )),
    ("navigation_title", re.compile(
        r"""(?:navigationTitle|navigationBarTitle|toolbarTitle)\s*\(\s*$"""
    )),
    ("section", re.compile(
        r"""(?:^|[^.\w])Section\s*\(\s*(?:header\s*:\s*)?$"""
    )),
    ("toggle", re.compile(
        r"""(?:^|[^.\w])Toggle\s*\(\s*$"""
    )),
    ("picker", re.compile(
        r"""(?:^|[^.\w])Picker\s*\(\s*$"""
    )),
    ("link", re.compile(
        r"""(?:^|[^.\w])Link\s*\(\s*$"""
    )),
    ("alert", re.compile(
        r"""(?:\.alert|confirmationDialog)\s*\(\s*$"""
    )),
    ("searchable_prompt", re.compile(
        r"""(?:searchable\s*\([^)]*prompt\s*:\s*|prompt\s*:\s*Text\s*\()\s*$"""
    )),
    # SwiftUI / form field labels — avoid bare `message:` (DiagnosticsLog noise)
    ("prompt", re.compile(
        r"""(?:prompt|placeholder|subtitle|header|footer)\s*:\s*(?:Text\s*\()?\s*$"""
    )),
    ("swiftui_title", re.compile(
        r"""(?:^|[^.\w])(?:title|label)\s*:\s*(?:Text\s*\()?\s*$"""
    )),
    ("a11y", re.compile(
        r"""accessibility(?:Label|Hint|Value|InputLabels)\s*\(\s*(?:Text\s*\()?\s*$"""
    )),
    ("uni_field", re.compile(
        r"""(?:UniTextField|UniTextArea|UniSecureField)\s*\([^)]*(?:placeholder|title|label|prompt)\s*:\s*$"""
    )),
    # format with localized format string
    ("string_format_localized", re.compile(
        r"""String\s*\(\s*format\s*:\s*String\s*\.\s*apertureLocalized(?:Key)?\s*\(\s*$"""
    )),
]

# Paths / symbols that are never user-facing localization targets
_SKIP_PATH_PARTS = (
    "/Diagnostics/",
    "DiagnosticsLogStore.swift",
    "DiagnosticsLogView.swift",  # optional: still UI — keep for now
    "/Networking/NetworkProbe",
)

_SKIP_PATH_BASENAMES = {
    "DiagnosticsLogStore.swift",
}

# If the prefix looks like a logger call, ignore even when labeled "message:"
_LOGGER_PREFIX_RE = re.compile(
    r"""(?:DiagnosticsLogStore|Logger|os\.log|print|NSLog|fatalError|preconditionFailure|assertionFailure"""
    r"""|record\s*\(|\.debug\b|\.info\b|\.error\b|\.fault\b|\.warning\b"""
    r"""|category\s*:\s*")"""
)


def _line_col(text: str, index: int) -> tuple[int, int]:
    line = text.count("\n", 0, index) + 1
    last_nl = text.rfind("\n", 0, index)
    col = index - last_nl
    return line, col


def _decode_swift_string(literal: str) -> tuple[str, bool]:
    """Return (decoded_content, has_interpolation)."""
    has_interp = False
    if literal.startswith('"""') and literal.endswith('"""'):
        body = literal[3:-3]
    elif literal.startswith('"') and literal.endswith('"'):
        body = literal[1:-1]
    else:
        body = literal

    # Detect \( ... ) interpolation (not escaped)
    if re.search(r"(?<!\\)\\\(", body):
        has_interp = True

    # Unescape common sequences (best-effort)
    out: list[str] = []
    i = 0
    while i < len(body):
        ch = body[i]
        if ch == "\\" and i + 1 < len(body):
            nxt = body[i + 1]
            if nxt == "(":
                # keep interpolation marker as-is for reporting
                out.append("\\(")
                i += 2
                # skip until matching ) at depth 1 — rough
                depth = 1
                while i < len(body) and depth:
                    if body[i] == "(":
                        depth += 1
                    elif body[i] == ")":
                        depth -= 1
                    if depth:
                        out.append(body[i])
                    i += 1
                out.append(")")
                continue
            mapping = {
                "n": "\n",
                "t": "\t",
                "r": "\r",
                '"': '"',
                "'": "'",
                "\\": "\\",
                "0": "\0",
            }
            if nxt in mapping:
                out.append(mapping[nxt])
                i += 2
                continue
            if nxt == "u" and i + 2 < len(body) and body[i + 2] == "{":
                end = body.find("}", i + 3)
                if end != -1:
                    try:
                        out.append(chr(int(body[i + 3 : end], 16)))
                        i = end + 1
                        continue
                    except ValueError:
                        pass
            out.append(nxt)
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out), has_interp


def _strip_comments_preserve_lines(source: str) -> str:
    """Remove comments but keep newlines so line numbers stay aligned."""

    def block_repl(m: re.Match[str]) -> str:
        return re.sub(r"[^\n]", " ", m.group(0))

    def line_repl(m: re.Match[str]) -> str:
        return " " * len(m.group(0))

    no_block = _BLOCK_COMMENT_RE.sub(block_repl, source)
    return _LINE_COMMENT_RE.sub(line_repl, no_block)


def _window_before(source: str, index: int, size: int = 180) -> str:
    start = max(0, index - size)
    chunk = source[start:index]
    # collapse whitespace for regex matching but keep structure light
    return re.sub(r"[ \t]+", " ", chunk)


def _classify_context(prefix: str) -> str | None:
    # Normalize trailing call site
    p = prefix.rstrip()
    for kind, pattern in _CONTEXT_RULES:
        if pattern.search(p):
            return kind
    return None


def iter_swift_files(roots: Sequence[Path], include_tests: bool) -> Iterator[Path]:
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*.swift"):
            if not include_tests and ("/Tests/" in path.as_posix() or path.name.endswith("Tests.swift")):
                continue
            # Skip generated / package noise if any
            if "/build/" in path.as_posix() or "/.build/" in path.as_posix():
                continue
            yield path


def _should_skip_path(path: Path) -> bool:
    posix = path.as_posix()
    if path.name in _SKIP_PATH_BASENAMES:
        return True
    if "/Diagnostics/" in posix and path.name.endswith("LogStore.swift"):
        return True
    return False


def extract_hits(path: Path, source: str) -> list[SourceHit]:
    cleaned = _strip_comments_preserve_lines(source)
    hits: list[SourceHit] = []
    rel = str(path)

    # Triple-quoted first, then mark ranges to avoid double-counting
    occupied: list[tuple[int, int]] = []

    def add_match(m: re.Match[str], is_triple: bool) -> None:
        start, end = m.span()
        for a, b in occupied:
            if not (end <= a or start >= b):
                return
        occupied.append((start, end))
        literal = m.group(0)
        text, has_interp = _decode_swift_string(literal)
        prefix = _window_before(cleaned, start)
        # Diagnostics / logger call sites are not UI copy
        if _LOGGER_PREFIX_RE.search(prefix):
            return
        kind = _classify_context(prefix)
        if kind is None:
            return
        line, col = _line_col(source, start)
        # snippet: single source line
        line_start = source.rfind("\n", 0, start) + 1
        line_end = source.find("\n", start)
        if line_end < 0:
            line_end = len(source)
        snippet = source[line_start:line_end].strip()
        hits.append(
            SourceHit(
                path=rel,
                line=line,
                column=col,
                text=text,
                kind=kind,
                raw=snippet[:240],
                has_interpolation=has_interp,
            )
        )

    for m in _TRIPLE_STRING_RE.finditer(cleaned):
        add_match(m, True)
    for m in _STRING_LIT_RE.finditer(cleaned):
        add_match(m, False)

    return hits


# ---------------------------------------------------------------------------
# Heuristics: is this natural-language UI copy?
# ---------------------------------------------------------------------------

# Things that look technical / non-translatable even in UI APIs.
_TECHNICAL_EXACT = {
    "",
    " ",
    "OK",
    "ID",
    "QR",
    "PIN",
    "URL",
    "USD",
    "EUR",
    "BTC",
    "ETH",
    "SOL",
    "NFT",
    "RPC",
    "API",
    "CSV",
    "PDF",
    "JSON",
    "HTML",
    "UTF-8",
    "iOS",
    "macOS",
    "iPhone",
    "iPad",
    "Face ID",
    "Touch ID",
    "Optic ID",
    "App Store",
    "iCloud",
    "Aperture",  # brand — often Text(verbatim:)
    "Coinbase",
    "Trust Wallet",
    "Debug",
    "INFO",
    "WARN",
    "ERROR",
    "TODO",
    "FIXME",
}

# Demo / sample payloads that must stay fixed English
_SAMPLE_PAYLOAD_RE = re.compile(
    r"^(?:abandon\s+){3,}|^bc1[qpzry9]|example…example|^0x[a-fA-F0-9]{6,}",
    re.I,
)

_TECHNICAL_PREFIXES = (
    "http://",
    "https://",
    "www.",
    "mailto:",
    "file://",
    "com.",
    "iCloud.com.",
    "application/",
    "public.",
    "private.",
    "sysctl.",
    "kCF",
    "NS",
    "CG",
    "UI",
    "CK",
    "Sec",
)

_SF_SYMBOLISH = re.compile(
    r"^[a-z0-9]+(?:\.[a-z0-9]+)+(?:\.fill|\.circle|\.square)?$"
)
_FORMAT_ONLY = re.compile(
    r"^[\s%@0-9lldfF\.\,\-\–\—\·\:\;\/\\\(\)\[\]\{\}\+\|\#\*]+$"
)
_IDENT_ONLY = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
_PATHISH = re.compile(r"^[/~.]|\\|\.swift$|\.json$|\.csv$|\.png$|\.pdf$")
_HEX_COLOR = re.compile(r"^#?[0-9A-Fa-f]{3,8}$")
_HAS_LETTER = re.compile(r"[A-Za-z\u00C0-\u024F\u0400-\u04FF\u0600-\u06FF\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]")
_WORD = re.compile(r"[A-Za-z]{2,}")


def looks_technical(text: str) -> bool:
    t = text.strip()
    if t in _TECHNICAL_EXACT:
        return True
    if not t:
        return True
    if _SAMPLE_PAYLOAD_RE.search(t):
        return True
    if _FORMAT_ONLY.match(t):
        return True
    if _HEX_COLOR.match(t):
        return True
    if _SF_SYMBOLISH.match(t):
        return True
    if _PATHISH.search(t) and " " not in t:
        return True
    low = t.lower()
    if any(low.startswith(p.lower()) for p in _TECHNICAL_PREFIXES):
        return True
    # Store paths / debug labels
    if low.startswith("store:") or "/var/" in low or low.endswith(".sqlite"):
        return True
    # Byte counters "12 / 28 bytes" (digits may live only in \(interpolations\))
    if re.search(r"\bbytes\b", low) and ("/" in t or re.search(r"\d", t) or "\\(" in t):
        return True
    # Emails stay fixed
    if re.search(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", t):
        return True
    # camelCase / snake_case identifiers
    if " " not in t and ("_" in t or re.search(r"[a-z][A-Z]", t)):
        if not re.search(r"[.!?]$", t):
            return True
    # UUID-like / hex
    if re.fullmatch(r"[0-9a-fA-F-]{8,}", t):
        return True
    # Bundle / keychain style
    if t.count(".") >= 2 and " " not in t:
        return True
    return False


def looks_natural_language(text: str, min_len: int = 2) -> bool:
    t = text.strip()
    if len(t) < min_len:
        return False
    if looks_technical(t):
        return False
    if not _HAS_LETTER.search(t):
        return False
    # Single identifier token without spaces → usually not UI sentence
    if " " not in t and _IDENT_ONLY.match(t) and t[0].islower():
        return False
    # Must contain a word of 2+ letters OR non-Latin letters
    if _WORD.search(t) or re.search(r"[\u0400-\u04FF\u0600-\u06FF\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]", t):
        return True
    return False


def is_localization_key_kind(kind: str) -> bool:
    return kind in {
        "aperture_localized",
        "string_localized",
        "ns_localized",
        "localized_resource",
        "localized_key_type",
        "text",  # SwiftUI Text("Key") uses catalog when no interp
        "label",
        "button",
        "navigation_title",
        "section",
        "toggle",
        "picker",
        "link",
        "alert",
        "searchable_prompt",
        "prompt",
        "a11y",
        "uni_field",
        "string_format_localized",
        "swiftui_title",
    }


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

_PLACEHOLDER_RE = re.compile(
    r"%(?:\d+\$)?(?:ll)?[a-z@]|%@|%lld|%ld|%d|%f|%\.?\d*[fF]|\\\([^)]*\)"
)


def placeholders(s: str) -> list[str]:
    return sorted(_PLACEHOLDER_RE.findall(s or ""))


def analyze(
    catalog: StringCatalog,
    hits: Sequence[SourceHit],
    *,
    langs: Sequence[str],
    min_len: int,
    include_orphans: bool,
    incomplete_only: bool,
    skip_incomplete: bool,
    check_placeholders: bool,
) -> list[Finding]:
    findings: list[Finding] = []
    referenced_keys: set[str] = set()

    # Index hits by key text for orphan detection
    for hit in hits:
        if hit.has_interpolation:
            # Catalog keys almost never include raw \( — skip key membership
            continue
        if is_localization_key_kind(hit.kind) and hit.kind != "text_verbatim":
            if looks_natural_language(hit.text, min_len=1) or catalog.has_key(hit.text):
                referenced_keys.add(hit.text)

    if incomplete_only:
        for key in sorted(catalog.keys):
            if not key.strip():
                continue
            missing = catalog.missing_languages(key, langs)
            # en should exist; ignore empty keys
            if missing:
                findings.append(
                    Finding(
                        severity="medium" if "en" not in missing else "high",
                        category="incomplete_translation",
                        message=f"Missing {len(missing)} language(s): {', '.join(missing[:12])}"
                        + ("…" if len(missing) > 12 else ""),
                        key=key,
                        extra={"missing_langs": missing},
                    )
                )
        return findings

    for hit in hits:
        text = hit.text
        rel = _relpath(hit.path)

        # --- Verbatim natural language ---
        if hit.kind == "text_verbatim":
            # Dynamic/format-only verbatim is intentional (amounts, paths, indexes)
            stripped_interp = re.sub(r"\\\([^)]*\)", "", text).strip()
            if hit.has_interpolation and (
                looks_technical(stripped_interp) or len(stripped_interp) < 4
            ):
                continue
            if looks_natural_language(text, min_len=min_len) and text.strip() not in _TECHNICAL_EXACT:
                findings.append(
                    Finding(
                        severity="medium",
                        category="verbatim_bypass",
                        message="Text(verbatim:) shows raw string; will not translate",
                        key=text,
                        path=rel,
                        line=hit.line,
                        suggestion='Use Text("…") or String.apertureLocalized("…") unless brand/technical.',
                        extra={"snippet": hit.raw},
                    )
                )
            continue

        # --- String(localized:) without aperture path ---
        if hit.kind == "string_localized" and not hit.has_interpolation:
            findings.append(
                Finding(
                    severity="high",
                    category="process_locale_api",
                    message="String(localized:) ignores in-app language; use apertureLocalized",
                    key=text,
                    path=rel,
                    line=hit.line,
                    suggestion='Replace with String.apertureLocalized("…") or apertureLocalizedKey',
                    extra={"snippet": hit.raw},
                )
            )
            # also fall through to missing-key check

        # Interpolated Text / labels — not a single catalog key
        if hit.has_interpolation:
            if hit.kind in {"text", "label", "button", "a11y", "alert", "navigation_title"}:
                # Encourage format-based localization
                if looks_natural_language(re.sub(r"\\\([^)]*\)", "%@", text), min_len=min_len):
                    findings.append(
                        Finding(
                            severity="low",
                            category="interpolation_in_ui",
                            message="Interpolated UI string; prefer String.apertureLocalized + String(format:)",
                            key=text,
                            path=rel,
                            line=hit.line,
                            suggestion='Use String(format: String.apertureLocalized("… %@ …"), value)',
                            extra={"snippet": hit.raw},
                        )
                    )
            continue

        if not is_localization_key_kind(hit.kind):
            continue

        # Localization key expected
        if catalog.has_key(text):
            referenced_keys.add(text)
            continue

        # Not in catalog
        if not looks_natural_language(text, min_len=min_len) and hit.kind not in {
            "aperture_localized",
            "string_localized",
            "ns_localized",
        }:
            # Explicit localization API with non-NL key still reported if non-empty
            if hit.kind in {"aperture_localized", "string_localized", "ns_localized"} and text.strip():
                findings.append(
                    Finding(
                        severity="high",
                        category="missing_key",
                        message="Localization API key not found in Localizable.xcstrings",
                        key=text,
                        path=rel,
                        line=hit.line,
                        suggestion="Add this exact English key to Localizable.xcstrings",
                        extra={"kind": hit.kind, "snippet": hit.raw},
                    )
                )
            continue

        if hit.kind in {
            "aperture_localized",
            "string_localized",
            "ns_localized",
            "localized_resource",
            "localized_key_type",
            "string_format_localized",
        }:
            sev = "critical"
            cat = "missing_key"
            msg = "Localization API key missing from catalog — will show English source / raw key"
        else:
            # Text("…") etc. — SwiftUI extracts to catalog if using String Catalog
            # generation; if not in catalog file, it's effectively untranslated.
            sev = "high"
            cat = "hardcoded_or_missing"
            msg = "UI string not present in Localizable.xcstrings (hardcoded / not extracted)"

        findings.append(
            Finding(
                severity=sev,
                category=cat,
                message=msg,
                key=text,
                path=rel,
                line=hit.line,
                suggestion="Add key to Localizable.xcstrings and translate all app languages",
                extra={"kind": hit.kind, "snippet": hit.raw},
            )
        )

    # Incomplete translations
    if not skip_incomplete:
        for key in catalog.keys:
            if not key.strip():
                continue
            # Skip pure technical catalog keys
            if looks_technical(key) and len(key) < 40 and " " not in key:
                continue
            missing = catalog.missing_languages(key, langs)
            if not missing:
                continue
            # Don't flood for keys that are empty stubs nobody uses
            findings.append(
                Finding(
                    severity="medium" if len(missing) < 5 else "high",
                    category="incomplete_translation",
                    message=f"Missing {len(missing)}/{len(langs)} languages",
                    key=key,
                    extra={"missing_langs": missing, "missing_count": len(missing)},
                )
            )

    # Placeholder mismatches (en vs each lang) — sample check
    if check_placeholders:
        for key in catalog.keys:
            en = catalog.en_value(key) or key
            en_ph = placeholders(en)
            if not en_ph:
                continue
            for lang in langs:
                if lang == "en":
                    continue
                val = catalog.value(key, lang)
                if not val:
                    continue
                if placeholders(val) != en_ph:
                    findings.append(
                        Finding(
                            severity="high",
                            category="placeholder_mismatch",
                            message="Placeholder tokens differ from English",
                            key=key,
                            lang=lang,
                            extra={
                                "en_ph": en_ph,
                                "lang_ph": placeholders(val),
                                "value_preview": val[:120],
                            },
                        )
                    )

    # Orphans
    if include_orphans:
        for key in sorted(catalog.keys):
            if not key.strip():
                continue
            if key in referenced_keys:
                continue
            # Many keys are used via dynamic apertureLocalizedKey(variable)
            # so orphans are informational only
            findings.append(
                Finding(
                    severity="info",
                    category="orphan_key",
                    message="Catalog key never seen as a literal in scanned Swift sources",
                    key=key,
                    suggestion="May still be used dynamically; verify before deleting",
                )
            )

    findings.sort(key=lambda f: f.sort_key())
    return findings


def _relpath(path: str) -> str:
    p = Path(path)
    try:
        return str(p.resolve().relative_to(ROOT))
    except Exception:
        return path


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------


def summarize(findings: Sequence[Finding]) -> dict:
    by_sev: Counter[str] = Counter(f.severity for f in findings)
    by_cat: Counter[str] = Counter(f.category for f in findings)
    return {
        "total": len(findings),
        "by_severity": dict(by_sev),
        "by_category": dict(by_cat),
    }


def render_text(findings: Sequence[Finding], summary: dict, catalog: StringCatalog) -> str:
    lines: list[str] = []
    lines.append("=" * 72)
    lines.append("APERTURE LOCALIZATION AUDIT")
    lines.append("=" * 72)
    lines.append(f"Catalog : {catalog.path}")
    lines.append(f"Keys    : {len(catalog.keys)}")
    lines.append(f"When    : {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}")
    lines.append(f"Findings: {summary['total']}")
    lines.append("")
    lines.append("By severity:")
    for sev in ("critical", "high", "medium", "low", "info"):
        n = summary["by_severity"].get(sev, 0)
        if n:
            lines.append(f"  {sev:10s} {n}")
    lines.append("")
    lines.append("By category:")
    for cat, n in sorted(summary["by_category"].items(), key=lambda x: (-x[1], x[0])):
        lines.append(f"  {cat:28s} {n}")
    lines.append("")
    lines.append("-" * 72)

    current_cat = None
    for f in findings:
        if f.category != current_cat:
            current_cat = f.category
            lines.append("")
            lines.append(f"## {current_cat}")
            lines.append("")
        loc = f"{f.path}:{f.line}" if f.path else "(catalog)"
        key_preview = f.key.replace("\n", "\\n")
        if len(key_preview) > 100:
            key_preview = key_preview[:97] + "..."
        lines.append(f"[{f.severity.upper()}] {loc}")
        lines.append(f"  {f.message}")
        if key_preview:
            lines.append(f"  key: {key_preview!r}")
        if f.lang:
            lines.append(f"  lang: {f.lang}")
        if f.suggestion:
            lines.append(f"  → {f.suggestion}")
        if f.extra.get("snippet"):
            lines.append(f"  snippet: {f.extra['snippet'][:160]}")
        if f.extra.get("missing_langs") and f.category == "incomplete_translation":
            miss = f.extra["missing_langs"]
            lines.append(f"  missing: {', '.join(miss[:20])}" + ("…" if len(miss) > 20 else ""))
        lines.append("")
    return "\n".join(lines)


def render_md(findings: Sequence[Finding], summary: dict, catalog: StringCatalog) -> str:
    lines: list[str] = []
    lines.append("# Aperture localization audit")
    lines.append("")
    lines.append(f"- **Catalog:** `{catalog.path}`")
    lines.append(f"- **Keys:** {len(catalog.keys)}")
    lines.append(f"- **Findings:** {summary['total']}")
    lines.append(f"- **Generated:** {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append("| Severity | Count |")
    lines.append("|----------|------:|")
    for sev in ("critical", "high", "medium", "low", "info"):
        n = summary["by_severity"].get(sev, 0)
        if n:
            lines.append(f"| {sev} | {n} |")
    lines.append("")
    lines.append("| Category | Count |")
    lines.append("|----------|------:|")
    for cat, n in sorted(summary["by_category"].items(), key=lambda x: (-x[1], x[0])):
        lines.append(f"| `{cat}` | {n} |")
    lines.append("")

    by_cat: dict[str, list[Finding]] = defaultdict(list)
    for f in findings:
        by_cat[f.category].append(f)

    for cat in sorted(by_cat.keys()):
        items = by_cat[cat]
        lines.append(f"## {cat} ({len(items)})")
        lines.append("")
        lines.append("| Sev | Location | Key / detail |")
        lines.append("|-----|----------|--------------|")
        for f in items[:500]:
            loc = f"`{f.path}:{f.line}`" if f.path else "catalog"
            key = f.key.replace("|", "\\|").replace("\n", " ")
            if len(key) > 80:
                key = key[:77] + "…"
            detail = f.message.replace("|", "\\|")
            if f.lang:
                detail += f" (`{f.lang}`)"
            lines.append(f"| {f.severity} | {loc} | `{key}` — {detail} |")
        if len(items) > 500:
            lines.append(f"| | | *… {len(items) - 500} more* |")
        lines.append("")
    return "\n".join(lines)


def render_json(findings: Sequence[Finding], summary: dict, catalog: StringCatalog) -> str:
    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "catalog": str(catalog.path),
        "catalog_key_count": len(catalog.keys),
        "summary": summary,
        "findings": [asdict(f) for f in findings],
    }
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="find_unlocalized_strings.py",
        description="Professional localization auditor for the Aperture iOS app",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument(
        "--catalog",
        type=Path,
        default=DEFAULT_CATALOG,
        help="Path to Localizable.xcstrings",
    )
    p.add_argument(
        "--source",
        type=Path,
        action="append",
        dest="sources",
        help="Swift source root (repeatable). Default: Aperture/Sources",
    )
    p.add_argument(
        "--include-tests",
        action="store_true",
        help="Also scan Aperture/Tests",
    )
    p.add_argument(
        "--format",
        choices=("text", "md", "json"),
        default="text",
        help="Report format",
    )
    p.add_argument(
        "-o",
        "--output",
        type=Path,
        help="Write report to file (default: stdout)",
    )
    p.add_argument(
        "--min-length",
        type=int,
        default=2,
        help="Minimum natural-language string length to flag",
    )
    p.add_argument(
        "--lang",
        action="append",
        dest="langs",
        help="Limit incomplete-translation check to these langs (repeatable)",
    )
    p.add_argument(
        "--incomplete-only",
        action="store_true",
        help="Only report incomplete catalog translations",
    )
    p.add_argument(
        "--skip-incomplete",
        action="store_true",
        help="Do not report incomplete translations (focus on code issues)",
    )
    p.add_argument(
        "--include-orphans",
        action="store_true",
        help="Report catalog keys never seen as Swift literals",
    )
    p.add_argument(
        "--check-placeholders",
        action="store_true",
        help="Check %%@ / %%lld mismatches across languages",
    )
    p.add_argument(
        "--fail-on",
        default="",
        help="Comma-separated categories that cause exit 1 "
        "(e.g. missing_key,hardcoded_or_missing,process_locale_api)",
    )
    p.add_argument(
        "--fail-severity",
        choices=("critical", "high", "medium", "low", "info"),
        help="Fail if any finding is at least this severity",
    )
    p.add_argument(
        "--quiet",
        action="store_true",
        help="Only print summary + exit code (still writes -o fully)",
    )
    p.add_argument(
        "--max-findings",
        type=int,
        default=0,
        help="Cap printed findings (0 = no cap). Full set still counted.",
    )
    return p


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    catalog_path: Path = args.catalog
    if not catalog_path.is_file():
        print(f"error: catalog not found: {catalog_path}", file=sys.stderr)
        return 2

    sources: list[Path] = list(args.sources) if args.sources else list(DEFAULT_SOURCES)
    if args.include_tests and DEFAULT_TESTS not in sources:
        sources.append(DEFAULT_TESTS)

    try:
        catalog = StringCatalog(catalog_path)
    except json.JSONDecodeError as exc:
        print(f"error: invalid catalog JSON: {exc}", file=sys.stderr)
        return 2

    langs: list[str] = list(args.langs) if args.langs else list(APP_LANGS)

    all_hits: list[SourceHit] = []
    file_count = 0
    for path in iter_swift_files(sources, include_tests=args.include_tests):
        if _should_skip_path(path):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            print(f"warn: skip {path}: {exc}", file=sys.stderr)
            continue
        file_count += 1
        all_hits.extend(extract_hits(path, text))

    findings = analyze(
        catalog,
        all_hits,
        langs=langs,
        min_len=args.min_length,
        include_orphans=args.include_orphans,
        incomplete_only=args.incomplete_only,
        skip_incomplete=args.skip_incomplete,
        check_placeholders=args.check_placeholders,
    )
    summary = summarize(findings)
    summary["swift_files_scanned"] = file_count
    summary["string_hits"] = len(all_hits)

    display = findings
    if args.max_findings and len(findings) > args.max_findings:
        display = findings[: args.max_findings]

    if args.format == "json":
        body = render_json(findings, summary, catalog)
    elif args.format == "md":
        body = render_md(display if args.max_findings else findings, summary, catalog)
    else:
        body = render_text(display if args.max_findings else findings, summary, catalog)
        if args.max_findings and len(findings) > args.max_findings:
            body += f"\n… truncated to {args.max_findings} of {len(findings)} findings\n"

    if args.quiet and args.format == "text":
        body = (
            f"files={file_count} hits={len(all_hits)} findings={summary['total']} "
            f"severity={summary['by_severity']} categories={summary['by_category']}\n"
        )

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        # For quiet+output, still write full report to file
        if args.quiet:
            if args.format == "json":
                full = render_json(findings, summary, catalog)
            elif args.format == "md":
                full = render_md(findings, summary, catalog)
            else:
                full = render_text(findings, summary, catalog)
            args.output.write_text(full, encoding="utf-8")
            sys.stdout.write(body)
        else:
            args.output.write_text(body, encoding="utf-8")
            print(f"Wrote {args.output} ({summary['total']} findings)", file=sys.stderr)
    else:
        sys.stdout.write(body if body.endswith("\n") else body + "\n")

    # Exit code policy
    fail_categories = {c.strip() for c in args.fail_on.split(",") if c.strip()}
    if fail_categories:
        if any(f.category in fail_categories for f in findings):
            return 1
    if args.fail_severity:
        threshold = SEVERITY_ORDER[args.fail_severity]
        if any(SEVERITY_ORDER.get(f.severity, 99) <= threshold for f in findings):
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
