#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT/compose.yaml}"
# shellcheck disable=SC1091
source "$ROOT/scripts/compose-project-name.sh"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(default_compose_project_name "$ROOT")}"

# shellcheck disable=SC1091
source "$ROOT/scripts/docker-resources.sh"

die() { echo "bootstrap error: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
compose() { docker compose --project-directory "$ROOT" --project-name "$COMPOSE_PROJECT_NAME" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }
set_env() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
    rm -f "$ENV_FILE.bak"
  else
    printf '%s=%s\n' "$key" "$value" >>"$ENV_FILE"
  fi
}
is_placeholder() {
  [[ "${1:-}" == change-me-* || "${1:-}" == "" ]]
}

require_command docker
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"

if [[ -f "$ENV_FILE" ]]; then
  configured_memory_gib="$(sed -n 's/^PMS_MIN_DOCKER_MEMORY_GIB=//p' "$ENV_FILE" | tail -n 1)"
  if [[ -n "$configured_memory_gib" ]]; then
    PMS_MIN_DOCKER_MEMORY_GIB="$configured_memory_gib"
    export PMS_MIN_DOCKER_MEMORY_GIB
  fi
fi

docker_memory_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || true)"
check_docker_memory_limit "$docker_memory_bytes" || die "Docker resources are insufficient for this installation"

require_command openssl

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$ROOT/.env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "created $ENV_FILE"
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

PMS_PORT="${PMS_PORT:-5173}"
if ! [[ "$PMS_PORT" =~ ^[0-9]+$ ]] || (( PMS_PORT < 1 || PMS_PORT > 65535 )); then
  die "PMS_PORT must be a valid TCP port"
fi

if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$PMS_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  die "port $PMS_PORT is already in use"
fi

# Browsers send Origin even for same-host /api calls. A custom PMS_PORT with the
# example CORS list will make sign-in fail with 403.
if [[ "$PMS_PORT" != "5173" ]]; then
  case "${PMS_CORS_ALLOWED_ORIGINS:-}" in
    ""|http://localhost:5173|http://localhost:5173,http://127.0.0.1:5173)
      set_env PMS_CORS_ALLOWED_ORIGINS "http://localhost:${PMS_PORT},http://127.0.0.1:${PMS_PORT}"
      PMS_CORS_ALLOWED_ORIGINS="http://localhost:${PMS_PORT},http://127.0.0.1:${PMS_PORT}"
      ;;
  esac
  if [[ "${PMS_PUBLIC_BASE_URL:-}" == "http://localhost:5173" || "${PMS_PUBLIC_BASE_URL:-}" == "" ]]; then
    set_env PMS_PUBLIC_BASE_URL "http://localhost:${PMS_PORT}"
    PMS_PUBLIC_BASE_URL="http://localhost:${PMS_PORT}"
  fi
fi

touch "$ROOT/.pms-bootstrap-secrets"
# Only randomize infrastructure secrets. The initial admin password stays the
# documented default from .env.example so first login is predictable.
for key in MYSQL_ROOT_PASSWORD MYSQL_PASSWORD PMS_JWT_SECRET; do
  value="${!key:-}"
  if is_placeholder "$value"; then
    case "$key" in
      PMS_JWT_SECRET) value="$(openssl rand -hex 32)" ;;
      *) value="$(openssl rand -hex 16)" ;;
    esac
    set_env "$key" "$value"
    printf '%s=%s\n' "$key" "$value" >>"$ROOT/.pms-bootstrap-secrets"
  fi
done
chmod 600 "$ROOT/.pms-bootstrap-secrets"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ "${PMS_BOOTSTRAP_ADMIN_PASSWORD:-}" == "change-me-"* || ${#PMS_BOOTSTRAP_ADMIN_PASSWORD} -lt 12 ]]; then
  die "PMS_BOOTSTRAP_ADMIN_PASSWORD must be at least 12 characters (documented default: PmsAdmin123!)"
fi
if [[ -z "${PMS_BOOTSTRAP_ADMIN_EMAIL:-}" ]]; then
  die "PMS_BOOTSTRAP_ADMIN_EMAIL is required"
fi

compose config >/dev/null || die "Compose configuration is invalid"
if ! compose pull; then
  echo "warning: image pull failed; continuing with locally cached images" >&2
fi
compose up -d

echo "waiting for frontend health check..."
for attempt in {1..180}; do
  frontend_id="$(compose ps -q frontend 2>/dev/null || true)"
  frontend_health=""
  if [[ -n "$frontend_id" ]]; then
    frontend_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$frontend_id" 2>/dev/null || true)"
  fi
  if [[ "$frontend_health" == "healthy" ]]; then
    echo "PMS is available at http://localhost:${PMS_PORT}"
    echo "Initial admin login (empty database only):"
    echo "  email:    ${PMS_BOOTSTRAP_ADMIN_EMAIL}"
    echo "  password: ${PMS_BOOTSTRAP_ADMIN_PASSWORD}"
    echo "Change this password immediately after first login."
    if [[ -s "$ROOT/.pms-bootstrap-secrets" ]]; then
      echo "Generated MySQL/JWT secrets were written to $ROOT/.pms-bootstrap-secrets"
    fi
    exit 0
  fi
  if (( attempt % 12 == 0 )); then
    echo "still waiting (${attempt}/180); frontend=${frontend_health:-missing}"
  fi
  sleep 5
done

compose ps
die "frontend did not become running; inspect with ./scripts/logs.sh"
