#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

# Behavioral coverage for the split GitHub release boundaries:
# - macOS Action stages exact draft assets;
# - the maintainer Mac can only verify them;
# - the publication Action changes release metadata and the tiny Catalog ref.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
stager="${repo_root}/package/stage_github_release"
publisher="${repo_root}/package/publish_github_release"
manifest="${repo_root}/package/release_asset_manifest"
identity_owner="${repo_root}/package/release_candidate_identity"

fail() {
  echo "verify_action_publication: $*" >&2
  exit 1
}

for owner in "${stager}" "${publisher}" "${manifest}" "${identity_owner}"; do
  [[ -f "${owner}" && ! -L "${owner}" && -x "${owner}" ]] ||
    fail "publication owner is missing: ${owner##*/}"
  bash -n "${owner}"
done

for required in \
    'candidate draft mutation is owned by GitHub Actions' \
    'release create "${tag}"' \
    'release delete "${tag}"' \
    'release upload "${tag}"' \
    'contains foreign asset bytes' \
    'older Draft is not exact Linnet-owned state' \
    'Immutable pack' \
    'earlier revision'; do
  rg -Fq -- "${required}" "${stager}" ||
    fail "draft stager contract is incomplete: ${required}"
done
for required in \
    'public release mutation is owned by GitHub Actions' \
    'publication authorization differs from candidate bytes' \
    'data-seed authorization differs from candidate identity' \
    'Catalog not promoted' \
    'staged candidate inventory differs from the canonical asset set' \
    'publish_channel core' \
    'publish_channel data' \
    'promote_catalog' \
    'publish_channel public' \
    '-F force=false'; do
  rg -Fq -- "${required}" "${publisher}" ||
    fail "Action publisher contract is incomplete: ${required}"
done
if rg -n 'release (create|upload|delete)|--clobber|force=true' "${publisher}"; then
  fail "publisher regained authority to replace candidate bytes"
fi

