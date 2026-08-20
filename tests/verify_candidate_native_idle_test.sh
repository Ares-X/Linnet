#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
outside_root="$(mktemp -d /private/tmp/linnet-native-idle-outside.XXXXXX)"
inside_root=
outside_pid=
inside_pid=
reports_dir="${HOME}/Library/Logs/DiagnosticReports"

cleanup() {
  exit_code=$?
  trap - EXIT INT TERM
  for probe_pid in "${outside_pid}" "${inside_pid}"; do
    if [[ -n "${probe_pid}" ]]; then
      kill "${probe_pid}" >/dev/null 2>&1 || true
      wait "${probe_pid}" 2>/dev/null || true
    fi
  done
  if [[ "${outside_root}" == /private/tmp/linnet-native-idle-outside.?????? &&
        -d "${outside_root}" && ! -L "${outside_root}" ]]; then
    find "${outside_root}" -depth -delete
  fi
  if [[ -n "${inside_root}" &&
        "${inside_root}" == "${repo_root}"/build/linnet-native-idle-inside.?????? &&
        -d "${inside_root}" && ! -L "${inside_root}" ]]; then
    find "${inside_root}" -depth -delete
  fi
  exit "${exit_code}"
}
trap cleanup EXIT INT TERM

inside_root="$(mktemp -d "${repo_root}/build/linnet-native-idle-inside.XXXXXX")"
report_marker="${outside_root}/diagnostic-report-marker"
touch "${report_marker}"
cat >"${outside_root}/sleeper.c" <<'C'
#include <unistd.h>

int main(void) {
  sleep(30);
  return 0;
}
C
compiler="$(xcrun --find clang)"
macos_sdk="$(xcrun --show-sdk-path)"
"${compiler}" -isysroot "${macos_sdk}" -Os -Wall -Wextra -Werror \
  "${outside_root}/sleeper.c" \
  -o "${outside_root}/rime_deployer"
"${compiler}" -isysroot "${macos_sdk}" -Os -Wall -Wextra -Werror \
  "${outside_root}/sleeper.c" \
  -o "${inside_root}/rime_deployer"
codesign --verify --strict "${outside_root}/rime_deployer"
codesign --verify --strict "${inside_root}/rime_deployer"

"${outside_root}/rime_deployer" 30 &
outside_pid=$!
sleep 0.2
kill -0 "${outside_pid}"
set +e
outside_output="$(tests/verify_candidate_native_idle.sh 2>&1)"
outside_status=$?
set -e
if [[ "${outside_status}" -ne 0 ]]; then
  printf '%s\n' "${outside_output}" >&2
  echo "candidate native idle: an unrelated same-name process was blocked" >&2
  exit 1
fi
kill -0 "${outside_pid}"
kill "${outside_pid}"
wait "${outside_pid}" 2>/dev/null || true
outside_pid=

"${inside_root}/rime_deployer" 30 &
inside_pid=$!
sleep 0.2
kill -0 "${inside_pid}"
set +e
inside_output="$(tests/verify_candidate_native_idle.sh 2>&1)"
inside_status=$?
set -e
if [[ "${inside_status}" -ne 2 ]]; then
  printf '%s\n' "${inside_output}" >&2
  echo "candidate native idle: an exact candidate process was not blocked" >&2
  exit 1
fi
kill -0 "${inside_pid}"

sleep 0.2
if [[ -d "${reports_dir}" ]] && find "${reports_dir}" -maxdepth 1 -type f \
    -name 'rime_deployer*.ips' -newer "${report_marker}" -print -quit | grep -q .; then
  echo "candidate native idle: fixture generated a native crash report" >&2
  exit 1
fi

echo "Linnet candidate native idle ownership: PASS"
