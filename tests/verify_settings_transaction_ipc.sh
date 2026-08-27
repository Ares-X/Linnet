#!/usr/bin/env bash

# Product-shaped focused acceptance for the Settings <-> Host AF_UNIX owner.
# Both peers are separate compiled processes. The owner-only endpoint and
# kernel-owned UID/PID facts are the same-user peer identity boundary.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

if rg -n 'import Security|Sec(Code|StaticCode|Certificate)|kSecCode|CC_SHA256|leafCertificate|peerBundleIdentifier|LinnetIPCPeerBundleIdentifier' \
    sources/LinnetSettings/LinnetSettingsTransactionIPC.swift \
    tests/LinnetSettingsTransactionIPCTests.swift; then
  echo "verify_settings_transaction_ipc: certificate-based peer identity returned" >&2
  exit 1
fi
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

swift_compiler="$(xcrun --find swiftc)"
macos_sdk="$(xcrun --sdk macosx --show-sdk-path)"
host_helper="${fixture}/LinnetHostIPC"
settings_helper="${fixture}/LinnetSettingsIPC"
common_sources=(
  sources/LinnetSettings/SettingsContract.swift
  sources/LinnetSettings/LinnetSettingsTransactionIPC.swift
  tests/LinnetSettingsTransactionIPCTests.swift
)
"${swift_compiler}" -warnings-as-errors -sdk "${macos_sdk}" \
  -D LINNET_IPC_HOST_HELPER "${common_sources[@]}" -o "${host_helper}"
"${swift_compiler}" -warnings-as-errors -sdk "${macos_sdk}" \
  -D LINNET_IPC_SETTINGS_HELPER "${common_sources[@]}" -o "${settings_helper}"

[[ "${host_helper}" != "${settings_helper}" ]]

wait_for_socket() {
  local endpoint="$1"
  local pid="$2"
  local count
  for ((count = 0; count < 300; count += 1)); do
    [[ -S "${endpoint}" ]] && return 0
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
  "${host_helper}" "${mode}" "${endpoint}" "$@" \
    >"${log}" 2>&1 &
  active_host_pid="$!"
  wait_for_socket "${endpoint}" "${active_host_pid}" || {
    cat "${log}" >&2
    return 1
  }
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
  local client="$2"
  shift 2
  local endpoint="${fixture}/${label}.sock"
  local log="${fixture}/${label}.host.log"
  start_host --serve-rejection "${endpoint}" "${log}"
  "${client}" --expect-rejection "${endpoint}" "$@"
  wait_for_host "${log}"
}

# Positive: two distinct compiled executable paths/processes owned by the same
# user exchange a real progress + terminal reply sequence.
positive_endpoint="${fixture}/positive.sock"
positive_log="${fixture}/positive.host.log"
start_host --serve-success "${positive_endpoint}" "${positive_log}"
"${settings_helper}" --request-success "${positive_endpoint}"
wait_for_host "${positive_log}"

reload_endpoint="${fixture}/reload.sock"
reload_log="${fixture}/reload.host.log"
start_host --serve-reload "${reload_endpoint}" "${reload_log}"
"${settings_helper}" --request-reload "${reload_endpoint}"
wait_for_host "${reload_log}"

# A Core update atomically replaces the bundle while the InputMethodKit Host
# stays alive. The old executable vnode can then lose its pathname, but the
# kernel-authenticated same-user Host still owns the established runtime
# endpoint. A newly launched Settings process must continue to reach it.
update_host="${fixture}/LinnetHostIPC.update"
retired_host="${fixture}/.LinnetHostIPC.update.retired"
update_endpoint="${fixture}/core-update.sock"
update_log="${fixture}/core-update.host.log"
cp "${host_helper}" "${update_host}"
"${update_host}" --serve-success "${update_endpoint}" \
  >"${update_log}" 2>&1 &
active_host_pid="$!"
wait_for_socket "${update_endpoint}" "${active_host_pid}"
mv "${update_host}" "${retired_host}"
cp "${host_helper}" "${update_host}"
/bin/rm -f -- "${retired_host}"
"${settings_helper}" --request-success "${update_endpoint}"
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
"${settings_helper}" --request-timeout-recovery "${timeout_endpoint}" \
  "${timeout_live}" "${timeout_marker}"
wait_for_host "${timeout_log}"
rg -Fq \
  'timeout/recovery generation PASS (expired mixed read non-authoritative; stable recovery accepted)' \
  "${timeout_log}"

forged_pid_client="${fixture}/SettingsForgedRequesterPID"
cp "${settings_helper}" "${forged_pid_client}"
run_rejection forged-requester-pid "${forged_pid_client}" --forged-requester-pid

echo "LinnetSettingsTransactionIPCTwoProcessTests: PASS (activate + reload + live Core replacement + 3s timeout/recovery generation + owner-only socket + peer UID/PID + forged-pid)"
