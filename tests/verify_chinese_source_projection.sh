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
english_entity_projection = %q{xlit/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/}
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
  # Upstream 17.9.7 repeats the identical m̄ normalization in full pinyin.
  # Linnet projects it once; repeated identical transforms add no behavior.
  source_rules = source_profile.fetch("__append").each_with_object([]) do |rule, rules|
    rules << rule unless rule == %q{xform/m̄([a-z]*)$/m$1①/} && rules.last == rule
  end
  local_rules = local.fetch(local_name)
  raise "#{local_name} entity projection must be its final algebra rule" unless
    local_rules.last == english_entity_projection &&
      local_rules.count(english_entity_projection) == 1
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
      extra == [%q{derive/^([jqxy])v/$1u/}, english_entity_projection]
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
  fail "the retired generated rime-ice delta owners returned"
fi

dictionary_imports() {
  awk '
    /^import_tables:/ { reading = 1; next }
    reading && /^  - / { print $2; next }
    reading { exit }
  ' "$1"
}

expected_wanxiang_core=$'linnet_reviewed\nlinnet_english_entities\ndicts/zi\ndicts/jichu\ndicts/lianxiang\ndicts/cuoyin\ndicts/duoyin\ndicts/shici\ndicts/diming'
expected_core="${expected_wanxiang_core}"$'\ndicts/ext'
expected_complete="${expected_wanxiang_core}"$'\ndicts/yixue\ndicts/huaxue\ndicts/yaopin\ndicts/mingren\ndicts/yiren\ndicts/wuzhong\ndicts/renming\ndicts/taifeng\ndicts/fangyan\ndicts/ext'
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
[[ "$(wc -l < "${scratch}/actual-reviewed.tsv" | tr -d ' ')" == 57 ]] ||
  fail "the reviewed dictionary must contain exactly 57 accepted rows"
diff -u "${scratch}/expected-reviewed.tsv" "${scratch}/actual-reviewed.tsv" >/dev/null ||
  fail "the reviewed dictionary diverges from the accepted pronunciation/ranking ledgers"

for table in zi jichu lianxiang cuoyin duoyin shici diming \
    yixue huaxue yaopin mingren yiren wuzhong renming taifeng fangyan; do
  [[ -f "upstreams/rime-wanxiang/dicts/${table}.dict.yaml" ]] ||
    fail "a declared direct Wanxiang table is missing: ${table}"
  rg -Fq "dicts/${table}.dict.yaml" scripts/stage-linnet-data ||
    fail "staging does not project the locked table: ${table}"
done
ice_extended_dictionary="upstreams/rime-ice/cn_dicts/ext.dict.yaml"
[[ -f "${ice_extended_dictionary}" && ! -L "${ice_extended_dictionary}" ]] ||
  fail "the locked rime-ice extended dictionary is missing"
[[ "$(rg -F -c 'cn_dicts/ext.dict.yaml' scripts/stage-linnet-data)" -eq 1 ]] ||
  fail "staging must project exactly one rime-ice Chinese supplement"
[[ -x scripts/project-rime-ice-ext ]] ||
  fail "the rime-ice external-format projector is missing or not executable"
projected_ext="${scratch}/dicts/ext.dict.yaml"
projector_report="$(scripts/project-rime-ice-ext \
  "${ice_extended_dictionary}" \
  upstreams/rime-wanxiang/dicts \
  "${projected_ext}" \
  100000)"
[[ "${projector_report}" == *" verified accepted; skipped "* ]] ||
  fail "the supplement projector did not report its verified-only boundary"
! rg -Fq 'best_guess' scripts/project-rime-ice-ext ||
  fail "the supplement projector restored inferred multi-reading acceptance"
if rg -Fq $'希尔瓦娜斯\t' "${projected_ext}"; then
  fail "an ambiguous reviewed name leaked back into the automatic supplement"
fi
rg -Fq $'希尔瓦娜斯\txī ěr wǎ nà sī\t151' "${reviewed_dictionary}" ||
  fail "the reviewed name exception is missing from the declarative owner"
python3 - "${projected_ext}" <<'PY'
import importlib.machinery
import importlib.util
import sys
from collections import Counter, defaultdict
from pathlib import Path

projected_path = Path(sys.argv[1])
projector_path = Path("scripts/project-rime-ice-ext")
loader = importlib.machinery.SourceFileLoader("linnet_ext_projector", str(projector_path))
spec = importlib.util.spec_from_loader(loader.name, loader)
projector = importlib.util.module_from_spec(spec)
loader.exec_module(projector)

wanxiang_root = Path("upstreams/rime-wanxiang/dicts")
source_path = Path("upstreams/rime-ice/cn_dicts/ext.dict.yaml")
source_rows = list(projector.dictionary_rows(source_path))
source_texts = {text for _, text, _, _ in source_rows}
owned_texts = set()
core_weights = defaultdict(int)
abel_prize = None
for table in projector.CORE_TABLES:
    for _, text, code, weight in projector.dictionary_rows(
        wanxiang_root / f"{table}.dict.yaml"
    ):
        if text in source_texts:
            owned_texts.add(text)
        if text == "阿贝尔奖":
            abel_prize = (code, weight)
        plain = " ".join(projector.tone_to_plain(code).split())
        core_weights[plain] = max(core_weights[plain], weight)

