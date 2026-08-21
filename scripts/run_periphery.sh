#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${project_root}"

readonly baseline_path=".periphery-baseline.json"
readonly maximum_baseline_entries=72

baseline_entries="$(
  ruby -rjson -e '
    baseline = JSON.parse(File.read(ARGV.fetch(0)))
    puts baseline.fetch("v1").fetch("usrs").length
  ' "${baseline_path}"
)"

if (( baseline_entries > maximum_baseline_entries )); then
  echo "Periphery baseline grew from ${maximum_baseline_entries} to ${baseline_entries}." >&2
  echo "Fix new findings instead of accepting them into the baseline." >&2
  exit 1
fi

periphery scan \
  --relative-results \
  --strict \
  --baseline "${baseline_path}"
