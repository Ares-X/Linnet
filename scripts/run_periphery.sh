#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${project_root}"

readonly periphery_version="3.8.0"
readonly periphery_archive_sha256="07d4e286e31dd79164df39097e0b59f533c94badbe18158464a455ea88a166d7"
readonly periphery_binary_sha256="043b2c2ff7589b87f2b30c6c9b91e8d9b8e5c6c3cd03d2e3395960e00d53e9b5"

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

periphery_root="${project_root}/build/tools/periphery-${periphery_version}"
periphery_binary="${periphery_root}/periphery"
analysis_root="$(mktemp -d /private/tmp/linnet-periphery-analysis.XXXXXX)"
derived_data="${analysis_root}/DerivedData"
products="${derived_data}/Build/Products"

remove_analysis_root() {
  [[ "${analysis_root}" == /private/tmp/linnet-periphery-analysis.* &&
    -d "${analysis_root}" && ! -L "${analysis_root}" ]] || return 1
  /bin/chmod -R u+w "${analysis_root}" 2>/dev/null || true
  /bin/rm -rf -x -- "${analysis_root}"
}

cleanup() {
  remove_analysis_root >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM HUP

if [[ -x "${periphery_binary}" ]] &&
    ! printf '%s  %s\n' "${periphery_binary_sha256}" "${periphery_binary}" |
      shasum -a 256 -c - >/dev/null 2>&1; then
  echo "Cached Periphery binary failed its pinned identity check." >&2
  exit 1
fi

if [[ ! -x "${periphery_binary}" ]]; then
  archive_url="https://github.com/peripheryapp/periphery/releases/download/"
  archive_url+="${periphery_version}/periphery-${periphery_version}.zip"
  download_root="${analysis_root}/download"
  mkdir -p "${download_root}"
  archive_path="${download_root}/periphery.zip"
  curl --fail --location --silent --show-error \
    "${archive_url}" \
    --output "${archive_path}"
  printf '%s  %s\n' "${periphery_archive_sha256}" "${archive_path}" |
    shasum -a 256 -c - >/dev/null
  mkdir -p "${periphery_root}"
  unzip -q "${archive_path}" -d "${periphery_root}"
fi

printf '%s  %s\n' "${periphery_binary_sha256}" "${periphery_binary}" |
  shasum -a 256 -c - >/dev/null

echo "Periphery: indexing Linnet and Settings"
scripts/build-linnet-app Debug "${derived_data}" -quiet \
  LINNET_BUNDLE_IDENTIFIER="${analysis_bundle_identifier}" \
  LINNET_PRODUCT_NAME="${analysis_product_name}" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  COMPILER_INDEX_STORE_ENABLE=YES INDEX_ENABLE_DATA_STORE=YES build

index_store="${derived_data}/Index.noindex/DataStore"
analysis_app="${products}/Debug/${analysis_product_name}.app"
settings_app="${products}/Debug/Settings.app"
[[ -d "${index_store}" && -f "${analysis_app}/Contents/Info.plist" &&
  -f "${settings_app}/Contents/Info.plist" ]] || {
  echo "Periphery production index is incomplete." >&2
  exit 1
}

echo "Periphery: indexing release command-line products"
swiftc_path="$(xcrun --find swiftc)"
indexed_swiftc="${swiftc_path} -index-store-path ${index_store} -module-name Squirrel"
make --no-print-directory LINNET_RUNTIME_INSPECTOR="${analysis_root}/runtime-inspector" \
  SWIFTC="${indexed_swiftc}" linnet-runtime-inspector
make --no-print-directory LINNET_PACK_TOOL="${analysis_root}/pack-tool" \
  SWIFTC="${indexed_swiftc}" linnet-pack-tool
make --no-print-directory INPUT_SOURCE_REGISTRATION_INSPECTOR="${analysis_root}/registration-inspector" \
  SWIFTC="${indexed_swiftc}" input-source-registration-inspector
indexed_swiftc="${swiftc_path} -index-store-path ${index_store} -module-name LinnetEnglishDataGenerator"
make --no-print-directory ENGLISH_DATA_GENERATOR="${analysis_root}/english-generator" \
  SWIFTC="${indexed_swiftc}" english-data-generator

generic_config="${analysis_root}/generic-project.json"
cat >"${generic_config}" <<EOF
{
  "indexstores": ["${index_store}"],
  "test_targets": [],
  "plists": [
    "${analysis_app}/Contents/Info.plist",
    "${settings_app}/Contents/Info.plist"
  ],
  "xibs": [],
  "xcdatamodels": [],
  "xcmappingmodels": []
}
EOF

echo "Periphery: analyzing every production entrypoint"
"${periphery_binary}" scan --generic-project-config "${generic_config}"

remove_analysis_root
analysis_root=""
trap - EXIT INT TERM HUP
