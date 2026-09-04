#!/usr/bin/env bash

set -euo pipefail
trap 'echo "Package lifecycle failed at line ${LINENO}." >&2' ERR

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

test_root="$(mktemp -d /tmp/linnet-package-lifecycle.XXXXXX)"
test_root="$(cd "${test_root}" && pwd -P)"
cleanup() {
  if [[ ( "${test_root%/*}" == /tmp || "${test_root%/*}" == /private/tmp ) &&
    "${test_root##*/}" == linnet-package-lifecycle.* ]]; then
    /bin/chmod -R u+w "${test_root}" 2>/dev/null || true
    /bin/rm -rf -- "${test_root}"
  fi
}
trap cleanup EXIT

scripts_root="${test_root}/scripts"
user_home="${test_root}/home"
mkdir -p "${scripts_root}" "${user_home}/Library"
delta_tool="${repo_root}/build/linnet-pack"
[[ -x "${delta_tool}" ]] || {
  echo "Canonical pack CLI must be built before lifecycle tests." >&2
  exit 1
}
cp -X "${delta_tool}" "${scripts_root}/linnet-pack"
chmod 0755 "${scripts_root}/linnet-pack"
[[ -x package/installer-scripts/candidate-app-identity.sh ]] || {
  echo "Package lifecycle has no candidate App identity owner." >&2
  exit 1
}
if rg -n '/usr/bin/osascript|quit-applications-clean\.jxa' \
    package/core-installer-scripts/preinstall package/make_package \
    package/verify_package; then
  echo "Core Installer regained an application-quiescence owner." >&2
  exit 1
fi
cp package/core-installer-scripts/preinstall "${scripts_root}/preinstall"
cp package/installer-scripts/postinstall "${scripts_root}/postinstall"
cp package/installer-scripts/postinstall "${scripts_root}/lifecycle-postinstall"
cp package/installer-scripts/complete-postinstall "${scripts_root}/complete-postinstall"
cp package/installer-scripts/candidate-app-identity.sh \
  "${scripts_root}/candidate-app-identity.sh"
cat >"${scripts_root}/input-source-registration-inspector" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 1 && "$1" == io.github.ares-x.inputmethod.Linnet ]]
if [[ -f "${HOME}/.linnet-test-input-source-authorization-requested" ]]; then
  printf 'registered:enablement-required:path-unknown\n'
else
  printf '%s\n' "${LINNET_FAKE_REGISTRATION_STATE:-registered:enabled-observation:selectable:path-unknown}"
fi
SH
cat >"${scripts_root}/linnet-runtime-inspector" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 3 && "$1" == probe &&
  "$2" == 0.1.0 && "$3" == "${HOME}/Library/Application Support" ]]
[[ -z "${LINNET_FAKE_RUNTIME_LOG:-}" ]] || printf '%s\n' "$*" >>"${LINNET_FAKE_RUNTIME_LOG}"
if [[ -n "${LINNET_FAKE_RUNTIME_BUILD_LOG:-}" ]]; then
  /usr/bin/plutil -extract CFBundleVersion raw -o - \
    "${HOME}/Library/Input Methods/Linnet.app/Contents/Info.plist" >>"${LINNET_FAKE_RUNTIME_BUILD_LOG}"
fi
case "${LINNET_FAKE_RUNTIME_STATE:-auto}" in
  healthy)
    [[ -f "$3/Linnet/Runtime/Active/activation.json" ]] || exit 1
    printf 'healthy\n'
    ;;
  missing)
    [[ ! -e "$3/Linnet/Data" && ! -L "$3/Linnet/Data" && \
      ! -e "$3/Linnet/Runtime" && ! -L "$3/Linnet/Runtime" ]] || exit 1
    printf 'missing\n'
    ;;
  missing-then-invalid)
    [[ ! -e "$3/Linnet/Data" && ! -L "$3/Linnet/Data" && \
      ! -e "$3/Linnet/Runtime" && ! -L "$3/Linnet/Runtime" ]] || exit 1
    printf 'missing\n'
    ;;
  invalid)
    exit 1
    ;;
  target-invalid)
    [[ -f "$3/Linnet/Runtime/Active/activation.json" ]]
    installed_build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - \
      "${HOME}/Library/Input Methods/Linnet.app/Contents/Info.plist")"
    [[ "${installed_build}" != "${LINNET_FAKE_RUNTIME_TARGET_BUILD}" ]] || exit 1
    printf 'healthy\n'
    ;;
  auto)
    if [[ -f "$3/Linnet/Runtime/Active/activation.json" ]]; then
      printf 'healthy\n'
    elif [[ ! -e "$3/Linnet/Data" && ! -L "$3/Linnet/Data" && \
      ! -e "$3/Linnet/Runtime" && ! -L "$3/Linnet/Runtime" ]]; then
      printf 'missing\n'
    else
      exit 1
    fi
    ;;
  *) exit 1 ;;
esac
SH
chmod 755 "${scripts_root}/input-source-registration-inspector" \
  "${scripts_root}/linnet-runtime-inspector"

# A Core update must not replace the live InputMethodKit server. Existing
# client applications retain per-server connections and are not required to
# reconnect merely because package bytes changed on disk. Complete owns first
# registration; uninstall has no termination owner and requires exact product
# processes to be absent before mutation.
if rg -Fq -- '--quit-host-clean' package/installer-scripts/postinstall ||
    rg -Fq '/usr/bin/open' package/installer-scripts/postinstall ||
    rg -Fq '<app id="io.github.ares-x.inputmethod.Linnet"/>' \
      package/Distribution-Core.xml ||
    rg -Fq 'io.github.ares-x.inputmethod.Linnet >/dev/null' \
      package/core-installer-scripts/preinstall; then
  echo "Core update can launch, hide, or terminate the live InputMethodKit server." >&2
  exit 1
fi
fake_codesign="${scripts_root}/fake-codesign"
cat >"${fake_codesign}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
target=
for argument in "$@"; do
  target="${argument}"
done
fixture="${target}/Contents/Resources/LinnetLifecycleFixture"
kind="$(cat "${fixture}/signature-kind")"
case " $* " in
  *' --verify '*)
    [[ ! -e "${target}/Contents/unexpected" ]] || exit 1
    case "${kind}" in
      legacy-community-adhoc|community-cms) ;;
      *) exit 1 ;;
    esac
    ;;
  *' -dvvv '*)
    case "${kind}" in
      legacy-community-adhoc) printf '%s\n' 'Signature=adhoc' ;;
      community-cms|wrong-community-cms|unknown-cms)
        printf '%s\n' 'Authority=Linnet Community CMS fixture' \
          'Signature=size=384' 'TeamIdentifier=not set'
        ;;
      *) exit 1 ;;
    esac
    ;;
  *' -r- '*)
    case "${kind}" in
      community-cms|unknown-cms)
        leaf="${fixture}/certificate"
        ;;
      wrong-community-cms)
        leaf="${fixture}/wrong-certificate"
        ;;
      *) exit 1 ;;
    esac
    sha1="$(/usr/bin/shasum "${leaf}" | /usr/bin/awk '{print $1}')"
    printf '%s\n' "designated => identifier \"io.github.ares-x.inputmethod.Linnet\" and certificate leaf = H\"${sha1}\""
    ;;
  *) exit 1 ;;
esac
SH
chmod 755 "${fake_codesign}"
# Production has no codesign override. This isolated helper copy supplies exact
# deterministic CMS/ad-hoc identities without importing a test Keychain.
sed -i '' "s#/usr/bin/codesign#${fake_codesign}#g" \
  "${scripts_root}/candidate-app-identity.sh"
# The production script has no executable override. This isolated test copy
# redirects only the final Host CLI calls after the real finalized App has passed
# the package-owned identity gate.
sed -i '' 's#^executable="${app_path}/Contents/MacOS/Linnet"$#executable="${LINNET_TEST_EXECUTABLE:-${HOME}/fake-Linnet}"#' \
  "${scripts_root}/postinstall" "${scripts_root}/lifecycle-postinstall" \
  "${scripts_root}/complete-postinstall"
printf '0.1.0\n' >"${scripts_root}/candidate-core-version"

candidate_fixture="${test_root}/fixed-community-cms/Linnet.app"
candidate_fixture_available=true
candidate_version=0.1.13
candidate_build=31
candidate_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
candidate_leaf=553fb445ae10b48c395ee01aad3630f03c05d3da40f84db89b97d91039e72aff
wrong_candidate_leaf=bb696adf3a500641c2b5fef7af6436a10ed7a4552302d5d77066fd44099d48f0
candidate_identity_format=4
candidate_profile=community-cms
candidate_trust_model=
candidate_version_file="${candidate_fixture}/Contents/Resources/LinnetRelease/VERSION.json"
mkdir -p "${candidate_fixture}/Contents/MacOS" \
  "${candidate_fixture}/Contents/Resources/LinnetRelease" \
  "${candidate_fixture}/Contents/Resources/LinnetLifecycleFixture"
