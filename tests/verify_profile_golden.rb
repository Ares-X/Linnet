#!/usr/bin/env ruby

require "csv"
require "digest"
require "fileutils"
require "open3"
require "set"
require "tempfile"
require "timeout"
require "yaml"

class ProfileGoldenError < StandardError; end

SemanticCase = Struct.new(:case_id, :category, :full_pinyin, keyword_init: true)
ProfileCase = Struct.new(
  :case_id, :classification, :schema, :code, :expected, :max_rank,
  keyword_init: true
)
MappingCase = Struct.new(:kind, :name, :syllable, :code, keyword_init: true)

REPO_ROOT = File.expand_path("..", __dir__)
SEMANTIC_CORPUS = File.join(REPO_ROOT, "data/chinese/golden/input_corpus.txt")
PROFILE_FIXTURE = File.join(REPO_ROOT, "tests/fixtures/chinese_profile_golden.tsv")
DEFAULT_CONFIG = File.join(REPO_ROOT, "data/linnet/default.yaml")
CANONICAL_CASES = 215
TOP_N = 20
LOWERCASE_KEYS = Set.new(("a".."z").to_a).freeze
PROFILE_ALGEBRA_ORACLE = {
  "linnet_zh_pinyin" => "full_pinyin",
  "linnet_zh" => "ziranma",
  "linnet_zh_flypy" => "flypy",
  "linnet_zh_mspy" => "mspy",
  "linnet_zh_sogou" => "sogou",
  "linnet_zh_abc" => "abc",
  "linnet_zh_ziguang" => "ziguang",
  "linnet_zh_jiajia" => "jiajia",
}.freeze
PROFILES = PROFILE_ALGEBRA_ORACLE.keys.freeze

INITIAL_SAMPLES = {
  "b" => "ba", "p" => "pa", "m" => "ma", "f" => "fa",
  "d" => "da", "t" => "ta", "n" => "na", "l" => "la",
  "g" => "ga", "k" => "ka", "h" => "ha", "j" => "ji",
  "q" => "qi", "x" => "xi", "r" => "re", "z" => "za",
  "c" => "ca", "s" => "sa", "zh" => "zha", "ch" => "cha",
  "sh" => "sha", "y" => "ya", "w" => "wa",
}.freeze
FINAL_SAMPLES = {
  "a" => "ba", "o" => "bo", "e" => "de", "i" => "bi",
  "u" => "bu", "v" => "lv", "ai" => "bai", "ei" => "bei",
  "ao" => "bao", "ou" => "pou", "an" => "ban", "en" => "ben",
  "ang" => "bang", "eng" => "beng", "ong" => "dong", "ia" => "jia",
  "ie" => "bie", "iao" => "biao", "iu" => "diu", "ian" => "bian",
  "in" => "bin", "iang" => "liang", "ing" => "bing", "iong" => "jiong",
  "ua" => "gua", "uo" => "guo", "uai" => "guai", "ui" => "dui",
  "uan" => "duan", "un" => "dun", "uang" => "guang",
  "ue" => "jue", "ve" => "lve",
}.freeze

def reviewed_map(groups)
  groups.each_with_object({}) do |(key, finals), mapping|
    finals.split.each { |final| mapping[final] = key }
  end.freeze
end

