#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
baseline="${repo_root}/tests/fixtures/data-release-baseline/metadata-sequence-3.json"
current="${repo_root}/config/linnet-data-releases.json"
metadata_owner="${repo_root}/package/data_release_metadata"
[[ -f "${baseline}" && ! -L "${baseline}" ]] || {
  echo "Tracked data-release baseline is missing or unsafe." >&2
  exit 1
}

"${metadata_owner}" validate "${baseline}" >/dev/null
"${metadata_owner}" validate "${current}" >/dev/null
"${metadata_owner}" check-baseline "${baseline}" "${current}" >/dev/null

fixture="$(mktemp -d "${TMPDIR:-/tmp}/linnet-data-transition.XXXXXX")"
cleanup() {
  [[ "${fixture}" == "${TMPDIR:-/tmp}/linnet-data-transition."* ]] &&
    find "${fixture}" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

ruby -rjson -ropen3 - "${metadata_owner}" "${current}" "${fixture}" <<'RUBY'
owner, source, root = ARGV
base = JSON.parse(File.binread(source))

write = lambda do |name, document|
  path = File.join(root, "#{name}.json")
  File.binwrite(path, JSON.pretty_generate(document) + "\n")
  path
end
check_documents = lambda do |name, expected, before_document, after_document|
  scenario_before = write.call("#{name}-before", before_document)
  after = write.call(name, after_document)
  _stdout, _stderr, status = Open3.capture3(
    owner, "check-monotonic", scenario_before, after)
  actual = status.success? ? :pass : :fail
  abort "#{name}: expected #{expected}, got #{actual}" unless actual == expected
end
check = lambda do |name, expected, &mutation|
  candidate = Marshal.load(Marshal.dump(base))
  mutation.call(candidate)
  check_documents.call(name, expected, base, candidate)
end

check.call("unchanged-core-only", :pass) { |_document| }
check.call("sequence-only", :fail) do |document|
  document.fetch("packs").fetch("chinese")["sequence"] += 1
end
check.call("catalog-sequence-only", :fail) do |document|
  document["catalog_sequence"] += 1
end
check.call("version-only", :fail) do |document|
  pack = document.fetch("packs").fetch("chinese")
  pack["version"] = "#{pack.fetch("version")}.metadata-only"
end
check.call("version-only-with-sequences", :fail) do |document|
  pack = document.fetch("packs").fetch("chinese")
  pack["version"] = "#{pack.fetch("version")}.metadata-only"
  pack["sequence"] += 1
  document["catalog_sequence"] += 1
end
check.call("content-with-skipped-pack-sequence", :fail) do |document|
  pack = document.fetch("packs").fetch("chinese")
  pack["content_sha256"] = "a" * 64
  pack["version"] = "#{pack.fetch("version")}.reviewed"
  pack["sequence"] += 2
  document["catalog_sequence"] += 1
end
check.call("content-with-skipped-catalog-sequence", :fail) do |document|
  pack = document.fetch("packs").fetch("chinese")
  pack["content_sha256"] = "a" * 64
  pack["version"] = "#{pack.fetch("version")}.reviewed"
  pack["sequence"] += 1
  document["catalog_sequence"] += 2
end
check.call("content-without-version-transition", :fail) do |document|
  pack = document.fetch("packs").fetch("chinese")
  pack["content_sha256"] = "a" * 64
  pack["sequence"] += 1
  document["catalog_sequence"] += 1
end
abi_before = Marshal.load(Marshal.dump(base))
abi_before.fetch("packs").fetch("english")["data_abi"] = 2
abi_after = Marshal.load(Marshal.dump(abi_before))
abi_after.fetch("packs").fetch("english")["data_abi"] = 1
abi_after.fetch("packs").fetch("english")["version"] += ".abi-regression"
abi_after.fetch("packs").fetch("english")["sequence"] += 1
abi_after["catalog_sequence"] += 1
check_documents.call("abi-regression", :fail, abi_before, abi_after)
check.call("min-core-regression", :fail) do |document|
  pack = document.fetch("packs").fetch("chinese")
  pack["min_core"] = "0.1.0"
  pack["version"] = "#{pack.fetch("version")}.min-core-regression"
  pack["sequence"] += 1
  document["catalog_sequence"] += 1
end
check.call("content-identity-transition", :pass) do |document|
  pack = document.fetch("packs").fetch("chinese")
  pack["content_sha256"] = "a" * 64
  pack["version"] = "#{pack.fetch("version")}.reviewed"
  pack["sequence"] += 1
  document["catalog_sequence"] += 1
end
check.call("min-core-identity-transition", :pass) do |document|
  pack = document.fetch("packs").fetch("english")
  pack["min_core"] = "0.1.2"
  pack["version"] = "#{pack.fetch("version")}.min-core-0.1.2"
  pack["sequence"] += 1
  document["catalog_sequence"] += 1
end
check.call("abi-identity-transition", :pass) do |document|
  pack = document.fetch("packs").fetch("english")
  pack["data_abi"] += 1
  pack["version"] = "#{pack.fetch("version")}.abi-#{pack.fetch("data_abi")}"
  pack["sequence"] += 1
  document["catalog_sequence"] += 1
end
check.call("two-pack-identity-transition", :pass) do |document|
  %w[chinese english].each_with_index do |kind, index|
    pack = document.fetch("packs").fetch(kind)
    pack["content_sha256"] = (index + 1).to_s * 64
    pack["version"] = "#{pack.fetch("version")}.reviewed-#{kind}"
    pack["sequence"] += 1
  end
  document["catalog_sequence"] += 1
end
RUBY

echo "Linnet data-release identity transition: PASS"