cat >"${candidate_fixture}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Linnet</string>
<key>CFBundleIdentifier</key><string>io.github.ares-x.inputmethod.Linnet</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${candidate_version}</string>
<key>CFBundleVersion</key><string>${candidate_build}</string>
<key>LinnetCodeSigningProfile</key><string>${candidate_profile}</string>
</dict></plist>
PLIST
cat >"${candidate_fixture}/Contents/Resources/LinnetRelease/VERSION.json" <<JSON
{"format":2,"product":"Linnet","version":"${candidate_version}","build":"${candidate_build}","source":{"candidate_revision":"${candidate_revision}"},"distribution":{"application_code_signature":{"profile":"community-cms","kind":"external-cms","leaf_certificate_sha256":"${candidate_leaf}","hardened_runtime":true,"host_settings_same_leaf":true},"artifact_scope":"public-community","notarized":false,"publication_eligible":true,"trust_model":"manual-user-approval"}}
JSON
cat >"${candidate_fixture}/Contents/MacOS/Linnet" <<'SH'
#!/usr/bin/env bash
[[ -z "${LINNET_LEGACY_HOST_LOG:-}" ]] || printf '%s\n' "$*" >>"${LINNET_LEGACY_HOST_LOG}"
# Public 0.1.9/0.1.10 Hosts do not recognize the new inspection option. Their
# default branch enters the long-lived InputMethodKit run loop; fail promptly
# here so a preinstall regression cannot hang this fixture.
exit 97
SH
chmod 755 "${candidate_fixture}/Contents/MacOS/Linnet"
printf 'community-cms\n' \
  >"${candidate_fixture}/Contents/Resources/LinnetLifecycleFixture/signature-kind"
printf 'linnet-community-cms-test-leaf-v1\n' \
  >"${candidate_fixture}/Contents/Resources/LinnetLifecycleFixture/certificate"
printf 'linnet-community-cms-wrong-leaf-v1\n' \
  >"${candidate_fixture}/Contents/Resources/LinnetLifecycleFixture/wrong-certificate"
[[ "$(/usr/bin/shasum -a 256 \
  "${candidate_fixture}/Contents/Resources/LinnetLifecycleFixture/certificate" | \
  /usr/bin/awk '{print $1}')" == "${candidate_leaf}" ]]
[[ "$(/usr/bin/shasum -a 256 \
  "${candidate_fixture}/Contents/Resources/LinnetLifecycleFixture/wrong-certificate" | \
  /usr/bin/awk '{print $1}')" == "${wrong_candidate_leaf}" ]]

write_candidate_identity() {
  local version="$1"
  local build="$2"
  local revision="$3"
  local leaf="$4"
  local format="${5:-${candidate_identity_format}}"
  local trust_model="${6:-${candidate_trust_model}}"
  local profile="${7:-${candidate_profile}}"
  local tree="${8:-${candidate_tree}}"
  local leaf_sha1="${9:-${candidate_leaf_sha1}}"
  ruby -rjson -e '
    document = {
      "format" => Integer(ARGV.fetch(0), 10),
      "bundle_identifier" => "io.github.ares-x.inputmethod.Linnet",
      "version" => ARGV.fetch(1),
      "build" => ARGV.fetch(2),
      "candidate_revision" => ARGV.fetch(3),
    }
    case document.fetch("format")
    when 1 then document["leaf_certificate_sha256"] = ARGV.fetch(4)
    when 2 then document["trust_model"] = ARGV.fetch(5)
    when 3
      document["profile"] = ARGV.fetch(6)
      document["leaf_certificate_sha256"] = ARGV.fetch(4)
    when 4
      document["profile"] = ARGV.fetch(6)
      document["leaf_certificate_sha256"] = ARGV.fetch(4)
      document["app_tree_sha256"] = ARGV.fetch(7)
      document["leaf_certificate_sha1"] = ARGV.fetch(8)
    else abort
    end
    File.binwrite(ARGV.fetch(9), JSON.generate(document) + "\n")
  ' "${format}" "${version}" "${build}" "${revision}" "${leaf}" \
    "${trust_model}" "${profile}" "${tree}" "${leaf_sha1}" \
    "${scripts_root}/candidate-app-identity.json"
  chmod 0644 "${scripts_root}/candidate-app-identity.json"
}
candidate_tree="$("${delta_tool}" tree-digest --root "${candidate_fixture}")"
candidate_leaf_sha1="$(/usr/bin/shasum \
  "${candidate_fixture}/Contents/Resources/LinnetLifecycleFixture/certificate" | \
  /usr/bin/awk '{print toupper($1)}')"
write_candidate_identity "${candidate_version}" "${candidate_build}" \
  "${candidate_revision}" "${candidate_leaf}"

# The candidate App identity state machine is the only executable identity
# owner in Installer scripts. Packaging must project one exact metadata record
# into every component that crosses a pre- or post-payload App boundary.
for source in package/core-installer-scripts/preinstall \
    package/installer-scripts/postinstall; do
  rg -Fq 'candidate-app-identity.sh' "${source}"
done
rg -Fq 'candidate-app-identity.json' package/make_package package/verify_package
rg -Fq 'candidate-app-identity.sh' package/make_package package/verify_package
rg -Fq 'verification_scope="${4:-}"' package/verify_package
rg -Fq '"${verification_scope}"' package/make_package
rg -Fq '"${identity_helper}" existing' package/core-installer-scripts/preinstall
rg -Fq '"${identity_helper}" installed' package/installer-scripts/postinstall
rg -Fq 'community-cms' package/make_package package/verify_package \
  package/installer-scripts/candidate-app-identity.sh
rg -Fq 'document["format"] = 4' package/make_package
rg -Fq 'candidate_identity["format"] = 4' package/verify_package
ruby -e '
  source = File.binread(ARGV.fetch(0))
  prefix, profiles = source.split(/^case "\$\{embedded_profile\}" in\n/, 2)
  cms = profiles&.match(/\Acommunity-cms\).*?^  ;;$/m)&.[](0)
  legacy = profiles&.match(/^community-adhoc\).*?^  ;;$/m)&.[](0)
  verify = %q{/usr/bin/codesign --verify --deep --strict}
  abort unless prefix && cms && legacy &&
    !prefix.include?(verify) && cms.scan(verify).size == 1 &&
    legacy.scan(verify).size == 1 &&
    !source.include?(%q{--extract-certificates})
' package/installer-scripts/candidate-app-identity.sh || {
  echo "Candidate identity integrity checks are not scoped to both admitted signing profiles." >&2
  exit 1
}
if rg -n 'core-update-selection|prior_enablement|TISDisable|--activate-input-source|--disable-input-source|--select-input-source|--refresh-core-input-source' \
    package/core-installer-scripts/preinstall package/installer-scripts sources/Main.swift; then
  echo "Core or shell Installer regained a user-owned input-source state path." >&2
  exit 1
fi
test "$(rg -F -c 'TISRegisterInputSource' sources/InputSource.swift)" = 1
test "$(rg -F -c 'TISEnableInputSource' sources/InputSource.swift)" = 1
if rg -Fq 'TISSelectInputSource' sources/InputSource.swift; then
  echo "Complete first install still selects the user-owned input source." >&2
  exit 1
fi
legacy_revisions=(
  755f69612ddd529ae5178a940498a2f2f9ac7cbf
  3a48e4853674b27cfd49b6bddcf9f6c9d6ee0999
)
legacy_versions=(0.1.9 0.1.10)
legacy_builds=(68 27)
for index in "${!legacy_revisions[@]}"; do
  legacy_revision="${legacy_revisions[index]}"
  legacy_main="$(git show "${legacy_revision}:sources/Main.swift")"
  legacy_product="$(git show "${legacy_revision}:config/LinnetProduct.xcconfig")"
  [[ "${legacy_main}" != *'--inspect-input-source-registration'* &&
    "${legacy_main}" == *'app.run()'* &&
    "${legacy_product}" == *"MARKETING_VERSION = ${legacy_versions[index]}"* &&
    "${legacy_product}" == *"CURRENT_PROJECT_VERSION = ${legacy_builds[index]}"* ]] || {
    echo "Legacy Host contract changed unexpectedly: ${legacy_revision}" >&2
    exit 1
  }
done
if rg -Fq -- '"${executable}" --inspect-input-source-registration' \
    package/core-installer-scripts/preinstall; then
  echo "Core preinstall still depends on a new CLI in the installed legacy Host." >&2
  exit 1
fi
rg -Fq 'input-source-registration-inspector' package/core-installer-scripts/preinstall
rg -Fq 'linnet-runtime-inspector' package/core-installer-scripts/preinstall \
  package/installer-scripts/postinstall package/make_package package/verify_package
if rg -n 'semver_at_least|check_active_core|packs\.\$\{index\}\.min_core' \
    package/core-installer-scripts/preinstall; then
  echo "Installer retained a second shell owner for installed Runtime compatibility." >&2
  exit 1
fi
if rg -Fq -- '--request-first-install-authorization' \
    package/installer-scripts/postinstall; then
  echo "Shared Core lifecycle regained the Complete-only authorization command." >&2
  exit 1
fi
test "$(rg -F -c -- '"${executable}" --request-first-install-authorization' \
  package/installer-scripts/complete-postinstall)" = 1
if rg -n 'missing-app-install' package/core-installer-scripts/preinstall \
    package/installer-scripts/candidate-app-identity.sh; then
  echo "The ambiguous missing-App repair transition returned." >&2
  exit 1
fi
rg -Fq 'clean-complete-install' package/core-installer-scripts/preinstall \
  package/installer-scripts/candidate-app-identity.sh
