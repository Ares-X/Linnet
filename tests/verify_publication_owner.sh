#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
verifier="${repo_root}/package/verify_publication_artifacts"
asset_manifest="${repo_root}/package/release_asset_manifest"
publisher="${repo_root}/package/publish_github_release"
workflow="${repo_root}/.github/workflows/release-ci.yml"
commit_workflow="${repo_root}/.github/workflows/commit-ci.yml"
pull_request_workflow="${repo_root}/.github/workflows/pull-request-ci.yml"
cache_action="${repo_root}/.github/actions/restore-locked-build-cache/action.yml"

fail() {
  echo "verify_publication_owner: $*" >&2
  exit 1
}

for retired in package/publication_plan package/publish_release \
    config/linnet-publication-acceptance.json; do
  [[ ! -e "${repo_root}/${retired}" ]] ||
    fail "retired approval-commit publication path returned: ${retired}"
done

for owner in "${asset_manifest}" "${publisher}"; do
  [[ -f "${owner}" && ! -L "${owner}" && -x "${owner}" ]] ||
    fail "release channel owner is missing: ${owner##*/}"
  bash -n "${owner}"
done

if ! ruby - "${repo_root}/CHANGELOG.md" <<'RUBY'
text = File.read(ARGV.fetch(0))
sections = text.scan(/^## \d+\.\d+\.\d+ — .*?(?=^## \d+\.\d+\.\d+ — |\z)/m)
abort if sections.empty?
forbidden = [
  /\bREADME\b/i,
  /\bCHANGELOG\b/i,
  /\bGitHub Actions\b/i,
  /\bCI\b/,
  /文档/,
  /安装指南/,
  /下载入口/,
  /发布流程/,
  /发布脚本/,
  /构建流程/,
  /源码/,
]
abort if sections.any? { |section| forbidden.any? { |pattern| section.match?(pattern) } }
RUBY
then
  fail "CHANGELOG version notes contain maintainer-only repository work"
fi

policy_docs=(
  "${repo_root}/docs/product-acceptance.md"
  "${repo_root}/docs/development.md"
  "${repo_root}/docs/release.md"
)
if rg -ni 'approval commit|publication=go|installation_uat=passed|machine-bound' \
    "${policy_docs[@]}"; then
  fail "retired publication approval state returned to the policy documents"
fi
if rg -n '\b[0-9]+\.[0-9]+\.[0-9]+\b' "${repo_root}/docs/release.md"; then
  fail "the release guide hard-coded a product version"
fi

signing_contract="${repo_root}/config/linnet-community-signing.json"
product_contract="${repo_root}/config/LinnetProduct.xcconfig"
if ! ruby -rjson -rdigest -ropen3 -rtime - "${repo_root}" "${signing_contract}" \
    "${product_contract}" "${policy_docs[@]}" <<'RUBY'
root, signing_path, product_path, *policy_paths = ARGV
document = JSON.parse(File.binread(signing_path))
abort unless document.keys.sort ==
  %w[certificate_sha1 certificate_sha256 format legacy_migration_acceptance profile]
abort unless document.fetch("format") == 2 &&
  document.fetch("profile") == "community-cms"
sha1 = document.fetch("certificate_sha1")
sha256 = document.fetch("certificate_sha256")
abort unless sha1.match?(/\A[0-9A-F]{40}\z/) && sha256.match?(/\A[0-9a-f]{64}\z/)

acceptance = document.fetch("legacy_migration_acceptance")
abort unless acceptance.keys.sort ==
  %w[contract core_package format runtime scope source_revision target]
source_revision = acceptance.fetch("source_revision")
abort unless acceptance.fetch("format") == 1 &&
  acceptance.fetch("scope") == "core-installer-lifecycle" &&
  source_revision.match?(/\A[0-9a-f]{40}\z/)
_, object_status = Open3.capture2e(
  "git", "-C", root, "cat-file", "-e", "#{source_revision}^{commit}")
_, ancestor_status = Open3.capture2e(
  "git", "-C", root, "merge-base", "--is-ancestor", source_revision, "HEAD")
abort unless object_status.success? && ancestor_status.success?

artifact = acceptance.fetch("core_package")
abort unless artifact.keys.sort == %w[build name sha256 size version]
abort unless artifact.fetch("version").match?(/\A\d+\.\d+\.\d+\z/) &&
  artifact.fetch("build").match?(/\A[1-9]\d*\z/) &&
  artifact.fetch("name") ==
    "Linnet-#{artifact.fetch("version")}-arm64-Core-community-beta.pkg" &&
  artifact.fetch("sha256").match?(/\A[0-9a-f]{64}\z/) &&
  artifact.fetch("size").is_a?(Integer) && artifact.fetch("size").positive?
historical_product, historical_product_status = Open3.capture2(
  "git", "-C", root, "show", "#{source_revision}:config/LinnetProduct.xcconfig")
abort unless historical_product_status.success? &&
  historical_product[/^MARKETING_VERSION = (\S+)$/, 1] == artifact.fetch("version") &&
  historical_product[/^CURRENT_PROJECT_VERSION = (\S+)$/, 1] == artifact.fetch("build") &&
  historical_product[/^LINNET_BUNDLE_IDENTIFIER = (\S+)$/, 1] ==
    acceptance.fetch("target").fetch("bundle_identifier")

target = acceptance.fetch("target")
abort unless target.keys.sort == %w[bundle_identifier certificate_sha256]
product = File.read(product_path)
bundle_identifier = product[/^LINNET_BUNDLE_IDENTIFIER = (\S+)$/, 1]
abort unless target.fetch("bundle_identifier") == bundle_identifier &&
  target.fetch("certificate_sha256") == sha256
historical_signing_text, historical_signing_status = Open3.capture2(
  "git", "-C", root, "show", "#{source_revision}:config/linnet-community-signing.json")
abort unless historical_signing_status.success?
historical_signing = JSON.parse(historical_signing_text)
abort unless historical_signing.fetch("certificate_sha256") ==
  target.fetch("certificate_sha256")

contract = acceptance.fetch("contract")
abort unless contract.keys.sort == %w[algorithm paths sha256]
abort unless contract.fetch("algorithm") == "sha256-git-mode-content-path-v1"
expected_paths = %w[
  package/Distribution-Core.xml
  package/core-installer-scripts/preinstall
  package/installer-scripts/candidate-app-identity.sh
  package/installer-scripts/postinstall
  package/installer-scripts/quit-applications-clean.jxa
  sources/InputSource.swift
  sources/Main.swift
]
paths = contract.fetch("paths")
abort unless paths == expected_paths && paths == paths.sort && paths.uniq == paths
entries = paths.map do |path|
  absolute = File.join(root, path)
  abort unless File.file?(absolute) && !File.symlink?(absolute)
  index, status = Open3.capture2("git", "-C", root, "ls-files", "-s", "--", path)
  abort unless status.success?
  match = index.match(/\A(\d{6}) [0-9a-f]{40,64} 0\t/)
  abort unless match
  "#{match[1]}\t#{Digest::SHA256.file(absolute).hexdigest}\t#{path}\n"
end
historical_entries = paths.map do |path|
  tree, tree_status = Open3.capture2(
    "git", "-C", root, "ls-tree", source_revision, "--", path)
  match = tree.match(/\A(\d{6}) blob [0-9a-f]{40,64}\t/)
  content, content_status = Open3.capture2(
    "git", "-C", root, "show", "#{source_revision}:#{path}")
  abort unless tree_status.success? && content_status.success? && match
  "#{match[1]}\t#{Digest::SHA256.hexdigest(content)}\t#{path}\n"
end
contract_sha256 = contract.fetch("sha256")
abort unless contract_sha256.match?(/\A[0-9a-f]{64}\z/) &&
  Digest::SHA256.hexdigest(entries.join) == contract_sha256 &&
  Digest::SHA256.hexdigest(historical_entries.join) == contract_sha256

runtime = acceptance.fetch("runtime")
abort unless runtime.keys.sort == %w[
  architecture initial_enable_reassertions initial_install_time
  initial_transition installer_authorization login_session_preserved macos_major
  same_artifact_reinstall_enable_reassertions same_artifact_reinstall_time
]
abort unless runtime.fetch("architecture") == "arm64" &&
  runtime.fetch("macos_major").is_a?(Integer) && runtime.fetch("macos_major").positive? &&
  runtime.fetch("installer_authorization") == "none" &&
  runtime.fetch("login_session_preserved") == true &&
  runtime.fetch("initial_transition") == "legacy-community-adhoc-to-cms" &&
  runtime.fetch("initial_enable_reassertions") == 1 &&
  runtime.fetch("same_artifact_reinstall_enable_reassertions") == 0
%w[initial_install_time same_artifact_reinstall_time].each do |field|
  abort unless runtime.fetch(field).match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}\z/)
