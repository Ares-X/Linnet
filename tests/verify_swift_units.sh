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
source tests/swift_test_cache.sh
linnet_swift_cache_init "${repo_root}" "${scratch}"
phase_started=0

begin_phase() {
  phase_started="${SECONDS}"
  printf '==> Swift owner tests: %s\n' "$1"
}

end_phase() {
  printf '<== Swift owner tests: PASS in %ss: %s\n' \
    "$((SECONDS - phase_started))" "$1"
}

compile_run() {
  local name="$1"
  shift
  begin_phase "compile and run ${name}"
  linnet_swift_compile "${name}" -warnings-as-errors -sdk "${sdk}" "$@"
  "${LINNET_SWIFT_COMPILED_BINARY}"
  end_phase "compile and run ${name}"
}

compile_run hallelujah-importer \
  sources/LinnetSettings/HallelujahSubstitutionImporter.swift \
  tests/HallelujahSubstitutionImporterTests.swift
compile_run personal-data \
  sources/LinnetSettings/PersonalDataStore.swift \
  sources/LinnetSettings/PersonalDataValidation.swift \
  tests/PersonalDataStoreTests.swift
compile_run stable-row-binding -framework SwiftUI \
  sources/LinnetSettings/PersonalDataStore.swift \
  sources/LinnetSettings/PersonalDataValidation.swift \
  sources/LinnetSettings/LinnetStableRowTextBinding.swift \
  tests/LinnetStableRowTextBindingTests.swift
compile_run projection-renderer \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetSettings/PersonalDataStore.swift \
  sources/LinnetSettings/PersonalDataValidation.swift \
  sources/LinnetSettings/LinnetSettingsDocument.swift sources/LinnetSettings/LinnetSettingsDocumentStore.swift \
  sources/LinnetSettings/LinnetSettingsProjectionRenderer.swift \
  tests/LinnetSettingsProjectionRendererTests.swift
compile_run appearance-preview -framework SwiftUI \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetSettings/PersonalDataStore.swift \
  sources/LinnetSettings/PersonalDataValidation.swift \
  sources/LinnetSettings/LinnetSettingsDocument.swift sources/LinnetSettings/LinnetSettingsDocumentStore.swift \
  sources/LinnetCandidatePresentation.swift \
  sources/LinnetSettings/LinnetSettingsAppearancePreview.swift \
  sources/LinnetSettings/LinnetSettingsThemeFamilyPicker.swift \
  tests/LinnetSettingsAppearancePreviewTests.swift
compile_run settings-page-layout -framework SwiftUI \
  sources/LinnetSettings/LinnetSettingsPage.swift \
  tests/LinnetSettingsPageLayoutTests.swift
compile_run presentation-status \
  sources/LinnetSettings/SettingsRuntimeReachability.swift \
  sources/LinnetSettings/SettingsPresentationStatus.swift \
  tests/SettingsPresentationStatusTests.swift
compile_run cloud-sync-location \
  sources/LinnetSettings/LinnetCloudSyncLocation.swift \
  tests/LinnetCloudSyncLocationTests.swift
compile_run rime-sync-controller \
  sources/LinnetSettings/LinnetRimeSyncController.swift \
  tests/LinnetRimeSyncControllerTests.swift
compile_run settings-session \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetSettings/PersonalDataStore.swift \
  sources/LinnetSettings/PersonalDataValidation.swift \
  sources/LinnetSettings/LinnetSettingsDocument.swift sources/LinnetSettings/LinnetSettingsDocumentStore.swift \
  sources/LinnetSettings/LinnetPortableJSONBudget.swift \
  sources/LinnetSettings/LinnetBackupStore.swift sources/LinnetSettings/LinnetBackupStoreSupport.swift \
  sources/LinnetSettings/SettingsSessionState.swift \
  tests/SettingsSessionStateTests.swift
compile_run settings-window-close -framework AppKit -framework SwiftUI \
  sources/LinnetSettings/SettingsWindowCloseGuard.swift \
  tests/SettingsWindowCloseCoordinatorTests.swift
