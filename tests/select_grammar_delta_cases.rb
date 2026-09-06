require 'csv'
require 'digest'
require 'json'
require 'yaml'
require 'set'
# Usage: ruby tests/select_grammar_delta_cases.rb DELTA.tsv OUTPUT_DIRECTORY
# Exploratory candidates, not independent quality expectations.
require 'fileutils'
abort 'usage: DELTA.tsv OUTPUT_DIRECTORY' unless ARGV.size == 2
input = File.expand_path(ARGV[0])
root = File.expand_path(ARGV[1])
FileUtils.mkdir_p(root)
repo = File.expand_path('..', __dir__)
rows = CSV.read(input, headers: true, col_sep: "\t").map(&:to_h)
readable = rows.select { |r| r['text']&.match?(/\A\p{Han}{2,8}\z/) }
groups = readable.group_by do |r|
  kind = r['change'] == 'reweighted' ? (r['new_weight'].to_i > r['old_weight'].to_i ? 'up' : 'down') : r['change']
  [kind, r['text'].length <= 3 ? '2-3' : r['text'].length <= 5 ? '4-5' : '6-8']
end
selected = groups.values.flat_map { |g| g.sort_by { |r| Digest::SHA256.hexdigest(r['encoded_hex']) }.first(64) }
selected |= readable.select { |r| r['change'] == 'reweighted' }.sort_by { |r| -(r['new_weight'].to_i-r['old_weight'].to_i).abs }.first(64)
needed = selected.flat_map { |r| chars=r['text'].chars; (0...chars.size).flat_map { |i| (i+1..chars.size).map { |j| chars[i...j].join } } }.to_set
readings = Hash.new { |h,k| h[k] = {} }
shared = repo+'/data/plum'
config = YAML.safe_load(File.read(shared+'/linnet_zh.dict.yaml'))
config.fetch('import_tables').each do |table|
  path = shared+"/#{table}.dict.yaml"
  File.foreach(path) do |line|
    word, code, weight = line.chomp.split("\t")
    next unless needed.include?(word) && code
    # Diagnostic query generation only, not an expected-candidate oracle.
    plain = code.unicode_normalize(:nfd).gsub("u\u0308", 'v').gsub(/\p{Mn}/, '').split
    next unless plain.size == word.length && plain.all? { |p| p.match?(/\A[a-z]+\z/) }
    signature = plain.join(' ')
    previous = readings[word][signature]
    readings[word][signature] = {code: plain, weight: weight.to_i, source: table} if !previous || weight.to_i > previous[:weight]
  end
end
selected.each do |row|
  chars = row['text'].chars
  segments = []; i = 0
  while i < chars.size
    ending = (i+1..chars.size).to_a.reverse.find { |j| !readings[chars[i...j].join].empty? }
    break unless ending
    word = chars[i...ending].join
    options = readings[word].values.sort_by { |r| [-r[:weight], r[:code]] }
    segments << options.first.merge(text: word, reading_count: options.size)
    i = ending
  end
  row['segments'] = segments
  row['code'] = segments.flat_map { |r| r[:code] }.join if i == chars.size
end
excluded = {unreadable: rows.count { |r| r['text'].to_s.empty? }, rear_marker: rows.count { |r| r['text']&.end_with?('$') }}
File.write(root+'/delta-cases.json', JSON.pretty_generate({groups: groups.transform_keys { |k| k.join(':') }.transform_values(&:size), total_delta: rows.size, readable_han: readable.size, excluded: excluded, cases: selected})+"\n")
File.write(root+'/delta-inputs.txt', selected.map { |r| r['code'] }.compact.uniq.join("\n")+"\n")
puts JSON.generate(selected: selected.size, coded: selected.count { |r| r['code'] }, ambiguous: selected.count { |r| r['segments'].any? { |s| s[:reading_count] > 1 } })
