#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

# Online update has one standard owner chain: the official HTTPS catalog names
# immutable release assets, each artifact binds its exact container bytes, and
# the pack contract validates compatibility and inventory before activation.
# Mirrors may route pack bytes, but never replace the canonical catalog.
rg -Fq 'let containerSHA256: String' sources/LinnetDataChannel.swift
rg -Fq 'case containerSHA256 = "container_sha256"' sources/LinnetDataChannel.swift

for retired in resources/linnet-pack-publishers.json package/build_signing_request \
    tools/LinnetDataChannelPublisher.swift tests/LinnetExternalSignerFixture.swift; do
  if [[ -e "${retired}" ]]; then
    echo "Retired private catalog-signing path remains: ${retired}" >&2
    exit 1
  fi
done

if rg -n 'manifest\.ed25519|verifySignedManifest|publisherKeyID|publisher_key_id|PublisherDocument|loadPublishers|trustedPublishers|signingPreimage|invalidSignature|invalidPublisher|publishers-file' \
    sources/LinnetDataChannel.swift sources/LinnetDataRegistry.swift \
    tools/LinnetPackTool.swift package/make_archive package/make_package \
    package/verify_package; then
  echo "A retired catalog publisher/signature authority returned." >&2
  exit 1
fi

if rg -n 'LINNET_SIGNED_PACKS_ROOT|signed_packs_root|consume_signed_pack' \
    package/make_package; then
  echo "Local package assembly still depends on external signed pack roots." >&2
  exit 1
fi

if rg -n 'LINNET_SIGNED_RELEASE_ROOT|signed_release_root|LINNET_DATA_RELEASE_ROOT|SIGNING_HANDOFF_REQUIRED|data_release_root' \
    package/make_archive; then
  echo "Archive still depends on a private external data-release handoff." >&2
  exit 1
fi
rg -Fq 'build-container' package/make_archive
rg -Fq 'build-catalog' package/make_archive
rg -Fq 'container_sha256' package/make_archive

rg -Fq 'source: .direct' sources/LinnetSettings/LinnetSettingsDownloadTransport.swift || {
  echo "Catalog download is still routed through a mutable mirror." >&2
  exit 1
}

if rg -n 'candidate_revision|candidate-revision|signing-request-set|pack-signing-request' \
    package/build_data_pack tools/LinnetPackTool.swift; then
  echo "Language-pack identity is still coupled to an App revision." >&2
  exit 1
fi

rg -Fq 'verifyAndStagePack(package: package, artifact: artifact)' \
  sources/LinnetSettings/SettingsModelLanguageData.swift
if rg -n 'verifyDownloadedArtifact\(|artifact\.matches\(staged\)' \
    sources/LinnetSettings/SettingsMain.swift \
    sources/LinnetSettings/SettingsModelLanguageData.swift; then
  echo "Settings still reinterprets Registry-owned pack verification." >&2
  exit 1
fi
if rg -n 'publisherDocumentURL' sources/LinnetSettings/SettingsMain.swift \
    sources/LinnetSettings/SettingsModelLanguageData.swift; then
  echo "Settings still owns a second Catalog trust-root availability path." >&2
  exit 1
fi

# Current product documentation is part of the release contract.  Historical
# ADRs may describe retired designs, but no current authority may advertise a
# private Shift/schema owner, per-application mode persistence, or a private
# language-data signing ceremony after those paths have been removed.
current_authority_docs=(
  README.md
  CHANGELOG.md
  THIRD_PARTY_NOTICES.md
  package/WELCOME.md
  docs/product-acceptance.md
  docs/development.md
  docs/release.md
)
if rg -n -i \
    'LinnetModeSwitcher|per[- ]application (Chinese|mode)|per-app mode|signed catalog|Ed25519|build_signing_request|external publisher|validated_against|rime-wanxiang@v17\.2\.4|wanxiang v17\.2\.4|librime 1\.16\.0|librime weighted restricted Damerau' \
    "${current_authority_docs[@]}"; then
  echo "Current product authority still advertises a retired private path or stale pin." >&2
  exit 1
fi
if rg -n 'PASS \(librime correction' scripts/build-rime-runtime; then
  echo "Runtime build status still advertises the retired global correction owner." >&2
  exit 1
fi
if rg -n 'cmake.*--version.*\| head -n 1' scripts/build-rime-runtime; then
  echo "Runtime build can misclassify valid CMake output as SIGPIPE under pipefail." >&2
  exit 1
fi
fetch_guard='fetch_grammar_model() ('
rg -Fq "${fetch_guard}" action-install.sh || {
  echo "Grammar download does not own a scoped cleanup subshell." >&2
  exit 1
}
ruby -e '
  source = File.read(ARGV.fetch(0))
  method = source[/fetch_grammar_model\(\) \(.*?^\)/m]
  abort "grammar download owner is missing" unless method
  abort "grammar download lacks one all-exit cleanup" unless
    method.scan("trap cleanup_grammar_download EXIT INT TERM").length == 1 &&
      method.include?(%q{trap - EXIT INT TERM}) &&
      method.include?(%q{linnet-grammar."??????}) &&
      method.include?(%q{find "${download_dir}" -depth -delete})
' action-install.sh || {
  echo "Grammar download can leave its large temporary directory behind." >&2
  exit 1
}
rg -Fq 'fail "OpenCC did not bind the locked standalone marisa"' \
  scripts/build-rime-runtime || {
  echo "OpenCC no longer proves which marisa implementation it linked." >&2
  exit 1
}
rg -Fq 'fail "OpenCC enabled its second embedded Darts implementation"' \
  scripts/build-rime-runtime || {
  echo "OpenCC can silently restore its redundant Darts implementation." >&2
  exit 1
}
if rg -n 'storedBytes|storedSHA256|storedHasher' sources/LinnetPackContract.swift; then
  echo "Pack compression still computes transport facts that no contract consumes." >&2
  exit 1
fi

echo "Linnet lean data trust architecture: PASS"
