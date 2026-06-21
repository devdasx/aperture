# Supabase → CSV exporter

`export_supabase_to_csv.py` dumps every readable table in a Supabase project to
a CSV file (one file per table).

## How it works

Supabase auto-generates a REST API (PostgREST) at `<project-url>/rest/v1/`. The
script:

1. Reads the OpenAPI spec at `/rest/v1/` to discover every table/view.
2. Pages through each table (1000 rows per request) and writes `<table>.csv`.

## Requirements

```bash
pip install requests
```

## Run

```bash
# Uses the URL/key baked into the script as defaults:
python3 scripts/export_supabase_to_csv.py

# Or override:
python3 scripts/export_supabase_to_csv.py \
  --url https://YOURPROJECT.supabase.co \
  --key <anon-or-service-role-key> \
  --out ./supabase_export

# Or via env vars:
SUPABASE_URL=... SUPABASE_KEY=... python3 scripts/export_supabase_to_csv.py

# Export only specific tables:
python3 scripts/export_supabase_to_csv.py --tables users orders
```

CSV files land in `./supabase_export/` by default (git-ignored).

## Important: anon key vs. service_role key

The default key is the project's **anon** key. It is public by design and every
query through it is filtered by your **Row Level Security (RLS)** policies — so
you only get rows that are exposed to the anonymous role. If a table comes back
empty or is missing, RLS is hiding it.

To export rows that RLS hides, run with the project's **`service_role`** key
instead. That key bypasses RLS and must be kept secret — never commit it or put
it in client code.
