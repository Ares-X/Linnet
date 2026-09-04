#!/usr/bin/env bash

# Product-shaped focused acceptance for the Settings <-> Host AF_UNIX owner.
# Both peers are separate compiled processes. The owner-only endpoint and
# kernel-owned UID/PID facts are the same-user peer identity boundary.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

fixture="$(mktemp -d /tmp/linnet-settings-ipc.XXXXXX)"
fixture="$(cd "${fixture}" && pwd -P)"
active_host_pid=''

cleanup() {
  if [[ "${active_host_pid}" =~ ^[0-9]+$ ]] && kill -0 "${active_host_pid}" 2>/dev/null; then
    kill "${active_host_pid}" 2>/dev/null || true
    wait "${active_host_pid}" 2>/dev/null || true
  fi
  if [[ "${fixture}" == /private/tmp/linnet-settings-ipc.* ||
    "${fixture}" == /tmp/linnet-settings-ipc.* ]]; then
    /bin/rm -rf -- "${fixture}"
  fi
}
trap cleanup EXIT INT TERM

macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"
source tests/swift_test_cache.sh
linnet_swift_cache_init "${repo_root}" "${fixture}"
host_app="${fixture}/LinnetHostIPC.app"
settings_app="${fixture}/LinnetSettingsIPC.app"
host_helper="${host_app}/Contents/MacOS/LinnetHostIPC"
settings_helper="${settings_app}/Contents/MacOS/LinnetSettingsIPC"
mkdir -p "${host_helper%/*}" "${settings_helper%/*}"
common_sources=(
  sources/LinnetSettings/SettingsContract.swift
  sources/LinnetSettings/LinnetSettingsTransactionIPC.swift
  tests/LinnetSettingsTransactionIPCTests.swift
)
linnet_swift_compile settings-ipc-host -warnings-as-errors -sdk "${macos_sdk}" \
  -D LINNET_IPC_HOST_HELPER "${common_sources[@]}"
cp "${LINNET_SWIFT_COMPILED_BINARY}" "${host_helper}"
linnet_swift_compile settings-ipc-settings -warnings-as-errors -sdk "${macos_sdk}" \
  -D LINNET_IPC_SETTINGS_HELPER "${common_sources[@]}"
cp "${LINNET_SWIFT_COMPILED_BINARY}" "${settings_helper}"

write_bundle_info() {
  local app="$1"
  local executable="$2"
  local identifier="$3"
  local info="${app}/Contents/Info.plist"
  plutil -create xml1 "${info}"
  plutil -insert CFBundleExecutable -string "${executable}" "${info}"
  plutil -insert CFBundleIdentifier -string "${identifier}" "${info}"
  plutil -insert CFBundleDisplayName -string LinnetIPCTest "${info}"
  plutil -insert CFBundleName -string "${executable}" "${info}"
  plutil -insert CFBundlePackageType -string APPL "${info}"
  plutil -insert CFBundleShortVersionString -string 1.0.0 "${info}"
  plutil -insert CFBundleVersion -string 1 "${info}"
  plutil -insert InputMethodConnectionName -string LinnetIPCTest_Connection "${info}"
}
write_bundle_info "${host_app}" LinnetHostIPC io.github.ares-x.linnet.ipc-test.host
write_bundle_info "${settings_app}" LinnetSettingsIPC io.github.ares-x.linnet.ipc-test.settings

[[ "${host_helper}" != "${settings_helper}" ]]

runtime_root_for() {
  local key
  key="$(printf '%s' "$1" | cksum | awk '{print $1}')"
  printf '%s/r%s\n' "${fixture}" "${key}"
}
runtime_socket_for() {
  printf '%s/State/settings-transaction.sock\n' "$(runtime_root_for "$1")"
}

wait_for_socket() {
  local endpoint="$1"
  local pid="$2"
  local previous_inode="${3:-}"
  local count
  for ((count = 0; count < 300; count += 1)); do
    if [[ -S "${endpoint}" ]]; then
      current_inode="$(stat -f '%i' "${endpoint}")"
      if [[ -z "${previous_inode}" || "${current_inode}" != "${previous_inode}" ]]; then
        return 0
      fi
    fi
    kill -0 "${pid}" 2>/dev/null || return 1
    sleep 0.01
  done
  return 1
}

