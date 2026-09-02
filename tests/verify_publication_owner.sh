#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
verifier="${repo_root}/package/verify_publication_artifacts"
asset_manifest="${repo_root}/package/release_asset_manifest"
publisher="${repo_root}/package/publish_github_release"
stager="${repo_root}/package/stage_github_release"
candidate_identity_owner="${repo_root}/package/release_candidate_identity"
commit_workflow="${repo_root}/.github/workflows/commit-ci.yml"
pull_request_workflow="${repo_root}/.github/workflows/pull-request-ci.yml"
release_workflow="${repo_root}/.github/workflows/release-ci.yml"
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

for owner in "${verifier}" "${asset_manifest}" "${candidate_identity_owner}" "${stager}" "${publisher}"; do
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
if rg -ni 'approval commit|publication=go|installation_uat=passed|machine-bound|community-publication|Environment approval|stage-update-channels|publish-stable' \
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
periphery = File.read(File.join(root, "scripts/run_periphery.sh"))
analysis_identity =
  'readonly analysis_bundle_identifier="${product_bundle_identifier}.periphery"'
build_identity = 'LINNET_BUNDLE_IDENTIFIER="${analysis_bundle_identifier}"'
analysis_name = 'readonly analysis_product_name="${product_name}Periphery"'
build_name = 'LINNET_PRODUCT_NAME="${analysis_product_name}"'
input_source_safe_build = 'scripts/build-linnet-app Debug "${derived_data}"'
abort unless periphery.include?(
  'product_bundle_identifier="$(read_product_setting LINNET_BUNDLE_IDENTIFIER)"') &&
  periphery.include?('product_name="$(read_product_setting LINNET_PRODUCT_NAME)"') &&
  periphery.include?(analysis_identity) &&
  periphery.include?(analysis_name) &&
  periphery.scan(build_identity).size == 1 &&
  periphery.scan(build_name).size == 1 &&
  periphery.scan(input_source_safe_build).size == 1 &&
  !periphery.include?("lsregister") &&
  !periphery.include?("unregister-local-apps") &&
  periphery.include?(%q{--generic-project-config "${generic_config}"}) &&
  periphery.include?(%q{"test_targets": []}) &&
  periphery.include?(%q{SWIFTC="${indexed_swiftc}" linnet-runtime-inspector}) &&
  periphery.include?(%q{SWIFTC="${indexed_swiftc}" linnet-pack-tool}) &&
  periphery.include?(%q{SWIFTC="${indexed_swiftc}" input-source-registration-inspector}) &&
  periphery.include?(%q{SWIFTC="${indexed_swiftc}" english-data-generator}) &&
  !periphery.include?("com.github.peripheryapp") &&
  !periphery.include?("WorkspacePath") &&
  periphery.index(analysis_identity) < periphery.index(build_identity) &&
  periphery.index(analysis_name) < periphery.index(build_name) &&
  !periphery.include?(bundle_identifier)
historical_signing_text, historical_signing_status = Open3.capture2(
  "git", "-C", root, "show", "#{source_revision}:config/linnet-community-signing.json")
abort unless historical_signing_status.success?
historical_signing = JSON.parse(historical_signing_text)
abort unless historical_signing.fetch("certificate_sha256") ==
  target.fetch("certificate_sha256")

contract = acceptance.fetch("contract")
abort unless contract.keys.sort == %w[algorithm paths sha256]
abort unless contract.fetch("algorithm") == "sha256-legacy-migration-projection-v1"
expected_paths = %w[
  package/installer-scripts/candidate-app-identity.sh
]
paths = contract.fetch("paths")
abort unless paths == expected_paths && paths == paths.sort && paths.uniq == paths

# The accepted legacy migration ends below build 29. A fixed-CMS candidate may
# replace an unaccepted candidate with the same product build, so that
# fixed-CMS-only conflict branch is deliberately outside the historical
# migration fingerprint. Every byte that can govern the admitted ad-hoc edge
# remains identical to the accepted source revision.
fixed_cms_candidate_conflict = <<~'BASH'
  if (( version_comparison == 0 )) && [[ "${actual_build}" == "${expected_build}" &&
    "${embedded_revision}" != "${expected_revision}" ]]; then
    fail_identity "installed App revision conflicts with this Core candidate"
  fi
