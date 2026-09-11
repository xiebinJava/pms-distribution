#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required_files=(
  README.md
  LICENSE
  NOTICE
  CHANGELOG.md
  CODE_OF_CONDUCT.md
  CONTRIBUTING.md
  SECURITY.md
  .env.example
  compose.yaml
  scripts/bootstrap.sh
  scripts/docker-resources.sh
  scripts/status.sh
  scripts/logs.sh
  scripts/check-privacy.sh
  scripts/privacy-denylist.txt
  scripts/verify-ghcr-images.sh
  scripts/test-distribution-workflows.sh
  docs/operations/clean-machine-smoke-test.md
  docs/operations/image-attribution.md
  .github/workflows/validate.yml
  .github/workflows/release.yml
  .github/ISSUE_TEMPLATE/install-problem.yml
  .github/ISSUE_TEMPLATE/feature-request.yml
  .github/PULL_REQUEST_TEMPLATE.md
)

for file in "${required_files[@]}"; do
  if [[ ! -s "$ROOT/$file" ]]; then
    echo "missing required distribution file: $file" >&2
    exit 1
  fi
done

required_env=(
  PMS_VERSION
  PMS_FRONTEND_IMAGE
  PMS_BACKEND_IMAGE
  PMS_PORT
  PMS_MIN_DOCKER_MEMORY_GIB
  MYSQL_ROOT_PASSWORD
  MYSQL_USER
  MYSQL_PASSWORD
  MYSQL_DB
  PMS_JWT_SECRET
  PMS_BOOTSTRAP_ADMIN_EMAIL
  PMS_BOOTSTRAP_ADMIN_PASSWORD
  PMS_DEPLOYMENT_ENV
)

for key in "${required_env[@]}"; do
  if ! grep -Eq "^${key}=" "$ROOT/.env.example"; then
    echo "missing .env.example key: $key" >&2
    exit 1
  fi
done

if grep -Eq '^(PMS_MIGRATOR_IMAGE|OCEANBASE_|PMS_APP_PASSWORD|PMS_MIGRATOR_PASSWORD)=' "$ROOT/.env.example"; then
  echo ".env.example still declares OceanBase or migrator credentials" >&2
  exit 1
fi

if [[ -e "$ROOT/compose.oceanbase.yaml" ]]; then
  echo "compose.oceanbase.yaml must be removed" >&2
  exit 1
fi

if grep -RInE --exclude-dir=.git --exclude=.env.example --exclude=test-distribution-contract.sh \
  -e '-----BEGIN [A-Z ]+PRIVATE KEY-----' \
  -e 'AKIA[0-9A-Z]{16}' \
  -e 'gh[pousr]_[A-Za-z0-9]{20,}' \
  -e 'password=[^[:space:]]+@' \
  "$ROOT"; then
  echo "possible credential or private key found in distribution repository" >&2
  exit 1
fi

if grep -RIn --exclude-dir=.git --include='*.yaml' --include='*.yml' ':latest' "$ROOT"; then
  echo "release configuration must not use latest image tags" >&2
  exit 1
fi

echo "distribution contract passed"
