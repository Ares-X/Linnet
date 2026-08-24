#!/usr/bin/env bash

# Native engine acceptance for the staged product data. This is intentionally
# one real librime deployment and one smoke process; profile and grammar matrices
# have their own focused gates and are not repeated here.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

runtime_probe="${1:-}"
if [[ "${1:-}" == --mixed-input-probe ||
      "${1:-}" == --mixed-latency-probe ]]; then
  :
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--mixed-input-probe|--mixed-latency-probe]" >&2
  exit 64
fi

scratch="$(mktemp -d /tmp/linnet-rime-runtime.XXXXXX)"
cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  [[ "${scratch}" == /tmp/linnet-rime-runtime.* ]] && /bin/rm -rf -- "${scratch}"
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

shared="${scratch}/shared"
user="${scratch}/user"
logs="${scratch}/logs"
mkdir -p "${shared}/opencc" "${user}" "${logs}"
cp -R data/plum/. "${shared}/"
# The ignored data/plum directory is a generated cache and can legitimately
# predate the current source checkout. Native acceptance must consume the
# canonical default owner, just as packaging does when it stages a candidate.
cp data/linnet/default.yaml "${shared}/default.yaml"
# Core-only updates deliberately keep the installed language pack. Reproduce
# build 10's old Active owner so the native suite proves the Core projection,
# not a coincidentally current pack, retires the hidden / and ~ raw prefixes.
ruby -e '
  path = ARGV.fetch(0)
  source = File.binread(path)
  placeholder = "    zz_code_token: \"^$\"\n"
  stale = "    zz_code_token: \"^(?:(?:/|~).*|(?:www[.]|https?:|ftp[.:]|mailto:|file:).*)$\"\n"
  abort "Core compile placeholder is missing" unless source.scan(placeholder).length == 1
  File.binwrite(path, source.sub(placeholder, stale))
' "${shared}/default.yaml"
cp data/linnet/linnet_zh.schema.yaml "${shared}/linnet_zh.schema.yaml"
cp data/linnet/linnet_en.schema.yaml "${shared}/linnet_en.schema.yaml"
cp -R data/opencc/. "${shared}/opencc/"
cp tests/fixtures/linnet_pinyin_limit.dict.yaml \
  tests/fixtures/linnet_pinyin_limit_algebra.yaml \
  tests/fixtures/linnet_pinyin_limit_64.schema.yaml \
  tests/fixtures/linnet_pinyin_limit_65.schema.yaml "${shared}/"
cp tests/fixtures/linnet_user.yaml \
  tests/fixtures/linnet_custom_words.txt \
  tests/fixtures/linnet_text_expander.txt "${user}/"

swiftc="$(xcrun --find swiftc)"
sdk="$(xcrun --show-sdk-path)"
"${swiftc}" -warnings-as-errors -sdk "${sdk}" \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetSettings/PersonalDataStore.swift \
  sources/LinnetSettings/LinnetSettingsDocument.swift \
  sources/LinnetSettings/LinnetSettingsProjectionRenderer.swift \
  tests/LinnetSettingsProjectionFixture.swift \
  -o "${scratch}/projection-fixture"
"${scratch}/projection-fixture" default "${user}"
test "$(rg -F -c '"ascii_composer/switch_key/Caps_Lock": commit_text' \
  "${user}/default.custom.yaml")" -eq 1
test "$(rg -F -c '"linnet/recognizer_patterns/zz_code_token"' \
  "${user}/default.custom.yaml")" -eq 1

# These two profiles deliberately override the default document after the
# production renderer has installed the Core-owned policy projection.
cp tests/fixtures/linnet_zh_pipe.custom.yaml \
  "${user}/linnet_zh_jiajia.custom.yaml"
cp tests/fixtures/linnet_zh_pipe.custom.yaml \
  "${user}/linnet_zh_mspy.custom.yaml"

