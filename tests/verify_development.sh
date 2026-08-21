#!/usr/bin/env bash

# Fast post-build development gate. It needs staged data and a compiled App but
# no certificate, Keychain, package or installed-product mutation.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

host_app="${repo_root}/build/Build/Products/Release/Linnet.app"
standalone_settings="${repo_root}/build/Build/Products/Release/Settings.app"
embedded_settings="${host_app}/Contents/Applications/Settings.app"
for app in "${host_app}" "${standalone_settings}" "${embedded_settings}"; do
  [[ -d "${app}" && ! -L "${app}" ]] || {
    echo "verify_development: missing unsigned Release App: ${app}" >&2
    exit 1
  }
  [[ ! -e "${app}/Contents/_CodeSignature" &&
     ! -L "${app}/Contents/_CodeSignature" ]] || {
    echo "verify_development: unsigned Release retained a stale signature: ${app}" >&2
    exit 1
  }
done

# A local unsigned composite has no clean candidate revision to bind. Refuse
# the common false-PASS shape instead: each target's source inputs must predate
# its Release executable, while shared project/resources must predate both.
host_executable="${host_app}/Contents/MacOS/Linnet"
settings_executables=(
  "${standalone_settings}/Contents/MacOS/Settings"
  "${embedded_settings}/Contents/MacOS/Settings"
)
for executable in "${host_executable}" "${settings_executables[@]}"; do
  [[ -f "${executable}" && ! -L "${executable}" && -x "${executable}" ]] || {
    echo "verify_development: missing Release executable: ${executable}" >&2
    exit 1
  }
done

verify_inputs_predate() {
  local executable="$1"
  local input
  while IFS= read -r input; do
    [[ -f "${input}" && ! -L "${input}" ]] || continue
    [[ ! "${input}" -nt "${executable}" ]] || {
      echo "verify_development: Release is older than build input: ${input}" >&2
      exit 1
    }
  done
}

verify_inputs_predate "${host_executable}" < <(
  {
    git ls-files --cached --others --exclude-standard -- \
      Linnet.xcodeproj/project.pbxproj resources data/squirrel.yaml
    git ls-files --cached --others --exclude-standard -- sources data/linnet |
      grep -v '^sources/LinnetSettings/'
    git ls-files --cached --others --exclude-standard -- \
      sources/LinnetSettings/SettingsContract.swift \
      sources/LinnetSettings/LinnetSettingsTransactionIPC.swift \
      sources/LinnetSettings/PersonalDataStore.swift \
      sources/LinnetSettings/LinnetSettingsDocument.swift \
      sources/LinnetSettings/LinnetSettingsProjectionRenderer.swift
    find data/plum data/opencc lib -type f -print
  } | LC_ALL=C sort -u
)
for executable in "${settings_executables[@]}"; do
  verify_inputs_predate "${executable}" < <(
    {
      git ls-files --cached --others --exclude-standard -- \
        Linnet.xcodeproj/project.pbxproj resources data/squirrel.yaml \
        sources/LinnetSettings
      printf '%s\n' \
        sources/LinnetPackContract.swift \
        sources/LinnetDataChannel.swift \
        sources/LinnetDataRegistry.swift \
        sources/LinnetCandidatePresentation.swift
    } | LC_ALL=C sort -u
  )
done

bash -n action-build.sh action-install.sh package/installer-scripts/postinstall
tests/verify_runtime_footprint.sh
LINNET_LIFECYCLE_CANDIDATE_APP="${host_app}" tests/verify_package_lifecycle.sh
tests/verify_visible_settings_fixture.sh --verify
tests/verify_swift_units.sh
tests/verify_chinese_source_projection.sh
tests/verify_english_data_projection.sh
tests/verify_rime_runtime.sh

echo "Linnet development gate: PASS (no signing or installation)"
