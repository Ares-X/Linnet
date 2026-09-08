#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
export LC_ALL=C

readonly host_bundle_id='io.github.ares-x.inputmethod.Linnet'
readonly script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly metadata_path="${script_root}/candidate-app-identity.json"
readonly release_tool="${script_root}/linnet-pack"
readonly user_home="${HOME:-}"
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

[[ "$#" -ge 1 ]] || fail_identity "usage: installed | packaged | staged APP"
readonly verification_mode="$1"
case "${verification_mode}" in
  installed)
    [[ "$#" -eq 1 ]] || fail_identity "unexpected App path"
    readonly app_path="${user_home}/Library/Input Methods/Linnet.app"
    ;;
  staged)
    [[ "$#" -eq 2 && ( "$2" == \
      "${user_home}/Library/Input Methods/.linnet-core."??????"/Linnet.app" || \
      "$2" == "${user_home}/Library/Application Support/Linnet/.linnet-complete/App/Linnet.payload" ) ]] ||
      fail_identity "staged App is outside the package transaction"
    readonly app_path="$2"
    secure_owned_path "${app_path%/*}" directory &&
      [[ "$(cd "${app_path%/*}" && pwd -P)" == "${app_path%/*}" ]] ||
      fail_identity "staged App parent is unsafe"
    ;;
  packaged)
    [[ "$#" -eq 1 ]] || fail_identity "unexpected packaged App path"
    readonly app_path="${script_root}/Linnet.payload"
    secure_owned_path "${script_root}" directory ||
      fail_identity "packaged App parent is unsafe"
    ;;
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
expected_profile="$(read_value "${metadata_path}" profile)" ||
  fail_identity "candidate signing profile is unavailable"
expected_leaf="$(read_value "${metadata_path}" leaf_certificate_sha256)" ||
  fail_identity "candidate signing leaf is unavailable"
expected_leaf_sha1="$(read_value "${metadata_path}" leaf_certificate_sha1)" ||
  fail_identity "candidate signing leaf requirement is unavailable"
expected_tree="$(read_value "${metadata_path}" app_tree_sha256)" ||
  fail_identity "candidate App tree identity is unavailable"
[[ "${expected_bundle_id}" == "${host_bundle_id}" &&
  "${expected_format}" == 4 &&
  "${expected_profile}" == community-cms &&
  "${expected_version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$ &&
  "${expected_build}" =~ ^(0|[1-9][0-9]*)$ &&
  "${expected_revision}" =~ ^[0-9a-f]{40}$ &&
  "${expected_leaf}" =~ ^[0-9a-f]{64}$ &&
  "${expected_leaf_sha1}" =~ ^[0-9A-F]{40}$ &&
  "${expected_tree}" =~ ^[0-9a-f]{64}$ ]] ||
  fail_identity "candidate identity metadata shape is invalid"

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

actual_bundle_id="$(read_value "${info_path}" CFBundleIdentifier)" ||
  fail_identity "installed App bundle identifier is unavailable"
actual_version="$(read_value "${info_path}" CFBundleShortVersionString)" ||
  fail_identity "installed App version is unavailable"
actual_build="$(read_value "${info_path}" CFBundleVersion)" ||
  fail_identity "installed App build is unavailable"
actual_profile="$(read_value "${info_path}" LinnetCodeSigningProfile)" ||
  fail_identity "installed App signing profile is unavailable"
[[ "${actual_bundle_id}" == "${host_bundle_id}" &&
  "${actual_build}" =~ ^(0|[1-9][0-9]*)$ ]] ||
  fail_identity "installed App bundle metadata is invalid"
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
embedded_profile="$(read_value "${version_path}" \
  distribution.application_code_signature.profile)" ||
  fail_identity "installed release signing profile is unavailable"
embedded_kind="$(read_value "${version_path}" \
  distribution.application_code_signature.kind)" ||
  fail_identity "installed release signing kind is unavailable"
embedded_artifact_scope="$(read_value "${version_path}" \
  distribution.artifact_scope)" ||
  fail_identity "installed release artifact scope is unavailable"
embedded_notarized="$(read_value "${version_path}" distribution.notarized)" ||
  fail_identity "installed release notarization policy is unavailable"
embedded_publication="$(read_value "${version_path}" \
  distribution.publication_eligible)" ||
  fail_identity "installed release publication policy is unavailable"
embedded_trust="$(read_value "${version_path}" distribution.trust_model)" ||
  fail_identity "installed release trust model is unavailable"
[[ "${embedded_format}" == 2 && "${embedded_product}" == Linnet &&
  "${embedded_version}" == "${actual_version}" &&
  "${embedded_build}" == "${actual_build}" &&
  "${embedded_revision}" =~ ^[0-9a-f]{40}$ &&
  "${embedded_hardened}" == true &&
  "${embedded_artifact_scope}" == public-community &&
  "${embedded_notarized}" == false &&
  "${embedded_publication}" == true &&
  "${embedded_trust}" == manual-user-approval ]] ||
  fail_identity "installed release metadata does not describe the finalized App"

case "${embedded_profile}" in
community-cms)
  [[ "${actual_profile}" == community-cms &&
    "${embedded_kind}" == external-cms ]] ||
    fail_identity "installed App is not a community CMS release"
  # Publication verifies the complete CMS chain before packaging. Installation
  # must not require the maintainer certificate in the user's trust store; it
  # binds the packaged bytes to the same fixed leaf through the designated
  # requirement, verifies the installed code integrity, then verifies the exact
  # target tree for packaged, staged and post-install candidate modes below.
  expected_requirement="designated => identifier \"${host_bundle_id}\" and certificate leaf = H\"$(
    /usr/bin/tr '[:upper:]' '[:lower:]' <<<"${expected_leaf_sha1}")\""
  actual_requirement="$(/usr/bin/codesign -d -r- "${app_path}" 2>&1 |
    /usr/bin/grep '^designated => ')" ||
    fail_identity "installed App signing requirement is unavailable"
  [[ "${actual_requirement}" == "${expected_requirement}" ]] ||
    fail_identity "installed App signing requirement does not match"
  /usr/bin/codesign --verify --deep --strict "${app_path}" >/dev/null 2>&1 ||
    fail_identity "installed App code signature is invalid"
  embedded_leaf="$(read_value "${version_path}" \
    distribution.application_code_signature.leaf_certificate_sha256)" ||
    fail_identity "installed release signing leaf is unavailable"
  embedded_same_leaf="$(read_value "${version_path}" \
    distribution.application_code_signature.host_settings_same_leaf)" ||
    fail_identity "installed release signing policy is unavailable"
  [[ "${embedded_leaf}" == "${expected_leaf}" &&
    "${embedded_same_leaf}" == true ]] ||
    fail_identity "installed release signing leaf does not match"
  ;;
*)
  fail_identity "installed App signing history is not admitted"
  ;;
esac

secure_owned_path "${release_tool}" file && [[ -x "${release_tool}" ]] ||
  fail_identity "candidate tree verifier is unavailable or unsafe"
actual_tree="$("${release_tool}" tree-digest --root "${app_path}")" ||
  fail_identity "candidate App tree cannot be verified"
[[ "${actual_tree}" == "${expected_tree}" &&
  "${actual_version}" == "${expected_version}" &&
  "${actual_build}" == "${expected_build}" &&
  "${embedded_revision}" == "${expected_revision}" ]] ||
  fail_identity "App is not the exact packaged candidate"
exit 0
