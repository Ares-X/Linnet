#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

app_path="${APP_PATH:-}"
language_data_root="${LANGUAGE_DATA_ROOT:-}"

fail() {
  echo "verify_input_process_offline: FAIL: $*" >&2
  exit 1
}

if [[ -z "${app_path}" ]]; then
  fail "APP_PATH must name the built input-method App"
fi
app_path="${app_path%/}"
if [[ ! -d "${app_path}" || "${app_path##*/}" != *.app ]]; then
  fail "APP_PATH is not an App bundle"
fi
if [[ -z "${language_data_root}" || ! -d "${language_data_root}" ]]; then
  fail "LANGUAGE_DATA_ROOT must name the staged language-pack payload"
fi

for required_tool in codesign file nm otool rg xcrun; do
  command -v "${required_tool}" >/dev/null 2>&1 ||
    fail "required inspection tool is unavailable: ${required_tool}"
done

probe_source="${repo_root}/tests/fixtures/network_probe.c"
[[ -f "${probe_source}" ]] || fail "network scanner probe is missing"
lua_probe_source="${repo_root}/tests/fixtures/network_probe.lua"
[[ -f "${lua_probe_source}" ]] || fail "Lua scanner probe is missing"
lua_embedding_generator="${repo_root}/scripts/generate-linnet-lua-embedding"
[[ -x "${lua_embedding_generator}" ]] || fail "Lua embedding generator is missing"
member_probe_source="${repo_root}/tests/fixtures/network_member_probe.cc"
[[ -f "${member_probe_source}" ]] || fail "member-call scanner probe is missing"

scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/linnet-offline.XXXXXX")"
cleanup() {
  if [[ -n "${scratch_root:-}" && -d "${scratch_root}" ]]; then
    rm -rf -- "${scratch_root}"
  fi
}
trap cleanup EXIT

source_framework_pattern="(^|[^[:alnum:]_])(import|@import)[[:space:]]+(FoundationNetworking|Network|NetworkExtension|CFNetwork|WebKit|Sparkle)([^[:alnum:]_]|$)|#[[:space:]]*(include|import)[[:space:]]*[<\"](Network|NetworkExtension|CFNetwork|WebKit|curl)/|-framework[[:space:]\"']*(Network|NetworkExtension|CFNetwork|WebKit|Sparkle)([^[:alnum:]_]|$)|(Network|NetworkExtension|CFNetwork|WebKit|Sparkle)\\.framework"
source_symbol_pattern='URLSession|NSURLSession|URLSessionWebSocketTask|NW(Connection|Listener|Browser|PathMonitor)|CFHTTP|CFSocket|CFStreamCreatePairWithSocketToHost|curl_(easy|multi|share|url)|SPU(StandardUpdaterController|Updater)|(^|[^[:alnum:]_.>])(socketpair|getaddrinfo|getnameinfo|sendto|recvfrom)[[:space:]]*\('
local_ipc_source_pattern='(^|[^[:alnum:]_.>])(socket|connect|send|accept|listen|bind)[[:space:]]*\('
entitlement_pattern='com\.apple\.security\.network\.|com\.apple\.developer\.networking\.|com\.apple\.developer\.associated-domains'
binary_framework_pattern='/(Network|NetworkExtension|CFNetwork|WebKit|Sparkle)\.framework/|/lib(network|curl)([^/]*)\.dylib'
binary_symbol_pattern='NSURLSession|URLSessionWebSocketTask|(^|[[:space:]])_nw_|_CFHTTP|_CFSocket|_CFStreamCreatePairWithSocketToHost|_curl_(easy|multi|share|url)|SPU(StandardUpdaterController|Updater)|(^|[[:space:]])(U[[:space:]]+)?_?(socketpair|getaddrinfo|getnameinfo|sendto|recv|recvfrom)([[:space:]@]|$)'
binary_local_ipc_symbol_pattern='(^|[[:space:]])(U[[:space:]]+)?_?(socket|connect|send|accept|listen|bind)([[:space:]@]|$)'
lua_external_execution_pattern='(^|[^[:alnum:]_])(os\.execute|io\.popen|package\.loadlib|loadfile|dofile)[[:space:]]*\('
lua_network_module_pattern="require[[:space:]]*(\\([[:space:]]*)?['\"](socket(\\.[^'\"]*)?|ssl(\\.[^'\"]*)?|http|https|curl)['\"]"