fixture="$(mktemp -d "${TMPDIR:-/tmp}/linnet-action-publication.XXXXXX")"
cleanup() {
  [[ "${fixture}" == "${TMPDIR:-/tmp}/linnet-action-publication."* ]] &&
    find "${fixture}" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

fixture_repo="${fixture}/repo"
fixture_assets="${fixture}/assets"
fake_bin="${fixture}/bin"
publisher_state="${fixture}/publisher-state"
stager_state="${fixture}/stager-state"
mkdir -p "${fixture_repo}/package" "${fixture_repo}/config" "${fixture_assets}" "${fake_bin}" \
  "${publisher_state}/releases" "${publisher_state}/tags" \
  "${stager_state}/releases" "${stager_state}/tags"
cp "${stager}" "${fixture_repo}/package/stage_github_release"
cp "${publisher}" "${fixture_repo}/package/publish_github_release"
cp "${manifest}" "${fixture_repo}/package/release_asset_manifest"
cp "${identity_owner}" "${fixture_repo}/package/release_candidate_identity"
cp "${repo_root}/config/linnet-data-releases.json" "${fixture_repo}/config/"
cp "${repo_root}/config/linnet-update-baselines.json" "${fixture_repo}/config/"
cp "${repo_root}/CHANGELOG.md" "${fixture_repo}/CHANGELOG.md"
chmod 755 "${fixture_repo}/package/"*

version="$(sed -n 's/^MARKETING_VERSION = \([^[:space:]]*\)$/\1/p' \
  "${repo_root}/config/LinnetProduct.xcconfig")"
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "fixture product version is invalid"
catalog_sequence=73
candidate_revision=0123456789abcdef0123456789abcdef01234567
core_name="Linnet-${version}-arm64-Core-community-beta.pkg"
printf 'complete installer\n' >"${fixture_assets}/Linnet.pkg"
printf 'core installer\n' >"${fixture_assets}/${core_name}"
printf '#!/bin/sh\nexit 0\n' \
  >"${fixture_assets}/Linnet-${version}-Uninstall.command"
for kind in Chinese English Extended LTS; do
  printf 'pack:%s\n' "${kind}" >"${fixture_assets}/Linnet-${kind}.linnetpack"
done

ruby -rjson -rdigest - "${fixture_assets}" "${version}" \
    "${catalog_sequence}" "${candidate_revision}" "${fixture_repo}/config" <<'RUBY'
root, version, sequence, revision, config = ARGV
sequence = Integer(sequence, 10)
baselines = JSON.parse(File.binread(File.join(config, "linnet-update-baselines.json"))).fetch("pack_baselines")
releases = JSON.parse(File.binread(File.join(config, "linnet-data-releases.json"))).fetch("packs")
asset = lambda do |name|
  path = File.join(root, name)
  {
    "bytes" => File.size(path),
    "container_sha256" => Digest::SHA256.file(path).hexdigest,
  }
end
core_name = "Linnet-#{version}-arm64-Core-community-beta.pkg"
core = asset.call(core_name)
packs = {
  "chinese" => "Linnet-Chinese.linnetpack",
  "english" => "Linnet-English.linnetpack",
  "extended" => "Linnet-Extended.linnetpack",
  "lts" => "Linnet-LTS.linnetpack",
}
pack = lambda do |kind|
  name = packs.fetch(kind)
  identity = asset.call(name)
  entry = {
    "kind" => kind,
    "bytes" => identity.fetch("bytes"),
    "container_sha256" => identity.fetch("container_sha256"),
    "content_sha256" => releases.fetch(kind).fetch("content_sha256"),
    "url" => "https://github.com/Ares-X/Linnet/releases/download/data-#{sequence}/#{name}",
  }
  base = baselines.fetch(kind).fetch("content_sha256")
  unless base == entry.fetch("content_sha256")
    delta_name = name.sub(/\.linnetpack\z/, "-from-#{base}.linnetdelta")
    File.binwrite(File.join(root, delta_name), "delta:#{kind}:#{base}\n")
    delta = asset.call(delta_name)
    entry["deltas"] = [{
      "base_content_sha256" => base,
      "bytes" => delta.fetch("bytes"),
      "sha256" => delta.fetch("container_sha256"),
      "url" => "https://github.com/Ares-X/Linnet/releases/download/data-#{sequence}/#{delta_name}",
    }]
  end
  entry
end
catalog = {
  "format" => 1,
  "sequence" => sequence,
  "core" => {
    "version" => version,
    "revision" => revision,
    "bytes" => core.fetch("bytes"),
    "sha256" => core.fetch("container_sha256"),
    "release_url" => "https://github.com/Ares-X/Linnet/releases/tag/core-v#{version}",
    "package_url" => "https://github.com/Ares-X/Linnet/releases/download/core-v#{version}/#{core_name}",
  },
  "activation_sets" => [
    {"edition" => "standard", "packs" => [pack.call("chinese"), pack.call("english")]},
    {"edition" => "full", "packs" => [pack.call("extended"), pack.call("lts")]},
  ],
}
File.binwrite(
  File.join(root, "Linnet-Data-Channel.json"),
  JSON.generate(catalog) + "\n")
RUBY

candidate_identity="$("${fixture_repo}/package/release_candidate_identity" \
  "${fixture_assets}" "${version}" "${catalog_sequence}")"
[[ "${candidate_identity}" =~ ^sha256:([0-9a-f]{64})$ ]] ||
  fail "fixture candidate identity is invalid"
candidate_digest="${BASH_REMATCH[1]}"
authorization_tag="linnet-publication/v${version}-${candidate_revision}-h${candidate_digest}"

cat >"${fake_bin}/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -C ]] && shift 2
[[ "${1:-} ${2:-}" == "rev-parse --verify" ]]
printf '%s\n' "${FAKE_CANDIDATE_REVISION:?}"
FAKE_GIT

cat >"${fake_bin}/gh" <<'FAKE_GH'
#!/usr/bin/env ruby

require "base64"
require "digest"
require "fileutils"
require "json"

state = ENV.fetch("FAKE_GH_STATE")
assets_root = ENV.fetch("FAKE_RELEASE_ASSETS")
revision = ENV.fetch("FAKE_CANDIDATE_REVISION")
FileUtils.mkdir_p(File.join(state, "releases"))
FileUtils.mkdir_p(File.join(state, "tags"))

def fail_fake(message, status = 90)
  warn(message)
  exit(status)
end

def append_line(path, line)
  File.open(path, "ab") { |file| file.puts(line) }
end

def release_path(state, tag)
  File.join(state, "releases", "#{tag}.json")
end

def tag_path(state, tag)
  File.join(state, "tags", tag)
end

def read_release(state, tag)
  path = release_path(state, tag)
  fail_fake("release not found", 1) unless File.file?(path)
  JSON.parse(File.binread(path))
end

def write_release(state, tag, document)
  path = release_path(state, tag)
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path, JSON.generate(document) + "\n")
end

def write_tag(state, tag, revision)
  path = tag_path(state, tag)
  FileUtils.mkdir_p(File.dirname(path))
  File.binwrite(path, "#{revision}\n")
end

mutations = File.join(state, "mutations.log")
command = ARGV.shift

