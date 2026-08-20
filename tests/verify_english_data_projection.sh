#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

generator=build/linnet-english-data-generator
cache=build/linnet-english-cache
[[ -x "${generator}" && "$(lipo -archs "${generator}")" == arm64 ]] || {
  echo "verify_english_data_projection: native generator is missing" >&2
  exit 1
}
expected=$'linnet.english-data-manifest.json\nlinnet.smart-index.tsv\nlinnet.smart.db\nlinnet_en.dict.yaml'
actual="$(find "${cache}" -mindepth 1 -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort)"
[[ "${actual}" == "${expected}" ]] || {
  echo "verify_english_data_projection: cache inventory changed" >&2
  exit 1
}

ruby -rjson -rdigest -e '
  root, cache = ARGV
  manifest_path = File.join(cache, "linnet.english-data-manifest.json")
  manifest = JSON.parse(File.read(manifest_path))
  lock = JSON.parse(File.read(File.join(root, "upstreams.lock.json"))).fetch("sources")
  abort "native generator identity changed" unless
    manifest.fetch("format") == 4 &&
      manifest.fetch("generator") == {"name" => "LinnetEnglishDataGenerator", "version" => 1}
  %w[hallelujah rime_ice].each do |name|
    source = manifest.fetch("sources").fetch(name)
    expected = lock.fetch(name)
    %w[repository tag commit tree].each do |field|
      abort "#{name} #{field} differs from the lock" unless source.fetch(field) == expected.fetch(field)
    end
  end
  local_inputs = {
    "curated_ipa" => "data/linnet/linnet_en_ipa_overrides.tsv",
    "curated_new_words" => "data/linnet/linnet_en_zh_new_words.tsv",
    "curated_translations" => "data/linnet/linnet_en_zh_decisions_final.tsv",
    "enriched_pinyin" => "data/chinese/reports/enriched_pinyin_english.json",
    "pinyin_embargo" => "data/chinese/reports/pinyin_embargo_remove.tsv",
  }
  abort "English projection source set changed" unless
    manifest.fetch("sources").keys.sort == (local_inputs.keys + %w[hallelujah rime_ice]).sort
  local_inputs.each do |name, relative_path|
    source = manifest.fetch("sources").fetch(name)
    input = File.join(root, relative_path)
    abort "#{name} source path changed" unless source.fetch("input") == relative_path
    abort "#{name} source bytes changed after generation" unless
      File.size(input) == source.fetch("bytes")
    abort "#{name} source digest changed after generation" unless
      Digest::SHA256.file(input).hexdigest == source.fetch("sha256")
  end
  outputs = manifest.fetch("outputs")
  expected_outputs = %w[linnet.smart-index.tsv linnet.smart.db linnet_en.dict.yaml]
  abort "projection output set changed" unless outputs.keys.sort == expected_outputs.sort
  outputs.each do |name, contract|
    path = File.join(cache, name)
    abort "projection artifact is missing" unless File.file?(path) && !File.symlink?(path)
    abort "projection artifact byte count changed after generation" unless File.size(path) == contract.fetch("bytes")
    abort "projection artifact digest changed after generation" unless
      Digest::SHA256.file(path).hexdigest == contract.fetch("sha256")
  end
  counts = manifest.fetch("projection_counts")
  namespaces = counts.fetch("namespace_rows")
  abort "smart namespace set changed" unless namespaces.keys.sort == %w[f m/ipa m/skip m/zh n p].sort
  abort "smart row total is inconsistent" unless namespaces.values.sum == counts.fetch("smart_index_rows")
  abort "English projection lost its production vocabulary" unless
    counts.fetch("dictionary_entries") >= 140_000 &&
      counts.fetch("smart_index_rows") >= 4_000_000 &&
      counts.fetch("pinyin_edges") == namespaces.fetch("p")
  puts "English data projection: PASS (#{counts.fetch("dictionary_entries")} words, #{counts.fetch("smart_index_rows")} smart rows)"
' "${repo_root}" "${cache}"

rg -Fq 'name: linnet_en' "${cache}/linnet_en.dict.yaml"
rg -q $'^deserialization\tdeserialization\t45364$' \
  "${cache}/linnet_en.dict.yaml"
