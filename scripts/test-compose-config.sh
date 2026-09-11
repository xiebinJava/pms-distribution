#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Host-exported Compose variables would otherwise override .env.example.
unset PMS_PORT PMS_CORS_ALLOWED_ORIGINS PMS_PUBLIC_BASE_URL PMS_VERSION \
  PMS_FRONTEND_IMAGE PMS_BACKEND_IMAGE MYSQL_ROOT_PASSWORD MYSQL_PASSWORD MYSQL_USER MYSQL_DB

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 2; }
docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 is required" >&2; exit 2; }

rendered="$(docker compose --env-file "$ROOT/.env.example" -f "$ROOT/compose.yaml" config)"
version="$(awk -F= '$1 == "PMS_VERSION" { print $2; exit }' "$ROOT/.env.example")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "PMS_VERSION in .env.example must be a semantic version" >&2
  exit 1
}
for service in mysql uploads-init backend frontend; do
  grep -q "^  ${service}:" <<<"$rendered" || {
    echo "missing Compose service: $service" >&2
    exit 1
  }
done

grep -q "ghcr.io/xiebinjava/pms-backend:${version}" <<<"$rendered" || {
  echo "Compose does not render the version-matched backend image" >&2
  exit 1
}
grep -q "ghcr.io/xiebinjava/pms-front:${version}" <<<"$rendered" || {
  echo "Compose does not render the version-matched frontend image" >&2
  exit 1
}
grep -q "image: mysql:8.4" <<<"$rendered" || {
  echo "Compose does not use MySQL 8.4" >&2
  exit 1
}
grep -q 'published: "5173"' <<<"$rendered" || {
  echo "Compose does not publish the frontend entry port" >&2
  exit 1
}
if grep -qE '3306:3306|8080:8080' <<<"$rendered"; then
  echo "database or backend port is exposed to the host" >&2
  exit 1
fi
if grep -q ':latest' <<<"$rendered"; then
  echo "rendered Compose contains latest tag" >&2
  exit 1
fi
if grep -qiE 'oceanbase|accounts-init|schema-init|pms-migrator' <<<"$rendered"; then
  echo "rendered Compose still references OceanBase or the migrator image" >&2
  exit 1
fi

echo "Compose configuration passed"
