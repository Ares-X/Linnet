#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
export LC_ALL=C

readonly host_bundle_id='io.github.ares-x.inputmethod.Linnet'
readonly script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly metadata_path="${script_root}/candidate-app-identity.json"
readonly user_home="${HOME:-}"
readonly app_path="${user_home}/Library/Input Methods/Linnet.app"
readonly current_uid="$(/usr/bin/id -u)"

fail_identity() {
  echo "Linnet candidate App identity: $1" >&2
  exit 1
}

secure_owned_path() {
  local path="$1"
  local expected_type="$2"
  local owner mode
  case "${expected_type}" in
    directory) [[ -d "${path}" && ! -L "${path}" ]] || return 1 ;;
    file) [[ -f "${path}" && ! -L "${path}" ]] || return 1 ;;
    *) return 1 ;;
  esac
  read -r owner mode < <(/usr/bin/stat -f '%u %Lp' "${path}") || return 1
  [[ "${owner}" == "${current_uid}" ]] || return 1
  (( (8#${mode} & 0022) == 0 ))
}

read_value() {
  local path="$1"
  local key="$2"
  /usr/bin/plutil -extract "${key}" raw -o - "${path}" 2>/dev/null
}

semver_compare() {
  local actual="$1"
  local expected="$2"
  local pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$'
  local actual_major actual_minor actual_patch actual_pre
  local expected_major expected_minor expected_patch expected_pre
  local index actual_part expected_part
  local -a actual_parts expected_parts

  [[ "${actual}" =~ ${pattern} ]] || return 2
  actual_major="${BASH_REMATCH[1]}"
  actual_minor="${BASH_REMATCH[2]}"
  actual_patch="${BASH_REMATCH[3]}"
  actual_pre="${BASH_REMATCH[5]:-}"
  [[ "${expected}" =~ ${pattern} ]] || return 2
  expected_major="${BASH_REMATCH[1]}"
  expected_minor="${BASH_REMATCH[2]}"
  expected_patch="${BASH_REMATCH[3]}"
  expected_pre="${BASH_REMATCH[5]:-}"

  for index in 0 1 2; do
    actual_part=("${actual_major}" "${actual_minor}" "${actual_patch}")
    expected_part=("${expected_major}" "${expected_minor}" "${expected_patch}")
    if (( 10#${actual_part[index]} < 10#${expected_part[index]} )); then
      printf '%s\n' -1
      return 0
    fi
    if (( 10#${actual_part[index]} > 10#${expected_part[index]} )); then
      printf '%s\n' 1
      return 0
    fi
  done
  if [[ "${actual_pre}" == "${expected_pre}" ]]; then
    printf '%s\n' 0
    return 0
  fi
  if [[ -z "${actual_pre}" ]]; then
    printf '%s\n' 1
    return 0
  fi
  if [[ -z "${expected_pre}" ]]; then
    printf '%s\n' -1
    return 0
  fi

  IFS='.' read -r -a actual_parts <<<"${actual_pre}"
  IFS='.' read -r -a expected_parts <<<"${expected_pre}"
  index=0
  while (( index < ${#actual_parts[@]} || index < ${#expected_parts[@]} )); do
    if [[ "${actual_parts[index]+set}" != set ]]; then
      printf '%s\n' -1
      return 0
    fi
    if [[ "${expected_parts[index]+set}" != set ]]; then
      printf '%s\n' 1
      return 0
    fi
    actual_part="${actual_parts[index]}"
    expected_part="${expected_parts[index]}"
    if [[ "${actual_part}" != "${expected_part}" ]]; then
      if [[ "${actual_part}" =~ ^[0-9]+$ && "${expected_part}" =~ ^[0-9]+$ ]]; then
        if (( 10#${actual_part} < 10#${expected_part} )); then
          printf '%s\n' -1
        else
          printf '%s\n' 1
        fi
        return 0
      fi
      if [[ "${actual_part}" =~ ^[0-9]+$ ]]; then
        printf '%s\n' -1
        return 0
      fi
      if [[ "${expected_part}" =~ ^[0-9]+$ ]]; then
        printf '%s\n' 1
        return 0
      fi
      if [[ "${actual_part}" < "${expected_part}" ]]; then
        printf '%s\n' -1
      else
        printf '%s\n' 1
      fi
      return 0
    fi
    ((index += 1))
  done
  printf '%s\n' 0
}

[[ "$#" -eq 1 ]] || fail_identity "usage: existing | installed"
readonly verification_mode="$1"
case "${verification_mode}" in
  existing|installed) ;;
  *) fail_identity "verification mode is invalid" ;;
esac

[[ "${user_home}" == /* && "$(cd "${user_home}" 2>/dev/null && pwd -P)" == \
  "${user_home}" ]] || fail_identity "current user home is unavailable"
[[ -f "${metadata_path}" && ! -L "${metadata_path}" ]] ||
  fail_identity "candidate identity metadata is unavailable"
metadata_mode="$(/usr/bin/stat -f '%Lp' "${metadata_path}")" ||
  fail_identity "candidate identity metadata cannot be inspected"
(( (8#${metadata_mode} & 0022) == 0 )) ||
  fail_identity "candidate identity metadata is writable by another user"

expected_format="$(read_value "${metadata_path}" format)" ||
  fail_identity "candidate identity metadata is invalid"
expected_bundle_id="$(read_value "${metadata_path}" bundle_identifier)" ||
  fail_identity "candidate bundle identifier is unavailable"
expected_version="$(read_value "${metadata_path}" version)" ||
  fail_identity "candidate version is unavailable"
expected_build="$(read_value "${metadata_path}" build)" ||
  fail_identity "candidate build is unavailable"
expected_revision="$(read_value "${metadata_path}" candidate_revision)" ||
  fail_identity "candidate revision is unavailable"
expected_leaf="$(read_value "${metadata_path}" leaf_certificate_sha256 || true)"
expected_trust_model="$(read_value "${metadata_path}" trust_model || true)"
[[ "${expected_bundle_id}" == "${host_bundle_id}" &&
  "${expected_version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$ &&
  "${expected_build}" =~ ^(0|[1-9][0-9]*)$ &&
  "${expected_revision}" =~ ^[0-9a-f]{40}$ ]] ||
  fail_identity "candidate identity metadata shape is invalid"
case "${expected_format}" in
  1)
    [[ "${expected_leaf}" =~ ^[0-9a-f]{64}$ && -z "${expected_trust_model}" ]] ||
      fail_identity "candidate signing leaf is invalid"
    ;;
  2)
    [[ "${expected_trust_model}" == unsigned-community && -z "${expected_leaf}" ]] ||
      fail_identity "community trust model is invalid"
    ;;
  *) fail_identity "candidate identity metadata format is invalid" ;;
esac

if [[ ! -e "${app_path}" && ! -L "${app_path}" ]]; then
  [[ "${verification_mode}" == existing ]] && exit 0
  fail_identity "installed App is missing"
fi

for directory in \
    "${user_home}" \
    "${user_home}/Library" \
    "${user_home}/Library/Input Methods" \
    "${app_path}" \
    "${app_path}/Contents" \
    "${app_path}/Contents/Resources" \
    "${app_path}/Contents/Resources/LinnetRelease"; do
  secure_owned_path "${directory}" directory ||
    fail_identity "installed App has an unsafe bundle path"
done
readonly info_path="${app_path}/Contents/Info.plist"
readonly version_path="${app_path}/Contents/Resources/LinnetRelease/VERSION.json"
secure_owned_path "${info_path}" file && secure_owned_path "${version_path}" file ||
  fail_identity "installed App identity files are unsafe"

/usr/bin/codesign --verify --deep --strict "${app_path}" >/dev/null 2>&1 ||
  fail_identity "installed App code signature is invalid"

actual_leaf=""
if [[ "${expected_format}" == 1 ]]; then
  scratch_root="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" ||
    fail_identity "temporary root is unavailable"
  scratch="$(/usr/bin/mktemp -d "${scratch_root}/linnet-candidate-app-identity.XXXXXX")" ||
    fail_identity "temporary identity directory cannot be created"
  cleanup_identity() {
    if [[ "${scratch%/*}" == "${scratch_root}" &&
      "${scratch##*/}" == linnet-candidate-app-identity.* &&
      -d "${scratch}" && ! -L "${scratch}" ]]; then
      /bin/rm -rf -- "${scratch}"
    fi
  }
  trap cleanup_identity EXIT INT TERM HUP
  certificate_prefix="${scratch}/leaf"
  /usr/bin/codesign -d --extract-certificates="${certificate_prefix}" \
    "${app_path}" >/dev/null 2>&1 ||
    fail_identity "installed App signing certificate is unavailable"
  [[ -s "${certificate_prefix}0" && ! -L "${certificate_prefix}0" ]] ||
    fail_identity "installed App signing certificate is missing"
  actual_leaf="$(/usr/bin/shasum -a 256 "${certificate_prefix}0" | \
    /usr/bin/awk '{print $1}')" || fail_identity "installed App signing leaf cannot be read"
  [[ "${actual_leaf}" == "${expected_leaf}" ]] ||
    fail_identity "installed App uses a different signing leaf"
fi

actual_bundle_id="$(read_value "${info_path}" CFBundleIdentifier)" ||
  fail_identity "installed App bundle identifier is unavailable"
actual_version="$(read_value "${info_path}" CFBundleShortVersionString)" ||
  fail_identity "installed App version is unavailable"
actual_build="$(read_value "${info_path}" CFBundleVersion)" ||
  fail_identity "installed App build is unavailable"
[[ "${actual_bundle_id}" == "${host_bundle_id}" &&
  "${actual_build}" =~ ^(0|[1-9][0-9]*)$ ]] ||
  fail_identity "installed App bundle metadata is invalid"
version_comparison="$(semver_compare "${actual_version}" "${expected_version}")" ||
  fail_identity "installed App version is invalid"

embedded_format="$(read_value "${version_path}" format)" ||
  fail_identity "installed release metadata format is unavailable"
embedded_product="$(read_value "${version_path}" product)" ||
  fail_identity "installed release product is unavailable"
embedded_version="$(read_value "${version_path}" version)" ||
  fail_identity "installed release version is unavailable"
embedded_build="$(read_value "${version_path}" build)" ||
  fail_identity "installed release build is unavailable"
embedded_revision="$(read_value "${version_path}" source.candidate_revision)" ||
  fail_identity "installed release revision is unavailable"
embedded_hardened="$(read_value "${version_path}" \
  distribution.application_code_signature.hardened_runtime)" ||
  fail_identity "installed release runtime policy is unavailable"
[[ "${embedded_format}" == 2 && "${embedded_product}" == Linnet &&
  "${embedded_version}" == "${actual_version}" &&
  "${embedded_build}" == "${actual_build}" &&
  "${embedded_revision}" =~ ^[0-9a-f]{40}$ &&
  "${embedded_hardened}" == true ]] ||
  fail_identity "installed release metadata does not describe the finalized App"

if [[ "${expected_format}" == 1 ]]; then
  embedded_leaf="$(read_value "${version_path}" \
    distribution.application_code_signature.leaf_certificate_sha256)" ||
    fail_identity "installed release signing leaf is unavailable"
  embedded_same_leaf="$(read_value "${version_path}" \
    distribution.application_code_signature.host_settings_same_leaf)" ||
    fail_identity "installed release signing policy is unavailable"
  [[ "${embedded_leaf}" == "${actual_leaf}" && "${embedded_same_leaf}" == true ]] ||
    fail_identity "installed release signing leaf does not match"
elif [[ "${verification_mode}" == installed ]]; then
  embedded_profile="$(read_value "${version_path}" \
    distribution.application_code_signature.profile)" || exit 1
  embedded_kind="$(read_value "${version_path}" \
    distribution.application_code_signature.kind)" || exit 1
  embedded_trust="$(read_value "${version_path}" distribution.trust_model)" || exit 1
  signature_details="$(/usr/bin/codesign -dvvv "${app_path}" 2>&1)" || exit 1
  [[ "${embedded_profile}" == community-adhoc && "${embedded_kind}" == adhoc &&
    "${embedded_trust}" == manual-user-approval ]] &&
    /usr/bin/grep -Fxq 'Signature=adhoc' <<<"${signature_details}" ||
    fail_identity "installed App is not the packaged community candidate"
fi

if [[ "${verification_mode}" == installed ]]; then
  [[ "${actual_version}" == "${expected_version}" &&
    "${actual_build}" == "${expected_build}" &&
    "${embedded_revision}" == "${expected_revision}" ]] ||
    fail_identity "installed App is not the exact packaged candidate"
  exit 0
fi

if (( version_comparison > 0 )); then
  fail_identity "installed App is newer than this Core candidate"
fi
if (( 10#${actual_build} > 10#${expected_build} )); then
  fail_identity "installed App build is newer than this Core candidate"
fi
if (( version_comparison == 0 )) && [[ "${actual_build}" == "${expected_build}" &&
  "${embedded_revision}" != "${expected_revision}" ]]; then
  fail_identity "installed App revision conflicts with this Core candidate"
fi

exit 0