if command == "release"
  action = ARGV.shift
  tag = ARGV.shift
  case action
  when "view"
    puts JSON.generate(read_release(state, tag))
  when "create"
    if ENV["FAKE_FAIL_CREATE_ONCE"] == "true"
      marker = File.join(state, "fail-create-once-#{tag}")
      unless File.exist?(marker)
        FileUtils.touch(marker)
        fail_fake("injected release create interruption", 1)
      end
    end
    target_index = ARGV.index("--target")
    target = target_index ? ARGV.fetch(target_index + 1) : revision
    title_index = ARGV.index("--title")
    document = {
      "databaseId" => 1,
      "isDraft" => true,
      "isPrerelease" => ARGV.include?("--prerelease"),
      "tagName" => tag,
      "name" => title_index ? ARGV.fetch(title_index + 1) : "",
      "targetCommitish" => target,
      "assets" => [],
    }
    write_release(state, tag, document)
    append_line(mutations, "release-create #{tag}")
  when "upload"
    path = ARGV.shift
    document = read_release(state, tag)
    name = File.basename(path)
    fail_fake("duplicate upload") if document.fetch("assets").any? { |item| item.fetch("name") == name }
    document.fetch("assets") << {
      "name" => name,
      "digest" => "sha256:#{Digest::SHA256.file(path).hexdigest}",
      "size" => File.size(path),
    }
    write_release(state, tag, document)
    append_line(mutations, "release-upload #{tag} #{name}")
  when "delete"
    document = read_release(state, tag)
    fail_fake("published release deletion") unless document.fetch("isDraft")
    fail_fake("unconfirmed release deletion") unless ARGV.include?("--yes")
    FileUtils.rm_f(release_path(state, tag))
    append_line(mutations, "release-delete #{tag}")
  when "edit"
    document = read_release(state, tag)
    if ARGV.include?("--draft=false")
      document["isDraft"] = false
      write_release(state, tag, document)
      write_tag(state, tag, revision)
      append_line(mutations, "release-publish #{tag}")
    elsif ARGV.include?("--latest")
      append_line(mutations, "release-latest #{tag}")
    else
      fail_fake("unsupported release edit")
    end
  when "download"
    pattern_index = ARGV.index("--pattern")
    dir_index = ARGV.index("--dir")
    fail_fake("missing bounded download") unless pattern_index && dir_index
    pattern = ARGV.fetch(pattern_index + 1)
    destination = ARGV.fetch(dir_index + 1)
    document = read_release(state, tag)
    fail_fake("asset not staged") unless
      document.fetch("assets").any? { |item| item.fetch("name") == pattern }
    FileUtils.cp(File.join(assets_root, pattern), File.join(destination, pattern))
  else
    fail_fake("unsupported release command")
  end
  exit 0
end

fail_fake("unsupported gh command") unless command == "api"
method = "GET"
endpoint = nil
input = nil
jq = nil
fields = {}
until ARGV.empty?
  token = ARGV.shift
  case token
  when "--method"
    method = ARGV.shift
  when "--input"
    input = ARGV.shift
  when "--jq"
    jq = ARGV.shift
  when "-f", "-F"
    key, value = ARGV.shift.split("=", 2)
    fields[key] = value
  else
    endpoint ||= token
  end
end
fail_fake("missing API endpoint") unless endpoint

case "#{method}:#{endpoint}"
when %r{\AGET:repos/Ares-X/Linnet/git/ref/tags/(.+)\z}
  tag = Regexp.last_match(1)
  path = tag_path(state, tag)
  fail_fake("tag not found", 1) unless File.file?(path)
  sha = File.read(path).strip
  if jq&.include?("object.type")
    puts "commit\t#{sha}"
  else
    puts sha
  end
when "GET:repos/Ares-X/Linnet/git/ref/heads/data-channel"
  path = File.join(state, "data-channel", "ref")
  fail_fake("HTTP 404 Not Found", 1) unless File.file?(path)
  puts File.read(path).strip
when %r{\AGET:repos/Ares-X/Linnet/git/commits/(.+)\z}
  commit = Regexp.last_match(1)
  path = File.join(state, "data-channel", "commits", commit)
  fail_fake("commit not found", 1) unless File.file?(path)
  puts File.readlines(path, chomp: true).fetch(0)
when %r{\AGET:repos/Ares-X/Linnet/git/trees/(.+)\z}
  path = File.join(state, "data-channel", "blob")
  fail_fake("tree not found", 1) unless File.file?(path)
  puts File.read(path).strip
when %r{\AGET:repos/Ares-X/Linnet/git/blobs/(.+)\z}
  path = File.join(state, "data-channel", "catalog")
  fail_fake("blob not found", 1) unless File.file?(path)
  puts Base64.strict_encode64(File.binread(path))
when "POST:repos/Ares-X/Linnet/git/blobs"
  document = JSON.parse(File.binread(input))
  bytes = Base64.strict_decode64(document.fetch("content"))
  root = File.join(state, "data-channel")
  FileUtils.mkdir_p(root)
  File.binwrite(File.join(root, "pending-catalog"), bytes)
  blob = "b" * 40
  File.binwrite(File.join(root, "pending-blob"), "#{blob}\n")
  puts blob
when "POST:repos/Ares-X/Linnet/git/trees"
  root = File.join(state, "data-channel")
  tree = "a" * 40
  File.binwrite(File.join(root, "pending-tree"), "#{tree}\n")
  puts tree
