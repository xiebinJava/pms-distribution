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
printf 'effective image version: %s command: %s\n' "${PMS_VERSION:-unset}" "$*" >>"$DOCKER_CALLS"
if [[ "$*" == *" config" && "${FAKE_CONFIG_FAIL:-}" == 1 ]]; then exit 1; fi
if [[ "$*" == *" up -d" && -n "${CHECK_ADMIN_FILE:-}" ]]; then
  [[ "$PMS_BOOTSTRAP_ADMIN_PASSWORD" == "$(<"$CHECK_ADMIN_FILE")" ]] || exit 2
fi
if [[ "$*" == "compose version" ]]; then
  exit 0
fi
if [[ "$*" == *" ps -q"* ]]; then
  service="${!#}"
  case "$service" in mysql) [[ -n "${FAKE_MYSQL_ID:-}" ]] && printf '%s\n' "$FAKE_MYSQL_ID";; backend) [[ ! -f "$FAKE_PHASE" || $(<"$FAKE_PHASE") == rollback ]] && echo old-backend || echo new-backend;; frontend) [[ -f "$FAKE_PHASE" && $(<"$FAKE_PHASE") == rollback ]] && echo old-frontend || echo new-frontend;; esac
  exit 0
fi
if [[ "$1" == "inspect" && "$*" == *".Mounts"* ]]; then
  printf '%s\n' "${FAKE_UPLOADS_MOUNT:-${PMS_UPLOADS_VOLUME:-}}"
  exit 0
fi
if [[ "$1" == "inspect" ]]; then
  if [[ "${FAKE_UPGRADE_SUCCESS:-}" == 1 ]]; then echo healthy; else [[ "$*" == *new-* ]] && echo unhealthy || echo healthy; fi
  exit 0
fi
if [[ "$1 $2" == "volume create" ]]; then printf '%s\n' "${!#}" >>"$FAKE_WORK_DIR/created-volumes"; exit 0; fi
if [[ "$1 $2" == "volume inspect" && ( "$*" == *restore* || "$*" == *rollback* ) ]]; then
  grep -Fxq "$3" "$FAKE_WORK_DIR/created-volumes" 2>/dev/null
  exit $?
fi
if [[ "$1 $2" == "run --rm" && "$*" == *mysqldump* ]]; then echo 'SELECT 1;'; exit 0; fi
if [[ "$*" == "run --rm -i"* && "$*" == *"mysql:8.4"* && "$*" != *mysqldump* ]]; then
  cat >/dev/null
  [[ "${FAKE_RESTORE_FAIL:-}" != 1 ]]
  exit $?
fi
if [[ "$1 $2" == "run --rm" && "$*" == *busybox* && "$*" == *tar* ]]; then for arg in "$@"; do case "$arg" in *:/backup) tar -czf "${arg%:/backup}/uploads.tar.gz" --files-from /dev/null;; esac; done; exit 0; fi
if [[ "$1" == "exec" && "$*" == *old-backend* ]]; then [[ "${FAKE_PREVIOUS_UNREADY:-}" != 1 ]] || exit 1; echo '{"status":"UP"}'; exit 0; fi
if [[ "$1" == "exec" && "$*" == *new-backend* && "${FAKE_UPGRADE_SUCCESS:-}" == 1 ]]; then echo '{"status":"UP"}'; exit 0; fi
if [[ "$1 $2" == "compose --project-name" && "$*" == *" up -d"* ]]; then
  if [[ "${PMS_VERSION:-}" == "1.0.0" ]]; then echo rollback >"$FAKE_PHASE"; else echo new >"$FAKE_PHASE"; fi
  exit 0
fi
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
cp "$ENV_FILE" "$WORK_DIR/first-upgrade.env"
ENV_FILE="$WORK_DIR/first-upgrade.env" FAKE_MYSQL_ID=fake-mysql COMPOSE_PROJECT_NAME=pms-staging BACKUP_DIR="$WORK_DIR/backups" \
  "$ROOT/scripts/upgrade.sh" 1.0.1 >/dev/null 2>&1 || true
