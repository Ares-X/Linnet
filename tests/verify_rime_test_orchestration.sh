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

matrix_source = runtime[/profile_cases=\(\n(.*?)\n\)/m, 1]
abort "Rime profile matrix is missing" unless matrix_source
actual = matrix_source.scan(/'([^']+)'/).flatten
expected = [
  "semicolon:natural:linnet_zh:srfa",
  "semicolon:full_pinyin:linnet_zh_pinyin:suanfa",
  "semicolon:flypy:linnet_zh_flypy:srfa",
  "semicolon:microsoft:linnet_zh_mspy:srfa",
  "semicolon:sogou:linnet_zh_sogou:srfa",
  "semicolon:abc:linnet_zh_abc:spfa",
  "semicolon:ziguang:linnet_zh_ziguang:slfa",
  "semicolon:jiajia:linnet_zh_jiajia:scfa",
  "vertical_bar:microsoft:linnet_zh_mspy:srfa",
]
abort "Rime profile matrix lost an owner or regained a redundant cross-product" unless
  actual == expected
RUBY

echo "Linnet Rime test orchestration: PASS (bounded latency sample and orthogonal profile/trigger matrix)"