when "POST:repos/Ares-X/Linnet/git/commits"
  document = JSON.parse(File.binread(input))
  root = File.join(state, "data-channel")
  ref_path = File.join(root, "ref")
  parent = document.fetch("parents", []).first
  if parent
    fail_fake("parent moved", 1) unless File.file?(ref_path) && File.read(ref_path).strip == parent
  else
    fail_fake("unexpected root commit", 1) if File.file?(ref_path)
  end
  count_path = File.join(root, "commit-count")
  count = File.file?(count_path) ? Integer(File.read(count_path), 10) + 1 : 1
  File.binwrite(count_path, "#{count}\n")
  commit = format("%040x", count + 4096)
  tree = document.fetch("tree")
  FileUtils.mkdir_p(File.join(root, "commits"))
  File.binwrite(File.join(root, "commits", commit), "#{tree}\n#{parent}\n")
  File.binwrite(File.join(root, "pending-commit"), "#{commit}\n")
  puts commit
when "POST:repos/Ares-X/Linnet/git/refs"
  fail_fake("wrong ref create") unless fields.fetch("ref") == "refs/heads/data-channel"
  root = File.join(state, "data-channel")
  fail_fake("ref already exists", 1) if File.file?(File.join(root, "ref"))
  commit = fields.fetch("sha")
  fail_fake("wrong commit") unless
    File.read(File.join(root, "pending-commit")).strip == commit
  FileUtils.cp(File.join(root, "pending-catalog"), File.join(root, "catalog"))
  FileUtils.cp(File.join(root, "pending-tree"), File.join(root, "tree"))
  FileUtils.cp(File.join(root, "pending-blob"), File.join(root, "blob"))
  File.binwrite(File.join(root, "ref"), "#{commit}\n")
  append_line(mutations, "catalog-create")
when "PATCH:repos/Ares-X/Linnet/git/refs/heads/data-channel"
  fail_fake("forced update") unless fields.fetch("force") == "false"
  root = File.join(state, "data-channel")
  if File.file?(File.join(root, "inject-race"))
    race = "e" * 40
    File.binwrite(File.join(root, "ref"), "#{race}\n")
    append_line(mutations, "catalog-race")
    exit 1
  end
  commit = fields.fetch("sha")
  parent = File.readlines(File.join(root, "commits", commit), chomp: true).fetch(1)
  fail_fake("non-fast-forward", 1) unless File.read(File.join(root, "ref")).strip == parent
  FileUtils.cp(File.join(root, "pending-catalog"), File.join(root, "catalog"))
  FileUtils.cp(File.join(root, "pending-tree"), File.join(root, "tree"))
  FileUtils.cp(File.join(root, "pending-blob"), File.join(root, "blob"))
  File.binwrite(File.join(root, "ref"), "#{commit}\n")
  append_line(mutations, "catalog-update")
else
  fail_fake("unsupported API call: #{method} #{endpoint}")
end
FAKE_GH
chmod 755 "${fake_bin}/git" "${fake_bin}/gh"

# The real GitHub runner exports this globally. Fixture calls without an
# explicit override model a local maintainer process and must not inherit it.
unset GITHUB_ACTIONS

write_release() {
  local state="$1" channel="$2" tag="$3" prerelease="$4" draft="$5"
  local release_revision="${6:-${candidate_revision}}"
  local bytes_revision="${7:-current}"
  local release_title
  case "${channel}" in
    core) release_title="Linnet Core update ${version}" ;;
    data) release_title="Linnet automatic data channel ${catalog_sequence}" ;;
    public) release_title="Linnet ${version}" ;;
  esac
  ruby -rjson -rdigest - "${state}" "${fixture_assets}" \
      "${fixture_repo}/package/release_asset_manifest" "${channel}" \
      "${tag}" "${prerelease}" "${draft}" "${version}" \
      "${catalog_sequence}" "${release_revision}" "${release_title}" "${bytes_revision}" <<'RUBY'
state, root, manifest, channel, tag, prerelease, draft, version, sequence, revision, title, bytes_revision = ARGV
names = IO.popen([manifest, channel, version, sequence], &:read).lines(chomp: true)
assets = names.map do |name|
  path = File.join(root, name)
  bytes = File.binread(path)
  bytes = "previous candidate\n#{bytes}" if bytes_revision == "previous"
  {
    "name" => name,
    "digest" => "sha256:#{Digest::SHA256.hexdigest(bytes)}",
    "size" => bytes.bytesize,
  }
end
document = {
  "databaseId" => 1,
  "isDraft" => draft == "true",
  "isPrerelease" => prerelease == "true",
  "tagName" => tag,
  "name" => title,
  "targetCommitish" => revision,
  "assets" => assets,
}
File.binwrite(File.join(state, "releases", "#{tag}.json"), JSON.generate(document) + "\n")
RUBY
}

