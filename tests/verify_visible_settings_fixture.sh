#!/usr/bin/env bash

# Builds one canonical four-pack Runtime fixture below CFFIXED_USER_HOME.
# --verify checks the real embedded Settings bundle against a disposable home;
# --ui-test runs SettingsUITests with a separate UAT bundle identity and the
# one fixed home required by the UI-test contract. Installed-product UAT is a
# later artifact boundary and is not claimed by either mode.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

[[ "$#" -le 2 ]] || {
  echo "usage: tests/verify_visible_settings_fixture.sh [--verify|--ui-test [test-name,...]]" >&2
  exit 2
}
mode="${1:---verify}"
ui_test_name="${2:-}"
run_ui_tests=false
case "${mode}" in
  --verify)
    [[ -z "${ui_test_name}" ]] || {
      echo "--verify does not accept a UI test name" >&2
      exit 2
    }
    ;;
  --ui-test) run_ui_tests=true ;;
  *)
    echo "usage: tests/verify_visible_settings_fixture.sh [--verify|--ui-test [test-name,...]]" >&2
    exit 2
    ;;
esac

fail() {
  echo "verify_visible_settings_fixture: $1" >&2
  exit 1
}

if [[ "${run_ui_tests}" == true && "${CI:-}" != true &&
      "${LINNET_ISOLATED_UI_TEST_DESKTOP:-}" != 1 ]]; then
  fail "Settings UI tests require a CI runner or an explicitly isolated macOS desktop"
fi
if [[ "${run_ui_tests}" == true ]]; then
  developer_mode_status="$(DevToolsSecurity -status 2>&1 || true)"
  [[ "${developer_mode_status}" == *"enabled"* ]] ||
    fail "Settings UI tests require macOS Developer Mode; run DevToolsSecurity -enable first"
fi

uat_host_identifier="io.github.ares-x.inputmethod.Linnet.settings-ui-uat"
uat_settings_identifier="${uat_host_identifier}.settings"
uat_test_identifier="${uat_host_identifier}.SettingsUITests"
uat_home="/private/tmp/linnet-settings-ui-uat-active-$(id -u)"
uat_home_marker="${uat_home}/.linnet-settings-ui-uat-fixture"
xcode_user_name="$(id -un)"
settings_ui_source="tests/SettingsUITests/SettingsUITests.swift"
focused_ui_tests=()
if [[ -n "${ui_test_name}" ]]; then
  [[ "${ui_test_name}" =~ ^test[A-Za-z0-9]+(,test[A-Za-z0-9]+)*$ ]] ||
    fail "invalid Settings UI test name: ${ui_test_name}"
  IFS=, read -r -a selected_tests <<<"${ui_test_name}"
  for selected_test in "${selected_tests[@]}"; do
    rg -q "^[[:space:]]*func ${selected_test}\\(\\) (async )?throws \\{" \
      "${settings_ui_source}" || fail "unknown Settings UI test: ${selected_test}"
    focused_ui_tests+=("-only-testing:SettingsUITests/SettingsUITests/${selected_test}")
  done
fi
xcode_generated_paths=(
  "${repo_root}/Linnet.xcodeproj/project.xcworkspace/xcuserdata/${xcode_user_name}.xcuserdatad/UserInterfaceState.xcuserstate"
  "${repo_root}/Linnet.xcodeproj/xcuserdata/${xcode_user_name}.xcuserdatad/xcschemes/xcschememanagement.plist"
)

