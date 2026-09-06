#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

if rg -n -- '--contact-sheet|--(?:natural-default|paging-middle|horizontal-detail|dark-horizontal-detail|horizontal-reference|vertical-detail)-shot' \
    tests/LinnetCandidateWindowInteractionTests.swift; then
  echo "Retired ad-hoc candidate screenshot commands returned." >&2
  exit 1
fi

scratch="$(mktemp -d /tmp/linnet-candidate-interaction.XXXXXX)"
cleanup() {
  [[ "${scratch}" == /tmp/linnet-candidate-interaction.* ]] && /bin/rm -rf -- "${scratch}"
}
trap cleanup EXIT INT TERM

source tests/swift_test_cache.sh
linnet_swift_cache_init "${repo_root}" "${scratch}"
linnet_swift_compile candidate-interaction \
  -warnings-as-errors -enable-bare-slash-regex \
  -sdk "$(xcrun --show-sdk-path)" -framework AppKit \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDirectoryDelta.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetCandidatePresentation.swift \
  sources/LinnetClientAppearance.swift \
  sources/LinnetPanelGeometry.swift \
  sources/LinnetCandidateGridView.swift \
  sources/SquirrelView.swift \
  sources/SquirrelView+CandidateDrawing.swift \
  sources/LinnetCandidateInteractionState.swift \
  sources/SquirrelPanel.swift \
  sources/SquirrelPanel+CandidatePresentation.swift \
  tests/LinnetCandidateWindowInteractionTests.swift
candidate_interaction="${LINNET_SWIFT_COMPILED_BINARY}"

if [[ "${1:-}" == --behavior && $# -eq 1 ]]; then
  "${candidate_interaction}"
elif (( $# == 0 )); then
  generated_modes="${scratch}/input-modes.png"
  generated_features="${scratch}/bilingual-features.png"
  generated_themes="${scratch}/theme-gallery.png"
  "${candidate_interaction}" \
    --readme-product-gallery data/squirrel.yaml \
    "${generated_modes}" "${generated_features}" \
    --readme-theme-gallery data/squirrel.yaml "${generated_themes}" \
    --verify-readme-render \
    resources/readme/input-modes.png "${generated_modes}" "README input-mode image" \
    --verify-readme-render \
    resources/readme/bilingual-features.png "${generated_features}" "README bilingual image" \
    --verify-readme-render \
    resources/readme/theme-gallery.png "${generated_themes}" "README theme gallery"
  ! rg -n 'resources/readme/[^ )]+[.]svg' README.md
else
  "${candidate_interaction}" "$@"
fi