compile_run settings-update-checker -framework AppKit \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetSettings/LinnetSettingsDownloadSource.swift \
  sources/LinnetSettings/LinnetSettingsExclusiveFileSink.swift \
  sources/LinnetSettings/LinnetSettingsDownloadTransport.swift \
  sources/LinnetSettings/LinnetSettingsTransactionIPC.swift \
  sources/LinnetSettings/LinnetSettingsUpdateChecker.swift \
  tests/LinnetSettingsUpdateCheckerStateTests.swift
compile_run backup-store \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetSettings/PersonalDataStore.swift \
  sources/LinnetSettings/PersonalDataValidation.swift \
  sources/LinnetSettings/LinnetSettingsDocument.swift sources/LinnetSettings/LinnetSettingsDocumentStore.swift \
  sources/LinnetSettings/LinnetPortableJSONBudget.swift \
  sources/LinnetSettings/LinnetBackupStore.swift sources/LinnetSettings/LinnetBackupStoreSupport.swift \
  tests/LinnetBackupStoreTests.swift
compile_run candidate-presentation \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetCandidatePresentation.swift tests/LinnetCandidatePresentationTests.swift
compile_run candidate-snapshot-builder -target "${target}" -framework AppKit \
  -import-objc-header sources/Squirrel-Bridging-Header.h \
  -I librime/dist/include \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetCandidatePresentation.swift \
  sources/LinnetRimeCandidateSnapshotBuilder.swift \
  tests/LinnetRimeCandidateSnapshotBuilderTests.swift
compile_run macos-keycodes -target "${target}" -framework AppKit \
  -import-objc-header sources/Squirrel-Bridging-Header.h \
  -I librime/dist/include \
  sources/MacOSKeyCodes.swift tests/MacOSKeyCodesTests.swift
compile_run rime-session-lease -target "${target}" \
  -import-objc-header sources/Squirrel-Bridging-Header.h \
  -I librime/dist/include \
  sources/LinnetRimeSessionLease.swift tests/LinnetRimeSessionLeaseTests.swift
compile_run input-activation-policy \
  sources/LinnetInputActivationPolicy.swift tests/LinnetInputActivationPolicyTests.swift
compile_run input-source-lifecycle -parse-as-library -framework InputMethodKit -framework Carbon \
  sources/LinnetInputSourceRegistration.swift sources/InputSource.swift \
  tests/LinnetInputSourceLifecycleTests.swift
begin_phase "parse Host entrypoints"
"${swiftc}" -swift-version 5 -parse sources/Main.swift \
  sources/LinnetInputSourceRegistration.swift sources/InputSource.swift
end_phase "parse Host entrypoints"
compile_run preedit-geometry -parse-as-library \
  sources/LinnetPreeditGeometry.swift tests/LinnetPreeditGeometryTests.swift
compile_run panel-geometry -parse-as-library \
  sources/LinnetPanelGeometry.swift tests/LinnetPanelGeometryTests.swift
begin_phase "candidate window interaction"
tests/verify_candidate_window_interaction.sh
end_phase "candidate window interaction"
compile_run client-appearance -framework AppKit \
  sources/LinnetClientAppearance.swift tests/LinnetClientAppearanceTests.swift
compile_run settings-contract \
  sources/LinnetPackContract.swift sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift sources/LinnetSettings/SettingsContract.swift \
  tests/SettingsContractTests.swift
compile_run data-registry \
  tests/LinnetTestFailure.swift sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift sources/LinnetDataRegistry.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  tests/LinnetDataRegistryTests.swift
compile_run data-channel \
  tests/LinnetTestFailure.swift sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift sources/LinnetDataRegistry.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  tools/LinnetDataCatalogBuilder.swift tests/LinnetDataChannelTests.swift
compile_run download-transport \
  sources/LinnetPackContract.swift sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  sources/LinnetSettings/LinnetSettingsDownloadSource.swift \
  sources/LinnetSettings/LinnetSettingsExclusiveFileSink.swift \
  sources/LinnetSettings/LinnetSettingsDownloadTransport.swift \
  tests/LinnetSettingsDownloadTransportTests.swift