run_stager() {
  local state="$1" mode="$2" channel="$3"
  GITHUB_REPOSITORY=Ares-X/Linnet GH_TOKEN=fixture \
    FAKE_GH_STATE="${state}" FAKE_RELEASE_ASSETS="${fixture_assets}" \
    FAKE_CANDIDATE_REVISION="${candidate_revision}" \
    PATH="${fake_bin}:${PATH}" \
    "${fixture_repo}/package/stage_github_release" "${mode}" "${channel}" \
      "${fixture_assets}" "${version}" "${catalog_sequence}" \
      "${candidate_revision}"
}

: >"${stager_state}/mutations.log"
if run_stager "${stager_state}" stage core >/dev/null 2>&1; then
  fail "local process was allowed to stage candidate bytes"
fi
[[ ! -s "${stager_state}/mutations.log" ]] ||
  fail "rejected local staging mutated GitHub state"

GITHUB_ACTIONS=true run_stager "${stager_state}" stage core >/dev/null ||
  fail "Action stager rejected an exact Core draft"
expected_stage_mutations="$(
  {
    echo "release-create core-v${version}"
    while IFS= read -r name; do
      echo "release-upload core-v${version} ${name}"
    done < <("${manifest}" core "${version}" "${catalog_sequence}")
  }
)"
[[ "$(cat "${stager_state}/mutations.log")" == "${expected_stage_mutations}" ]] ||
  fail "Core stager did not create and fill one exact draft"
: >"${stager_state}/mutations.log"
run_stager "${stager_state}" verify core >/dev/null ||
  fail "local UAT verifier rejected the exact Action draft"
GITHUB_ACTIONS=true run_stager "${stager_state}" stage core >/dev/null ||
  fail "exact draft retry was not idempotent"
[[ ! -s "${stager_state}/mutations.log" ]] ||
  fail "exact draft retry uploaded or recreated bytes"

core_release="${stager_state}/releases/core-v${version}.json"
cp "${core_release}" "${fixture}/exact-core-release.json"
old_candidate_revision=89abcdef0123456789abcdef0123456789abcdef
write_release "${stager_state}" core "core-v${version}" true true \
  "${old_candidate_revision}" previous
: >"${stager_state}/mutations.log"
GITHUB_ACTIONS=true run_stager "${stager_state}" stage core >/dev/null ||
  fail "same-version Core Draft from an older revision was not retired"
[[ "$(sed -n '1p' "${stager_state}/mutations.log")" == \
    "release-delete core-v${version}" ]] ||
  fail "older Core Draft was not retired before replacement"
ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  abort unless document.fetch("isDraft") &&
    document.fetch("targetCommitish") == ARGV.fetch(1)
' "${core_release}" "${candidate_revision}" ||
  fail "replacement Core Draft does not own the current candidate"

write_release "${stager_state}" public "v${version}" false true \
  "${old_candidate_revision}" previous
: >"${stager_state}/mutations.log"
GITHUB_ACTIONS=true run_stager "${stager_state}" stage public >/dev/null ||
  fail "same-version public Draft from an older revision was not retired"
[[ "$(sed -n '1p' "${stager_state}/mutations.log")" == \
    "release-delete v${version}" ]] ||
  fail "older public Draft was not retired before replacement"

write_release "${stager_state}" data "data-${catalog_sequence}" true true \
  "${old_candidate_revision}"
: >"${stager_state}/mutations.log"
GITHUB_ACTIONS=true run_stager "${stager_state}" stage data >/dev/null ||
  fail "byte-identical data Draft from an earlier direct commit was not reusable"
[[ ! -s "${stager_state}/mutations.log" ]] ||
  fail "byte-identical earlier-revision data Draft was mutated"
run_stager "${stager_state}" verify data >/dev/null ||
  fail "local verifier rejected a byte-identical earlier-revision data Draft"
data_release="${stager_state}/releases/data-${catalog_sequence}.json"
cp "${data_release}" "${fixture}/exact-data-release.json"

ruby -rjson -e '
  path = ARGV.fetch(0)
  document = JSON.parse(File.binread(path))
  document["name"] = "foreign data title"
  File.binwrite(path, JSON.generate(document) + "\n")
' "${data_release}"
: >"${stager_state}/mutations.log"
if GITHUB_ACTIONS=true run_stager "${stager_state}" stage data >/dev/null 2>&1; then
  fail "earlier-revision data Draft with a foreign title was accepted"
fi
[[ ! -s "${stager_state}/mutations.log" ]] ||
  fail "foreign-title data Draft rejection mutated release state"

cp "${fixture}/exact-data-release.json" "${data_release}"
ruby -rjson -e '
  path = ARGV.fetch(0)
  document = JSON.parse(File.binread(path))
  document["targetCommitish"] = "0" * 40
  File.binwrite(path, JSON.generate(document) + "\n")
' "${data_release}"
if GITHUB_ACTIONS=true run_stager "${stager_state}" stage data >/dev/null 2>&1; then
  fail "data Draft without a valid direct commit identity was accepted"
fi
[[ ! -s "${stager_state}/mutations.log" ]] ||
  fail "invalid-target data Draft rejection mutated release state"