end
abort unless Time.iso8601(runtime.fetch("same_artifact_reinstall_time")) >
  Time.iso8601(runtime.fetch("initial_install_time"))

policy_paths.each do |path|
  text = File.read(path)
  abort unless text.include?("config/linnet-community-signing.json") &&
    text.include?("迁移契约指纹") && text.include?("两轮同 leaf Core")
end
release = File.read(policy_paths.find { |path| path.end_with?("release.md") })
abort if release.include?("完成旧 ad-hoc → 固定 CMS 升级和第二次同 leaf Core 升级")
abort unless release.include?("首次公开后即前一公开版")
product_acceptance = File.read(
  policy_paths.find { |path| path.end_with?("product-acceptance.md") })
abort unless product_acceptance.match?(
  /previous public build after the first\s+publication/)
development = File.read(policy_paths.find { |path| path.end_with?("development.md") })
abort unless development.include?("首次公开后即前一公开版")
RUBY
then
  fail "the durable legacy-to-CMS migration acceptance contract is invalid"
fi

if printf '%s\n' config/LinnetProduct.xcconfig |
    "${repo_root}/package/data_release_metadata" check-source-change \
      >/dev/null 2>&1; then
  fail "a Core identity change can still reuse an already-published Catalog sequence"
fi
printf '%s\n' config/LinnetProduct.xcconfig config/linnet-data-releases.json |
  "${repo_root}/package/data_release_metadata" check-source-change >/dev/null

version="$(sed -n 's/^MARKETING_VERSION = \([^[:space:]]*\)$/\1/p' \
  "${repo_root}/config/LinnetProduct.xcconfig")"
if ! ruby - "${repo_root}/README.md" "${version}" <<'RUBY'
readme, version = ARGV
versions = File.read(readme).scan(/\b\d+\.\d+\.\d+\b/)
abort unless versions == [version]
RUBY
then
  fail "README must project the current Core version exactly once"
fi
current_release_change="$(ruby - "${repo_root}/CHANGELOG.md" "${version}" <<'RUBY'
path, version = ARGV
lines = File.readlines(path, chomp: true)
start = lines.index { |line| line.start_with?("## #{version} — ") }
abort unless start
finish = ((start + 1)...lines.size).find { |index| lines.fetch(index).start_with?("## ") } || lines.size
change = lines[(start + 1)...finish].find { |line| line.start_with?("- ") }
abort unless change
puts change
RUBY
)"
adjacent_release_heading="$(ruby - "${repo_root}/CHANGELOG.md" "${version}" <<'RUBY'
path, version = ARGV
headings = File.readlines(path, chomp: true).grep(/^## \d+\.\d+\.\d+ — /)
current = headings.index { |line| line.start_with?("## #{version} — ") }
abort unless current && headings[current + 1]
puts headings.fetch(current + 1).split(" — ", 2).first
RUBY
)"
catalog_sequence="$("${repo_root}/package/data_release_metadata" get-catalog-sequence \
  "${repo_root}/config/linnet-data-releases.json")"
candidate_expected="$(printf '%s\n' \
  Linnet.pkg \
  "Linnet-${version}-arm64-Core-community-beta.pkg" \
  "Linnet-${version}-Uninstall.command" \
  Linnet-Chinese.linnetpack Linnet-English.linnetpack \
  Linnet-LTS.linnetpack Linnet-Extended.linnetpack \
  Linnet-Data-Channel.json | LC_ALL=C sort)"
public_expected=Linnet.pkg
core_expected="$(printf '%s\n' \
  "Linnet-${version}-arm64-Core-community-beta.pkg" \
  "Linnet-${version}-Uninstall.command" | LC_ALL=C sort)"
data_expected="$(printf '%s\n' \
  Linnet-Chinese.linnetpack Linnet-English.linnetpack \
  Linnet-LTS.linnetpack Linnet-Extended.linnetpack \
  Linnet-Data-Channel.json | LC_ALL=C sort)"
for spec in \
    "candidate:${candidate_expected}" \
    "public:${public_expected}" \
    "core:${core_expected}" \
    "data:${data_expected}"; do
  channel="${spec%%:*}"
  expected="${spec#*:}"
  actual="$("${asset_manifest}" "${channel}" "${version}" "${catalog_sequence}" |
    LC_ALL=C sort)" || fail "cannot project ${channel} release assets"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${channel} release asset inventory differs from the product contract"
done
if "${asset_manifest}" public "${version}" "${catalog_sequence}" |
    rg -q '\.sha256$|Core|linnetpack|Data-Channel'; then
  fail "the stable user Release regained component or checksum assets"
fi
for required in \
    '"${project_root}/package/verify_publication_artifacts"' \
    'git/ref/heads/main' \
    'actions/workflows/commit-ci.yml/runs' \
    'run.fetch("path") == ".github/workflows/commit-ci.yml"' \
    'data-seed-${catalog_sequence}' \
    'release create "${tag}" "${assets[@]}"' \
    'release delete "${tag}"' \
    'release_tag_preexisting' \
    'git/ref/tags/${requested_tag}' \
    'verify_retryable_draft_assets' \
    'verify_release_state' \
    'verify_assets' \
    'release edit "${tag}"' \
    'core-v${version}' \
    'data-${catalog_sequence}' \
    'refs/heads/data-channel' \
    '"${api}/blobs"' \
    '"${api}/trees"' \
    '"${api}/commits"' \
    'force=false'; do
  rg -Fq "${required}" "${publisher}" ||
    fail "the bounded GitHub publication state machine is incomplete: ${required}"
done
if rg -n -- '--clobber|--cleanup-tag|releases/delete' "${publisher}"; then
  fail "the publisher regained a destructive published-asset replacement path"
fi
if rg -n 'verify_draft_target|targetCommitish' "${publisher}"; then
  fail "draft metadata regained authority over the exact tag ref"
fi
if rg -Fq 'actions/runs' "${publisher}" "${workflow}"; then
  fail "publication regained a repository-wide same-name CI lookup"
fi
if rg -Fq 'repos/${repository}/commits/${requested_tag}' "${publisher}"; then
  fail "the publisher regained a branch-compatible tag identity lookup"
fi
rg -Fq 'actions: read' "${workflow}" ||
  fail "the release publisher cannot read exact main CI evidence"
rg -Fq 'LINNET_RELEASE_TOOL: ${{ runner.temp }}/linnet-pack' \
    "${workflow}" ||
  fail "the release publisher did not retain the verified pack CLI"
if rg -Fq 'package/publish_github_release data-seed' "${workflow}"; then
  fail "the product release workflow regained the cold-build seed path"
fi

