#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

scratch="$(mktemp -d /tmp/linnet-candidate-interaction.XXXXXX)"
cleanup() {
  [[ "${scratch}" == /tmp/linnet-candidate-interaction.* ]] && /bin/rm -rf -- "${scratch}"
}
trap cleanup EXIT INT TERM

"$(xcrun --find swiftc)" -warnings-as-errors -enable-bare-slash-regex \
  -sdk "$(xcrun --show-sdk-path)" -framework AppKit \
  sources/LinnetPackContract.swift \
  sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift \
  sources/LinnetSettings/SettingsContract.swift \
  sources/LinnetCandidatePresentation.swift \
  sources/LinnetClientAppearance.swift \
  sources/LinnetInputActivationRegistry.swift \
  sources/LinnetPanelGeometry.swift \
  sources/SquirrelView.swift \
  sources/SquirrelView+CandidateDrawing.swift \
  sources/LinnetCandidateInteractionState.swift \
  sources/LinnetCandidateAccessibility.swift \
  sources/SquirrelPanel.swift \
  sources/SquirrelPanel+CandidatePresentation.swift \
  tests/LinnetCandidateWindowInteractionTests.swift \
  -o "${scratch}/candidate-interaction"
"${scratch}/candidate-interaction" "$@"

if (( $# == 0 )); then
  generated_modes="${scratch}/input-modes.png"
  generated_features="${scratch}/bilingual-features.png"
  generated_themes="${scratch}/theme-gallery.png"
  "${scratch}/candidate-interaction" \
    --readme-product-gallery data/squirrel.yaml \
    "${generated_modes}" "${generated_features}"
  "${scratch}/candidate-interaction" \
    --readme-theme-gallery data/squirrel.yaml "${generated_themes}"

  "${scratch}/candidate-interaction" --verify-readme-render \
    resources/readme/input-modes.png "${generated_modes}" "README input-mode image"
  "${scratch}/candidate-interaction" --verify-readme-render \
    resources/readme/bilingual-features.png "${generated_features}" "README bilingual image"
  "${scratch}/candidate-interaction" --verify-readme-render \
    resources/readme/theme-gallery.png "${generated_themes}" "README theme gallery"
  ! rg -n 'resources/readme/[^ )]+[.]svg' README.md
fi
