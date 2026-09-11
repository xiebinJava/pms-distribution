#!/usr/bin/env bash
# Confirm the release images are anonymously readable from GHCR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/.env.example}"

read_env() {
  awk -F= -v key="$1" '$1 == key { print $2; exit }' "$ENV_FILE"
}

version="${PMS_VERSION:-$(read_env PMS_VERSION)}"
backend_image="${PMS_BACKEND_IMAGE:-$(read_env PMS_BACKEND_IMAGE)}"
frontend_image="${PMS_FRONTEND_IMAGE:-$(read_env PMS_FRONTEND_IMAGE)}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "PMS_VERSION must be MAJOR.MINOR.PATCH, got: ${version:-<empty>}" >&2
  exit 1
fi

require_command() { command -v "$1" >/dev/null 2>&1 || { echo "$1 is required" >&2; exit 2; }; }
require_command curl
require_command python3

anonymous_manifest() {
  local image="$1"
  local repo="${image#ghcr.io/}"
  local token code
  token="$(curl -fsS "https://ghcr.io/token?service=ghcr.io&scope=repository:${repo}:pull" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))')"
  if [[ -z "$token" ]]; then
    echo "anonymous GHCR token was empty for ${image}:${version}" >&2
    exit 1
  fi
  code="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://ghcr.io/v2/${repo}/manifests/${version}")"
  if [[ "$code" != "200" ]]; then
    echo "anonymous GHCR pull failed: ${image}:${version} (HTTP ${code})" >&2
    echo "Publish the versioned image from the source repository and set the GHCR package visibility to Public." >&2
    exit 1
  fi
  echo "ok ${image}:${version}"
}

anonymous_manifest "$backend_image"
anonymous_manifest "$frontend_image"
echo "GHCR images are anonymously readable"