ruby -e '
  workflow = File.read(ARGV.fetch(0))
  publisher = File.read(ARGV.fetch(1))
  abort if workflow.match?(/^\s*push:\s*$/)
  abort unless workflow.scan(/^\s*make --no-print-directory archive\s*$/).size == 1
  abort unless workflow.scan(%r{^\s*uses:\s*actions/upload-artifact@[0-9a-f]{40}(?:\s+#.*)?$}).size == 1
  abort unless workflow.scan(%r{^\s*uses:\s*actions/download-artifact@[0-9a-f]{40}(?:\s+#.*)?$}).size == 2
  release_path = %q{path: ${{ runner.temp }}/linnet-candidate/release}
  abort unless workflow.scan(/^\s*#{Regexp.escape(release_path)}\s*$/).size == 3
  abort if workflow.match?(%r{^\s*path:\s*\$\{\{ runner\.temp \}\}/linnet-candidate(?:/tools)?\s*$})
  abort unless workflow.scan(/package\/verify_publication_artifacts/).size == 3
  abort unless workflow.include?("build-candidate:") &&
    workflow.include?("stage-update-channels:") &&
    workflow.include?("publish-stable:")
  abort unless workflow.scan(/^    environment: community-publication$/).size == 1
  abort unless workflow.scan(/artifact-ids:\s*\$\{\{ needs\.build-candidate\.outputs\.artifact_id \}\}/).size == 2
  build = workflow[/^  build-candidate:\n(?<body>.*?)(?=^  [a-z][a-z0-9-]*:\n|\z)/m, :body]
  stage = workflow[/^  stage-update-channels:\n(?<body>.*?)(?=^  [a-z][a-z0-9-]*:\n|\z)/m, :body]
  public_job = workflow[/^  publish-stable:\n(?<body>.*?)(?=^  [a-z][a-z0-9-]*:\n|\z)/m, :body]
  abort unless build && stage && public_job
  abort unless stage.include?("environment: community-publication")
  abort if public_job.include?("environment: community-publication")
  ci_contract = [
    %q{actions/workflows/commit-ci.yml/runs},
    %q{run.fetch("name") == "Linnet commit CI"},
    %q{run.fetch("path") == ".github/workflows/commit-ci.yml"},
    %q{run.fetch("head_sha") == revision},
    %q{run.fetch("head_branch") == "main"},
    %q{run.fetch("event") == "push"},
    %q{run.fetch("status") == "completed"},
    %q{run.fetch("conclusion") == "success"},
  ]
  [build, publisher].each do |boundary|
    abort unless ci_contract.all? { |predicate| boundary.include?(predicate) }
  end
  abort unless build.index("git/ref/heads/main") <
    build.index("LINNET_COMMUNITY_CMS_P12_BASE64")
  abort unless build.index("actions/workflows/commit-ci.yml/runs") <
    build.index("LINNET_COMMUNITY_CMS_P12_BASE64")
  abort unless build.include?(%q{run.fetch("path") == ".github/workflows/commit-ci.yml"})
  abort unless build.include?(%q{rm -rf -- "${signing_root}"})
  abort unless build.index("package/verify_publication_artifacts") <
    build.index("actions/upload-artifact")
  abort unless stage.include?("package/publish_github_release core") &&
    stage.include?("package/publish_github_release data") &&
    stage.include?("package/publish_github_release catalog")
  abort unless public_job.include?("package/publish_github_release public")
  [stage, public_job].each do |job|
    abort if job.match?(/make --no-print-directory archive|LINNET_COMMUNITY_CMS|LINNET_CODE_SIGN|security import/)
    abort unless job.scan(/xcrun swiftc/).size == 1
    abort unless job.scan(/package\/verify_publication_artifacts/).size == 1
    abort unless job.index("actions/download-artifact") <
      job.index("package/verify_publication_artifacts")
  end
' "${workflow}" "${publisher}" ||
  fail "the release workflow can rebuild or replace the installation candidate bytes"

publication_fixture="$(mktemp -d "${TMPDIR:-/tmp}/linnet-publication-owner.XXXXXX")"
cleanup() {
  [[ "${publication_fixture}" == "${TMPDIR:-/tmp}/linnet-publication-owner."* ]] &&
    rm -rf -- "${publication_fixture}"
}
trap cleanup EXIT
fixture_assets="${publication_fixture}/assets"
fake_bin="${publication_fixture}/bin"
fake_state="${publication_fixture}/state"
fixture_repo="${publication_fixture}/repo"
fixture_publisher="${fixture_repo}/package/publish_github_release"
fake_release_tool="${publication_fixture}/linnet-pack"
mkdir -p "${fixture_assets}" "${fake_bin}" "${fake_state}" \
  "${fixture_repo}/package"
cp "${publisher}" "${fixture_publisher}"
cp "${asset_manifest}" "${fixture_repo}/package/release_asset_manifest"
cp "${repo_root}/CHANGELOG.md" "${fixture_repo}/CHANGELOG.md"
cat >"${fixture_repo}/package/verify_publication_artifacts" <<'FAKE_VERIFIER'
#!/usr/bin/env bash
set -euo pipefail
printf 'verify_publication_artifacts %s\n' "$*" >>"${FAKE_GH_STATE:?}/calls.log"
[[ "$#" -eq 3 && "$1" == "${FAKE_RELEASE_ASSETS:?}" ]]
[[ "$2" == "${FAKE_VERSION:?}" && "$3" == "${FAKE_CANDIDATE_REVISION:?}" ]]
[[ "${LINNET_RELEASE_TOOL:-}" == "${FAKE_RELEASE_TOOL:?}" &&
  -x "${LINNET_RELEASE_TOOL}" ]]
[[ -f "${FAKE_GH_STATE}/artifacts-valid" ]]
FAKE_VERIFIER
chmod 755 "${fixture_publisher}" \
  "${fixture_repo}/package/release_asset_manifest" \
  "${fixture_repo}/package/verify_publication_artifacts"
printf '#!/usr/bin/env bash\nexit 0\n' >"${fake_release_tool}"
chmod 755 "${fake_release_tool}"
git -C "${fixture_repo}" init -q
git -C "${fixture_repo}" add CHANGELOG.md package
git -C "${fixture_repo}" -c user.name=Linnet -c user.email=linnet.invalid \
  commit -qm 'publication fixture'
candidate_revision="$(git -C "${fixture_repo}" rev-parse HEAD)"
printf '%s\n' "${candidate_revision}" >"${fake_state}/main-ref"
ruby -rjson -e '
  puts JSON.generate({"workflow_runs" => [{
    "name" => "Linnet commit CI",
    "path" => ".github/workflows/commit-ci.yml",
    "head_sha" => ARGV.fetch(0),
    "head_branch" => "main",
    "event" => "push",
    "status" => "completed",
    "conclusion" => "success",
  }]})
' "${candidate_revision}" >"${fake_state}/main-ci.json"
: >"${fake_state}/artifacts-valid"
while IFS= read -r asset; do
  printf 'fixture:%s\n' "${asset}" >"${fixture_assets}/${asset}"
done < <("${asset_manifest}" candidate "${version}" "${catalog_sequence}")
printf '{"sequence":%s}\n' "${catalog_sequence}" \
  >"${fixture_assets}/Linnet-Data-Channel.json"
cat >"${fake_bin}/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_GH_STATE:?}"
printf '%s\n' "$*" >>"${state}/calls.log"
if [[ "${1:-}" == api ]]; then
  shift
  method=GET
  include=false
  input=""
  endpoint=""
  sha_field=""
  force_field=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --method) method="$2"; shift 2 ;;
      --include) include=true; shift ;;
      --input) input="$2"; shift 2 ;;
      --jq) shift 2 ;;
      -f|-F)
        case "$2" in
          sha=*) sha_field="${2#sha=}" ;;
          force=*) force_field="${2#force=}" ;;
        esac
        shift 2
        ;;
      *) [[ -z "${endpoint}" ]] && endpoint="$1"; shift ;;
    esac
  done
  branch="${state}/data-channel"
  mkdir -p "${branch}/blobs" "${branch}/trees" "${branch}/commits"
  case "${method}:${endpoint}" in
    GET:repos/Ares-X/Linnet/git/ref/heads/main)
      cat "${state}/main-ref"
      ;;
    GET:repos/Ares-X/Linnet/actions/workflows/commit-ci.yml/runs)
      cat "${state}/main-ci.json"
      ;;
    GET:repos/Ares-X/Linnet/commits/*)
      release_tag="${endpoint##*/}"
      if [[ -f "${state}/tags/${release_tag}" ]]; then
        cat "${state}/tags/${release_tag}"
      elif [[ -f "${state}/branches/${release_tag}" ]]; then
        cat "${state}/branches/${release_tag}"
      else
        exit 1
      fi
      ;;
    GET:repos/Ares-X/Linnet/git/ref/tags/*)
      release_tag="${endpoint##*/}"
      if [[ -f "${state}/tag-ref-transport-error" ]]; then
        printf '%s\n' 'gh: simulated tag-ref transport failure' >&2
        exit 1
      fi
      if [[ -f "${state}/tags/${release_tag}" ]]; then
        object_type=commit
        object_sha="$(cat "${state}/tags/${release_tag}")"
        if [[ -f "${state}/tag-types/${release_tag}" ]]; then
          object_type="$(cat "${state}/tag-types/${release_tag}")"
          object_sha="$(cat "${state}/tag-object-ids/${release_tag}")"
        fi
        [[ "${include}" == false ]] || printf 'HTTP/2.0 200 OK\n\n'
        printf '{"ref":"refs/tags/%s","object":{"type":"%s","sha":"%s"}}\n' \
          "${release_tag}" "${object_type}" "${object_sha}"
      else
        [[ "${include}" == false ]] || printf 'HTTP/2.0 404 Not Found\n\n'
        printf '%s\n' '{"message":"Not Found","status":"404"}'
        exit 1
      fi
      ;;
    GET:repos/Ares-X/Linnet/git/tags/*)
      object_sha="${endpoint##*/}"
      [[ -f "${state}/tag-objects/${object_sha}" ]] || exit 1
      cat "${state}/tag-objects/${object_sha}"
      ;;
    GET:repos/Ares-X/Linnet/git/ref/heads/data-channel)
      if [[ ! -f "${branch}/ref" ]]; then
        printf '%s\n' '{"message":"Not Found","status":"404"}'
        exit 1
      fi
      cat "${branch}/ref"
      ;;
    GET:repos/Ares-X/Linnet/git/commits/*)
      sed -n '1p' "${branch}/commits/${endpoint##*/}"
      ;;
    GET:repos/Ares-X/Linnet/git/trees/*)
      cat "${branch}/trees/${endpoint##*/}"
      ;;
    GET:repos/Ares-X/Linnet/git/blobs/*)
      base64 <"${branch}/blobs/${endpoint##*/}" | tr -d '\n'
      ;;
    POST:repos/Ares-X/Linnet/git/blobs)
      sha="$(ruby -rjson -rbase64 -e '
        document = JSON.parse(File.read(ARGV.fetch(0)))
        bytes = Base64.strict_decode64(document.fetch("content"))
        File.binwrite(ARGV.fetch(1), bytes)
        print Digest::SHA1.hexdigest(bytes)
      ' -rdigest "${input}" "${branch}/pending-blob")"
      mv "${branch}/pending-blob" "${branch}/blobs/${sha}"
      printf '%s\n' "${sha}"
      ;;
    POST:repos/Ares-X/Linnet/git/trees)
      blob="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("tree").fetch(0).fetch("sha")' "${input}")"
      sha="$(printf 'tree:%s' "${blob}" | shasum | awk '{print $1}')"
      printf '%s\n' "${blob}" >"${branch}/trees/${sha}"
      printf '%s\n' "${sha}"
      ;;
    POST:repos/Ares-X/Linnet/git/commits)
      ruby -rjson -e '
        document = JSON.parse(File.read(ARGV.fetch(0)))
        parents = document.fetch("parents", [])
        abort unless parents.all? { |parent| parent.match?(/\A[0-9a-f]{40}\z/) }
      ' "${input}"
      tree="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("tree")' "${input}")"
      parent="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("parents", []).first.to_s' "${input}")"
      if [[ -n "${parent}" ]]; then
        [[ -f "${branch}/ref" && "$(cat "${branch}/ref")" == "${parent}" ]]
      else
        [[ ! -f "${branch}/ref" ]]
      fi
      count=1
      [[ ! -f "${branch}/commit-count" ]] || count=$(( $(cat "${branch}/commit-count") + 1 ))
      printf '%s\n' "${count}" >"${branch}/commit-count"
      sha="$(printf 'commit:%s:%s' "${tree}" "${count}" | shasum | awk '{print $1}')"
      printf '%s\n%s\n' "${tree}" "${parent}" >"${branch}/commits/${sha}"
      printf '%s\n' "${sha}"
      ;;
    POST:repos/Ares-X/Linnet/git/refs)
      [[ ! -f "${branch}/ref" && -n "${sha_field}" ]]
      printf '%s\n' "${sha_field}" >"${branch}/ref"
      ;;
    PATCH:repos/Ares-X/Linnet/git/refs/heads/data-channel)
      [[ -f "${branch}/ref" && -n "${sha_field}" && "${force_field}" == false ]]
      if [[ -f "${branch}/inject-race" ]]; then
        mv "${branch}/inject-race" "${branch}/ref"
      fi
      current="$(cat "${branch}/ref")"
      parent="$(sed -n '2p' "${branch}/commits/${sha_field}")"
      if [[ -z "${parent}" || "${parent}" != "${current}" ]]; then
        exit 1
      fi
      printf '%s\n' "${sha_field}" >"${branch}/ref"
      ;;
    *) exit 2 ;;
  esac
  exit 0
