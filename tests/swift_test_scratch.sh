#!/usr/bin/env bash

# Process-level lifetime owner for standalone Swift test fixtures.
linnet_swift_scratch_init() {
  scratch="$(mktemp -d /private/tmp/linnet-swift-units.XXXXXX)"
  readonly scratch
  trap linnet_swift_scratch_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  export LINNET_SWIFT_TEST_SCRATCH="${scratch}/fixtures"
  mkdir "${LINNET_SWIFT_TEST_SCRATCH}"
  export TMPDIR="${LINNET_SWIFT_TEST_SCRATCH}/"
}

linnet_swift_scratch_cleanup() {
  local result=$?
  trap - EXIT INT TERM
  # Only this mktemp root is owned here; never follow a fixture's external links.
  if [[ ! "${scratch}" =~ ^/private/tmp/linnet-swift-units\.[A-Za-z0-9]+$ ||
    ! -d "${scratch}" || -L "${scratch}" ]]; then
    echo "Swift test scratch root changed: ${scratch}" >&2
    [[ "${result}" -ne 0 ]] || result=1
  elif ! find -P "${scratch}" -type d -exec chmod u+w {} + ||
    ! /bin/rm -r -- "${scratch}" </dev/null; then
    echo "Swift test scratch cleanup failed: ${scratch}" >&2
    [[ "${result}" -ne 0 ]] || result=1
  fi
  exit "${result}"
}