IDENTITY_FINALS = %w[a o e i u].to_h { |final| [final, final] }.freeze
DOUBLE_FINAL_ORACLE = {
  "linnet_zh" => IDENTITY_FINALS.merge(reviewed_map(
    "q" => "iu", "w" => "ia ua", "r" => "uan", "t" => "ue ve",
    "y" => "ing uai", "o" => "uo", "p" => "un", "s" => "ong iong",
    "d" => "iang uang", "f" => "en", "g" => "eng", "h" => "ang",
    "m" => "ian", "j" => "an", "c" => "iao", "k" => "ao", "l" => "ai",
    "z" => "ei", "x" => "ie", "v" => "v ui", "b" => "ou", "n" => "in"
  )).freeze,
  "linnet_zh_flypy" => IDENTITY_FINALS.merge(reviewed_map(
    "v" => "v ui", "q" => "iu", "w" => "ei", "r" => "uan", "t" => "ue ve",
    "y" => "un", "o" => "uo", "p" => "ie", "s" => "ong iong",
    "d" => "ai", "f" => "en", "g" => "eng", "h" => "ang", "j" => "an",
    "k" => "ing uai", "l" => "iang uang", "z" => "ou", "x" => "ia ua",
    "c" => "ao", "b" => "in", "n" => "iao", "m" => "ian"
  )).freeze,
  "linnet_zh_mspy" => IDENTITY_FINALS.merge(reviewed_map(
    "y" => "v uai", "q" => "iu", "w" => "ia ua", "r" => "uan", "t" => "ue ve",
    "o" => "uo", "p" => "un", "s" => "ong iong", "d" => "iang uang",
    "f" => "en", "g" => "eng", "h" => "ang", "m" => "ian", "j" => "an",
    "c" => "iao", "k" => "ao", "l" => "ai", "z" => "ei", "x" => "ie",
    "v" => "ui", "b" => "ou", "n" => "in", ";" => "ing"
  )).freeze,
  "linnet_zh_sogou" => IDENTITY_FINALS.merge(reviewed_map(
    "y" => "v uai", "q" => "iu", "w" => "ia ua", "r" => "uan", "t" => "ue ve",
    "o" => "uo", "p" => "un", "s" => "ong iong", "d" => "iang uang",
    "f" => "en", "g" => "eng", "h" => "ang", "m" => "ian", "j" => "an",
    "c" => "iao", "k" => "ao", "l" => "ai", "z" => "ei", "x" => "ie",
    "v" => "ui", "b" => "ou", "n" => "in", ";" => "ing"
  )).freeze,
  "linnet_zh_abc" => IDENTITY_FINALS.merge(reviewed_map(
    "v" => "v", "q" => "ei", "w" => "ian", "r" => "iu", "t" => "iang uang",
    "y" => "ing", "o" => "uo", "p" => "uan", "s" => "ong iong",
    "d" => "ia ua", "f" => "en", "g" => "eng", "h" => "ang", "j" => "an",
    "z" => "iao", "k" => "ao", "c" => "in uai", "l" => "ai", "x" => "ie",
    "b" => "ou", "n" => "un", "m" => "ue ve ui"
  )).freeze,
  "linnet_zh_ziguang" => IDENTITY_FINALS.merge(reviewed_map(
    "v" => "v", "w" => "en", "t" => "eng", "y" => "in uai", "o" => "uo",
    "p" => "ai", "g" => "iang uang", "s" => "ang", "d" => "ie", "f" => "ian",
    "h" => "ong iong", "j" => "iu", "k" => "ei", "l" => "uan", ";" => "ing",
    "z" => "ou", "x" => "ia ua", "b" => "iao", "n" => "ue ve ui",
    "m" => "un", "q" => "ao", "r" => "an"
  )).freeze,
  "linnet_zh_jiajia" => IDENTITY_FINALS.merge(reviewed_map(
    "v" => "v ui", "n" => "iu", "b" => "ia ua", "q" => "ing", "c" => "uan",
    "x" => "ue ve uai", "o" => "uo", "z" => "un", "y" => "ong iong",
    "h" => "iang uang", "r" => "en", "t" => "eng", "g" => "ang", "j" => "ian",
    "f" => "an", "k" => "iao", "d" => "ao", "s" => "ai", "w" => "ei",
    "m" => "ie", "p" => "ou", "l" => "in"
  )).freeze,
}.freeze
INITIAL_OVERRIDES = {
  "linnet_zh" => {"zh" => "v", "ch" => "i", "sh" => "u"},
  "linnet_zh_flypy" => {"zh" => "v", "ch" => "i", "sh" => "u"},
  "linnet_zh_mspy" => {"zh" => "v", "ch" => "i", "sh" => "u"},
  "linnet_zh_sogou" => {"zh" => "v", "ch" => "i", "sh" => "u"},
  "linnet_zh_abc" => {"zh" => "a", "ch" => "e", "sh" => "v"},
  "linnet_zh_ziguang" => {"zh" => "u", "ch" => "a", "sh" => "i"},
  "linnet_zh_jiajia" => {"zh" => "v", "ch" => "u", "sh" => "i"},
}.transform_values(&:freeze).freeze
ZERO_FINAL_ORACLE = {
  "linnet_zh_pinyin" => {"ai" => "ai", "er" => "er"},
  "linnet_zh" => {"ai" => "ai", "er" => "er"},
  "linnet_zh_flypy" => {"ai" => "ai", "er" => "er"},
  "linnet_zh_mspy" => {"ai" => "ol", "er" => "or"},
  "linnet_zh_sogou" => {"ai" => "ol", "er" => "or"},
  "linnet_zh_abc" => {"ai" => "ol", "er" => "or"},
  "linnet_zh_ziguang" => {"ai" => "op", "er" => "oj"},
  "linnet_zh_jiajia" => {"ai" => "as", "er" => "eq"},
}.transform_values(&:freeze).freeze