fi
[[ "${1:-} ${2:-}" == "release view" || "${1:-} ${2:-}" == "release create" ||
  "${1:-} ${2:-}" == "release edit" || "${1:-} ${2:-}" == "release delete" ||
  "${1:-} ${2:-}" == "release download" ]] || exit 2
action="$2"
tag="${3:-}"
root="${state}/${tag}"
case "${action}" in
  view)
    if [[ -f "${state}/release-view-transport-error" ]]; then
      printf '%s\n' 'gh: simulated release-view transport failure' >&2
      exit 1
    fi
    if [[ ! -f "${root}/status" ]]; then
      printf '%s\n' 'release not found' >&2
      exit 1
    fi
    read -r draft prerelease <"${root}/status"
    joined=" $* "
    if [[ "${joined}" == *" --json assets "* ]]; then
      cat "${root}/assets"
    elif [[ "${joined}" == *" --jq "* ]]; then
      printf '%s\n' "${draft}"
    else
      printf '{"isDraft":%s,"isPrerelease":%s}\n' "${draft}" "${prerelease}"
    fi
    ;;
  create)
    mkdir -p "${root}"
    : >"${root}/assets"
    shift 3
    while [[ "$#" -gt 0 && "$1" != --* ]]; do
      digest="$(shasum -a 256 "$1" | awk '{print $1}')"
      printf '%s\tsha256:%s\n' "${1##*/}" "${digest}" >>"${root}/assets"
      shift
    done
    LC_ALL=C sort -o "${root}/assets" "${root}/assets"
    prerelease=false
    revision="${FAKE_CANDIDATE_REVISION:?}"
    verify_tag=false
    [[ " $* " == *" --prerelease "* ]] && prerelease=true
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --notes-file)
          cp "$2" "${root}/notes"
          shift 2
          ;;
        --target)
          revision="$2"
          shift 2
          ;;
        --verify-tag)
          verify_tag=true
          shift
          ;;
        *) shift ;;
      esac
    done
    if [[ "${verify_tag}" == true ]]; then
      [[ -f "${state}/tags/${tag}" ]] || exit 1
      revision="$(cat "${state}/tags/${tag}")"
    else
      mkdir -p "${state}/tags"
      if [[ -f "${state}/tag-create-races/${tag}" ]]; then
        mv "${state}/tag-create-races/${tag}" "${state}/tags/${tag}"
      fi
      if [[ ! -f "${state}/tags/${tag}" ]]; then
        grep -Eq '^[0-9a-f]{40}$' <<<"${revision}"
        printf '%s\n' "${revision}" >"${state}/tags/${tag}"
      fi
    fi
    printf '%s\n' "${revision}" >"${root}/revision"
    printf 'true %s\n' "${prerelease}" >"${root}/status"
    ;;
  edit)
    read -r _ prerelease <"${root}/status"
    shift 3
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --notes-file)
          cp "$2" "${root}/notes"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    printf 'false %s\n' "${prerelease}" >"${root}/status"
    ;;
  delete)
    rm -rf -- "${root}"
    ;;
  download)
    destination=""
    pattern=""
    shift 3
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --dir) destination="$2"; shift 2 ;;
        --pattern) pattern="$2"; shift 2 ;;
        --repo) shift 2 ;;
        *) shift ;;
      esac
    done
    [[ -f "${root}/status" && -n "${destination}" && -n "${pattern}" ]]
    [[ "${pattern}" == "${pattern##*/}" && -f "${FAKE_RELEASE_ASSETS:?}/${pattern}" ]]
    cut -f1 "${root}/assets" | grep -Fxq "${pattern}"
    cp "${FAKE_RELEASE_ASSETS}/${pattern}" "${destination}/${pattern}"
    ;;
