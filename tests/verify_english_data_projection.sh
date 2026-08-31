#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

ruby tests/verify_pinyin_english_quality.rb

generator=build/linnet-english-data-generator
cache=build/linnet-english-cache
installer=action-install.sh
[[ -x "${generator}" && "$(lipo -archs "${generator}")" == arm64 ]] || {
  echo "verify_english_data_projection: native generator is missing" >&2
  exit 1
}

ruby -e '
  source = File.binread(ARGV.fetch(0))
  compile = %q{"${linnet_make}" english-data-generator}
  miss = %q{else
    rm -rf -- "${english_cache}"}
  execute = %q{build/linnet-english-data-generator \\}
  abort "English generator compile owner is not exact" unless
    source.scan(compile).length == 1 && source.scan(execute).length == 1
  abort "English generator is compiled on a warm cache hit" unless
    source.index(miss) < source.index(compile) &&
      source.index(compile) < source.index(execute)
' "${installer}"
expected=$'linnet.english-data-manifest.json\nlinnet.smart-index.tsv\nlinnet.smart.db\nlinnet_en.dict.yaml\nlinnet_english_entities.dict.yaml'
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
    manifest.fetch("format") == 5 &&
      manifest.fetch("generator") == {"name" => "LinnetEnglishDataGenerator", "version" => 2}
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
  expected_outputs = %w[
    linnet.smart-index.tsv linnet.smart.db linnet_en.dict.yaml
    linnet_english_entities.dict.yaml
  ]
  abort "projection output set changed" unless outputs.keys.sort == expected_outputs.sort
  outputs.each do |name, contract|
    path = File.join(cache, name)
    abort "projection artifact is missing" unless File.file?(path) && !File.symlink?(path)
    abort "projection artifact byte count changed after generation" unless File.size(path) == contract.fetch("bytes")
    abort "projection artifact digest changed after generation" unless
      Digest::SHA256.file(path).hexdigest == contract.fetch("sha256")
  end
  counts = manifest.fetch("projection_counts")
  abort "mixed entity count changed" unless counts.fetch("mixed_entities") == 429
  namespaces = counts.fetch("namespace_rows")
  abort "smart namespace set changed" unless namespaces.keys.sort == %w[f m/ipa m/skip m/zh n p].sort
  abort "smart row total is inconsistent" unless namespaces.values.sum == counts.fetch("smart_index_rows")
  abort "English projection lost its production vocabulary" unless
    counts.fetch("dictionary_entries") >= 140_000 &&
      counts.fetch("smart_index_rows") >= 4_000_000 &&
      counts.fetch("pinyin_edges") == namespaces.fetch("p")

  entity_path = File.join(cache, "linnet_english_entities.dict.yaml")
  lines = File.readlines(entity_path, chomp: true)
  marker = lines.index("...")
  abort "entity dictionary body marker is missing" unless marker
  entities = lines.drop(marker + 1).reject { |line| line.empty? || line.start_with?("#") }.map do |line|
    fields = line.split("\t", -1)
    abort "invalid entity dictionary row: #{line}" unless
      fields.length == 3 && fields[0] == fields[1] &&
        fields[0].match?(/\A[A-Z]{2,6}\z/) && fields[2] == "1"
    fields[0]
  end
  abort "entity dictionary count changed" unless entities.length == 429
  abort "entity dictionary order or uniqueness changed" unless
    entities == entities.uniq.sort
  %w[AI CPU CS HTTPS].each do |entity|
    abort "representative mixed entity is missing: #{entity}" unless entities.include?(entity)
  end
  puts "English data projection: PASS (#{counts.fetch("dictionary_entries")} words, #{counts.fetch("smart_index_rows")} smart rows)"
' "${repo_root}" "${cache}"

ruby -e '
  stage = File.binread("scripts/stage-linnet-data")
  abort "English entity staging fingerprint owner changed" unless
    stage.scan("linnet-stage-fingerprint-v6-english-entities").length == 1 &&
      stage.include?(%q{"${english_root}/linnet_english_entities.dict.yaml"}) &&
      stage.include?(%q{-s data/plum/linnet_english_entities.dict.yaml})
  pack = File.binread("package/stage_language_pack_sources")
  abort "English entity pack owner changed" unless
    pack.include?("for name in linnet_en.dict.yaml linnet_english_entities.dict.yaml")
'

rg -Fq 'name: linnet_en' "${cache}/linnet_en.dict.yaml"
rg -Fq 'name: linnet_english_entities' \
  "${cache}/linnet_english_entities.dict.yaml"
rg -q $'^deserialization\tdeserialization\t45364$' \
  "${cache}/linnet_en.dict.yaml"
rg -q $'^m/zh/deserialization\tn. 反序列化\t45364$' \
  "${cache}/linnet.smart-index.tsv"
rg -q $'^f/D264235\tdeserialization\t45364$' \
  "${cache}/linnet.smart-index.tsv"

# Curated translations have one data owner. Keep representative modern
# programming, systems, data, and AI terms precise without dropping ordinary
# meanings. Use the same expectations for the ledger and its generated index.
ruby -e '
  expected = STDIN.each_line.to_h { |line| line.chomp.split("\t", 2) }
  ledger = File.readlines(ARGV.fetch(0), chomp: true).drop(1)
    .to_h { |line| line.split("\t", 2) }
  failures = expected.keys.select { |word| ledger[word] != expected.fetch(word) }
  abort "incomplete curated gloss: #{failures.join(", ")}" unless failures.empty?
  actual = {}
  File.foreach(ARGV.fetch(1)) do |line|
    next unless line.start_with?("m/zh/")
    key, gloss = line.chomp.split("\t", 3)
    word = key.delete_prefix("m/zh/")
    actual[word] = gloss if expected.key?(word)
  end
  failures = expected.keys.select { |word| actual[word] != expected.fetch(word) }
  abort "incorrect generated gloss: #{failures.join(", ")}" unless failures.empty?
  puts "English gloss contracts: PASS (#{expected.length} source/index cases)"
