#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

# Publication source acceptance is limited to observable contracts: current
# signing identity, projected assets, and user trust instructions. The remote
# mutation transaction has one separate low-frequency release test instead of
# running its fake GitHub service in every local, pull-request, and manual build.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
verifier="${repo_root}/package/verify_publication_artifacts"
asset_manifest="${repo_root}/package/release_asset_manifest"
publisher="${repo_root}/package/publish_github_release"
stager="${repo_root}/package/stage_github_release"
candidate_identity_owner="${repo_root}/package/release_candidate_identity"
release_control="${repo_root}/scripts/release-control"

fail() {
  echo "verify_publication_owner: $*" >&2
  exit 1
}

for retired in package/publication_plan package/publish_release \
    config/linnet-publication-acceptance.json; do
  [[ ! -e "${repo_root}/${retired}" && ! -L "${repo_root}/${retired}" ]] ||
    fail "retired publication path returned: ${retired}"
done

for owner in "${verifier}" "${asset_manifest}" "${candidate_identity_owner}" \
    "${stager}" "${publisher}" "${release_control}"; do
  [[ -f "${owner}" && ! -L "${owner}" && -x "${owner}" ]] ||
    fail "release channel owner is missing: ${owner##*/}"
  bash -n "${owner}"
done

signing_contract="${repo_root}/config/linnet-community-signing.json"
if ! ruby -rjson - "${signing_contract}" <<'RUBY'
document = JSON.parse(File.binread(ARGV.fetch(0)))
abort unless document.keys.sort ==
  %w[certificate_sha1 certificate_sha256 format profile]
abort unless document.fetch("format") == 1 &&
  document.fetch("profile") == "community-cms"
abort unless document.fetch("certificate_sha1").match?(/\A[0-9A-F]{40}\z/)
abort unless document.fetch("certificate_sha256").match?(/\A[0-9a-f]{64}\z/)
RUBY
then
  fail "the pinned community CMS signing contract is invalid"
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
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  fail "the product version is unavailable"
catalog_sequence="$("${repo_root}/package/data_release_metadata" get-catalog-sequence \
  "${repo_root}/config/linnet-data-releases.json")"
core_artifact_format="$("${repo_root}/package/data_release_metadata" get-core-artifact-format \
  "${repo_root}/config/linnet-data-releases.json")"

public_expected=Linnet.pkg
case "${core_artifact_format}" in
  installer-package) core_artifact="Linnet-${version}-arm64-Core-community-beta.pkg" ;;
  app-tar-gzip) core_artifact="Linnet-${version}-arm64-Core.linnetcore" ;;
  *) fail "unknown Core artifact format" ;;
esac
core_expected="$(printf '%s\n' \
  "${core_artifact}" \
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
' "${repo_root}/config/linnet-update-baselines.json" \
  "${repo_root}/config/linnet-data-releases.json")"
data_expected="$(printf '%s\n' \
  Linnet-Chinese.linnetpack Linnet-English.linnetpack \
  Linnet-LTS.linnetpack Linnet-Extended.linnetpack "${delta_expected}" |
  sed '/^$/d' | LC_ALL=C sort)"
candidate_expected="$(printf '%s\n' \
  "${public_expected}" "${core_expected}" "${data_expected}" | LC_ALL=C sort)"

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

manual_trust_docs=(
  "${repo_root}/README.md"
  "${repo_root}/package/WELCOME.md"
  "${repo_root}/docs/release.md"
)
if rg -n 'xattr[[:space:]].*(-d|-c)|spctl[[:space:]].*--master-disable' \
    "${manual_trust_docs[@]}"; then
  fail "manual trust instructions disable or bypass a system security boundary"
fi

echo "Linnet publication contracts: PASS"