esac
FAKE_GH
chmod 755 "${fake_bin}/gh"
run_fixture() {
  GITHUB_REPOSITORY=Ares-X/Linnet GH_TOKEN=fixture \
    FAKE_GH_STATE="${fake_state}" FAKE_RELEASE_ASSETS="${fixture_assets}" \
    FAKE_CANDIDATE_REVISION="${candidate_revision}" FAKE_VERSION="${version}" \
    FAKE_RELEASE_TOOL="${fake_release_tool}" \
    LINNET_RELEASE_TOOL="${fake_release_tool}" \
    RUNNER_TEMP="${publication_fixture}" \
    PATH="${fake_bin}:${PATH}" "${fixture_publisher}" "$1" "${fixture_assets}" \
      "${version}" "${catalog_sequence}" "${candidate_revision}"
}
publish_fixture() {
  if ! run_fixture "$1" >/dev/null; then
    fail "publisher rejected the ${1} fixture"
  fi
}
require_public_fixture_rejection() {
  local ref_before="" commits_before=""
  if [[ -f "${fake_state}/data-channel/ref" ]]; then
    ref_before="$(cat "${fake_state}/data-channel/ref")"
    commits_before="$(cat "${fake_state}/data-channel/commit-count")"
  fi
  if run_fixture public >"${publication_fixture}/rejected-public.log" 2>&1; then
    fail "the public Release accepted incomplete staged publication state"
  fi
  [[ ! -e "${fake_state}/v${version}" ]] ||
    fail "a rejected public publication left a formal Release"
  if [[ -n "${ref_before}" ]]; then
    [[ "$(cat "${fake_state}/data-channel/ref")" == "${ref_before}" &&
      "$(cat "${fake_state}/data-channel/commit-count")" == "${commits_before}" ]] ||
      fail "a rejected public publication changed stable pointer state"
  else
    [[ ! -e "${fake_state}/data-channel/ref" &&
      ! -e "${fake_state}/data-channel/commit-count" ]] ||
      fail "a rejected public publication created stable pointer state"
  fi
}
require_unpromoted_catalog_rejection() {
  if run_fixture catalog >"${publication_fixture}/rejected-catalog.log" 2>&1; then
    fail "Catalog promotion accepted an unauthorized candidate"
  fi
  [[ ! -e "${fake_state}/data-channel/ref" &&
    ! -e "${fake_state}/data-channel/commit-count" ]] ||
    fail "a rejected Catalog candidate changed stable pointer state"
}
require_catalog_fixture_rejection() {
  local ref_before commits_before
  ref_before="$(cat "${fake_state}/data-channel/ref")"
  commits_before="$(cat "${fake_state}/data-channel/commit-count")"
  if run_fixture catalog >"${publication_fixture}/rejected-catalog.log" 2>&1; then
    fail "Catalog promotion accepted a non-monotonic stable pointer"
  fi
  [[ "$(cat "${fake_state}/data-channel/ref")" == "${ref_before}" &&
    "$(cat "${fake_state}/data-channel/commit-count")" == "${commits_before}" ]] ||
    fail "a rejected Catalog promotion changed stable pointer state"
}

mkdir -p "${fake_state}/branches"
printf '%s\n' "${candidate_revision}" \
  >"${fake_state}/branches/data-seed-${catalog_sequence}"
if run_fixture data-seed >"${publication_fixture}/rejected-seed.log" 2>&1; then
  fail "data seed publication accepted a missing seed tag"
fi
[[ ! -e "${fake_state}/data-${catalog_sequence}" &&
  ! -e "${fake_state}/data-channel/ref" ]] ||
  fail "a rejected data seed changed remote publication state"
mkdir -p "${fake_state}/tags"
printf '%040d\n' 0 >"${fake_state}/tags/data-seed-${catalog_sequence}"
if run_fixture data-seed >"${publication_fixture}/rejected-seed.log" 2>&1; then
  fail "data seed publication accepted a mismatched seed tag"
fi
printf '%s\n' "${candidate_revision}" \
  >"${fake_state}/tags/data-seed-${catalog_sequence}"
printf '%040d\n' 0 >"${fake_state}/main-ref"
ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  document.fetch("workflow_runs").fetch(0)["conclusion"] = "failure"
  File.binwrite(ARGV.fetch(0), JSON.generate(document))
' "${fake_state}/main-ci.json"
main_checks_before_seed="$(awk '/git\/ref\/heads\/main|actions\/workflows\/commit-ci.yml\/runs/ { count += 1 } END { print count + 0 }' \
  "${fake_state}/calls.log")"
seed_creates_before="$(grep -c "^release create data-${catalog_sequence} " \
  "${fake_state}/calls.log" || true)"
seed_deletes_before="$(grep -c "^release delete data-${catalog_sequence} " \
  "${fake_state}/calls.log" || true)"
: >"${fake_state}/tag-ref-transport-error"
if run_fixture data-seed >"${publication_fixture}/rejected-seed.log" 2>&1; then
  fail "data seed publication treated an unavailable tag owner as absent"
fi
[[ "$(grep -c "^release create data-${catalog_sequence} " \
  "${fake_state}/calls.log" || true)" == "${seed_creates_before}" &&
  "$(grep -c "^release delete data-${catalog_sequence} " \
  "${fake_state}/calls.log" || true)" == "${seed_deletes_before}" ]] ||
  fail "an unavailable tag owner authorized a release mutation"
rm "${fake_state}/tag-ref-transport-error"
: >"${fake_state}/release-view-transport-error"
if run_fixture data-seed >"${publication_fixture}/rejected-seed.log" 2>&1; then
  fail "data seed publication treated an unavailable Release owner as absent"
fi
[[ "$(grep -c "^release create data-${catalog_sequence} " \
  "${fake_state}/calls.log" || true)" == "${seed_creates_before}" &&
  "$(grep -c "^release delete data-${catalog_sequence} " \
  "${fake_state}/calls.log" || true)" == "${seed_deletes_before}" ]] ||
  fail "an unavailable Release owner authorized a release mutation"
rm "${fake_state}/release-view-transport-error"
printf '%s\n' "${candidate_revision}" \
  >"${fake_state}/branches/data-${catalog_sequence}"
publish_fixture data-seed
main_checks_after_seed="$(awk '/git\/ref\/heads\/main|actions\/workflows\/commit-ci.yml\/runs/ { count += 1 } END { print count + 0 }' \
  "${fake_state}/calls.log")"
[[ "${main_checks_after_seed}" == "${main_checks_before_seed}" ]] ||
  fail "the isolated data seed incorrectly depended on main publication state"
[[ ! -e "${fake_state}/data-channel/ref" &&
  "$(cut -f1 "${fake_state}/data-${catalog_sequence}/assets")" == "${data_expected}" ]] ||
  fail "the data seed escaped its five-asset prerelease boundary"
printf '%s\n' "${candidate_revision}" >"${fake_state}/main-ref"
ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  document.fetch("workflow_runs").fetch(0)["conclusion"] = "success"
  File.binwrite(ARGV.fetch(0), JSON.generate(document))
' "${fake_state}/main-ci.json"

core_creates_before="$(grep -c "^release create core-v${version} " \
  "${fake_state}/calls.log" || true)"
ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  document.fetch("workflow_runs").fetch(0)["path"] = ".github/workflows/lookalike-ci.yml"
  File.binwrite(ARGV.fetch(0), JSON.generate(document))
' "${fake_state}/main-ci.json"
if run_fixture core >"${publication_fixture}/rejected-ci-owner.log" 2>&1; then
  fail "the publisher accepted a same-name run from another workflow"
fi
[[ "$(grep -c "^release create core-v${version} " \
  "${fake_state}/calls.log" || true)" == "${core_creates_before}" ]] ||
  fail "a foreign CI workflow authorized a Release mutation"
ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  document.fetch("workflow_runs").fetch(0)["path"] = ".github/workflows/commit-ci.yml"
  File.binwrite(ARGV.fetch(0), JSON.generate(document))
' "${fake_state}/main-ci.json"

publish_fixture core
rg -Fq -- "${current_release_change}" \
  "${fake_state}/core-v${version}/notes" ||
  fail "the Core Release omitted the version change summary"
printf 'stale core notes\n' >"${fake_state}/core-v${version}/notes"
publish_fixture core
rg -Fq -- "${current_release_change}" \
  "${fake_state}/core-v${version}/notes" ||
  fail "an exact published Core Release did not repair stale notes"
