#!/usr/bin/env ruby

require "digest"
require "json"
require "set"

ROOT = File.expand_path("..", __dir__)
MAPPING_PATH = File.join(ROOT, "data/chinese/reports/enriched_pinyin_english.json")
REVIEW_PATH = File.join(ROOT, "data/chinese/reports/enriched_pinyin_embarrassing_review.tsv")
EMBARGO_PATH = File.join(ROOT, "data/chinese/reports/pinyin_embargo_remove.tsv")

TOP_1 = {
  "suanfa" => "algorithm", "huzhao" => "passport", "zong" => "total",
  "cheng" => "ride", "zu" => "enough", "su" => "speed", "qin" => "relative",
  "sihou" => "time", "zhinengti" => "agent", "xiecheng" => "coroutine",
  "bingfa" => "concurrency", "xiaoxi" => "message", "chengxu" => "program",
  "duotai" => "polymorphism", "yunjisuan" => "cloud computing",
  "kaiyuan" => "open source", "damoxing" => "large language model",
  "duilie" => "queue", "shuzihua" => "digitalization", "daishu" => "algebra",
  "juzhen" => "matrix", "tongji" => "statistics", "jisuanji" => "computer",
  "jiemi" => "decrypt", "xunihua" => "virtualization", "jiqiren" => "robot",
  "jihe" => "set", "daoshu" => "derivative", "xiangliang" => "vector",
  "wangluo" => "network", "xieyi" => "protocol", "jiekou" => "interface",
  "duixiang" => "object", "jicheng" => "inherit", "biancheng" => "programming",
  "bu" => "no", "shuo" => "say", "yun" => "cloud", "he" => "and",
  "ni" => "you", "de" => "of", "chu" => "out", "fa" => "send",
}.freeze
CONTAINS = {
  "xuliehua" => "serialize", "duotai" => "polymorphism", "xiancheng" => "thread",
  "jincheng" => "process", "bianyi" => "compile", "moxing" => "model",
  "ceshi" => "test", "jingtai" => "static", "cunchu" => "storage",
  "jihe" => "geometry", "daoshu" => "reciprocal", "xiangliang" => "resounding",
  "wangluo" => "internet", "xieyi" => "agreement", "jiekou" => "connector",
  "duixiang" => "partner", "jicheng" => "integrated", "biancheng" => "become",
}.freeze
CONTAINS_ALL = {
  "bu" => %w[no not], "shuo" => %w[say speak], "yun" => %w[cloud],
  "he" => %w[and with], "ni" => %w[you], "de" => %w[of],
  "chu" => %w[out exit leave], "fa" => %w[send fine],
}.freeze
FORBIDDEN = Set.new(%w[
  modle moel instal fixe sequetyped cain't out-countenance extersory orderin
  gonest wentest betterest getted doggest lovedest lovingest
]).freeze
KEY_FORBIDDEN = { "zhinengti" => Set.new(["a gent"]) }.freeze

def require_quality(condition, message)
  raise message unless condition
end

def printable_ascii?(candidate)
  !candidate.empty? && candidate.match?(/[A-Za-z]/) &&
    candidate.bytes.all? { |byte| byte.between?(32, 126) }
end

def load_embargo
  seen = Set.new
  pairs = []
  File.foreach(EMBARGO_PATH, chomp: true, encoding: "UTF-8") do |line|
    next if line.empty? || line.start_with?("#", "pinyin_key\t")
    fields = line.split("\t", -1)
    require_quality(fields.length == 2, "invalid embargo ledger row")
    pair = [fields[0], fields[1].downcase]
    require_quality(seen.add?(pair), "duplicate embargo ledger pair")
    pairs << pair
  end
  require_quality(!pairs.empty?, "empty embargo ledger")
  pairs
end

def verify_review_queue(mapping)
  lines = File.readlines(REVIEW_PATH, chomp: true, encoding: "UTF-8")
  require_quality(lines.first == "pinyin_key\trank\tcandidate", "invalid review header")
  previous = nil
  lines.drop(1).each do |line|
    key, rank_text, candidate = line.split("\t", -1)
    require_quality(key && rank_text&.match?(/\A[0-9]+\z/) && candidate, "invalid review row")
    rank = rank_text.to_i
    values = mapping.fetch(key, [])
    require_quality(rank.between?(1, values.length), "review rank is unreachable")
    require_quality(values[rank - 1] == candidate, "review row is stale")
    identity = [key.b, rank, candidate.b]
    require_quality(previous.nil? || (previous <=> identity) == -1, "review rows are not sorted")
    previous = identity
  end
end

begin
  payload = File.binread(MAPPING_PATH)
  mapping = JSON.parse(payload)
  require_quality(mapping.is_a?(Hash) && !mapping.empty?, "snapshot must be a non-empty object")
  previous = nil
  candidates_total = 0
  forbidden_locations = Hash.new { |hash, key| hash[key] = [] }
  mapping.each do |key, candidates|
    require_quality(previous.nil? || previous < key.b, "snapshot keys are not byte-sorted")
    previous = key.b
    require_quality(key.match?(/\A[a-z]+\z/), "invalid key: #{key.inspect}")
    require_quality(candidates.is_a?(Array) && !candidates.empty?, "empty candidates: #{key}")
    require_quality(candidates.length <= 64, "candidate cap exceeded: #{key}")
    lowered = candidates.map(&:downcase)
    require_quality(lowered.length == lowered.uniq.length, "case-insensitive duplicate: #{key}")
    require_quality(candidates.all? { |candidate| candidate.is_a?(String) && printable_ascii?(candidate) },
                    "non-printable candidate: #{key}")
    candidates_total += candidates.length
    lowered.each { |candidate| forbidden_locations[candidate] << key if FORBIDDEN.include?(candidate) }
  end
  TOP_1.each do |key, expected|
    require_quality(mapping.fetch(key, [nil]).first.downcase == expected,
                    "#{key} top-1 must be #{expected.inspect}")
  end
  CONTAINS.each do |key, expected|
    require_quality(mapping.fetch(key, []).map(&:downcase).include?(expected),
                    "#{key} must contain #{expected.inspect}")
  end
  CONTAINS_ALL.each do |key, expected|
    actual = Set.new(mapping.fetch(key, []).map(&:downcase))
    require_quality(Set.new(expected).subset?(actual), "#{key} is missing reviewed senses")
  end
  require_quality(forbidden_locations.empty?, "confirmed non-words remain")
  KEY_FORBIDDEN.each do |key, forbidden|
    actual = Set.new(mapping.fetch(key, []).map(&:downcase))
    require_quality((actual & forbidden).empty?, "#{key} retains wrong-sense candidates")
  end
  leaked = load_embargo.select do |key, candidate|
    mapping.fetch(key, []).map(&:downcase).include?(candidate)
  end
  require_quality(leaked.empty?, "embargo ledger pairs reappeared")
  verify_review_queue(mapping)
  puts "verify-pinyin-english-quality: PASS " \
    "(#{mapping.length} keys, #{candidates_total} candidates, sha256 #{Digest::SHA256.hexdigest(payload)})"
rescue JSON::ParserError, SystemCallError, StandardError => error
  warn "verify-pinyin-english-quality: FAIL: #{error.message}"
  exit 1
end