for visible_installer_text in package/WELCOME.md package/Conclusion-summary.txt; do
  visible_installer_contents="$(tr '\n' ' ' <"${visible_installer_text}" | tr -s ' ')"
  for required_text in \
    'Only creation of the first installed App registers Linnet' \
    'Complete repair of an existing App and every Core update leave registration, enablement and selection untouched.' \
    '只有首次创建 App 时' \
    '已有 App 的 Complete 修复与 Core 更新都不注册、启用或选择输入源' \
    'Healthy installations use Core for routine updates.' \
    '健康安装的常规升级只使用 Core。' \
    'If Core reports a non-matching published baseline or damaged App bytes,' \
    'If Linnet is missing or disabled' \
    '若 Core 报告未匹配精确发布基线或 App 字节损坏' \
    '若输入菜单缺少或停用了 Linnet' \
    'If Core reports duplicate, conflicting, or unverifiable registration remnants,' \
    'run the offline uninstall commands in README, then install Complete.' \
    '若 Core 报告重复、冲突或无法验证的注册残留，' \
    '请先运行 README 中的离线卸载命令，再安装 Complete。'; do
    [[ "${visible_installer_contents}" == *"${required_text}"* ]] || {
      echo "Installer-visible contract missing from ${visible_installer_text}: ${required_text}" >&2
      exit 1
    }
  done
done
if rg -n 'A first Complete installation registers|Complete rejects an existing App|首次 Complete 只注册|Complete 会拒绝.*已有 App' \
    package/WELCOME.md package/Conclusion-summary.txt; then
  echo "Installer-visible text restored the clean-install-only Complete contract." >&2
  exit 1
fi
if rg -n 'historical client|历史客户端应用|关闭本次登录期间使用过 Linnet|Installer closes|Installer 只关闭|开关.*拼写纠错|prediction, spelling' \
    package/WELCOME.md package/Conclusion-summary.txt; then
  echo "Installer-visible text restored application quiescence or client-history requirements." >&2
  exit 1
fi
for visible_installer_text in package/WELCOME.md package/Conclusion-summary.txt; do
  rg -Fq 'Other applications stay open' "${visible_installer_text}"
  rg -Fq '其他应用保持打开' "${visible_installer_text}"
  rg -Fq 'Settings' "${visible_installer_text}"
done
rg -Fq 'if model.operationActive {' sources/LinnetSettings/SettingsApplication.swift
rg -Fq 'return .terminateCancel' sources/LinnetSettings/SettingsApplication.swift
rg -Fq 'guard model.pendingChanges else { return .terminateNow }' \
  sources/LinnetSettings/SettingsApplication.swift
rg -Fq 'return .terminateLater' sources/LinnetSettings/SettingsApplication.swift

copy_candidate_app() {
  local home="$1"
  local destination="${home}/Library/Input Methods/Linnet.app"
  mkdir -p "$(dirname "${destination}")"
  COPYFILE_DISABLE=1 ditto --norsrc --noextattr "${candidate_fixture}" "${destination}"
  write_fake_input_source_cli "${home}"
}

write_fake_input_source_cli() {
  local home="$1"
  local fake_executable="${home}/fake-Linnet"
  cat >"${fake_executable}" <<'SH'
#!/usr/bin/env bash
[[ "$*" == --request-first-install-authorization ]]
: >"${HOME}/.linnet-test-input-source-authorization-requested"
printf '%s\n' "$*" >>"${LINNET_FAKE_HOST_LOG:?}"
SH
  chmod 755 "${fake_executable}"
}

configure_installed_identity() {
  local home="$1"
  local scenario="$2"
  local requested_version="${3:-}"
  local requested_build="${4:-}"
  local app="${home}/Library/Input Methods/Linnet.app"
  local info="${app}/Contents/Info.plist"
  local version_file="${app}/Contents/Resources/LinnetRelease/VERSION.json"
  local marker="${app}/Contents/Resources/LinnetLifecycleFixture/signature-kind"
  local profile kind leaf same_field marker_value version build revision
  version=0.1.0
  build=1
  revision=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  case "${scenario}" in
    exact-community-cms)
      profile=community-cms
      kind=external-cms
      leaf="${candidate_leaf}"
      same_field=host_settings_same_leaf
      marker_value=community-cms
      version="${candidate_version}"
      build="${candidate_build}"
      revision="${candidate_revision}"
      ;;
    same-community-cms-leaf)
      profile=community-cms
      kind=external-cms
      leaf="${candidate_leaf}"
      same_field=host_settings_same_leaf
      marker_value=community-cms
      ;;
    legacy-community-adhoc)
      profile=community-adhoc
      kind=adhoc
      leaf=
      same_field=host_settings_same_kind
      marker_value=legacy-community-adhoc
      ;;
    wrong-community-cms-leaf)
      profile=community-cms
      kind=external-cms
      leaf="${wrong_candidate_leaf}"
      same_field=host_settings_same_leaf
      marker_value=wrong-community-cms
      ;;
    uat)
      profile=uat
      kind=external-cms
      leaf="${candidate_leaf}"
      same_field=host_settings_same_leaf
      marker_value=community-cms
      ;;
    unknown)
      profile=unknown-community
      kind=external-cms
      leaf="${candidate_leaf}"
      same_field=host_settings_same_leaf
      marker_value=unknown-cms
      ;;
    *) return 1 ;;
  esac
  [[ -z "${requested_version}" ]] || version="${requested_version}"
  [[ -z "${requested_build}" ]] || build="${requested_build}"
  /usr/bin/plutil -replace CFBundleShortVersionString -string "${version}" "${info}"
  /usr/bin/plutil -replace CFBundleVersion -string "${build}" "${info}"
  /usr/bin/plutil -replace LinnetCodeSigningProfile -string "${profile}" "${info}"
  ruby -rjson -e '
    version, build, revision, profile, kind, leaf, same_field, destination = ARGV
    signature = {
      "profile" => profile,
      "kind" => kind,
      "hardened_runtime" => true,
      same_field => true,
    }
    signature["leaf_certificate_sha256"] = leaf unless leaf.empty?
    document = {
      "format" => 2,
      "product" => "Linnet",
      "version" => version,
      "build" => build,
      "source" => {"candidate_revision" => revision},
      "distribution" => {
        "application_code_signature" => signature,
        "artifact_scope" => "public-community",
        "notarized" => false,
        "publication_eligible" => true,
        "trust_model" => "manual-user-approval",
      },
    }
    File.binwrite(destination, JSON.generate(document) + "\n")
  ' "${version}" "${build}" "${revision}" "${profile}" "${kind}" \
    "${leaf}" "${same_field}" "${version_file}"
  printf '%s\n' "${marker_value}" >"${marker}"
}

# The new package identity is one fixed community CMS leaf. An older public
# ad-hoc build has one explicit migration edge; subsequent releases require the
# same CMS leaf. Every other signing history fails before payload mutation.
for accepted_transition in \
    legacy-community-adhoc:legacy-community-adhoc-to-cms \
    same-community-cms-leaf:same-community-cms-leaf; do
  scenario="${accepted_transition%%:*}"
  expected_transition="${accepted_transition#*:}"
  transition_home="${test_root}/identity-transition-${scenario}/home"
  copy_candidate_app "${transition_home}"
  configure_installed_identity "${transition_home}" "${scenario}"
  actual_transition="$(HOME="${transition_home}" \
    "${scripts_root}/candidate-app-identity.sh" existing)"
  [[ "${actual_transition}" == "${expected_transition}" ]] || {
    echo "Candidate identity owner lost transition ${expected_transition}." >&2
    exit 1
  }
done

legacy_boundary_home="${test_root}/identity-transition-legacy-boundary/home"
copy_candidate_app "${legacy_boundary_home}"
configure_installed_identity "${legacy_boundary_home}" \
  legacy-community-adhoc 0.1.11 28
[[ "$(HOME="${legacy_boundary_home}" \
  "${scripts_root}/candidate-app-identity.sh" existing)" == \
  legacy-community-adhoc-to-cms ]] || {
  echo "Candidate identity owner rejected the final admitted legacy build." >&2
  exit 1
}
for rejected_legacy_boundary in 0.1.12:28 0.1.11:29; do
  rejected_legacy_version="${rejected_legacy_boundary%%:*}"
  rejected_legacy_build="${rejected_legacy_boundary#*:}"
  configure_installed_identity "${legacy_boundary_home}" \
    legacy-community-adhoc "${rejected_legacy_version}" \
    "${rejected_legacy_build}"
  if HOME="${legacy_boundary_home}" \
      "${scripts_root}/candidate-app-identity.sh" existing >/dev/null 2>&1; then
    echo "Candidate identity owner accepted legacy ${rejected_legacy_version} build ${rejected_legacy_build} beyond the migration boundary." >&2
    exit 1
  fi
done
for rejected_identity in wrong-community-cms-leaf uat unknown; do
  rejected_home="${test_root}/identity-transition-${rejected_identity}/home"
  copy_candidate_app "${rejected_home}"
  configure_installed_identity "${rejected_home}" "${rejected_identity}"
  if HOME="${rejected_home}" "${scripts_root}/candidate-app-identity.sh" existing \
      >/dev/null 2>&1; then
    echo "Candidate identity owner accepted ${rejected_identity}." >&2
    exit 1
  fi
done

