#!/bin/bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

# Linnet carries no lint-debt allowlist. Warnings are errors so a new warning
# cannot silently become tomorrow's baseline.
if [[ -e .swiftlint-baseline.json ]]; then
  echo "SwiftLint debt baselines are not allowed." >&2
  exit 1
fi
cache_path="${repo_root}/build/swiftlint-cache"
mkdir -p "${cache_path}"
swiftlint lint --quiet --config .swiftlint.yml --cache-path "${cache_path}"
