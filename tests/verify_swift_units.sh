#!/usr/bin/env bash

# Standalone owner/unit tests. This gate compiles and executes behavior; source
# shape and packaging policy belong to their focused gates.

set -euo pipefail

owners='hallelujah-importer personal-data projection-renderer appearance-preview settings-page-layout presentation-status cloud-sync-location rime-sync-controller settings-session settings-window-close settings-update-checker backup-store candidate-presentation candidate-snapshot-builder macos-keycodes rime-session-lease input-activation-policy input-source-lifecycle host-entrypoints preedit-geometry panel-geometry candidate-window client-appearance settings-contract data-registry data-channel download-transport download-source pack rime-path rime-user-data-bridge settings-data-coordinator settings-ipc'
selection=all
case "$#:${1:-}" in
  0:) ;;
  1:--appearance-preview) selection=appearance-preview ;;
  1:--list)
    printf '%s\n' ${owners}
    exit 0
    ;;
  2:--only) selection="$2" ;;
  *)
    echo "Usage: $0 [--list|--appearance-preview|--only OWNER[,OWNER...]]" >&2
    exit 2
    ;;
esac

selected() {
  local owner="$1"
  [[ "${selection}" == all ]] && return 0
  case ",${selection}," in
    *,"${owner}",*) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ "${selection}" != all ]]; then
  IFS=',' read -r -a requested_owners <<<"${selection}"
  for requested in "${requested_owners[@]}"; do
    [[ -n "${requested}" && " ${owners} " == *" ${requested} "* ]] || {
      echo "Unknown Swift test owner: ${requested:-<empty>}" >&2
      exit 2
    }
  done
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

source tests/swift_test_scratch.sh
linnet_swift_scratch_init

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
  linnet_swift_compile "${name}" -warnings-as-errors -sdk "${sdk}" \
    tests/LinnetTestScratch.swift "$@"
  "${LINNET_SWIFT_COMPILED_BINARY}"
  end_phase "compile and run ${name}"
}

compile_run_selected() {
  local name="$1"
  shift
  selected "${name}" || return 0
  compile_run "${name}" "$@"
}

appearance_preview() {
  begin_phase "compile and run appearance-preview"
  linnet_swift_compile appearance-preview -warnings-as-errors -sdk "${sdk}" -framework SwiftUI \
    sources/LinnetPackContract.swift \
    sources/LinnetDataChannel.swift \
    sources/LinnetDataRegistry.swift sources/LinnetDirectoryDelta.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
    sources/LinnetSettings/SettingsContract.swift \
    sources/LinnetSettings/PersonalDataStore.swift \
    sources/LinnetSettings/PersonalDataValidation.swift \
    sources/LinnetSettings/LinnetSettingsDocument.swift sources/LinnetSettings/LinnetSettingsDocumentStore.swift \
    sources/LinnetCandidatePresentation.swift \
    sources/LinnetSettings/LinnetSettingsAppearancePreview.swift \
    sources/LinnetSettings/LinnetSettingsThemeFamilyPicker.swift \
    tests/LinnetSettingsAppearancePreviewTests.swift
  local preview_app="${scratch}/AppearancePreview.app/Contents"
  mkdir -p "${preview_app}/MacOS" "${preview_app}/Resources"
  cp "${LINNET_SWIFT_COMPILED_BINARY}" "${preview_app}/MacOS/AppearancePreview"
  cp data/squirrel.yaml "${preview_app}/Resources/squirrel.yaml"
  plutil -create xml1 "${preview_app}/Info.plist"
  plutil -insert CFBundleExecutable -string AppearancePreview "${preview_app}/Info.plist"
  "${preview_app}/MacOS/AppearancePreview"
  end_phase "compile and run appearance-preview"
}

compile_run_selected hallelujah-importer \
  sources/LinnetSettings/HallelujahSubstitutionImporter.swift \
  tests/HallelujahSubstitutionImporterTests.swift
compile_run_selected personal-data \
  sources/LinnetSettings/PersonalDataStore.swift \
  sources/LinnetSettings/PersonalDataValidation.swift \
  tests/PersonalDataStoreTests.swift
compile_run_selected projection-renderer \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDirectoryDelta.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetSettings/PersonalDataStore.swift \
  sources/LinnetSettings/PersonalDataValidation.swift \
  sources/LinnetSettings/LinnetSettingsDocument.swift sources/LinnetSettings/LinnetSettingsDocumentStore.swift \
  sources/LinnetSettings/LinnetSettingsProjectionRenderer.swift \
  tests/LinnetSettingsProjectionRendererTests.swift
if selected appearance-preview; then
  appearance_preview
