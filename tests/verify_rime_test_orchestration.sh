#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

ruby - tests/rime_smoke_test.cc tests/verify_rime_runtime.sh <<'RUBY'
smoke = File.binread(ARGV.fetch(0))
runtime = File.binread(ARGV.fetch(1))

warmup = smoke[/constexpr size_t kLatencyWarmupSamples = (\d+);/, 1]&.to_i
samples = smoke[/constexpr size_t kLatencySamples = (\d+);/, 1]&.to_i
abort "Rime latency sample contract is missing" unless warmup && samples
abort "Rime latency warm-up regained benchmark-scale repetition" unless warmup <= 1_024
abort "Rime latency gate regained benchmark-scale repetition" unless samples <= 8_192
abort "Rime p99 gate has fewer than 80 tail observations" unless samples / 100 >= 80

abort "Rime profile gate regained the full trigger/profile Cartesian product" if
  runtime.include?("for trigger in semicolon vertical_bar; do")

retired_probes = %w[
  --shift-probe --core-shift-overlap-probe --prediction-layout-probe
  --partial-return-probe --single-key-ranking-probe
]
returned = retired_probes.select { |probe| smoke.include?(probe) || runtime.include?(probe) }
abort "retired overlapping Rime probes returned: #{returned.join(", ")}" unless returned.empty?
abort "the formal product-key matrix lost its single focused entrypoint" unless
  smoke.scan("--profile-key-matrix-probe").length == 2 &&
    runtime.scan("--profile-key-matrix-probe").length == 3

remaining_punctuation = smoke[/void ExpectNonFormalPunctuationBoundaries.*?^\}/m]
abort "the non-formal punctuation owner is missing" unless remaining_punctuation
formal_symbols = ["/", ",", ".", ":", ";", "'", "[", "]", "-", "=", "|"]
duplicated = formal_symbols.select do |symbol|
  remaining_punctuation.match?(/,\s*"#{Regexp.escape(symbol)}",/)
end
abort "formal symbols returned to the generic punctuation owner: #{duplicated.join}" unless
  duplicated.empty?

matrix_source = runtime[/profile_cases=\(\n(.*?)\n\)/m, 1]
abort "Rime profile matrix is missing" unless matrix_source
actual = matrix_source.scan(/'([^']+)'/).flatten
expected = [
  "vertical_bar:natural:linnet_zh:srfa",
  "vertical_bar:full_pinyin:linnet_zh_pinyin:suanfa",
  "vertical_bar:flypy:linnet_zh_flypy:srfa",
  "vertical_bar:microsoft:linnet_zh_mspy:srfa",
  "vertical_bar:sogou:linnet_zh_sogou:srfa",
  "vertical_bar:abc:linnet_zh_abc:spfa",
  "vertical_bar:ziguang:linnet_zh_ziguang:slfa",
  "vertical_bar:jiajia:linnet_zh_jiajia:scfa",
  "semicolon:microsoft:linnet_zh_mspy:srfa",
]
abort "Rime profile matrix lost an owner or regained a redundant cross-product" unless
  actual == expected
RUBY

echo "Linnet Rime test orchestration: PASS (bounded latency sample and orthogonal profile/trigger matrix)"