cp "${fixture}/exact-data-release.json" "${data_release}"
ruby -rjson -e '
  path = ARGV.fetch(0)
  document = JSON.parse(File.binread(path))
  document.fetch("assets").fetch(0)["digest"] = "sha256:#{"0" * 64}"
  File.binwrite(path, JSON.generate(document) + "\n")
' "${data_release}"
if GITHUB_ACTIONS=true run_stager "${stager_state}" stage data >/dev/null 2>&1; then
  fail "earlier-revision data Draft with foreign bytes was accepted"
fi
[[ ! -s "${stager_state}/mutations.log" ]] ||
  fail "foreign-byte data Draft rejection mutated release state"
cp "${fixture}/exact-data-release.json" "${data_release}"

write_release "${stager_state}" core "core-v${version}" true true \
  "${old_candidate_revision}"
: >"${stager_state}/mutations.log"
if FAKE_FAIL_CREATE_ONCE=true GITHUB_ACTIONS=true \
    run_stager "${stager_state}" stage core >/dev/null 2>&1; then
  fail "injected Draft replacement interruption unexpectedly succeeded"
fi
[[ "$(cat "${stager_state}/mutations.log")" == \
    "release-delete core-v${version}" ]] ||
  fail "interrupted replacement mutated more than the retired old Draft"
[[ ! -e "${core_release}" ]] ||
  fail "interrupted replacement left the old-revision Core Draft active"
: >"${stager_state}/mutations.log"
GITHUB_ACTIONS=true run_stager "${stager_state}" stage core >/dev/null ||
  fail "Draft replacement was not retryable after interruption"
run_stager "${stager_state}" verify core >/dev/null ||
  fail "retried Draft replacement did not produce exact candidate bytes"

write_release "${stager_state}" core "core-v${version}" true true \
  "${old_candidate_revision}"
ruby -rjson -e '
  path = ARGV.fetch(0)
  document = JSON.parse(File.binread(path))
  document.fetch("assets") << {
    "name" => "foreign.pkg", "digest" => "sha256:#{"0" * 64}", "size" => 1,
  }
  File.binwrite(path, JSON.generate(document) + "\n")
' "${core_release}"
: >"${stager_state}/mutations.log"
if GITHUB_ACTIONS=true run_stager "${stager_state}" stage core >/dev/null 2>&1; then
  fail "foreign draft asset was accepted"
fi
[[ ! -s "${stager_state}/mutations.log" ]] ||
  fail "foreign old-revision Draft was silently replaced"
cp "${fixture}/exact-core-release.json" "${core_release}"
ruby -rjson -e '
  path = ARGV.fetch(0)
  document = JSON.parse(File.binread(path))
  document["isDraft"] = false
  File.binwrite(path, JSON.generate(document) + "\n")
' "${core_release}"
mkdir -p "${stager_state}/tags"
printf '%s\n' "${old_candidate_revision}" >"${stager_state}/tags/core-v${version}"
: >"${stager_state}/mutations.log"
if GITHUB_ACTIONS=true run_stager "${stager_state}" stage core \
    >/dev/null 2>&1; then
  fail "published Core channel was accepted as a data seed"
fi
[[ ! -s "${stager_state}/mutations.log" ]] ||
  fail "published Core rejection mutated release state"
if run_stager "${stager_state}" verify core >/dev/null 2>&1; then
  fail "published Core tag owned by another revision was accepted"
fi

write_release "${stager_state}" data "data-${catalog_sequence}" true false
data_seed_revision=89abcdef0123456789abcdef0123456789abcdef
printf '%s\n' "${data_seed_revision}" \
  >"${stager_state}/tags/data-${catalog_sequence}"
: >"${stager_state}/mutations.log"
GITHUB_ACTIONS=true run_stager "${stager_state}" stage data >/dev/null ||
  fail "byte-identical published data assets from an earlier revision were not reusable"
[[ ! -s "${stager_state}/mutations.log" ]] ||
  fail "published byte-identical data seed was mutated"

write_release "${publisher_state}" core "core-v${version}" true true
write_release "${publisher_state}" data "data-${catalog_sequence}" true true
write_release "${publisher_state}" public "v${version}" false true
mkdir -p "$(dirname "${publisher_state}/tags/${authorization_tag}")"
printf '%s\n' "${candidate_revision}" \
  >"${publisher_state}/tags/${authorization_tag}"

run_publisher() {
  local mode="$1"
  local auth_tag="${2:-${authorization_tag}}"
  GITHUB_REPOSITORY=Ares-X/Linnet GH_TOKEN=fixture \
    FAKE_GH_STATE="${publisher_state}" \
    FAKE_RELEASE_ASSETS="${fixture_assets}" \
    FAKE_CANDIDATE_REVISION="${candidate_revision}" \
    RUNNER_TEMP="${fixture}" PATH="${fake_bin}:${PATH}" \
    "${fixture_repo}/package/publish_github_release" "${mode}" \
      "${version}" "${catalog_sequence}" "${candidate_revision}" "${auth_tag}"
}