make --no-print-directory smart-english-plugin
make --no-print-directory verify-rime-binaries
RIME_LOG_DIR="${logs}" \
DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
  bin/rime_deployer --build "${user}" "${shared}" "${user}/build" >/dev/null
for fixture_schema in \
  linnet_pinyin_limit_64.schema.yaml \
  linnet_pinyin_limit_65.schema.yaml; do
  DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
    bin/rime_deployer --compile "${shared}/${fixture_schema}" \
      "${user}" "${shared}" "${user}/build" >/dev/null
done

cxx="$(xcrun --find clang++)"
"${cxx}" -isysroot "${sdk}" -std=c++17 -O2 -Wall -Wextra -Werror \
  -DGLOG_USE_GLOG_EXPORT -isystem librime/dist/include \
  -isystem build/dependencies/boost tests/rime_smoke_test.cc \
  plugins/smart_english/smart_english_index.cc \
  lib/librime.1.dylib lib/rime-plugins/librime-lua.dylib \
  lib/rime-plugins/librime-predict.dylib -o "${scratch}/rime-smoke"

smoke_args=("${shared}" "${user}")
if [[ -n "${runtime_probe}" ]]; then
  smoke_args+=("${runtime_probe}")
fi
if ! DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
    "${scratch}/rime-smoke" "${smoke_args[@]}" \
    >"${scratch}/stdout" 2>"${scratch}/stderr"; then
  tail -n 160 "${scratch}/stdout" >&2 || true
  tail -n 160 "${scratch}/stderr" >&2 || true
  exit 1
fi

if [[ -n "${runtime_probe}" ]]; then
  cat "${scratch}/stdout"
  if [[ "${runtime_probe}" == --mixed-latency-probe ]]; then
    echo "Linnet native Rime mixed-input latency measurement: COMPLETE"
  else
    echo "Linnet native Rime focused mixed-input probe: PASS"
  fi
  exit 0
fi

rg -Fq 'shared PredictEngine factory/engine identity: PASS' "${scratch}/stdout"
test "$(LC_ALL=C grep -a -F -c 'loading predict db:' "${scratch}/stderr")" -eq 1

# Exercise librime's canonical multi-device user-dictionary merge. Linnet only
# schedules this upstream owner; it never interprets snapshot rows itself.
sync_root="${scratch}/rime-sync"
device_a="${scratch}/device-a"
device_b="${scratch}/device-b"
mkdir "${sync_root}" "${device_a}" "${device_b}"
"${swiftc}" -warnings-as-errors -sdk "${sdk}" \
  sources/LinnetSettings/LinnetRimeSyncController.swift \
  tests/LinnetRimeSyncProjectionFixture.swift \
  -o "${scratch}/rime-sync-projection"
for dictionary in linnet_zh linnet_en; do
  test -d "${user}/${dictionary}.userdb"
  cp -R "${user}/${dictionary}.userdb" "${device_a}/${dictionary}.userdb"
  cp -R "${user}/${dictionary}.userdb" "${device_b}/${dictionary}.userdb"
done
printf 'installation_id: device-a\n' >"${device_a}/installation.yaml"
printf 'installation_id: device-b\n' >"${device_b}/installation.yaml"
"${scratch}/rime-sync-projection" "${device_a}" "${sync_root}"
"${scratch}/rime-sync-projection" "${device_b}" "${sync_root}"
printf '# Rime user dictionary export\n云同步甲\tyun tong bu jia\t7\nlinnetclouda\tlinnetclouda\t7\n' \
  >"${scratch}/device-a-rows.txt"
printf '# Rime user dictionary export\n云同步乙\tyun tong bu yi\t9\nlinnetcloudb\tlinnetcloudb\t9\n' \
  >"${scratch}/device-b-rows.txt"
for dictionary in linnet_zh linnet_en; do
  (
    cd "${device_a}"
    DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
      "${repo_root}/bin/rime_dict_manager" --import "${dictionary}" \
        "${scratch}/device-a-rows.txt" >/dev/null
  )
  (
    cd "${device_b}"
    DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
      "${repo_root}/bin/rime_dict_manager" --import "${dictionary}" \
        "${scratch}/device-b-rows.txt" >/dev/null
  )