BASH
clean_complete_transition = "    printf '%s\\n' clean-complete-install\n"
historical_missing_transition = "    printf '%s\\n' missing-app-install\n"
staged_identity_dispatch = <<~'BASH'
  [[ "$#" -ge 1 ]] || fail_identity "usage: existing | installed | staged APP"
  readonly verification_mode="$1"
  case "${verification_mode}" in
    existing|installed)
      [[ "$#" -eq 1 ]] || fail_identity "unexpected App path"
      readonly app_path="${user_home}/Library/Input Methods/Linnet.app"
      ;;
    staged)
      [[ "$#" -eq 2 && ( "$2" == \
        "${user_home}/Library/Input Methods/.linnet-core."??????"/Linnet.app" || \
        "$2" == "${user_home}/Library/Application Support/Linnet/.linnet-complete/App/Linnet.payload" ) ]] ||
        fail_identity "staged App is outside the package transaction"
      readonly app_path="$2"
      secure_owned_path "${app_path%/*}" directory &&
        [[ "$(cd "${app_path%/*}" && pwd -P)" == "${app_path%/*}" ]] ||
        fail_identity "staged App parent is unsafe"
      ;;
    *) fail_identity "verification mode is invalid" ;;
  esac
BASH
historical_identity_dispatch = <<~'BASH'
  [[ "$#" -eq 1 ]] || fail_identity "usage: existing | installed"
  readonly verification_mode="$1"
  case "${verification_mode}" in
    existing|installed) ;;
    *) fail_identity "verification mode is invalid" ;;
  esac
BASH
current_uid_binding = "readonly current_uid=\"$(/usr/bin/id -u)\"\n"
historical_app_binding = "readonly app_path=\"${user_home}/Library/Input Methods/Linnet.app\"\n"
staged_exact_candidate_gate = "if [[ \"${verification_mode}\" != existing ]]; then"
historical_installed_candidate_gate = "if [[ \"${verification_mode}\" == installed ]]; then"
release_tool_binding = 'readonly release_tool="${script_root}/linnet-pack"' + "\n"
target_identity_reads = <<~'BASH'
  expected_leaf_sha1="$(read_value "${metadata_path}" leaf_certificate_sha1)" ||
    fail_identity "candidate signing leaf requirement is unavailable"
  expected_tree="$(read_value "${metadata_path}" app_tree_sha256)" ||
    fail_identity "candidate App tree identity is unavailable"
BASH
current_target_shape = <<'BASH'
  "${expected_revision}" =~ ^[0-9a-f]{40}$ &&
  "${expected_leaf}" =~ ^[0-9a-f]{64}$ &&
  "${expected_leaf_sha1}" =~ ^[0-9A-F]{40}$ &&
  "${expected_tree}" =~ ^[0-9a-f]{64}$ ]] ||
BASH
historical_target_shape = <<'BASH'
  "${expected_revision}" =~ ^[0-9a-f]{40}$ &&
  "${expected_leaf}" =~ ^[0-9a-f]{64}$ ]] ||
BASH
current_cms_validation = <<~'BASH'
  community-cms)
    [[ "${actual_profile}" == community-cms &&
      "${embedded_kind}" == external-cms ]] ||
      fail_identity "installed App is not a community CMS release"
    # Publication verifies the complete CMS chain before packaging. Installation
    # must not require the maintainer certificate in the user's trust store; it
    # binds the packaged bytes to the same fixed leaf through the designated
    # requirement, then verifies the exact target tree below.
    expected_requirement="designated => identifier \"${host_bundle_id}\" and certificate leaf = H\"$(
      /usr/bin/tr '[:upper:]' '[:lower:]' <<<"${expected_leaf_sha1}")\""
    actual_requirement="$(/usr/bin/codesign -d -r- "${app_path}" 2>&1 |
      /usr/bin/grep '^designated => ')" ||
      fail_identity "installed App signing requirement is unavailable"
    [[ "${actual_requirement}" == "${expected_requirement}" ]] ||
      fail_identity "installed App signing requirement does not match"
    embedded_leaf="$(read_value "${version_path}" \
      distribution.application_code_signature.leaf_certificate_sha256)" ||
      fail_identity "installed release signing leaf is unavailable"
    embedded_same_leaf="$(read_value "${version_path}" \
      distribution.application_code_signature.host_settings_same_leaf)" ||
      fail_identity "installed release signing policy is unavailable"
    [[ "${embedded_leaf}" == "${expected_leaf}" &&
      "${embedded_same_leaf}" == true ]] ||
      fail_identity "installed release signing leaf does not match"
    identity_transition=same-community-cms-leaf
    ;;
BASH
historical_cms_validation = <<~'BASH'
  community-cms)
    [[ "${actual_profile}" == community-cms &&
      "${embedded_kind}" == external-cms ]] ||
      fail_identity "installed App is not a community CMS release"
    scratch_root="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" ||
      fail_identity "temporary root is unavailable"
    scratch="$(/usr/bin/mktemp -d "${scratch_root}/linnet-candidate-app-identity.XXXXXX")" ||
      fail_identity "temporary identity directory cannot be created"
    cleanup_identity() {
      if [[ "${scratch%/*}" == "${scratch_root}" &&
        "${scratch##*/}" == linnet-candidate-app-identity.* &&
        -d "${scratch}" && ! -L "${scratch}" ]]; then
        /bin/rm -rf -- "${scratch}"
      fi
    }
    trap cleanup_identity EXIT INT TERM HUP
    certificate_prefix="${scratch}/leaf"
    /usr/bin/codesign -d --extract-certificates="${certificate_prefix}" \
      "${app_path}" >/dev/null 2>&1 ||
      fail_identity "installed App signing certificate is unavailable"
    [[ -s "${certificate_prefix}0" && ! -L "${certificate_prefix}0" ]] ||
      fail_identity "installed App signing certificate is missing"
    actual_leaf="$(/usr/bin/shasum -a 256 "${certificate_prefix}0" | \
      /usr/bin/awk '{print $1}')" ||
      fail_identity "installed App signing leaf cannot be read"
    embedded_leaf="$(read_value "${version_path}" \
      distribution.application_code_signature.leaf_certificate_sha256)" ||
      fail_identity "installed release signing leaf is unavailable"
    embedded_same_leaf="$(read_value "${version_path}" \
      distribution.application_code_signature.host_settings_same_leaf)" ||
      fail_identity "installed release signing policy is unavailable"
    [[ "${actual_leaf}" == "${expected_leaf}" &&
      "${embedded_leaf}" == "${actual_leaf}" &&
      "${embedded_same_leaf}" == true ]] ||
      fail_identity "installed release signing leaf does not match"
    identity_transition=same-community-cms-leaf
    ;;