seed_tag="linnet-data-seed/v${version}-${catalog_sequence}-${candidate_revision}"
mkdir -p "$(dirname "${publisher_state}/tags/${seed_tag}")"
printf '%s\n' "${candidate_revision}" >"${publisher_state}/tags/${seed_tag}"
: >"${publisher_state}/mutations.log"
if run_publisher data-seed "${seed_tag}" >/dev/null 2>&1; then
  fail "non-Action process was allowed to publish a data seed"
fi
[[ ! -s "${publisher_state}/mutations.log" ]] ||
  fail "rejected data seed changed GitHub state"
wrong_seed_tag="linnet-data-seed/v${version}-$((catalog_sequence + 1))-${candidate_revision}"
if GITHUB_ACTIONS=true run_publisher data-seed "${wrong_seed_tag}" \
    >/dev/null 2>&1; then
  fail "data seed for another Catalog sequence was accepted"
fi
GITHUB_ACTIONS=true run_publisher data-seed "${seed_tag}" >/dev/null ||
  fail "Action publisher rejected an exact data seed"
[[ "$(cat "${publisher_state}/mutations.log")" == \
    "release-publish data-${catalog_sequence}" ]] ||
  fail "data seed mutated more than its prerelease"
[[ ! -e "${publisher_state}/data-channel/ref" ]] ||
  fail "data seed exposed an unaccepted stable Catalog"

# Consume a Draft accepted by the real stager, including the earlier-revision
# immutable data owner. This must remain valid all the way through publication.
write_release "${publisher_state}" data "data-${catalog_sequence}" true true \
  "${old_candidate_revision}"
find "${publisher_state}/tags/data-${catalog_sequence}" -delete
: >"${publisher_state}/mutations.log"
run_stager "${publisher_state}" verify data >/dev/null ||
  fail "stager rejected the earlier-revision data Draft before publication"
run_publisher verify >/dev/null ||
  fail "publisher rejected the byte-identical earlier-revision data Draft accepted by staging"
[[ ! -s "${publisher_state}/mutations.log" ]] ||
  fail "read-only publication verification changed GitHub state"

wrong_authorization="linnet-publication/v${version}-${candidate_revision}-h$(printf '%064d' 0)"
if run_publisher verify "${wrong_authorization}" >/dev/null 2>&1; then
  fail "authorization for different candidate bytes was accepted"
fi
[[ ! -s "${publisher_state}/mutations.log" ]] ||
  fail "wrong byte authorization changed GitHub state"

core_release="${publisher_state}/releases/core-v${version}.json"
cp "${core_release}" "${fixture}/publisher-core-release.json"
ruby -rjson -e '
  path = ARGV.fetch(0)
  document = JSON.parse(File.binread(path))
  document.fetch("assets").fetch(0)["digest"] = "sha256:#{"0" * 64}"
  File.binwrite(path, JSON.generate(document) + "\n")
' "${core_release}"
if run_publisher verify >/dev/null 2>&1; then
  fail "wrong remote asset digest was accepted"
fi
cp "${fixture}/publisher-core-release.json" "${core_release}"
ruby -rjson -e '
  path = ARGV.fetch(0)
  document = JSON.parse(File.binread(path))
  document["targetCommitish"] = "0" * 40
  File.binwrite(path, JSON.generate(document) + "\n")
' "${core_release}"
if run_publisher verify >/dev/null 2>&1; then
  fail "draft targeting another revision was accepted"
fi
cp "${fixture}/publisher-core-release.json" "${core_release}"
printf '%040d\n' 0 >"${publisher_state}/tags/${authorization_tag}"
if run_publisher verify >/dev/null 2>&1; then
  fail "authorization tag owned by another revision was accepted"
fi
printf '%s\n' "${candidate_revision}" \
  >"${publisher_state}/tags/${authorization_tag}"

if run_publisher publish >/dev/null 2>&1; then
  fail "non-Action process was allowed to publish"
fi
[[ ! -s "${publisher_state}/mutations.log" ]] ||
  fail "rejected non-Action publisher changed GitHub state"

GITHUB_ACTIONS=true run_publisher publish >/dev/null ||
  fail "Action publisher rejected exact staged releases"
expected_publish_mutations="$(
  printf '%s\n' \
    "release-publish core-v${version}" \
    "release-publish data-${catalog_sequence}" \
    "catalog-create" \
    "release-publish v${version}"
)"
[[ "$(cat "${publisher_state}/mutations.log")" == \
    "${expected_publish_mutations}" ]] ||
  fail "publication order is not Core -> data -> Catalog -> public"
cmp -s "${fixture_assets}/Linnet-Data-Channel.json" \
  "${publisher_state}/data-channel/catalog" ||
  fail "stable data-channel did not receive the exact staged Catalog"

