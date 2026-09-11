#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PMS_MIN_DOCKER_MEMORY_GIB=10

# shellcheck disable=SC1091
source "$ROOT/scripts/docker-resources.sh"

minimum_bytes=$((10 * 1024 * 1024 * 1024))

if check_docker_memory_limit $((minimum_bytes - 1)) >/dev/null 2>&1; then
  echo "memory below the minimum was accepted" >&2
  exit 1
fi

check_docker_memory_limit "$minimum_bytes" >/dev/null
check_docker_memory_limit 0 >/dev/null

if check_docker_memory_limit 9 >/dev/null 2>&1; then
  echo "a non-byte value was accepted as Docker memory" >&2
  exit 1
fi

if PMS_MIN_DOCKER_MEMORY_GIB=invalid check_docker_memory_limit "$minimum_bytes" >/dev/null 2>&1; then
  echo "an invalid minimum memory setting was accepted" >&2
  exit 1
fi

if PMS_MIN_DOCKER_MEMORY_GIB=09 ! check_docker_memory_limit $((9 * 1024 * 1024 * 1024)) >/dev/null 2>&1; then
  echo "a leading-zero memory threshold was not parsed as decimal" >&2
  exit 1
fi

if PMS_MIN_DOCKER_MEMORY_GIB=18446744073709551617 check_docker_memory_limit "$minimum_bytes" >/dev/null 2>&1; then
  echo "an overflowing memory threshold was accepted" >&2
  exit 1
fi

echo "Docker resource checks passed"