BASH
current_legacy_integrity = <<'BASH'
  # This one-time legacy edge has no certificate trust chain. Verify its ad-hoc
  # code integrity without imposing that check on current community CMS users.
  /usr/bin/codesign --verify --deep --strict "${app_path}" >/dev/null 2>&1 ||
    fail_identity "legacy App code signature is invalid"
BASH
historical_common_integrity = <<~'BASH'
  /usr/bin/codesign --verify --deep --strict "${app_path}" >/dev/null 2>&1 ||
    fail_identity "installed App code signature is invalid"

BASH
identity_file_gate = <<~'BASH'
  secure_owned_path "${info_path}" file && secure_owned_path "${version_path}" file ||
    fail_identity "installed App identity files are unsafe"

BASH
target_tree_validation = <<'BASH'
  secure_owned_path "${release_tool}" file && [[ -x "${release_tool}" ]] ||
    fail_identity "candidate tree verifier is unavailable or unsafe"
  actual_tree="$("${release_tool}" tree-digest --root "${app_path}")" ||
    fail_identity "candidate App tree cannot be verified"
  [[ "${actual_tree}" == "${expected_tree}" ]] ||
    fail_identity "candidate App tree differs from the packaged target"
BASH
legacy_projection = lambda do |content|
  if content.include?(release_tool_binding)
    abort unless content.scan(release_tool_binding).size == 1 &&
      content.scan(target_identity_reads).size == 1 &&
      content.scan(current_target_shape).size == 1 &&
      content.scan(current_cms_validation).size == 1 &&
      content.scan(current_legacy_integrity).size == 1 &&
      content.scan(historical_common_integrity).empty? &&
      content.scan(identity_file_gate).size == 1 &&
      content.scan(target_tree_validation).size == 1 &&
      content.scan('"${expected_format}" == 4').size == 1
    content = content.sub(release_tool_binding, "")
      .sub(target_identity_reads, "")
      .sub('"${expected_format}" == 4', '"${expected_format}" == 3')
      .sub(current_target_shape, historical_target_shape)
      .sub(current_cms_validation, historical_cms_validation)
      .sub(current_legacy_integrity, "")
      .sub(identity_file_gate, identity_file_gate + historical_common_integrity)
      .sub(target_tree_validation, "")
  end
  if content.include?(staged_identity_dispatch)
    abort unless content.scan(staged_identity_dispatch).size == 1 &&
      content.scan(historical_identity_dispatch).empty? &&
      content.scan(current_uid_binding).size == 1 &&
      content.scan(historical_app_binding).size == 1 &&
      content.scan(staged_exact_candidate_gate).size == 1 &&
      content.scan(historical_installed_candidate_gate).empty?
    content = content.sub(current_uid_binding, historical_app_binding + current_uid_binding)
      .sub(staged_identity_dispatch, historical_identity_dispatch)
      .sub(staged_exact_candidate_gate, historical_installed_candidate_gate)
  end
  occurrences = content.scan(fixed_cms_candidate_conflict).size
  abort unless occurrences <= 1
  content.sub(fixed_cms_candidate_conflict, "")
    .sub(clean_complete_transition, historical_missing_transition)
