#!/usr/bin/env bash

# Builds a small, canonical four-pack Runtime fixture below CFFIXED_USER_HOME
# and verifies the real embedded Settings bundle resolves only that isolated
# Runtime. Visible UI acceptance remains an installed-product UAT boundary.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

mode="${1:---verify}"
case "${mode}" in
  --verify) ;;
  *)
    echo "usage: tests/verify_visible_settings_fixture.sh [--verify]" >&2
    exit 2
    ;;
esac

fail() {
  echo "verify_visible_settings_fixture: $1" >&2
  exit 1
}

host_app="${repo_root}/build/Build/Products/Release/Linnet.app"
settings_app="${host_app}/Contents/Applications/Settings.app"
settings_executable="${settings_app}/Contents/MacOS/Settings"
[[ -d "${host_app}" && ! -L "${host_app}" ]] || fail "fresh Release Linnet.app is missing"
[[ -d "${settings_app}" && ! -L "${settings_app}" ]] || fail "embedded Settings.app is missing"
[[ -x "${settings_executable}" && ! -L "${settings_executable}" ]] ||
  fail "embedded Settings executable is missing"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "${settings_app}/Contents/Info.plist")" == \
  io.github.ares-x.inputmethod.Linnet.settings ]] || fail "unexpected Settings bundle identity"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :InputMethodConnectionName' \
  "${host_app}/Contents/Info.plist")" == \
  io.github.ares-x.inputmethod.Linnet_Connection ]] || fail "unexpected embedded Host bundle"

newest_input_epoch="$({
  find sources resources Linnet.xcodeproj -type f \
    \( -name '*.swift' -o -name '*.h' -o -name '*.m' -o -name '*.mm' -o \
       -name '*.plist' -o -name '*.xcstrings' -o -name '*.xcconfig' -o \
       -name 'project.pbxproj' -o -name 'Contents.json' \) -print0
  printf '%s\0' data/squirrel.yaml Makefile
} | xargs -0 stat -f '%m' | sort -nr | head -1)"
settings_epoch="$(stat -f '%m' "${settings_executable}")"
[[ "${settings_epoch}" -ge "${newest_input_epoch}" ]] ||
  fail "embedded Settings is older than a production build input"
cmp -s data/squirrel.yaml "${settings_app}/Contents/Resources/squirrel.yaml" ||
  fail "embedded Settings squirrel.yaml is stale"
embedded_uuid="$(dwarfdump --uuid "${settings_executable}" | awk '{print $2 ":" $3}')"
standalone_executable="${repo_root}/build/Build/Products/Release/Settings.app/Contents/MacOS/Settings"
[[ -x "${standalone_executable}" ]] || fail "standalone Settings build product is missing"
standalone_uuid="$(dwarfdump --uuid "${standalone_executable}" | awk '{print $2 ":" $3}')"
[[ "${embedded_uuid}" == "${standalone_uuid}" ]] ||
  fail "embedded Settings does not match the fresh Settings build UUID"

fixture="$(mktemp -d /tmp/linnet-visible-settings.XXXXXX)"
fixture="$(cd "${fixture}" && pwd -P)"
marker="${fixture}/.linnet-visible-settings-fixture"
: >"${marker}"

cleanup() {
  exit_code=$?
  trap - EXIT INT TERM HUP
  if [[ ("${fixture}" == /tmp/linnet-visible-settings.* || \
      "${fixture}" == /private/tmp/linnet-visible-settings.*) && -f "${marker}" ]]; then
    chmod -R u+w "${fixture}" 2>/dev/null || true
    find "${fixture}" -depth -delete 2>/dev/null || true
  fi
  exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

isolated_home="${fixture}/home"
isolated_support="${isolated_home}/Library/Application Support"
runtime_root="${isolated_support}/Linnet"
isolated_tmp="${fixture}/tmp"
mkdir -p "${isolated_home}/Library/Preferences" \
  "${isolated_home}/Library/Caches" "${isolated_home}/Library/Logs" \
  "${runtime_root}/Data/Packs" "${fixture}/sources" "${isolated_tmp}"
chmod 0700 "${isolated_home}" "${isolated_home}/Library" \
  "${isolated_home}/Library/Preferences" "${isolated_home}/Library/Caches" \
  "${isolated_home}/Library/Logs" "${isolated_support}" "${runtime_root}" \
  "${isolated_tmp}"

account_name="$(id -un)"
real_user_home="$(/usr/bin/dscl . -read "/Users/${account_name}" NFSHomeDirectory |
  awk 'NR == 1 { print $2 }')"
