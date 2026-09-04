#!/usr/bin/env bash

# Isolated product-shaped acceptance for the three Chinese learning strategies.
# It deliberately uses only a temporary Rime user directory.  The production
# process, its userdb, and input-source registration are never touched.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

selection_identity_only=0
case "${1:-}" in
  "") ;;
  --selection-identity) selection_identity_only=1 ;;
  *) echo "usage: $0 [--selection-identity]" >&2; exit 2 ;;
esac

for required in \
  bin/rime_deployer \
  lib/librime.1.dylib \
  lib/rime-plugins/librime-lua.dylib \
  librime/dist/include/rime_api.h \
  data/plum \
  data/opencc \
  data/linnet/linnet_zh.schema.yaml \
  data/linnet/lua/auto_phrase.lua \
  data/plum/linnet_zh.schema.yaml \
  tests/auto_phrase_probe.cc; do
  [[ -e "${required}" ]] || {
    echo "verify_chinese_learning_policy: missing required input: ${required}" >&2
    exit 1
  }
done

reports_dir="${HOME}/Library/Logs/DiagnosticReports"
reports_before="$(mktemp /tmp/linnet-learning-reports-before.XXXXXX)"
reports_after="$(mktemp /tmp/linnet-learning-reports-after.XXXXXX)"
if [[ -d "${reports_dir}" ]]; then
  find "${reports_dir}" -maxdepth 1 -type f \( \
    -name '*Linnet*' -o -name '*Squirrel*' -o -name '*rime*' \
  \) -print | LC_ALL=C sort >"${reports_before}"
else
  : >"${reports_before}"
fi

work_root="$(mktemp -d /tmp/linnet-learning-policy.XXXXXX)"
cleanup() {
  rm -f -- "${reports_before}" "${reports_after}"
  rm -rf -- "${work_root}"
}
trap cleanup EXIT

shared="${work_root}/shared"
user="${work_root}/user"
mkdir -p "${shared}" "${user}"
cmp -s data/linnet/linnet_zh.schema.yaml data/plum/linnet_zh.schema.yaml || {
  echo "verify_chinese_learning_policy: staged Chinese schema is stale" >&2
  exit 1
}
tests/verify_lua_embedding.sh >/dev/null || {
  echo "verify_chinese_learning_policy: embedded Core Lua source is stale" >&2
  exit 1
}
[[ ! -e lib/rime-plugins/lua && ! -L lib/rime-plugins/lua ]] || {
  echo "verify_chinese_learning_policy: retired Core Lua resource tree returned" >&2
  exit 1
}
[[ ! -e data/plum/lua && ! -L data/plum/lua ]] || {
  echo "verify_chinese_learning_policy: language data still owns Lua" >&2
  exit 1
}
cp -R -X data/plum/. "${shared}/"
[[ -z "$(find "${shared}" -type f -name '*.lua' -print -quit)" ]] || {
  echo "verify_chinese_learning_policy: Lua entered the writable shared root" >&2
  exit 1
}
cp -R -X data/opencc/. "${shared}/opencc/"
cp \
  tests/fixtures/linnet_zh.custom.yaml \
  tests/fixtures/linnet_user.yaml \
  tests/fixtures/linnet_custom_words.txt \
  tests/fixtures/linnet_text_expander.txt \
  "${user}/"

compiler="$(xcrun --find clang++)"
swiftc="$(xcrun --find swiftc)"
sdk="$(xcrun --show-sdk-path)"
probe="${work_root}/auto_phrase_probe"
projection_fixture="${work_root}/projection-fixture"
"${compiler}" -isysroot "${sdk}" -std=c++17 -O2 -Wall -Wextra -Werror \
  -isystem librime/dist/include \
  tests/auto_phrase_probe.cc \
  lib/librime.1.dylib lib/rime-plugins/librime-lua.dylib \
  -o "${probe}"
if [[ "${selection_identity_only}" -eq 0 ]]; then
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
  -o "${projection_fixture}"
fi

export DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins"

deploy() {
  local label="$1"
  local log_dir="${work_root}/logs-${label}"
  mkdir -p "${log_dir}"
  RIME_LOG_DIR="${log_dir}" \
    bin/rime_deployer --build "${user}" "${shared}" "${user}/build" \
    >"${work_root}/deploy-${label}.out" \
    2>"${work_root}/deploy-${label}.err"
}