end
current_identity = File.binread(File.join(root, paths.fetch(0)))
historical_identity, historical_identity_status = Open3.capture2(
  "git", "-C", root, "show", "#{source_revision}:#{paths.fetch(0)}")
abort unless historical_identity_status.success? &&
  historical_identity.scan(fixed_cms_candidate_conflict).size == 1 &&
  current_identity.scan(fixed_cms_candidate_conflict).empty? &&
  historical_identity.scan(clean_complete_transition).empty? &&
  current_identity.scan(clean_complete_transition).size == 1 &&
  historical_identity.scan(staged_identity_dispatch).empty? &&
  current_identity.scan(staged_identity_dispatch).size == 1
legacy_max_build = current_identity[/^readonly legacy_max_build='(\d+)'$/, 1]
historical_legacy_max_build = historical_identity[/^readonly legacy_max_build='(\d+)'$/, 1]
current_build = product[/^CURRENT_PROJECT_VERSION = (\d+)$/, 1]
abort unless legacy_max_build && legacy_max_build == historical_legacy_max_build &&
  artifact.fetch("build").to_i > legacy_max_build.to_i &&
  current_build && current_build.to_i > legacy_max_build.to_i
entries = paths.map do |path|
  absolute = File.join(root, path)
  abort unless File.file?(absolute) && !File.symlink?(absolute)
  index, status = Open3.capture2("git", "-C", root, "ls-files", "-s", "--", path)
  abort unless status.success?
  match = index.match(/\A(\d{6}) [0-9a-f]{40,64} 0\t/)
  abort unless match
  projected = legacy_projection.call(File.binread(absolute))
  "#{match[1]}\t#{Digest::SHA256.hexdigest(projected)}\t#{path}\n"
end
historical_entries = paths.map do |path|
  tree, tree_status = Open3.capture2(
    "git", "-C", root, "ls-tree", source_revision, "--", path)
  match = tree.match(/\A(\d{6}) blob [0-9a-f]{40,64}\t/)
  content, content_status = Open3.capture2(
    "git", "-C", root, "show", "#{source_revision}:#{path}")
  abort unless tree_status.success? && content_status.success? && match
  projected = legacy_projection.call(content)
  "#{match[1]}\t#{Digest::SHA256.hexdigest(projected)}\t#{path}\n"
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
    text.include?("旧迁移投影指纹") && text.include?("两轮同 leaf Core")
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

printf '%s\n' config/LinnetProduct.xcconfig data/linnet/lua/auto_phrase.lua |
  "${repo_root}/package/data_release_metadata" check-source-change >/dev/null
if printf '%s\n' data/linnet/default.yaml |
    "${repo_root}/package/data_release_metadata" check-source-change \
      >/dev/null 2>&1; then
  fail "a pack source change can still reuse unchanged pack metadata"
fi

version="$(sed -n 's/^MARKETING_VERSION = \([^[:space:]]*\)$/\1/p' \
  "${repo_root}/config/LinnetProduct.xcconfig")"