compile_run download-source \
  sources/LinnetSettings/LinnetSettingsDownloadSource.swift \
  tests/LinnetSettingsDownloadSourceTests.swift
compile_run pack \
  tests/LinnetTestFailure.swift sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift sources/LinnetDataRegistry.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  tools/LinnetPackEncoder.swift \
  tests/LinnetPackTests.swift

begin_phase "Rime filesystem projection"
linnet_swift_compile rime-path -parse-as-library -warnings-as-errors -sdk "${sdk}" \
  tests/RimeFilesystemPathProjectionTests.swift
"${LINNET_SWIFT_COMPILED_BINARY}" \
  sources/SquirrelApplicationDelegate.swift sources/SquirrelApplicationRuntime.swift sources/SquirrelApplicationTransactions.swift \
  sources/SquirrelApplicationPresentation.swift
end_phase "Rime filesystem projection"

common_settings_sources=(
  sources/LinnetPackContract.swift
  sources/LinnetDataChannel.swift
  sources/LinnetDataRegistry.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift
  sources/LinnetSettings/SettingsContract.swift
  sources/LinnetSettings/PersonalDataStore.swift
  sources/LinnetSettings/PersonalDataValidation.swift
  sources/LinnetSettings/LinnetSettingsDocument.swift sources/LinnetSettings/LinnetSettingsDocumentStore.swift
  sources/LinnetSettings/LinnetPortableJSONBudget.swift
  sources/LinnetSettings/LinnetBackupStore.swift sources/LinnetSettings/LinnetBackupStoreSupport.swift
  sources/LinnetSettings/HallelujahSubstitutionImporter.swift
  sources/LinnetSettings/RimeUserDataBridge.swift
)

begin_phase "Rime user-data bridge"
linnet_swift_compile rime-user-data-bridge \
  -warnings-as-errors -sdk "${sdk}" -target "${target}" \
  -import-objc-header sources/LinnetSettings/Settings-Bridging-Header.h \
  -I librime/dist/include \
  "${common_settings_sources[@]}" \
  tests/RimeUserDataBridgeDirectoryTests.swift -L lib -lrime.1
DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
  "${LINNET_SWIFT_COMPILED_BINARY}"
end_phase "Rime user-data bridge"

begin_phase "Settings data coordinator"
linnet_swift_compile settings-data-coordinator \
  -warnings-as-errors -sdk "${sdk}" -target "${target}" \
  -import-objc-header sources/LinnetSettings/Settings-Bridging-Header.h \
  -I librime/dist/include \
  "${common_settings_sources[@]}" \
  sources/LinnetSettings/LinnetSettingsTransactionIPC.swift \
  sources/LinnetSettings/LinnetSettingsProjectionRenderer.swift \
  sources/LinnetSettings/LinnetSettingsMutationLease.swift \
  sources/LinnetSettings/SettingsRuntimeReachability.swift \
  sources/LinnetSettings/SettingsDataCoordinator.swift sources/LinnetSettings/SettingsDataCoordinatorMutation.swift sources/LinnetSettings/SettingsDataCoordinatorRuntime.swift \
  tests/SettingsDataCoordinatorTests.swift -L lib -lrime.1
mkdir -p "${scratch}/rime-logs"
if ! RIME_LOG_DIR="${scratch}/rime-logs" \
    DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
    "${LINNET_SWIFT_COMPILED_BINARY}" \
    >"${scratch}/settings-data.out" 2>&1; then
  tail -n 160 "${scratch}/settings-data.out" >&2 || true
  exit 1
fi
rg -Fq 'SettingsDataCoordinatorTests: PASS' "${scratch}/settings-data.out"
end_phase "Settings data coordinator"

begin_phase "Settings transaction IPC"
tests/verify_settings_transaction_ipc.sh
end_phase "Settings transaction IPC"
echo "Linnet Swift owner tests: PASS"
