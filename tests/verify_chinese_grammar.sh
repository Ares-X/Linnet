#!/usr/bin/env bash

set -Eeuo pipefail

report_failure() {
  local exit_code="$1"
  local line_number="$2"
  local failed_command="$3"
  trap - ERR
  echo "verify_chinese_grammar: command failed at line ${line_number}: ${failed_command}" >&2
  exit "${exit_code}"
}
trap 'report_failure "$?" "$LINENO" "$BASH_COMMAND"' ERR

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

for required in \
  bin/rime_deployer \
  lib/librime.1.dylib \
  lib/rime-plugins/librime-octagram.dylib \
  tests/rime_grammar_probe.cc \
  tests/fixtures/chinese_grammar.tsv; do
  [[ -e "${required}" ]] || {
    echo "verify_chinese_grammar: missing required input" >&2
    exit 1
  }
done

work_root="$(mktemp -d /tmp/linnet-grammar-test.XXXXXX)"
cleanup() {
  rm -rf -- "${work_root}"
}
trap cleanup EXIT

# Post-Wanxiang migration: Wanxiang LTS grammar replaces octagram. The model
# is the committed asset data/chinese/grammar; the staged copy must match it.
model_name="wanxiang-lts-zh-hans.gram"
source_model="data/chinese/grammar/${model_name}"
staged_model="data/plum/${model_name}"
scripts/verify-linnet-grammar-model "${source_model}" "${staged_model}" >/dev/null

if scripts/verify-linnet-grammar-model "${work_root}/${model_name}" >/dev/null 2>&1; then
  echo "verify_chinese_grammar: a missing model passed" >&2
  exit 1
fi
cp "${source_model}" "${work_root}/${model_name}"
truncate -s 1024 "${work_root}/${model_name}"
if scripts/verify-linnet-grammar-model "${work_root}/${model_name}" >/dev/null 2>&1; then
  echo "verify_chinese_grammar: a truncated model passed" >&2
  exit 1
fi
cp "${source_model}" "${work_root}/${model_name}"
printf '\0' | dd of="${work_root}/${model_name}" bs=1 seek=4096 conv=notrunc 2>/dev/null
if scripts/verify-linnet-grammar-model "${work_root}/${model_name}" >/dev/null 2>&1; then
  echo "verify_chinese_grammar: a hash-mismatched model passed" >&2
  exit 1
fi
rm "${work_root}/${model_name}"

on_shared="${work_root}/on-shared"
off_shared="${work_root}/off-shared"
on_user="${work_root}/on-user"
off_user="${work_root}/off-user"
mkdir -p \
  "${on_shared}/opencc" "${off_shared}" "${on_user}" "${off_user}" \
  "${work_root}/on-logs" "${work_root}/off-logs"
cp -R -X data/plum/. "${on_shared}/"
cp -R -X data/opencc/. "${on_shared}/opencc/"
cp -R -X "${on_shared}/." "${off_shared}/"
# The staged tree intentionally defaults to the Standard compact grammar.
# This A/B probe owns a Full activation fixture, so select the LTS model in
# the same one-file projection that release profiles replace at install time.
ruby -ryaml -e '
  path = ARGV.fetch(0)
  profile = YAML.load_file(path)
  profile.fetch("grammar")["language"] = "wanxiang-lts-zh-hans"
  File.write(path, YAML.dump(profile))
' "${on_shared}/linnet_grammar_active.yaml"
rm "${off_shared}/${model_name}"
ruby -ryaml -e '
  path = ARGV.fetch(0)
  schema = YAML.load_file(path)
  abort "grammar fixture source is missing" unless schema.delete("grammar")
  File.write(path, YAML.dump(schema))
' "${off_shared}/linnet_zh.schema.yaml"

for user_root in "${on_user}" "${off_user}"; do
  cp \
    tests/fixtures/linnet_zh.custom.yaml \
    tests/fixtures/linnet_user.yaml \
    tests/fixtures/linnet_custom_words.txt \
    tests/fixtures/linnet_text_expander.txt \
    "${user_root}/"
done

export DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins"
RIME_LOG_DIR="${work_root}/on-logs" \
  bin/rime_deployer --build "${on_user}" "${on_shared}" "${on_user}/build"
RIME_LOG_DIR="${work_root}/off-logs" \
  bin/rime_deployer --build "${off_user}" "${off_shared}" "${off_user}/build"

for schema in \
  linnet_zh linnet_zh_pinyin linnet_zh_flypy linnet_zh_mspy \
  linnet_zh_sogou linnet_zh_abc linnet_zh_ziguang linnet_zh_jiajia; do
  ruby -ryaml -e '
    grammar = YAML.load_file(ARGV.fetch(0)).fetch("grammar")
    abort unless grammar["language"] == "wanxiang-lts-zh-hans" &&
      %w[collocation_max_length collocation_min_length].all? { |key| grammar.key?(key) }
  ' "${on_user}/build/${schema}.schema.yaml"
done

compiler="$(xcrun --find clang++)"
sdk="$(xcrun --show-sdk-path)"
probe="${work_root}/rime-grammar-probe"
"${compiler}" -isysroot "${sdk}" -std=c++17 -O2 -Wall -Wextra -Werror \
  -isystem librime/dist/include tests/rime_grammar_probe.cc lib/librime.1.dylib \
  -o "${probe}"

fixture="$(rg -v '^#|^[[:space:]]*$' tests/fixtures/chinese_grammar.tsv)"
[[ "$(rg -v '^#|^[[:space:]]*$' tests/fixtures/chinese_grammar.tsv | wc -l | tr -d ' ')" == "1" ]] || {
  echo "verify_chinese_grammar: fixture set is not exact" >&2
  exit 1
}
IFS=$'\t' read -r key_sequence expected_on expected_off <<<"${fixture}"
"${probe}" "${on_shared}" "${on_user}" "${key_sequence}" \
  >"${work_root}/on.out" 2>"${work_root}/on.err"
"${probe}" "${off_shared}" "${off_user}" "${key_sequence}" \
  >"${work_root}/off.out" 2>"${work_root}/off.err"
actual_on="$(awk -F '\t' 'NR == 1 { print $2 }' "${work_root}/on.out")"
actual_off="$(awk -F '\t' 'NR == 1 { print $2 }' "${work_root}/off.out")"
[[ "${actual_on}" == "${expected_on}" && "${actual_off}" == "${expected_off}" && \
   "${actual_on}" != "${actual_off}" ]] || {
  echo "verify_chinese_grammar: reviewed A/B candidate contract failed" >&2
  exit 1
}
cold_ms="$(rg -o 'cold_ms=[0-9]+' "${work_root}/on.err" | cut -d= -f2)"
[[ "${cold_ms}" =~ ^[0-9]+$ && "${cold_ms}" -le 750 ]] || {
  echo "verify_chinese_grammar: cold first sentence exceeded 750ms" >&2
  exit 1
}
rg -q 'use grammar: wanxiang-lts-zh-hans' "${work_root}/on.err"
rg -q 'loading gram db: .*wanxiang-lts-zh-hans.gram' "${work_root}/on.err"

echo "Linnet Chinese grammar: PASS (reviewed A/B, cold ${cold_ms}ms)"
