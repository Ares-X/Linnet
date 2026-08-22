#!/bin/bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
baseline_source="${repo_root}/.swiftlint-baseline.json"
runtime_baseline="$(mktemp)"
trap 'rm -f "${runtime_baseline}"' EXIT

# SwiftLint reports the public macOS aliases for these two system paths, while
# Git resolves them to their physical /private locations.
baseline_root="${repo_root}"
case "${baseline_root}" in
  /private/var/*) baseline_root="/var/${baseline_root#/private/var/}" ;;
  /private/tmp/*) baseline_root="/tmp/${baseline_root#/private/tmp/}" ;;
esac

baseline_count="$(awk -F'"violation"' '{ count += NF - 1 } END { print count + 0 }' "${baseline_source}")"
if (( baseline_count > 131 )); then
  echo "SwiftLint baseline grew from its reviewed maximum of 131 violations." >&2
  exit 1
fi

if ! grep -q '__LINNET_ROOT__' "${baseline_source}"; then
  echo "SwiftLint baseline is missing its relocatable root marker." >&2
  exit 1
fi

LINNET_BASELINE_ROOT="${baseline_root}" perl -0pe '
  BEGIN {
    $root = $ENV{"LINNET_BASELINE_ROOT"};
    $root =~ s{/}{\\/}g;
  }
  s{__LINNET_ROOT__}{$root}g;
' "${baseline_source}" >"${runtime_baseline}"

cd "${repo_root}"
swiftlint lint --quiet --baseline "${runtime_baseline}"
