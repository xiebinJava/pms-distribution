#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pms-operations-test.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() { echo "test failure: $*" >&2; exit 1; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
assert_refuses() {
  local expected="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    fail "command unexpectedly succeeded: $*"
  fi
  [[ "$output" == *"$expected"* ]] || fail "expected '$expected', got: $output"
}

mkdir -p "$WORK_DIR/bin"
cat >"$WORK_DIR/.env" <<'EOF'
PMS_VERSION=1.0.0
MYSQL_USER=pms
MYSQL_PASSWORD=test-app-password
MYSQL_ROOT_PASSWORD=test-root-password
MYSQL_DB=pms
EOF

cat >"$WORK_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker was invoked: %s\n' "$*" >>"$DOCKER_CALLS"
if [[ "$*" == "compose version" ]]; then
  exit 0
fi
if [[ "$*" == *" ps -q"* ]]; then
  service="${!#}"
  case "$service" in mysql) [[ -n "${FAKE_MYSQL_ID:-}" ]] && printf '%s\n' "$FAKE_MYSQL_ID";; backend) [[ -f "$FAKE_PHASE" && $(<"$FAKE_PHASE") == rollback ]] && echo old-backend || echo new-backend;; frontend) [[ -f "$FAKE_PHASE" && $(<"$FAKE_PHASE") == rollback ]] && echo old-frontend || echo new-frontend;; esac
  exit 0
fi
if [[ "$1" == "inspect" ]]; then
  [[ "$*" == *new-* ]] && echo unhealthy || echo healthy
  exit 0
fi
if [[ "$1 $2" == "volume inspect" && "$*" == *restore* ]]; then exit 1; fi
if [[ "$1 $2" == "run --rm" && "$*" == *mysqldump* ]]; then echo 'SELECT 1;'; exit 0; fi
if [[ "$1 $2" == "run --rm" && "$*" == *busybox* && "$*" == *tar* ]]; then for arg in "$@"; do case "$arg" in *:/backup) tar -czf "${arg%:/backup}/uploads.tar.gz" --files-from /dev/null;; esac; done; exit 0; fi
if [[ "$1" == "exec" && "$*" == *old-backend* ]]; then echo '{"status":"UP"}'; exit 0; fi
if [[ "$1 $2" == "compose --project-name" && "$*" == *" up -d"* ]]; then n=$(($(cat "$FAKE_PHASE.count" 2>/dev/null || echo 0)+1)); echo "$n" >"$FAKE_PHASE.count"; [[ "$n" -gt 1 ]] && echo rollback >"$FAKE_PHASE" || echo new >"$FAKE_PHASE"; exit 0; fi
exit 0
EOF
chmod +x "$WORK_DIR/bin/docker"
printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK_DIR/bin/sleep"
chmod +x "$WORK_DIR/bin/sleep"

export PATH="$WORK_DIR/bin:$PATH"
export ENV_FILE="$WORK_DIR/.env"
export COMPOSE_FILE="$ROOT/compose.yaml"
export DOCKER_CALLS="$WORK_DIR/docker-calls"
export FAKE_WORK_DIR="$WORK_DIR"
export FAKE_PHASE="$WORK_DIR/phase"

source "$ROOT/scripts/compose-project-name.sh"
[[ "$(default_compose_project_name "/tmp/pms-fresh-install.LFktGS")" == "pms-fresh-install-lfktgs" ]] || {
  fail "repository directory names must be normalized to valid Compose project names"
}

assert_project_name() {
  local expected="$1"
  shift
  : >"$DOCKER_CALLS"
  "$@" >/dev/null 2>&1 || fail "command failed: $*"
  grep -Fq -- "--project-name $expected" "$DOCKER_CALLS" || {
    fail "expected Compose project name $expected, got: $(<"$DOCKER_CALLS")"
  }
}

# Scripts must share the repository-basename default and honor an override.
unset COMPOSE_PROJECT_NAME
expected_project_name="$(default_compose_project_name "$ROOT")"
assert_project_name "$expected_project_name" "$ROOT/scripts/status.sh"
assert_project_name "$expected_project_name" "$ROOT/scripts/logs.sh" backend
COMPOSE_PROJECT_NAME=pms-staging assert_project_name "pms-staging" "$ROOT/scripts/status.sh"
export COMPOSE_PROJECT_NAME="pms-safety-test"
: >"$DOCKER_CALLS"

# A missing confirmation must be rejected before Docker is invoked.
assert_refuses "RESTORE_CONFIRM=YES" "$ROOT/scripts/restore.sh" "$WORK_DIR/missing.tar.gz"
[[ ! -s "$DOCKER_CALLS" ]] || fail "restore invoked Docker before confirmation"

# A missing running stack must prevent backup creation.
assert_refuses "mysql is not running" "$ROOT/scripts/backup.sh"

# Invalid version input must be rejected before backup or Docker operations.
assert_refuses "valid semantic version" "$ROOT/scripts/upgrade.sh" "not-a-version"

