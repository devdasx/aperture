#!/usr/bin/env python3
"""Fill missing Localizable.xcstrings for all supported languages (batched + parallel)."""
from __future__ import annotations

import json
import re
import ssl
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from threading import Lock

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Aperture/Resources/Localizable.xcstrings"
CACHE = Path("/tmp/aperture_l10n_cache.json")

GT_LANG = {
    "af": "af", "ar": "ar", "bg": "bg", "bn": "bn", "ca": "ca", "cs": "cs",
    "da": "da", "de": "de", "el": "el", "en": "en", "es": "es", "et": "et",
    "fa": "fa", "fi": "fi", "fil": "tl", "fr": "fr", "he": "iw", "hi": "hi",
    "hr": "hr", "hu": "hu", "id": "id", "is": "is", "it": "it", "ja": "ja",
    "ko": "ko", "lt": "lt", "lv": "lv", "ml": "ml", "mr": "mr", "ms": "ms",
    "nb": "no", "nl": "nl", "pa": "pa", "pl": "pl", "pt-BR": "pt", "ro": "ro",
    "ru": "ru", "sk": "sk", "sl": "sl", "sr": "sr", "sv": "sv", "sw": "sw",
    "ta": "ta", "te": "te", "th": "th", "tr": "tr", "uk": "uk", "ur": "ur",
    "vi": "vi", "zh-Hans": "zh-CN", "zh-Hant": "zh-TW",
}
TARGET_LANGS = [c for c in GT_LANG if c != "en"]
PLACEHOLDER_RE = re.compile(
    r"(%(?:\d+\$)?[@%dDiuUxXoOeEfFgGaAcCsSp]|%lld|%ld|%llu|%\{[^}]+\}|\\n)"
)
CTX = ssl.create_default_context()
CACHE_LOCK = Lock()


def protect(text: str) -> tuple[str, list[str]]:
    parts: list[str] = []

    def repl(m: re.Match) -> str:
        parts.append(m.group(0))
        return f"__PH{len(parts)-1}__"

    return PLACEHOLDER_RE.sub(repl, text), parts


def unprotect(text: str, parts: list[str]) -> str:
    out = text
    for i, p in enumerate(parts):
        for token in (f"__PH{i}__", f"__ph{i}__"):
            if token in out:
                out = out.replace(token, p)
                break
            low = out.lower()
            t = f"__ph{i}__"
            if t in low:
                idx = low.index(t)
                out = out[:idx] + p + out[idx + len(t) :]
                break
    return out


def load_cache() -> dict:
    if CACHE.exists():
        return json.loads(CACHE.read_text())
    return {}


def save_cache(cache: dict) -> None:
    with CACHE_LOCK:
        CACHE.write_text(json.dumps(cache, ensure_ascii=False))


def translate_gtx(text: str, tl: str) -> str:
    q = urllib.parse.quote(text)
    url = (
        "https://translate.googleapis.com/translate_a/single"
        f"?client=gtx&sl=en&tl={urllib.parse.quote(tl)}&dt=t&q={q}"
    )
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, context=CTX, timeout=45) as resp:
        data = json.loads(resp.read().decode("utf-8", errors="replace"))
    chunks = data[0] or []
    return "".join(part[0] for part in chunks if part and part[0])


def translate_batch_multiline(items: list[str], lang: str) -> list[str]:
    if not items:
        return []
    tl = GT_LANG[lang]
    protected = [protect(t) for t in items]
    payload = "\n".join(f"<<<{i}>>> {prot}" for i, (prot, _) in enumerate(protected))
    last_err = None
    for attempt in range(4):
        try:
            out = translate_gtx(payload, tl)
            by_idx: dict[int, str] = {}
            for line in out.splitlines():
                m = re.match(r"\s*<<<(\d+)>>>\s*(.*)$", line.strip())
                if m:
                    by_idx[int(m.group(1))] = m.group(2).strip()
            if len(by_idx) >= max(1, int(len(items) * 0.65)):
                results = []
                for i, (src, (prot, parts)) in enumerate(zip(items, protected)):
                    if i in by_idx and by_idx[i].strip():
                        results.append(unprotect(by_idx[i], parts))
                    else:
                        try:
                            results.append(unprotect(translate_gtx(prot, tl), parts))
                            time.sleep(0.04)
                        except Exception:
                            results.append(src)
                return results
            last_err = RuntimeError(f"parse {len(by_idx)}/{len(items)}")
        except Exception as e:
            last_err = e
            time.sleep(0.5 * (attempt + 1))
    print(f"  batch fail {lang}: {last_err}", flush=True)
    results = []
    for src, (prot, parts) in zip(items, protected):
        try:
            results.append(unprotect(translate_gtx(prot, tl), parts))
            time.sleep(0.06)
        except Exception:
            results.append(src)
    return results