fi
compile_run_selected settings-page-layout -framework SwiftUI \
  sources/LinnetSettings/LinnetSettingsPage.swift \
  tests/LinnetSettingsPageLayoutTests.swift
compile_run_selected presentation-status \
  sources/LinnetSettings/SettingsRuntimeReachability.swift \
  sources/LinnetSettings/SettingsPresentationStatus.swift \
  tests/SettingsPresentationStatusTests.swift
compile_run_selected cloud-sync-location \
  sources/LinnetSettings/LinnetCloudSyncLocation.swift \
  tests/LinnetCloudSyncLocationTests.swift
compile_run_selected rime-sync-controller \
  sources/LinnetSettings/LinnetRimeSyncController.swift \
  tests/LinnetRimeSyncControllerTests.swift
compile_run_selected settings-session \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDirectoryDelta.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetSettings/PersonalDataStore.swift \
  sources/LinnetSettings/PersonalDataValidation.swift \
  sources/LinnetSettings/LinnetSettingsDocument.swift sources/LinnetSettings/LinnetSettingsDocumentStore.swift \
  sources/LinnetSettings/LinnetBackupStore.swift sources/LinnetSettings/LinnetBackupStoreSupport.swift \
  sources/LinnetSettings/SettingsSessionState.swift \
  tests/SettingsSessionStateTests.swift
compile_run_selected settings-window-close -framework AppKit -framework SwiftUI \
  sources/LinnetSettings/SettingsWindowCloseGuard.swift \
  tests/SettingsWindowCloseCoordinatorTests.swift
compile_run_selected settings-update-checker -framework AppKit \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDirectoryDelta.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetSettings/LinnetSettingsDownloadSource.swift \
  sources/LinnetSettings/LinnetSettingsExclusiveFileSink.swift \
  sources/LinnetSettings/LinnetSettingsDownloadTransport.swift \
  sources/LinnetSettings/LinnetSettingsTransactionIPC.swift \
  sources/LinnetSettings/LinnetSettingsUpdateChecker.swift \
  tests/LinnetSettingsUpdateCheckerStateTests.swift
compile_run_selected backup-store \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDirectoryDelta.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetSettings/PersonalDataStore.swift \
  sources/LinnetSettings/PersonalDataValidation.swift \
  sources/LinnetSettings/LinnetSettingsDocument.swift sources/LinnetSettings/LinnetSettingsDocumentStore.swift \
  sources/LinnetSettings/LinnetBackupStore.swift sources/LinnetSettings/LinnetBackupStoreSupport.swift \
  sources/LinnetSettings/LinnetCloudRecoveryArchive.swift \
  tests/LinnetBackupStoreTests.swift
compile_run_selected candidate-presentation \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDirectoryDelta.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetCandidatePresentation.swift tests/LinnetCandidatePresentationTests.swift
compile_run_selected candidate-snapshot-builder -target "${target}" -framework AppKit \
  -import-objc-header sources/Squirrel-Bridging-Header.h \
  -I librime/dist/include \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDirectoryDelta.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetCandidatePresentation.swift \
  sources/LinnetRimeCandidateSnapshotBuilder.swift \
  tests/LinnetRimeCandidateSnapshotBuilderTests.swift
compile_run_selected macos-keycodes -target "${target}" -framework AppKit \
  -import-objc-header sources/Squirrel-Bridging-Header.h \
  -I librime/dist/include \
  sources/MacOSKeyCodes.swift tests/MacOSKeyCodesTests.swift
compile_run_selected rime-session-lease -target "${target}" \
  -import-objc-header sources/Squirrel-Bridging-Header.h \
  -I librime/dist/include \
  sources/LinnetRimeSessionLease.swift sources/LinnetRimeWarmSession.swift \
  tests/LinnetRimeSessionLeaseTests.swift
compile_run_selected input-activation-policy \
  sources/LinnetInputActivationPolicy.swift tests/LinnetInputActivationPolicyTests.swift
compile_run_selected input-source-lifecycle -parse-as-library -framework InputMethodKit -framework Carbon \
  sources/LinnetInputSourceRegistration.swift sources/InputSource.swift \
  tests/LinnetInputSourceLifecycleTests.swift
if selected host-entrypoints; then
  begin_phase "parse Host entrypoints"
  "${swiftc}" -swift-version 5 -parse sources/Main.swift \
    sources/LinnetInputSourceRegistration.swift sources/InputSource.swift
  end_phase "parse Host entrypoints"
fi
compile_run_selected preedit-geometry -parse-as-library \
  sources/LinnetPreeditGeometry.swift tests/LinnetPreeditGeometryTests.swift