[[ "$(grep -c "^release create core-v${version} " "${fake_state}/calls.log")" == 1 ]] ||
  fail "an exact published Core Release was recreated"
[[ ! -e "${fake_state}/data-channel/ref" &&
  ! -e "${fake_state}/data-channel/commit-count" ]] ||
  fail "the Core channel changed the stable Catalog pointer"

publish_fixture data
[[ ! -e "${fake_state}/data-channel/ref" &&
  ! -e "${fake_state}/data-channel/commit-count" ]] ||
  fail "the data channel changed the stable Catalog pointer before promotion"
cp "${fake_state}/data-${catalog_sequence}/assets" \
  "${publication_fixture}/exact-data-draft-assets"
rm -rf -- "${fake_state}/data-${catalog_sequence}"
mkdir -p "${fake_state}/data-${catalog_sequence}"
printf 'true true\n' >"${fake_state}/data-${catalog_sequence}/status"
printf '%s\n' "${candidate_revision}" >"${fake_state}/data-${catalog_sequence}/revision"
printf '%040d\n' 0 >"${fake_state}/tags/data-${catalog_sequence}"
sed -n '1p' "${publication_fixture}/exact-data-draft-assets" \
  >"${fake_state}/data-${catalog_sequence}/assets"
data_draft_deletes_before="$(grep -c "^release delete data-${catalog_sequence} " \
  "${fake_state}/calls.log" || true)"
if run_fixture data >"${publication_fixture}/rejected-data-draft.log" 2>&1; then
  fail "a data draft whose tag resolves to another revision was replaced"
fi
[[ "$(grep -c "^release delete data-${catalog_sequence} " \
  "${fake_state}/calls.log" || true)" == "${data_draft_deletes_before}" ]] ||
  fail "a foreign data draft was deleted"
printf '%s\n' "${candidate_revision}" \
  >"${fake_state}/tags/data-${catalog_sequence}"
printf 'true false\n' >"${fake_state}/data-${catalog_sequence}/status"
if run_fixture data >"${publication_fixture}/rejected-data-draft.log" 2>&1; then
  fail "a data draft with the wrong release kind was replaced"
fi
[[ "$(grep -c "^release delete data-${catalog_sequence} " \
  "${fake_state}/calls.log" || true)" == "${data_draft_deletes_before}" ]] ||
  fail "a wrong-kind data draft was deleted"
printf 'true true\n' >"${fake_state}/data-${catalog_sequence}/status"
printf 'stale\tsha256:%064d\n' 0 >"${fake_state}/data-${catalog_sequence}/assets"
if run_fixture data >"${publication_fixture}/rejected-data-draft.log" 2>&1; then
  fail "a data draft with foreign assets was replaced"
fi
[[ "$(grep -c "^release delete data-${catalog_sequence} " \
  "${fake_state}/calls.log" || true)" == "${data_draft_deletes_before}" ]] ||
  fail "a data draft with foreign assets was deleted"
sed -n '1p' "${publication_fixture}/exact-data-draft-assets" \
  >"${fake_state}/data-${catalog_sequence}/assets"
publish_fixture data
grep -Fq "release delete data-${catalog_sequence}" "${fake_state}/calls.log" ||
  fail "an interrupted data-channel draft did not enter the bounded retry path"
[[ ! -e "${fake_state}/data-channel/ref" &&
  ! -e "${fake_state}/data-channel/commit-count" ]] ||
  fail "a data-channel retry changed the stable Catalog pointer"
for spec in core:core-v${version} data:data-${catalog_sequence}; do
  channel="${spec%%:*}"
  tag="${spec#*:}"
  expected="$("${asset_manifest}" "${channel}" "${version}" "${catalog_sequence}")"
  actual="$(cut -f1 "${fake_state}/${tag}/assets")"
  [[ "${actual}" == "${expected}" ]] || fail "${channel} upload bypassed the manifest"
done

require_public_fixture_rejection
[[ ! -e "${fake_state}/data-channel/ref" &&
  ! -e "${fake_state}/data-channel/commit-count" ]] ||
  fail "a rejected public publication created the stable Catalog pointer"

rm "${fake_state}/artifacts-valid"
require_unpromoted_catalog_rejection
: >"${fake_state}/artifacts-valid"
rg -Fq "verify_publication_artifacts ${fixture_assets} ${version} ${candidate_revision}" \
  "${fake_state}/calls.log" ||
  fail "Catalog promotion did not invoke the exact final artifact verifier"

printf '%040d\n' 0 >"${fake_state}/main-ref"
require_unpromoted_catalog_rejection
printf '%s\n' "${candidate_revision}" >"${fake_state}/main-ref"

ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  document.fetch("workflow_runs").fetch(0)["conclusion"] = "failure"
  File.binwrite(ARGV.fetch(0), JSON.generate(document))
' "${fake_state}/main-ci.json"
require_unpromoted_catalog_rejection
ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  document.fetch("workflow_runs").fetch(0)["conclusion"] = "success"
  File.binwrite(ARGV.fetch(0), JSON.generate(document))
' "${fake_state}/main-ci.json"

publish_fixture catalog
[[ "$(cat "${fake_state}/data-channel/commit-count")" == 1 ]] ||
  fail "Catalog promotion did not create exactly one stable pointer commit"
catalog_ref="$(cat "${fake_state}/data-channel/ref")"
catalog_tree="$(cat "${fake_state}/data-channel/commits/${catalog_ref}")"
catalog_blob="$(cat "${fake_state}/data-channel/trees/${catalog_tree}")"
cmp -s "${fixture_assets}/Linnet-Data-Channel.json" \
  "${fake_state}/data-channel/blobs/${catalog_blob}" ||
  fail "the data-channel branch did not publish the exact Catalog bytes"
rg -Fq "release download data-${catalog_sequence} --repo Ares-X/Linnet --pattern Linnet-Data-Channel.json" \
  "${fake_state}/calls.log" ||
  fail "Catalog promotion did not verify the exact published data asset"
core_package="Linnet-${version}-arm64-Core-community-beta.pkg"
rg -Fq "release download core-v${version} --repo Ares-X/Linnet --pattern ${core_package}" \
  "${fake_state}/calls.log" ||
  fail "Catalog promotion did not verify the exact published Core asset"

printf '%s\n' "${candidate_revision}" >"${fake_state}/branches/v${version}"
mkdir -p "${fake_state}/tags" "${fake_state}/tag-types" \
  "${fake_state}/tag-object-ids" "${fake_state}/tag-objects"
printf '%040d\n' 0 >"${fake_state}/tags/v${version}"
version_tag_object="$(printf 'tag:v%s:%s' "${version}" "${candidate_revision}" | \
  shasum | awk '{print $1}')"
printf '%s\n' tag >"${fake_state}/tag-types/v${version}"
printf '%s\n' "${version_tag_object}" \
  >"${fake_state}/tag-object-ids/v${version}"
printf 'commit\t%040d\n' 0 \
  >"${fake_state}/tag-objects/${version_tag_object}"
require_public_fixture_rejection
rm "${fake_state}/tags/v${version}" \
  "${fake_state}/tag-types/v${version}" \
  "${fake_state}/tag-object-ids/v${version}" \
  "${fake_state}/tag-objects/${version_tag_object}"
printf '%040d\n' 0 >"${fake_state}/main-ref"
require_public_fixture_rejection
printf '%s\n' "${candidate_revision}" >"${fake_state}/main-ref"
ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  document.fetch("workflow_runs").fetch(0)["conclusion"] = "failure"
  File.binwrite(ARGV.fetch(0), JSON.generate(document))
' "${fake_state}/main-ci.json"
require_public_fixture_rejection
ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  document.fetch("workflow_runs").fetch(0)["conclusion"] = "success"
  File.binwrite(ARGV.fetch(0), JSON.generate(document))
' "${fake_state}/main-ci.json"