scroll_owners="$(awk '
  /func [A-Za-z0-9_]+\(/ {
    owner = $0
    sub(/^.*func /, "", owner)
    sub(/\(.*/, "", owner)
  }
  /\.scroll\(/ { print owner }
' "${settings_ui_source}" | sort -u)"
[[ "${scroll_owners}" == reveal ]] ||
  fail "SettingsUITests must keep reveal as its only manual scroll owner"
if /usr/bin/grep -Eq \
  'func visibleButton|descendants\(matching: \.button\)\[option\]' \
  "${settings_ui_source}"; then
  fail "SettingsUITests restored a retired scroll helper or segmented fallback"
fi
rg -Fq 'continueAfterFailure = false' "${settings_ui_source}" ||
  fail "Settings UI tests must stop interactions inside a failed test"
if rg -n 'suiteHasFailed|XCTSkipIf' "${settings_ui_source}"; then
  fail "one failed Settings test must not skip independent UI workflows"
fi
rg -Fq 'terminate_fixture_apps' "$0" ||
  fail "Settings UI cleanup no longer terminates its exact fixture processes"
if rg -Fq 'configuration.environment' "${settings_ui_source}"; then
  fail "sandboxed XCTRunner cannot own the Settings launch environment"
fi

if [[ "${run_ui_tests}" == true ]] &&
  { [[ -e "${uat_home}" ]] || [[ -L "${uat_home}" ]]; }; then
  fail "Settings UI fixed home already exists: ${uat_home}"
fi
if [[ "${run_ui_tests}" == true ]] &&
  ! /usr/bin/grep -Fq "\"${uat_settings_identifier}\"" \
    "${settings_ui_source}"; then
  fail "SettingsUITests does not require the isolated UAT preference domain"
fi
if [[ "${run_ui_tests}" == true ]]; then
  # Results outlive disposable apps so a failed run retains its actual UI
  # evidence. Each invocation owns a new directory, never an older result.
  mkdir -p "${repo_root}/build/settings-ui-results"
  results="$(mktemp -d "${repo_root}/build/settings-ui-results/run.XXXXXX")"
  for generated_path in "${xcode_generated_paths[@]}"; do
    [[ ! -e "${generated_path}" && ! -L "${generated_path}" ]] ||
      fail "refusing to overwrite pre-existing Xcode user state: ${generated_path}"
  done
fi

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

cmp -s data/squirrel.yaml "${settings_app}/Contents/Resources/squirrel.yaml" ||
  fail "embedded Settings squirrel.yaml is stale"
cmp -s data/squirrel.yaml "${host_app}/Contents/Resources/squirrel.yaml" ||
  fail "Core and Settings must ship the same canonical UI configuration"
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
launch_services_register='/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister'

real_user_home=""
before_fingerprint=""
before_content_fingerprint=""
uat_home_created=false
fixture_settings_stopped=true
ui_test_completed=false

terminate_fixture_apps() {
  local executable process_id remaining=0
  for executable in \
      "${fixture}/DerivedData/Build/Products/Debug/Linnet.app/Contents/Applications/Settings.app/Contents/MacOS/Settings" \
      "${fixture}/DerivedData/Build/Products/Debug/ForegroundFixture.app/Contents/MacOS/ForegroundFixture"; do
    while read -r process_id; do
      [[ -n "${process_id}" ]] || continue
      /bin/kill -TERM "${process_id}" 2>/dev/null || true
    done < <(/bin/ps -axo pid=,command= | /usr/bin/awk -v executable="${executable}" \
      '$2 == executable { print $1 }')
    for _ in {1..50}; do
      remaining="$(/bin/ps -axo command= | /usr/bin/awk -v executable="${executable}" \
        '$1 == executable { count += 1 } END { print count + 0 }')"
      [[ "${remaining}" -eq 0 ]] && break
      /bin/sleep 0.1
    done
    [[ "${remaining}" -eq 0 ]] || return 1
  done
  return 0
}

unregister_fixture_apps() {
  local products_root="${fixture}/DerivedData/Build/Products"
  local app_path
  [[ -x "${launch_services_register}" ]] || return 1
  [[ "${products_root}" == "${fixture}/DerivedData/Build/Products" &&
    ( ! -e "${products_root}" || ( -d "${products_root}" && ! -L "${products_root}" ) ) ]] ||
    return 1
  [[ -d "${products_root}" ]] || return 0

  while IFS= read -r -d '' app_path; do
    "${launch_services_register}" -u "${app_path}" >/dev/null 2>&1 || true
  done < <(find "${products_root}" -depth -type d -name '*.app' -print0)

  ! "${launch_services_register}" -dump 2>/dev/null |
    /usr/bin/grep -F "${products_root}/" >/dev/null
}

cleanup_uat_preference_domains() {
  local domain preference_file
  for domain in "${uat_host_identifier}" "${uat_settings_identifier}" \
    "${uat_test_identifier}" "${uat_host_identifier}.foreground"; do
    case "${domain}" in
      "${uat_host_identifier}"|"${uat_settings_identifier}"|"${uat_test_identifier}"|"${uat_host_identifier}.foreground") ;;
      *) return 1 ;;
    esac
    /usr/bin/defaults delete "${domain}" >/dev/null 2>&1 || true
    if /usr/bin/defaults read "${domain}" >/dev/null 2>&1; then
      return 1
    fi
    if [[ -n "${real_user_home}" ]]; then
      preference_file="${real_user_home}/Library/Preferences/${domain}.plist"
      if [[ -L "${preference_file}" || \
          (-e "${preference_file}" && ! -f "${preference_file}") ]]; then
        return 1
      fi
      if [[ -f "${preference_file}" ]]; then
        [[ "$(stat -f '%u:%l' "${preference_file}")" == "$(id -u):1" ]] || return 1
        /bin/rm -f "${preference_file}" || return 1
      fi
      [[ ! -e "${preference_file}" && ! -L "${preference_file}" ]] || return 1
    fi
  done
}

cleanup() {
  exit_code=$?
  trap - EXIT INT TERM HUP
  if [[ "${run_ui_tests}" == true ]]; then
    if [[ "${ui_test_completed}" != true && "${exit_code}" -eq 0 ]]; then
      echo "verify_visible_settings_fixture: UI suite did not reach its completed boundary" >&2
      exit_code=1
    fi
    if ! terminate_fixture_apps; then
      echo "verify_visible_settings_fixture: an exact fixture process did not stop" >&2
      fixture_settings_stopped=false
      exit_code=1
    fi
    if ! unregister_fixture_apps; then
      echo "verify_visible_settings_fixture: fixture Apps remain registered with LaunchServices" >&2
      exit_code=1
    fi
    if ! cleanup_uat_preference_domains; then
      echo "verify_visible_settings_fixture: failed to remove an exact UAT preference domain" >&2
      exit_code=1
    fi
    if [[ -n "${before_fingerprint}" && -n "${before_content_fingerprint}" ]]; then
      after_fingerprint="$(metadata_fingerprint)"
      after_content_fingerprint="$(content_fingerprint)"
      if [[ "${after_fingerprint}" != "${before_fingerprint}" ]]; then
        echo "verify_visible_settings_fixture: protected path metadata changed:" >&2
        diff -u \
          <(printf '%s\n' "${before_fingerprint}") \
          <(printf '%s\n' "${after_fingerprint}") >&2 || true
        exit_code=1
      fi
      if [[ "${after_content_fingerprint}" != "${before_content_fingerprint}" ]]; then
        echo "verify_visible_settings_fixture: protected Settings bytes changed" >&2
        exit_code=1
      fi
    fi
    if [[ "${uat_home_created}" == true ]]; then
      if [[ "${uat_home}" == "/private/tmp/linnet-settings-ui-uat-active-$(id -u)" && \
          -d "${uat_home}" && ! -L "${uat_home}" && \
          -f "${uat_home_marker}" && ! -L "${uat_home_marker}" && \
          "$(stat -f '%u' "${uat_home}")" == "$(id -u)" ]]; then
        chmod -R u+w "${uat_home}" 2>/dev/null || true
        find "${uat_home}" -depth -delete 2>/dev/null || true
        if [[ -e "${uat_home}" || -L "${uat_home}" ]]; then
          echo "verify_visible_settings_fixture: Settings UI fixed home cleanup was incomplete" >&2
          exit_code=1
        fi
      else
        echo "verify_visible_settings_fixture: refusing unsafe UI fixture cleanup" >&2
        exit_code=1
      fi
    fi
    for generated_path in "${xcode_generated_paths[@]}"; do
      if [[ -e "${generated_path}" || -L "${generated_path}" ]]; then
        if [[ -f "${generated_path}" && ! -L "${generated_path}" &&
            "$(stat -f '%u' "${generated_path}")" == "$(id -u)" ]]; then
          find "${generated_path}" -type f -delete 2>/dev/null || exit_code=1
        else
          echo "verify_visible_settings_fixture: refusing unsafe Xcode user-state cleanup" >&2
          exit_code=1
        fi
      fi
    done
    find "${repo_root}/Linnet.xcodeproj/project.xcworkspace/xcuserdata" \
      "${repo_root}/Linnet.xcodeproj/xcuserdata" \
      -depth -type d -empty -delete 2>/dev/null || true
  fi
  if [[ "${fixture_settings_stopped}" == true && \
      ("${fixture}" == /tmp/linnet-visible-settings.* || \
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

if [[ "${run_ui_tests}" == true ]]; then
  mkdir -m 0700 "${uat_home}" || fail "could not create the Settings UI fixed home"
  uat_home_created=true
  : >"${uat_home_marker}"
  chmod 0600 "${uat_home_marker}"
  [[ "$(cd "${uat_home}" && pwd -P)" == "${uat_home}" ]] ||
    fail "Settings UI fixed home did not resolve to its exact path"
  isolated_home="${uat_home}"
else
  isolated_home="${fixture}/home"
fi
isolated_support="${isolated_home}/Library/Application Support"
runtime_root="${isolated_support}/Linnet"
isolated_tmp="${fixture}/tmp"
mkdir -p "${isolated_home}/Library/Preferences" \
  "${isolated_home}/Library/Caches" "${isolated_home}/Library/Logs" \
  "${runtime_root}/Data/Packs" "${runtime_root}/UserData" \
  "${fixture}/sources" "${isolated_tmp}"
chmod 0700 "${isolated_home}" "${isolated_home}/Library" \
  "${isolated_home}/Library/Preferences" "${isolated_home}/Library/Caches" \
  "${isolated_home}/Library/Logs" "${isolated_support}" "${runtime_root}" \
  "${isolated_tmp}"
if [[ "${run_ui_tests}" == true ]]; then
  # The document decoder owns every default; an empty object is its minimal
  # valid persisted form and avoids a second copy of the schema in this runner.
  printf '{}\n' >"${runtime_root}/UserData/linnet_settings.json"
  chmod 0600 "${runtime_root}/UserData/linnet_settings.json"
fi

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
protected_content_paths=(
  "${real_user_home}/Library/Preferences/io.github.ares-x.inputmethod.Linnet.plist"
  "${real_user_home}/Library/Preferences/io.github.ares-x.inputmethod.Linnet.settings.plist"
  "${real_user_home}/Library/Application Support/Linnet/UserData/linnet_settings.json"
  "${real_user_home}/Library/Application Support/Linnet/UserData/linnet_custom_words.txt"
  "${real_user_home}/Library/Application Support/Linnet/UserData/linnet_text_expander.txt"
  "${real_user_home}/Library/Application Support/Linnet/UserData/linnet_user.custom.yaml"
  "${real_user_home}/Library/Application Support/Linnet/UserData/linnet_user.yaml"
  "${real_user_home}/Library/Application Support/Linnet/UserData/default.custom.yaml"
  "${real_user_home}/Library/Application Support/Linnet/UserData/squirrel.custom.yaml"
  "${real_user_home}/Library/Application Support/Linnet/UserData/linnet_en.custom.yaml"
  "${real_user_home}/Library/Application Support/Linnet/UserData/linnet_zh_pinyin.custom.yaml"
  "${real_user_home}/Library/Application Support/Linnet/UserData/linnet_zh.custom.yaml"
  "${real_user_home}/Library/Application Support/Linnet/UserData/linnet_zh_flypy.custom.yaml"
  "${real_user_home}/Library/Application Support/Linnet/UserData/linnet_zh_mspy.custom.yaml"
  "${real_user_home}/Library/Application Support/Linnet/UserData/linnet_zh_sogou.custom.yaml"
  "${real_user_home}/Library/Application Support/Linnet/UserData/linnet_zh_abc.custom.yaml"
  "${real_user_home}/Library/Application Support/Linnet/UserData/linnet_zh_ziguang.custom.yaml"
  "${real_user_home}/Library/Application Support/Linnet/UserData/linnet_zh_jiajia.custom.yaml"
  "${real_user_home}/Library/Application Support/Linnet/State/active.json"
  "${real_user_home}/Library/Application Support/Linnet/Runtime/Active/activation.json"
)
metadata_fingerprint() {
  local path
  for path in "${protected_paths[@]}"; do
    printf '%s\t' "${path}"
    if [[ -e "${path}" || -L "${path}" ]]; then
      stat -f '%d:%i:%p:%u:%g:%z:%m:%c:%HT' "${path}"
    else
      printf '%s\n' ABSENT
    fi
  done
}
content_fingerprint() {
  local path target
  {
    for path in "${protected_content_paths[@]}"; do
      printf '%s\0' "${path}"
      if [[ -L "${path}" ]]; then
        target="$(readlink "${path}")" || return 1
        printf 'SYMLINK\0%s\0' "${target}"
        if [[ -f "${path}" ]]; then
          /usr/bin/shasum -a 256 "${path}" || return 1
        elif [[ -e "${path}" ]]; then
          stat -f 'TARGET:%HT' "${path}" || return 1
        else
          printf 'DANGLING\0'
        fi
      elif [[ -f "${path}" ]]; then
        printf 'FILE\0'
        /usr/bin/shasum -a 256 "${path}" || return 1
      elif [[ -e "${path}" ]]; then
        stat -f 'OTHER:%HT' "${path}" || return 1
      else
        printf 'ABSENT\0'
      fi
    done
  } | /usr/bin/shasum -a 256 | awk '{print $1}'
}
if [[ "${run_ui_tests}" == true ]] && ! cleanup_uat_preference_domains; then
  fail "could not clear the exact UAT preference domains"
fi
before_fingerprint="$(metadata_fingerprint)"
if ! before_content_fingerprint="$(content_fingerprint)"; then
  fail "could not hash the protected real-user Settings state"
fi

sdk="$(xcrun --sdk macosx --show-sdk-path)"
release_tool="${repo_root}/build/linnet-pack"
probe="${fixture}/visible-settings-fixture-probe"
make -C "${repo_root}" --no-print-directory linnet-pack-tool
xcrun swiftc -warnings-as-errors -sdk "${sdk}" \
  sources/LinnetPackContract.swift sources/LinnetDataChannel.swift \
  sources/LinnetDataRegistry.swift sources/LinnetDataRegistryTransactions.swift sources/LinnetDataRegistryStorage.swift sources/LinnetSettings/SettingsContract.swift \
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
      for payload in default.yaml linnet_zh.schema.yaml linnet_zh.dict.yaml; do
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

LINNET_RELEASE_TOOL="${release_tool}" \
  LINNET_CORE_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "${host_app}/Contents/Info.plist")" \
  package/build_activation_profile complete "${runtime_root}" \
    "${pack_roots[0]}" "${pack_roots[1]}" "${pack_roots[2]}" "${pack_roots[3]}"

canonical_settings_identifier="io.github.ares-x.inputmethod.Linnet.settings"
canonical_host_identifier="io.github.ares-x.inputmethod.Linnet"
HOME="${isolated_home}" CFFIXED_USER_HOME="${isolated_home}" TMPDIR="${isolated_tmp}/" \
  "${probe}" "${settings_app}" "${isolated_home}" \
    "${canonical_settings_identifier}" "${canonical_host_identifier}"
[[ "$(metadata_fingerprint)" == "${before_fingerprint}" ]] ||
  fail "fixed-home probe changed a protected real-user path"
[[ "$(content_fingerprint)" == "${before_content_fingerprint}" ]] ||
  fail "fixed-home probe changed protected real-user Settings content"

if [[ "${run_ui_tests}" == true ]]; then
  foreground_app="${fixture}/DerivedData/Build/Products/Debug/ForegroundFixture.app"
  mkdir -p "${foreground_app}/Contents/MacOS"
  cp tests/SettingsUITests/ForegroundFixture-Info.plist "${foreground_app}/Contents/Info.plist"
  xcrun swiftc -warnings-as-errors -parse-as-library -target arm64-apple-macos13.0 \
    tests/SettingsUITests/ForegroundFixture.swift \
    -o "${foreground_app}/Contents/MacOS/ForegroundFixture"
  codesign --sign - "${foreground_app}"
  if [[ -n "${ui_test_name}" ]]; then
    echo "Visible Settings focused UI test: ${ui_test_name}"
  else
    echo "Visible Settings full UI suite: stop each failed test, report all workflows"
  fi
  xcodebuild_args=(-project Linnet.xcodeproj -scheme SettingsUITests \
    -configuration Debug -destination 'platform=macOS' \
    -derivedDataPath "${fixture}/DerivedData" \
    -resultBundlePath "${results}/SettingsUITests.xcresult" \
    LINNET_BUNDLE_IDENTIFIER="${uat_host_identifier}" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY="-")
  [[ -z "${ui_test_name}" ]] || xcodebuild_args+=("${focused_ui_tests[@]}")
  xcodebuild_args+=(test)
  xcodebuild "${xcodebuild_args[@]}"
  [[ "$(metadata_fingerprint)" == "${before_fingerprint}" ]] ||
    fail "Settings UI tests changed a protected real-user path"
  [[ "$(content_fingerprint)" == "${before_content_fingerprint}" ]] ||
    fail "Settings UI tests changed protected real-user Settings content"
  ui_test_completed=true
  echo "Visible Settings isolated UI suite: PASS"
  echo "uat_bundle_identifier=${uat_settings_identifier}"
  exit 0
fi

echo "Visible Settings isolated fixture dry-run: PASS"
echo "embedded_settings_uuid=${embedded_uuid}"