start_host() {
  local mode="$1"
  local endpoint="$2"
  local log="$3"
  shift 3
  local runtime_root
  local runtime_socket
  local previous_inode=''
  runtime_root="$(runtime_root_for "${endpoint}")"
  runtime_socket="$(runtime_socket_for "${endpoint}")"
  if [[ -S "${runtime_socket}" ]]; then
    previous_inode="$(stat -f '%i' "${runtime_socket}")"
  fi
  LINNET_IPC_TEST_ROOT="${runtime_root}" \
    "${host_helper}" "${mode}" "${endpoint}" "$@" \
    >"${log}" 2>&1 &
  active_host_pid="$!"
  wait_for_socket "${runtime_socket}" "${active_host_pid}" "${previous_inode}" || {
    cat "${log}" >&2
    return 1
  }
}

run_settings() {
  local endpoint="$1"
  local mode="$2"
  shift 2
  LINNET_IPC_TEST_ROOT="$(runtime_root_for "${endpoint}")" \
    "${settings_helper}" "${mode}" "${endpoint}" "$@"
}

wait_for_host() {
  local log="$1"
  local status=0
  wait "${active_host_pid}" || status="$?"
  active_host_pid=''
  if [[ "${status}" -ne 0 ]]; then
    cat "${log}" >&2
    return "${status}"
  fi
}

run_rejection() {
  local label="$1"
  shift
  local endpoint="${fixture}/${label}.sock"
  local log="${fixture}/${label}.host.log"
  start_host --serve-rejection "${endpoint}" "${log}"
  run_settings "${endpoint}" --expect-rejection "$@"
  wait_for_host "${log}"
}

run_compatibility_rejection() {
  local label="$1"
  local capability="$2"
  local endpoint="${fixture}/${label}.sock"
  local log="${fixture}/${label}.host.log"
  start_host --serve-rejection "${endpoint}" "${log}"
  run_settings "${endpoint}" --request-pause "${capability}" --expect-rejection
  wait_for_host "${log}"
}

# Positive: two distinct compiled executable paths/processes owned by the same
# user exchange a real progress + terminal reply sequence.
positive_endpoint="${fixture}/positive.sock"
positive_log="${fixture}/positive.host.log"
start_host --serve-success "${positive_endpoint}" "${positive_log}"
run_settings "${positive_endpoint}" --request-success
wait_for_host "${positive_log}"

# A second Host cannot classify the first Host's live owner-only endpoint as
# stale. The original listener must remain reachable after the rejected start.
owner_endpoint="${fixture}/owner-collision.sock"
owner_log="${fixture}/owner-collision.host.log"
start_host --serve-owner-collision "${owner_endpoint}" "${owner_log}"
run_settings "${owner_endpoint}" --request-success
wait_for_host "${owner_log}"
rg -Fq 'active endpoint owner preserved' "${owner_log}"

# A socket path with no listener is genuinely stale and must not strand the
# next Host. This is the positive counterpart to active-owner preservation.
stale_endpoint="${fixture}/stale-owner.sock"
stale_log="${fixture}/stale-owner.host.log"
stale_socket="$(runtime_socket_for "${stale_endpoint}")"
mkdir -p "${stale_socket%/*}"
ruby -rsocket -e 'server = UNIXServer.new(ARGV.fetch(0)); server.close' "${stale_socket}"
[[ -S "${stale_socket}" ]]
start_host --serve-success "${stale_endpoint}" "${stale_log}"
run_settings "${stale_endpoint}" --request-success
wait_for_host "${stale_log}"

reload_endpoint="${fixture}/reload.sock"
reload_log="${fixture}/reload.host.log"
start_host --serve-reload "${reload_endpoint}" "${reload_log}"
run_settings "${reload_endpoint}" --request-reload
wait_for_host "${reload_log}"

core_activation_endpoint="${fixture}/core-activation.sock"
core_activation_log="${fixture}/core-activation.host.log"
start_host --serve-core-activation "${core_activation_endpoint}" "${core_activation_log}"
run_settings "${core_activation_endpoint}" --request-core-activation
wait_for_host "${core_activation_log}"