def english_source(key: str, entry: dict) -> str:
    loc = (entry or {}).get("localizations") or {}
    en = ((loc.get("en") or {}).get("stringUnit") or {}).get("value")
    if en is not None and str(en).strip() != "":
        return en
    return key


def fill_language(lang: str, sources_needed: list[str], cache: dict) -> dict[str, str]:
    """Return map english_source -> translation for this language."""
    print(f"{lang}: {len(sources_needed)} unique sources…", flush=True)
    u2t: dict[str, str] = {}
    pending = []
    for s in sources_needed:
        ck = f"{lang}::{s}"
        if ck in cache:
            u2t[s] = cache[ck]
        else:
            pending.append(s)

    chunks: list[list[str]] = []
    chunk: list[str] = []
    size = 0
    for s in pending:
        if size + len(s) > 2800 and chunk:
            chunks.append(chunk)
            chunk, size = [], 0
        chunk.append(s)
        size += len(s) + 12
    if chunk:
        chunks.append(chunk)

    for ci, ch in enumerate(chunks):
        translated = translate_batch_multiline(ch, lang)
        for s, t in zip(ch, translated):
            if not (t or "").strip():
                t = s
            u2t[s] = t
            cache[f"{lang}::{s}"] = t
        if (ci + 1) % 3 == 0 or ci + 1 == len(chunks):
            print(f"  {lang}: chunk {ci+1}/{len(chunks)}", flush=True)
            save_cache(cache)
        time.sleep(0.1)
    print(f"{lang}: done", flush=True)
    return u2t


def main() -> None:
    data = json.loads(CATALOG.read_text())
    strings: dict = data["strings"]
    cache = load_cache()

    # Build unique English sources missing per language
    missing_sources: dict[str, list[str]] = {l: [] for l in TARGET_LANGS}
    key_source: dict[str, str] = {}
    for key, entry in strings.items():
        src = english_source(key, entry or {})
        key_source[key] = src
        if src == "" and key == "":
            continue
        loc = (entry or {}).get("localizations") or {}
        for lang in TARGET_LANGS:
            if ((loc.get(lang) or {}).get("stringUnit") or {}).get("value") is None:
                missing_sources[lang].append(src)

    # Unique per language
    for lang in TARGET_LANGS:
        missing_sources[lang] = list(dict.fromkeys(missing_sources[lang]))

    total_unique = sum(len(v) for v in missing_sources.values())
    print(f"Unique missing translations: {total_unique}", flush=True)

    results: dict[str, dict[str, str]] = {}
    with ThreadPoolExecutor(max_workers=5) as ex:
        futs = {
            ex.submit(fill_language, lang, missing_sources[lang], cache): lang
            for lang in TARGET_LANGS
            if missing_sources[lang]
        }
        for fut in as_completed(futs):
            lang = futs[fut]
            try:
                results[lang] = fut.result()
            except Exception as e:
                print(f"{lang}: FATAL {e}", flush=True)
                results[lang] = {}
            save_cache(cache)

    # Merge into catalog (single-threaded)
    filled = 0
    for key, entry in list(strings.items()):
        src = key_source.get(key) or english_source(key, entry or {})
        if not entry:
            entry = {}
            strings[key] = entry
        locs = entry.setdefault("localizations", {})
        for lang in TARGET_LANGS:
            if ((locs.get(lang) or {}).get("stringUnit") or {}).get("value") is None:
                value = results.get(lang, {}).get(src) or cache.get(f"{lang}::{src}") or src
                locs[lang] = {"stringUnit": {"state": "translated", "value": value}}
                filled += 1
        if "en" not in locs or not ((locs["en"].get("stringUnit") or {}).get("value")):
            if key and re.search(r"[A-Za-z]", key):
                locs["en"] = {"stringUnit": {"state": "translated", "value": key}}

    CATALOG.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    missing_after = 0
    for key, entry in strings.items():
        loc = (entry or {}).get("localizations") or {}
        for lang in TARGET_LANGS:
            if ((loc.get(lang) or {}).get("stringUnit") or {}).get("value") is None:
                missing_after += 1
    print(f"Filled slots: {filled}; remaining missing: {missing_after}", flush=True)
    print("Wrote", CATALOG, flush=True)


if __name__ == "__main__":
    main()
