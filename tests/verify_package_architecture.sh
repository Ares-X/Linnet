#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

fail() {
  echo "verify_package_architecture: $1" >&2
  exit 1
}

for script in package/build_data_pack package/build_activation_profile \
    package/make_package package/make_archive \
    package/verify_package; do
  [[ -x "${script}" ]] || fail "missing executable: ${script}"
  bash -n "${script}"
done

tests/verify_lean_data_trust.sh

if rg -n -i 'python|\.py([[:space:]"]|$)' \
    sources resources package/installer-scripts package/uninstall-linnet; then
  fail "the installed product or lifecycle scripts gained a Python runtime dependency"
fi
rg -Fq -- "-name '*.py'" package/stage_language_pack_sources ||
  fail "language-pack staging can admit Python source"

if rg -n 'LINNET_SIGNED_PACKS_ROOT|LINNET_SIGNED_RELEASE_ROOT|manifest\.ed25519|pack-signing-request|signing-request-set' \
    package/build_data_pack package/make_package \
    tools/LinnetPackTool.swift; then
  fail "local packaging or data release regained the retired pack-signing path"
fi
if rg -n 'candidate_revision|candidate-revision' \
    package/build_data_pack tools/LinnetPackTool.swift; then
  fail "data-pack identity is coupled to an App revision"
fi
if rg -n 'LINNET_PACK_PRIVATE|private[_-]key|manifest\.ed25519' \
    package tools sources .github/workflows/release-ci.yml; then
  fail "candidate-controlled production code can read a Catalog private key"
fi
rg -Fq 'build-container' package/make_archive ||
  fail "archive does not build deterministic pack containers"
rg -Fq 'build-catalog' package/make_archive ||
  fail "archive does not build the canonical data Catalog"
rg -Fq 'container_sha256' package/make_archive ||
  fail "archive does not bind pack containers to the Catalog"
rg -Fq 'verify-catalog' package/make_archive ||
  fail "archive does not verify the Catalog"

fixture="$(mktemp -d /tmp/linnet-package-architecture.XXXXXX)"
cleanup() {
  exit_code=$?
  trap - EXIT INT TERM HUP
  chmod -R u+w "${fixture}" 2>/dev/null || true
  find "${fixture}" -depth -delete 2>/dev/null || true
  exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

sdk="$(xcrun --sdk macosx --show-sdk-path)"
tool="${fixture}/linnet-pack"
xcrun swiftc -warnings-as-errors -sdk "${sdk}" \
  sources/LinnetPackContract.swift sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift tools/LinnetDataCatalogBuilder.swift \
  tools/LinnetPackTool.swift -o "${tool}"
snapshot_test="${fixture}/activation-profile-runtime-snapshot"
xcrun swiftc -warnings-as-errors -sdk "${sdk}" \
  sources/LinnetPackContract.swift sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift tests/ActivationProfileRuntimeSnapshotTests.swift \
  -o "${snapshot_test}"

mkdir "${fixture}/sources" "${fixture}/packs" "${fixture}/containers"
for kind in chinese english lts extended; do
  source="${fixture}/sources/${kind}"
  mkdir "${source}"
  abi=2
  case "${kind}" in
    chinese)
      mkdir "${source}/build"
      for payload in default.yaml squirrel.yaml linnet_zh.schema.yaml linnet_zh.dict.yaml; do
        printf '%s\n' "${kind} ${payload} fixture" >"${source}/${payload}"
      done
      printf '%s\n' "${kind} build fixture" >"${source}/build/default.yaml"
      ;;
    english)
      abi=1
      printf '%s\n' "${kind} fixture" >"${source}/linnet_en.schema.yaml"
      ;;
    lts)
      printf '%s\n' "${kind} fixture" >"${source}/wanxiang-lts-zh-hans.gram"
      ;;
    extended)
      printf '%s\n' "${kind} fixture" >"${source}/linnet_zh_full.dict.yaml"
      ;;
  esac
  content_sha="$("${tool}" inspect-source --kind "${kind}" --source "${source}")"
  pack_root="${fixture}/packs/${kind}/1-fixture"
  mkdir "${fixture}/packs/${kind}"
  "${tool}" build-installed --kind "${kind}" --version fixture --sequence 1 \
    --data-abi "${abi}" --min-core 0.1.0 --content-sha256 "${content_sha}" \
    --source "${source}" --output "${pack_root}"
  asset_name="$("${tool}" asset-name --kind "${kind}")"
  "${tool}" build-container --root "${pack_root}" --core-version 0.1.0 \
    --output "${fixture}/containers/${asset_name}"
  "${tool}" verify --pack "${fixture}/containers/${asset_name}" \
    --core-version 0.1.0 >/dev/null
  extracted="${fixture}/extracted-${kind}"
  "${tool}" extract --pack "${fixture}/containers/${asset_name}" \
    --core-version 0.1.0 --output "${extracted}"
  cmp "${pack_root}/manifest.json" "${extracted}/manifest.json"
  if [[ "${kind}" == english ]]; then
    printf '%s\n' 'English fixture' >"${source}/linnet_en.schema.yaml"
    mutated_content_sha="$("${tool}" inspect-source --kind "${kind}" \
      --source "${source}")"
    [[ "${mutated_content_sha}" != "${content_sha}" ]] ||
      fail "source digest ignored a same-size English byte change"
  fi
done

release_sources="${fixture}/release-sources"
mkdir "${release_sources}"
package/stage_language_pack_sources "${release_sources}" >/dev/null
for kind in chinese english lts extended; do
  actual_content_sha="$("${tool}" inspect-source --kind "${kind}" \
    --source "${release_sources}/${kind}")"
  expected_content_sha="$(package/data_release_metadata get \
    config/linnet-data-releases.json "${kind}" content_sha256)"
  [[ "${actual_content_sha}" == "${expected_content_sha}" ]] ||
    fail "${kind} staged source differs from release metadata: actual=${actual_content_sha} expected=${expected_content_sha}"
done

runtime_support="${fixture}/support"
runtime_root="${runtime_support}/Linnet"
mkdir -p "${runtime_root}/Data/Packs"
for kind in chinese english lts extended; do
  mkdir "${runtime_root}/Data/Packs/${kind}"
  cp -R "${fixture}/packs/${kind}/1-fixture" \
    "${runtime_root}/Data/Packs/${kind}/1-fixture"
done
LINNET_RELEASE_TOOL="${tool}" LINNET_CORE_VERSION=0.1.0 \
  package/build_activation_profile complete "${runtime_root}" \
    "${runtime_root}/Data/Packs/chinese/1-fixture" \
    "${runtime_root}/Data/Packs/english/1-fixture" \
    "${runtime_root}/Data/Packs/lts/1-fixture" \
    "${runtime_root}/Data/Packs/extended/1-fixture"
"${snapshot_test}" "${runtime_support}" Linnet

tests/verify_data_channel_release.sh

echo "Linnet lean package architecture: PASS"
