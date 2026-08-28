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

if rg -n -i 'installation-uat|\buat\b' \
    package/make_package package/verify_package; then
  fail "the installable package path retained the retired UAT identity"
fi
rg -Fq 'verification_scope=publication' package/make_package ||
  fail "package assembly has no single public community verification scope"
rg -Fq 'case "${verification_scope}" in publication)' package/verify_package ||
  fail "package verification accepts a non-public identity scope"
[[ "$(rg -c 'package/verify_package' package/make_package)" -eq 2 ]] ||
  fail "package assembly must verify Core and Complete exactly once"
if rg -n 'package/verify_package' package/make_archive; then
  fail "archive assembly repeated the package owner's completed verification"
fi
rg -q '^archive:[[:space:]]+package$' Makefile ||
  fail "archive no longer consumes the package owner's verified output"
[[ "$(rg -c 'package/verify_package' package/verify_publication_artifacts)" -eq 1 ]] ||
  fail "final publication lost its distinct byte-consumer verification boundary"

tests/verify_lean_data_trust.sh

if rg -n -i 'python|\.py([[:space:]"]|$)' \
    sources resources package/installer-scripts package/uninstall-linnet; then
  fail "the installed product or lifecycle scripts gained a Python runtime dependency"
fi
rg -Fq -- "-name '*.py'" package/stage_language_pack_sources ||
  fail "language-pack staging can admit Python source"

if rg -n 'LINNET_SIGNED_PACKS_ROOT|LINNET_SIGNED_RELEASE_ROOT|manifest\.ed25519|pack-signing-request|signing-request-set' \
    package/build_data_pack package/make_package \
    tools/LinnetPackEncoder.swift tools/LinnetPackTool.swift; then
  fail "local packaging or data release regained the retired pack-signing path"
fi
if rg -n 'candidate_revision|candidate-revision' \
    package/build_data_pack tools/LinnetPackEncoder.swift tools/LinnetPackTool.swift; then
  fail "data-pack identity is coupled to an App revision"
fi
if rg -n 'compressZlib|writeContainer' sources --glob '*.swift'; then
  fail "offline pack encoding returned to an App runtime target"
fi
rg -Fq 'enum LinnetPackEncoder' tools/LinnetPackEncoder.swift ||
  fail "the offline pack encoder owner is missing"
pack_compiler_owners="$(
  rg -l -F --hidden \
    -g '!build/**' -g '!librime/**' -g '!vendor/**' -g '!.git/**' \
    -g '!tests/verify_package_architecture.sh' \
    -g '!tests/verify_lean_data_trust.sh' \
    'tools/LinnetPackTool.swift' . | sed 's#^\./##' | LC_ALL=C sort
)"
[[ "${pack_compiler_owners}" == "Makefile" ]] ||
  fail "pack compiler owners: ${pack_compiler_owners:-none}"
ruby -e '
  paths = %w[
    Makefile action-install.sh package/make_package package/make_archive
    scripts/release-control tests/verify_package_architecture.sh
    tests/verify_data_channel_release.sh tests/verify_visible_settings_fixture.sh
  ]
  sources = paths.to_h { |path| [path, File.read(path)] }
  compiler_callers = %w[
    action-install.sh scripts/release-control tests/verify_data_channel_release.sh
    tests/verify_visible_settings_fixture.sh
  ]
  abort "a pack-tool compiler caller bypasses the canonical Make target" unless
    compiler_callers.all? { |path|
      sources.fetch(path).include?("linnet-pack-tool")
    }
  packaging_consumers = %w[package/make_package package/make_archive]
  abort "package assembly regained a second pack-tool compiler" unless
    packaging_consumers.all? { |path|
      source = sources.fetch(path)
      source.include?(%q{release_tool="${LINNET_RELEASE_TOOL:-}"}) &&
        !source.include?("linnet-pack-tool")
    }
  makefile = sources.fetch("Makefile")
  abort "Make did not pass one precompiled pack tool through both assemblies" unless
    makefile.include?("package: community-verified linnet-pack-tool") &&
    makefile.scan(%q{LINNET_RELEASE_TOOL="$(abspath $(LINNET_PACK_TOOL))"}).size == 2
' || fail "the pack CLI does not have one incremental compiler owner"
if rg -n 'LINNET_PACK_PRIVATE|private[_-]key|manifest\.ed25519' \
    package tools sources scripts/release-control; then
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
tool="${repo_root}/build/linnet-pack"
make -C "${repo_root}" --no-print-directory linnet-pack-tool
snapshot_test="${fixture}/activation-profile-runtime-snapshot"
xcrun swiftc -warnings-as-errors -sdk "${sdk}" \
  sources/LinnetPackContract.swift sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift tests/ActivationProfileRuntimeSnapshotTests.swift \
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
