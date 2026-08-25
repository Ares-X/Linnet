#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

fail() {
  echo "verify_chinese_source_projection: $1" >&2
  exit 1
}

reviewed_dictionary="data/linnet/linnet_reviewed.dict.yaml"
source_patch="patches/rime-wanxiang-linnet-reviewed.patch"
[[ -f "${reviewed_dictionary}" && ! -L "${reviewed_dictionary}" ]] ||
  fail "the declarative reviewed dictionary is missing"
[[ -f "${source_patch}" && ! -L "${source_patch}" ]] ||
  fail "the exact Wanxiang source patch is missing"

if ! ruby -rjson -ryaml <<'RUBY'
lock = JSON.parse(File.read("upstreams.lock.json"))
wanxiang = lock.fetch("sources").fetch("rime_wanxiang")
contract = wanxiang.fetch("data_inputs").fetch("algebra")
source_path = File.join(wanxiang.fetch("submodule_path"), contract.fetch("path"))
local_path = "data/linnet/linnet_algebra.yaml"

raise "unsafe algebra source" unless File.file?(source_path) && !File.symlink?(source_path)
raise "unsafe Linnet algebra" unless File.file?(local_path) && !File.symlink?(local_path)

source = YAML.safe_load(
  File.read(source_path), permitted_classes: [], permitted_symbols: [], aliases: false
).fetch(contract.fetch("section"))
local = YAML.safe_load(
  File.read(local_path), permitted_classes: [], permitted_symbols: [], aliases: false
)
profiles = contract.fetch("profiles")
raise "profile set changed" unless local.keys == profiles.keys

header = File.readlines(local_path, encoding: "UTF-8").first(12).join
raise "local header lost canonical provenance" unless
  header.include?("wanxiang_algebra.yaml:/base") &&
    header.include?("upstreams.lock.json")
raise "local header duplicated a mutable commit" if
  header.match?(/\b[0-9a-f]{7,40}\b/)

full = local.fetch("full_pinyin")
selector_marker = /\Axform\/[ⅠⅡⅢⅣⅤⅥⅦⅧ]+\//
generic_single_tone = %q{derive/^(.).+(\d)$/$1$2/}
natural_single_key_a = %q{derive/^aa(\d)$/a/}
full_broad_tail_start = %q{derive/([qtpdjlxbnm])iao$/$1ioa/}
full_individual_omissions = [
  %q{abbrev/^ng(\d)$/ng/},
  %q{erase/^ng(\d)$/},
  %q{derive/([wrtpsdfghklzcbnm])eng$/$1wng/},
  %q{derive/([rtysdghklzcn])ong$/$1ogn/}
]
single_abbreviations = [
  %q{abbrev/^([qwrtypsdfghjklzxcbnm]).+$/$1/},
  %q{abbrev/^([qwrtypsdfghjklzxcbnm]).+(\d)$/$1$2/}
]

profiles.each do |local_name, source_name|
  source_profile = source.fetch(source_name)
  raise "unexpected upstream profile shape" unless source_profile.keys == ["__append"]
  source_rules = source_profile.fetch("__append")
  local_rules = local.fetch(local_name)
  raise "selector marker leaked into #{local_name}" if
    local_rules.any? { |rule| rule.match?(selector_marker) }

  if local_name == "full_pinyin"
    source_without_marker = source_rules.drop(1)
    broad_tail_index = source_without_marker.index(full_broad_tail_start)
    raise "full-pinyin source selection anchor changed" unless broad_tail_index
    expected_source_rules = source_without_marker.first(broad_tail_index).reject do |rule|
      full_individual_omissions.include?(rule)
    end
    actual_source_rules = local_rules.select { |rule| source_rules.include?(rule) }
    raise "full-pinyin source selection drifted" unless
      actual_source_rules.sort == expected_source_rules.sort
    extra = local_rules.reject { |rule| source_rules.include?(rule) }
    raise "undeclared full-pinyin rule" unless
      extra == [%q{derive/^([jqxy])v/$1u/}]
    next
  end

  raise "#{local_name} normalization drifted" unless
    local_rules.first(35) == source_rules.drop(1).first(35)
  required = source_rules.drop(1).reject { |rule| rule == generic_single_tone }
  raise "#{local_name} lost an upstream layout rule" unless
    required.all? { |rule| local_rules.include?(rule) }
  raise "#{local_name} gained an undeclared rule" unless
    local_rules.all? do |rule|
      source_rules.include?(rule) || full.include?(rule) ||
        (local_name == "ziranma" && rule == natural_single_key_a)
    end
  raise "Natural Code lost its reviewed single-key a shortcut" unless
    (local_name == "ziranma") == local_rules.include?(natural_single_key_a)
  raise "#{local_name} restored a broad single-character path" if
    local_rules.include?(generic_single_tone) ||
      single_abbreviations.any? { |rule| local_rules.include?(rule) }
