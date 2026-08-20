#!/usr/bin/env ruby

require "csv"
require "digest"
require "fileutils"
require "open3"
require "set"
require "tempfile"
require "timeout"

class ProfileGoldenError < StandardError; end

SemanticCase = Struct.new(:case_id, :category, :full_pinyin, keyword_init: true)
ProfileCase = Struct.new(
  :case_id, :classification, :schema, :code, :expected, :max_rank,
  keyword_init: true
)

REPO_ROOT = File.expand_path("..", __dir__)
SEMANTIC_CORPUS = File.join(REPO_ROOT, "data/chinese/golden/input_corpus.txt")
PROFILE_FIXTURE = File.join(REPO_ROOT, "tests/fixtures/chinese_profile_golden.tsv")
CANONICAL_CASES = 215
TOP_N = 20
PROFILES = %w[
  linnet_zh_pinyin linnet_zh linnet_zh_flypy linnet_zh_mspy
  linnet_zh_sogou linnet_zh_abc linnet_zh_ziguang linnet_zh_jiajia
].freeze
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
    require_golden(profile_case.code.match?(/\A[A-Za-z;]+\z/),
                   "fixture row #{index + 1}: invalid fixed code")
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

def build_active_shared(work_root)
  plum = File.join(REPO_ROOT, "data/plum")
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

def verify_lts_projection(user)
  PROFILES.each do |schema|
    path = File.join(user, "build", "#{schema}.schema.yaml")
    text = File.file?(path) ? File.read(path, encoding: "UTF-8") : ""
    require_golden(
      text.match?(/^  language: ["']?wanxiang-lts-zh-hans["']?$/),
      "#{schema}: temporary Active profile did not select LTS grammar"
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
    verify_lts_projection(user)
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