def load_formal_profiles
  config = YAML.safe_load(File.read(DEFAULT_CONFIG, encoding: "UTF-8"), aliases: true)
  declared = config.fetch("schema_list").map { |entry| entry.fetch("schema") }
  chinese = declared.reject { |schema| schema == "linnet_en" }
  unless chinese == PROFILES
    raise ProfileGoldenError, "default.yaml diverges from the reviewed profile order"
  end
end

load_formal_profiles
SUPPLEMENTAL_CLASSIFICATIONS = {
  "reverse_yun" => "supplemental:pinyin_reverse",
  "v_lve" => "supplemental:v_final",
  "zero_ai" => "supplemental:zero_initial",
  "retroflex_zhishi" => "supplemental:zh_ch_sh",
  "fangyan_wugai" => "supplemental:fangyan",
  "fangyan_daowuqi" => "supplemental:fangyan",
  "user_yunshanma" => "supplemental:user_learning",
}.freeze
FIXTURE_COLUMNS = %w[case_id classification schema code expected max_rank].freeze
FIXTURE_FILES = [
  %w[linnet_zh.custom.yaml rimeduo_zh.custom.yaml],
  %w[linnet_user.yaml rimeduo_user.yaml],
  %w[linnet_custom_words.txt rimeduo_custom_words.txt],
  %w[linnet_text_expander.txt rimeduo_text_expander.txt],
].freeze

def require_golden(condition, message)
  raise ProfileGoldenError, message unless condition
end

