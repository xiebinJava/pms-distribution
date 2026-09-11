#!/usr/bin/env bash

default_compose_project_name() {
  local root_path="$1"
  local raw_name normalized_name

  raw_name="$(basename "$root_path" | tr '[:upper:]' '[:lower:]')"
  normalized_name="$(sed 's/[^a-z0-9_-]/-/g; s/^[^a-z0-9]*//; s/-*$//; s/_*$//' <<<"$raw_name")"
  printf '%s\n' "${normalized_name:-pms-distribution}"
}