[[ "${real_user_home}" == /* && "${real_user_home}" != / ]] ||
  fail "could not resolve the real user-home boundary"
protected_paths=(
  "${real_user_home}/Library/Application Support/Linnet"
  "${real_user_home}/Library/Application Support/Linnet/UserData"
  "${real_user_home}/Library/Application Support/Linnet/State"
  "${real_user_home}/Library/Application Support/Linnet/Transactions"
  "${real_user_home}/Library/Application Support/hallelujah"
  "${real_user_home}/Library/Rime"
  "${real_user_home}/Library/Preferences/io.github.ares-x.inputmethod.Linnet.plist"
  "${real_user_home}/Library/Preferences/io.github.ares-x.inputmethod.Linnet.settings.plist"
)
metadata_fingerprint() {
  local path
  for path in "${protected_paths[@]}"; do
    if [[ -e "${path}" || -L "${path}" ]]; then
      stat -f '%d:%i:%p:%u:%g:%z:%m:%c:%HT' "${path}"
    else
      printf '%s\n' ABSENT
    fi
  done
}
before_fingerprint="$(metadata_fingerprint)"

sdk="$(xcrun --sdk macosx --show-sdk-path)"
release_tool="${fixture}/linnet-pack"
probe="${fixture}/visible-settings-fixture-probe"
xcrun swiftc -warnings-as-errors -sdk "${sdk}" \
  sources/LinnetPackContract.swift sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift tools/LinnetDataCatalogBuilder.swift \
  tools/LinnetPackTool.swift -o "${release_tool}"
xcrun swiftc -warnings-as-errors -sdk "${sdk}" \
  sources/LinnetPackContract.swift sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetSettings/SettingsContract.swift \
  tests/LinnetVisibleSettingsFixtureProbe.swift -o "${probe}"

pack_roots=()
for kind in chinese english lts extended; do
  source="${fixture}/sources/${kind}"
  mkdir "${source}"
  abi="$(package/data_release_metadata get config/linnet-data-releases.json \
    "${kind}" data_abi)"
  version="$(package/data_release_metadata get config/linnet-data-releases.json \
    "${kind}" version)"
  sequence="$(package/data_release_metadata get config/linnet-data-releases.json \
    "${kind}" sequence)"
  minimum_core="$(package/data_release_metadata get config/linnet-data-releases.json \
    "${kind}" min_core)"
  case "${kind}" in
    chinese)
      mkdir "${source}/build"
      for payload in default.yaml squirrel.yaml linnet_zh.schema.yaml linnet_zh.dict.yaml; do
        printf '%s\n' "${kind} ${payload} visible Settings fixture" >"${source}/${payload}"
      done
      printf '%s\n' "${kind} build visible Settings fixture" >"${source}/build/default.yaml"
      ;;
    english)
      printf '%s\n' "${kind} visible Settings fixture" >"${source}/linnet_en.schema.yaml"
      ;;
    lts)
      printf '%s\n' "${kind} visible Settings fixture" >"${source}/wanxiang-lts-zh-hans.gram"
      ;;
    extended)
      printf '%s\n' "${kind} visible Settings fixture" >"${source}/linnet_zh_full.dict.yaml"
      ;;
  esac
  content_sha="$("${release_tool}" inspect-source --kind "${kind}" --source "${source}")"
  identity="${sequence}-${version}"
  pack_root="${runtime_root}/Data/Packs/${kind}/${identity}"
  mkdir -p "${runtime_root}/Data/Packs/${kind}"
  "${release_tool}" build-installed --kind "${kind}" --version "${version}" \
    --sequence "${sequence}" --data-abi "${abi}" --min-core "${minimum_core}" \
    --content-sha256 "${content_sha}" --source "${source}" --output "${pack_root}"
  pack_roots+=("${pack_root}")
done

LINNET_RELEASE_TOOL="${release_tool}" LINNET_CORE_VERSION=0.1.1 \
  package/build_activation_profile complete "${runtime_root}" \
    "${pack_roots[0]}" "${pack_roots[1]}" "${pack_roots[2]}" "${pack_roots[3]}"

canonical_settings_identifier="io.github.ares-x.inputmethod.Linnet.settings"
canonical_host_identifier="io.github.ares-x.inputmethod.Linnet"
HOME="${isolated_home}" CFFIXED_USER_HOME="${isolated_home}" TMPDIR="${isolated_tmp}/" \
  "${probe}" "${settings_app}" "${isolated_home}" \
    "${canonical_settings_identifier}" "${canonical_host_identifier}"
[[ "$(metadata_fingerprint)" == "${before_fingerprint}" ]] ||
  fail "fixed-home probe changed a protected real-user path"

echo "Visible Settings isolated fixture dry-run: PASS"
echo "embedded_settings_uuid=${embedded_uuid}"