compile_run_selected panel-geometry -parse-as-library \
  sources/LinnetPanelGeometry.swift tests/LinnetPanelGeometryTests.swift
if selected candidate-window; then
  begin_phase "candidate window interaction"
  if [[ "${selection}" == all ]]; then
    tests/verify_candidate_window_interaction.sh
  else
    tests/verify_candidate_window_interaction.sh --behavior
  fi
  end_phase "candidate window interaction"
fi
compile_run_selected client-appearance -framework AppKit \
  sources/LinnetClientAppearance.swift tests/LinnetClientAppearanceTests.swift
compile_run_selected settings-contract \
  sources/LinnetPackContract.swift sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDirectoryDelta.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift sources/LinnetSettings/SettingsContract.swift \
  tests/SettingsContractTests.swift
compile_run_selected data-registry \
  tests/LinnetTestFailure.swift sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift sources/LinnetDataRegistry.swift sources/LinnetDirectoryDelta.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  tests/LinnetDataRegistryTests.swift
compile_run_selected data-channel \
  tests/LinnetTestFailure.swift sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift sources/LinnetDataRegistry.swift sources/LinnetDirectoryDelta.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  tools/LinnetDataCatalogBuilder.swift tests/LinnetDataChannelTests.swift
compile_run_selected download-transport \
  sources/LinnetPackContract.swift sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDirectoryDelta.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  sources/LinnetSettings/LinnetSettingsDownloadSource.swift \
  sources/LinnetSettings/LinnetSettingsExclusiveFileSink.swift \
  sources/LinnetSettings/LinnetSettingsDownloadTransport.swift \
  tests/LinnetSettingsDownloadTransportTests.swift
compile_run_selected download-source \
  sources/LinnetSettings/LinnetSettingsDownloadSource.swift \
  tests/LinnetSettingsDownloadSourceTests.swift
compile_run_selected pack \
  tests/LinnetTestFailure.swift sources/LinnetPackContract.swift \
  tests/LinnetDirectoryDeltaTests.swift \
  sources/LinnetDataChannel.swift sources/LinnetDataRegistry.swift sources/LinnetDirectoryDelta.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  tools/LinnetPackEncoder.swift \
  tests/LinnetPackTests.swift

if selected rime-path; then
  begin_phase "Rime filesystem projection"
  linnet_swift_compile rime-path -parse-as-library -warnings-as-errors -sdk "${sdk}" \
    -target "${target}" \
    -import-objc-header sources/Squirrel-Bridging-Header.h \
    -I librime/dist/include sources/BridgingFunctions.swift \
    tests/RimeFilesystemPathProjectionTests.swift \
    lib/librime.1.dylib \
    lib/rime-plugins/librime-lua.dylib \
    lib/rime-plugins/librime-octagram.dylib \
    lib/rime-plugins/librime-predict.dylib \
    lib/rime-plugins/librime-smart-english.dylib
  external_rime_cwd="${scratch}/Rime external cwd"
  mkdir -p "${external_rime_cwd}"
  (
    cd "${external_rime_cwd}"
    DYLD_LIBRARY_PATH="${repo_root}/lib:${repo_root}/lib/rime-plugins" \
      "${LINNET_SWIFT_COMPILED_BINARY}" "${repo_root}"
  )
  end_phase "Rime filesystem projection"
fi

common_settings_sources=(
  tests/LinnetTestScratch.swift
  sources/LinnetPackContract.swift
  sources/LinnetDataChannel.swift
  sources/LinnetDataRegistry.swift sources/LinnetDirectoryDelta.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift
  sources/LinnetSettings/SettingsContract.swift
  sources/LinnetSettings/PersonalDataStore.swift
  sources/LinnetSettings/PersonalDataValidation.swift
  sources/LinnetSettings/LinnetSettingsDocument.swift sources/LinnetSettings/LinnetSettingsDocumentStore.swift
  sources/LinnetSettings/LinnetBackupStore.swift sources/LinnetSettings/LinnetBackupStoreSupport.swift
  sources/LinnetSettings/LinnetCloudRecoveryArchive.swift
  sources/LinnetSettings/HallelujahSubstitutionImporter.swift
  sources/LinnetSettings/RimeUserDataBridge.swift
)

if selected rime-user-data-bridge; then
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
fi

if selected settings-data-coordinator; then
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
    sources/LinnetSettings/LinnetCloudSyncLocation.swift \
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
fi

if selected settings-ipc; then
  begin_phase "Settings transaction IPC"
  tests/verify_settings_transaction_ipc.sh
  end_phase "Settings transaction IPC"
fi
echo "Linnet Swift owner tests (${selection}): PASS"
