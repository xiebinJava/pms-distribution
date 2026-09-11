#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT/compose.yaml}"
# shellcheck disable=SC1091
source "$ROOT/scripts/compose-project-name.sh"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(default_compose_project_name "$ROOT")}"
[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE; run ./scripts/bootstrap.sh first" >&2; exit 1; }
exec docker compose --project-name "$COMPOSE_PROJECT_NAME" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs -f --tail="${PMS_LOG_TAIL:-200}" "$@"
