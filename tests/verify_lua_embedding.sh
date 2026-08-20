#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
patch_file="${repo_root}/patches/librime-lua-linnet-state-lifetime.patch"
translator_patch="${repo_root}/patches/rime-ice-linnet-pinyin-tag-boundary.patch"
generator="${repo_root}/scripts/generate-linnet-lua-embedding"

fail() {
  echo "verify_lua_embedding: FAIL: $*" >&2
  exit 1
}

[[ -f "${patch_file}" && ! -L "${patch_file}" ]] ||
  fail "downstream patch is missing or unsafe"
[[ -f "${translator_patch}" && ! -L "${translator_patch}" ]] ||
  fail "pinyin tag-boundary patch is missing or unsafe"
if rg -n '(^\*\*\* |^--- /|^\+\+\+ /|/(U[s]ers|h[o]me)/)' "${patch_file}"; then
  fail "downstream patch contains an invalid directive or private absolute path"
fi
if rg -n '(^\*\*\* |^--- /|^\+\+\+ /|/(U[s]ers|h[o]me)/)' "${translator_patch}"; then
  fail "pinyin tag-boundary patch contains an invalid directive or private absolute path"
fi
expected_diff_headers="$(printf '%s\n' \
  'diff --git a/src/modules.cc b/src/modules.cc' \
  'diff --git a/src/lib/lua.cc b/src/lib/lua.cc')"
actual_diff_headers="$(rg '^diff --git ' "${patch_file}")"
[[ "${actual_diff_headers}" == "${expected_diff_headers}" ]] ||
  fail "downstream patch owns an unexpected source path"
expected_translator_headers="$(printf '%s\n' \
  'diff --git a/upstreams/rime-ice/lua/date_translator.lua b/upstreams/rime-ice/lua/date_translator.lua' \
  'diff --git a/upstreams/rime-ice/lua/uuid.lua b/upstreams/rime-ice/lua/uuid.lua')"
actual_translator_headers="$(rg '^diff --git ' "${translator_patch}")"
[[ "${actual_translator_headers}" == "${expected_translator_headers}" ]] ||
  fail "pinyin tag-boundary patch owns an unexpected source path"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/linnet-lua-embedding.XXXXXX")"
cleanup() {
  rm -rf -- "${scratch}"
}
trap cleanup EXIT

mkdir -p "${scratch}/plugin/src/lib"
cp "${repo_root}/build/upstreams/git/plugins/lua/src/modules.cc" \
  "${scratch}/plugin/src/modules.cc"
cp "${repo_root}/build/upstreams/git/plugins/lua/src/lib/lua.cc" \
  "${scratch}/plugin/src/lib/lua.cc"
env GIT_CEILING_DIRECTORIES="${repo_root}" \
  git -C "${scratch}/plugin" apply --no-index "${patch_file}" >/dev/null ||
  fail "downstream patch does not apply to pinned librime-lua"

patched_modules="${scratch}/plugin/src/modules.cc"
patched_lua="${scratch}/plugin/src/lib/lua.cc"
if rg -n 'dladdr|dli_fname|lstat|LUA_DIRSEP|get_(user|shared)_data_dir|rime\.lua|luaL_dofile' \
    "${patched_modules}" "${patched_lua}"; then
  fail "patched source retains a filesystem Lua execution path"
fi
rg -Fq '#include "linnet_embedded_lua.h"' "${patched_modules}" ||
  fail "patched loader does not consume the generated embedding"
rg -Fq 'LUA_PRELOAD_TABLE' "${patched_modules}" ||
  fail "patched loader does not register package.preload"

patched_sources="${scratch}/patched-sources"
mkdir -p "${patched_sources}/upstreams/rime-ice/lua"
cp "${repo_root}/upstreams/rime-ice/lua/date_translator.lua" \
  "${patched_sources}/upstreams/rime-ice/lua/date_translator.lua"
cp "${repo_root}/upstreams/rime-ice/lua/uuid.lua" \
  "${patched_sources}/upstreams/rime-ice/lua/uuid.lua"
/usr/bin/patch -f -s -F 0 -p1 -d "${patched_sources}" \
  -i "${translator_patch}" ||
  fail "pinyin tag-boundary patch does not apply exactly to pinned rime-ice"
test "$(rg -F -l 'seg:has_tag("linnet_pinyin")' \
  "${patched_sources}/upstreams/rime-ice/lua/date_translator.lua" \
  "${patched_sources}/upstreams/rime-ice/lua/uuid.lua" | wc -l | tr -d ' ')" -eq 2 ||
  fail "patched date/UUID translators do not own the pinyin tag boundary"
