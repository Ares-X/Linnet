#!/usr/bin/env bash
#
# Verify the librime-lua static-state lifetime patch end to end.
#
# The patch (patches/librime-lua-linnet-state-lifetime.patch, tracked in
# upstreams.lock.json as downstream_patches.librime_lua_state_lifetime)
# makes the shared Lua object process-lifetime and replaces every filesystem
# loader with ten generated package.preload modules.
#
# This script verifies, in order:
#
#   1. The patch is registered in upstreams.lock.json and the on-disk
#      digest matches the lock (the build contract).
#   2. The built librime-lua.dylib was actually compiled from the patched
#      source: rime_lua_initialize() must contain the function-local-static
#      guard sequence (__cxa_guard_acquire + __cxa_atexit destructor
#      registration + __cxa_guard_release). The unpatched code has none of
#      these in that function. (The static's own symbol is merged into the
#      __MergedGlobals anonymous section by the compiler, so symbol-name
#      checks are unreliable; the guard-call sequence is.)
#   3. Core and Xcode contain no Lua resource directory; the exact ten modules
#      are generated into the dylib build source.
#   4. A Lua-using schema (lua_translator@*date_translator) deploys with
#      malicious user/shared rime.lua and lua modules planted as sentinels.
#   5. The Lua lifetime probe (tests/fixtures/lua_lifetime_probe.cc) runs
#      repeated RimeInitialize -> type "rq" (Lua date candidates) ->
#      RimeFinalize -> re-initialize cycles, including the finalize-with-
#      live-composition variant that crashed before the mitigation. A crash
#      (SIGSEGV/SIGABRT) or a wrong Lua result fails the script.
#
# Prerequisites: scripts/build-rime-runtime has been run so
# librime/dist contains the patched runtime.
#
# Usage: tests/verify_lua_lifetime.sh

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
dist="${repo_root}/librime/dist"

fail() {
  echo "verify_lua_lifetime: FAIL: $*" >&2
  exit 1
}
info() {
  echo "verify_lua_lifetime: $*"
}

# --- 1. lock registration and digest ---------------------------------------

lock="${repo_root}/upstreams.lock.json"
patch_file="${repo_root}/patches/librime-lua-linnet-state-lifetime.patch"
[[ -f "${lock}" ]] || fail "lock file is missing: ${lock}"
[[ -f "${patch_file}" ]] || fail "patch file is missing: ${patch_file}"

locked_sha="$(ruby -rjson -e '
  j = JSON.parse(File.read(ARGV.fetch(0)))
  puts j.fetch("downstream_patches").fetch("librime_lua_state_lifetime").fetch("sha256")
' "${lock}")"
actual_sha="$(shasum -a 256 "${patch_file}" | awk '{print $1}')"
[[ "${actual_sha}" == "${locked_sha}" ]] ||
  fail "patch digest differs from lock (run scripts/upstream-sync verify)"
info "patch registered in upstreams.lock.json; digest matches (${locked_sha:0:16}...)"

# --- 2. deterministic embedded source owner -------------------------------

"${repo_root}/tests/verify_lua_embedding.sh" >/dev/null ||
  fail "embedded Lua source contract failed"
info "patched source has exact deterministic package.preload modules"

# --- 3. no Lua resource projection ----------------------------------------

[[ ! -e "${repo_root}/lib/rime-plugins/lua" && \
  ! -L "${repo_root}/lib/rime-plugins/lua" ]] ||
  fail "retired sibling Lua resource directory remains"
[[ ! -e "${repo_root}/data/plum/lua" && ! -L "${repo_root}/data/plum/lua" ]] ||
  fail "staged language data still owns Lua"
pbx="${repo_root}/Linnet.xcodeproj/project.pbxproj"
if rg -n 'lib/rime-plugins/lua|lua in Copy Rime plugins' "${pbx}"; then
  fail "Xcode still copies a Lua resource directory"
fi
info "Core, language data, and Xcode own no Lua resource directory"

# --- 4. built binary carries the static-state code -------------------------

lua_plugin="${dist}/lib/rime-plugins/librime-lua.dylib"
[[ -f "${lua_plugin}" ]] ||
  fail "librime-lua.dylib is missing (run scripts/build-rime-runtime first)"