done
for device in "${device_a}" "${device_b}" "${device_a}"; do
  (
    cd "${device}"
    DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
      "${repo_root}/bin/rime_dict_manager" --sync >/dev/null
  )
done
for dictionary in linnet_zh linnet_en; do
  export_file="${scratch}/${dictionary}-merged.txt"
  (
    cd "${device_a}"
    DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
      "${repo_root}/bin/rime_dict_manager" --export "${dictionary}" \
        "${export_file}" >/dev/null
  )
  rg -Fq $'云同步甲\t' "${export_file}"
  rg -Fq $'云同步乙\t' "${export_file}"
  rg -Fq $'linnetclouda\t' "${export_file}"
  rg -Fq $'linnetcloudb\t' "${export_file}"
done
echo "Linnet upstream multi-device user dictionary sync: PASS"

# Exercise the production-shaped exact-11 configuration reload in its own
# user directory so its same-second projections and session invalidation never
# become implicit setup for the remaining Settings/runtime matrix.
fast_user="${scratch}/fast-user"
mkdir "${fast_user}"
cp -R "${user}/." "${fast_user}/"
DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
  "${scratch}/rime-smoke" "${shared}" "${fast_user}" \
    --fast-config-reload-probe

profile_cases=(
  'natural:linnet_zh:srfa:semicolon'
  'full_pinyin:linnet_zh_pinyin:suanfa:semicolon'
  'flypy:linnet_zh_flypy:srfa:semicolon'
  'microsoft:linnet_zh_mspy:srfa:vertical_bar'
  'sogou:linnet_zh_sogou:srfa:semicolon'
  'abc:linnet_zh_abc:spfa:semicolon'
  'ziguang:linnet_zh_ziguang:slfa:semicolon'
  'jiajia:linnet_zh_jiajia:scfa:vertical_bar'
)
for profile_case in "${profile_cases[@]}"; do
  IFS=: read -r profile schema code trigger <<<"${profile_case}"
  "${scratch}/projection-fixture" profile "${profile}" "${trigger}" "${user}"
  DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
    bin/rime_deployer --build "${user}" "${shared}" "${user}/build" >/dev/null
  rg -Fq "prism: ${schema}" "${user}/build/linnet_en.schema.yaml"
  rg -Fq "chinese_schema: ${schema}" "${user}/build/linnet_en.schema.yaml"
  test -s "${user}/build/${schema}.prism.bin"
  prefix=';'
  [[ "${trigger}" == vertical_bar ]] && prefix='|'
  DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
    "${scratch}/rime-smoke" "${shared}" "${user}" \
      --english-profile-probe "${profile}" "${schema}" "${code}" "${prefix}" >/dev/null
done

for page_size in 3 5 7 9; do
  "${scratch}/projection-fixture" page-size "${page_size}" "${user}"
  DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
    bin/rime_deployer --build "${user}" "${shared}" "${user}/build" >/dev/null
  DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
    "${scratch}/rime-smoke" "${shared}" "${user}" \
      --page-size-probe "${page_size}" >/dev/null
done

"${scratch}/projection-fixture" english-learning-off "${user}"
DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
  bin/rime_deployer --build "${user}" "${shared}" "${user}/build" >/dev/null
rg -Fq 'prism: linnet_zh_jiajia' "${user}/build/linnet_en.schema.yaml"
rg -Fq 'chinese_schema: linnet_zh_jiajia' "${user}/build/linnet_en.schema.yaml"
rg -Fq 'enable_user_dict: false' "${user}/build/linnet_en.schema.yaml"
rg -Fq 'learning_enabled: false' "${user}/build/linnet_en.schema.yaml"
DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
  "${scratch}/rime-smoke" "${shared}" "${user}" \
    --learning-off-probe >/dev/null

"${scratch}/projection-fixture" english-suggestions-off "${user}"
DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
  bin/rime_deployer --build "${user}" "${shared}" "${user}/build" >/dev/null
