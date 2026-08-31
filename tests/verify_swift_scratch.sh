#!/usr/bin/env bash

set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

if [[ "${1:-}" == --child ]]; then
  source "${repo_root}/tests/swift_test_scratch.sh"
  linnet_swift_scratch_init
  printf '%s\n' "${scratch}"
  "$3" "$2" "$4"
  case "$2" in
    term) kill -TERM "$$" ;;
    int) kill -INT "$$" ;;
  esac
  exit 0
fi

if rg -n 'FileManager\.default\.temporaryDirectory|NSTemporaryDirectory\(' \
  "${repo_root}/tests" --glob '*.swift'; then
  echo "Swift fixtures must use the runner-owned LinnetTestScratch.directory." >&2
  exit 1
fi

fixture="$(mktemp -d /private/tmp/linnet-scratch-regression.XXXXXX)"
cleanup() {
  find -P "${fixture}" -type d -exec chmod u+w {} +
  /bin/rm -r -- "${fixture}" </dev/null
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "${fixture}/system-temp" "${fixture}/external"
printf 'preserve external data\n' >"${fixture}/external/sentinel"
chmod 444 "${fixture}/external/sentinel"
chmod 555 "${fixture}/external"
external_before="$(stat -f '%Lp' "${fixture}/external" "${fixture}/external/sentinel")"
sentinel_before="$(shasum -a 256 "${fixture}/external/sentinel")"
xcrun swiftc -warnings-as-errors "${repo_root}/tests/LinnetTestScratch.swift" \
  "${repo_root}/tests/SwiftTestScratchProbe.swift" -o "${fixture}/probe"

failed=0
for scenario in success failure term int; do
  expected=0
  case "${scenario}" in failure) expected=37 ;; term) expected=143 ;; int) expected=130 ;; esac
  result=0
  TMPDIR="${fixture}/system-temp/" bash "$0" --child "${scenario}" \
    "${fixture}/probe" "${fixture}/external" >"${fixture}/report" 2>"${fixture}/errors" || result=$?
  run_root="$(sed -n '1p' "${fixture}/report")"
  probe_root="$(sed -n '2p' "${fixture}/report")"
  if [[ "${result}" -ne "${expected}" || -z "${run_root}" || -z "${probe_root}" ||
    -e "${run_root}" || -e "${probe_root}" ||
    "${probe_root}" != "${run_root}/"* ||
    "$(stat -f '%Lp' "${fixture}/external" "${fixture}/external/sentinel")" != "${external_before}" ||
    "$(shasum -a 256 "${fixture}/external/sentinel")" != "${sentinel_before}" ]]; then
    printf 'Swift scratch: FAIL %s (exit=%s, expected=%s, runner=%s, fixture=%s)\n' \
      "${scenario}" "${result}" "${expected}" "${run_root}" "${probe_root}" >&2
    failed=1
  else
    printf 'Swift scratch: PASS %s (isolated, removed, external symlink untouched)\n' "${scenario}"
  fi
  # Also remove a leaked baseline runner, so the regression itself leaves no debris.
  if [[ "${run_root}" =~ ^/(private/)?tmp/linnet-swift-units\.[A-Za-z0-9]+$ &&
    -d "${run_root}" && ! -L "${run_root}" ]]; then
    find -P "${run_root}" -type d -exec chmod u+w {} +
    /bin/rm -r -- "${run_root}" </dev/null
  fi
done
exit "${failed}"
