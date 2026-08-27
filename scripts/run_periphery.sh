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

if [[ ! -x "${periphery_binary}" ]]; then
  archive_url="https://github.com/peripheryapp/periphery/releases/download/"
  archive_url+="${periphery_version}/periphery-${periphery_version}.zip"
  download_root="$(mktemp -d "${TMPDIR:-/tmp}/linnet-periphery.XXXXXX")"
  archive_path="${download_root}/periphery.zip"
  trap 'rm -rf -- "${download_root}"' EXIT

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
