#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT/compose.yaml}"
# shellcheck disable=SC1091
source "$ROOT/scripts/compose-project-name.sh"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(default_compose_project_name "$ROOT")}"
die() { echo "restore error: $*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
sha256_check() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -c "$1"; else shasum -a 256 -c "$1"; fi; }
require_sha256() { command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || die "sha256sum or shasum is required"; }
compose() { docker compose --project-name "$COMPOSE_PROJECT_NAME" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }
[[ "${RESTORE_CONFIRM:-}" == "YES" ]] || die "set RESTORE_CONFIRM=YES to confirm an isolated restore"
[[ $# -eq 1 ]] || die "usage: RESTORE_CONFIRM=YES $0 <backup.tar.gz>"
archive_path="$1"
checksum_path="${archive_path}.sha256"
[[ -f "$archive_path" ]] || die "backup archive does not exist: $archive_path"
[[ -f "$checksum_path" ]] || die "backup checksum does not exist: $checksum_path"
require_command tar
require_sha256
(cd "$(dirname "$archive_path")" && sha256_check "$(basename "$checksum_path")") >/dev/null || die "backup checksum verification failed"
members="$(tar -tzf "$archive_path")" || die "backup archive is malformed"
expected_members=$'metadata.env\ndatabase.sql.gz\nuploads.tar.gz\nSHA256SUMS'
[[ "$members" == "$expected_members" ]] || die "backup archive has unexpected members"
# Keep the work directory under the repository so Colima/Lima can bind-mount it.
mkdir -p "${BACKUP_DIR:-$ROOT/backups}"
work_dir="$(mktemp -d "${BACKUP_DIR:-$ROOT/backups}/.work.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
tar -xzf "$archive_path" -C "$work_dir"
(cd "$work_dir" && sha256_check SHA256SUMS) >/dev/null || die "backup member checksum verification failed"
uploads_members="$(tar -tzf "$work_dir/uploads.tar.gz")" || die "uploads archive is malformed"
while IFS= read -r member; do
  [[ "$member" != /* && "$member" != ".." && "$member" != *"../"* ]] || die "uploads archive contains an unsafe path"
done <<<"$uploads_members"
backup_format="$(sed -n 's/^PMS_BACKUP_FORMAT=//p' "$work_dir/metadata.env")"
backup_database="$(sed -n 's/^PMS_BACKUP_DATABASE=//p' "$work_dir/metadata.env")"
[[ "$backup_format" == "1" && "$backup_database" == "pms" ]] || die "backup metadata is unsupported"
[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE; run ./scripts/bootstrap.sh first"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
[[ "${PMS_DEPLOYMENT_ENV:-development}" != "production" ]] || die "refusing restore from a production configuration; use an isolated non-production clone"
[[ -n "${PMS_VERSION:-}" ]] || die "PMS_VERSION must be set"
[[ -n "${MYSQL_ROOT_PASSWORD:-}" ]] || die "MySQL root password must be set"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
restore_database="${RESTORE_DATABASE:-pms_restore_$timestamp}"
current_uploads_volume="${COMPOSE_PROJECT_NAME}_pms-uploads"
restore_uploads_volume="${RESTORE_UPLOADS_VOLUME:-${COMPOSE_PROJECT_NAME}_pms-uploads-restore-$timestamp}"
[[ "$restore_database" =~ ^[A-Za-z0-9_]+$ ]] || die "RESTORE_DATABASE contains unsafe characters"
[[ "$restore_database" != "pms" ]] || die "refusing to overwrite pms"
[[ "$restore_uploads_volume" != "$current_uploads_volume" ]] || die "refusing to overwrite current pms-uploads volume"
require_command docker
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"
mysql_id="$(compose ps -q mysql 2>/dev/null || true)"
[[ -n "$mysql_id" ]] || die "mysql is not running"
mysql_health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' "$mysql_id" 2>/dev/null || true)"
[[ "$mysql_health" == "healthy" ]] || die "mysql is not healthy"
network="${COMPOSE_PROJECT_NAME}_pms-data"
docker network inspect "$network" >/dev/null 2>&1 || die "network $network does not exist"
image="${PMS_MYSQL_TOOL_IMAGE:-mysql:8.4}"
docker image inspect "$image" >/dev/null 2>&1 || die "required MySQL tool image is not available locally"
if docker volume inspect "$restore_uploads_volume" >/dev/null 2>&1; then die "restore uploads volume already exists: $restore_uploads_volume"; fi
if docker exec "$mysql_id" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -h127.0.0.1 -P3306 -uroot -Nse "$1"' sh "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$restore_database'" | grep -qx "$restore_database"; then die "restore database already exists: $restore_database"; fi
mysql_env="$work_dir/mysql.env"
umask 077
printf 'MYSQL_PWD=%s\n' "$MYSQL_ROOT_PASSWORD" >"$mysql_env"
chmod 600 "$mysql_env"
docker run --rm --env-file "$mysql_env" --network "$network" "$image" mysql --protocol=tcp -hmysql -P3306 -uroot -e "CREATE DATABASE \`$restore_database\`"
gunzip -c "$work_dir/database.sql.gz" | docker run --rm -i --env-file "$mysql_env" --network "$network" "$image" mysql --protocol=tcp -hmysql -P3306 -uroot "$restore_database"
docker volume create "$restore_uploads_volume" >/dev/null
docker run --rm -v "$restore_uploads_volume":/target -v "$work_dir":/backup:ro busybox:1.36.1-musl sh -c 'tar xzf /backup/uploads.tar.gz -C /target'
echo "restore complete in isolated targets: database=$restore_database uploads_volume=$restore_uploads_volume"