if [[ "${candidate_fixture_available}" == true ]]; then
  identity_home="${test_root}/candidate-identity/home"
  copy_candidate_app "${identity_home}"
  HOME="${identity_home}" "${scripts_root}/candidate-app-identity.sh" existing \
    >/dev/null
  HOME="${identity_home}" "${scripts_root}/candidate-app-identity.sh" installed

  if [[ "${candidate_identity_format}" == 1 || "${candidate_identity_format}" == 3 ]]; then
    wrong_leaf="1${candidate_leaf:1}"
    [[ "${wrong_leaf}" != "${candidate_leaf}" ]] || wrong_leaf="2${candidate_leaf:1}"
    write_candidate_identity "${candidate_version}" "${candidate_build}" \
      "${candidate_revision}" "${wrong_leaf}"
  else
    wrong_leaf=
    write_candidate_identity "${candidate_version}" "${candidate_build}" \
      "${candidate_revision}" "" 2 invalid-community-trust
  fi
  if HOME="${identity_home}" "${scripts_root}/candidate-app-identity.sh" existing \
      >/dev/null 2>&1; then
    echo "Candidate identity owner accepted a conflicting trust identity." >&2
    exit 1
  fi

  wrong_revision="1${candidate_revision:1}"
  [[ "${wrong_revision}" != "${candidate_revision}" ]] || \
    wrong_revision="2${candidate_revision:1}"
  write_candidate_identity "${candidate_version}" "${candidate_build}" \
    "${wrong_revision}" "${candidate_leaf}"
  if ! HOME="${identity_home}" "${scripts_root}/candidate-app-identity.sh" existing \
      >/dev/null; then
    echo "Candidate identity owner rejected a corrected same-version candidate." >&2
    exit 1
  fi
  if HOME="${identity_home}" "${scripts_root}/candidate-app-identity.sh" installed \
      >/dev/null 2>&1; then
    echo "Installed identity gate accepted bytes from the replaced candidate." >&2
    exit 1
  fi

  write_candidate_identity 0.0.0 "${candidate_build}" \
    "${candidate_revision}" "${candidate_leaf}"
  if HOME="${identity_home}" "${scripts_root}/candidate-app-identity.sh" existing \
      >/dev/null 2>&1; then
    echo "Candidate identity owner accepted an App newer than the candidate." >&2
    exit 1
  fi

  # A valid older candidate signed by the same product leaf may be updated.
  # Post-payload verification remains exact and therefore rejects that state.
  candidate_next_build="$((10#${candidate_build} + 1))"
  write_candidate_identity 999.0.0 "${candidate_next_build}" \
    "${wrong_revision}" "${candidate_leaf}"
  HOME="${identity_home}" "${scripts_root}/candidate-app-identity.sh" existing \
    >/dev/null
  if HOME="${identity_home}" "${scripts_root}/candidate-app-identity.sh" installed \
      >/dev/null 2>&1; then
    echo "Installed identity gate accepted an older App candidate." >&2
    exit 1
  fi

  if (( 10#${candidate_build} > 0 )); then
    write_candidate_identity 999.0.0 "$((10#${candidate_build} - 1))" \
      "${wrong_revision}" "${candidate_leaf}"
    if HOME="${identity_home}" "${scripts_root}/candidate-app-identity.sh" existing \
        >/dev/null 2>&1; then
      echo "Candidate identity owner accepted an App with a newer build." >&2
      exit 1
    fi
  fi

  write_candidate_identity "${candidate_version}" "${candidate_build}" \
    "${candidate_revision}" "${candidate_leaf}"
  tampered_home="${test_root}/candidate-identity-tampered/home"
  copy_candidate_app "${tampered_home}"
  /usr/bin/plutil -replace CFBundleIdentifier -string invalid.example \
    "${tampered_home}/Library/Input Methods/Linnet.app/Contents/Info.plist"
  if HOME="${tampered_home}" "${scripts_root}/candidate-app-identity.sh" installed \
      >/dev/null 2>&1; then
    echo "Installed identity gate accepted tampered bundle metadata." >&2
    exit 1
  fi
else
  echo "Package lifecycle: signed candidate identity behavior NOT_EXERCISED" >&2
fi

# Complete owns first registration; its instructions explain the first login.
# Neither a Complete repair nor a Core update unconditionally forces logout. Its
# Distribution templates and products leave every Linnet process and
# per-application connection open.
ruby -rrexml/document -e '
  component = REXML::Document.new(File.binread(ARGV.shift)).root
  abort "component duplicates the product conclusion owner" if
    component&.attributes&.key?("postinstall-action")
  complete, core = ARGV
  complete_document = REXML::Document.new(File.binread(complete)).root
  core_document = REXML::Document.new(File.binread(core)).root
  complete_ref = complete_document.get_elements("pkg-ref")
    .find { |ref| ref.attributes["version"] }
  core_ref = core_document.get_elements("pkg-ref")
    .find { |ref| ref.attributes["version"] }
  abort "Complete repair still requires an unnecessary logout" if
    complete_ref&.attributes&.key?("onConclusion")
  abort "Core update still requires an unnecessary logout" if
    core_ref&.attributes&.key?("onConclusion")
  abort "Complete Distribution retained a must-close mapping" unless
    complete_document.get_elements("pkg-ref/must-close").empty?
  abort "Core Distribution retained a must-close mapping" unless
    core_document.get_elements("pkg-ref/must-close").empty?
' package/PackageInfo package/Distribution.xml package/Distribution-Core.xml
rg -Fq 'cp -X "${project_root}/package/installer-scripts/postinstall"' \
  package/make_package || {
  echo "Core update lost its post-payload identity verification." >&2
  exit 1
}
ruby -e '
  source = File.read(ARGV.fetch(0))
  abort "package verifier does not distinguish Core and Complete script shapes" unless
    source.include?(%q{edition == "core" ? %w[preinstall postinstall] : %w[preinstall]})
' package/verify_package

if rg -n '/usr/bin/(ruby|python)|data_release_metadata' \
    package/core-installer-scripts/preinstall ||
    rg -n 'cp -X .*data_release_tool|destination.*/data_release_metadata' package/make_package; then
  echo "Installed package lifecycle retains a third-party language runtime." >&2
  exit 1
fi

assert_complete_rejects_symlink() {
  local label="$1"
  local relative="$2"
  local case_root="${test_root}/preinstall-${label}"
  local case_home="${case_root}/home"
  local external="${case_root}/external"
  local target="${case_home}/${relative}"
  local sentinel="preinstall-${label}-sentinel"
  mkdir -p "$(dirname "${target}")" "${external}"
  printf '%s\n' "${sentinel}" >"${external}/sentinel"
  ln -s "${external}" "${target}"
  if HOME="${case_home}" "${scripts_root}/preinstall" >/dev/null 2>&1; then
    echo "Complete preinstall accepted a symbolic-link ${label} path." >&2
    exit 1
  fi
  [[ "$(cat "${external}/sentinel")" == "${sentinel}" ]] || {
    echo "Complete preinstall touched the symbolic-link ${label} target." >&2
    exit 1
  }
}

prepare_postinstall_home() {
  local home="$1"
  local app="${home}/Library/Input Methods/Linnet.app"
  local support="${home}/Library/Application Support/Linnet"
  mkdir -p "${app}/Contents/MacOS" "${support}/Runtime/Active" "${support}/State"
cat >"${app}/Contents/MacOS/Linnet" <<'SH'
#!/usr/bin/env bash
[[ "$*" == --request-first-install-authorization ]]
: >"${HOME}/.linnet-test-input-source-authorization-requested"
printf '%s\n' "$*" >>"${LINNET_FAKE_HOST_LOG:?}"
SH
  chmod 755 "${app}/Contents/MacOS/Linnet"
  printf '{}\n' >"${support}/Runtime/Active/activation.json"
}

prepare_signed_postinstall_home() {
  local home="$1"
  local support="${home}/Library/Application Support/Linnet"
  copy_candidate_app "${home}"
  mkdir -p "${support}/Runtime/Active" "${support}/State"
  printf '{}\n' >"${support}/Runtime/Active/activation.json"
}

stage_complete_candidate() {
  local home="$1"
  local root="${home}/Library/Application Support/Linnet/.linnet-complete"
  local stage="${root}/App/Linnet.payload"
  mkdir -p "${stage%/*}" "${root}/Data/Packs" "${root}/Runtime/Active"
  COPYFILE_DISABLE=1 ditto --norsrc --noextattr "${candidate_fixture}" "${stage}"
  printf 'staged language data\n' >"${root}/Data/Packs/staged"
  printf '{}\n' >"${root}/Runtime/Active/activation.json"
  ln -s ../../Data/Packs "${root}/Runtime/Active/Packs"
}

assert_postinstall_rejects_parent_symlink() {
  local label="$1"
  local relative="$2"
  local case_root="${test_root}/postinstall-${label}"
  local case_home="${case_root}/home"
  local target="${case_home}/${relative}"
  local external="${case_root}/external"
  local invocation_log="${case_root}/host-invocations"
  local sentinel="postinstall-${label}-sentinel"
  prepare_postinstall_home "${case_home}"
  mv "${target}" "${external}"
  ln -s "${external}" "${target}"
  printf '%s\n' "${sentinel}" >"${external}/sentinel"
  if HOME="${case_home}" LINNET_FAKE_HOST_LOG="${invocation_log}" \
      "${scripts_root}/complete-postinstall" >/dev/null 2>&1; then
    echo "Postinstall accepted a symbolic-link ${label} parent." >&2
    exit 1
  fi
  [[ ! -e "${invocation_log}" || ! -s "${invocation_log}" ]] || {
    echo "Postinstall invoked Host through a symbolic-link ${label} parent." >&2
    exit 1
  }
  [[ "$(cat "${external}/sentinel")" == "${sentinel}" ]] || {
    echo "Postinstall touched the symbolic-link ${label} target." >&2
    exit 1
  }
}

# Complete owns the only first-install path. Its Core component may run before
# the language payload exists and must therefore accept absent product roots.
printf 'complete\n' >"${scripts_root}/install-mode"
HOME="${user_home}" "${scripts_root}/preinstall"
if HOME="${test_root}/missing-home" "${scripts_root}/preinstall" >/dev/null 2>&1; then
  echo "Complete preinstall accepted a missing current-user home." >&2
  exit 1
fi
missing_library_home="${test_root}/missing-library-home"
mkdir -p "${missing_library_home}"
if HOME="${missing_library_home}" "${scripts_root}/preinstall" >/dev/null 2>&1; then
  echo "Complete preinstall accepted a missing user Library." >&2
  exit 1
fi

# Every existing component of both current-user payload roots is a pre-payload
# trust boundary. Missing leaves remain valid, but no App, data-pack or Active
# ancestor may redirect Installer through a symbolic link.
assert_complete_rejects_symlink input-methods 'Library/Input Methods'
assert_complete_rejects_symlink linnet-app 'Library/Input Methods/Linnet.app'
assert_complete_rejects_symlink data 'Library/Application Support/Linnet/Data'
assert_complete_rejects_symlink packs 'Library/Application Support/Linnet/Data/Packs'
for kind in chinese english lts extended; do
  assert_complete_rejects_symlink "pack-${kind}" \
    "Library/Application Support/Linnet/Data/Packs/${kind}"
done
assert_complete_rejects_symlink runtime 'Library/Application Support/Linnet/Runtime'
assert_complete_rejects_symlink active 'Library/Application Support/Linnet/Runtime/Active'
assert_complete_rejects_symlink state 'Library/Application Support/Linnet/State'

unsafe_mode_home="${test_root}/preinstall-unsafe-mode/home"
mkdir -p "${unsafe_mode_home}/Library/Input Methods"
chmod 0777 "${unsafe_mode_home}/Library/Input Methods"
if HOME="${unsafe_mode_home}" "${scripts_root}/preinstall" >/dev/null 2>&1; then
  echo "Complete preinstall accepted a group/world-writable Input Methods path." >&2
  exit 1
fi

# Postinstall is the distinct post-payload identity boundary. Only creation of
# the first App may request registration/enablement; an existing App update and
# every Core update must make no input-source Host CLI call.
if [[ "${candidate_fixture_available}" == true ]]; then
  delta_tool="${repo_root}/build/linnet-pack"
  [[ -x "${delta_tool}" ]] || { echo "Canonical pack CLI must be built before lifecycle tests." >&2; exit 1; }
  cp -X "${delta_tool}" "${scripts_root}/linnet-pack"
  chmod 0755 "${scripts_root}/linnet-pack"

  first_install_home="${test_root}/postinstall-first-install/home"
  first_install_log="${test_root}/postinstall-first-install/host-invocations"
  mkdir -p "${first_install_home}/Library/Input Methods" \
    "${first_install_home}/Library/Application Support/Linnet/State"
  write_fake_input_source_cli "${first_install_home}"
  stage_complete_candidate "${first_install_home}"
  HOME="${first_install_home}" LINNET_FAKE_REGISTRATION_STATE=missing \
    LINNET_FAKE_HOST_LOG="${first_install_log}" \
    LINNET_TEST_EXECUTABLE="${first_install_home}/fake-Linnet" \
    "${scripts_root}/complete-postinstall" \
      "/private/tmp/Linnet-Profile.component.pkg" "/Users/aresx" "/" "/"
  [[ "$(cat "${first_install_log}")" == '--request-first-install-authorization' ]] || {
    echo "First Complete install did not submit exactly one authorization request." >&2
    exit 1
  }

  postinstall_home="${test_root}/postinstall-positive/home"
  postinstall_log="${test_root}/postinstall-positive/host-invocations"
  postinstall_runtime_log="${test_root}/postinstall-positive/runtime-inspections"
  prepare_signed_postinstall_home "${postinstall_home}"
  stage_complete_candidate "${postinstall_home}"
  HOME="${postinstall_home}" \
    LINNET_FAKE_REGISTRATION_STATE=registered:enabled-observation:selectable:path-unknown \
    LINNET_FAKE_HOST_LOG="${postinstall_log}" \
    LINNET_FAKE_RUNTIME_LOG="${postinstall_runtime_log}" \
    LINNET_TEST_EXECUTABLE="${postinstall_home}/fake-Linnet" \
    "${scripts_root}/complete-postinstall"
  [[ ! -e "${postinstall_log}" || ! -s "${postinstall_log}" ]] || {
    echo "Complete update of an existing App requested input-source authorization." >&2
    exit 1
  }
  grep -Fxq "probe 0.1.0 ${postinstall_home}/Library/Application Support" \
    "${postinstall_runtime_log}" || {
    echo "Complete postinstall did not use the read-only Runtime probe." >&2
    exit 1
  }

  # Registry classifies missing only when neither language baseline tree
  # exists. Complete then publishes Data before Runtime, whose Active view may
  # legally refer back to Data/Packs; it must not route Runtime through the
  # App-directory delta inventory.
  missing_complete_home="${test_root}/postinstall-missing-runtime/home"
  missing_complete_log="${test_root}/postinstall-missing-runtime/host-invocations"
  copy_candidate_app "${missing_complete_home}"
  mkdir -p "${missing_complete_home}/Library/Application Support/Linnet/State"
  stage_complete_candidate "${missing_complete_home}"
  HOME="${missing_complete_home}" \
      LINNET_FAKE_REGISTRATION_STATE=registered:enabled-observation:selectable:path-unknown \
      LINNET_FAKE_HOST_LOG="${missing_complete_log}" \
      "${scripts_root}/complete-postinstall"
  [[ -f "${missing_complete_home}/Library/Application Support/Linnet/Data/Packs/staged" && \
    -f "${missing_complete_home}/Library/Application Support/Linnet/Runtime/Active/activation.json" && \
    -L "${missing_complete_home}/Library/Application Support/Linnet/Runtime/Active/Packs" && \
    "$(readlink "${missing_complete_home}/Library/Application Support/Linnet/Runtime/Active/Packs")" == ../../Data/Packs ]] || {
    echo "Complete missing-runtime repair did not publish Data before its Runtime projection." >&2
    exit 1
  }
  [[ ! -e "${missing_complete_home}/Library/Application Support/Linnet/.linnet-complete" && \
    ( ! -e "${missing_complete_log}" || ! -s "${missing_complete_log}" ) ]] || {
    echo "Complete data repair of an existing App requested authorization." >&2
    exit 1
  }

  # A final Runtime validation failure rolls the first-install baseline back in
  # reverse order and restores the exact preexisting App pair.
  rollback_complete_home="${test_root}/postinstall-missing-runtime-rollback/home"
  rollback_complete_support="${rollback_complete_home}/Library/Application Support/Linnet"
  copy_candidate_app "${rollback_complete_home}"
  mkdir -p "${rollback_complete_support}/State"
  printf 'original App bytes\n' \
    >"${rollback_complete_home}/Library/Input Methods/Linnet.app/Contents/rollback-before"
  stage_complete_candidate "${rollback_complete_home}"
  if HOME="${rollback_complete_home}" \
      LINNET_FAKE_REGISTRATION_STATE=registered:enabled-observation:selectable:path-unknown \
      LINNET_FAKE_RUNTIME_STATE=missing-then-invalid \
      "${scripts_root}/complete-postinstall" >/dev/null 2>&1; then
    echo "Complete accepted a Runtime projection that failed final validation." >&2
    exit 1
  fi
  [[ -f "${rollback_complete_home}/Library/Input Methods/Linnet.app/Contents/rollback-before" && \
    ! -e "${rollback_complete_support}/Data" && ! -L "${rollback_complete_support}/Data" && \
    ! -e "${rollback_complete_support}/Runtime" && ! -L "${rollback_complete_support}/Runtime" && \
    ! -e "${rollback_complete_support}/.linnet-complete" ]] || {
    echo "Complete Runtime failure did not reverse its baseline publication and App replacement." >&2
    exit 1
  }

  invalid_runtime_home="${test_root}/postinstall-invalid-runtime/home"
  invalid_runtime_log="${test_root}/postinstall-invalid-runtime/host-invocations"
  prepare_signed_postinstall_home "${invalid_runtime_home}"
  stage_complete_candidate "${invalid_runtime_home}"
  if HOME="${invalid_runtime_home}" LINNET_FAKE_HOST_LOG="${invalid_runtime_log}" \
      LINNET_TEST_EXECUTABLE="${invalid_runtime_home}/fake-Linnet" \
      LINNET_FAKE_RUNTIME_STATE=invalid \
      "${scripts_root}/complete-postinstall" >/dev/null 2>&1; then
    echo "Complete postinstall accepted an invalid final Runtime projection." >&2
    exit 1
  fi
  [[ ! -e "${invalid_runtime_log}" || ! -s "${invalid_runtime_log}" ]] || {
    echo "Complete registered the input source before validating final Runtime bytes." >&2
    exit 1
  }
fi

# Core replaces App bytes without stopping the connected Host or touching the
# existing TIS identity. The replacement activates on a natural Host launch.
printf 'core-update\n' >"${scripts_root}/install-mode"
if [[ "${candidate_fixture_available}" == true ]]; then
  delta_tool="${repo_root}/build/linnet-pack"
  [[ -x "${delta_tool}" ]] || { echo "Canonical pack CLI must be built before lifecycle tests." >&2; exit 1; }
  cp -X "${delta_tool}" "${scripts_root}/linnet-pack"
  chmod 0755 "${scripts_root}/linnet-pack"
  COPYFILE_DISABLE=1 ditto --norsrc --noextattr \
    "${candidate_fixture}" "${scripts_root}/Linnet.payload"
  target_tree="$("${delta_tool}" tree-digest --root "${candidate_fixture}")"

  # Core admits any intact, same-leaf public release no newer than the sealed
  # candidate. This includes a stable build and a lower Preview with distinct
  # bytes; a tampered App still fails before PackageKit can mutate state.
  for preflight_case in stable preview target tampered; do
    preflight_home="${test_root}/delta-preflight-${preflight_case}/home"
    preflight_app="${preflight_home}/Library/Input Methods/Linnet.app"
    prepare_signed_postinstall_home "${preflight_home}"
    case "${preflight_case}" in
      stable) configure_installed_identity "${preflight_home}" same-community-cms-leaf ;;
      preview)
        configure_installed_identity "${preflight_home}" same-community-cms-leaf \
          0.1.13 30
        printf 'published preview bytes\n' >"${preflight_app}/Contents/preview-build"
        ;;
      target) ;;
      tampered)
        configure_installed_identity "${preflight_home}" same-community-cms-leaf
        printf 'unexpected bytes\n' >"${preflight_app}/Contents/unexpected"
        ;;
    esac
    before_tree="$("${delta_tool}" tree-digest --root "${preflight_app}")"
    if HOME="${preflight_home}" "${scripts_root}/preinstall" \
        >"${test_root}/delta-preflight-${preflight_case}/result.log" 2>&1; then
      [[ "${preflight_case}" != tampered ]] || {
        echo "Core preinstall accepted a tampered App tree." >&2; exit 1;
      }
    else
      [[ "${preflight_case}" == tampered ]] || {
        cat "${test_root}/delta-preflight-${preflight_case}/result.log" >&2; exit 1;
      }
      grep -Fq 'code signature is invalid' \
        "${test_root}/delta-preflight-${preflight_case}/result.log" || {
        echo "Core tampered-App exit did not explain the integrity failure." >&2; exit 1;
      }
    fi
    [[ "$("${delta_tool}" tree-digest --root "${preflight_app}")" == "${before_tree}" ]] || {
      echo "Core preinstall changed App bytes before its admission decision." >&2; exit 1;
    }
  done

  snapshot_app() {
    ruby -e '
      root = ARGV.fetch(0)
      ([root] + Dir.glob("#{root}/**/*", File::FNM_DOTMATCH)).sort.each do |path|
        next if %w[. ..].include?(File.basename(path))
        stat = File.lstat(path)
        puts [path.delete_prefix(root), stat.ino, stat.mode, stat.size, stat.mtime.to_r, stat.ctime.to_r].join("\t")
      end
    ' "$1"
  }

  # Settings download holds this same Registry lease for its whole transfer.
  # An Installer must fail before its child dispatcher can move either live App
  # or language trees; this uses the production lease CLI rather than a second
  # test lock.
  hold_download_lease() {
    local home="$1"
    local ready="$2"
    local release="$3"
    rm -f "${ready}" "${release}"
    "${delta_tool}" with-settings-mutation-lease \
      --application-support "${home}/Library/Application Support" \
      --core-version 0.1.0 --timeout-seconds 0 -- /bin/bash -c '
        printf ready >"$1"
        while [[ ! -e "$2" ]]; do /bin/sleep 0.05; done
      ' -- "${ready}" "${release}" &
    download_lease_pid=$!
    for _ in $(seq 1 100); do
      [[ -e "${ready}" ]] && return 0
      /bin/sleep 0.05
    done
    wait "${download_lease_pid}" || true
    echo "Settings download lease did not become ready." >&2
    exit 1
  }

  release_download_lease() {
    local release="$1"
    : >"${release}"
    wait "${download_lease_pid}"
  }

  # Complete otherwise has a valid signed App, exact registration, staged App,
  # Data and Runtime. A concurrent Settings download must leave every live
  # tree intact rather than relying on a must-close or a silent repair path.
  printf 'complete\n' >"${scripts_root}/install-mode"
  lease_complete_home="${test_root}/lease-complete/home"
  prepare_signed_postinstall_home "${lease_complete_home}"
  configure_installed_identity "${lease_complete_home}" same-community-cms-leaf
  mkdir -p "${lease_complete_home}/Library/Application Support/Linnet/Data"
  printf 'live data\n' >"${lease_complete_home}/Library/Application Support/Linnet/Data/sentinel"
  stage_complete_candidate "${lease_complete_home}"
  lease_complete_app_before="$(snapshot_app "${lease_complete_home}/Library/Input Methods/Linnet.app")"
  lease_complete_data_before="$("${delta_tool}" tree-digest --root \
    "${lease_complete_home}/Library/Application Support/Linnet/Data")"
  lease_complete_runtime_before="$("${delta_tool}" tree-digest --root \
    "${lease_complete_home}/Library/Application Support/Linnet/Runtime")"
  lease_complete_ready="${test_root}/lease-complete/ready"
  lease_complete_release="${test_root}/lease-complete/release"
  hold_download_lease "${lease_complete_home}" "${lease_complete_ready}" "${lease_complete_release}"
  if HOME="${lease_complete_home}" LINNET_FAKE_REGISTRATION_STATE=registered:enabled-observation:selectable:path-unknown \
      LINNET_FAKE_RUNTIME_STATE=healthy \
      "${scripts_root}/complete-postinstall" >/dev/null 2>&1; then
    release_download_lease "${lease_complete_release}"
    echo "Complete changed state while a Settings download held the mutation lease." >&2
    exit 1
  fi
  [[ "$(snapshot_app "${lease_complete_home}/Library/Input Methods/Linnet.app")" == \
    "${lease_complete_app_before}" && \
    "$("${delta_tool}" tree-digest --root \
      "${lease_complete_home}/Library/Application Support/Linnet/Data")" == \
      "${lease_complete_data_before}" && \
    "$("${delta_tool}" tree-digest --root \
      "${lease_complete_home}/Library/Application Support/Linnet/Runtime")" == \
      "${lease_complete_runtime_before}" ]] || {
    release_download_lease "${lease_complete_release}"
    echo "Complete mutated a live App or language tree before lease admission." >&2
    exit 1
  }
  release_download_lease "${lease_complete_release}"

  # Core uses the same dispatcher. The shared lease keeps its atomic App
  # replacement outside a concurrent data download.
  printf 'core-update\n' >"${scripts_root}/install-mode"
  lease_core_home="${test_root}/lease-core/home"
  prepare_signed_postinstall_home "${lease_core_home}"
  configure_installed_identity "${lease_core_home}" same-community-cms-leaf
  mkdir -p "${lease_core_home}/Library/Application Support/Linnet/Data"
  printf 'live data\n' >"${lease_core_home}/Library/Application Support/Linnet/Data/sentinel"
  lease_core_app_before="$(snapshot_app "${lease_core_home}/Library/Input Methods/Linnet.app")"
  lease_core_data_before="$("${delta_tool}" tree-digest --root \
    "${lease_core_home}/Library/Application Support/Linnet/Data")"
  lease_core_ready="${test_root}/lease-core/ready"
  lease_core_release="${test_root}/lease-core/release"
  hold_download_lease "${lease_core_home}" "${lease_core_ready}" "${lease_core_release}"
  if HOME="${lease_core_home}" LINNET_FAKE_RUNTIME_STATE=healthy \
      "${scripts_root}/postinstall" >/dev/null 2>&1; then
    release_download_lease "${lease_core_release}"
    echo "Core changed state while a Settings download held the mutation lease." >&2
    exit 1
  fi
  [[ "$(snapshot_app "${lease_core_home}/Library/Input Methods/Linnet.app")" == \
    "${lease_core_app_before}" && \
    "$("${delta_tool}" tree-digest --root \
      "${lease_core_home}/Library/Application Support/Linnet/Data")" == \
      "${lease_core_data_before}" ]] || {
    release_download_lease "${lease_core_release}"
    echo "Core mutated a live App or language tree before lease admission." >&2
    exit 1
  }
  release_download_lease "${lease_core_release}"
  printf 'core-update\n' >"${scripts_root}/install-mode"
  for delta_case in success corrupt staged-identity rollback; do
    delta_home="${test_root}/delta-${delta_case}/home"
    delta_app="${delta_home}/Library/Input Methods/Linnet.app"
    delta_runtime_log="${test_root}/delta-${delta_case}/runtime-build"
    prepare_signed_postinstall_home "${delta_home}"
    configure_installed_identity "${delta_home}" same-community-cms-leaf
    /bin/chmod -R -P u+w "${scripts_root}/Linnet.payload"
    /bin/rm -rf -- "${scripts_root}/Linnet.payload"
    COPYFILE_DISABLE=1 ditto --norsrc --noextattr \
      "${candidate_fixture}" "${scripts_root}/Linnet.payload"
    case "${delta_case}" in
      corrupt)
        printf 'unexpected bytes\n' >"${scripts_root}/Linnet.payload/Contents/unexpected"
        ;;
      staged-identity)
        write_candidate_identity "${candidate_version}" "${candidate_build}" \
          "${wrong_revision}" "${candidate_leaf}"
        ;;
    esac
    before_tree="$("${delta_tool}" tree-digest --root "${delta_app}")"
    before_app="$(snapshot_app "${delta_app}")"
    before_app_identity="$(stat -f '%d:%i' "${delta_app}")"
    before_build="$(plutil -extract CFBundleVersion raw -o - "${delta_app}/Contents/Info.plist")"
    runtime_state=healthy
    [[ "${delta_case}" != rollback ]] || runtime_state=target-invalid
    if HOME="${delta_home}" LINNET_FAKE_RUNTIME_STATE="${runtime_state}" \
        LINNET_FAKE_RUNTIME_TARGET_BUILD="${candidate_build}" \
        LINNET_FAKE_RUNTIME_BUILD_LOG="${delta_runtime_log}" \
        "${scripts_root}/postinstall" >"${test_root}/delta-${delta_case}/result.log" 2>&1; then
      [[ "${delta_case}" == success ]] || { echo "Core payload accepted ${delta_case}" >&2; exit 1; }
      [[ "$("${delta_tool}" tree-digest --root "${delta_app}")" == "${target_tree}" ]]
    else
      [[ "${delta_case}" != success ]] || { cat "${test_root}/delta-${delta_case}/result.log" >&2; exit 1; }
      [[ "$("${delta_tool}" tree-digest --root "${delta_app}")" == "${before_tree}" ]]
      if [[ "${delta_case}" == rollback ]]; then
        [[ "$(cat "${delta_runtime_log}")" == "${before_build}"$'\n'"${candidate_build}" ]] || {
          echo "Runtime failure did not exercise the installed target before rollback." >&2; exit 1;
        }
      else
        [[ "$(snapshot_app "${delta_app}")" == "${before_app}" ]]
      fi
    fi
    [[ "$(stat -f '%d:%i' "${delta_app}")" == "${before_app_identity}" ]] || {
      echo "Core ${delta_case} replaced the registered App directory." >&2; exit 1;
    }
    [[ -z "$(find "${delta_home}/Library/Input Methods" -maxdepth 1 -name '.linnet-core.*' -print)" ]]
    write_candidate_identity "${candidate_version}" "${candidate_build}" \
      "${candidate_revision}" "${candidate_leaf}"
  done
  /bin/chmod -R -P u+w "${scripts_root}/Linnet.payload"
  /bin/rm -rf -- "${scripts_root}/Linnet.payload"
  COPYFILE_DISABLE=1 ditto --norsrc --noextattr \
    "${candidate_fixture}" "${scripts_root}/Linnet.payload"

  core_postinstall_home="${test_root}/postinstall-core/home"
  core_postinstall_log="${test_root}/postinstall-core/host-invocations"
  prepare_signed_postinstall_home "${core_postinstall_home}"
  before_app="$(snapshot_app "${core_postinstall_home}/Library/Input Methods/Linnet.app")"
  HOME="${core_postinstall_home}" LINNET_FAKE_HOST_LOG="${core_postinstall_log}" \
    LINNET_TEST_EXECUTABLE="${core_postinstall_home}/fake-Linnet" \
    "${scripts_root}/postinstall"
  [[ "$(snapshot_app "${core_postinstall_home}/Library/Input Methods/Linnet.app")" == "${before_app}" ]] || {
    echo "An exact Core target reinstall rewrote the App." >&2; exit 1;
  }
  [[ ! -e "${core_postinstall_log}" || ! -s "${core_postinstall_log}" ]] || {
    echo "Core postinstall invoked the live Host or input-source registration." >&2
    exit 1
  }

  rejected_postinstall_home="${test_root}/postinstall-rejected-identity/home"
  rejected_postinstall_log="${test_root}/postinstall-rejected-identity/host-invocations"
  prepare_signed_postinstall_home "${rejected_postinstall_home}"
  write_candidate_identity "${candidate_version}" "${candidate_build}" \
    "${wrong_revision}" "${candidate_leaf}"
  if HOME="${rejected_postinstall_home}" \
      LINNET_FAKE_HOST_LOG="${rejected_postinstall_log}" \
      LINNET_TEST_EXECUTABLE="${rejected_postinstall_home}/fake-Linnet" \
      "${scripts_root}/postinstall" >/dev/null 2>&1; then
    echo "Postinstall accepted a payload with the wrong source revision." >&2
    exit 1
  fi
  [[ ! -e "${rejected_postinstall_log}" || ! -s "${rejected_postinstall_log}" ]] || {
    echo "Postinstall invoked Host before rejecting the payload identity." >&2
    exit 1
  }
  write_candidate_identity "${candidate_version}" "${candidate_build}" \
    "${candidate_revision}" "${candidate_leaf}"
