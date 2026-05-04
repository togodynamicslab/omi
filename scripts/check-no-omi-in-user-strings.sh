#!/usr/bin/env bash
# Fail the build if "Omi" leaks into user-facing surfaces.
#
# We are a fork of Omi but ship as Nooto. After every upstream merge from
# based-hardware/omi, this lint catches re-leaked brand strings before they
# reach users.
#
# Surfaces scanned:
#   - app-v2/lib/l10n/*.arb               -> JSON value lines (skip "@key" descriptions)
#   - app-v2/lib/**/*.dart                -> non-comment lines (skip /// and //)
#   - backend/utils/llm/*.py              -> non-comment lines (skip # and prompt_cache_key=)
#   - desktop-v2/src/**/*.ts(x)           -> non-comment lines (skip // and *-prefixed block lines)
#
# Match rule: case-insensitive whole-word "omi" (grep -wi). Identifiers like
# omiServiceUuid or IsAnOmiQuestion are not matched — only standalone tokens.
#
# Allowlist: any line containing `// allow-omi:` or `# allow-omi:` is skipped.
# Use sparingly with a reason after the colon.

set -u

# Resolve repo root from this script's location so we can be invoked from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

found=0

# Match the word "omi" case-insensitive. -w treats word boundaries portably
# across BSD grep (macOS) and GNU grep (Linux/CI), so identifiers like
# omiServiceUuid or IsAnOmiQuestion don't match — only standalone tokens do.
PATTERN='omi'

scan() {
  local file="$1"
  local skip_pattern="$2"  # extended regex for lines to ignore

  # Pull line numbers + content with grep -n; filter out skip_pattern lines and allowlisted lines.
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    # entry format: "<lineno>:<content>"
    local lineno content
    lineno="${entry%%:*}"
    content="${entry#*:}"

    # Skip allowlisted lines.
    if [[ "$content" == *"// allow-omi:"* ]] || [[ "$content" == *"# allow-omi:"* ]]; then
      continue
    fi

    # Skip lines matching the surface-specific skip pattern.
    if [ -n "$skip_pattern" ] && echo "$content" | grep -qE "$skip_pattern"; then
      continue
    fi

    echo "$file:$lineno:$content" >&2
    found=1
  done < <(grep -niw "$PATTERN" "$file" 2>/dev/null || true)
}

# ARB files: skip "@..." description lines (translator metadata, not user copy).
arb_skip='^[[:space:]]*"description"[[:space:]]*:'
for f in app-v2/lib/l10n/*.arb; do
  [ -f "$f" ] || continue
  scan "$f" "$arb_skip"
done

# Dart files in app-v2/lib: skip pure /// and // comment lines.
dart_skip='^[[:space:]]*(///|//)'
while IFS= read -r f; do
  scan "$f" "$dart_skip"
done < <(find app-v2/lib -type f -name '*.dart' 2>/dev/null)

# Backend LLM Python files: skip pure # comment lines and prompt_cache_key= lines.
py_skip='(^[[:space:]]*#)|(prompt_cache_key)'
for f in backend/utils/llm/*.py; do
  [ -f "$f" ] || continue
  scan "$f" "$py_skip"
done

# desktop-v2 TS/TSX: skip pure // comment lines and lines whose first non-whitespace
# token is `*` (continuation lines inside /* ... */ block comments). Multi-line
# /* */ comments where the opening and offending text share a line are rare; the
# `// allow-omi:` escape hatch handles the residual cases.
ts_skip='^[[:space:]]*(//|\*)'
while IFS= read -r f; do
  scan "$f" "$ts_skip"
done < <(find desktop-v2/src -type f \( -name '*.tsx' -o -name '*.ts' \) 2>/dev/null)

if [ "$found" -ne 0 ]; then
  echo "" >&2
  echo "Omi leaked into a user-facing surface. Replace with Nooto, or add" >&2
  echo "  // allow-omi: <reason>   (Dart)" >&2
  echo "  # allow-omi: <reason>    (Python)" >&2
  echo "if the reference is genuinely internal." >&2
  exit 1
fi

echo "no Omi leaks in user-facing surfaces"
exit 0