rg -q $'^m/zh/serialization\tn. 序列化\t' \
  "${cache}/linnet.smart-index.tsv"
rg -q $'^m/zh/deserialization\tn. 反序列化\t45364$' \
  "${cache}/linnet.smart-index.tsv"
rg -q $'^f/D264235\tdeserialization\t45364$' \
  "${cache}/linnet.smart-index.tsv"

# Curated translations have one data owner. Keep representative modern
# programming, systems, data, and AI terms precise in the generated index
# without adding a runtime translation rule or a second lexicon.
while IFS=$'\t' read -r term gloss; do
  expected=$'m/zh/'"${term}"$'\t'"${gloss}"$'\t'
  rg -Fq -- "${expected}" "${cache}/linnet.smart-index.tsv" || {
    echo "verify_english_data_projection: missing curated gloss for ${term}" >&2
    exit 1
  }
done <<'LINNET_GLOSSES'
WebSocket	n. WebSocket 协议
agent	n. 智能体
agents	n. 智能体
asynchronously	adv. 异步地
client	n. 客户端
clients	n. 客户端
cluster	n. 集群
commit	v. 提交
commits	n. 提交；v. 提交
committing	v. 提交
compilation	n. 编译
concurrency	n. 并发
coroutine	n. 协程
dataset	n. 数据集
dependency	n. 依赖
deserialized	adj. 已反序列化
deserializing	v. 反序列化
embedding	n. 嵌入
hash	n. 哈希；v. 哈希计算
hashes	n. 哈希；v. 哈希计算
hashing	n. 哈希计算
logging	n. 日志记录
migrate	v. 迁移
migration	n. 迁移
package	n. 软件包
packages	n. 软件包
parser	n. 解析器
pipeline	n. 流水线
process	n. 进程
processes	n. 进程
queried	v. 查询
queries	n. 查询；v. 查询
query	n. 查询
querying	v. 查询
queue	n. 队列；v. 入队
queued	adj. 已入队
queueing	n. 排队；入队操作
queues	n. 队列；v. 入队
queuing	n. 排队；入队操作
renderable	adj. 可渲染的
renderer	n. 渲染器
rendering	n. 渲染
replicate	v. 复制
replication	n. 复制
repository	n. 代码仓库
runtime	n. 运行时
schema	n. 模式
serialized	adj. 已序列化
serializing	v. 序列化
thread	n. 线程
threads	n. 线程
token	n. 词元
tokens	n. 词元
tokenization	n. 词元化
transformer	n. Transformer 模型
transformers	n. Transformer 模型
websocket	n. WebSocket 协议
LINNET_GLOSSES

# Product names stay untranslated in both exact-case forms. WebSocket is a
# protocol and is intentionally covered by the translated glossary above.
while IFS= read -r product; do
  rg -Fq -- $'m/skip/'"${product}"$'\t1\t1' \
    "${cache}/linnet.smart-index.tsv" || {
    echo "verify_english_data_projection: product-name skip changed for ${product}" >&2
    exit 1
  }
done <<'LINNET_PRODUCTS'
Elasticsearch
Kubernetes
MongoDB
Nginx
PostgreSQL
Redis
elasticsearch
kubernetes
mongodb
nginx
postgresql
redis
LINNET_PRODUCTS

rg -Fq 'tools/LinnetEnglishDataSources.swift' action-install.sh
rg -Fq 'tools/LinnetEnglishDataGenerator.swift' action-install.sh
test "$(rg -F -c 'build/linnet-english-data-generator \' action-install.sh)" -eq 1
rg -Fq 'URLQueryItem(name: "immutable", value: "1")' \
  tools/LinnetEnglishDataSources.swift
rg -Fq 'SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI' \
  tools/LinnetEnglishDataSources.swift
! rg -Fq 'sqlite3_open_v2(url.path' tools/LinnetEnglishDataSources.swift
rg -Fq 'catch LinnetEnglishDataError.invalid(let detail)' \
  tools/LinnetEnglishDataGenerator.swift
if rg -n 'python|\.py([[:space:]"'"'"']|$)' \
    tools/LinnetEnglishDataSources.swift tools/LinnetEnglishDataGenerator.swift \
    action-install.sh; then
  echo "verify_english_data_projection: Python returned to the English owner" >&2
  exit 1
fi
