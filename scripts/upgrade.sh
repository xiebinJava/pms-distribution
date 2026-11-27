#!/usr/bin/env bash
set -euo pipefail
umask 077
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
lock="${ENV_FILE}.upgrade.lock"
recovery="${ENV_FILE}.upgrade-recovery"
mkdir "$lock" || die "an upgrade already owns $lock"
archive=''
restored_uploads_volume=''
stopped=0

service_ready() {
  local service="$1" id health
  id="$(compose ps -q "$service" 2>/dev/null)" || return 1
  [[ -n "$id" ]] || return 1
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' "$id" 2>/dev/null)" || return 1
  [[ "$health" == healthy ]] || return 1
  [[ "$service" == frontend ]] || docker exec "$id" curl --fail --silent --show-error \
    --max-time 4 http://127.0.0.1:8080/api/health/ready | grep -q '"status":"UP"'
}

wait_for_service() {
  for _ in {1..90}; do
    if service_ready "$1"; then return 0; fi
    sleep 2
  done
  return 1
}

verify_uploads_mount() {
  local expected="$1" backend_id mounted
  [[ -z "$expected" ]] && return 0
  backend_id="$(compose ps -q backend)" || return 1
  [[ -n "$backend_id" ]] || return 1
  mounted="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/var/lib/pms/uploads"}}{{.Name}}{{end}}{{end}}' "$backend_id")" || return 1
  if [[ "$mounted" != "$expected" ]]; then
    echo "rollback attachments: expected volume $expected, mounted ${mounted:-none}" >&2
    return 1
  fi
  if ! docker exec "$backend_id" sh -c 'test -r /var/lib/pms/uploads && test -x /var/lib/pms/uploads'; then
    echo "rollback attachments: backend cannot read the restored uploads directory" >&2
    return 1
  fi
}

start_application() {
  compose up -d --no-deps --force-recreate backend && wait_for_service backend \
    && verify_uploads_mount "${1:-}" \
    && compose up -d --no-deps --force-recreate frontend && wait_for_service frontend
}

write_config() {
  awk -v version="$1" -v database="${2:-}" -v volume="${3:-}" '
    /^PMS_VERSION=/ { next }
    /^MYSQL_DB=/ && database != "" { next }
    /^PMS_UPLOADS_VOLUME=/ && volume != "" { next }
    { print }
    END {
      print "PMS_VERSION=" version
      if (database != "") print "MYSQL_DB=" database
      if (volume != "") print "PMS_UPLOADS_VOLUME=" volume
    }
  ' "$lock/original.env" >"$lock/next.env" && mv "$lock/next.env" "$ENV_FILE"
}

restore_snapshot() {
  local suffix database volume
  suffix="$(date -u +%Y%m%d%H%M%S)p$$" || return 1
  database="pmsrollback$suffix"
  volume="${COMPOSE_PROJECT_NAME}_pms-uploads-rollback-$suffix"
  # Retain the candidate data and restore to fresh destinations.
  ENV_FILE="$ENV_FILE" COMPOSE_FILE="$COMPOSE_FILE" COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" \
    RESTORE_CONFIRM=YES RESTORE_DATABASE="$database" RESTORE_UPLOADS_VOLUME="$volume" \
    "$ROOT/scripts/restore.sh" --upgrade-rollback "$archive" >&2 || return 1
  write_config "$previous_version" "$database" "$volume" || return 1
  export MYSQL_DB="$database" PMS_UPLOADS_VOLUME="$volume"
  restored_uploads_volume="$volume"
  echo "rollback is using database=$database uploads_volume=$volume" >&2
}

restore_original_config() {
  cp "$lock/original.env" "$lock/next.env" && mv "$lock/next.env" "$ENV_FILE" || return 1
  export PMS_VERSION="$previous_version" MYSQL_DB="$original_database" PMS_UPLOADS_VOLUME="$original_uploads_volume"
}

record_recovery() {
  local staged="$lock/recovery"
  mkdir "$staged"
  cp "$lock/original.env" "$staged/original.env"
  printf '%s\n' "$previous_version" "$archive" "$COMPOSE_PROJECT_NAME" "$COMPOSE_FILE" \
    "$original_database" "$original_uploads_volume" >"$staged/details"
  mv "$staged" "$recovery"
}