end

references = Hash.new(0)
Dir.glob("data/linnet/linnet_zh*.schema.yaml").sort.each do |schema_path|
  File.read(schema_path, encoding: "UTF-8").scan(
    %r{linnet_algebra\.yaml:/([a-z_]+)}
  ) { |match| references[match.first] += 1 }
end
expected_references = profiles.keys.each_with_object({}) { |name, memo| memo[name] = 1 }
raise "schema/algebra projection changed" unless references == expected_references
RUBY
then
  fail "the Linnet algebra is not a declared projection of the locked Wanxiang base"
fi

for retired_path in \
  data/chinese/customizations.yaml \
  data/linnet/duo_overrides.dict.yaml \
  scripts/chinese/build_dictionary.py \
  scripts/chinese/update_upstreams.py \
  scripts/chinese/upstream_update_gate.py \
  scripts/chinese/verify_generated.py; do
  [[ ! -e "${retired_path}" && ! -L "${retired_path}" ]] ||
    fail "a retired Chinese composition owner returned: ${retired_path}"
done

generated_root="data/chinese/generated"
[[ ! -L "${generated_root}" && \
   ( ! -e "${generated_root}" || -d "${generated_root}" ) ]] ||
  fail "the retired generated Chinese root is unsafe"
if [[ -d "${generated_root}" ]] &&
    find "${generated_root}" -mindepth 1 \( -type f -o -type l \) \
      -print -quit | grep -q .; then
  fail "a generated Chinese dictionary truth returned"
fi

if rg -n '"(delta_dictionaries|longtail_dictionary)"' \
    upstreams.lock.json scripts/upstream-sync tests/verify_product.sh; then
  fail "rime-ice Chinese dictionaries returned to the locked product inputs"
fi

dictionary_imports() {
  awk '
    /^import_tables:/ { reading = 1; next }
    reading && /^  - / { print $2; next }
    reading { exit }
  ' "$1"
}

expected_core=$'linnet_reviewed\ndicts/zi\ndicts/jichu\ndicts/lianxiang\ndicts/cuoyin\ndicts/duoyin\ndicts/shici\ndicts/diming'
expected_complete="${expected_core}"$'\ndicts/yixue\ndicts/huaxue\ndicts/yaopin\ndicts/mingren\ndicts/yiren\ndicts/wuzhong\ndicts/renming\ndicts/taifeng\ndicts/fangyan'
[[ "$(dictionary_imports data/linnet/linnet_zh.dict.yaml)" == "${expected_core}" ]] ||
  fail "the Core dictionary does not import the canonical direct tables"
[[ "$(dictionary_imports data/linnet/linnet_zh_full.dict.yaml)" == "${expected_complete}" ]] ||
  fail "the Complete dictionary does not import the canonical direct tables"

scratch="$(mktemp -d /private/tmp/linnet-chinese-source-test.XXXXXX)"
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [[ "${scratch}" != /private/tmp/linnet-chinese-source-test.?????? ||
        ! -d "${scratch}" || -L "${scratch}" ]]; then
    echo "verify_chinese_source_projection: refusing unsafe cleanup: ${scratch}" >&2
    exit 1
  fi
  find "${scratch}" -depth -delete
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "${scratch}/dicts"
for table in jichu lianxiang zi cuoyin; do
  source="upstreams/rime-wanxiang/dicts/${table}.dict.yaml"
  [[ -f "${source}" && ! -L "${source}" ]] ||
    fail "locked Wanxiang source is missing: ${table}"
  cp -X "${source}" "${scratch}/dicts/"