rg -Fq 'prism: linnet_zh_jiajia' "${user}/build/linnet_en.schema.yaml"
rg -Fq 'chinese_schema: linnet_zh_jiajia' "${user}/build/linnet_en.schema.yaml"
rg -Fq 'reset: 0' "${user}/build/linnet_en.schema.yaml"
rg -Fq 'spelling_correction: false' "${user}/build/linnet_en.schema.yaml"
rg -Fq 'show_ipa: false' "${user}/build/linnet_en.schema.yaml"
rg -Fq 'show_translation: false' "${user}/build/linnet_en.schema.yaml"
DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
  "${scratch}/rime-smoke" "${shared}" "${user}" \
    --settings-off-probe >/dev/null

"${scratch}/projection-fixture" input-options "${user}"
test -s "${user}/linnet_user.custom.yaml"
test ! -e "${user}/linnet_user.yaml"
rg -Fq '    - "hello"' "${user}/linnet_user.custom.yaml"
! rg -Fq 'sentence_capitalization' "${user}/linnet_user.custom.yaml"
! rg -Fq 'tab_behavior' "${user}/linnet_user.custom.yaml"
for settings_schema in \
  linnet_zh linnet_zh_pinyin linnet_zh_flypy linnet_zh_mspy \
  linnet_zh_sogou linnet_zh_abc linnet_zh_ziguang linnet_zh_jiajia \
  linnet_en; do
  test -s "${user}/${settings_schema}.custom.yaml"
  rg -Fq '"linnet_english_interaction/sentence_capitalization": false' \
    "${user}/${settings_schema}.custom.yaml"
  rg -Fq '"linnet_english_interaction/tab_behavior": "pass"' \
    "${user}/${settings_schema}.custom.yaml"
  rg -Fq '"linnet_english_interaction/space_adds_trailing_space": false' \
    "${user}/${settings_schema}.custom.yaml"
done
DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
  bin/rime_deployer --build "${user}" "${shared}" "${user}/build" >/dev/null
for chinese_schema in \
  linnet_zh linnet_zh_pinyin linnet_zh_flypy linnet_zh_mspy \
  linnet_zh_sogou linnet_zh_abc linnet_zh_ziguang linnet_zh_jiajia; do
  rg -Fq 'reset: 1' "${user}/build/${chinese_schema}.schema.yaml"
  rg -Fq 'prefix: "|"' "${user}/build/${chinese_schema}.schema.yaml"
done
rg -Fq 'prism: linnet_zh_pinyin' "${user}/build/linnet_en.schema.yaml"
rg -Fq 'chinese_schema: linnet_zh_pinyin' "${user}/build/linnet_en.schema.yaml"
rg -Fq 'prefix: "|"' "${user}/build/linnet_en.schema.yaml"
DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
  "${scratch}/rime-smoke" "${shared}" "${user}" \
    --input-options-probe >/dev/null

"${scratch}/projection-fixture" input-switches "${user}"
DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
  bin/rime_deployer --build "${user}" "${shared}" "${user}/build" >/dev/null
for chinese_schema in \
  linnet_zh linnet_zh_pinyin linnet_zh_flypy linnet_zh_mspy \
  linnet_zh_sogou linnet_zh_abc linnet_zh_ziguang linnet_zh_jiajia; do
  rg -Fq '"switches/@1/reset": 1' "${user}/${chinese_schema}.custom.yaml"
  rg -Fq '"switches/@3/reset": 0' "${user}/${chinese_schema}.custom.yaml"
  rg -Fq '"switches/@4/reset": 1' "${user}/${chinese_schema}.custom.yaml"
done
DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
  "${scratch}/rime-smoke" "${shared}" "${user}" \
    --input-switches-probe >/dev/null

echo "Linnet native Rime runtime: PASS (Chinese, 8-profile Smart English, direct Shift, Caps Lock raw, learning, graphical English and input settings)"