load_recovery() {
  local project file
  {
    IFS= read -r previous_version &&
      IFS= read -r archive &&
      IFS= read -r project &&
      IFS= read -r file &&
      IFS= read -r original_database &&
      IFS= read -r original_uploads_volume
  } <"$recovery/details" || die "cannot read the pending recovery record in $recovery"
  [[ "$project" == "$COMPOSE_PROJECT_NAME" && "$file" == "$COMPOSE_FILE" ]] \
    || die "pending recovery belongs to Compose project $project and file $file"
  is_semver "$previous_version" || die "invalid previous version in $recovery"
  [[ -n "$original_database" && -n "$original_uploads_volume" && -f "$archive" && -f "$archive.sha256" ]] \
    || die "pending recovery is missing its original database, uploads volume, or backup: $archive"
  cp "$recovery/original.env" "$lock/original.env"
}

rollback_application() {
  if ! compose stop frontend backend; then
    echo "rollback failed: could not stop the candidate application" >&2
  elif ! restore_original_config; then
    echo "rollback failed: could not restore the prior configuration" >&2
  elif ! restore_snapshot; then
    echo "rollback failed: could not prepare the pre-upgrade snapshot; the application remains stopped" >&2
  elif ! start_application "$restored_uploads_volume"; then
    echo "rollback failed: previous version $previous_version did not become ready" >&2
  else
    mv "$recovery" "$lock/completed-recovery" || return 1
    echo "rollback verified: previous version $previous_version is ready" >&2
    return 0
  fi
  echo "pending recovery retained for original backup: $archive" >&2
  return 1
}

finish() {
  local code="$?"
  trap - EXIT INT TERM
  if (( code != 0 && stopped )) && [[ ! -d "$lock/completed-recovery" ]]; then
    if [[ -d "$recovery" ]]; then
      rollback_application || true
    elif restore_original_config && start_application; then
      echo "restart verified: previous version $previous_version is ready" >&2
    else
      echo "restart failed: previous version $previous_version did not become ready" >&2
    fi
    [[ -z "$archive" ]] || echo "pre-upgrade backup: $archive" >&2
    compose ps >&2 || true
    compose logs --tail=200 mysql backend frontend >&2 || true
  fi
  rm -rf "$lock"
  exit "$code"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
require_command docker
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"
compose_directory="$(cd "$(dirname "$COMPOSE_FILE")" && pwd -P)"
COMPOSE_FILE="$compose_directory/$(basename "$COMPOSE_FILE")"

if [[ -d "$recovery" ]]; then
  load_recovery
  echo "resuming rollback from original backup: $archive" >&2
  if rollback_application; then
    echo "previous version recovered; requested upgrade to $target_version has not run" >&2
  fi
  exit 1
fi

previous_version="${PMS_VERSION:-}"
is_semver "$previous_version" || die "current PMS_VERSION must be a valid semantic version"
[[ "$target_version" != "$previous_version" ]] || die "target version is already installed"
service_ready backend || die "current backend must be ready before taking an upgrade backup"
original_database="${MYSQL_DB:-pms}"
original_uploads_volume="${PMS_UPLOADS_VOLUME:-${COMPOSE_PROJECT_NAME}_pms-uploads}"
cp "$ENV_FILE" "$lock/original.env"
# Pull before interrupting the running services.
PMS_VERSION="$target_version" compose pull mysql backend frontend

# Take the backup with all application writers stopped. MySQL stays running.
stopped=1
compose stop frontend backend
archive="$(ENV_FILE="$ENV_FILE" COMPOSE_FILE="$COMPOSE_FILE" COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" \
  "$ROOT/scripts/backup.sh" --print-path)"
archive_directory="$(cd "$(dirname "$archive")" && pwd -P)"
archive="$archive_directory/$(basename "$archive")"
echo "pre-upgrade backup: $archive"
record_recovery
write_config "$target_version"
export PMS_VERSION="$target_version"
start_application || die "candidate did not become healthy and ready"
mv "$recovery" "$lock/completed-recovery"
echo "upgrade complete: $previous_version -> $target_version"