def load_semantic_corpus
  raw = File.read(SEMANTIC_CORPUS, encoding: "UTF-8")
  cases = []
  category = nil
  raw.each_line do |raw_line|
    line = raw_line.strip
    if (match = line.match(/^# ([a-z_]+):/))
      category = match[1]
      next
    end
    next if line.empty? || line.start_with?("#")
    require_golden(category, "semantic corpus row has no category")
    cases << SemanticCase.new(
      case_id: format("c%03d", cases.length + 1), category: category,
      full_pinyin: line.delete(" ")
    )
  end
  require_golden(
    cases.length == CANONICAL_CASES,
    "semantic corpus has #{cases.length} cases; expected #{CANONICAL_CASES}"
  )
  counts = cases.group_by(&:category).transform_values(&:length)
  required = Set.new(%w[daily work tech finance modern places polyphone long sentences])
  require_golden(Set.new(counts.keys) == required, "semantic corpus categories changed")
  require_golden(counts.fetch("long").positive? && counts.fetch("sentences").positive?,
                 "long/LTS sentence coverage is empty")
  semantic_rows = cases.map do |item|
    [item.case_id, item.category, item.full_pinyin].join("\t")
  end.join("\n") + "\n"
  [cases, Digest::SHA256.hexdigest(semantic_rows)]
end

def load_profile_fixture(semantic_cases, semantic_digest)
  require_golden(File.file?(PROFILE_FIXTURE), "fixed profile fixture is missing")
  raw_lines = File.readlines(PROFILE_FIXTURE, chomp: true, encoding: "UTF-8")
  metadata = raw_lines.each_with_object([]) do |line, values|
    match = line.strip.match(/^# ([a-z0-9_]+)=(.+)$/)
    values << [match[1], match[2]] if match
  end.to_h
  require_golden(metadata["format"] == "1", "profile fixture format must be 1")
  require_golden(metadata["semantic_sha256"] == semantic_digest,
                 "profile fixture semantic corpus hash is stale")
  data = raw_lines.reject { |line| line.start_with?("#") }.join("\n") + "\n"
  table = CSV.parse(data, headers: true, col_sep: "\t")
  require_golden(table.headers == FIXTURE_COLUMNS, "profile fixture columns changed")
  by_profile = PROFILES.to_h { |schema| [schema, []] }
  seen_pairs = Set.new
  seen_codes = Set.new
  table.each_with_index do |row, index|
    schema = row.fetch("schema")
    require_golden(by_profile.key?(schema), "fixture row #{index + 1}: unknown schema")
    rank = Integer(row.fetch("max_rank"), 10) rescue nil
    profile_case = ProfileCase.new(
      case_id: row.fetch("case_id"), classification: row.fetch("classification"),
      schema: schema, code: row.fetch("code"), expected: row.fetch("expected"),
      max_rank: rank
    )
    require_golden(profile_case.code.match?(/\A[A-Za-z;|]+\z/),
                   "fixture row #{index + 1}: invalid fixed code")
    require_golden(
      profile_case.case_id == "reverse_yun" ? profile_case.code.start_with?("|") : !profile_case.code.include?("|"),
      "fixture row #{index + 1}: reverse-lookup prefix is not uniquely owned"
    )
    require_golden(!profile_case.expected.empty? && rank && rank.between?(1, TOP_N),
                   "fixture row #{index + 1}: empty expectation or rank out of range")
    pair = [schema, profile_case.case_id]
    code_key = [schema, profile_case.code]
    require_golden(seen_pairs.add?(pair), "duplicate fixture case: #{pair.inspect}")
    require_golden(seen_codes.add?(code_key), "ambiguous fixed profile code: #{code_key.inspect}")
    by_profile.fetch(schema) << profile_case
  end

  semantic_by_id = semantic_cases.to_h { |item| [item.case_id, item] }
  canonical_ids = semantic_cases.map(&:case_id)
  supplemental_ids = SUPPLEMENTAL_CLASSIFICATIONS.keys
  reviewed = {}
  by_profile.each do |schema, cases|
    canonical = cases.select { |item| item.case_id.start_with?("c") }
    supplemental = cases.reject { |item| item.case_id.start_with?("c") }
    require_golden(canonical.map(&:case_id) == canonical_ids,
                   "#{schema}: canonical fixture is not the exact ordered 215 cases")
    require_golden(supplemental.map(&:case_id) == supplemental_ids,
                   "#{schema}: supplemental classifications are incomplete or reordered")
    canonical.each do |item|
      semantic = semantic_by_id.fetch(item.case_id)
      require_golden(item.classification == "canonical:#{semantic.category}",
                     "#{schema} #{item.case_id}: semantic classification drift")
      if schema == "linnet_zh_pinyin"
        require_golden(item.code == semantic.full_pinyin,
                       "#{item.case_id}: full-pinyin code diverges from semantic owner")
      end
    end
    supplemental.each do |item|
      require_golden(item.classification == SUPPLEMENTAL_CLASSIFICATIONS.fetch(item.case_id),
                     "#{schema} #{item.case_id}: supplemental classification drift")
    end
    cases.each do |item|
      reviewed[item.case_id] ||= item.expected
      require_golden(reviewed.fetch(item.case_id) == item.expected,
                     "#{item.case_id}: expectation diverges across profiles")
    end

    schema_config = YAML.safe_load(
      File.read(
        File.join(REPO_ROOT, "data/linnet/#{schema}.schema.yaml"),
        encoding: "UTF-8"
      ),
      aliases: true
    )
    algebra_owner = schema_config.dig("speller", "algebra", "__include")
    expected_owner = "linnet_algebra.yaml:/#{PROFILE_ALGEBRA_ORACLE.fetch(schema)}"
    require_golden(algebra_owner == expected_owner,
                   "#{schema}: schema points at #{algebra_owner.inspect}, expected #{expected_owner}")
    alphabet = schema_config.dig("speller", "alphabet")
    require_golden(alphabet.is_a?(String), "#{schema}: speller alphabet is missing")
    formal_keys = Set.new(alphabet.scan(/[a-z]/))
    fixture_keys = Set.new(cases.flat_map { |item| item.code.scan(/[a-z]/) })
    require_golden(formal_keys == LOWERCASE_KEYS,
                   "#{schema}: formal alphabet is not the exact a-z key set")
    require_golden(fixture_keys == formal_keys,
                   "#{schema}: fixture key set diverges from its formal alphabet")
    allowed_spelling_keys = Set.new(alphabet.chars)
    cases.each do |item|
      spelling = item.case_id == "reverse_yun" ? item.code.delete_prefix("|") : item.code
      unexpected = Set.new(spelling.chars) - allowed_spelling_keys
      require_golden(unexpected.empty?,
                     "#{schema} #{item.case_id}: fixture uses undeclared keys #{unexpected.to_a.join}")
    end

    %w[zero_ai v_lve retroflex_zhishi].each do |case_id|
      critical = cases.find { |item| item.case_id == case_id }
      require_golden(critical && !critical.code.empty?,
                     "#{schema}: missing critical #{case_id} fixture")
    end
    unless schema == "linnet_zh_pinyin"
      require_golden(Set.new(DOUBLE_FINAL_ORACLE.fetch(schema).keys) == Set.new(FINAL_SAMPLES.keys),
                     "#{schema}: reviewed final oracle is incomplete")
      require_golden(Set.new(INITIAL_OVERRIDES.fetch(schema).keys) == Set.new(%w[zh ch sh]),
                     "#{schema}: reviewed compound-initial oracle is incomplete")
    end
    puts [
      "#{schema}: reviewed mapping oracle",
      "initials=#{INITIAL_SAMPLES.length}",
      "finals=#{FINAL_SAMPLES.length + 1}",
      "zero_initials=#{ZERO_FINAL_ORACLE.fetch(schema).length}",
      "formal_keys=#{formal_keys.length}",
    ].join(" ")
  end
  by_profile
end

def runtime_paths
  paths = {
    deployer: File.join(REPO_ROOT, "bin/rime_deployer"),
    dylib: File.join(REPO_ROOT, "lib/librime.1.dylib"),
    includes: File.join(REPO_ROOT, "librime/dist/include"),
    probe_source: File.join(REPO_ROOT, "tests/rime_golden_probe.cc"),
  }
  missing = paths.values.reject { |path| File.exist?(path) }
  require_golden(missing.empty?, "Linnet runtime is not fully built: #{missing.join(", ")}")
  paths
end

def compile_probe(runtime, work_root)
  compiler, status = Open3.capture2("xcrun", "--find", "clang++")
  require_golden(status.success?, "clang++ is unavailable")
  sdk, status = Open3.capture2("xcrun", "--show-sdk-path")
  require_golden(status.success?, "macOS SDK is unavailable")
  output = File.join(work_root, "rime_golden_probe")
  _stdout, stderr, status = Open3.capture3(
    compiler.strip, "-isysroot", sdk.strip, "-std=c++17", "-O2", "-Wall", "-Wextra",
    "-Werror", "-isystem", runtime.fetch(:includes), runtime.fetch(:probe_source),
    runtime.fetch(:dylib), "-o", output
  )
  require_golden(status.success?, "golden probe compilation failed:\n#{stderr}")
  output
end

def compile_auto_phrase_probe(runtime, work_root)
  compiler, status = Open3.capture2("xcrun", "--find", "clang++")
  require_golden(status.success?, "clang++ is unavailable")
  sdk, status = Open3.capture2("xcrun", "--show-sdk-path")
  require_golden(status.success?, "macOS SDK is unavailable")
  output = File.join(work_root, "auto_phrase_probe")
  _stdout, stderr, status = Open3.capture3(
    compiler.strip, "-isysroot", sdk.strip, "-std=c++17", "-O2", "-Wall", "-Wextra",
    "-Werror", "-isystem", runtime.fetch(:includes),
    File.join(REPO_ROOT, "tests/auto_phrase_probe.cc"), runtime.fetch(:dylib),
    File.join(REPO_ROOT, "lib/rime-plugins/librime-lua.dylib"), "-o", output
  )
  require_golden(status.success?, "auto-phrase probe compilation failed:\n#{stderr}")
  output
end

def mapping_cases(schema)
  full_pinyin = schema == "linnet_zh_pinyin"
  final_keys = DOUBLE_FINAL_ORACLE[schema]
  initial_keys = INITIAL_OVERRIDES[schema] || {}
  cases = INITIAL_SAMPLES.map do |initial, syllable|
    final = syllable.delete_prefix(initial)
    code = full_pinyin ? syllable : "#{initial_keys.fetch(initial, initial)}#{final_keys.fetch(final)}"
    MappingCase.new(kind: "initial", name: initial, syllable: syllable, code: code)
  end
  cases.concat(FINAL_SAMPLES.map do |final, syllable|
    initial = INITIAL_SAMPLES.keys.sort_by { |candidate| -candidate.length }
      .find { |candidate| syllable.start_with?(candidate) }
    require_golden(initial, "#{schema}: no reviewed initial for #{syllable}")
    code = if full_pinyin
             syllable
           else
             "#{initial_keys.fetch(initial, initial)}#{final_keys.fetch(final)}"
           end
    MappingCase.new(kind: "final", name: final, syllable: syllable, code: code)
  end)
  cases.concat(ZERO_FINAL_ORACLE.fetch(schema).map do |final, code|
    MappingCase.new(kind: "zero-final", name: final, syllable: final, code: code)
  end)
  cases
end

def compile_prism_probe(runtime, work_root)
  compiler, status = Open3.capture2("xcrun", "--find", "clang++")
  require_golden(status.success?, "clang++ is unavailable")
  sdk, status = Open3.capture2("xcrun", "--show-sdk-path")
  require_golden(status.success?, "macOS SDK is unavailable")
  source = File.join(work_root, "prism_mapping_probe.cc")
  File.write(source, <<~'CPP', mode: "w:UTF-8")
    #include <iostream>
    #include <string>
    #include <rime/dict/prism.h>
    #include <rime/dict/table.h>

    int main(int argc, char** argv) {
      if (argc != 3) return 2;
      rime::Table table{rime::path(argv[1])};
      rime::Prism prism{rime::path(argv[2])};
      if (!table.Load() || !prism.Load()) return 3;
      std::string key;
      while (std::getline(std::cin, key)) {
        int spelling_id = -1;
        if (!prism.GetValue(key, &spelling_id)) {
          std::cout << key << "\tMISSING\n";
          continue;
        }
        auto spelling = prism.QuerySpelling(spelling_id);
        while (!spelling.exhausted()) {
          const auto properties = spelling.properties();
          std::cout << key << '\t' << table.GetSyllableById(spelling.syllable_id())
                    << '\t' << static_cast<int>(properties.type) << '\n';
          spelling.Next();
        }
      }
      return 0;
    }
  CPP
  output = File.join(work_root, "prism_mapping_probe")
  boost = File.join(REPO_ROOT, "build/dependencies/boost")
  require_golden(File.directory?(boost), "Boost headers are unavailable")
  _stdout, stderr, status = Open3.capture3(
    compiler.strip, "-isysroot", sdk.strip, "-std=c++17", "-O2", "-Wall", "-Wextra",
    "-Werror", "-DGLOG_USE_GLOG_EXPORT", "-isystem", runtime.fetch(:includes),
    "-isystem", boost, source, runtime.fetch(:dylib), "-o", output
  )
  require_golden(status.success?, "prism mapping probe compilation failed:\n#{stderr}")
  output
end

def normalize_prism_syllable(value)
  value.tr("üǖǘǚǜ", "vvvvv")
    .unicode_normalize(:nfd).gsub(/\p{Mn}/, "").gsub(/[0-9]/, "").downcase
end

def mapping_failures(probe, user, schema, environment)
  cases = mapping_cases(schema)
  keys = cases.map(&:code).uniq
  table = File.join(user, "build", "linnet_zh.table.bin")
  prism = File.join(user, "build", "#{schema}.prism.bin")
  stdout, stderr, status = Open3.capture3(
    environment, probe, table, prism, stdin_data: keys.join("\n") + "\n"
  )
  require_golden(status.success?, "#{schema}: prism mapping probe failed: #{stderr}")
  observed = Hash.new { |hash, key| hash[key] = Set.new }
  stdout.each_line do |line|
    key, syllable, spelling_type = line.chomp.split("\t", 3)
    next if syllable == "MISSING"
    observed[key] << [normalize_prism_syllable(syllable), spelling_type]
  end
  cases.each_with_object([]) do |item, failures|
    next if observed.fetch(item.code, Set.new).include?([item.syllable, "0"])
    failures << "#{schema} #{item.kind}=#{item.name} " \
      "expected #{item.syllable}->#{item.code} normal spelling"
  end
end

def verify_mapping_oracle(probe, user, environment, profiles = PROFILES)
  failures = profiles.flat_map do |schema|
    profile_failures = mapping_failures(probe, user, schema, environment)
    puts "MAPPING #{schema}: rows=#{mapping_cases(schema).length} fail=#{profile_failures.length}"
    profile_failures
  end
  require_golden(failures.empty?, failures.first(20).join("\n"))
end

def verify_mapping_mutation_rejected(runtime, probe, shared, work_root, environment)
  mutation_shared = File.join(work_root, "mapping-mutation-shared")
  FileUtils.cp_r(shared, mutation_shared, preserve: true)
  algebra_path = File.join(mutation_shared, "linnet_algebra.yaml")
  source = File.read(algebra_path, encoding: "UTF-8")
  before = '    - xform/(.)ei(\d)$/$1Ⓦ$2/'
  after = '    - xform/(.)ei(\d)$/$1Ⓠ$2/'
  flypy_start = source.index("\nflypy:\n")
  flypy_end = source.index("\nsogou:\n")
  require_golden(flypy_start && flypy_end && flypy_start < flypy_end,
                 "temporary mapping mutation lost its Flypy section")
  flypy = source[flypy_start...flypy_end]
  require_golden(flypy.scan(before).length == 1,
                 "temporary mapping mutation lost its reviewed Flypy anchor")
  mutated = source[0...flypy_start] + flypy.sub(before, after) + source[flypy_end..-1]
  File.write(algebra_path, mutated, mode: "w:UTF-8")
  mutation_user = File.join(work_root, "mapping-mutation-user")
  Dir.mkdir(mutation_user)
  deploy(runtime, mutation_shared, mutation_user, environment)
  failures = mapping_failures(probe, mutation_user, "linnet_zh_flypy", environment)
  require_golden(failures.any? { |failure| failure.include?("final=ei") },
                 "reviewed mapping oracle accepted a temporary Flypy ei key mutation")
  puts "MAPPING MUTATION: rejected flypy final=ei w->q"
end

def build_active_shared(work_root)
  plum = File.join(REPO_ROOT, "data/plum")
  canonical = File.join(REPO_ROOT, "data/linnet")
  opencc = File.join(REPO_ROOT, "data/opencc")
  require_golden(File.directory?(plum) && File.directory?(opencc), "missing staged runtime input")
  require_golden(File.file?(File.join(plum, "wanxiang-lts-zh-hans.gram")), "missing LTS grammar")
  shared = File.join(work_root, "active-shared")
  Dir.mkdir(shared)
  Dir.children(plum).each do |name|
    next if ["build", "linnet_grammar_active.yaml"].include?(name)
    source = File.join(plum, name)
    target = File.join(shared, name)
    if File.file?(source) && [".yaml", ".lua"].include?(File.extname(source))
      FileUtils.cp(source, target, preserve: true)
    else
      FileUtils.ln_s(source, target)
    end
  end
  Dir.glob(File.join(canonical, "*.schema.yaml")).each do |source|
    FileUtils.cp(source, File.join(shared, File.basename(source)), preserve: true)
  end
  FileUtils.cp(File.join(canonical, "default.yaml"), File.join(shared, "default.yaml"), preserve: true)
  FileUtils.ln_s(opencc, File.join(shared, "opencc"))
  File.write(File.join(shared, "linnet_grammar_active.yaml"),
             "grammar:\n  language: wanxiang-lts-zh-hans\n", mode: "w:UTF-8")
  shared
end

def build_user_dir(work_root)
  user = File.join(work_root, "user")
  Dir.mkdir(user)
  fixture_root = File.join(REPO_ROOT, "tests/fixtures")
  FIXTURE_FILES.each do |candidates|
    source = candidates.map { |name| File.join(fixture_root, name) }.find { |path| File.exist?(path) }
    FileUtils.cp(source, File.join(user, File.basename(source)), preserve: true) if source
  end
  user
end

def product_environment(log_root)
  ENV.to_h.merge(
    "DYLD_LIBRARY_PATH" => [File.join(REPO_ROOT, "lib"), File.join(REPO_ROOT, "lib/rime-plugins")].join(":"),
    "RIME_LOG_DIR" => log_root
  )
end

def deploy(runtime, shared, user, environment)
  stdout, stderr, status = Open3.capture3(
    environment, runtime.fetch(:deployer), "--build", user, shared, File.join(user, "build")
  )
  require_golden(status.success?, "rime_deployer failed:\n#{stdout}\n#{stderr}")
end

def verify_deployed_owner_projection(user)
  default_config = YAML.safe_load(File.read(DEFAULT_CONFIG, encoding: "UTF-8"), aliases: true)
  expected_pattern = default_config.dig("linnet", "recognizer_patterns", "pinyin_reverse_lookup")
  expected_prefix = default_config.dig("linnet", "pinyin_reverse_lookup", "prefix")
  PROFILES.each do |schema|
    path = File.join(user, "build", "#{schema}.schema.yaml")
    require_golden(File.file?(path), "#{schema}: deployed schema is missing")
    text = File.read(path, encoding: "UTF-8")
    deployed = YAML.safe_load(text, aliases: true)
    require_golden(
      text.match?(/^  language: ["']?wanxiang-lts-zh-hans["']?$/),
      "#{schema}: temporary Active profile did not select LTS grammar"
    )
    require_golden(
      deployed.dig("recognizer", "patterns", "linnet_pinyin") == expected_pattern &&
        deployed.dig("linnet_pinyin", "prefix") == expected_prefix,
      "#{schema}: deployed reverse lookup differs from canonical default owner"
    )
  end
end

def run_probe(probe, shared, user, schema, cases, environment)
  input = cases.map(&:code).join("\n") + "\n"
  stdout = stderr = nil
  status = nil
  Timeout.timeout(600) do
    stdout, stderr, status = Open3.capture3(
      environment, probe, shared, user, TOP_N.to_s, schema, stdin_data: input
    )
  end
  require_golden(status.success?, "golden probe failed:\n#{stdout}#{stderr}")
  results = Hash.new { |hash, key| hash[key] = [] }
  current = nil
  cold_ms = nil
  stdout.each_line do |line|
    first, second = line.chomp.split("\t", 2)
    case first
    when "INPUT"
      current = second
      results[current]
    when "COLD_MS"
      cold_ms = Integer(second, 10) rescue cold_ms
    when "END", "REJECT"
      current = nil
    else
      rank = Integer(first, 10) rescue nil
      results[current] << second if current && second && rank && rank < TOP_N
    end
  end
  cases.each { |item| results[item.code] }
  [results, cold_ms]
end

def verify_user_word_absent(by_profile, probe, shared, user, environment)
  PROFILES.each do |schema|
    item = by_profile.fetch(schema).find { |candidate| candidate.case_id == "user_yunshanma" }
    results, = run_probe(probe, shared, user, schema, [item], environment)
    require_golden(!results.fetch(item.code).include?(item.expected),
                   "#{schema}: isolated QA phrase exists before user learning")
  end
end

def seed_user_word(probe, shared, user, environment)
  stdout, stderr, status = Open3.capture3(
    environment, probe, shared, user, "linnet_zh_pinyin",
    stdin_data: "learn 云杉码 yunshanma 云杉 码\n"
  )
  require_golden(status.success? && stdout.include?("LEARN_COMMIT\t云杉码"),
                 "failed to seed user-learning fixture:\n#{stdout}#{stderr}")
end

def run_gate(by_profile)
  runtime = runtime_paths
  failures = []
  temp_root = Dir.mktmpdir("linnet-profile-golden.", "/private/tmp")
  at_exit do
    FileUtils.remove_entry_secure(temp_root) if temp_root&.start_with?("/private/tmp/linnet-profile-golden.") && File.exist?(temp_root)
  end
  begin
    log_root = File.join(temp_root, "logs")
    Dir.mkdir(log_root)
    environment = product_environment(log_root)
    shared = build_active_shared(temp_root)
    user = build_user_dir(temp_root)
    deploy(runtime, shared, user, environment)
    verify_deployed_owner_projection(user)
    mapping_probe = compile_prism_probe(runtime, temp_root)
    verify_mapping_oracle(mapping_probe, user, environment)
    verify_mapping_mutation_rejected(
      runtime, mapping_probe, shared, temp_root, environment)
    probe = compile_probe(runtime, temp_root)
    verify_user_word_absent(by_profile, probe, shared, user, environment)
    seed_probe = compile_auto_phrase_probe(runtime, temp_root)
    seed_user_word(seed_probe, shared, user, environment)

    PROFILES.each do |schema|
      cases = by_profile.fetch(schema)
      results, cold_ms = run_probe(probe, shared, user, schema, cases, environment)
      passed = 0
      maximum_rank = 0
      profile_failures = []
      cases.each do |item|
        rank = results.fetch(item.code).index(item.expected)
        rank = rank ? rank + 1 : 0
        if rank.zero? || rank > item.max_rank
          profile_failures << "#{schema} #{item.case_id} code=#{item.code} " \
            "expected=#{item.expected.inspect} max_rank=#{item.max_rank} " \
            "now=#{results.fetch(item.code).first(5).inspect}"
        else
          passed += 1
          maximum_rank = [maximum_rank, rank].max
        end
      end
      failures.concat(profile_failures)
      puts "PROFILE #{schema}: cases=#{cases.length} pass=#{passed} " \
        "fail=#{profile_failures.length} max_rank=#{maximum_rank} cold_ms=#{cold_ms || "unknown"}"
    end
  ensure
    FileUtils.remove_entry_secure(temp_root) if File.exist?(temp_root)
    temp_root = nil
  end

  failures.first(40).each { |failure| puts "FAIL: #{failure}" }
  unless failures.empty?
    puts "PROFILE GOLDEN FAILED: #{failures.length} case(s)"
    return 1
  end
  puts "PROFILE GOLDEN PASSED: 8 profiles, fixed 215-case corpus + 7 supplements"
  0
end

begin
  fixture_only = ARGV.delete("--fixture-only")
  raise ProfileGoldenError, "unknown arguments" unless ARGV.empty?
  semantic_cases, semantic_digest = load_semantic_corpus
  by_profile = load_profile_fixture(semantic_cases, semantic_digest)
  if fixture_only
    puts "PROFILE FIXTURE PASSED: 8 profiles x (215 canonical + 7 supplemental)"
    exit 0
  end
  exit run_gate(by_profile)
rescue ProfileGoldenError, SystemCallError, Timeout::Error => error
  warn "ERROR: #{error.message}"
  exit 2
end
