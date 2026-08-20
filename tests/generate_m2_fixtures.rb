#!/usr/bin/env ruby

# Copyright Linnet contributors
# SPDX-License-Identifier: GPL-3.0-or-later

require "fileutils"
require "optparse"
require "tmpdir"

class FixtureError < StandardError; end

module M2Fixtures
  REPO_ROOT = File.expand_path("..", __dir__)
  FIXTURE_ROOT = File.join(__dir__, "fixtures")
  GOLDEN_ROOT = File.join(FIXTURE_ROOT, "m2_generated")
  LEXICON_PATH = File.join(FIXTURE_ROOT, "m2_smart_english_lexicon.tsv")
  BIGRAM_PATH = File.join(FIXTURE_ROOT, "m2_smart_english_bigrams.tsv")
  CASES_PATH = File.join(FIXTURE_ROOT, "m2_smart_english_cases.tsv")
  DICTIONARY_NAME = "linnet_m2_fixture_en.dict.yaml"
  INDEX_NAME = "linnet_m2_fixture.smart-index.tsv"
  OUTPUT_NAMES = [DICTIONARY_NAME, INDEX_NAME].freeze

  LEXICON_COLUMNS = %w[
    word code weight ipa zh phonex pinyin
  ].freeze
  BIGRAM_COLUMNS = %w[context next weight].freeze
  CASE_COLUMNS = %w[kind query expected].freeze
  METADATA_FIELDS = %w[ipa zh].freeze
  WORD_PATTERN = /\A[a-z]+\z/
  SUFFIX_PATTERN = /\A'[a-z]+\z/

  module_function

  def parse_tsv(path, expected_columns, fixture_name)
    source = File.binread(path).force_encoding(Encoding::UTF_8)
    raise FixtureError, "#{fixture_name} is not valid UTF-8" unless source.valid_encoding?
    raise FixtureError, "#{fixture_name} uses CR line endings" if source.include?("\r")

    columns = nil
    rows = []
    source.each_line(chomp: true).with_index(1) do |line, line_number|
      next if line.empty? || line.start_with?("#")

      fields = line.split("\t", -1)
      if columns.nil?
        unless fields == expected_columns
          raise FixtureError, "#{fixture_name} has an unexpected header"
        end
        columns = fields
        next
      end
      unless fields.length == columns.length && fields.none?(&:empty?)
        raise FixtureError,
              "#{fixture_name} has an invalid row at line #{line_number}"
      end
      rows << columns.zip(fields).to_h
    end
    raise FixtureError, "#{fixture_name} is missing its header" unless columns
    raise FixtureError, "#{fixture_name} has no records" if rows.empty?

    rows
  end

  def positive_integer(value, fixture_name)
    unless value.match?(/\A[1-9][0-9]*\z/)
      raise FixtureError, "#{fixture_name} contains an invalid weight"
    end
    value.to_i
  end

  def context_tokens(value)
    tokens = value.split(" ", -1)
    return nil unless tokens.length.between?(1, 4)

    tokens.each_with_index do |token, index|
      next if token.match?(WORD_PATTERN)
      return nil unless token.match?(SUFFIX_PATTERN) && index.positive? &&
                        tokens.fetch(index - 1).match?(WORD_PATTERN)
    end
    tokens
  end

  def load_model
    lexicon = parse_tsv(LEXICON_PATH, LEXICON_COLUMNS, "lexicon fixture")
    bigrams = parse_tsv(BIGRAM_PATH, BIGRAM_COLUMNS, "bigram fixture")
    cases = parse_tsv(CASES_PATH, CASE_COLUMNS, "case fixture")
    seen_words = {}

    lexicon.each do |entry|
      word = entry.fetch("word")
      unless word.match?(WORD_PATTERN) &&
             entry.fetch("code").match?(WORD_PATTERN)
        raise FixtureError, "lexicon fixture contains a non-canonical word"
      end
      raise FixtureError, "lexicon fixture contains a duplicate word" if seen_words[word]
      seen_words[word] = true

      entry["weight"] = positive_integer(entry.fetch("weight"), "lexicon fixture")
      unless entry.fetch("ipa").match?(/\A\/[^\s\/]+\/\z/u) &&
             entry.fetch("zh").match?(/\A\S+\z/u) &&
             entry.fetch("phonex").match?(/\A[A-Z][A-Z0-9]*\z/)
        raise FixtureError, "lexicon fixture contains invalid metadata"
      end

      pinyin = entry.fetch("pinyin").split("|", -1)
      unless pinyin.uniq.length == pinyin.length &&
             pinyin.all? { |value| value.match?(/\A[a-z]+\z/) }
        raise FixtureError, "lexicon fixture contains invalid pinyin"
      end
      entry["pinyin"] = pinyin
    end
    verify_dictionary_entries!(lexicon, "lexicon fixture")

    bigrams.each do |entry|
      tokens = context_tokens(entry.fetch("context"))
      next_word = entry.fetch("next")
      unless tokens && tokens.grep(WORD_PATTERN).all? { |word| seen_words[word] } &&
             (seen_words[next_word] || next_word.match?(SUFFIX_PATTERN))
        raise FixtureError, "bigram fixture refers to an unknown word"
      end
      entry["weight"] = positive_integer(entry.fetch("weight"), "bigram fixture")
    end
    pairs = bigrams.map { |entry| [entry.fetch("context"), entry.fetch("next")] }
    raise FixtureError, "bigram fixture contains a duplicate edge" unless pairs.uniq == pairs

    validate_cases!(cases, seen_words, pairs)

    [lexicon, bigrams]
  end

  def verify_dictionary_entries!(entries, fixture_name)
    overflow = entries.select { |entry| entry.fetch("word").start_with?("overflow") }
    ordinary = entries - overflow
    unless ordinary.all? { |entry| entry.fetch("code") == entry.fetch("word") }
      raise FixtureError, "#{fixture_name} contains a non-identity ordinary code"
    end
    unless overflow.length == 65 &&
           overflow.all? { |entry| entry.fetch("code") == "overflo" } &&
           overflow.map { |entry| entry.fetch("weight") } == 700.downto(636).to_a &&
           overflow.last.fetch("word") == "overfloweeo"
      raise FixtureError, "#{fixture_name} lost its deterministic 65-candidate dictionary overflow"
    end
  end

  def validate_cases!(cases, seen_words, static_pairs)
    expected_kinds = %w[
      correction_deletion correction_insertion correction_substitution
      correction_transposition contraction prediction_learned_only
      prediction_static phonex_overflow pinyin_order pinyin_overflow
    ]
    unless cases.map { |entry| entry.fetch("kind") }.sort == expected_kinds.sort
      raise FixtureError, "case fixture does not contain the exact M2 P0 set"
    end

    cases.each do |entry|
      kind = entry.fetch("kind")
      query = entry.fetch("query")
      expected = entry.fetch("expected")
      case kind
      when /\Acorrection_/
        unless query.match?(WORD_PATTERN) && seen_words[expected] && query != expected
          raise FixtureError, "correction case is not anchored to a dictionary word"
        end
      when "contraction", "prediction_static"
        unless context_tokens(query) && static_pairs.include?([query, expected])
          raise FixtureError, "static prediction case has no exact index row"
        end
      when "prediction_learned_only"
        unless context_tokens(query) && seen_words[expected] &&
               static_pairs.none? { |context, _| context == query }
          raise FixtureError, "learned-only case gained a static prediction row"
        end
      when "phonex_overflow", "pinyin_overflow"
        unless query.match?(WORD_PATTERN) && expected == "<none>"
          raise FixtureError, "overflow case is malformed"
        end
      when "pinyin_order"
        words = expected.split("|", -1)
        unless query.match?(WORD_PATTERN) && words.length >= 2 &&
               words.uniq == words && words.all? { |word| seen_words[word] }
          raise FixtureError, "pinyin order case is malformed"
        end
      end
    end
  end

  def byte_key(value)
    value.encode(Encoding::UTF_8).bytes
  end

  def render_dictionary(lexicon)
    header = <<~YAML
      # Generated from project-authored test fixtures; do not ship.
      # SPDX-License-Identifier: GPL-3.0-or-later
      ---
      name: linnet_m2_fixture_en
      version: "fixture-v1"
      sort: by_weight
      use_preset_vocabulary: false
      columns:
        - text
        - code
        - weight
      ...
    YAML
    body = lexicon.sort_by do |entry|
      [byte_key(entry.fetch("code")), -entry.fetch("weight"), byte_key(entry.fetch("word"))]
    end.map do |entry|
      [entry.fetch("word"), entry.fetch("code"), entry.fetch("weight")].join("\t")
    end.join("\n")
    "#{header}#{body}\n"
  end

  def add_index_row(rows, key, value, weight)
    ordinary_key = key.match?(/\A(?:m\/(?:ipa|zh)|f|p)\/[a-zA-Z0-9'-]+\z/)
    prediction_key = key.start_with?("n/") && context_tokens(key.delete_prefix("n/"))
    unless key.ascii_only? && (ordinary_key || prediction_key) &&
           !value.match?(/\s/u)
      raise FixtureError, "generated index contains an invalid key or value"
    end
    rows << [key, value, weight]
  end

  def render_index(lexicon, bigrams)
    rows = []
    pinyin_candidates = Hash.new { |values, key| values[key] = [] }
    lexicon.each do |entry|
      word = entry.fetch("word")
      METADATA_FIELDS.each do |field|
        add_index_row(rows, "m/#{field}/#{word}", entry.fetch(field), entry.fetch("weight"))
      end
      add_index_row(rows, "f/#{entry.fetch('phonex')}", word, entry.fetch("weight"))
      entry.fetch("pinyin").each do |pinyin|
        pinyin_candidates[pinyin] << word
      end
    end
    # Mirror the production pinyin projection: retain at most 64 candidates
    # in source order and encode the fixed 64..1 rank contract consumed by
    # Rime::Predict/2.0. The 65-word phonex bucket remains intact so the
    # independent raw-candidate overflow probe still crosses its boundary.
    pinyin_candidates.each do |pinyin, candidates|
      candidates.first(64).each_with_index do |word, rank|
        add_index_row(rows, "p/#{pinyin}", word, 64 - rank)
      end
    end
    bigrams.each do |entry|
      add_index_row(
        rows,
        "n/#{entry.fetch('context')}",
        entry.fetch("next"),
        entry.fetch("weight")
      )
    end

    identities = rows.map { |key, value, _weight| [key, value] }
    raise FixtureError, "generated index contains a duplicate entry" unless identities.uniq == identities

    rows.sort_by do |key, value, weight|
      [byte_key(key), -weight, byte_key(value)]
    end.map { |row| row.join("\t") }.join("\n") + "\n"
  end

  def build_outputs
    lexicon, bigrams = load_model
    {
      DICTIONARY_NAME => render_dictionary(lexicon),
      INDEX_NAME => render_index(lexicon, bigrams)
    }
  end

  def projected_real_path(path)
    expanded = File.expand_path(path)
    suffix = []
    cursor = expanded
    until File.exist?(cursor) || File.symlink?(cursor)
      parent = File.dirname(cursor)
      raise FixtureError, "output path has no existing parent" if parent == cursor
      suffix.unshift(File.basename(cursor))
      cursor = parent
    end
    File.join(File.realpath(cursor), *suffix)
  end

  def reject_product_data_output!(output_root)
    data_root = File.realpath(File.join(REPO_ROOT, "data"))
    destination = projected_real_path(output_root)
    if destination == data_root || destination.start_with?("#{data_root}#{File::SEPARATOR}")
      raise FixtureError, "test fixtures cannot be written into product data"
    end
  end

  def write_outputs(output_root, outputs)
    reject_product_data_output!(output_root)
    FileUtils.mkdir_p(output_root)
    outputs.each do |name, bytes|
      target = File.join(output_root, name)
      temporary = File.join(output_root, ".#{name}.#{$$}.tmp")
      begin
        File.binwrite(temporary, bytes)
        File.rename(temporary, target)
      ensure
        FileUtils.rm_f(temporary)
      end
    end
  end

  def read_outputs(root)
    OUTPUT_NAMES.to_h { |name| [name, File.binread(File.join(root, name))] }
  end

  def verify_index!(bytes)
    source = bytes.dup.force_encoding(Encoding::UTF_8)
    raise FixtureError, "generated index is not valid UTF-8" unless source.valid_encoding?
    rows = source.lines(chomp: true).map { |line| line.split("\t", -1) }
    unless rows.all? { |row| row.length == 3 && row.fetch(2).match?(/\A[1-9][0-9]*\z/) }
      raise FixtureError, "generated index is not build_predict-compatible TSV"
    end

    pairs = rows.to_h { |key, value, _weight| [[key, value], true] }
    required = [
      ["m/ipa/cloud", "/klaʊd/"],
      ["m/zh/cloud", "云"],
      ["f/N230", "night"],
      ["f/N230", "knight"],
      ["p/yun", "cloud"],
      ["n/hello", "world"],
      ["n/hello", "cloud"],
      ["n/he", "'s"],
      ["n/he 's", "not"],
      ["n/i do not", "know"]
    ]
    raise FixtureError, "generated index lost a namespace contract" unless required.all? { |pair| pairs[pair] }

    grouped = rows.group_by(&:first)
    unless grouped.fetch("f/A14").length == 65 &&
           grouped.fetch("p/overflow").length == 64 &&
           grouped.fetch("p/overflow").map { |row| row.fetch(2).to_i } == 64.downto(1).to_a
      raise FixtureError, "overflow cardinality fixture changed"
    end
    pinyin_order = grouped.fetch("p/pailie").map { |row| row.fetch(1) }
    unless pinyin_order == %w[overflow overflowa overflowe]
      raise FixtureError, "pinyin multi-value order fixture changed"
    end
    if grouped.key?("n/privacy cloud")
      raise FixtureError, "learned-only context gained static data"
    end
  end

  def verify_dictionary!(bytes)
    source = bytes.dup.force_encoding(Encoding::UTF_8)
    raise FixtureError, "generated dictionary is not valid UTF-8" unless source.valid_encoding?
    header, body = source.split("...\n", 2)
    unless header && body &&
           header.include?("name: linnet_m2_fixture_en\n") &&
           header.include?("columns:\n  - text\n  - code\n  - weight\n")
      raise FixtureError, "generated dictionary lost its Rime header contract"
    end
    rows = body.lines(chomp: true).map { |line| line.split("\t", -1) }
    unless !rows.empty? && rows.all? do |row|
             word, code, weight = row
             row.length == 3 && word.match?(WORD_PATTERN) &&
               code.match?(WORD_PATTERN) && weight.match?(/\A[1-9][0-9]*\z/)
           end
      raise FixtureError, "generated dictionary has an invalid Rime entry"
    end
    entries = rows.map do |word, code, weight|
      {"word" => word, "code" => code, "weight" => Integer(weight)}
    end
    verify_dictionary_entries!(entries, "generated dictionary")
  end

  def verify!
    expected = build_outputs
    Dir.mktmpdir("linnet-m2-fixture-a-") do |first_root|
      Dir.mktmpdir("linnet-m2-fixture-b-") do |second_root|
        write_outputs(first_root, expected)
        write_outputs(second_root, build_outputs)
        first = read_outputs(first_root)
        second = read_outputs(second_root)
        unless first == second
          raise FixtureError, "two fixture generations are not byte-identical"
        end

        golden = read_outputs(GOLDEN_ROOT)
        raise FixtureError, "checked-in generated fixtures are stale" unless first == golden
        verify_dictionary!(first.fetch(DICTIONARY_NAME))
        verify_index!(first.fetch(INDEX_NAME))
      end
    end
    puts "generate_m2_fixtures: PASS (2 byte-identical outputs)"
  end
end

options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: tests/generate_m2_fixtures.rb (--check | --output DIR)"
  opts.on("--check", "--verify", "verify deterministic output and checked-in fixtures") do
    options[:verify] = true
  end
  opts.on("--output DIR", "write the two generated test fixtures") do |directory|
    options[:output] = directory
  end
end

begin
  parser.parse!
  operation_count = (options[:verify] ? 1 : 0) + (options.key?(:output) ? 1 : 0)
  if !ARGV.empty? || operation_count != 1 || options[:output] == ""
    raise FixtureError, "choose exactly one operation"
  end

  if options[:verify]
    M2Fixtures.verify!
  else
    M2Fixtures.write_outputs(options.fetch(:output), M2Fixtures.build_outputs)
    puts "generate_m2_fixtures: wrote 2 deterministic test outputs"
  end
rescue OptionParser::ParseError, FixtureError => error
  warn "generate_m2_fixtures: ERROR: #{error.message}"
  exit 1
rescue SystemCallError
  warn "generate_m2_fixtures: ERROR: filesystem operation failed"
  exit 1
end
