#!/usr/bin/env bash
set -euo pipefail
umask 077

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
  local tmp
  tmp="$(mktemp "${ENV_FILE}.update.XXXXXX")"
  awk -v key="$key" -v value="$value" '
    index($0, key "=") == 1 { print key "=" value; found=1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$ENV_FILE" >"$tmp"
  mv "$tmp" "$ENV_FILE"
}
generate_secret() {
  local bytes="$1" result
  result="$(openssl rand -hex "$bytes")" || die "could not generate an installation secret"
  [[ "$result" =~ ^[[:xdigit:]]+$ && ${#result} -eq $((bytes * 2)) ]] \
    || die "random source returned an invalid installation secret"
  printf '%s' "$result"
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

# Publish only complete 0600 files. Concurrent starts use the first published value.
work="$(mktemp -d "$(dirname "$ENV_FILE")/.pms-bootstrap.XXXXXX")"
trap 'rm -rf "$work"' EXIT
publish_once() { ln "$1" "$2" 2>/dev/null || [[ -f "$2" ]]; }
if [[ ! -f "$ENV_FILE" ]]; then
  cat "$ROOT/.env.example" >"$work/env"
  publish_once "$work/env" "$ENV_FILE"
fi
chmod 600 "$ENV_FILE"
explicit_password="${PMS_BOOTSTRAP_ADMIN_PASSWORD:-}"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

PMS_PORT="${PMS_PORT:-5173}"
if ! [[ "$PMS_PORT" =~ ^[0-9]+$ ]] || (( PMS_PORT < 1 || PMS_PORT > 65535 )); then
  die "PMS_PORT must be a valid TCP port"
fi

if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$PMS_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  [[ -n "$(compose ps -q frontend 2>/dev/null)" ]] || die "port $PMS_PORT is already in use"
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

prefix="$ENV_FILE.pms-bootstrap"
if [[ "$(basename "$ENV_FILE")" == ".env" ]]; then prefix="$(dirname "$ENV_FILE")/.pms-bootstrap"; fi
secrets="$prefix-secrets"
handoff="$prefix-admin-password"
completed="$prefix-initialized"
if [[ ! -f "$secrets" ]]; then
  for key in MYSQL_ROOT_PASSWORD MYSQL_PASSWORD PMS_JWT_SECRET; do
    if is_placeholder "${!key:-}"; then
      value="$(generate_secret 32)"
      printf '%s=%s\n' "$key" "$value" >>"$work/secrets"
    fi
  done
  touch "$work/secrets"
  publish_once "$work/secrets" "$secrets"
fi
chmod 600 "$secrets"
for key in MYSQL_ROOT_PASSWORD MYSQL_PASSWORD PMS_JWT_SECRET; do
  if is_placeholder "${!key:-}"; then
    value="$(sed -n "s/^${key}=//p" "$secrets" | tail -n 1)"
    [[ -n "$value" ]] || die "restore $key from your installation backup before restarting"
    set_env "$key" "$value"
    export "$key=$value"
  fi
done

if [[ ! -f "$handoff" && ! -f "$completed" ]]; then
  value="${explicit_password:-${PMS_BOOTSTRAP_ADMIN_PASSWORD:-}}"
  if [[ "$value" == "PmsAdmin123!" ]]; then
    [[ -z "$explicit_password" ]] || die "choose a unique initial admin password"
    value='' # Replace the public default in historical sample files on a fresh database.
  fi
  if is_placeholder "$value"; then value="$(generate_secret 24)"; fi
  bytes="$(printf %s "$value" | wc -c)"
  [[ ${#value} -ge 12 && $bytes -le 72 && "$value" =~ [^[:space:]] && "$value" != *$'\n'* && "$value" != *$'\r'* ]]     || die "initial admin password needs at least 12 characters and at most 72 UTF-8 bytes on one line"
  printf '%s\n' "$value" >"$work/admin"
  publish_once "$work/admin" "$handoff"
fi
PMS_BOOTSTRAP_ADMIN_PASSWORD=''
if [[ -f "$handoff" ]]; then
  chmod 600 "$handoff"
  IFS= read -r PMS_BOOTSTRAP_ADMIN_PASSWORD <"$handoff" || die "admin credential file is incomplete"
  [[ -n "$PMS_BOOTSTRAP_ADMIN_PASSWORD" ]] || die "admin credential file is empty"
fi
export PMS_BOOTSTRAP_ADMIN_PASSWORD
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
    touch "$work/completed"
    publish_once "$work/completed" "$completed"
    if [[ -f "$handoff" ]]; then echo "Initial administrator credential for an empty database: $handoff"; fi
    exit 0
  fi
  if (( attempt % 12 == 0 )); then
    echo "still waiting (${attempt}/180); frontend=${frontend_health:-missing}"
  fi
  sleep 5
done

compose ps
die "frontend did not become running; inspect with ./scripts/logs.sh"