: >"${publisher_state}/mutations.log"
printf '%s\n' "${data_seed_revision}" \
  >"${publisher_state}/tags/data-${catalog_sequence}"
GITHUB_ACTIONS=true run_publisher publish >/dev/null ||
  fail "exact publication retry was not idempotent"
[[ "$(cat "${publisher_state}/mutations.log")" == \
    "release-latest v${version}" ]] ||
  fail "publication retry copied immutable data assets or recreated Catalog state"

seed_catalog() {
  local source="$1" ref="$2"
  local branch="${publisher_state}/data-channel"
  mkdir -p "${branch}/commits"
  cp "${source}" "${branch}/catalog"
  printf '%s\n' "${ref}" >"${branch}/ref"
  printf '%040d\n' 10 >"${branch}/tree"
  printf '%040d\n' 11 >"${branch}/blob"
  printf '%040d\n' 10 >"${branch}/commits/${ref}"
}

previous_core_catalog="${fixture}/previous-core-catalog.json"
ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  document.fetch("core")["version"] = "0.1.0"
  document.fetch("core")["revision"] = "f" * 40
  document.fetch("core")["release_url"] =
    "https://github.com/Ares-X/Linnet/releases/tag/core-v0.1.0"
  document.fetch("core")["package_url"] =
    "https://github.com/Ares-X/Linnet/releases/download/core-v0.1.0/Linnet-0.1.0-arm64-Core-community-beta.pkg"
  File.binwrite(ARGV.fetch(1), JSON.generate(document) + "\n")
' "${fixture_assets}/Linnet-Data-Channel.json" "${previous_core_catalog}"
seed_catalog "${previous_core_catalog}" "$(printf 'b%.0s' {1..40})"
: >"${publisher_state}/mutations.log"
GITHUB_ACTIONS=true run_publisher publish >/dev/null ||
  fail "same-sequence Catalog could not advance its Core snapshot"
[[ "$(cat "${publisher_state}/mutations.log")" == $'catalog-update\n'"release-latest v${version}" ]] ||
  fail "Core-only Catalog promotion mutated a pack Release"
cmp -s "${fixture_assets}/Linnet-Data-Channel.json" \
  "${publisher_state}/data-channel/catalog" ||
  fail "Core-only Catalog promotion did not retain the exact candidate snapshot"

changed_pack_catalog="${fixture}/changed-pack-catalog.json"
ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  document.fetch("activation_sets").fetch(0).fetch("packs").fetch(0)[
    "container_sha256"] = "0" * 64
  File.binwrite(ARGV.fetch(1), JSON.generate(document) + "\n")
' "${fixture_assets}/Linnet-Data-Channel.json" "${changed_pack_catalog}"
seed_catalog "${changed_pack_catalog}" "$(printf 'a%.0s' {1..40})"
: >"${publisher_state}/mutations.log"
if GITHUB_ACTIONS=true run_publisher publish >/dev/null 2>&1; then
  fail "same-sequence Catalog replaced a different immutable pack set"
fi
[[ ! -s "${publisher_state}/mutations.log" ]] ||
  fail "rejected same-sequence pack mutation changed publication state"

higher_catalog="${fixture}/higher-catalog.json"
ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  document["sequence"] += 1
  File.binwrite(ARGV.fetch(1), JSON.generate(document) + "\n")
' "${fixture_assets}/Linnet-Data-Channel.json" "${higher_catalog}"
seed_catalog "${higher_catalog}" "$(printf 'd%.0s' {1..40})"
: >"${publisher_state}/mutations.log"
if GITHUB_ACTIONS=true run_publisher publish >/dev/null 2>&1; then
  fail "older Catalog replaced a newer stable sequence"
fi
[[ ! -s "${publisher_state}/mutations.log" ]] ||
  fail "non-monotonic Catalog rejection mutated publication state"

lower_catalog="${fixture}/lower-catalog.json"
ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  document["sequence"] -= 1
  File.binwrite(ARGV.fetch(1), JSON.generate(document) + "\n")
' "${fixture_assets}/Linnet-Data-Channel.json" "${lower_catalog}"
seed_catalog "${lower_catalog}" "$(printf 'c%.0s' {1..40})"
: >"${publisher_state}/data-channel/inject-race"
: >"${publisher_state}/mutations.log"
if GITHUB_ACTIONS=true run_publisher publish >/dev/null 2>&1; then
  fail "Catalog promotion overwrote a concurrent pointer advance"
fi
[[ "$(cat "${publisher_state}/data-channel/ref")" == \
    "$(printf 'e%.0s' {1..40})" ]] ||
  fail "concurrent Catalog owner was not preserved"
if rg -q '^release-(publish|latest) v' "${publisher_state}/mutations.log"; then
  fail "public Release was exposed after the Catalog race"
fi

echo "Linnet Action publication owner: PASS (exact drafts + ordered metadata publish + monotonic Catalog)"
