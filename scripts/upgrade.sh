#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT/compose.yaml}"
# shellcheck disable=SC1091
source "$ROOT/scripts/compose-project-name.sh"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(default_compose_project_name "$ROOT")}"
die() { echo "upgrade error: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
compose() { docker compose --project-name "$COMPOSE_PROJECT_NAME" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }
is_semver() { [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; }
[[ $# -eq 1 ]] || die "usage: $0 <version>"
target_version="$1"
is_semver "$target_version" || die "version must be a valid semantic version"
[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE; run ./scripts/bootstrap.sh first"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
previous_version="${PMS_VERSION:-}"
is_semver "$previous_version" || die "current PMS_VERSION must be a valid semantic version"
[[ "$target_version" != "$previous_version" ]] || die "target version is already installed"
require_command docker
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"
ENV_FILE="$ENV_FILE" COMPOSE_FILE="$COMPOSE_FILE" COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" "$ROOT/scripts/backup.sh"
env_backup="$(mktemp "${ENV_FILE}.upgrade.XXXXXX")"
cp "$ENV_FILE" "$env_backup"
updated_env="$(mktemp "${ENV_FILE}.updated.XXXXXX")"
wait_for_readiness() {
  for _ in {1..90}; do
    backend_id="$(compose ps -q backend 2>/dev/null || true)"
    frontend_id="$(compose ps -q frontend 2>/dev/null || true)"
    backend_health=""
    frontend_health=""
    [[ -z "$backend_id" ]] || backend_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' "$backend_id" 2>/dev/null || true)"
    [[ -z "$frontend_id" ]] || frontend_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' "$frontend_id" 2>/dev/null || true)"
    if [[ "$backend_health" == "healthy" && "$frontend_health" == "healthy" ]] && docker exec "$backend_id" curl --fail --silent --show-error --max-time 4 http://127.0.0.1:8080/api/health/ready | grep -q '"status":"UP"'; then return 0; fi
    sleep 2
  done
  return 1
}
rollback() {
  local code="$?"
  if [[ "$code" -ne 0 ]]; then
    mv "$env_backup" "$ENV_FILE"
    echo "upgrade failed; restored PMS_VERSION=$previous_version" >&2
    if ! compose up -d --force-recreate backend frontend; then
      echo "rollback failed: could not recreate backend/frontend with PMS_VERSION=$previous_version" >&2
    elif ! wait_for_readiness; then
      echo "rollback failed: backend/frontend did not become healthy and ready with PMS_VERSION=$previous_version" >&2
    else
      echo "rollback verified: backend/frontend are healthy and ready with PMS_VERSION=$previous_version" >&2
    fi
    compose ps >&2 || true
    compose logs --tail=200 mysql backend frontend >&2 || true
  else
    rm -f "$env_backup"
  fi
  rm -f "$updated_env"
  exit "$code"
}
trap rollback EXIT
awk -v version="$target_version" '
  BEGIN { replaced=0 }
  /^PMS_VERSION=/ { print "PMS_VERSION=" version; replaced=1; next }
  { print }
  END { if (!replaced) print "PMS_VERSION=" version }
' "$ENV_FILE" >"$updated_env"
mv "$updated_env" "$ENV_FILE"
compose pull mysql backend frontend
compose up -d --force-recreate
wait_for_readiness || die "backend/frontend did not become healthy; diagnostics follow"
echo "upgrade complete: $previous_version -> $target_version"