# The static Lua state's guard sequence lives inside rime_lua_initialize().
# Locate the function's address range, then require __cxa_guard_acquire and
# __cxa_atexit stub calls within it.
func_start="$(nm "${lua_plugin}" | awk \
  '$2 == "t" && $3 == "__ZL19rime_lua_initializev" && !found {print $1; found = 1}')"
[[ -n "${func_start}" ]] || fail "rime_lua_initialize not found in the dylib"
# Scan to EOF (an early exit would SIGPIPE sort under pipefail) and keep the
# first text symbol after func_start.
func_end="$(nm "${lua_plugin}" | sort | awk -v s="${func_start}" \
  '$1 > s && $2 ~ /^[tT]$/ && !found {print $1; found = 1}')"
[[ -n "${func_end}" ]] || fail "could not bound rime_lua_initialize"

guard_stub="$(otool -Iv "${lua_plugin}" | awk \
  '$NF == "___cxa_guard_acquire" && !found {print $1; found = 1}')"
atexit_stub="$(otool -Iv "${lua_plugin}" | awk \
  '$NF == "___cxa_atexit" && !found {print $1; found = 1}')"
[[ -n "${guard_stub}" && -n "${atexit_stub}" ]] ||
  fail "guard/atexit stubs not found in dylib"
guard_hex="$(printf '%x' "0x${guard_stub#0x}")"
atexit_hex="$(printf '%x' "0x${atexit_stub#0x}")"

disasm="$(mktemp "${TMPDIR:-/tmp}/lua-init-disasm.XXXXXX")"
xcrun llvm-objdump --disassemble --start-address="0x${func_start}" \
  --stop-address="0x${func_end}" "${lua_plugin}" > "${disasm}" ||
  fail "disassembly failed"
guard_calls="$(grep -c "bl[[:space:]]0x${guard_hex}" "${disasm}" || true)"
atexit_calls="$(grep -c "bl[[:space:]]0x${atexit_hex}" "${disasm}" || true)"
[[ "${guard_calls}" -ge 1 && "${atexit_calls}" -ge 1 ]] ||
  fail "rime_lua_initialize lacks the function-local-static guard sequence \
(guard_calls=${guard_calls}, atexit_calls=${atexit_calls}); rebuild with \
scripts/build-rime-runtime"
info "built dylib contains the static Lua state (guard + atexit in rime_lua_initialize)"

# --- 5. deploy a Lua-using schema ------------------------------------------

deployer="${dist}/bin/rime_deployer"
[[ -x "${deployer}" ]] || fail "rime_deployer is missing"
probe_source="${repo_root}/tests/fixtures/lua_lifetime_probe.cc"
schema_source="${repo_root}/tests/fixtures/lua_date_test.schema.yaml"
unknown_schema_source="${repo_root}/tests/fixtures/lua_unknown_test.schema.yaml"
[[ -f "${probe_source}" && -f "${schema_source}" && \
  -f "${unknown_schema_source}" ]] ||
  fail "test fixture is missing"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/linnet-lua-lifetime.XXXXXX")"
cleanup() {
  rm -rf -- "${scratch}" "${disasm:-}"
}
trap cleanup EXIT

shared="${scratch}/shared"
user="${scratch}/user"
runtime="${scratch}/runtime"
runtime_lib="${runtime}/lib"
runtime_plugins="${runtime_lib}/rime-plugins"
env_lua="${scratch}/env-lua"
env_c="${scratch}/env-c"
empty_lua="${scratch}/empty-lua"
mkdir -p "${shared}/lua" "${user}/lua" "${runtime_plugins}/lua" \
  "${env_lua}" "${env_c}" "${empty_lua}"
cp "${dist}/lib/librime.1.dylib" "${runtime_lib}/"
cp "${lua_plugin}" "${runtime_plugins}/"

# These files cover every retired filesystem/environment loader. Each writes a
# unique marker before returning an invalid module; embedded Core must ignore
# all of them.
for sentinel in \
  "${user}/rime.lua:${scratch}/sentinel-executed-user-rime" \
  "${shared}/rime.lua:${scratch}/sentinel-executed-shared-rime" \
  "${user}/lua/date_translator.lua:${scratch}/sentinel-executed-user-module" \
  "${shared}/lua/date_translator.lua:${scratch}/sentinel-executed-shared-module" \
  "${runtime_plugins}/lua/rime.lua:${scratch}/sentinel-executed-sibling-rime" \
  "${runtime_plugins}/lua/date_translator.lua:${scratch}/sentinel-executed-sibling-module" \
  "${env_lua}/unknown_module.lua:${scratch}/sentinel-executed-lua-path"; do
  sentinel_source="${sentinel%%:*}"
  sentinel_marker="${sentinel#*:}"
  cat > "${sentinel_source}" <<LUA
local marker = assert(io.open("${sentinel_marker}", "w"))
marker:write("executed")
marker:close()
error("writable Lua sentinel executed")
LUA
done

cat > "${scratch}/unknown_module.c" <<C
#include <stdio.h>
#include <lua.h>
__attribute__((constructor)) static void mark_loaded(void) {
  FILE *marker = fopen("${scratch}/sentinel-executed-lua-cpath", "w");
  if (marker) { fputs("executed", marker); fclose(marker); }
}
int luaopen_unknown_module(lua_State *L) { lua_newtable(L); return 1; }
C
xcrun clang -dynamiclib -Wall -Wextra -Werror \
  -I"${repo_root}/build/upstreams/git/plugins/lua-thirdparty/lua5.4" \
  -undefined dynamic_lookup "${scratch}/unknown_module.c" \
  -o "${env_c}/unknown_module.so" || fail "malicious C loader fixture compilation failed"

# Raw schema + minimal default; the session resolver reads <shared>/<id>.schema.yaml.
cp "${schema_source}" "${shared}/lua_date_test.schema.yaml"
cp "${unknown_schema_source}" "${shared}/lua_unknown_test.schema.yaml"
cat > "${shared}/default.yaml" <<'YAML'
# Minimal default for the Lua lifetime verification (tests/verify_lua_lifetime.sh).
config_version: "2026.08.08"
schema_list:
  - schema: lua_date_test
  - schema: lua_unknown_test
ascii_composer:
  switch_key:
    Shift_L: inline_ascii
    Shift_R: commit_code
    Control_L: noop
    Control_R: noop
    Caps_Lock: clear
YAML

info "deploying lua_date_test with rime_deployer"
DYLD_FALLBACK_LIBRARY_PATH="${dist}/lib" \
  "${deployer}" --build "${user}" "${shared}" >/dev/null ||
  fail "rime_deployer --build failed"
[[ -f "${user}/build/lua_date_test.schema.yaml" ]] ||
  fail "deploy produced no compiled schema"
[[ -z "$(find "${scratch}" -maxdepth 1 -name 'sentinel-executed-*' -print -quit)" ]] ||
  fail "rime_deployer executed a writable Lua sentinel"

# --- 6. run the Lua lifetime probe -----------------------------------------

probe="${scratch}/lua_lifetime_probe"
clang++ -std=c++17 -O0 -g \
  -I"${dist}/include" \
  -Wl,-rpath,"${runtime_lib}" -Wl,-rpath,"${runtime_plugins}" \
  "${probe_source}" "${runtime_lib}/librime.1.dylib" \
  "${runtime_plugins}/librime-lua.dylib" -o "${probe}" ||
  fail "probe compilation failed"

info "running embedded Lua probe against malicious Lua path and sibling roots"
DYLD_LIBRARY_PATH="${runtime_lib}:${runtime_plugins}" \
LUA_PATH="${env_lua}/?.lua" LUA_CPATH="${env_c}/?.so" \
  "${probe}" "${shared}" "${user}" || fail "Lua-path lifetime probe failed"
[[ -z "$(find "${scratch}" -maxdepth 1 -name 'sentinel-executed-*' -print -quit)" ]] ||
  fail "native probe executed a filesystem/environment Lua sentinel"

info "running embedded Lua probe against malicious C path only"
DYLD_LIBRARY_PATH="${runtime_lib}:${runtime_plugins}" \
LUA_PATH="${empty_lua}/?.lua" LUA_CPATH="${env_c}/?.so" \
  "${probe}" "${shared}" "${user}" || fail "Lua-C-path lifetime probe failed"
[[ -z "$(find "${scratch}" -maxdepth 1 -name 'sentinel-executed-*' -print -quit)" ]] ||
  fail "native probe executed a C loader sentinel"
info "PASS: embedded-only Lua, unknown modules fail closed, lifetime survives"
