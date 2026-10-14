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
matches="$(git grep -I -n -i -E --untracked -e "$regex" -- ':!scripts/privacy-denylist.txt' || true)"

# The public npm package coordinate is intentionally documented so users can
# install the CLI. Keep this allowlist exact; other occurrences of the
# identifier must still fail the privacy scan.
violations="$matches"
if [[ -n "$violations" ]]; then
  violations="$(printf '%s\n' "$violations" | grep -vF '@brad.xie/pms-cli' || true)"
fi

if [[ -n "$violations" ]]; then
  printf '%s\n' "$violations"
  echo "privacy scan failed: remove company brand, internal hostnames, and real-person identifiers" >&2
  exit 1
fi

echo "privacy scan passed"