if abel_prize != ("ā bèi ěr jiǎng", 52):
    raise SystemExit(f"Wanxiang science sample drifted: 阿贝尔奖={abel_prize}")

readings = projector.load_zi(wanxiang_root / "zi.dict.yaml")
source_status = {}
for _, text, code, _ in source_rows:
    if text in owned_texts:
        continue
    plain = " ".join(projector.tone_to_plain(code).split())
    resolved, status = projector.resolve_tones(text, plain, readings)
    source_status[(text, resolved)] = status

lengths = Counter()
admitted_statuses = Counter()
seen = set()
same_code_collisions = 0
projected_rows = {}
for _, text, code, weight in projector.dictionary_rows(projected_path):
    key = (text, code)
    if key in seen:
        raise SystemExit(f"duplicate projected row: {text}")
    seen.add(key)
    if text in owned_texts:
        raise SystemExit(f"projected supplement duplicated Wanxiang text: {text}")
    status = source_status.get(key)
    if status != "verified":
        raise SystemExit(f"projected supplement admitted non-verified input: {text}")
    admitted_statuses[status] += 1
    plain = " ".join(projector.tone_to_plain(code).split())
    core_weight = core_weights.get(plain)
    if core_weight is not None and weight >= core_weight:
        raise SystemExit(
            f"projected supplement can outrank Wanxiang for {plain}: "
            f"{text}={weight}, Wanxiang={core_weight}"
        )
    if core_weight is not None:
        same_code_collisions += 1
    lengths[len(text)] += 1
    projected_rows[text] = (code, weight)

if admitted_statuses != Counter({"verified": sum(lengths.values())}):
    raise SystemExit(f"projected supplement status mix changed: {admitted_statuses}")

# This is a reviewed value sample, not an inferred quality score. It keeps one
# real product row in every accepted length/rank stratum and across distinct
# domains so a large but low-value projection cannot satisfy the gate by count.
reviewed_samples = {
    "person": ("阿黛尔", "ā dài ěr", 13, 3),
    "science": ("零点定理", "líng diǎn dìng lǐ", 6, 4),
    "medicine": ("阿尔茨海默", "ā ěr cí hǎi mò", 151, 5),
    "education": ("阿亨科技大学", "ā hēng kē jì dà xué", 163, 6),
    "technology": ("生成式人工智能", "shēng chéng shì rén gōng zhì néng", 163, 7),
}
for domain, (text, expected_code, expected_weight, expected_length) in reviewed_samples.items():
    actual = projected_rows.get(text)
    if actual != (expected_code, expected_weight) or len(text) != expected_length:
        raise SystemExit(
            f"reviewed {domain} supplement sample drifted: {text}={actual}"
        )
if {sample[2] for sample in reviewed_samples.values()} != {6, 13, 151, 163}:
    raise SystemExit("reviewed supplement samples lost a projected rank stratum")
if same_code_collisions < 4000:
    raise SystemExit(
        f"supplement/core collision proof became vacuous: {same_code_collisions}"
    )

minimums = {3: 18000, 4: 40000, 5: 25000, 6: 9000, 7: 4500}
for length, minimum in minimums.items():
    actual = (
        sum(count for row_length, count in lengths.items() if row_length >= 7)
        if length == 7
        else lengths[length]
    )
    if actual < minimum:
        raise SystemExit(
            f"verified supplement length stratum {length} has {actual}, expected {minimum}"
        )
print(
    "verified supplement quality: PASS "
    f"({sum(lengths.values())} rows; best_guess=0; unverified=0; "
    f"reviewed domains={len(reviewed_samples)}; "
    f"same-code floors={same_code_collisions}; "
    f"length strata {dict(sorted(lengths.items()))})"
)
PY
rg -Fq '"dicts/diming.dict.yaml", "dicts/ext.dict.yaml"' \
  sources/LinnetPackContract.swift ||
  fail "the Chinese pack contract does not own the projected supplement"
rg -Fq 'for name in zi jichu lianxiang cuoyin duoyin shici diming ext; do' \
  package/stage_language_pack_sources ||
  fail "the Chinese pack staging owner omits the projected supplement"
ruby -e '
  source = File.binread("package/stage_language_pack_sources")
  standard = %q{verify_dictionary_root "${chinese}/linnet_zh.dict.yaml" \
  "${chinese}" "${english}" --}
  complete = %q{verify_dictionary_root "${extended}/linnet_zh_full.dict.yaml" \
  "${chinese}" "${english}" "${extended}" --}
  abort "Standard Chinese cannot resolve the English entity dictionary" unless
    source.include?(standard)
  abort "Complete Chinese cannot resolve the English entity dictionary" unless
    source.include?(complete)
' || fail "Chinese pack dictionary roots lost their cross-pack entity owner"
[[ "$(rg -F -c 'linnet_english_entities.dict.yaml' scripts/stage-linnet-data)" -ge 4 ]] ||
  fail "staging does not fingerprint, validate, copy, and inventory the English entities"
if rg -n $'^.{1,2}\t' "${projected_ext}"; then
  fail "the extended supplement admitted a one- or two-character row"
fi
if rg -n 'cn_dicts/(base|tencent|41448|8105|others)[.]dict[.]yaml' \
    scripts/stage-linnet-data data/linnet/linnet_zh*.dict.yaml; then
  fail "an undeclared rime-ice Chinese table entered the product graph"
fi
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
