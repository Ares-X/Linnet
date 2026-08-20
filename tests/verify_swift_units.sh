#!/usr/bin/env bash

# Standalone owner/unit tests. This gate compiles and executes behavior; source
# shape and packaging policy belong to their focused gates.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

scratch="$(mktemp -d /tmp/linnet-swift-units.XXXXXX)"
cleanup() {
  [[ "${scratch}" == /tmp/linnet-swift-units.* ]] && /bin/rm -rf -- "${scratch}"
}
trap cleanup EXIT INT TERM

swiftc="$(xcrun --find swiftc)"
sdk="$(xcrun --show-sdk-path)"
target=arm64-apple-macosx13.0

compile_run() {
  local name="$1"
  shift
  "${swiftc}" -warnings-as-errors -sdk "${sdk}" "$@" -o "${scratch}/${name}"
  "${scratch}/${name}"
}

compile_run hallelujah-importer \
  sources/LinnetSettings/HallelujahSubstitutionImporter.swift \
  tests/HallelujahSubstitutionImporterTests.swift
compile_run personal-data \
  sources/LinnetSettings/PersonalDataStore.swift \
  tests/PersonalDataStoreTests.swift
compile_run projection-renderer \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetSettings/PersonalDataStore.swift \
  sources/LinnetSettings/LinnetSettingsDocument.swift \
  sources/LinnetSettings/LinnetSettingsProjectionRenderer.swift \
  tests/LinnetSettingsProjectionRendererTests.swift
compile_run appearance-preview -framework SwiftUI \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetSettings/PersonalDataStore.swift \
  sources/LinnetSettings/LinnetSettingsDocument.swift \
  sources/LinnetCandidatePresentation.swift \
  sources/LinnetSettings/LinnetSettingsAppearancePreview.swift \
  tests/LinnetSettingsAppearancePreviewTests.swift
compile_run settings-page-layout -framework SwiftUI \
  sources/LinnetSettings/LinnetSettingsPage.swift \
  tests/LinnetSettingsPageLayoutTests.swift
compile_run presentation-status \
  sources/LinnetSettings/SettingsPresentationStatus.swift \
  tests/SettingsPresentationStatusTests.swift
compile_run settings-session \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetSettings/PersonalDataStore.swift \
  sources/LinnetSettings/LinnetSettingsDocument.swift \
  sources/LinnetSettings/LinnetPortableJSONBudget.swift \
  sources/LinnetSettings/LinnetBackupStore.swift \
  sources/LinnetSettings/SettingsSessionState.swift \
  tests/SettingsSessionStateTests.swift
compile_run backup-store \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetSettings/PersonalDataStore.swift \
  sources/LinnetSettings/LinnetSettingsDocument.swift \
  sources/LinnetSettings/LinnetPortableJSONBudget.swift \
  sources/LinnetSettings/LinnetBackupStore.swift \
  tests/LinnetBackupStoreTests.swift
compile_run candidate-presentation \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetCandidatePresentation.swift tests/LinnetCandidatePresentationTests.swift
compile_run macos-keycodes -target "${target}" -framework AppKit \
  -import-objc-header sources/Squirrel-Bridging-Header.h \
  -I librime/src -I librime/include -I librime/dist/include \
  sources/MacOSKeyCodes.swift tests/MacOSKeyCodesTests.swift
compile_run input-source-lifecycle -parse-as-library -framework InputMethodKit -framework Carbon \
  sources/InputSource.swift tests/LinnetInputSourceLifecycleTests.swift
"${swiftc}" -swift-version 5 -parse sources/Main.swift sources/InputSource.swift
compile_run preedit-geometry -parse-as-library \
  sources/LinnetPreeditGeometry.swift tests/LinnetPreeditGeometryTests.swift
compile_run panel-geometry -parse-as-library \
  sources/LinnetPanelGeometry.swift tests/LinnetPanelGeometryTests.swift
tests/verify_candidate_window_interaction.sh
compile_run client-appearance -framework AppKit \
  sources/LinnetClientAppearance.swift tests/LinnetClientAppearanceTests.swift
