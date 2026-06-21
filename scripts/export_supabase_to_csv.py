#!/usr/bin/env python3
"""
Export all readable tables from a Supabase project to CSV files.

It talks to the auto-generated PostgREST API that every Supabase project
exposes at  <project-url>/rest/v1/ :

  1. GET /rest/v1/            -> OpenAPI spec, used to discover every table
  2. GET /rest/v1/<table>     -> rows, fetched page-by-page and written to CSV

Notes on what "all data" means here
-----------------------------------
This uses the project's **anon** API key, so you will only get the rows that
your Row Level Security (RLS) policies expose to the anonymous role. That is by
design: the anon key is meant to be public and is always filtered by RLS. To
dump rows that RLS hides, run this with the project's *service_role* key
instead (keep that one secret — never commit it).

Usage
-----
    # uses the built-in defaults below
    python3 export_supabase_to_csv.py

    # or override per-run
    python3 export_supabase_to_csv.py \
        --url   https://YOURPROJECT.supabase.co \
        --key   <anon-or-service-role-key> \
        --out   ./supabase_export

    # or via environment variables
    SUPABASE_URL=...  SUPABASE_KEY=...  python3 export_supabase_to_csv.py

Only dependency: the `requests` package  ->  pip install requests
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
from typing import Any

import requests

# --- Defaults (override with --url/--key or env vars) ------------------------
# The anon key is safe to embed: it is public by design and constrained by RLS.
DEFAULT_URL = "https://adaiiavwbdshctxcvrwm.supabase.co"
DEFAULT_KEY = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
    "eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFkYWlpYXZ3YmRzaGN0eGN2cndtIiwicm9sZSI6"
    "ImFub24iLCJpYXQiOjE3ODIwMTUzODcsImV4cCI6MjA5NzU5MTM4N30."
    "6WXIZrwIBdZZx-nznp902d3KzQ4uvdrcfun8oAmqEiI"
)

PAGE_SIZE = 1000          # rows fetched per request
MAX_RETRIES = 4           # network retries per request (exponential backoff)


def log(msg: str) -> None:
    print(msg, flush=True)


def make_session(key: str) -> requests.Session:
    s = requests.Session()
    s.headers.update(
        {
            "apikey": key,
            "Authorization": f"Bearer {key}",
            "Accept": "application/json",
        }
    )
    return s


def get_with_retries(session: requests.Session, url: str, **kwargs) -> requests.Response:
    """GET with simple exponential-backoff retries on network/5xx errors."""
    delay = 2.0
    last_exc: Exception | None = None
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = session.get(url, timeout=60, **kwargs)
            if resp.status_code >= 500:
                raise requests.HTTPError(f"server error {resp.status_code}", response=resp)
            return resp
        except requests.RequestException as exc:
            last_exc = exc
            if attempt == MAX_RETRIES:
                break
            log(f"    request failed ({exc}); retrying in {delay:.0f}s "
                f"[{attempt}/{MAX_RETRIES}]")
            time.sleep(delay)
            delay *= 2
    raise RuntimeError(f"giving up on {url}: {last_exc}")


def discover_tables(session: requests.Session, base: str) -> list[str]:
    """Read the PostgREST OpenAPI spec to list every exposed table/view."""
    resp = get_with_retries(session, base + "/")
    resp.raise_for_status()
    spec = resp.json()

    # `definitions` holds one entry per table/view. RPC functions live under
    # paths like /rpc/..., which we deliberately ignore.
    tables = sorted(spec.get("definitions", {}).keys())
    if not tables:
        # Fallback: derive from paths if definitions is empty.
        tables = sorted(
            p.strip("/")
            for p in spec.get("paths", {})
            if p.startswith("/") and p != "/" and not p.startswith("/rpc/")
        )
    return tables


def flatten_value(v: Any) -> Any:
    """Make a value CSV-friendly. Dicts/lists -> compact JSON; None -> ''."""
    if v is None:
        return ""
    if isinstance(v, (dict, list)):
        return json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, bool):
        return "true" if v else "false"
    return v


def fetch_all_rows(session: requests.Session, base: str, table: str) -> list[dict]:
    """Page through one table and return all rows the key is allowed to read."""
    rows: list[dict] = []
    offset = 0
    while True:
        params = {"select": "*", "limit": PAGE_SIZE, "offset": offset}
        resp = get_with_retries(session, f"{base}/{table}", params=params)
        if resp.status_code != 200:
            raise RuntimeError(f"HTTP {resp.status_code}: {resp.text[:200]}")
        batch = resp.json()
        if not isinstance(batch, list):
            raise RuntimeError(f"unexpected response: {str(batch)[:200]}")
        rows.extend(batch)
        if len(batch) < PAGE_SIZE:
            break
        offset += PAGE_SIZE
        log(f"    fetched {len(rows)} rows so far...")
    return rows


def write_csv(path: str, rows: list[dict]) -> None:
    """Write rows to CSV using the union of all keys as the header."""
    # Build a stable column order: first-seen order across all rows.
    columns: list[str] = []
    seen: set[str] = set()
    for row in rows:
        for k in row.keys():
            if k not in seen:
                seen.add(k)
                columns.append(k)

    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({k: flatten_value(row.get(k)) for k in columns})


def main() -> int:
    parser = argparse.ArgumentParser(description="Export Supabase tables to CSV.")
    parser.add_argument("--url", default=os.environ.get("SUPABASE_URL", DEFAULT_URL),
                        help="Supabase project URL")
    parser.add_argument("--key", default=os.environ.get("SUPABASE_KEY", DEFAULT_KEY),
                        help="Supabase API key (anon or service_role)")
    parser.add_argument("--out", default=os.environ.get("SUPABASE_OUT", "supabase_export"),
                        help="Output directory for CSV files")
    parser.add_argument("--tables", nargs="*", default=None,
                        help="Only export these tables (default: all discovered)")
    args = parser.parse_args()

    base = args.url.rstrip("/") + "/rest/v1"
    out_dir = args.out
    os.makedirs(out_dir, exist_ok=True)

    session = make_session(args.key)

    log(f"Project : {args.url}")
    log(f"Output  : {os.path.abspath(out_dir)}\n")

    log("Discovering tables...")
    try:
        tables = args.tables or discover_tables(session, base)
    except Exception as exc:
        log(f"ERROR: could not discover tables: {exc}")
        return 1

    if not tables:
        log("No tables found (the anon key may not expose any tables via RLS).")
        return 0

    log(f"Found {len(tables)} table(s): {', '.join(tables)}\n")

    summary: list[tuple[str, int | str]] = []
    for table in tables:
        log(f"-> {table}")
        try:
            rows = fetch_all_rows(session, base, table)
            csv_path = os.path.join(out_dir, f"{table}.csv")
            write_csv(csv_path, rows)
            log(f"   saved {len(rows)} row(s) -> {csv_path}")
            summary.append((table, len(rows)))
        except Exception as exc:
            log(f"   SKIPPED ({exc})")
            summary.append((table, f"error: {exc}"))

    log("\n=== Summary ===")
    for table, result in summary:
        log(f"  {table}: {result}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