# Upgrade must pass a caller-selected Compose project to its backup subprocess.
: >"$DOCKER_CALLS"
FAKE_MYSQL_ID=fake-mysql COMPOSE_PROJECT_NAME=pms-staging BACKUP_DIR="$WORK_DIR/backups" \
  "$ROOT/scripts/upgrade.sh" 1.0.1 >/dev/null 2>&1 || true
grep -Fq -- "--project-name pms-staging --env-file $ENV_FILE -f $COMPOSE_FILE ps -q mysql" "$DOCKER_CALLS" || {
  fail "upgrade did not pass COMPOSE_PROJECT_NAME to backup: $(<"$DOCKER_CALLS")"
}
# Backup uses the selected project's network and uploads volume.
: >"$DOCKER_CALLS"
FAKE_MYSQL_ID=fake-mysql COMPOSE_PROJECT_NAME=pms-staging BACKUP_DIR="$WORK_DIR/backup-output" "$ROOT/scripts/backup.sh" >/dev/null
grep -Fq -- '--network pms-staging_pms-data' "$DOCKER_CALLS" || fail "backup did not use project network"
grep -Fq -- 'pms-staging_pms-uploads:/source:ro' "$DOCKER_CALLS" || fail "backup did not use project uploads volume"
mkdir -p "$WORK_DIR/archive"
printf 'SELECT 1;\n' >"$WORK_DIR/archive/database.sql"
gzip -n -f "$WORK_DIR/archive/database.sql"
tar -C "$WORK_DIR/archive" -czf "$WORK_DIR/archive/uploads.tar.gz" database.sql.gz
printf 'PMS_BACKUP_FORMAT=1\nPMS_BACKUP_DATABASE=pms\n' >"$WORK_DIR/archive/metadata.env"
(cd "$WORK_DIR/archive" && sha256 database.sql.gz uploads.tar.gz metadata.env >SHA256SUMS)
tar -C "$WORK_DIR/archive" -czf "$WORK_DIR/restore.tar.gz" metadata.env database.sql.gz uploads.tar.gz SHA256SUMS
(cd "$WORK_DIR" && sha256 restore.tar.gz >restore.tar.gz.sha256)
: >"$DOCKER_CALLS"
FAKE_MYSQL_ID=fake-mysql RESTORE_CONFIRM=YES COMPOSE_PROJECT_NAME=pms-staging "$ROOT/scripts/restore.sh" "$WORK_DIR/restore.tar.gz" >/dev/null
grep -Fq -- 'CREATE DATABASE `pms_restore_' "$DOCKER_CALLS" || fail "restore did not create isolated database"
grep -Fq -- 'volume create pms-staging_pms-uploads-restore-' "$DOCKER_CALLS" || fail "restore did not create isolated uploads volume"
assert_refuses "refusing to overwrite pms" env RESTORE_CONFIRM=YES RESTORE_DATABASE=pms "$ROOT/scripts/restore.sh" "$WORK_DIR/restore.tar.gz"
assert_refuses "refusing to overwrite current pms-uploads volume" env RESTORE_CONFIRM=YES RESTORE_UPLOADS_VOLUME=pms-staging_pms-uploads COMPOSE_PROJECT_NAME=pms-staging "$ROOT/scripts/restore.sh" "$WORK_DIR/restore.tar.gz"
: >"$DOCKER_CALLS"; rm -f "$FAKE_PHASE" "$FAKE_PHASE.count"
FAKE_MYSQL_ID=fake-mysql COMPOSE_PROJECT_NAME=pms-upgrade BACKUP_DIR="$WORK_DIR/upgrade-backups" "$ROOT/scripts/upgrade.sh" 1.0.1 >/dev/null 2>&1 || true
grep -Fq -- 'old-backend curl' "$DOCKER_CALLS" || fail "upgrade rollback did not verify old backend readiness"
grep -Fq -- 'compose --project-name pms-upgrade' "$DOCKER_CALLS" || fail "upgrade rollback did not recreate selected project"

# Bootstrap runs in a disposable copy and must select that repository name.
fixture="$WORK_DIR/bootstrap-fixture"
mkdir -p "$fixture/scripts"
cp "$ROOT/scripts/bootstrap.sh" "$ROOT/scripts/compose-project-name.sh" "$ROOT/scripts/docker-resources.sh" "$fixture/scripts/"
cp "$ROOT/.env.example" "$fixture/.env"
sed -i.bak 's/^PMS_PORT=.*/PMS_PORT=59999/' "$fixture/.env" && rm -f "$fixture/.env.bak"
printf 'PMS_PORT=59999\n' >>"$fixture/.env"
: >"$DOCKER_CALLS"
FAKE_MYSQL_ID=fake-frontend env -u ENV_FILE -u COMPOSE_PROJECT_NAME "$fixture/scripts/bootstrap.sh" >/dev/null
grep -Fq -- '--project-name bootstrap-fixture' "$DOCKER_CALLS" || fail "bootstrap did not use repository basename as project name"
echo "Operation safety checks passed"
