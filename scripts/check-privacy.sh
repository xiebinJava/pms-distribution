#!/usr/bin/env bash
# Fail if tracked or untracked (non-ignored) files contain company or personal identifiers.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DENYLIST="$ROOT/scripts/privacy-denylist.txt"

if [[ ! -f "$DENYLIST" ]]; then
  echo "privacy denylist missing: $DENYLIST" >&2
  exit 2
fi

patterns=()
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    ''|'#'*) continue ;;
  esac
  patterns+=("$line")
done < "$DENYLIST"

if [[ ${#patterns[@]} -eq 0 ]]; then
  echo "privacy denylist is empty: $DENYLIST" >&2
  exit 2
fi

regex="$(printf '%s|' "${patterns[@]}")"
regex="${regex%|}"

cd "$ROOT"
if git grep -I -n -i -E --untracked -e "$regex" -- ':!scripts/privacy-denylist.txt'; then
  echo "privacy scan failed: remove company brand, internal hostnames, and real-person identifiers" >&2
  exit 1
fi

echo "privacy scan passed"