for release_tag in "core-v${version}" "data-${catalog_sequence}"; do
  revision="${fake_state}/tags/${release_tag}"
  exact_revision="${publication_fixture}/${release_tag}-exact-revision"
  cp "${revision}" "${exact_revision}"
  printf '%040d\n' 0 >"${revision}"
  require_catalog_fixture_rejection
  require_public_fixture_rejection
  mv "${exact_revision}" "${revision}"
  mv "${revision}" "${exact_revision}"
  printf '%s\n' "${candidate_revision}" \
    >"${fake_state}/branches/${release_tag}"
  require_catalog_fixture_rejection
  require_public_fixture_rejection
  mv "${exact_revision}" "${revision}"
  rm "${fake_state}/branches/${release_tag}"
done

ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  document["sequence"] = Integer(ARGV.fetch(2), 10) + 1
  File.binwrite(ARGV.fetch(1), JSON.generate(document))
' "${fixture_assets}/Linnet-Data-Channel.json" \
  "${fake_state}/data-channel/blobs/${catalog_blob}" "${catalog_sequence}"
require_catalog_fixture_rejection
ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  document["same_sequence_different_bytes"] = true
  File.binwrite(ARGV.fetch(1), JSON.generate(document))
' "${fixture_assets}/Linnet-Data-Channel.json" \
  "${fake_state}/data-channel/blobs/${catalog_blob}"
require_catalog_fixture_rejection
cp "${fixture_assets}/Linnet-Data-Channel.json" \
  "${fake_state}/data-channel/blobs/${catalog_blob}"
publish_fixture catalog
[[ "$(cat "${fake_state}/data-channel/ref")" == "${catalog_ref}" &&
  "$(cat "${fake_state}/data-channel/commit-count")" == 1 ]] ||
  fail "restoring the exact Catalog pointer changed stable state"

race_base_ref="$(cat "${fake_state}/data-channel/ref")"
race_base_tree="$(sed -n '1p' "${fake_state}/data-channel/commits/${race_base_ref}")"
race_base_blob="$(cat "${fake_state}/data-channel/trees/${race_base_tree}")"
ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  document["sequence"] = Integer(ARGV.fetch(2), 10) - 1
  File.binwrite(ARGV.fetch(1), JSON.generate(document))
' "${fixture_assets}/Linnet-Data-Channel.json" \
  "${fake_state}/data-channel/blobs/${race_base_blob}" "${catalog_sequence}"
require_public_fixture_rejection
publish_fixture catalog
[[ "$(cat "${fake_state}/data-channel/commit-count")" == 2 ]] ||
  fail "Catalog promotion did not fast-forward a stale stable pointer"
rg -Fq "api --method PATCH repos/Ares-X/Linnet/git/refs/heads/data-channel" \
  "${fake_state}/calls.log" ||
  fail "Catalog promotion did not use a non-destructive pointer fast-forward"
rg -Fq -- "-F force=false" "${fake_state}/calls.log" ||
  fail "Catalog pointer fast-forward regained forced replacement"
publish_fixture catalog
[[ "$(cat "${fake_state}/data-channel/commit-count")" == 2 ]] ||
  fail "an exact Catalog promotion created a duplicate stable pointer commit"

cp "${fake_state}/core-v${version}/assets" \
  "${publication_fixture}/exact-core-assets"
printf 'stale\tsha256:%064d\n' 0 >"${fake_state}/core-v${version}/assets"
require_public_fixture_rejection
mv "${publication_fixture}/exact-core-assets" \
  "${fake_state}/core-v${version}/assets"
cp "${fake_state}/data-${catalog_sequence}/assets" \
  "${publication_fixture}/exact-data-assets"
printf 'stale\tsha256:%064d\n' 0 >"${fake_state}/data-${catalog_sequence}/assets"
require_public_fixture_rejection
mv "${publication_fixture}/exact-data-assets" \
  "${fake_state}/data-${catalog_sequence}/assets"

pointer_ref_before_public="$(cat "${fake_state}/data-channel/ref")"
pointer_commits_before_public="$(cat "${fake_state}/data-channel/commit-count")"
mkdir -p "${fake_state}/tag-create-races"
wrong_public_tag_revision="$(printf 'd%.0s' {1..40})"
printf '%s\n' "${wrong_public_tag_revision}" \
  >"${fake_state}/tag-create-races/v${version}"
public_edits_before_race="$(grep -c "^release edit v${version} " \
  "${fake_state}/calls.log" || true)"
if run_fixture public >"${publication_fixture}/rejected-public-tag-race.log" 2>&1; then
  fail "tagless public publication accepted a concurrently created foreign tag"
fi
[[ -f "${fake_state}/v${version}/status" &&
  "$(cut -d' ' -f1 "${fake_state}/v${version}/status")" == true ]] ||
  fail "tagless public publication exposed a draft before rejecting its foreign tag"
[[ "$(grep -c "^release edit v${version} " \
  "${fake_state}/calls.log" || true)" == "${public_edits_before_race}" ]] ||
  fail "tagless public publication invoked draft=false before verifying its tag"
[[ "$(cat "${fake_state}/tags/v${version}")" == "${wrong_public_tag_revision}" ]] ||
  fail "the tag race fixture did not retain the competing tag owner"
rm -rf -- "${fake_state}/v${version}"
rm -f -- "${fake_state}/tags/v${version}"

publish_fixture public
[[ "$(cat "${fake_state}/v${version}/revision")" == "${candidate_revision}" &&
  "$(cat "${fake_state}/tags/v${version}")" == "${candidate_revision}" ]] ||
  fail "tagless public publication did not bind its draft and tag to exact main"
rg -Fq "release create v${version} ${fixture_assets}/Linnet.pkg" \
    "${fake_state}/calls.log" ||
  fail "tagless public publication did not create the verified Installer draft"
rg -Fq -- "--target ${candidate_revision}" "${fake_state}/calls.log" ||
  fail "tagless public publication did not create its tag from exact main"
rg -Fq '## 本版本更新' "${fake_state}/v${version}/notes" ||
  fail "the stable Release omitted the version change summary"
rg -Fq -- "${current_release_change}" "${fake_state}/v${version}/notes" ||
  fail "the stable Release did not consume the current CHANGELOG section"
if rg -Fq -- "${adjacent_release_heading}" \
    "${fake_state}/v${version}/notes"; then
  fail "the stable Release leaked an adjacent CHANGELOG version"
fi
printf 'stale release notes\n' >"${fake_state}/v${version}/notes"
public_creates_before_rerun="$(grep -c "^release create v${version} " \
  "${fake_state}/calls.log" || true)"
latest_edits_before="$(awk -v tag="v${version}" '
  $1 == "release" && $2 == "edit" && $3 == tag && $0 ~ / --latest( |$)/ {
    count += 1
  }
  END { print count + 0 }
' "${fake_state}/calls.log")"
publish_fixture public
latest_edits_after="$(awk -v tag="v${version}" '
  $1 == "release" && $2 == "edit" && $3 == tag && $0 ~ / --latest( |$)/ {
    count += 1
  }
  END { print count + 0 }
' "${fake_state}/calls.log")"
(( latest_edits_after == latest_edits_before + 1 )) ||
  fail "an exact published stable Release rerun did not retain Latest"
rg -Fq -- "${current_release_change}" "${fake_state}/v${version}/notes" ||
  fail "an exact published Release did not repair stale notes"
[[ "$(grep -c "^release create v${version} " \
  "${fake_state}/calls.log")" == "${public_creates_before_rerun}" ]] ||
  fail "an exact published stable Release was recreated"
[[ "$(cut -f1 "${fake_state}/v${version}/assets")" == Linnet.pkg ]] ||
  fail "the stable Release published more than the complete installer"
[[ "$(cat "${fake_state}/data-channel/ref")" == "${pointer_ref_before_public}" &&
  "$(cat "${fake_state}/data-channel/commit-count")" == "${pointer_commits_before_public}" ]] ||
  fail "the public Release changed the already-promoted Catalog pointer"

ruby -rjson -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  document["sequence"] = Integer(ARGV.fetch(2), 10) - 1
  File.binwrite(ARGV.fetch(1), JSON.generate(document))
' "${fixture_assets}/Linnet-Data-Channel.json" \
  "${fake_state}/data-channel/blobs/${catalog_blob}" "${catalog_sequence}"
race_ref="$(printf 'e%.0s' {1..40})"
printf '%s\n' "${race_ref}" >"${fake_state}/data-channel/inject-race"
if run_fixture catalog >"${publication_fixture}/rejected-race.log" 2>&1; then
  fail "Catalog promotion overwrote a concurrent stable pointer advance"