fi

printf 'invalid\n' >"${scripts_root}/install-mode"
invalid_postinstall_home="${test_root}/postinstall-invalid-mode/home"
invalid_postinstall_log="${test_root}/postinstall-invalid-mode/host-invocations"
prepare_postinstall_home "${invalid_postinstall_home}"
if HOME="${invalid_postinstall_home}" LINNET_FAKE_HOST_LOG="${invalid_postinstall_log}" \
    "${scripts_root}/complete-postinstall" >/dev/null 2>&1; then
  echo "Postinstall accepted an unknown package lifecycle mode." >&2
  exit 1
fi
[[ ! -e "${invalid_postinstall_log}" || ! -s "${invalid_postinstall_log}" ]] || {
  echo "Postinstall invoked Host before rejecting an unknown lifecycle mode." >&2
  exit 1
}
printf 'complete\n' >"${scripts_root}/install-mode"
assert_postinstall_rejects_parent_symlink library 'Library'
assert_postinstall_rejects_parent_symlink input-methods 'Library/Input Methods'
assert_postinstall_rejects_parent_symlink linnet-app \
  'Library/Input Methods/Linnet.app'
assert_postinstall_rejects_parent_symlink app-contents \
  'Library/Input Methods/Linnet.app/Contents'
assert_postinstall_rejects_parent_symlink app-macos \
  'Library/Input Methods/Linnet.app/Contents/MacOS'