has_direct_network_framework() {
  rg -q --pcre2 "${source_framework_pattern}" "$@"
}

has_direct_network_symbol() {
  rg -q --pcre2 "${source_symbol_pattern}" "$@"
}

has_network_entitlement() {
  rg -q "${entitlement_pattern}" "$@"
}

has_remote_workspace_open() {
  local source_file
  for source_file in "$@"; do
    if rg -q 'NSWorkspace' "${source_file}" &&
        rg -q 'https?://' "${source_file}" &&
        rg -q '\.open[[:space:]]*\(' "${source_file}"; then
      return 0
    fi
  done
  return 1
}

has_remote_url_literal() {
  rg -q 'https?://' "$@"
}

# The one probe independently exercises each static rule. Its executable then
# proves that the Mach-O symbol rule sees an imported networking implementation,
# rather than merely matching source spelling.
has_direct_network_framework "${probe_source}" ||
  fail "framework scanner rejected its positive contract"
has_direct_network_symbol "${probe_source}" ||
  fail "symbol scanner rejected its positive contract"
for positive_symbol in getaddrinfo socket connect; do
  rg -q --pcre2 \
    "(^|[^[:alnum:]_.>])${positive_symbol}[[:space:]]*\\(" \
    "${probe_source}" ||
    fail "symbol scanner rejected its ${positive_symbol} positive contract"
done
if has_direct_network_symbol "${member_probe_source}"; then
  fail "symbol scanner treated a member connect selector as a network call"
fi
has_network_entitlement "${probe_source}" ||
  fail "entitlement scanner rejected its positive contract"
has_remote_workspace_open "${probe_source}" ||
  fail "remote workspace scanner rejected its positive contract"
has_remote_url_literal "${probe_source}" ||
  fail "remote URL scanner rejected its positive contract"
rg -q --pcre2 "${lua_external_execution_pattern}" "${lua_probe_source}" ||
  fail "Lua external-execution scanner rejected its positive contract"
rg -q --pcre2 "${lua_network_module_pattern}" "${lua_probe_source}" ||
  fail "Lua network-module scanner rejected its positive contract"

clang_path="$(xcrun --find clang 2>/dev/null)" ||
  fail "the probe compiler is unavailable"
sdk_path="$(xcrun --show-sdk-path 2>/dev/null)" ||
  fail "the probe SDK is unavailable"
probe_binary="${scratch_root}/network-probe"
if ! "${clang_path}" -arch arm64 -mmacosx-version-min=13.0 -isysroot "${sdk_path}" \
    "${probe_source}" -o "${probe_binary}" >/dev/null 2>&1; then
  fail "the network scanner probe did not compile"
fi
if ! file -b "${probe_binary}" 2>/dev/null | rg -q 'Mach-O.*arm64'; then
  fail "the network scanner probe is not an arm64 Mach-O"
fi
if ! nm -u "${probe_binary}" >"${scratch_root}/probe-symbols" 2>/dev/null; then
  fail "the network scanner probe symbols are unreadable"
fi
if ! rg -q --pcre2 "${binary_symbol_pattern}" "${scratch_root}/probe-symbols"; then
  fail "the Mach-O scanner accepted the positive network probe"
fi

source_files=()
while IFS= read -r -d '' source_file; do
  source_files+=("${source_file}")
done < <(
  find "${repo_root}/sources" -maxdepth 1 -type f \
    \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.h' \
       -o -name '*.m' -o -name '*.mm' -o -name '*.swift' \) -print0
  find "${repo_root}/plugins/smart_english" -type f \
    \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.h' \
       -o -name '*.m' -o -name '*.mm' -o -name '*.swift' \) -print0
)
source_files+=("${repo_root}/sources/LinnetSettings/SettingsContract.swift")
local_ipc_owner="${repo_root}/sources/LinnetSettings/LinnetSettingsTransactionIPC.swift"
[[ -f "${local_ipc_owner}" ]] || fail "the authenticated local IPC owner is missing"