if ! ruby - "${repo_root}/README.md" "${version}" <<'RUBY'
readme, version = ARGV
# Upgrade instructions may name an older baseline; only the current-branch
# projection owns the version that must agree with the product config.
versions = File.read(readme).scan(/本分支版本为 \*\*(\d+\.\d+\.\d+)\*\*/).flatten
abort unless versions == [version]
RUBY
then
  fail "README current-branch version must match the Core version exactly once"
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
public_expected=Linnet.pkg
core_expected="$(printf '%s\n' \
  "Linnet-${version}-arm64-Core-community-beta.pkg" \
  Linnet-Data-Channel.json | LC_ALL=C sort)"
delta_expected="$(ruby -rjson -e '
  baseline = JSON.parse(File.read(ARGV.fetch(0))).fetch("pack_baselines")
  packs = JSON.parse(File.read(ARGV.fetch(1))).fetch("packs")
  %w[chinese english lts extended].each do |kind|
    entry = baseline.fetch(kind)
    next if entry.fetch("content_sha256") == packs.fetch(kind).fetch("content_sha256")
    name = kind == "lts" ? "LTS" : kind.capitalize
    puts "Linnet-#{name}-from-#{entry.fetch("content_sha256")}.linnetdelta"
  end
' "${repo_root}/config/linnet-update-baselines.json" "${repo_root}/config/linnet-data-releases.json")"
data_expected="$(printf '%s\n' \
  Linnet-Chinese.linnetpack Linnet-English.linnetpack \
  Linnet-LTS.linnetpack Linnet-Extended.linnetpack "${delta_expected}" | sed '/^$/d' | LC_ALL=C sort)"