done
patch --batch --forward --fuzz=0 -s -d "${scratch}" -p1 < "${source_patch}" ||
  fail "the reviewed source patch does not apply exactly"

awk -F '\t' 'NR > 1 && $1 == "wanxiang" { print $2 "\t" $3 }' \
  data/chinese/overrides/reviewed_pronunciations.tsv |
  LC_ALL=C sort > "${scratch}/retired.tsv"
[[ "$(wc -l < "${scratch}/retired.tsv" | tr -d ' ')" == 42 ]] ||
  fail "the retired Wanxiang wrong-code set is not exactly 42 rows"

for table in jichu lianxiang zi cuoyin; do
  awk -F '\t' 'NF >= 2 { print $1 "\t" $2 }' \
    "${scratch}/dicts/${table}.dict.yaml"
done | LC_ALL=C sort > "${scratch}/patched-pairs.tsv"
if comm -12 "${scratch}/retired.tsv" "${scratch}/patched-pairs.tsv" |
    grep -q .; then
  fail "a reviewed wrong-code row remains after the exact source patch"
fi

{
  awk -F '\t' 'NR > 1 { print $2 "\t" $4 }' \
    data/chinese/overrides/reviewed_pronunciations.tsv
  awk -F '\t' 'NR > 1 { print $1 "\t" $2 }' \
    data/chinese/overrides/reviewed_rankings.tsv
} | LC_ALL=C sort > "${scratch}/expected-reviewed.tsv"
awk -F '\t' '
  $0 == "..." { body = 1; next }
  body && $0 !~ /^#/ && NF >= 3 { print $1 "\t" $2 }
' "${reviewed_dictionary}" | LC_ALL=C sort > "${scratch}/actual-reviewed.tsv"
[[ "$(wc -l < "${scratch}/actual-reviewed.tsv" | tr -d ' ')" == 55 ]] ||
  fail "the reviewed dictionary must contain exactly 55 accepted rows"
diff -u "${scratch}/expected-reviewed.tsv" "${scratch}/actual-reviewed.tsv" >/dev/null ||
  fail "the reviewed dictionary diverges from the accepted pronunciation/ranking ledgers"

for table in zi jichu lianxiang cuoyin duoyin shici diming \
    yixue huaxue yaopin mingren yiren wuzhong renming taifeng fangyan; do
  [[ -f "upstreams/rime-wanxiang/dicts/${table}.dict.yaml" ]] ||
    fail "a declared direct Wanxiang table is missing: ${table}"
  rg -Fq "dicts/${table}.dict.yaml" scripts/stage-linnet-data ||
    fail "staging does not project the locked table: ${table}"
done
rg -Fq "${source_patch}" scripts/stage-linnet-data ||
  fail "staging does not apply the reviewed source patch"
rg -Fq "${reviewed_dictionary}" scripts/stage-linnet-data ||
  fail "staging does not project the reviewed dictionary"

if rg -n 'data/chinese/generated/(duo_zh_l[123]|professional)|duo_overrides' \
    action-build.sh action-install.sh scripts/stage-linnet-data \
    package/stage_language_pack_sources data/linnet/linnet_zh*.dict.yaml; then
  fail "a retired generated Chinese product path remains authoritative"
fi
if rg -n 'build_dictionary\.py|verify_generated\.py' \
    action-build.sh action-install.sh scripts/stage-linnet-data \
    package/stage_language_pack_sources; then
  fail "the Python Chinese composer remains on the Release/package path"
fi

current_authority_docs=(
  README.md
  CHANGELOG.md
  THIRD_PARTY_NOTICES.md
  package/WELCOME.md
  docs/product-acceptance.md
  docs/development.md
  docs/release.md
)
if rg -n 'rime-ice (contributes a generated|delta entries)|雾凇增量|build_dictionary\.py|verify_generated\.py|data/chinese/customizations\.yaml' \
    "${current_authority_docs[@]}"; then
  fail "current product authority still describes the retired Chinese composer"
fi

echo "verify_chinese_source_projection: PASS"
