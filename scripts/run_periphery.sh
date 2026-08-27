#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${project_root}"

readonly baseline_path=".periphery-baseline.json"
readonly maximum_baseline_entries=72
readonly periphery_version="3.8.0"
readonly periphery_archive_sha256="07d4e286e31dd79164df39097e0b59f533c94badbe18158464a455ea88a166d7"

read_product_setting() {
  local key="$1"
  local contract="${project_root}/config/LinnetProduct.xcconfig"
  local value
  value="$(sed -n "s/^${key} = //p" "${contract}")"
  if [[ -z "${value}" || "${value}" == *$'\n'* ]]; then
    echo "Unable to read the canonical Linnet product setting: ${key}." >&2
    return 1
  fi
  printf '%s\n' "${value}"
}

product_bundle_identifier="$(read_product_setting LINNET_BUNDLE_IDENTIFIER)"
[[ "${product_bundle_identifier}" =~ ^[A-Za-z0-9.-]+$ ]] || {
  echo "Invalid canonical Linnet bundle identifier." >&2
  exit 1
}
readonly product_bundle_identifier
readonly analysis_bundle_identifier="${product_bundle_identifier}.periphery"
product_name="$(read_product_setting LINNET_PRODUCT_NAME)"
[[ "${product_name}" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "Invalid canonical Linnet product name." >&2
  exit 1
}
readonly product_name
readonly analysis_product_name="${product_name}Periphery"

if [[ -n "${RUNNER_TEMP:-}" ]]; then
  periphery_root="${RUNNER_TEMP}/linnet-periphery-${periphery_version}"
else
  periphery_root="${project_root}/build/tools/periphery-${periphery_version}"
fi
periphery_binary="${periphery_root}/periphery"
readonly local_app_cleanup="${project_root}/scripts/unregister-local-apps"
download_root=""

periphery_products_roots() {
  local cache_root="${HOME}/Library/Caches/com.github.peripheryapp"
  local info workspace
  [[ -d "${cache_root}" ]] || return 1
  while IFS= read -r -d '' info; do
    workspace="$(plutil -extract WorkspacePath raw -o - "${info}" 2>/dev/null)" ||
      continue
    if [[ "${workspace}" == "${project_root}/Linnet.xcodeproj" ]]; then
      printf '%s/Build/Products\n' "${info%/info.plist}"
    fi
  done < <(find "${cache_root}" -mindepth 2 -maxdepth 2 -type f \
    -name info.plist -print0)
}

cleanup_local_registrations() {
  local required="${1:-false}"
  local products analysis_app settings_app embedded_settings_app retired_app
  local found=false
  while IFS= read -r products; do
    [[ -n "${products}" ]] || continue
    found=true
    analysis_app="${products}/Debug/${analysis_product_name}.app"
    settings_app="${products}/Debug/Settings.app"
    embedded_settings_app="${analysis_app}/Contents/Applications/Settings.app"
    retired_app="${products}/Debug/${product_name}.app"
    "${local_app_cleanup}" "${products}" \
      "${analysis_app}" "${settings_app}" "${embedded_settings_app}" "${retired_app}"
  done < <(periphery_products_roots)
  [[ "${found}" == true || "${required}" != true ]]
}

cleanup() {
  cleanup_local_registrations false >/dev/null 2>&1 || true
  if [[ -n "${download_root}" && -d "${download_root}" ]]; then
    rm -rf -- "${download_root}"
  fi
}
trap cleanup EXIT INT TERM HUP

if [[ ! -x "${periphery_binary}" ]]; then
  archive_url="https://github.com/peripheryapp/periphery/releases/download/"
  archive_url+="${periphery_version}/periphery-${periphery_version}.zip"
  download_root="$(mktemp -d "${TMPDIR:-/tmp}/linnet-periphery.XXXXXX")"
  archive_path="${download_root}/periphery.zip"
  curl --fail --location --silent --show-error \
    "${archive_url}" \
    --output "${archive_path}"
  printf '%s  %s\n' "${periphery_archive_sha256}" "${archive_path}" |
    shasum -a 256 -c - >/dev/null
  mkdir -p "${periphery_root}"
  unzip -q "${archive_path}" -d "${periphery_root}"
fi

baseline_entries="$(
  ruby -rjson -e '
    baseline = JSON.parse(File.read(ARGV.fetch(0)))
    puts baseline.fetch("v1").fetch("usrs").length
  ' "${baseline_path}"
)"

if (( baseline_entries > maximum_baseline_entries )); then
  echo "Periphery baseline grew from ${maximum_baseline_entries} to ${baseline_entries}." >&2
  echo "Fix new findings instead of accepting them into the baseline." >&2
  exit 1
fi

"${periphery_binary}" scan \
  --relative-results \
  --strict \
  --baseline "${baseline_path}" \
  -- LINNET_BUNDLE_IDENTIFIER="${analysis_bundle_identifier}" \
  LINNET_PRODUCT_NAME="${analysis_product_name}"

cleanup_local_registrations true
if [[ -n "${download_root}" && -d "${download_root}" ]]; then
  rm -rf -- "${download_root}"
  download_root=""
fi
trap - EXIT INT TERM HUP