grep -Fq -- "--project-name pms-staging --env-file $WORK_DIR/first-upgrade.env -f $COMPOSE_FILE ps -q mysql" "$DOCKER_CALLS" || {
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
# Model a migrated database and an installation with a manual restore target.
printf 'RESTORE_UPLOADS_VOLUME=operator-manual-restore\n' >>"$ENV_FILE"
: >"$DOCKER_CALLS"
rm -f "$FAKE_PHASE"
if FAKE_MYSQL_ID=fake-mysql COMPOSE_PROJECT_NAME=pms-upgrade BACKUP_DIR="$WORK_DIR/upgrade-backups" \
    "$ROOT/scripts/upgrade.sh" 1.0.1 >"$WORK_DIR/failed-upgrade.log" 2>&1; then
  fail "failed candidate must leave a nonzero upgrade exit code"
fi
grep -Fq -- 'rollback verified' "$WORK_DIR/failed-upgrade.log" || fail "upgrade rollback did not verify old backend readiness: $(<"$WORK_DIR/failed-upgrade.log")"
grep -qx 'PMS_VERSION=1.0.0' "$ENV_FILE" || fail "rollback did not restore the previous version"
grep -q '^MYSQL_DB=pmsrollback' "$ENV_FILE" || fail "rollback did not point to the restored database"
grep -q '^PMS_UPLOADS_VOLUME=pms-upgrade_pms-uploads-rollback-' "$ENV_FILE" || fail "rollback did not point to the restored uploads"
rollback_volume="$(sed -n 's/^PMS_UPLOADS_VOLUME=//p' "$ENV_FILE")"
grep -Fq -- "-v $rollback_volume:/target" "$DOCKER_CALLS" || fail "rollback did not extract attachments into the mounted volume"
if grep -Fq -- '-v operator-manual-restore:/target' "$DOCKER_CALLS"; then
  fail "configuration for manual restores overrode the rollback volume"
fi
grep -Fq -- 'old-backend sh -c test -r /var/lib/pms/uploads' "$DOCKER_CALLS" || fail "missing rolled-back attachment readability check"
grep -Fq -- 'GRANT ALL ON' "$DOCKER_CALLS" || fail "application user cannot access the restored database"
grep -Fq -- 'old-backend curl' "$DOCKER_CALLS" || fail "upgrade rollback did not verify old backend readiness"
grep -Fq -- "effective image version: 1.0.0 command: compose --project-name pms-upgrade --env-file $ENV_FILE -f $COMPOSE_FILE up -d --no-deps --force-recreate backend" "$DOCKER_CALLS" || fail "rollback did not restore the exported image version"
grep -Fq -- 'stop frontend backend' "$DOCKER_CALLS" || fail "rollback did not stop application writers"

# Do not start the frontend if the backend mounted a different volume.
cp "$ENV_FILE" "$WORK_DIR/wrong-mount.env"
: >"$DOCKER_CALLS"
rm -f "$FAKE_PHASE"
assert_refuses 'mounted wrong-volume' env ENV_FILE="$WORK_DIR/wrong-mount.env" \
  FAKE_MYSQL_ID=fake-mysql FAKE_UPLOADS_MOUNT=wrong-volume BACKUP_DIR="$WORK_DIR/wrong-mount-backups" \
  "$ROOT/scripts/upgrade.sh" 1.0.1
if grep -F 'effective image version: 1.0.0 command: compose' "$DOCKER_CALLS" | grep -Fq 'up -d --no-deps --force-recreate frontend'; then
  fail "rollback opened the frontend with the wrong attachment volume"
fi

# A failed restore must leave the application stopped on the original configuration.
cp "$ENV_FILE" "$WORK_DIR/failed-restore.env"
: >"$DOCKER_CALLS"
rm -f "$FAKE_PHASE"
assert_refuses "could not prepare the pre-upgrade snapshot" env ENV_FILE="$WORK_DIR/failed-restore.env" \
  FAKE_MYSQL_ID=fake-mysql FAKE_RESTORE_FAIL=1 BACKUP_DIR="$WORK_DIR/failing-restore" "$ROOT/scripts/upgrade.sh" 1.0.1
cmp -s "$ENV_FILE" "$WORK_DIR/failed-restore.env" || fail "failed restore configured a partial database"
if grep -Fq "effective image version: 1.0.0 command: compose" "$DOCKER_CALLS" \
    && grep -F 'effective image version: 1.0.0 command: compose' "$DOCKER_CALLS" | grep -Fq 'up -d'; then
  fail "failed restore started the old app"
fi

pending="$WORK_DIR/failed-restore.env.upgrade-recovery"
[[ -d "$pending" ]] || fail "failed restore discarded its recovery state"
original_archive="$(sed -n '2p' "$pending/details")"
[[ -f "$original_archive" && -f "$original_archive.sha256" ]] || fail "recovery record lacks its original snapshot"
: >"$DOCKER_CALLS"
assert_refuses "pending recovery belongs to Compose project" env ENV_FILE="$WORK_DIR/failed-restore.env" \
  COMPOSE_PROJECT_NAME=other-install FAKE_MYSQL_ID=fake-mysql "$ROOT/scripts/upgrade.sh" 1.0.1
[[ -d "$pending" ]] || fail "wrong project cleared pending recovery"
if grep -Eq 'stop frontend backend|mysqldump| up -d' "$DOCKER_CALLS"; then
  fail "wrong project took action on the recovery"
fi
: >"$DOCKER_CALLS"
second_attempt="$(env ENV_FILE="$WORK_DIR/failed-restore.env" FAKE_MYSQL_ID=fake-mysql \
  BACKUP_DIR="$WORK_DIR/failing-restore" "$ROOT/scripts/upgrade.sh" 1.0.1 2>&1)" \
  && fail "resuming rollback returned success for an upgrade it did not run"
[[ "$second_attempt" == *"resuming rollback from original backup: $original_archive"* \
    && "$second_attempt" == *"previous version recovered"* ]] || fail "failed restore did not resume: $second_attempt"
[[ ! -e "$pending" ]] || fail "a verified rollback left a recovery record"
if grep -Eq 'mysqldump|pull mysql backend frontend' "$DOCKER_CALLS"; then
  fail "rollback retry started a new upgrade or took a new snapshot"
fi

# A first attempt must not snapshot a database served by an unready old backend.
: >"$DOCKER_CALLS"
rm -f "$FAKE_PHASE"
assert_refuses 'current backend must be ready' env FAKE_MYSQL_ID=fake-mysql FAKE_PREVIOUS_UNREADY=1 \
  "$ROOT/scripts/upgrade.sh" 1.0.1
if grep -Eq 'stop frontend backend|mysqldump|pull mysql backend frontend' "$DOCKER_CALLS"; then
  fail "an unready installation was modified"
fi

# Compose prefers exported variables over --env-file: upgrade must switch both.
: >"$DOCKER_CALLS"
rm -f "$FAKE_PHASE"
FAKE_UPGRADE_SUCCESS=1 FAKE_MYSQL_ID=fake-mysql COMPOSE_PROJECT_NAME=pms-upgrade BACKUP_DIR="$WORK_DIR/success-backups" "$ROOT/scripts/upgrade.sh" 1.0.1 >/dev/null
grep -qx 'PMS_VERSION=1.0.1' "$ENV_FILE" || fail "successful upgrade did not save the target version"
grep -Fq -- "effective image version: 1.0.1 command: compose --project-name pms-upgrade --env-file $ENV_FILE -f $COMPOSE_FILE pull" "$DOCKER_CALLS" || fail "upgrade pulled the old image because exported PMS_VERSION overrode --env-file"
grep -Fq -- "effective image version: 1.0.1 command: compose --project-name pms-upgrade --env-file $ENV_FILE -f $COMPOSE_FILE up -d --no-deps --force-recreate backend" "$DOCKER_CALLS" || fail "upgrade recreated services with the wrong image version"

# Bootstrap runs in a disposable copy and must select that repository name.
printf 'rollback\n' >"$FAKE_PHASE"
fixture="$WORK_DIR/bootstrap-fixture"
mkdir -p "$fixture/scripts"
cp "$ROOT/scripts/bootstrap.sh" "$ROOT/scripts/compose-project-name.sh" "$ROOT/scripts/docker-resources.sh" "$fixture/scripts/"
cp "$ROOT/.env.example" "$fixture/.env"
sed -i.bak 's/^PMS_PORT=.*/PMS_PORT=59999/' "$fixture/.env" && rm -f "$fixture/.env.bak"
printf 'PMS_PORT=59999\n' >>"$fixture/.env"
: >"$DOCKER_CALLS"
FAKE_MYSQL_ID=fake-frontend env -u ENV_FILE -u COMPOSE_PROJECT_NAME "$fixture/scripts/bootstrap.sh" >/dev/null
grep -Fq -- '--project-name bootstrap-fixture' "$DOCKER_CALLS" || fail "bootstrap did not use repository basename as project name"
bootstrap_fixture() {
  local dir="$1"; shift
  mkdir -p "$dir"
  CHECK_ADMIN_FILE="$dir/.pms-bootstrap-admin-password" ENV_FILE="$dir/.env"     "$@" "$fixture/scripts/bootstrap.sh" >"$dir/console" 2>&1
}
cp "$ROOT/.env.example" "$fixture/.env.example"
isolated="$WORK_DIR/isolated"
if bootstrap_fixture "$isolated" env FAKE_CONFIG_FAIL=1; then fail "expected simulated interruption"; fi
initial="$(<"$isolated/.pms-bootstrap-admin-password")"
bootstrap_fixture "$isolated" env
[[ "$initial" == "$(<"$isolated/.pms-bootstrap-admin-password")" ]] || fail "credential changed on retry"
second="$WORK_DIR/second"
bootstrap_fixture "$second" env
[[ "$initial" != "$(<"$second/.pms-bootstrap-admin-password")" ]] || fail "installations shared a credential"
explicit="$WORK_DIR/explicit"
custom="Private fixture $""!# & test"
bootstrap_fixture "$explicit" env PMS_BOOTSTRAP_ADMIN_PASSWORD="$custom"
[[ "$custom" == "$(<"$explicit/.pms-bootstrap-admin-password")" ]] || fail "explicit credential changed"
staging="$isolated/.env.staging"
CHECK_ADMIN_FILE="$staging.pms-bootstrap-admin-password" ENV_FILE="$staging" COMPOSE_PROJECT_NAME=staging   "$fixture/scripts/bootstrap.sh" >"$isolated/staging-console" 2>&1
staged="$(<"$staging.pms-bootstrap-admin-password")"
[[ "$staged" != "$initial" ]] || fail "sibling env files shared the admin credential"
if cmp -s "$staging.pms-bootstrap-secrets" "$isolated/.pms-bootstrap-secrets"; then fail "sibling environments shared infrastructure credentials"; fi
CHECK_ADMIN_FILE="$staging.pms-bootstrap-admin-password" ENV_FILE="$staging" COMPOSE_PROJECT_NAME=staging   "$fixture/scripts/bootstrap.sh" >>"$isolated/staging-console" 2>&1
[[ "$staged" == "$(<"$staging.pms-bootstrap-admin-password")" ]] || fail "staging credential changed on retry"
for dir in "$isolated" "$second" "$explicit"; do
  for path in "$dir/.env" "$dir/.pms-bootstrap-admin-password" "$dir/.pms-bootstrap-secrets"; do
    [[ "$(LC_ALL=C ls -ld "$path" | cut -c2-10)" == "rw-------" ]] || fail "secret file mode must be 0600"
  done
  if grep -Fq -- "$(<"$dir/.pms-bootstrap-admin-password")" "$dir/console"; then fail "credential appeared in log"; fi
done
rm "$isolated/.pms-bootstrap-admin-password"
ENV_FILE="$isolated/.env" "$fixture/scripts/bootstrap.sh" >"$isolated/after-disposal" 2>&1
[[ ! -e "$isolated/.pms-bootstrap-admin-password" ]] || fail "disposed credential was recreated"
real_openssl="$(command -v openssl)"
cat >"$WORK_DIR/bin/openssl" <<'EOF'
#!/usr/bin/env bash
if [[ "${FAIL_ENTROPY:-}" == 1 ]]; then exit 1; fi
exec "$REAL_OPENSSL" "$@"
EOF
chmod +x "$WORK_DIR/bin/openssl"
entropy="$WORK_DIR/entropy"
if bootstrap_fixture "$entropy" env FAIL_ENTROPY=1 REAL_OPENSSL="$real_openssl"; then fail "expected failed secret generation"; fi
grep -Fq "could not generate an installation secret" "$entropy/console" || fail "missing entropy failure diagnostic"
[[ ! -e "$entropy/.pms-bootstrap-secrets" ]] || fail "failed secret generation published an incomplete file"
bootstrap_fixture "$entropy" env REAL_OPENSSL="$real_openssl"
[[ -s "$entropy/.pms-bootstrap-admin-password" ]] || fail "bootstrap could not recover after entropy returned"
echo "Operation safety checks passed"
