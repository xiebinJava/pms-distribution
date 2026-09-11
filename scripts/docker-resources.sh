#!/usr/bin/env bash

check_docker_memory_limit() {
  local total_bytes="${1:-0}"
  local minimum_gib="${PMS_MIN_DOCKER_MEMORY_GIB:-2}"

  if ! [[ "$total_bytes" =~ ^[0-9]+$ ]]; then
    echo "unable to determine Docker memory allocation; continuing without a hard check" >&2
    return 0
  fi

  if (( total_bytes == 0 )); then
    echo "Docker did not report a memory allocation; continuing without a hard check" >&2
    return 0
  fi

  if ! [[ "$minimum_gib" =~ ^[0-9]+$ ]]; then
    echo "PMS_MIN_DOCKER_MEMORY_GIB must be a positive integer" >&2
    return 1
  fi

  local minimum_gib_normalized="${minimum_gib#${minimum_gib%%[!0]*}}"
  if [[ -z "$minimum_gib_normalized" ]]; then
    echo "PMS_MIN_DOCKER_MEMORY_GIB must be a positive integer" >&2
    return 1
  fi

  # Keep the conversion below inside Bash's signed 64-bit arithmetic range.
  if (( ${#minimum_gib_normalized} > 10 )) || {
    (( ${#minimum_gib_normalized} == 10 )) && [[ "$minimum_gib_normalized" > "8589934591" ]]
  }; then
    echo "PMS_MIN_DOCKER_MEMORY_GIB is too large" >&2
    return 1
  fi

  local minimum_gib_decimal=$((10#$minimum_gib_normalized))
  if (( minimum_gib_decimal < 1 )); then
    echo "PMS_MIN_DOCKER_MEMORY_GIB must be a positive integer" >&2
    return 1
  fi

  local minimum_bytes=$((minimum_gib_decimal * 1024 * 1024 * 1024))
  if (( total_bytes < minimum_bytes )); then
    local total_mib=$((total_bytes / 1024 / 1024))
    echo "Docker has ${total_mib} MiB allocated; PMS requires at least ${minimum_gib_decimal} GiB for MySQL, the API, and the frontend. Increase the Docker daemon or VM memory allocation and retry." >&2
    return 1
  fi

  echo "Docker memory allocation is sufficient: $((total_bytes / 1024 / 1024)) MiB (minimum ${minimum_gib_decimal} GiB)"
}