# A Core update atomically replaces the bundle while the InputMethodKit Host
# stays alive. The old executable vnode can then lose its pathname, but the
# kernel-authenticated same-user Host still owns the established runtime
# endpoint. A newly launched Settings process must continue to reach it.
update_app="${fixture}/LinnetHostIPC.update.app"
cp -R "${host_app}" "${update_app}"
update_host="${update_app}/Contents/MacOS/LinnetHostIPC"
retired_host="${update_app}/Contents/MacOS/.LinnetHostIPC.retired"
update_endpoint="${fixture}/core-update.sock"
update_log="${fixture}/core-update.host.log"
LINNET_IPC_TEST_ROOT="$(runtime_root_for "${update_endpoint}")" \
  "${update_host}" --serve-success "${update_endpoint}" \
  >"${update_log}" 2>&1 &
active_host_pid="$!"
wait_for_socket "$(runtime_socket_for "${update_endpoint}")" "${active_host_pid}"
mv "${update_host}" "${retired_host}"
cp "${host_helper}" "${update_host}"
/bin/rm -f -- "${retired_host}"
run_settings "${update_endpoint}" --request-success
wait_for_host "${update_log}"

# Product-shaped timeout/recovery: the first real Host connection reads one
# renderer-owned projection, remains inside the owned-file read beyond the exact 3 s
# Settings deadline, and observes a mixed transient snapshot after Settings
# restores stable bytes. Its expired transaction is non-authoritative. A fresh
# recovery UUID on a second real socket is serialized behind it and may only
# accept the complete stable generation.
timeout_endpoint="${fixture}/timeout-recovery.sock"
timeout_log="${fixture}/timeout-recovery.host.log"
timeout_live="${fixture}/timeout-recovery-live"
timeout_marker="${fixture}/timeout-recovery-first-read"
start_host --serve-timeout-recovery "${timeout_endpoint}" \
  "${timeout_log}" "${timeout_live}" "${timeout_marker}"
run_settings "${timeout_endpoint}" --request-timeout-recovery \
  "${timeout_live}" "${timeout_marker}"
wait_for_host "${timeout_log}"
rg -Fq \
  'timeout/recovery generation PASS (expired mixed read non-authoritative; stable recovery accepted)' \
  "${timeout_log}"

run_rejection forged-requester-pid --forged-requester-pid

# Published Settings does not declare a native learning-data logical view, so
# it may still diagnose and request Core activation but cannot pause Rime.
run_compatibility_rejection missing-native-learning-data-version \
  --legacy-native-learning-data
run_compatibility_rejection unknown-native-learning-data-version \
  --unknown-native-learning-data

pause_endpoint="${fixture}/pause.sock"
pause_log="${fixture}/pause.host.log"
start_host --serve-success "${pause_endpoint}" "${pause_log}"
run_settings "${pause_endpoint}" --request-pause
wait_for_host "${pause_log}"

legacy_diagnose_endpoint="${fixture}/legacy-diagnose.sock"
legacy_diagnose_log="${fixture}/legacy-diagnose.host.log"
start_host --serve-success "${legacy_diagnose_endpoint}" "${legacy_diagnose_log}"
run_settings "${legacy_diagnose_endpoint}" --request-diagnose --legacy-native-learning-data
wait_for_host "${legacy_diagnose_log}"

legacy_core_endpoint="${fixture}/legacy-core-activation.sock"
legacy_core_log="${fixture}/legacy-core-activation.host.log"
start_host --serve-core-activation "${legacy_core_endpoint}" "${legacy_core_log}"
run_settings "${legacy_core_endpoint}" --request-core-activation --legacy-native-learning-data
wait_for_host "${legacy_core_log}"

echo "LinnetSettingsTransactionIPCTwoProcessTests: PASS (activate + Core termination + reload + current pause capability + legacy/unknown pause rejection + legacy diagnose/Core + active/stale owner classification + live Core replacement + 3s timeout/recovery generation + owner-only socket + peer UID/PID + forged-pid)"
