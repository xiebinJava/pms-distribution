#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v ruby >/dev/null 2>&1 || { echo "ruby is required" >&2; exit 2; }

ruby -ryaml -e '
validate = YAML.load_file(ARGV[0])
abort "validate triggers" unless validate["on"] || validate[true]
steps = validate.dig("jobs", "validate", "steps").map { |s| s["run"] }.compact.join("\n")
%w[
  test-distribution-contract.sh
  test-compose-config.sh
  test-operations-safety.sh
  check-privacy.sh
].each { |name| abort "validate missing #{name}" unless steps.include?(name) }

release = YAML.load_file(ARGV[1])
on = release["on"] || release[true]
abort "release tag trigger" unless on.dig("push", "tags") == ["v*.*.*"]
abort "release permissions" unless release.dig("permissions", "contents") == "write"
release_steps = release.dig("jobs", "validate", "steps").map { |s| s["run"].to_s }.join("\n")
abort "release missing GHCR verification" unless release_steps.include?("verify-ghcr-images.sh")
abort "release missing version pin" unless release_steps.include?("PMS_VERSION")
puts "Distribution workflow contracts passed"
' "$ROOT/.github/workflows/validate.yml" "$ROOT/.github/workflows/release.yml"
