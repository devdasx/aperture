#!/usr/bin/env bash
# .claude/hooks/check-new-strings.sh
#
# PostToolUse hook (CLAUDE.md Rule #9 Part E). Runs after every Edit/Write
# that touches a .swift or .xcstrings file. Detects whether new
# user-facing strings were introduced, and if so appends a queue entry to
# `.claude/translation-queue.log` so the main agent (and the translator
# agents) know there's work to do.
#
# The hook receives the tool call's JSON payload on stdin. We parse the
# `file_path` field from it, decide whether to scan, and emit output to
# stderr + queue file. Exit code 0 always — this hook is informational,
# never blocking.

set -euo pipefail

# Read tool payload from stdin (Claude Code hook contract)
PAYLOAD="$(cat || true)"

# Best-effort extract file_path (jq optional)
FILE_PATH="$(printf '%s' "$PAYLOAD" | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read() or '{}')
    print(d.get('tool_input', {}).get('file_path') or d.get('file_path') or '', end='')
except Exception:
    pass
" 2>/dev/null || true)"

# Only act on Swift / xcstrings files inside the project
case "$FILE_PATH" in
  */UniApp/*.swift|*/UniApp/Resources/Localizable.xcstrings|*Localizable.xcstrings)
    ;;
  *)
    exit 0
    ;;
esac

REPO_ROOT="/Users/thuglifex/Documents/UniApp"
QUEUE_LOG="$REPO_ROOT/.claude/translation-queue.log"
CATALOG="$REPO_ROOT/UniApp/Resources/Localizable.xcstrings"

# If the catalog doesn't exist yet (initial bootstrap), nothing to compare.
[ -f "$CATALOG" ] || exit 0

# Extract localizable string LITERALS from the changed file. We accept the
# common surfaces SwiftUI auto-localizes from:
#   Text("...")
#   Button("...") { … }
#   Label("...", ...)
#   String(localized: "...")
#   LocalizedStringResource("...")
#   LocalizedStringKey("...")
# We capture the literal between the FIRST pair of double quotes after the
# call name. False positives are acceptable — the queue is advisory; the
# translator agents do the real reconciliation against the catalog.

if [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

DETECTED_KEYS="$(grep -oE '(Text|Button|Label|String\(localized:|LocalizedStringResource|LocalizedStringKey)\([^"]*"[^"]+"' "$FILE_PATH" 2>/dev/null \
  | sed -E 's/.*"([^"]+)".*/\1/' \
  | sort -u || true)"

if [ -z "$DETECTED_KEYS" ]; then
  exit 0
fi

# For each detected key, check if it already has a translated entry in the
# catalog. If not, append to the queue with a timestamp.
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ADDED=0
while IFS= read -r KEY; do
  [ -z "$KEY" ] && continue
  # Skip if catalog already lists this key (basic literal match — String
  # Catalog JSON contains the key inside quotes at the start of an entry).
  if grep -qF "\"$KEY\" :" "$CATALOG" 2>/dev/null; then
    continue
  fi
  printf '%s\t%s\t%s\n' "$TS" "$FILE_PATH" "$KEY" >> "$QUEUE_LOG"
  ADDED=$((ADDED + 1))
done <<< "$DETECTED_KEYS"

if [ "$ADDED" -gt 0 ]; then
  echo "🌐 [check-new-strings] $ADDED new string(s) detected in $FILE_PATH — queued in .claude/translation-queue.log. Run translator-primary + translator-secondary (background) to translate." >&2
fi

exit 0
