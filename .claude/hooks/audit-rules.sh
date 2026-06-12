#!/usr/bin/env bash
# .claude/hooks/audit-rules.sh
#
# Stop hook (runs at the end of every assistant turn). Audits the project
# against the rules I have a habit of skipping under pressure:
#
#   - Rule #9 (i18n)   — every code string must be in Localizable.xcstrings.
#   - Rule #13 — RETIRED 2026-06-12 per user direction ("only add the
#     english keys for all future new strings; translate once we finish
#     the app"). Untranslated cells are now INFORMATIONAL only — they
#     are the expected state until the final app-completion pass, and
#     they no longer count as drift or trigger translator dispatch.
#
# Writes findings to .claude/rule-audit.log AND prints to stderr. The
# next assistant turn reads the log at the top of the SHIPPED workflow
# (and a SessionStart hook surfaces it). This is the structural fix for
# the "I claim Rule #X ✓ while skipping it" anti-pattern that the user
# called out 2026-06-06.
#
# Exit code 0 always — informational, never blocking (a session that
# legitimately introduces new strings must be able to finish so the
# orchestrator can spawn the translator agents on the next turn).

set -euo pipefail

# Resolve the repo root portably so this hook works on every surface:
#   - In a Claude Code hook context, $CLAUDE_PROJECT_DIR is the project root.
#   - Otherwise (manual run, other shells), derive it from this script's
#     own location ($REPO_ROOT/.claude/hooks/audit-rules.sh).
# This replaces a previously hardcoded macOS path that silently no-op'd in
# cloud / mobile (Claude Code on the web) sessions, where the repo lives
# under a different filesystem root.
REPO_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CATALOG="$REPO_ROOT/UniApp/Resources/Localizable.xcstrings"
AUDIT_LOG="$REPO_ROOT/.claude/rule-audit.log"

if [ ! -f "$CATALOG" ]; then
  exit 0
fi

python3 - "$REPO_ROOT" "$CATALOG" "$AUDIT_LOG" <<'PY' 2>&1
import json, os, re, sys, glob
from datetime import datetime, timezone

repo, catalog_path, log_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(catalog_path) as f:
    catalog = json.load(f)
existing_keys = set(catalog['strings'].keys())

TARGETS = ['es','zh-Hans','zh-Hant','hi','ar','pt-BR','bn','ru','ja','de',
           'fr','ko','it','tr','vi','th','id','fa','pl','nl',
           'uk','el','ro','cs','hu','sv','nb','da','fi','he',
           'ca','hr','sk','sl','sr','ur','bg','et','lt','lv',
           'is','ms','fil','sw','af','ta','te','ml','mr','pa']

# --- Rule #13: untranslated cells -----------------------------------------
missing_cells = 0
keys_with_missing = set()
for key, entry in catalog['strings'].items():
    if entry.get('shouldTranslate') is False:
        continue
    locs = entry.get('localizations', {})
    for lang in TARGETS:
        unit = locs.get(lang, {}).get('stringUnit', {})
        if unit.get('state') != 'translated' or not unit.get('value'):
            missing_cells += 1
            keys_with_missing.add(key)

# --- Rule #9: code strings not in catalog ---------------------------------
# Capture broader set of string introductions than the PostToolUse hook —
# include parameter-label patterns the original regex missed.
patterns = [
    r'\bText\(\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*[\),]',
    r'\bButton\(\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*[\),]',
    r'\bLabel\(\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*,',
    r'\bnavigationTitle\(\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*\)',
    r'\bnavigationTitle\(\s*Text\(\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*\)',
    r'\bString\(\s*localized:\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*[,\)]',
    r'\bLocalizedStringKey\(\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*\)',
    r'\bLocalizedStringResource\(\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*\)',
    r'\.accessibilityLabel\(\s*Text\(\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*\)',
    r'\.accessibilityHint\(\s*Text\(\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*\)',
    r'\btitle:\s*"([^"\\]*(?:\\.[^"\\]*)*)"',
    r'\bmessage:\s*"([^"\\]*(?:\\.[^"\\]*)*)"',
    r'\btext:\s*"([^"\\]*(?:\\.[^"\\]*)*)"',
    r'\bdetail:\s*"([^"\\]*(?:\\.[^"\\]*)*)"',
    r'\bplaceholder:\s*"([^"\\]*(?:\\.[^"\\]*)*)"',
    r'\bsubtitle:\s*"([^"\\]*(?:\\.[^"\\]*)*)"',
    r'\bprompt:\s*Text\(\s*"([^"\\]*(?:\\.[^"\\]*)*)"\s*\)',
    r'\btrailing:\s*"([^"\\]*(?:\\.[^"\\]*)*)"',
    r'\blabel:\s*"([^"\\]*(?:\\.[^"\\]*)*)"',
]
compiled = [re.compile(p) for p in patterns]

found = set()
for path in glob.glob(os.path.join(repo, 'UniApp/Sources/**/*.swift'), recursive=True):
    try:
        src = open(path).read()
    except Exception:
        continue
    for pat in compiled:
        for m in pat.finditer(src):
            s = m.group(1)
            if not s.strip(): continue
            if s.startswith('com.thuglife'): continue
            if s.startswith('http'): continue
            if len(s) < 2: continue
            # Pure-interpolation strings ("\(value)", "\(x.y)") carry no
            # translatable text after stripping the \(...) segments —
            # they are runtime values, not localizable keys.
            if not re.sub(r'\\\([^)]*\)', '', s).strip(): continue
            found.add(s)

missing_from_catalog = sorted(found - existing_keys)

# --- Report ---------------------------------------------------------------
# Rule #13 RETIRED 2026-06-12: untranslated cells are informational only.
# Drift = Rule #9 only (code strings missing from the catalog).
ts = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
clean = (len(missing_from_catalog) == 0)

with open(log_path, 'w') as f:
    f.write(f'# Rule audit run at {ts}\n\n')
    f.write(f'## Rule #9 (i18n) — strings in code missing from catalog: {len(missing_from_catalog)}\n')
    for k in missing_from_catalog[:30]:
        f.write(f'  - {k!r}\n')
    if len(missing_from_catalog) > 30:
        f.write(f'  ... and {len(missing_from_catalog) - 30} more\n')
    f.write(f'\n## INFO (Rule #13 retired 2026-06-12) — untranslated cells deferred to app completion: {missing_cells}')
    f.write(f' across {len(keys_with_missing)} keys\n' if missing_cells else '\n')
    f.write('   (Expected state — English keys only until the final translation pass. Do NOT dispatch translators.)\n')
    f.write('\n')
    if clean:
        f.write('STATUS: CLEAN — every rule audit returned 0 drift.\n')
    else:
        f.write('STATUS: DRIFT — run the Rule #20 two-stage chain (scanner -> catalog-writer, English keys only).\n')

# Print to stderr so the assistant sees it immediately on the next turn.
if not clean:
    print(f'⚠️  [rule-audit] Rule drift detected.', file=sys.stderr)
    print(f'   Rule #9:  {len(missing_from_catalog)} code strings missing from catalog.', file=sys.stderr)
    print(f'   Full report: {log_path}', file=sys.stderr)
    print(f'   Run the Rule #20 two-stage chain (scanner -> catalog-writer). English keys only — translators deferred.', file=sys.stderr)
PY

exit 0
