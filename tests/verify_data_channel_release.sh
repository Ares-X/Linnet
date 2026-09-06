#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"
fixture="$(mktemp -d /tmp/linnet-data-channel-release.XXXXXX)"
cleanup() {
  exit_code=$?
  chmod -R u+w "${fixture}" 2>/dev/null || true
  find "${fixture}" -depth -delete 2>/dev/null || true
  exit "${exit_code}"
}
trap cleanup EXIT INT TERM

tool="${repo_root}/build/linnet-pack"
make -C "${repo_root}" --no-print-directory linnet-pack-tool

release="${fixture}/release"
mkdir "${release}"
for kind in chinese english lts extended; do
  source="${fixture}/source-${kind}"
  installed="${fixture}/installed-${kind}"
  mkdir "${source}"
  abi=2
  case "${kind}" in
    chinese) payload=default.yaml ;;
    english) abi=1; payload=linnet_en.dict.yaml ;;
    lts) payload=wanxiang-lts-zh-hans.gram ;;
    extended) payload=linnet_zh_full.dict.yaml ;;
  esac
  printf '%s\n' "${kind} fixture" >"${source}/${payload}"
  content_sha="$(shasum -a 256 "${source}/${payload}" | awk '{print $1}')"
  "${tool}" build-installed --kind "${kind}" --version 1.0.0 --sequence 1 \
    --data-abi "${abi}" --min-core 0.1.0 --content-sha256 "${content_sha}" \
    --source "${source}" --output "${installed}"
  asset_name="$("${tool}" asset-name --kind "${kind}")"
  "${tool}" build-container --root "${installed}" --core-version 0.1.0 \
    --output "${release}/${asset_name}"
done

catalog="${release}/Linnet-Data-Channel.json"
core_package="${release}/Linnet-0.1.0-arm64-Core-community-beta.pkg"
printf 'Core fixture\n' >"${core_package}"
"${tool}" build-catalog --sequence 7 --core-version 0.1.0 --output "${catalog}" \
  --core-build 8 --core-revision aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --core-package "${core_package}" \
  --chinese-pack "${release}/Linnet-Chinese.linnetpack" \
  --english-pack "${release}/Linnet-English.linnetpack" \
  --lts-pack "${release}/Linnet-LTS.linnetpack" \
  --extended-pack "${release}/Linnet-Extended.linnetpack"
"${tool}" verify-catalog --catalog "${catalog}" --core-version 0.1.0 >/dev/null
"${tool}" inspect-catalog --catalog "${catalog}" --core-version 0.1.0 \
  >"${fixture}/catalog.json"

ruby -rjson -rdigest -e '
  catalog, root = ARGV
  document = JSON.parse(File.read(catalog))
  abort unless document.keys.sort == %w[activation_sets core format sequence]
  abort unless document.fetch("sequence") == 7
  core = document.fetch("core")
  abort unless core.fetch("version") == "0.1.0" && core.fetch("build") == 8
  abort unless core.fetch("revision") == "a" * 40
  core_path = File.join(root, "Linnet-0.1.0-arm64-Core-community-beta.pkg")
  abort unless core.fetch("bytes") == File.size(core_path)
  abort unless core.fetch("sha256") == Digest::SHA256.file(core_path).hexdigest
  abort unless core.fetch("package_url") ==
    "https://github.com/Ares-X/Linnet/releases/download/core-v0.1.0/Linnet-0.1.0-arm64-Core-community-beta.pkg"
  abort unless core.fetch("release_url") ==
    "https://github.com/Ares-X/Linnet/releases/tag/core-v0.1.0"
  artifacts = document.fetch("activation_sets").flat_map { |set| set.fetch("packs") }
  artifacts.uniq { |artifact| artifact.fetch("kind") }.each do |artifact|
    path = File.join(root, File.basename(artifact.fetch("url")))
    abort unless artifact.fetch("bytes") == File.size(path)
    abort unless artifact.fetch("container_sha256") == Digest::SHA256.file(path).hexdigest
  end
' "${fixture}/catalog.json" "${release}"

core_archive="${release}/Linnet-0.1.0-arm64-Core.linnetcore"
printf 'Core App archive fixture\n' >"${core_archive}"
archive_catalog="${release}/Linnet-Data-Channel-v2.json"
"${tool}" build-catalog --sequence 7 --core-version 0.1.0 --output "${archive_catalog}" \
  --core-build 9 --core-revision bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --core-archive "${core_archive}" \
  --chinese-pack "${release}/Linnet-Chinese.linnetpack" \
  --english-pack "${release}/Linnet-English.linnetpack" \
  --lts-pack "${release}/Linnet-LTS.linnetpack" \
  --extended-pack "${release}/Linnet-Extended.linnetpack"
"${tool}" inspect-catalog --catalog "${archive_catalog}" --core-version 0.1.0 \
  >"${fixture}/catalog-v2.json"
ruby -rjson -rdigest -e '
  document = JSON.parse(File.binread(ARGV.fetch(0)))
  core = document.fetch("core")
  archive = ARGV.fetch(1)
  abort unless document.fetch("format") == 2 && core.fetch("build") == 9
  abort unless core.fetch("artifact_format") == "app-tar-gzip"
  abort unless core.fetch("artifact_url") ==
    "https://github.com/Ares-X/Linnet/releases/download/core-v0.1.0/Linnet-0.1.0-arm64-Core.linnetcore"
  abort if core.key?("package_url")
  abort unless core.fetch("bytes") == File.size(archive)
  abort unless core.fetch("sha256") == Digest::SHA256.file(archive).hexdigest
' "${fixture}/catalog-v2.json" "${core_archive}"

chmod u+w "${release}" "${release}/Linnet-English.linnetpack"
printf X | dd of="${release}/Linnet-English.linnetpack" bs=1 seek=0 conv=notrunc status=none
if ruby -rjson -rdigest -e '
  catalog, asset = ARGV
  artifact = JSON.parse(File.read(catalog)).fetch("activation_sets")
    .flat_map { |set| set.fetch("packs") }
    .find { |pack| pack.fetch("kind") == "english" }
  exit artifact.fetch("container_sha256") == Digest::SHA256.file(asset).hexdigest ? 0 : 1
' "${fixture}/catalog.json" "${release}/Linnet-English.linnetpack"; then
  echo "Catalog failed to bind exact container bytes." >&2
  exit 1
fi

echo "Linnet canonical data release: PASS"