assert_postinstall_rejects_parent_symlink application-support \
  'Library/Application Support'
assert_postinstall_rejects_parent_symlink support-root \
  'Library/Application Support/Linnet'
assert_postinstall_rejects_parent_symlink runtime \
  'Library/Application Support/Linnet/Runtime'
assert_postinstall_rejects_parent_symlink active \
  'Library/Application Support/Linnet/Runtime/Active'
assert_postinstall_rejects_parent_symlink state \
  'Library/Application Support/Linnet/State'
postinstall_mode_home="${test_root}/postinstall-unsafe-mode/home"
postinstall_mode_log="${test_root}/postinstall-unsafe-mode/host-invocations"
prepare_postinstall_home "${postinstall_mode_home}"
chmod 0777 "${postinstall_mode_home}/Library/Application Support/Linnet/Runtime/Active"
if HOME="${postinstall_mode_home}" LINNET_FAKE_HOST_LOG="${postinstall_mode_log}" \
    "${scripts_root}/postinstall" >/dev/null 2>&1; then
  echo "Postinstall accepted a group/world-writable Active path." >&2
  exit 1
fi
[[ ! -e "${postinstall_mode_log}" || ! -s "${postinstall_mode_log}" ]] || {
  echo "Postinstall invoked Host after an unsafe Active mode." >&2
  exit 1
}

