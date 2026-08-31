#!/usr/bin/env bash

# Native engine acceptance for the staged product data. This is intentionally
# one real librime deployment and one smoke process; profile and grammar matrices
# have their own focused gates and are not repeated here.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

runtime_probe="${1:-}"
if [[ "${1:-}" == --mixed-input-probe ||
      "${1:-}" == --mixed-latency-probe ||
      "${1:-}" == --warm-session-probe ||
      "${1:-}" == --cold-client-probe ||
      "${1:-}" == --profile-key-matrix-probe ||
      "${1:-}" == --live-sync-probe ]]; then
  :
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--mixed-input-probe|--mixed-latency-probe|--warm-session-probe|--cold-client-probe|--profile-key-matrix-probe|--live-sync-probe]" >&2
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

phase_started=0
begin_phase() {
  phase_started="${SECONDS}"
  printf '==> Rime runtime: %s\n' "$1"
}
end_phase() {
  printf '<== Rime runtime: PASS in %ss: %s\n' \
    "$((SECONDS - phase_started))" "$1"
}

begin_phase "stage isolated product data"
shared="${scratch}/shared"
user="${scratch}/user"
logs="${scratch}/logs"
mkdir -p "${shared}/opencc" "${user}" "${logs}"
cp -R data/plum/. "${shared}/"
# The ignored data/plum directory is a generated cache and can legitimately
# predate the current source checkout. Native acceptance must consume the
# canonical public schemas and default owner, just as packaging does when it
# stages a candidate. No wrapper profile may be accepted from an old cache.
for schema in data/linnet/*.schema.yaml; do
  cp "${schema}" "${shared}/$(basename "${schema}")"
done
cp data/linnet/default.yaml "${shared}/default.yaml"
# Core-only updates deliberately keep the installed language pack. Reproduce
# old Active owners so the native suite proves the Core projections, not a
# coincidentally current pack, retire stale routing and schema defaults.
ruby -e '
  path = ARGV.fetch(0)
  source = File.binread(path)
  placeholder = "    zz_code_token: \"^$\"\n"
  stale = "    zz_code_token: \"^(?:(?:/|~).*|(?:www[.]|https?:|ftp[.:]|mailto:|file:).*)$\"\n"
  current_shift = "    Shift_L: commit_code\n    Shift_R: commit_code\n"
  stale_shift = "    Shift_L: commit_text\n    Shift_R: commit_text\n"
  current_schemas = "  - schema: linnet_zh_pinyin\n  - schema: linnet_zh\n"
  stale_schemas = "  - schema: linnet_zh\n  - schema: linnet_zh_pinyin\n"
  abort "Core compile placeholder is missing" unless source.scan(placeholder).length == 1
  abort "current Shift policy is missing" unless source.scan(current_shift).length == 1
  abort "current schema order is missing" unless source.scan(current_schemas).length == 1
  File.binwrite(
    path,
    source.sub(placeholder, stale)
      .sub(current_shift, stale_shift)
      .sub(current_schemas, stale_schemas)
  )
' "${shared}/default.yaml"
cp data/linnet/linnet_algebra.yaml "${shared}/linnet_algebra.yaml"
ruby -e '
  path = ARGV.fetch(0)
  source = File.binread(path)
  current_prism = "  prism: linnet_zh_pinyin\n"
  current_return = "  chinese_schema: linnet_zh_pinyin\n"
  abort "current full-pinyin Prism is missing" unless source.scan(current_prism).length == 1
  abort "current full-pinyin return is missing" unless source.scan(current_return).length == 1
  File.binwrite(
    path,
    source.sub(current_prism, "  prism: linnet_zh\n")
      .sub(current_return, "  chinese_schema: linnet_zh\n")
  )
' "${shared}/linnet_en.schema.yaml"
cp -R data/opencc/. "${shared}/opencc/"
cp tests/fixtures/linnet_pinyin_limit.dict.yaml \
  tests/fixtures/linnet_pinyin_limit_algebra.yaml \
  tests/fixtures/linnet_pinyin_limit_64.schema.yaml \
  tests/fixtures/linnet_pinyin_limit_65.schema.yaml "${shared}/"
cp tests/fixtures/linnet_user.yaml \
  tests/fixtures/linnet_custom_words.txt \
  tests/fixtures/linnet_text_expander.txt "${user}/"
end_phase "stage isolated product data"

begin_phase "compile Settings projection fixture"
swiftc="$(xcrun --find swiftc)"
sdk="$(xcrun --show-sdk-path)"
"${swiftc}" -warnings-as-errors -sdk "${sdk}" \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDirectoryDelta.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetSettings/PersonalDataStore.swift \
  sources/LinnetSettings/PersonalDataValidation.swift \
  sources/LinnetSettings/LinnetSettingsDocument.swift sources/LinnetSettings/LinnetSettingsDocumentStore.swift \
  sources/LinnetSettings/LinnetSettingsProjectionRenderer.swift \
  tests/LinnetSettingsProjectionFixture.swift \
  -o "${scratch}/projection-fixture"
"${scratch}/projection-fixture" default "${user}"
for switch_key in Caps_Lock Shift_L Shift_R; do
  test "$(rg -F -c \
    "\"ascii_composer/switch_key/${switch_key}\": commit_code" \
    "${user}/default.custom.yaml")" -eq 1
done
test "$(rg -F -c '"linnet/recognizer_patterns/zz_code_token"' \
  "${user}/default.custom.yaml")" -eq 1
end_phase "compile Settings projection fixture"

begin_phase "deploy native schemas"
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
end_phase "deploy native schemas"

begin_phase "compile native smoke harnesses"
cxx="$(xcrun --find clang++)"
"${cxx}" -isysroot "${sdk}" -std=c++17 -O2 -Wall -Wextra -Werror \
  -DGLOG_USE_GLOG_EXPORT -isystem librime/dist/include \
  -isystem build/dependencies/boost tests/rime_smoke_test.cc \
  plugins/smart_english/smart_english_index.cc \
  lib/librime.1.dylib lib/rime-plugins/librime-lua.dylib \
  lib/rime-plugins/librime-predict.dylib -o "${scratch}/rime-smoke"

# Reuse the canonical Chinese learning probe only where the mixed-input matrix
# consumes it. The learned phrase is written later to an isolated user root so
# it cannot perturb the general candidate-ranking matrix above.
if [[ -z "${runtime_probe}" || "${runtime_probe}" == --mixed-input-probe ]]; then
  "${cxx}" -isysroot "${sdk}" -std=c++17 -O2 -Wall -Wextra -Werror \
    -isystem librime/dist/include tests/auto_phrase_probe.cc \
    lib/librime.1.dylib lib/rime-plugins/librime-lua.dylib \
    -o "${scratch}/auto-phrase-probe"
fi
end_phase "compile native smoke harnesses"

begin_phase "run native candidate matrix"
smoke_args=("${shared}" "${user}")
if [[ -n "${runtime_probe}" ]]; then
  smoke_args+=("${runtime_probe}")
fi
if ! DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
    "${scratch}/rime-smoke" "${smoke_args[@]}" \
    2>"${scratch}/stderr" | tee "${scratch}/stdout"; then
  tail -n 160 "${scratch}/stdout" >&2 || true
  tail -n 160 "${scratch}/stderr" >&2 || true
  exit 1
fi
end_phase "run native candidate matrix"

if [[ -z "${runtime_probe}" || "${runtime_probe}" == --mixed-input-probe ]]; then
  begin_phase "verify mixed-input learning policy"
  mixed_learning_on_user="${scratch}/mixed-learning-on-user"
  mkdir "${mixed_learning_on_user}"
  cp -R "${user}/." "${mixed_learning_on_user}/"
  printf 'learn 霜河栈 shuanghezhan 霜 河 栈\n' | \
    DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
      "${scratch}/auto-phrase-probe" "${shared}" \
        "${mixed_learning_on_user}" linnet_zh_pinyin >/dev/null
  DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
    "${scratch}/rime-smoke" "${shared}" "${mixed_learning_on_user}" \
      --mixed-learning-on-probe >/dev/null

  mixed_learning_off_user="${scratch}/mixed-learning-off-user"
  mkdir "${mixed_learning_off_user}"
  cp -R "${mixed_learning_on_user}/." "${mixed_learning_off_user}/"
  "${scratch}/projection-fixture" chinese-learning disabled \
    "${mixed_learning_off_user}"
  DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
    bin/rime_deployer --build "${mixed_learning_off_user}" "${shared}" \
      "${mixed_learning_off_user}/build" >/dev/null
  rg -Fq 'enable_user_dict: false' \
    "${mixed_learning_off_user}/build/linnet_zh_pinyin.schema.yaml"
  DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
    "${scratch}/rime-smoke" "${shared}" "${mixed_learning_off_user}" \
      --mixed-learning-off-probe >/dev/null
  end_phase "verify mixed-input learning policy"
fi

if [[ -n "${runtime_probe}" ]]; then
  if [[ "${runtime_probe}" == --mixed-latency-probe ]]; then
    echo "Linnet native Rime mixed-input latency measurement: COMPLETE"
  elif [[ "${runtime_probe}" == --warm-session-probe ]]; then
    echo "Linnet native Rime retained warm-session latency: PASS"
  elif [[ "${runtime_probe}" == --cold-client-probe ]]; then
    echo "Linnet native Rime cold-client first-key latency: PASS"
  elif [[ "${runtime_probe}" == --profile-key-matrix-probe ]]; then
    echo "Linnet native Rime formal eight-profile key matrix: PASS"
  elif [[ "${runtime_probe}" == --live-sync-probe ]]; then
    echo "Linnet native Rime live synchronization: PASS"
  else
    echo "Linnet native Rime focused mixed-input probe: PASS"
  fi
  exit 0
fi

rg -Fq 'shared PredictEngine factory/engine identity: PASS' "${scratch}/stdout"
test "$(LC_ALL=C grep -a -F -c 'loading predict db:' "${scratch}/stderr")" -eq 1

lifecycle_user="${scratch}/lifecycle-user"
mkdir "${lifecycle_user}"
cp -R "${user}/." "${lifecycle_user}/"

# Exercise librime's canonical multi-device user-dictionary merge. Linnet only
# schedules this upstream owner; it never interprets snapshot rows itself.
begin_phase "verify upstream user-dictionary sync"
sync_root="${scratch}/rime-sync"
device_a="${scratch}/device-a"
device_b="${scratch}/device-b"
mkdir "${sync_root}" "${device_a}" "${device_b}"
for dictionary in linnet_zh linnet_en; do
  test -d "${user}/${dictionary}.userdb"
  cp -R "${user}/${dictionary}.userdb" "${device_a}/${dictionary}.userdb"
  cp -R "${user}/${dictionary}.userdb" "${device_b}/${dictionary}.userdb"
done
printf 'installation_id: device-a\nsync_dir: "%s"\nbackup_config_files: false\n' \
  "${sync_root}" >"${device_a}/installation.yaml"
printf 'installation_id: device-b\nsync_dir: "%s"\nbackup_config_files: false\n' \
  "${sync_root}" >"${device_b}/installation.yaml"
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
live_sync_user="${scratch}/live-sync-user"
mkdir "${live_sync_user}"
cp -R "${user}/." "${live_sync_user}/"
DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
  "${scratch}/rime-smoke" "${shared}" "${live_sync_user}" --live-sync-probe
end_phase "verify upstream user-dictionary sync"

# Exercise the production-shaped exact-11 configuration reload in its own
# user directory so its same-second projections and session invalidation never
# become implicit setup for the remaining Settings/runtime matrix.
begin_phase "verify eight profiles and Settings projections"
fast_user="${scratch}/fast-user"
mkdir "${fast_user}"
cp -R "${user}/." "${fast_user}/"
DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
  "${scratch}/rime-smoke" "${shared}" "${fast_user}" \
    --fast-config-reload-probe

profile_cases=(
  'vertical_bar:natural:linnet_zh:srfa'
  'vertical_bar:full_pinyin:linnet_zh_pinyin:suanfa'
  'vertical_bar:flypy:linnet_zh_flypy:srfa'
  'vertical_bar:microsoft:linnet_zh_mspy:srfa'
  'vertical_bar:sogou:linnet_zh_sogou:srfa'
  'vertical_bar:abc:linnet_zh_abc:spfa'
  'vertical_bar:ziguang:linnet_zh_ziguang:slfa'
  'vertical_bar:jiajia:linnet_zh_jiajia:scfa'
  # Profile and trigger are separate renderer facts. The Swift owner test
  # proves the optional trigger reaches every schema; retain one native custom
  # semicolon cross-case whose Microsoft code itself contains a semicolon.
  'semicolon:microsoft:linnet_zh_mspy:srfa'
)
for profile_case in "${profile_cases[@]}"; do
  IFS=: read -r trigger profile schema code <<<"${profile_case}"
  "${scratch}/projection-fixture" profile "${profile}" "${trigger}" "${user}"
  DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
    bin/rime_deployer --build "${user}" "${shared}" \
      "${user}/build" >/dev/null
  rg -Fq "prism: ${schema}" "${user}/build/linnet_en.schema.yaml"
  rg -Fq "chinese_schema: ${schema}" "${user}/build/linnet_en.schema.yaml"
  test -s "${user}/build/${schema}.prism.bin"
  prefix=';'
  [[ "${trigger}" == vertical_bar ]] && prefix='|'
  DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
    "${scratch}/rime-smoke" "${shared}" "${user}" \
      --english-profile-probe \
        "${profile}" "${schema}" "${code}" "${prefix}" >/dev/null
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
if rg -q 'spelling_correction:' "${user}/build/linnet_en.schema.yaml"; then
  echo "retired English correction switch returned to the deployed schema" >&2
  exit 1
fi
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
end_phase "verify eight profiles and Settings projections"

# The default matrix above owns the ordinary lifecycle rows. Reuse its staged
# data and compiled harness for the switcher-only rows instead of starting a
# second complete shell verifier and recompiling both Swift and C++ fixtures.
begin_phase "verify lifecycle exits with the F4 switcher"
ruby -e '
  path = ARGV.fetch(0)
  source = File.binread(path)
  current = "  hotkeys: []\n"
  fixture = "  hotkeys: [F4]\n"
  abort "switcher hotkey owner is missing" unless source.scan(current).length == 1
  File.binwrite(path, source.sub(current, fixture))
' "${shared}/default.yaml"
DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
  bin/rime_deployer --build "${lifecycle_user}" "${shared}" \
    "${lifecycle_user}/build" >/dev/null
DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
  "${scratch}/rime-smoke" "${shared}" "${lifecycle_user}" \
    --lifecycle-raw-exit-probe
end_phase "verify lifecycle exits with the F4 switcher"

echo "Linnet native Rime runtime: PASS (Chinese, 8-profile Smart English, direct Shift, Caps Lock raw, learning, graphical English and input settings)"
