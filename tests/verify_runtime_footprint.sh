#!/usr/bin/env bash

# Narrow structural guard for paths that were deliberately retired. Product
# behavior belongs to Swift, Rime, package-lifecycle, and native UI tests; this
# script must not prescribe helper names, statement order, or source layout.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

fail() {
  echo "verify_runtime_footprint: $*" >&2
  exit 1
}

retired_files=(
  sources/LinnetCandidateAccessibility.swift
  sources/LinnetSettings/LinnetStableRowTextBinding.swift
  tests/LinnetCandidateAccessibilityTests.swift
  tests/LinnetStableRowTextBindingTests.swift
  tests/verify_rime_test_orchestration.sh
)
for path in "${retired_files[@]}"; do
  [[ ! -e "${path}" && ! -L "${path}" ]] ||
    fail "retired path returned: ${path}"
done

assert_absent() {
  local description="$1"
  local pattern="$2"
  shift 2
  if rg -n --glob '!librime/**' --glob '!build/**' \
      --glob '!tests/verify_runtime_footprint.sh' "${pattern}" "$@"; then
    fail "${description}"
  fi
}

assert_absent \
  "expired identity-free Core bridge returned" \
  'identityFreeBridgeTargetVersion|restartRequired' \
  sources resources

assert_absent \
  "frontend chord compatibility returned" \
  'chordKeyCodes|chordModifiers|chordKeyCount|chordTimer|chordDuration|clearChord\(|updateChord\(|updateChordState\(|isChordingKey\(|_chord_typing|chord_duration' \
  sources data/squirrel.yaml

assert_absent \
  "backup-v2 compatibility returned" \
  'legacyV2Snapshot|normalizeLegacyV2|legacy-v2|format-v2' \
  sources/LinnetSettings config README.md docs

assert_absent \
  "retired legacy migration snapshot returned" \
  'legacy_migration_acceptance' \
  config scripts package tests

assert_absent \
  "global CWD mutation or leaking C-string helper returned" \
  'changeCurrentDirectoryPath|setCString\(' \
  sources

assert_absent \
  "retired source-location or observer cleanup returned" \
  '#sourceLocation|NotificationCenter\.default\.removeObserver\(self\)' \
  sources

unexpected_prints="$(
  rg -n '\bprint\s*\(' sources --glob '*.swift' |
    grep -v -E '^sources/Main\.swift:[0-9]+:[[:space:]]+print\(helpDoc\)$' || true
)"
[[ -z "${unexpected_prints}" ]] || {
  printf '%s\n' "${unexpected_prints}" >&2
  fail "production code regained raw print diagnostics"
}

registration_owners="$(
  rg -l 'TISRegisterInputSource|TISEnableInputSource' sources --glob '*.swift' |
    LC_ALL=C sort
)"
[[ "${registration_owners}" == sources/InputSource.swift ]] || {
  printf '%s\n' "${registration_owners}" >&2
  fail "input-source registration mutation escaped its single owner"
}

echo "Linnet retired runtime paths: PASS"