compile_run settings-contract \
  sources/LinnetPackContract.swift sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetSettings/SettingsContract.swift \
  tests/SettingsContractTests.swift
compile_run data-registry \
  tests/LinnetTestFailure.swift sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift sources/LinnetDataRegistry.swift \
  tests/LinnetDataRegistryTests.swift
compile_run data-channel \
  tests/LinnetTestFailure.swift sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift sources/LinnetDataRegistry.swift \
  tools/LinnetDataCatalogBuilder.swift tests/LinnetDataChannelTests.swift
compile_run download-transport \
  sources/LinnetPackContract.swift sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift \
  sources/LinnetSettings/LinnetSettingsDownloadSource.swift \
  sources/LinnetSettings/LinnetSettingsExclusiveFileSink.swift \
  sources/LinnetSettings/LinnetSettingsDownloadTransport.swift \
  tests/LinnetSettingsDownloadTransportTests.swift
compile_run download-source \
  sources/LinnetSettings/LinnetSettingsDownloadSource.swift \
  tests/LinnetSettingsDownloadSourceTests.swift
compile_run pack \
  tests/LinnetTestFailure.swift sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift sources/LinnetDataRegistry.swift \
  tests/LinnetPackTests.swift

"${swiftc}" -parse-as-library -warnings-as-errors -sdk "${sdk}" \
  tests/RimeFilesystemPathProjectionTests.swift -o "${scratch}/rime-path"
"${scratch}/rime-path" sources/SquirrelApplicationDelegate.swift

common_settings_sources=(
  sources/LinnetPackContract.swift
  sources/LinnetDataChannel.swift
  sources/LinnetDataRegistry.swift
  sources/LinnetSettings/SettingsContract.swift
  sources/LinnetSettings/PersonalDataStore.swift
  sources/LinnetSettings/LinnetSettingsDocument.swift
  sources/LinnetSettings/LinnetPortableJSONBudget.swift
  sources/LinnetSettings/LinnetBackupStore.swift
  sources/LinnetSettings/HallelujahSubstitutionImporter.swift
  sources/LinnetSettings/RimeUserDataBridge.swift
)

"${swiftc}" -warnings-as-errors -sdk "${sdk}" -target "${target}" \
  -import-objc-header sources/LinnetSettings/Settings-Bridging-Header.h \
  -I librime/src -I librime/include -I librime/dist/include \
  "${common_settings_sources[@]}" \
  tests/RimeUserDataBridgeDirectoryTests.swift -L lib -lrime.1 \
  -o "${scratch}/user-data-bridge"
DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
  "${scratch}/user-data-bridge"

"${swiftc}" -warnings-as-errors -sdk "${sdk}" -target "${target}" \
  -import-objc-header sources/LinnetSettings/Settings-Bridging-Header.h \
  -I librime/src -I librime/include -I librime/dist/include \
  "${common_settings_sources[@]}" \
  sources/LinnetSettings/LinnetSettingsTransactionIPC.swift \
  sources/LinnetSettings/LinnetSettingsProjectionRenderer.swift \
  sources/LinnetSettings/LinnetSettingsMutationLease.swift \
  sources/LinnetSettings/SettingsDataCoordinator.swift \
  tests/SettingsDataCoordinatorTests.swift -L lib -lrime.1 \
  -o "${scratch}/settings-data-coordinator"
mkdir -p "${scratch}/rime-logs"
if ! RIME_LOG_DIR="${scratch}/rime-logs" \
    DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
    "${scratch}/settings-data-coordinator" \
    >"${scratch}/settings-data.out" 2>&1; then
  tail -n 160 "${scratch}/settings-data.out" >&2 || true
  exit 1
fi
rg -Fq 'SettingsDataCoordinatorTests: PASS' "${scratch}/settings-data.out"

tests/verify_settings_transaction_ipc.sh
echo "Linnet Swift owner tests: PASS"