if rg -n 'M\.(date|time|week|datetime|timestamp|date_zh|date_en)' \
    "${patched_sources}/upstreams/rime-ice/lua/date_translator.lua"; then
  fail "the embedded date translator retained cross-session module state"
fi
for field in date time week datetime timestamp date_zh date_en; do
  rg -Fq "env.${field}" \
    "${patched_sources}/upstreams/rime-ice/lua/date_translator.lua" ||
    fail "the embedded date translator lost session-local ${field} state"
done

noenv_line="$(rg -n '"LUA_NOENV"' "${patched_lua}" | cut -d: -f1)"
openlibs_line="$(rg -n 'luaL_openlibs\(L\)' "${patched_lua}" | cut -d: -f1)"
[[ -n "${noenv_line}" && -n "${openlibs_line}" && \
  "${noenv_line}" -lt "${openlibs_line}" ]] ||
  fail "LUA_NOENV is not set before luaL_openlibs"

for required in \
  'lua_setfield(L, package_index, "path")' \
  'lua_setfield(L, package_index, "cpath")' \
  'lua_setfield(L, package_index, "loadlib")' \
  'lua_setfield(L, package_index, "searchers")' \
  'lua_setfield(L, package_index, "loaders")' \
  'lua_setglobal(L, "loadfile")' \
  'lua_setglobal(L, "dofile")'; do
  rg -Fq "${required}" "${patched_modules}" ||
    fail "patched Lua restrictions are incomplete: ${required}"
done

[[ -x "${generator}" ]] || fail "embedding generator is missing or not executable"
header_a="${scratch}/a/linnet_embedded_lua.h"
header_b="${scratch}/b/linnet_embedded_lua.h"
mkdir -p "${scratch}/a" "${scratch}/b"
"${generator}" "${header_a}"
"${generator}" "${header_b}"
cmp -s "${header_a}" "${header_b}" || fail "generator output is not deterministic"

ruby -rdigest -e '
  root, header_path, patched_root = ARGV
  expected = {
    "auto_phrase" => "data/linnet/lua/auto_phrase.lua",
    "calc_translator" => "upstreams/rime-ice/lua/calc_translator.lua",
    "convert_ar_num_to_zh" => "upstreams/rime-ice/lua/convert_ar_num_to_zh.lua",
    "corrector" => "upstreams/rime-ice/lua/corrector.lua",
    "date_translator" => "upstreams/rime-ice/lua/date_translator.lua",
    "force_gc" => "upstreams/rime-ice/lua/force_gc.lua",
    "pin_cand_filter" => "upstreams/rime-ice/lua/pin_cand_filter.lua",
    "search" => "upstreams/rime-ice/lua/search.lua",
    "unicode" => "upstreams/rime-ice/lua/unicode.lua",
    "uuid" => "upstreams/rime-ice/lua/uuid.lua",
  }
  header = File.binread(header_path)
  records = header.scan(%r{// LINNET_LUA_MODULE name=([^ ]+) source=([^ ]+) sha256=([0-9a-f]{64})\ninline constexpr unsigned char ([A-Za-z0-9_]+)\[\] = \{(.*?)\n\};}m)
  abort "module set differs" unless records.map(&:first).sort == expected.keys.sort
  records.each do |name, source, sha, _symbol, body|
    abort "source differs" unless expected.fetch(name) == source
    bytes = body.scan(/0x([0-9a-f]{2})/).flatten.map { |byte| byte.to_i(16) }.pack("C*")
    canonical_root = %w[date_translator uuid].include?(name) ? patched_root : root
    canonical = File.binread(File.join(canonical_root, source))
    abort "bytes differ: #{name}" unless bytes == canonical
    abort "digest differs: #{name}" unless sha == Digest::SHA256.hexdigest(canonical)
  end
' "${repo_root}" "${header_a}" "${patched_sources}" ||
  fail "generated bytes/provenance differ"

if rg -n 'lib/rime-plugins/lua|trusted_lua|/lua/\?\.lua' \
    "${repo_root}/scripts/stage-linnet-data" \
    "${repo_root}/Linnet.xcodeproj/project.pbxproj"; then
  fail "retired sibling Lua resource path remains"
fi

echo "verify_lua_embedding: PASS (exact deterministic bytes, preload-only source contract)"