run_probe() {
  local label="$1"
  "${probe}" "${shared}" "${user}" linnet_zh_pinyin \
    >"${work_root}/${label}.out" \
    2>"${work_root}/${label}.err"
}

project_learning_policy() {
  local policy="$1"
  "${projection_fixture}" chinese-learning "${policy}" "${user}"
}

contains_candidate() {
  local output="$1" code="$2" word="$3"
  awk -F $'\t' -v code="${code}" -v word="${word}" '
    $1 == "LIST" && $2 == code { inside = 1; next }
    inside && $1 == "END" { inside = 0; next }
    inside && $1 ~ /^[0-9]+$/ && $2 == word { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "${output}"
}

assert_setting() {
  local expected_user_dict="$1" expected_auto_phrase="$2"
  ruby -ryaml -e '
    schema = YAML.load_file(ARGV.fetch(0))
    expected_user = ARGV.fetch(1) == "true"
    expected_auto = ARGV.fetch(2) == "true"
    actual_user = schema.dig("translator", "enable_user_dict")
    actual_auto = schema.dig("auto_phrase", "enable")
    # librime omits an explicit true default from compiled YAML.  Its runtime
    # behavior is covered by the visible learned-word assertions below.
    abort "unexpected userdb setting #{actual_user.inspect}" unless
      actual_user == expected_user || (expected_user && actual_user.nil?)
    abort "unexpected auto_phrase setting #{actual_auto.inspect}" unless
      actual_auto == expected_auto
  ' "${user}/build/linnet_zh_pinyin.schema.yaml" \
    "${expected_user_dict}" "${expected_auto_phrase}"
}

export_userdb() {
  local output="$1"
  local userdb="${user}/linnet_zh.userdb"
  [[ -d "${userdb}" ]] || {
    echo "verify_chinese_learning_policy: expected shared userdb is missing" >&2
    exit 1
  }
  (
    cd "${user}"
    "${repo_root}/bin/rime_dict_manager" --export linnet_zh "${output}"
  ) >"${output}.log"
}

userdb_contains_word() {
  local input="$1" word="$2"
  awk -F $'\t' -v word="${word}" '
    $1 == word { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "${input}"
}

verify_selection_identity() {
  if ! run_probe selection-identity <<'EOF'
identity
EOF
  then
    sed -n '1,100p' "${work_root}/selection-identity.out" "${work_root}/selection-identity.err" >&2
    return 1
  fi
  local exported="${work_root}/selection-identity-userdb.txt"
  export_userdb "${exported}"
  ruby -e '
    entries = File.readlines(ARGV.fetch(0)).map { |line| line.chomp.split("\t") }
    {
      "长码在长大" => "cháng mǎ zài zhǎng dà", "行码" => "xíng mǎ", "行栈" => "xíng zhàn",
      "行杉" => "xíng shān", "行桥" => "xíng qiáo", "行湖" => "xíng hú"
    }.each do |word, code|
      codes = entries.select { |entry| entry[0] == word }.map { |entry| entry[1].strip }.uniq
      abort "selection identity: #{word}: expected #{code.inspect}, got #{codes.inspect}" unless codes == [code]
    end
  ' "${exported}"
  for boundary in browse commit abort fini delete; do
    rg -Fq "$(printf 'IDENTITY\t%s' "${boundary}")" "${work_root}/selection-identity.out"
  done
}

if [[ "${selection_identity_only}" -eq 1 ]]; then
  deploy selection-identity
  assert_setting true true
  verify_selection_identity
  echo "Linnet auto phrase selection identity: PASS"
  exit 0
fi

assert_userdb_excludes() {
  local label="$1"
  shift
  local userdb="${user}/linnet_zh.userdb"
  [[ -d "${userdb}" ]] || return 0
  local exported="${work_root}/${label}.txt"
  export_userdb "${exported}"
  local word
  for word in "$@"; do
    if userdb_contains_word "${exported}" "${word}"; then
      echo "verify_chinese_learning_policy: QA word unexpectedly exists in userdb: ${word}" >&2
      exit 1
    fi
  done
}

seed_userdb_sentinel() {
  local source="${work_root}/userdb-sentinel.txt"
  printf '# Rime user dictionary export\n鹓雏鹍鹏\ta a a a\t1\n' >"${source}"
  (
    cd "${user}"
    "${repo_root}/bin/rime_dict_manager" --import linnet_zh "${source}"
  ) >"${source}.log"
}

sentinel_code=aaaa
sentinel_word=鹓雏鹍鹏

# Enhanced: native userdb plus Linnet auto_phrase creates the QA phrase.
project_learning_policy enhanced
deploy enhanced
assert_setting true true
assert_userdb_excludes \
  enhanced-initial-userdb 云杉码 霜河栈 雪松栈 "${sentinel_word}"
run_probe enhanced-learn <<'EOF'
learn 云杉码 yunshanma 云杉 码
list yunshanma
EOF
rg -Fq $'LEARN_COMMIT\t云杉码' "${work_root}/enhanced-learn.out"
contains_candidate "${work_root}/enhanced-learn.out" yunshanma 云杉码
export_userdb "${work_root}/enhanced-userdb.txt"
userdb_contains_word "${work_root}/enhanced-userdb.txt" 云杉码 || {
  echo "verify_chinese_learning_policy: enhanced policy did not write 云杉码" >&2
  exit 1
}
verify_selection_identity
seed_userdb_sentinel

# Standard: turn off only Linnet's auto_phrase filter through the production
# Settings projection. The already learned word remains readable and
# librime's native userdb learning still works.
project_learning_policy standard
deploy standard
assert_setting true false
run_probe standard <<'EOF'
list aaaa
learn 霜河栈 shuanghezhan 霜 河 栈
EOF
contains_candidate \
  "${work_root}/standard.out" "${sentinel_code}" "${sentinel_word}"
rg -Fq $'LEARN_COMMIT\t霜河栈' "${work_root}/standard.out"
export_userdb "${work_root}/userdb-before-disabled.txt"
for learned_word in 云杉码 霜河栈 "${sentinel_word}"; do
  userdb_contains_word \
    "${work_root}/userdb-before-disabled.txt" "${learned_word}" || {
    echo "verify_chinese_learning_policy: userdb lost ${learned_word}" >&2
    exit 1
  }
done

# Disabled: the production Settings projection owns both switches.  Candidate
# text is not a provenance oracle because another translator may legitimately
# produce the same text; the authoritative contract is the compiled settings,
# no userdb mutation, and the preserved word returning after restore.  The
# complete before/after export is the write oracle: a word's mere presence in
# the after snapshot cannot identify which earlier learning phase created it.
project_learning_policy disabled
deploy disabled
assert_setting false false
run_probe disabled <<'EOF'
learn 雪松栈 xuesongzhan 雪 松 栈
EOF
export_userdb "${work_root}/userdb-after-disabled.txt"
cmp -s \
  "${work_root}/userdb-before-disabled.txt" \
  "${work_root}/userdb-after-disabled.txt" || {
  diff -u \
    "${work_root}/userdb-before-disabled.txt" \
    "${work_root}/userdb-after-disabled.txt" >&2 || true
  echo "verify_chinese_learning_policy: disabled policy changed the preserved userdb" >&2
  exit 1
}
# Re-enabling removes the one policy overlay through the same renderer. The
# preserved userdb returns through the same runtime reader.
project_learning_policy enhanced
deploy restored
assert_setting true true
run_probe restored <<'EOF'
list aaaa
EOF
contains_candidate \
  "${work_root}/restored.out" "${sentinel_code}" "${sentinel_word}"
# Opening a LevelDB userdb can rotate its MANIFEST/LOG files even when no
# candidate is learned.  The exported dictionary is therefore the semantic
# preservation invariant instead of the database directory's physical bytes.

if rg -n 'Lua (Compoment|Component) of (autoload|initialize).*error|LuaTranslation::Next error' \
    "${work_root}"/*.err; then
  echo "verify_chinese_learning_policy: an embedded Lua component failed to load or execute" >&2
  exit 1
fi

if [[ -d "${reports_dir}" ]]; then
  find "${reports_dir}" -maxdepth 1 -type f \( \
    -name '*Linnet*' -o -name '*Squirrel*' -o -name '*rime*' \
  \) -print | LC_ALL=C sort >"${reports_after}"
else
  : >"${reports_after}"
fi
if ! diff -u "${reports_before}" "${reports_after}"; then
  echo "verify_chinese_learning_policy: new native crash report detected" >&2
  exit 1
fi

echo "Linnet Chinese learning policy: PASS (enhanced, standard, disabled, restore)"