# Ownership is not safely mutable in an unprivileged fixture. Keep a structural
# guard on both mutation-time boundaries while the behavioral rows above prove
# the shared no-follow and mode invariant through the real shell entrypoints.
for boundary in package/core-installer-scripts/preinstall \
    package/installer-scripts/postinstall; do
  rg -Fq "/usr/bin/stat -f '%u %Lp'" "${boundary}"
  rg -Fq '[[ "${owner}" == "${current_uid}" ]]' "${boundary}"
  rg -Fq '(( (8#${mode} & 0022) == 0 ))' "${boundary}"
done

# Complete first-install may accept an absent product root, but must reject a
# pre-created product-root symlink before any payload can be installed through it.
support_root="${user_home}/Library/Application Support/Linnet"
external_support="${test_root}/preinstall-external-support"
mkdir -p "${user_home}/Library/Application Support" "${external_support}"
ln -s "${external_support}" "${support_root}"
if HOME="${user_home}" "${scripts_root}/preinstall" >/dev/null 2>&1; then
  echo "Complete preinstall accepted a symbolic-link Application Support root." >&2
  exit 1
fi
[[ -d "${external_support}" ]] || {
  echo "Complete preinstall touched the symbolic-link target." >&2
  exit 1
}
rm "${support_root}"

# Complete accepts a clean installation or a supported, signed damaged App so
# its sole postinstall mutation owner can idempotently repair registration.
# Residual Active state without an executable cannot supply authoritative TIS
# evidence and remains fail closed.
retained_home="${test_root}/complete-retained-data/home"
mkdir -p "${retained_home}/Library/Application Support/Linnet/UserData"
printf 'preserved\n' >"${retained_home}/Library/Application Support/Linnet/UserData/sentinel"
HOME="${retained_home}" "${scripts_root}/preinstall"

app_only_home="${test_root}/complete-app-only/home"
if [[ "${candidate_fixture_available}" == true ]]; then
  copy_candidate_app "${app_only_home}"
else
  mkdir -p "${app_only_home}/Library/Input Methods/Linnet.app"
fi
if [[ "${candidate_fixture_available}" == true ]]; then
  HOME="${app_only_home}" LINNET_FAKE_REGISTRATION_STATE=missing \
    "${scripts_root}/preinstall" || {
    echo "Complete preinstall rejected a supported missing-registration repair." >&2
    exit 1
  }
  HOME="${app_only_home}" \
    LINNET_FAKE_REGISTRATION_STATE=registered:enabled-observation:selectable:path-unknown \
    "${scripts_root}/preinstall" || {
    echo "Complete preinstall rejected an idempotent signed-App repair." >&2
    exit 1
  }
  for rejected_registration in duplicate:2 conflict:source-or-bundle-id unknown:bundle-id; do
    if HOME="${app_only_home}" \
        LINNET_FAKE_REGISTRATION_STATE="${rejected_registration}" \
        "${scripts_root}/preinstall" >/dev/null 2>&1; then
      echo "Complete accepted conflicting TIS state ${rejected_registration}." >&2
      exit 1
    fi
  done
fi

missing_app_home="${test_root}/complete-missing-app-repair/home"
mkdir -p "${missing_app_home}/Library/Application Support/Linnet/Runtime/Active" \
  "${missing_app_home}/Library/Application Support/Linnet/State"