' data/linnet/linnet_en_zh_decisions_final.tsv "${cache}/linnet.smart-index.tsv" <<'LINNET_GLOSSES'
WebSocket	n. WebSocket 协议
adenomyosis	n. 子宫腺肌病
agent	n. 智能体；代理人；代理商；特工；药剂
agents	n. 智能体；代理人；代理商；特工；药剂
asynchronously	adv. 异步地
brightest	adj. 最明亮的；最聪明的；最阳光的；最生动的；前途最光明的（bright的最高级）
called	vt. 呼叫；打电话；把 ...称为；vi. 呼叫；(短暂的)拜访（call的过去式和过去分词）
carbs	n. 碳水化合物（carbohydrates的非正式简称）；汽化器（carburetor的非正式简称）
childproofing	n. 儿童安全防护；v. 使对儿童安全（childproof的现在分词）
client	n. 客户端；客户；委托人
clients	n. 客户端；客户；委托人
cluster	n. 集群；群；簇；丛；串；v. 聚集
coast	n. 海岸；海滨；v. 滑行；沿海航行
commit	v. 提交；犯（罪）；承诺；托付；致力于
commits	n. 提交记录；v. 提交；犯（罪）；承诺；托付；致力于
committing	v. 提交；犯（罪）；承诺；托付；致力于
compilation	n. 编译；汇编；编纂；选集
concurrency	n. 并发；同时发生；意见一致
coroutine	n. 协程
dataset	n. 数据集
dependencies	n. 依赖；从属物；附属地
dependency	n. 依赖；从属物；附属地
deserialized	adj. 已反序列化
deserializing	v. 反序列化
developers	n. 开发者；开发商（developer的复数）
did	v. 做；干（do的过去式）；aux. 用于过去时的疑问、否定或强调
embedding	n. 嵌入
faqs	n. 常见问题（FAQ的复数）
frogs	n. 青蛙；（铁路）辙叉（frog的复数）
hash	n. 哈希；#号；肉丁杂烩；v. 哈希计算；切碎
hashes	n. 哈希；#号；肉丁杂烩；v. 哈希计算；切碎
hashing	n. 哈希计算；v. 切碎
hosted	v. 主办；主持；做东（host的过去式和过去分词）
lifted	v. 举起；运送；偷窃；升高；还清；取消；提升（lift的过去式和过去分词）
logging	n. 日志记录；伐木
median	adj. 中间的；中央的；正中的；n. 中位数；中值；（三角形）中线；梯形中位线
migrate	v. 迁移；迁徙；移居
migration	n. 迁移；迁徙；移民
package	n. 软件包；包裹；一揽子方案；v. 打包；包装
packages	n. 软件包；包裹；一揽子方案；v. 打包；包装
parser	n. 解析器
pho	n. 越南河粉；abbr. 医师-医院组织；基层卫生组织
pipeline	n. 流水线；管道；管线；渠道；v. 用管道输送
piti	abbr. 本金、利息、税费和保险费
process	n. 进程；过程；工序；v. 处理；加工
processes	n. 进程；过程；工序；v. 处理；加工
proximally	adv. 向近端；在近端
queried	v. 查询；询问；质疑
queries	n. 查询；疑问；v. 查询；询问；质疑
query	n. 查询；疑问；v. 查询；询问；质疑
querying	v. 查询；询问；质疑
queue	n. 队列；长队；v. 入队；排队
queued	v. 入队；排队
queueing	n. 排队；入队操作
queues	n. 队列；长队；v. 入队；排队
queuing	n. 排队；入队操作
ranking	n. 排名；等级；adj. 高级的；v. 排列；列为；排名（rank的现在分词）
renderable	adj. 可渲染的
renderer	n. 渲染器
rendering	n. 渲染；演绎；译文；墙面抹灰
replicate	v. 复制
replication	n. 复制
repository	n. 代码仓库；仓库；贮藏处
runtime	n. 运行时；运行时间
schema	n. 模式；图解；计划；纲要
serialization	n. 序列化；连载；连播
serialize	v. 序列化；连载；连播
serialized	adj. 已序列化的；连载的；连播的
serializes	v. 序列化；连载；连播
serializing	v. 序列化；连载；连播
shanghaied	v. 诱拐；诱骗；强行使当水手（shanghai的过去式和过去分词）
smelted	v. 熔炼（smelt的过去式和过去分词）
sorbed	v. 吸收；吸附（sorb的过去式和过去分词）
soundest	adj. 最可靠的；最健全的；最合理的（sound的最高级）
statues	n. 雕像；塑像（statue的复数）
sulfamethoxazole	n. 磺胺甲噁唑；新诺明
sysadmin	n. 系统管理员（system administrator的缩写）
thread	n. 线程；线；线索；思路；螺纹；帖子；v. 穿线
threads	n. 线程；线；线索；思路；螺纹；帖子；v. 穿线
token	n. 词元；令牌；代币；象征；标志；代金券；adj. 象征性的
tokens	n. 词元；令牌；代币；象征；标志；代金券
tokenization	n. 词元化；令牌化
transformer	n. Transformer 模型；变压器
transformers	n. Transformer 模型；变压器
watched	v. 注视；看守；观看（watch的过去式和过去分词）
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
