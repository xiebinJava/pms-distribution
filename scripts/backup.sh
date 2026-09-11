#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT/compose.yaml}"
# shellcheck disable=SC1091
source "$ROOT/scripts/compose-project-name.sh"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(default_compose_project_name "$ROOT")}"
BACKUP_DIR="${BACKUP_DIR:-$ROOT/backups}"
die() { echo "backup error: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
require_sha256() { command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || die "sha256sum or shasum is required"; }
compose() { docker compose --project-name "$COMPOSE_PROJECT_NAME" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }
require_command docker
require_sha256
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"
[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE; run ./scripts/bootstrap.sh first"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
[[ -n "${PMS_VERSION:-}" ]] || die "PMS_VERSION must be set"
[[ -n "${MYSQL_ROOT_PASSWORD:-}" ]] || die "MySQL root password must be set"
mysql_id="$(compose ps -q mysql 2>/dev/null || true)"
[[ -n "$mysql_id" ]] || die "mysql is not running; refusing to create a partial backup"
mysql_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' "$mysql_id" 2>/dev/null || true)"
[[ "$mysql_health" == "healthy" ]] || die "mysql is not healthy; refusing to create a partial backup"
uploads_volume="${COMPOSE_PROJECT_NAME}_pms-uploads"
docker volume inspect "$uploads_volume" >/dev/null 2>&1 || die "uploads volume $uploads_volume does not exist"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive_name="pms-backup-${timestamp}.tar.gz"
mkdir -p "$BACKUP_DIR"
archive_path="$BACKUP_DIR/$archive_name"
checksum_path="$archive_path.sha256"
[[ ! -e "$archive_path" && ! -e "$checksum_path" ]] || die "backup destination already exists: $archive_path"
# Keep the work directory under the repository so Colima/Lima can bind-mount it.
mkdir -p "$BACKUP_DIR"
work_dir="$(mktemp -d "$BACKUP_DIR/.work.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
mysql_env="$work_dir/mysql.env"
umask 077
printf 'MYSQL_PWD=%s\n' "$MYSQL_ROOT_PASSWORD" >"$mysql_env"
chmod 600 "$mysql_env"
network="${COMPOSE_PROJECT_NAME}_pms-data"
image="${PMS_MYSQL_TOOL_IMAGE:-mysql:8.4}"
docker run --rm --env-file "$mysql_env" --network "$network" "$image" mysqldump --protocol=tcp -hmysql -P3306 -uroot --single-transaction --routines --column-statistics=0 pms >"$work_dir/database.sql"
gzip -n -f "$work_dir/database.sql"
docker run --rm -v "$uploads_volume":/source:ro -v "$work_dir":/backup busybox:1.36.1-musl tar czf /backup/uploads.tar.gz -C /source .
cat >"$work_dir/metadata.env" <<EOF
PMS_BACKUP_FORMAT=1
PMS_BACKUP_CREATED_AT=$timestamp
PMS_BACKUP_VERSION=$PMS_VERSION
PMS_BACKUP_DATABASE=pms
PMS_BACKUP_UPLOADS_VOLUME=$uploads_volume
EOF
(cd "$work_dir" && sha256 database.sql.gz uploads.tar.gz metadata.env >SHA256SUMS)
tar -C "$work_dir" -czf "$archive_path" metadata.env database.sql.gz uploads.tar.gz SHA256SUMS
(cd "$BACKUP_DIR" && sha256 "$archive_name" >"$(basename "$checksum_path")")
echo "backup created: $archive_path"
echo "checksum created: $checksum_path"