fi
[[ "$(cat "${fake_state}/data-channel/ref")" == "${race_ref}" ]] ||
  fail "Catalog promotion did not preserve the concurrent pointer owner"

if rg -n 'Developer ID|notari[sz]|stapler|Gatekeeper rejected' "${verifier}"; then
  fail "the community artifact owner still requires Apple publisher trust"
fi
rg -Fq 'Status: no signature' "${verifier}" ||
  fail "the public artifact owner does not require an unsigned Installer"
rg -Fq 'manual-user-approval' "${verifier}" ||
  fail "the public artifact owner lost the manual-trust contract"
rg -Fq 'community CMS App' "${verifier}" ||
  fail "the public artifact owner lost the stable App identity contract"

manual_trust_docs=(
  "${repo_root}/README.md"
  "${repo_root}/package/WELCOME.md"
  "${repo_root}/docs/release.md"
)
if rg -ni 'candidate.*UAT|候选.*UAT' "${repo_root}/package/WELCOME.md"; then
  fail "the public Installer Welcome still contains pre-release acceptance text"
fi
if rg -n 'xattr[[:space:]].*(-d|-c)|spctl[[:space:]].*--master-disable' \
    "${manual_trust_docs[@]}"; then
  fail "manual trust instructions disable or bypass a system security boundary"
fi

ruby -e '
  workflow = File.read(ARGV.fetch(0))
  commit = File.read(ARGV.fetch(1))
  pull_request = File.read(ARGV.fetch(2))
  cache = File.read(ARGV.fetch(3))
  publisher = File.read(ARGV.fetch(4))
  local_cache = "./.github/actions/restore-locked-build-cache"
  pinned_cache = "actions/cache@caa296126883cff596d87d8935842f9db880ef25"
  pinned_restore = "actions/cache/restore@caa296126883cff596d87d8935842f9db880ef25"
  workflow_uses = workflow.scan(/^\s*uses:\s*(\S+)/).flatten
  commit_uses = commit.scan(/^\s*uses:\s*(\S+)/).flatten
  pull_request_uses = pull_request.scan(/^\s*uses:\s*(\S+)/).flatten
  cache_uses = cache.scan(/^\s*uses:\s*(\S+)/).flatten
  all_uses = workflow_uses + commit_uses + pull_request_uses + cache_uses
  abort unless all_uses.all? { |value|
    value == local_cache || value.match?(/@[0-9a-f]{40}\z/)
  }
  abort unless workflow_uses.count(local_cache) == 1
  abort unless commit_uses.count(local_cache) == 1
  abort unless pull_request_uses.count(local_cache) == 1
  abort unless cache_uses == [pinned_cache, pinned_restore]
  abort if workflow.include?("actions/cache") || commit.include?("actions/cache") ||
    pull_request.include?("actions/cache")
  save_policy = "save: ${{ github.ref == \x27refs/heads/main\x27 }}"
  abort unless workflow.scan(/^\s*save:\s*true\s*$/).size == 1
  abort unless commit.scan(save_policy).size == 1
  abort unless pull_request.scan(/^\s*save:\s*false\s*$/).size == 1
  abort unless cache.include?("if: inputs.save == \x27true\x27") &&
    cache.include?("if: inputs.save == \x27false\x27")
  abort unless cache.match?(/inputs:\s*\n\s*save:.*?required:\s*true/m)
  abort unless workflow.scan(/^\s*submodules:\s*false\s*$/).size == 3
  abort unless commit.scan(/^\s*submodules:\s*false\s*$/).size == 1
  abort unless pull_request.scan(/^\s*submodules:\s*false\s*$/).size == 1
  abort unless workflow.scan(/^\s*group:\s*linnet-release-publication\s*$/).size == 1
  abort unless cache.scan(/^\s*key:\s*linnet-build-v2-/).size == 2
  abort unless cache.scan(/^\s*restore-keys:\s*\|/).size == 2
  %w[
    build/upstreams
    build/dependencies
    data/chinese/grammar
    build/linnet-english-cache
  ].each { |path| abort unless cache.scan(/^\s*#{Regexp.escape(path)}\s*$/).size == 2 }
  %w[data/plum/build build/precompiled.fingerprint].each do |path|
    abort if cache.match?(/^\s*#{Regexp.escape(path)}\s*$/)
  end
  abort if cache.include?("sources/**") || cache.include?("tools/**") ||
    cache.include?("config/linnet-data-releases.json")
  abort if cache.match?(%r{^\s*(?:librime|plum|upstreams/[^/]+)\s*$})
  abort unless cache.include?("Restored bytes are acceleration only")
  abort unless workflow.scan(/^\s*run:\s*\.\/action-install\.sh\s*$/).size == 1
  abort unless workflow.scan(/^\s*make --no-print-directory archive\s*$/).size == 1
  abort if workflow.include?("./action-build.sh archive")
  abort unless workflow.include?("package/verify_publication_artifacts")
  abort unless workflow.include?("package/publish_github_release")
  abort if workflow.include?(%q{"${ARCHIVE_OUTPUT_DIR}"/*})
  release_positions = %w[core data catalog public].map do |channel|
    needle = "package/publish_github_release #{channel}"
    abort unless workflow.scan(needle).size == 1
    workflow.index(needle)
  end
  abort unless release_positions.each_cons(2).all? { |left, right| left < right }
  catalog_gate = <<~'BASH'
    if [[ "${channel}" == catalog ]]; then
      ensure_catalog_pointer true
  BASH
  public_gate = <<~'BASH'
    if [[ "${channel}" == public ]]; then
      ensure_catalog_pointer false
  BASH
  pointer_calls = publisher.scan(/^\s+ensure_catalog_pointer\s+\S+\s*$/).map(&:strip)
  abort unless publisher.scan(/^ensure_catalog_pointer\(\) \{$/).size == 1
  abort unless pointer_calls == ["ensure_catalog_pointer true", "ensure_catalog_pointer false"]
  abort unless publisher.scan(catalog_gate).size == 1
  abort unless publisher.scan(public_gate).size == 1
  abort unless workflow.include?(%q{GH_TOKEN: ${{ github.token }}})
  abort unless workflow.match?(/build-candidate:\s*\n\s*if:\s*github\.event_name == ["\x27]workflow_dispatch["\x27] && github\.ref == ["\x27]refs\/heads\/main["\x27]/)
  abort unless workflow.include?("environment: community-signing")
  abort unless workflow.scan(/^    environment: community-publication$/).size == 1
  abort if workflow.match?(/^\s*push:\s*$/)
  abort unless workflow.match?(/^permissions:\s*\n\s*contents:\s*read\s*$/m)
  abort unless workflow.match?(/stage-update-channels:.*?contents:\s*write/m)
  abort unless workflow.match?(/publish-stable:.*?contents:\s*write/m)
  abort unless workflow.scan(/^\s*run:\s*scripts\/install_ci_build_tools\.sh release\s*$/).size == 1
  abort unless commit.scan(/^\s*run:\s*scripts\/install_ci_build_tools\.sh quality\s*$/).size == 1
  abort unless pull_request.scan(/^\s*run:\s*scripts\/install_ci_build_tools\.sh quality\s*$/).size == 1
  %w[
    LINNET_COMMUNITY_CMS_P12_BASE64
    LINNET_COMMUNITY_CMS_P12_PASSWORD
    LINNET_CODE_SIGN_KEYCHAIN
    LINNET_CODE_SIGN_PASSWORD_FILE
    security\ set-key-partition-list
    security\ delete-keychain
  ].each { |marker| abort unless workflow.include?(marker.gsub("\\ ", " ")) }
  abort if workflow.include?("LINNET_CODE_SIGN_PROFILE")
  abort unless workflow.include?("if: always()") &&
    workflow.include?(%q{rm -rf -- "${signing_root}"})
  abort if workflow.match?(/security\s+import.*(?:^|\s)-A(?:\s|$)/) ||
    workflow.match?(/notary|Developer ID|publication_plan|community-adhoc/)
' "${workflow}" "${commit_workflow}" "${pull_request_workflow}" "${cache_action}" \
    "${publisher}" ||
  fail "immutable-candidate community workflow is incomplete"

echo "Linnet unsigned PKG / stable CMS App publication owner: PASS"