(( ${#source_files[@]} > 1 )) || fail "input-process sources are missing"
if has_direct_network_framework "${source_files[@]}"; then
  fail "the input process directly references a network framework"
fi
if has_direct_network_symbol "${source_files[@]}"; then
  fail "the input process directly references a network API"
fi
if has_remote_url_literal "${source_files[@]}"; then
  fail "the input process contains a remote URL path"
fi

# Linnet's transaction transport is the sole local-IPC exception to the
# offline input-process rule. Pin its path, address family, socket type and
# complete network-shaped call set so this cannot become a generic socket
# allowlist or a second transport owner.
if has_direct_network_framework "${local_ipc_owner}" ||
   has_direct_network_symbol "${local_ipc_owner}" ||
   has_remote_url_literal "${local_ipc_owner}"; then
  fail "the local IPC owner contains a remote-network path"
fi
if rg -n 'AF_INET6?|SOCK_DGRAM|socketpair|getaddrinfo|getnameinfo|sendto|recv(from)?|URLSession|https?://' \
    "${local_ipc_owner}"; then
  fail "the local IPC owner escaped its AF_UNIX stream contract"
fi
[[ "$(rg -F -c 'socket(AF_UNIX, SOCK_STREAM, 0)' "${local_ipc_owner}")" -eq 2 ]] ||
  fail "the local IPC owner changed its socket creation contract"
for call_contract in \
  'Darwin.bind(fileDescriptor, address, length)' \
  'listen(fileDescriptor, 8)' \
  'accept(listener, nil, nil)' \
  'Darwin.connect(fileDescriptor, address, length)' \
  'MSG_DONTWAIT | MSG_NOSIGNAL)'
do
  [[ "$(rg -F -c "${call_contract}" "${local_ipc_owner}")" -eq 1 ]] ||
    fail "the local IPC owner changed its system-call set"
done
[[ "$(rg -c --pcre2 "${local_ipc_source_pattern}" "${local_ipc_owner}")" -eq 5 ]] ||
  fail "the local IPC owner gained another network-shaped call"
[[ "$(rg -F -c 'getpeereid(fileDescriptor, &uid, &gid)' "${local_ipc_owner}")" -eq 1 ]] ||
  fail "the local IPC owner lost peer-UID authentication"
[[ "$(rg -F -c 'getsockopt(fileDescriptor, SOL_LOCAL, LOCAL_PEERPID' "${local_ipc_owner}")" -eq 1 ]] ||
  fail "the local IPC owner lost peer-PID authentication"
# Same-user local IPC has one identity owner: kernel UID/PID plus the exact
# counterpart executable path. Product code signing is a release boundary, not
# a second runtime IPC identity system.
[[ "$(rg -F -c 'proc_pidpath(pid' "${local_ipc_owner}")" -eq 1 ]] ||
  fail "the local IPC owner lost exact peer executable authentication"
if rg -n 'import Security|Sec(Code|StaticCode|Certificate)|kSecCode|CC_SHA256|leafCertificate|peerBundleIdentifier' \
    "${local_ipc_owner}"; then
  fail "the local IPC owner regained certificate-based peer identity"
fi

source_entitlements="${repo_root}/resources/Squirrel.entitlements"
if ! plutil -lint "${source_entitlements}" >/dev/null 2>&1; then
  fail "the input-process entitlement file is invalid"
fi
if has_network_entitlement "${source_entitlements}"; then
  fail "the input process declares a network entitlement"
fi

lua_files=()
if find "${language_data_root}" \( -type f -o -type l \) \
    -name '*.lua' -print -quit | grep -q .; then
  fail "a writable language-data root contains executable Lua"
fi
if find "${app_path}" \( -type f -o -type l \) \
    -name '*.lua' -print -quit | grep -q .; then
  fail "the App contains a filesystem Lua resource"
fi
while IFS= read -r relative_path; do
  [[ "${relative_path}" =~ ^[A-Za-z0-9._/-]+$ &&
     "${relative_path}" != /* && "${relative_path}" != *..* ]] ||
    fail "the embedded Lua inventory contains an unsafe path"
  lua_file="${repo_root}/${relative_path}"
  [[ -f "${lua_file}" && ! -L "${lua_file}" ]] ||
    fail "an embedded Lua source is missing or unsafe"
  lua_files+=("${lua_file}")
done < <("${lua_embedding_generator}" --print-inputs)
[[ "${#lua_files[@]}" -eq 11 ]] ||
  fail "embedded Core Lua is not the exact eleven-input set"
if rg -q --pcre2 "${lua_external_execution_pattern}" "${lua_files[@]}"; then
  fail "embedded Core Lua can execute an external program or native library"
fi
if rg -q --pcre2 "${lua_network_module_pattern}" "${lua_files[@]}"; then
  fail "embedded Core Lua imports a network-capable module"
fi

scan_entitlements() {
  local signed_path="$1"
  : >"${scratch_root}/entitlements"
  codesign -d --entitlements :- "${signed_path}" \
    >"${scratch_root}/entitlements" 2>/dev/null || true
  if has_network_entitlement "${scratch_root}/entitlements"; then
    return 13
  fi
  return 0
}

scan_macho() {
  local macho_path="$1"
  local allow_local_ipc="${2:-false}"
  if ! otool -L "${macho_path}" >"${scratch_root}/dependencies" 2>/dev/null; then
    return 20
  fi
  if rg -q --pcre2 "${binary_framework_pattern}" "${scratch_root}/dependencies"; then
    return 10
  fi
  if ! nm -u "${macho_path}" >"${scratch_root}/symbols" 2>/dev/null; then
    return 21
  fi
  if rg -q --pcre2 "${binary_symbol_pattern}" "${scratch_root}/symbols"; then
    return 11
  fi
  if [[ "${allow_local_ipc}" != true ]] &&
      rg -q --pcre2 "${binary_local_ipc_symbol_pattern}" "${scratch_root}/symbols"; then
    return 12
  fi
  scan_entitlements "${macho_path}"
}

report_macho_failure() {
  local status="$1"
  local label="$2"
  case "${status}" in
    10) fail "network framework found in App Mach-O: ${label}" ;;
    11) fail "network symbol found in App Mach-O: ${label}" ;;
    12) fail "local IPC symbol escaped the main executable: ${label}" ;;
    13) fail "network entitlement found in App Mach-O: ${label}" ;;
    *) fail "App Mach-O could not be inspected safely: ${label}" ;;
  esac
}

if ! scan_entitlements "${app_path}"; then
  fail "the App bundle declares a network entitlement"
fi

macho_count=0
input_executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
  "${app_path}/Contents/Info.plist" 2>/dev/null)" ||
  fail "the input-process executable identity is unavailable"
input_executable="${app_path}/Contents/MacOS/${input_executable_name}"
[[ -f "${input_executable}" ]] || fail "the input-process executable is missing"
while IFS= read -r -d '' candidate; do
  if ! description="$(file -b "${candidate}" 2>/dev/null)"; then
    fail "an App file could not be classified"
  fi
  [[ "${description}" == *Mach-O* ]] || continue
  ((macho_count += 1))
  label="${candidate#"${app_path}"/}"
  if [[ "${label}" == "${candidate}" ]]; then
    label="${candidate##*/}"
  fi
  allow_local_ipc=false
  [[ "${candidate}" == "${input_executable}" ]] && allow_local_ipc=true
  if scan_macho "${candidate}" "${allow_local_ipc}"; then
    continue
  else
    report_macho_failure "$?" "${label}"
  fi
done < <(
  find "${app_path}" \
    -path "${app_path}/Contents/Applications" -prune -o \
    -type f -print0
)

nm -u "${input_executable}" >"${scratch_root}/input-symbols" 2>/dev/null ||
  fail "the input-process symbols are unreadable"
actual_local_ipc_symbols="$(
  rg -o --pcre2 '_(socket|connect|send|accept|listen|bind)(?=[[:space:]@]|$)' \
    "${scratch_root}/input-symbols" | LC_ALL=C sort -u
)"
expected_local_ipc_symbols=$'_accept\n_bind\n_listen\n_send\n_socket'
[[ "${actual_local_ipc_symbols}" == "${expected_local_ipc_symbols}" ]] ||
  fail "the main executable changed its exact local IPC server symbol set"

(( macho_count > 0 )) || fail "the App bundle contains no Mach-O"
echo "verify_input_process_offline: PASS (${macho_count} Mach-O files)"