printf '{}\n' >"${missing_app_home}/Library/Application Support/Linnet/Runtime/Active/activation.json"
for repair_registration in missing \
    registered:enablement-required:path-unknown \
    registered:enabled-observation:selectable:path-unknown \
    registered:selected-observation:selectable:path-unknown; do
  HOME="${missing_app_home}" LINNET_FAKE_REGISTRATION_STATE="${repair_registration}" \
    "${scripts_root}/preinstall" || {
    echo "Complete could not repair a missing App with safe product state." >&2
    exit 1
  }
done
for rejected_registration in duplicate:2 conflict:source-or-bundle-id unknown:bundle-id; do
  if HOME="${missing_app_home}" \
      LINNET_FAKE_REGISTRATION_STATE="${rejected_registration}" \
      "${scripts_root}/preinstall" >/dev/null 2>&1; then
    echo "Complete accepted unrecoverable TIS residue ${rejected_registration}." >&2
    exit 1
  fi
done

# Complete may repair bytes of an existing CMS App, but that update must leave
# its user-owned registration and enablement untouched.
if [[ "${candidate_fixture_available}" == true ]]; then
  healthy_complete_home="${test_root}/complete-healthy/home"
  prepare_signed_postinstall_home "${healthy_complete_home}"
  HOME="${healthy_complete_home}" \
      LINNET_FAKE_REGISTRATION_STATE=registered:enabled-observation:selectable:path-unknown \
      LINNET_FAKE_RUNTIME_STATE=healthy \
      "${scripts_root}/preinstall" || {
    echo "Complete preinstall rejected the explicitly selected healthy repair." >&2
    exit 1
  }
  complete_repair_log="${test_root}/complete-healthy/host-invocations"
  printf 'old complete bytes\n' \
    >"${healthy_complete_home}/Library/Input Methods/Linnet.app/Contents/repair-before"
  stage_complete_candidate "${healthy_complete_home}"
  before_app_identity="$(stat -f '%d:%i' "${healthy_complete_home}/Library/Input Methods/Linnet.app")"
  HOME="${healthy_complete_home}" \
      LINNET_FAKE_REGISTRATION_STATE=registered:enabled-observation:selectable:path-unknown \
      LINNET_FAKE_RUNTIME_STATE=healthy \
      LINNET_FAKE_HOST_LOG="${complete_repair_log}" \
      LINNET_TEST_EXECUTABLE="${healthy_complete_home}/fake-Linnet" \
      "${scripts_root}/complete-postinstall" || {
    echo "Complete postinstall could not atomically repair a healthy App." >&2
    exit 1
  }
  [[ "$(stat -f '%d:%i' "${healthy_complete_home}/Library/Input Methods/Linnet.app")" == "${before_app_identity}" ]] || {
    echo "Complete repair replaced the registered App directory." >&2; exit 1;
  }
  [[ ! -e "${healthy_complete_home}/Library/Input Methods/Linnet.app/Contents/repair-before" ]] || {
    echo "Complete repair did not publish the staged candidate App." >&2; exit 1;
  }
  [[ ! -e "${complete_repair_log}" || ! -s "${complete_repair_log}" ]] || {
    echo "Complete repair of an existing App requested authorization." >&2; exit 1;
  }
  [[ ! -e "${healthy_complete_home}/Library/Application Support/Linnet/.linnet-complete" ]] || {
    echo "Complete repair retained its staging App." >&2; exit 1;
  }
  HOME="${healthy_complete_home}" \
      LINNET_FAKE_REGISTRATION_STATE=registered:enabled-observation:selectable:path-unknown \
      LINNET_FAKE_RUNTIME_STATE=invalid \
      "${scripts_root}/preinstall" >/dev/null 2>&1 && {
    echo "Complete accepted corrupt Runtime bytes as a repairable missing state." >&2
    exit 1
  }
fi

# The public Core artifact is update-only and may never install a Host that has
# no Active language snapshot from an earlier Complete install.
printf 'core-update\n' >"${scripts_root}/install-mode"
if HOME="${user_home}" "${scripts_root}/preinstall" >/dev/null 2>&1; then
  echo "Core update accepted a first installation without language data." >&2
  exit 1
fi

mkdir -p "${support_root}/Runtime/Active" "${support_root}/State"
cat >"${support_root}/Runtime/Active/activation.json" <<'JSON'
{
  "format": "io.github.ares-x.linnet.active-set.v1",
  "edition": "full",
  "generation": 1,
  "packs": [
    {"kind":"chinese","min_core":"0.1.0"},
    {"kind":"english","min_core":"0.1.0"},
    {"kind":"lts","min_core":"0.1.0"},
    {"kind":"extended","min_core":"0.1.0"}
  ]
}
JSON
core_missing_app_error="${test_root}/core-missing-app-error"
if HOME="${user_home}" "${scripts_root}/preinstall" \
    >/dev/null 2>"${core_missing_app_error}"; then
  echo "Core update accepted Active state without the registered App owner." >&2
  exit 1
fi
grep -Fq 'Linnet Complete' "${core_missing_app_error}" || {
  cat "${core_missing_app_error}" >&2
  echo "Core missing-App failure did not direct the user to Complete repair." >&2
  exit 1
}
if [[ "${candidate_fixture_available}" == true ]]; then
  copy_candidate_app "${user_home}"
fi
legacy_host_log="${test_root}/legacy-host-invocations"
if ! HOME="${user_home}" LINNET_LEGACY_HOST_LOG="${legacy_host_log}" \
    "${scripts_root}/preinstall"; then
  echo "Core preinstall could not upgrade the exact legacy Host contract." >&2
  exit 1
fi
[[ ! -e "${legacy_host_log}" || ! -s "${legacy_host_log}" ]] || {
  echo "Core preinstall invoked the legacy InputMethodKit Host before payload replacement." >&2
  exit 1
}
if HOME="${user_home}" LINNET_FAKE_REGISTRATION_STATE=missing \
    "${scripts_root}/preinstall" >/dev/null 2>"${test_root}/core-missing-registration"; then
  echo "Core update accepted a missing TIS registration." >&2
  exit 1
fi
grep -Fq 'Linnet Complete' "${test_root}/core-missing-registration" || {
  echo "Core missing-registration failure did not direct the user to Complete." >&2
  exit 1
}
for rejected_registration in duplicate:2 conflict:source-or-bundle-id unknown:bundle-id; do
  if HOME="${user_home}" \
      LINNET_FAKE_REGISTRATION_STATE="${rejected_registration}" \
      "${scripts_root}/preinstall" >/dev/null 2>&1; then
    echo "Core accepted conflicting TIS state ${rejected_registration}." >&2
    exit 1
  fi
done
[[ ! -e "${support_root}/Transactions" && ! -L "${support_root}/Transactions" ]] || {
  echo "Core preinstall created the runtime-owned Transactions directory." >&2
  exit 1
}
[[ ! -e "${support_root}/State/core-update-selection-v1.plist" ]] || {
  echo "Core preinstall persisted retired input-source state." >&2
  exit 1
}

# The explicit legacy public-signing edge remains a supported Core source now
# that Core carries one sealed candidate rather than one baseline-specific delta.
if [[ "${candidate_fixture_available}" == true ]]; then
  configure_installed_identity "${user_home}" legacy-community-adhoc
  HOME="${user_home}" "${scripts_root}/preinstall"
  configure_installed_identity "${user_home}" same-community-cms-leaf
  HOME="${user_home}" "${scripts_root}/preinstall"
fi

if [[ "${candidate_fixture_available}" == true ]]; then
  if [[ "${candidate_identity_format}" == 1 || "${candidate_identity_format}" == 3 ]]; then
    write_candidate_identity "${candidate_version}" "${candidate_build}" \
      "${candidate_revision}" "${wrong_leaf}"
  else
    write_candidate_identity "${candidate_version}" "${candidate_build}" \
      "${candidate_revision}" "" 2 invalid-community-trust
  fi
  if HOME="${user_home}" "${scripts_root}/preinstall" >/dev/null 2>&1; then
    echo "Core preinstall accepted a conflicting candidate trust identity." >&2
    exit 1
  fi
  write_candidate_identity "${candidate_version}" "${candidate_build}" \
    "${candidate_revision}" "${candidate_leaf}"
fi

if HOME="${user_home}" LINNET_FAKE_RUNTIME_STATE=invalid \
    "${scripts_root}/preinstall" >/dev/null 2>&1; then
  echo "Core update accepted Runtime bytes rejected by the canonical inspector." >&2
  exit 1
fi
HOME="${user_home}" "${scripts_root}/preinstall"

chmod 0777 "${support_root}/Runtime/Active"
if HOME="${user_home}" "${scripts_root}/preinstall" >/dev/null 2>&1; then
  echo "Core update accepted a group/world-writable Active directory." >&2
  exit 1
fi
chmod 0755 "${support_root}/Runtime/Active"

printf 'invalid\n' >"${scripts_root}/install-mode"
if HOME="${user_home}" "${scripts_root}/preinstall" >/dev/null 2>&1; then
  echo "Core preinstall accepted an unknown package mode." >&2
  exit 1
fi
printf 'complete\n' >"${scripts_root}/install-mode"


# Packaging must not invoke LaunchServices' private registration utility.
if rg -n 'LaunchServices\.framework/Support/lsregister|[[:space:]]lsregister[[:space:]]+-[uf]' \
    package/make_package package/make_archive package/verify_package; then
  echo "A private LaunchServices cleanup path returned." >&2
  exit 1
fi


echo "Linnet package lifecycle fixtures: PASS"