candidate_expected="$(printf '%s\n' "${public_expected}" "${core_expected}" "${data_expected}" | LC_ALL=C sort)"
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
"${repo_root}/tests/verify_action_publication.sh"
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
  commit = File.read(ARGV.fetch(0))
  pull_request = File.read(ARGV.fetch(1))
  release = File.read(ARGV.fetch(2))
  cache = File.read(ARGV.fetch(3))
  runtime_builder = File.read(ARGV.fetch(4))
  development_gate = File.read(ARGV.fetch(5))
  product_gate = File.read(ARGV.fetch(6))
  swift_gate = File.read(ARGV.fetch(7))
  swift_cache = File.read(ARGV.fetch(8))
  local_cache = "./.github/actions/restore-locked-build-cache"
  pinned_cache = "actions/cache@caa296126883cff596d87d8935842f9db880ef25"
  pinned_restore = "actions/cache/restore@caa296126883cff596d87d8935842f9db880ef25"
  commit_uses = commit.scan(/^\s*uses:\s*(\S+)/).flatten
  pull_request_uses = pull_request.scan(/^\s*uses:\s*(\S+)/).flatten
  release_uses = release.scan(/^\s*uses:\s*(\S+)/).flatten
  cache_uses = cache.scan(/^\s*uses:\s*(\S+)/).flatten
  all_uses = commit_uses + pull_request_uses + release_uses + cache_uses
  abort unless all_uses.all? { |value|
    value == local_cache || value.match?(/@[0-9a-f]{40}\z/)
  }
  abort unless commit_uses.count(local_cache) == 1
  abort unless pull_request_uses.count(local_cache) == 1
  abort unless release_uses.count(local_cache) == 1
  abort unless commit_uses.count(pinned_cache) == 1
  abort unless pull_request_uses.count(pinned_restore) == 1
  abort unless release_uses.count(pinned_cache) == 0
  abort unless cache_uses == [pinned_cache, pinned_restore, pinned_cache, pinned_restore]
  abort unless commit.scan(/^\s*save:\s*true\s*$/).size == 1
  abort unless pull_request.scan(/^\s*save:\s*false\s*$/).size == 1
  abort unless release.scan(/^\s*save:\s*false\s*$/).size == 1
  abort unless cache.include?("if: inputs.save == \x27true\x27") &&
    cache.include?("if: inputs.save == \x27false\x27")
  abort unless cache.match?(/inputs:\s*\n\s*save:.*?required:\s*true/m)
  abort unless commit.scan(/^\s*submodules:\s*false\s*$/).size == 1
  abort unless pull_request.scan(/^\s*submodules:\s*false\s*$/).size == 1
  abort unless release.scan(/^\s*submodules:\s*false\s*$/).size == 2
  abort unless commit.match?(/^name:\s*Linnet manual full CI\s*$/)
  abort unless commit.match?(/^on:\s*\n\s*workflow_dispatch:\s*$/m)
  abort if commit.match?(/^\s*push:\s*$/) || commit.include?("github.event.before")
  abort unless pull_request.match?(/^on:\s*\[pull_request\]\s*$/)
  abort unless commit.include?(%q{group: linnet-manual-${{ github.ref }}}) &&
    pull_request.include?(%q{group: linnet-pr-${{ github.event.pull_request.number }}})
  abort unless commit.scan(/^\s*cancel-in-progress:\s*true\s*$/).size == 1 &&
    pull_request.scan(/^\s*cancel-in-progress:\s*true\s*$/).size == 1
  ordered = lambda do |source, *markers|
    offsets = markers.map { |marker| source.index(marker) }
    abort unless offsets.all? && offsets.each_cons(2).all? { |left, right| left < right }
  end
  [commit, pull_request].each do |ci|
    abort if ci.match?(/^\s*(?:needs|strategy|matrix):/)
    abort unless ci.scan(/^\s{2}product:\s*$/).size == 1
    abort unless ci.scan(/^\s*runs-on:\s*macos-latest\s*$/).size == 1
    abort unless ci.scan(%r{tests/verify_release_automation\.sh && tests/verify_publication_owner\.sh}).size == 1
    abort if ci.include?("./action-build.sh")
    abort unless ci.scan(/^\s*run:\s*\.\/action-install\.sh\s*$/).size == 1
    abort unless ci.scan(/^\s*run:\s*make --no-print-directory release\s*$/).size == 1
    abort unless ci.scan(%r{tests/verify_development\.sh app}).size == 1
    abort unless ci.scan(%r{tests/verify_development\.sh swift}).size == 1
    abort unless ci.scan(%r{tests/verify_development\.sh rime}).size == 1
    abort unless ci.scan(%r{^\s*run:\s*tests/verify_visible_settings_fixture\.sh --ui-test\s*$}).size == 1
    abort unless ci.scan(%r{scripts/run_periphery\.sh}).size == 1
    abort unless ci.scan(/^\s*path:\s*build\/swift-unit-cache\s*$/).size == 1
    abort unless ci.scan(/linnet-swift-units-v1-/).size == 2
    ordered.call(ci,
      "./action-install.sh",
      "make --no-print-directory release",
      "tests/verify_development.sh app",
      "tests/verify_visible_settings_fixture.sh --ui-test",
      "tests/verify_development.sh swift",
      "tests/verify_development.sh rime",
      "scripts/run_periphery.sh")
  end
  abort if release.include?("workflow_dispatch") ||
    release.include?("workflow_run") || release.match?(/\bgh run\b/)
  abort unless release.scan(/^\s{2}build-candidate:\s*$/).size == 1
  abort unless release.scan(/^\s{2}publish:\s*$/).size == 1
  abort unless release.scan(/^\s*runs-on:\s*macos-latest\s*$/).size == 1
  abort unless release.scan(/^\s*runs-on:\s*ubuntu-latest\s*$/).size == 1
  abort unless release.scan(/^\s*run:\s*\.\/action-install\.sh\s*$/).size == 1
  abort unless release.scan(%r{scripts/run_swiftlint\.sh}).size == 1
  abort unless release.scan(%r{tests/verify_release_automation\.sh}).size == 1
  abort unless release.scan(%r{tests/verify_publication_owner\.sh}).size == 1
  abort unless release.scan(%r{tests/verify_development\.sh swift}).empty?
  abort unless release.scan(%r{tests/verify_development\.sh rime}).size == 1
  abort unless release.scan(%r{scripts/run_periphery\.sh}).empty?
  abort unless release.scan(%r{scripts/release-control verify-source}).size == 1
  abort unless release.include?("steps.request.outputs.settings_ui == \x27NOT_EXERCISED\x27")
  abort if release.include?("build/swift-unit-cache")
  abort unless release.scan(/^\s*make --no-print-directory archive\s*$/).size == 1
  ordered.call(release,
    "scripts/release-control verify-source",
    "./action-install.sh",
    "scripts/run_swiftlint.sh",
    "tests/verify_publication_owner.sh",
    "tests/verify_development.sh rime",
    "make --no-print-directory archive")
  abort unless development_gate.include?("[all|app|swift|rime]")
  abort unless development_gate.scan(/^if \[\[ "\$\{run_app\}" -eq 1 \]\]; then$/).size == 1
  abort unless development_gate.scan(/^if \[\[ "\$\{run_swift\}" -eq 1 \]\]; then$/).size == 1
  abort unless development_gate.scan(/^if \[\[ "\$\{run_rime\}" -eq 1 \]\]; then$/).size == 1
  abort unless development_gate.scan(/^\s*all\) run_app=1; run_swift=1; run_rime=1 ;;$/).size == 1
  app_start = development_gate.index(%q{if [[ "${run_app}" -eq 1 ]]; then})
  swift_start = development_gate.index(%q{if [[ "${run_swift}" -eq 1 ]]; then})
  rime_start = development_gate.index(%q{if [[ "${run_rime}" -eq 1 ]]; then})
  abort unless app_start && swift_start && rime_start &&
    app_start < swift_start && swift_start < rime_start
  profile_blocks = {
    app: development_gate[app_start...swift_start],
    swift: development_gate[swift_start...rime_start],
    rime: development_gate[rime_start..]
  }
  required_profile_commands = {
    app: {
      "tests/verify_runtime_footprint.sh" => 1,
      "LINNET_LIFECYCLE_CANDIDATE_APP=" => 1,
      "tests/verify_package_lifecycle.sh" => 1,
      "tests/verify_visible_settings_fixture.sh --verify local" => 1,
      "tests/verify_release_metadata.sh" => 1,
      "tests/verify_package_architecture.sh" => 1,
      "english-data-generator" => 1,
      "tests/verify_english_data_projection.sh" => 1,
      "ruby tests/generate_m2_fixtures.rb --check" => 1,
      "tests/verify_input_process_offline.sh" => 1,
      "scripts/build-privacy scan" => 1
    },
    swift: { "tests/verify_swift_units.sh" => 1 },
    rime: {
      "tests/verify_lua_lifetime.sh" => 1,
      "tests/verify_data_release_baseline.sh" => 1,
      "tests/verify_chinese_upstream_workflow.sh" => 1,
      "ruby scripts/upstream-sync verify" => 1,
      "tests/verify_chinese_source_projection.sh" => 1,
      "tests/verify_locked_release_asset.sh" => 1,
      "tests/verify_chinese_grammar.sh" => 1,
      "ruby tests/verify_profile_golden.rb" => 1,
      "tests/verify_chinese_learning_policy.sh" => 1,
      "tests/verify_rime_runtime.sh" => 1
    }
  }
  required_profile_commands.each do |profile, markers|
    markers.each do |marker, count|
      abort unless profile_blocks.fetch(profile).scan(marker).size == count
    end
  end
  required_profile_commands.each_value do |markers|
    markers.each do |marker, count|
      abort unless development_gate.scan(marker).size == count
    end
  end
  retired_candidate_source_gates = [
    "tests/verify_runtime_footprint.sh",
    "tests/verify_lua_lifetime.sh",
    "tests/verify_release_metadata.sh",
    "tests/verify_data_release_baseline.sh",
    "tests/verify_chinese_upstream_workflow.sh",
    "ruby scripts/upstream-sync verify",
    "tests/verify_chinese_source_projection.sh",
    "tests/verify_locked_release_asset.sh",
    "tests/verify_english_data_projection.sh",
    "ruby tests/generate_m2_fixtures.rb --check",
    "tests/verify_swift_units.sh",
    "tests/verify_package_architecture.sh",
    "tests/verify_release_automation.sh",
    "tests/verify_publication_owner.sh",
    "tests/verify_chinese_grammar.sh",
    "ruby tests/verify_profile_golden.rb",
    "tests/verify_chinese_learning_policy.sh",
    "tests/verify_rime_runtime.sh"
  ]
  abort if retired_candidate_source_gates.any? { |gate| product_gate.include?(gate) }
  abort unless product_gate.scan(%r{tests/verify_visible_settings_fixture\.sh --verify}).size == 1
  abort if product_gate.include?("--ui-test")
  abort unless product_gate.scan(/LINNET_LIFECYCLE_CANDIDATE_APP=/).size == 1
  abort unless product_gate.scan(%r{tests/verify_input_process_offline\.sh}).size == 1
  abort unless product_gate.scan(%r{scripts/build-privacy scan}).size == 1
  abort unless cache.scan(/^\s*key:\s*linnet-build-v2-/).size == 2
  abort unless cache.scan(/^\s*key:\s*linnet-rime-runtime-v2-/).size == 2
  abort unless cache.scan(/^\s*restore-keys:\s*\|/).size == 4
  %w[
    build/upstreams
    build/dependencies
    data/chinese/grammar
    build/linnet-english-cache
  ].each { |path| abort unless cache.scan(/^\s*#{Regexp.escape(path)}\s*$/).size == 2 }
  abort unless cache.scan(/^\s*path:\s*build\/rime-runtime-cache\s*$/).size == 2
  %w[data/plum/build build/precompiled.fingerprint].each do |path|
    abort if cache.match?(/^\s*#{Regexp.escape(path)}\s*$/)
  end
  abort if cache.include?("sources/**") || cache.include?("tools/**") ||
    cache.include?("config/linnet-data-releases.json")
  abort if cache.match?(%r{^\s*(?:librime|plum|upstreams/[^/]+)\s*$})
  abort unless cache.include?("Restored bytes are acceleration only")
  cache_contract = %w[
    linnet-rime-runtime-cache-v2
    runtime_tree_inventory
    runtime_cache_is_valid
    restore_runtime_cache
    refresh_runtime_cache
    inventory.sha256
    boost.inventory.sha256
    Digest::SHA256.file
    File.readlink
    /usr/bin/lockf
    runtime_paths_share_device
  ]
  abort unless cache_contract.all? { |marker| runtime_builder.include?(marker) }
  restore_guard = <<~BASH
    if [[ ! -e "${dist_target}" && ! -L "${dist_target}" &&
          ! -e "${opencc_target}" && ! -L "${opencc_target}" &&
          -d "${boost_target}/boost" ]] &&
        runtime_cache_is_valid "${runtime_cache_target}" &&
        restore_runtime_cache; then
  BASH
  abort unless runtime_builder.scan(restore_guard).size == 1
  abort unless runtime_builder.index(%q{run "${upstream_sync}" verify}) <
    runtime_builder.index(restore_guard)
  refresh = %q{refresh_runtime_cache || fail "verified runtime cache refresh failed"}
  stamp = %q{mv "${runtime_fingerprint_stamp}.tmp" "${runtime_fingerprint_stamp}"}
  abort unless runtime_builder.scan(/^#{Regexp.escape(refresh)}$/).size == 1
  abort unless runtime_builder.scan(/^\s*#{Regexp.escape(stamp)}$/).size == 2
  abort unless runtime_builder.index(refresh) < runtime_builder.rindex(stamp)
  abort if runtime_builder.include?("/private/tmp/linnet-rime-cache")
  abort unless runtime_builder.include?(%q{build/.rime-runtime-restore.XXXXXX}) &&
    runtime_builder.include?(%q{build/.rime-runtime-publish.XXXXXX})
  final_cache_check = %q{runtime_cache_is_valid "${runtime_cache_target}"}
  abort unless runtime_builder.rindex(final_cache_check) < runtime_builder.rindex(stamp)
  manual_tools = "run: scripts/install_ci_build_tools.sh ${{ inputs.profile == \x27full\x27 && \x27quality\x27 || \x27release\x27 }}"
  abort unless commit.lines.count { |line| line.strip == manual_tools } == 1
  abort unless pull_request.scan(/^\s*run:\s*scripts\/install_ci_build_tools\.sh quality\s*$/).size == 1
  abort unless swift_gate.scan(/^source tests\/swift_test_cache\.sh$/).size == 1
  abort unless swift_gate.scan(/linnet_swift_compile/).size >= 4
  abort unless swift_cache.include?("Cached binaries are acceleration only") &&
    swift_cache.include?("LINNET_SWIFT_ENVIRONMENT_FINGERPRINT") &&
    swift_cache.include?("shasum -a 256 -c")
' "${commit_workflow}" "${pull_request_workflow}" "${release_workflow}" \
    "${cache_action}" "${repo_root}/scripts/build-rime-runtime" \
    "${repo_root}/tests/verify_development.sh" \
    "${repo_root}/tests/verify_product.sh" \
    "${repo_root}/tests/verify_swift_units.sh" \
    "${repo_root}/tests/swift_test_cache.sh" ||
  fail "community CI or Action publication owner is incomplete"

echo "Linnet unsigned PKG / stable CMS App publication owner: PASS"
