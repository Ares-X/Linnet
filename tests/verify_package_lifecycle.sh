#!/usr/bin/env bash

set -euo pipefail

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
cp package/installer-scripts/candidate-app-identity.sh \
  "${scripts_root}/candidate-app-identity.sh"
cat >"${scripts_root}/input-source-registration-inspector" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 1 && "$1" == io.github.ares-x.inputmethod.Linnet ]]
printf '%s\n' "${LINNET_FAKE_REGISTRATION_STATE:-registered:bundle-match:path-unknown}"
SH
cat >"${scripts_root}/linnet-runtime-inspector" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 3 && "$1" == probe &&
  "$2" == 0.1.0 && "$3" == "${HOME}/Library/Application Support" ]]
[[ -z "${LINNET_FAKE_RUNTIME_LOG:-}" ]] || printf '%s\n' "$*" >>"${LINNET_FAKE_RUNTIME_LOG}"
case "${LINNET_FAKE_RUNTIME_STATE:-auto}" in
  healthy)
    [[ -f "$3/Linnet/Runtime/Active/activation.json" ]] || exit 1
    printf 'healthy\n'
    ;;
  missing)
    printf 'missing\n'
    ;;
  invalid)
    exit 1
    ;;
  auto)
    if [[ -f "$3/Linnet/Runtime/Active/activation.json" ]]; then
      printf 'healthy\n'
    else
      printf 'missing\n'
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
certificate_prefix=
for argument in "$@"; do
  target="${argument}"
  case "${argument}" in
    --extract-certificates=*) certificate_prefix="${argument#*=}" ;;
  esac
done
fixture="${target}/Contents/Resources/LinnetLifecycleFixture"
kind="$(cat "${fixture}/signature-kind")"
case " $* " in
  *' --verify '*)
    [[ "${kind}" != invalid ]]
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
  *)
    if [[ -n "${certificate_prefix}" ]]; then
      case "${kind}" in
        community-cms|unknown-cms)
          cp "${fixture}/certificate" "${certificate_prefix}0"
          ;;
        wrong-community-cms)
          cp "${fixture}/wrong-certificate" "${certificate_prefix}0"
          ;;
        *) exit 1 ;;
      esac
    else
      exit 1
    fi
    ;;
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
sed -i '' 's#^executable="${app_path}/Contents/MacOS/Linnet"$#executable="${LINNET_TEST_EXECUTABLE:-${app_path}/Contents/MacOS/Linnet}"#' \
  "${scripts_root}/postinstall"
printf '0.1.0\n' >"${scripts_root}/candidate-core-version"

candidate_fixture="${test_root}/fixed-community-cms/Linnet.app"
candidate_fixture_available=true
candidate_version=0.1.13
candidate_build=31
candidate_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
candidate_leaf=553fb445ae10b48c395ee01aad3630f03c05d3da40f84db89b97d91039e72aff
wrong_candidate_leaf=bb696adf3a500641c2b5fef7af6436a10ed7a4552302d5d77066fd44099d48f0
candidate_identity_format=3
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
    else abort
    end
    File.binwrite(ARGV.fetch(7), JSON.generate(document) + "\n")
  ' "${format}" "${version}" "${build}" "${revision}" "${leaf}" \
    "${trust_model}" "${profile}" \
    "${scripts_root}/candidate-app-identity.json"
  chmod 0644 "${scripts_root}/candidate-app-identity.json"
}
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
rg -Fq 'document["format"] = 3' package/make_package
rg -Fq 'candidate_identity["format"] = 3' package/verify_package
if rg -n 'core-update-selection|prior_enablement|TISDisable|TISEnableInputSource|TISSelectInputSource|--activate-input-source|--disable-input-source|--select-input-source|--refresh-core-input-source' \
    package/core-installer-scripts/preinstall package/installer-scripts \
    sources/InputSource.swift sources/Main.swift; then
  echo "Installer regained a user-owned input-source state path." >&2
  exit 1
fi
test "$(rg -F -c 'TISRegisterInputSource' sources/InputSource.swift)" = 1
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
test "$(rg -F -c -- '"${executable}" --register-input-source' \
  package/installer-scripts/postinstall)" = 1
if rg -n 'missing-app-install' package/core-installer-scripts/preinstall \
    package/installer-scripts/candidate-app-identity.sh; then
  echo "The ambiguous missing-App repair transition returned." >&2
  exit 1
fi
rg -Fq 'clean-complete-install' package/core-installer-scripts/preinstall \
  package/installer-scripts/candidate-app-identity.sh
for visible_installer_text in package/WELCOME.md package/Conclusion-summary.txt; do
  rg -Fq 'Complete is the sole registration owner' "${visible_installer_text}"
  rg -Fq 'supported, signature-verified App repair.' "${visible_installer_text}"
  rg -Fq 'Complete 是全新首次安装或受支持、已验证签名 App 修复的' \
    "${visible_installer_text}"
  rg -Fq 'Healthy installations use Core for routine updates.' \
    "${visible_installer_text}"
  rg -Fq '健康安装的常规升级只使用 Core。' "${visible_installer_text}"
  rg -Fq 'If Core reports only a missing registration, run Complete to repair it.' \
    "${visible_installer_text}"
  rg -Fq '若 Core 仅报告输入源未注册，请运行 Complete 修复。' \
    "${visible_installer_text}"
  rg -Fq 'If Core reports duplicate, conflicting, or unverifiable registration remnants,' \
    "${visible_installer_text}"
  rg -Fq 'run the official uninstaller first, then install Complete.' \
    "${visible_installer_text}"
  rg -Fq '若 Core 报告重复、冲突或无法验证的注册残留，' \
    "${visible_installer_text}"
  rg -Fq '请先运行官方卸载器，再安装 Complete。' "${visible_installer_text}"
done
if rg -n 'A first Complete installation registers|Complete rejects an existing App|首次 Complete 只注册|Complete 会拒绝.*已有 App' \
    package/WELCOME.md package/Conclusion-summary.txt; then
  echo "Installer-visible text restored the clean-install-only Complete contract." >&2
  exit 1
fi
if rg -n 'historical client|历史客户端应用|关闭本次登录期间使用过 Linnet' \
    package/WELCOME.md package/Conclusion-summary.txt; then
  echo "Installer-visible text restored application quiescence or client-history requirements." >&2
  exit 1
fi
for visible_installer_text in package/WELCOME.md package/Conclusion-summary.txt; do
  rg -Fq 'Other applications stay open' "${visible_installer_text}"
  rg -Fq '其他应用保持打开' "${visible_installer_text}"
  rg -Fq 'Settings' "${visible_installer_text}"
done
rg -Fq 'Registration mutation is exclusively a Complete clean-install or' \
  package/installer-scripts/postinstall
rg -Fq 'supported-repair boundary.' package/installer-scripts/postinstall
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

# Complete owns first registration and still requires one fresh login. The
# Core-only product is update-only: it closes Settings but deliberately leaves
# the live InputMethodKit Host and its per-application connections untouched.
ruby -rrexml/document -e '
  component = REXML::Document.new(File.binread(ARGV.shift)).root
  abort "component duplicates the product conclusion owner" if
    component&.attributes&.key?("postinstall-action")
  complete, core = ARGV
  documents = [complete, core].map do |path|
    REXML::Document.new(File.binread(path)).root
  end
  complete_ref = documents[0].get_elements("pkg-ref")
    .find { |ref| ref.attributes["version"] }
  core_ref = documents[1].get_elements("pkg-ref")
    .find { |ref| ref.attributes["version"] }
  abort "Complete stopped requiring its first-login boundary" unless
    complete_ref&.attributes&.[]("onConclusion") == "RequireLogout"
  abort "Core update still requires an unnecessary logout" if
    core_ref&.attributes&.key?("onConclusion")
  documents.each_with_index do |document, index|
    close = document.get_elements("pkg-ref/must-close")
    abort "Core payload must have one Apple must-close contract" unless close.length == 1
    ids = close.first.get_elements("app").map { |app| app.attributes["id"] }
    expected = index.zero? ? %w[
      io.github.ares-x.inputmethod.Linnet
      io.github.ares-x.inputmethod.Linnet.settings
    ] : %w[io.github.ares-x.inputmethod.Linnet.settings]
    abort "must-close does not own the edition lifecycle" unless ids == expected
  end
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
printf '%s\n' "$*" >>"${LINNET_FAKE_HOST_LOG:?}"
SH
  chmod 755 "${app}/Contents/MacOS/Linnet"
  printf '{}\n' >"${support}/Runtime/Active/activation.json"
  ln -s ../Runtime/Active/activation.json "${support}/State/active.json"
}

prepare_signed_postinstall_home() {
  local home="$1"
  local support="${home}/Library/Application Support/Linnet"
  local fake_executable="${home}/fake-Linnet"
  copy_candidate_app "${home}"
  mkdir -p "${support}/Runtime/Active" "${support}/State"
  printf '{}\n' >"${support}/Runtime/Active/activation.json"
  ln -s ../Runtime/Active/activation.json "${support}/State/active.json"
  cat >"${fake_executable}" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LINNET_FAKE_HOST_LOG:?}"
SH
  chmod 755 "${fake_executable}"
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
      "${scripts_root}/postinstall" >/dev/null 2>&1; then
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

# Postinstall is the distinct post-payload identity boundary. Complete performs
# the only first-install registration; Core must make no Host CLI call.
if [[ "${candidate_fixture_available}" == true ]]; then
  postinstall_home="${test_root}/postinstall-positive/home"
  postinstall_log="${test_root}/postinstall-positive/host-invocations"
  postinstall_runtime_log="${test_root}/postinstall-positive/runtime-inspections"
  prepare_signed_postinstall_home "${postinstall_home}"
  HOME="${postinstall_home}" LINNET_FAKE_HOST_LOG="${postinstall_log}" \
    LINNET_FAKE_RUNTIME_LOG="${postinstall_runtime_log}" \
    LINNET_TEST_EXECUTABLE="${postinstall_home}/fake-Linnet" \
    "${scripts_root}/postinstall"
  [[ "$(cat "${postinstall_log}")" == '--register-input-source' ]] || {
    echo "Complete postinstall did not perform exactly first registration." >&2
    exit 1
  }
  grep -Fxq "probe 0.1.0 ${postinstall_home}/Library/Application Support" \
    "${postinstall_runtime_log}" || {
    echo "Complete postinstall did not use the read-only Runtime probe." >&2
    exit 1
  }

  invalid_runtime_home="${test_root}/postinstall-invalid-runtime/home"
  invalid_runtime_log="${test_root}/postinstall-invalid-runtime/host-invocations"
  prepare_signed_postinstall_home "${invalid_runtime_home}"
  if HOME="${invalid_runtime_home}" LINNET_FAKE_HOST_LOG="${invalid_runtime_log}" \
      LINNET_TEST_EXECUTABLE="${invalid_runtime_home}/fake-Linnet" \
      LINNET_FAKE_RUNTIME_STATE=invalid \
      "${scripts_root}/postinstall" >/dev/null 2>&1; then
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
  core_postinstall_home="${test_root}/postinstall-core/home"
  core_postinstall_log="${test_root}/postinstall-core/host-invocations"
  prepare_signed_postinstall_home "${core_postinstall_home}"
  HOME="${core_postinstall_home}" LINNET_FAKE_HOST_LOG="${core_postinstall_log}" \
    LINNET_TEST_EXECUTABLE="${core_postinstall_home}/fake-Linnet" \
    "${scripts_root}/postinstall"
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
    "${scripts_root}/postinstall" >/dev/null 2>&1; then
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
    LINNET_FAKE_REGISTRATION_STATE=registered:bundle-match:path-unknown \
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
ln -s ../Runtime/Active/activation.json \
  "${missing_app_home}/Library/Application Support/Linnet/State/active.json"
for repair_registration in missing registered:bundle-match:path-unknown; do
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

# Complete is a first-install and damaged-state repair owner, not an alternate
# routine updater. A fully healthy signed App, exact TIS registration and
# validated immutable runtime must use Core so an installed user is never sent
# through Complete's one-time logout boundary again.
if [[ "${candidate_fixture_available}" == true ]]; then
  healthy_complete_home="${test_root}/complete-healthy/home"
  healthy_complete_error="${test_root}/complete-healthy/error"
  copy_candidate_app "${healthy_complete_home}"
  mkdir -p "${healthy_complete_home}/Library/Application Support/Linnet/Runtime/Active" \
    "${healthy_complete_home}/Library/Application Support/Linnet/State"
  printf '{}\n' \
    >"${healthy_complete_home}/Library/Application Support/Linnet/Runtime/Active/activation.json"
  ln -s ../Runtime/Active/activation.json \
    "${healthy_complete_home}/Library/Application Support/Linnet/State/active.json"
  if HOME="${healthy_complete_home}" \
      LINNET_FAKE_REGISTRATION_STATE=registered:bundle-match:path-unknown \
      LINNET_FAKE_RUNTIME_STATE=healthy \
      "${scripts_root}/preinstall" >/dev/null 2>"${healthy_complete_error}"; then
    echo "Complete accepted a fully healthy installation and would require another logout." >&2
    exit 1
  fi
  grep -Fq 'Core' "${healthy_complete_error}" || {
    echo "Complete healthy-install rejection did not direct the user to Core." >&2
    exit 1
  }
  HOME="${healthy_complete_home}" \
    LINNET_FAKE_REGISTRATION_STATE=registered:bundle-match:path-unknown \
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
ln -s ../Runtime/Active/activation.json "${support_root}/State/active.json"
core_missing_app_error="${test_root}/core-missing-app-error"
if HOME="${user_home}" "${scripts_root}/preinstall" \
    >/dev/null 2>"${core_missing_app_error}"; then
  echo "Core update accepted Active state without the registered App owner." >&2
  exit 1
fi
grep -Fq 'Linnet Complete' "${core_missing_app_error}" || {
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

# The signing migration remains an App identity decision only; it must not gain
# an input-source enablement or selection transaction.
if [[ "${candidate_fixture_available}" == true ]]; then
  configure_installed_identity "${user_home}" legacy-community-adhoc
  HOME="${user_home}" "${scripts_root}/preinstall"
  configure_installed_identity "${user_home}" exact-community-cms
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

# Core and uninstall have no broad process-control command. The exact
# no-execution uninstall contract is exercised below before its structural
# retirement gate, so a regression fails on behavior rather than source text.
if rg -Fq -- '--quit-host-clean' sources/Main.swift package/installer-scripts; then
  echo "A retired Core Host termination path returned." >&2
  exit 1
fi
if rg -n 'killall|pkill' package/uninstall-linnet sources/Main.swift; then
  echo "Product uninstall gained a broad process-kill path." >&2
  exit 1
fi
if rg -Fq '"${host_cli}" --disable-input-source' package/uninstall-linnet; then
  echo "Default uninstall mutates Text Input state before preserving user data." >&2
  exit 1
fi

# Registration mutation is a Complete boundary. Core consumes the package
# helper's typed, read-only TIS classification and never registers.
rg -Fq 'case registrationFailed(OSStatus)' sources/InputSource.swift
if ! rg -Fq 'static func classify' sources/LinnetInputSourceRegistration.swift ||
    ! rg -Fq 'registered:bundle-match:path-unknown' \
      sources/LinnetInputSourceRegistration.swift; then
  echo "The typed, read-only TIS owner is missing." >&2
  exit 1
fi
if rg -Fq 'registrationRequired' sources/InputSource.swift; then
  echo "TIS resolution retained a second count interpretation." >&2
  exit 1
fi

# The product config is the sole build-identity owner. Lifecycle verification
# checks its contract without copying a particular release's build number.
project_builds="$(sed -n 's/^CURRENT_PROJECT_VERSION = \([1-9][0-9]*\)$/\1/p' \
  config/LinnetProduct.xcconfig)"
[[ "$(printf '%s\n' "${project_builds}" | sed '/^$/d' | wc -l | tr -d ' ')" == 1 ]] || {
  echo "Product config must own exactly one positive integer build identity." >&2
  exit 1
}
rg -Fq 'if edition == "complete" && kind == "core"' package/verify_package

# The user-owned support root is a deletion trust boundary. A replaced root
# symlink must fail closed without touching any content behind that link.
uninstall_fixture="${scripts_root}/uninstall-linnet"
pkgutil_fixture="${scripts_root}/pkgutil"
ps_fixture="${scripts_root}/ps"
uninstall_stat_fixture="${scripts_root}/uninstall-stat"
cp package/uninstall-linnet "${uninstall_fixture}"
cat >"${pkgutil_fixture}" <<'SH'
#!/usr/bin/env bash
if [[ -n "${LINNET_FAKE_PKGUTIL_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"${LINNET_FAKE_PKGUTIL_LOG}"
  exit 0
fi
exit 1
SH
cat >"${ps_fixture}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '-axo command=' ]]
[[ -z "${LINNET_FAKE_PS_COMMANDS:-}" ]] || printf '%s\n' "${LINNET_FAKE_PS_COMMANDS}"
SH
cat >"${uninstall_stat_fixture}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
path=""
for argument in "$@"; do path="${argument}"; done
if [[ -n "${LINNET_FAKE_MOUNT_PATH:-}" && "${path}" == "${LINNET_FAKE_MOUNT_PATH}" ]]; then
  case "${2:-}" in
    '%u %d') printf '%s %s\n' "$(/usr/bin/id -u)" 2147483647 ;;
    '%d') printf '%s\n' 2147483647 ;;
    *) exec /usr/bin/stat "$@" ;;
  esac
else
  exec /usr/bin/stat "$@"
fi
SH
chmod +x "${uninstall_fixture}" "${pkgutil_fixture}" "${ps_fixture}" \
  "${uninstall_stat_fixture}"
sed -i '' "s#/usr/sbin/pkgutil#${pkgutil_fixture}#g" "${uninstall_fixture}"
sed -i '' "s#/bin/ps#${ps_fixture}#g" "${uninstall_fixture}"
sed -i '' "s#/usr/bin/stat#${uninstall_stat_fixture}#g" "${uninstall_fixture}"
external_support="${test_root}/external-support"
mkdir -p "${external_support}/Data"
printf 'external sentinel\n' >"${external_support}/Data/sentinel"
mkdir -p "${user_home}/Library/Application Support"
rm -rf "${support_root}"
ln -s "${external_support}" "${support_root}"
if HOME="${user_home}" "${uninstall_fixture}" >/dev/null 2>&1; then
  echo "Uninstall accepted a symbolic-link Application Support root." >&2
  exit 1
fi
[[ -f "${external_support}/Data/sentinel" ]] || {
  echo "Uninstall traversed a symbolic-link Application Support root." >&2
  exit 1
}

# A damaged or unverifiable App is never executed. When exact Host and Settings
# processes are absent, the official uninstaller still owns safe cleanup of the
# App and generated roots while preserving every personal-data owner.
damaged_home="${test_root}/damaged-home"
damaged_support="${damaged_home}/Library/Application Support/Linnet"
damaged_app="${damaged_home}/Library/Input Methods/Linnet.app"
damaged_host="${damaged_app}/Contents/MacOS/Linnet"
damaged_host_log="${test_root}/damaged-host-invocations"
mkdir -p "${damaged_app}/Contents/MacOS" "${damaged_support}/Data" \
  "${damaged_support}/UserData" "${damaged_support}/Backups" \
  "${damaged_support}/Transactions"
cat >"${damaged_host}" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LINNET_FAKE_UNINSTALL_HOST_LOG:?}"
exit 0
SH
chmod 0755 "${damaged_host}"
printf 'damaged install sentinel\n' >"${damaged_support}/Data/sentinel"
printf 'personal\n' >"${damaged_support}/UserData/sentinel"
printf 'backup\n' >"${damaged_support}/Backups/sentinel"
printf 'transaction\n' >"${damaged_support}/Transactions/sentinel"
HOME="${damaged_home}" LINNET_FAKE_PS_COMMANDS= \
  LINNET_FAKE_UNINSTALL_HOST_LOG="${damaged_host_log}" \
  "${uninstall_fixture}" >/dev/null
[[ ! -e "${damaged_app}" && ! -e "${damaged_support}/Data" ]] || {
  echo "Uninstall retained damaged App or generated data after proving processes absent." >&2
  exit 1
}
[[ ! -e "${damaged_host_log}" && \
  "$(cat "${damaged_support}/UserData/sentinel")" == personal && \
  "$(cat "${damaged_support}/Backups/sentinel")" == backup && \
  "$(cat "${damaged_support}/Transactions/sentinel")" == transaction ]] || {
  echo "Uninstall executed damaged bytes or changed retained personal data." >&2
  exit 1
}

damaged_running_home="${test_root}/damaged-running-home"
damaged_running_support="${damaged_running_home}/Library/Application Support/Linnet"
damaged_running_app="${damaged_running_home}/Library/Input Methods/Linnet.app"
damaged_running_host="${damaged_running_app}/Contents/MacOS/Linnet"
mkdir -p "${damaged_running_app}/Contents/MacOS" \
  "${damaged_running_support}/Data"
printf '#!/usr/bin/env bash\nexit 0\n' >"${damaged_running_host}"
chmod 0755 "${damaged_running_host}"
printf 'generated\n' >"${damaged_running_support}/Data/sentinel"
if HOME="${damaged_running_home}" \
    LINNET_FAKE_PS_COMMANDS="${damaged_running_host}" \
    "${uninstall_fixture}" >/dev/null 2>&1; then
  echo "Uninstall removed damaged bytes while the exact Host process was running." >&2
  exit 1
fi
[[ -f "${damaged_running_support}/Data/sentinel" && \
  -d "${damaged_running_app}" ]] || {
  echo "Uninstall changed damaged state before proving product processes absent." >&2
  exit 1
}

damaged_settings_home="${test_root}/damaged-settings-running-home"
damaged_settings_support="${damaged_settings_home}/Library/Application Support/Linnet"
damaged_settings_app="${damaged_settings_home}/Library/Input Methods/Linnet.app"
damaged_settings_cli="${damaged_settings_app}/Contents/Applications/Settings.app/Contents/MacOS/Settings"
mkdir -p "${damaged_settings_app}/Contents/MacOS" \
  "$(dirname "${damaged_settings_cli}")" "${damaged_settings_support}/Data"
printf '#!/usr/bin/env bash\nexit 0\n' \
  >"${damaged_settings_app}/Contents/MacOS/Linnet"
printf '#!/usr/bin/env bash\nexit 0\n' >"${damaged_settings_cli}"
chmod 0755 "${damaged_settings_app}/Contents/MacOS/Linnet" \
  "${damaged_settings_cli}"
printf 'generated\n' >"${damaged_settings_support}/Data/sentinel"
if HOME="${damaged_settings_home}" \
    LINNET_FAKE_PS_COMMANDS="${damaged_settings_cli}" \
    "${uninstall_fixture}" >/dev/null 2>&1; then
  echo "Uninstall removed bytes while the exact Settings process was running." >&2
  exit 1
fi
[[ -f "${damaged_settings_support}/Data/sentinel" && \
  -d "${damaged_settings_app}" ]] || {
  echo "Uninstall changed state before proving Settings was stopped." >&2
  exit 1
}

# If the App is already absent, the official uninstaller must still provide a
# reachable recovery path for safe Linnet-generated residue. It may do so only
# after proving the exact deleted-on-disk Host and Settings executables are not
# running; personal data remains byte-for-byte owned by the user. After the
# required fresh login clears TIS remnants, Complete must be reachable again.
missing_app_recovery_home="${test_root}/missing-app-recovery/home"
missing_app_recovery_support="${missing_app_recovery_home}/Library/Application Support/Linnet"
mkdir -p "${missing_app_recovery_home}/Library/Input Methods" \
  "${missing_app_recovery_support}/Data" \
  "${missing_app_recovery_support}/Runtime" \
  "${missing_app_recovery_support}/State" \
  "${missing_app_recovery_support}/UserData" \
  "${missing_app_recovery_support}/Backups" \
  "${missing_app_recovery_support}/Transactions"
printf 'generated\n' >"${missing_app_recovery_support}/Data/sentinel"
printf 'personal\n' >"${missing_app_recovery_support}/UserData/sentinel"
printf 'backup\n' >"${missing_app_recovery_support}/Backups/sentinel"
printf 'transaction\n' >"${missing_app_recovery_support}/Transactions/sentinel"
HOME="${missing_app_recovery_home}" LINNET_FAKE_PS_COMMANDS= \
  "${uninstall_fixture}" >/dev/null
[[ ! -e "${missing_app_recovery_support}/Data" && \
  ! -e "${missing_app_recovery_support}/Runtime" && \
  ! -e "${missing_app_recovery_support}/State" ]] || {
  echo "Uninstall left safe generated residue after the App was already absent." >&2
  exit 1
}
[[ "$(cat "${missing_app_recovery_support}/UserData/sentinel")" == personal && \
  "$(cat "${missing_app_recovery_support}/Backups/sentinel")" == backup && \
  "$(cat "${missing_app_recovery_support}/Transactions/sentinel")" == transaction ]] || {
  echo "Uninstall changed personal data while recovering a missing App." >&2
  exit 1
}
HOME="${missing_app_recovery_home}" LINNET_FAKE_REGISTRATION_STATE=missing \
  "${scripts_root}/preinstall" >/dev/null || {
  echo "Fresh-login missing-App recovery did not lead back to Complete." >&2
  exit 1
}

running_missing_app_home="${test_root}/missing-app-running/home"
running_missing_app_support="${running_missing_app_home}/Library/Application Support/Linnet"
running_host="${running_missing_app_home}/Library/Input Methods/Linnet.app/Contents/MacOS/Linnet"
mkdir -p "${running_missing_app_home}/Library/Input Methods" \
  "${running_missing_app_support}/Data"
printf 'generated\n' >"${running_missing_app_support}/Data/sentinel"
if HOME="${running_missing_app_home}" LINNET_FAKE_PS_COMMANDS="${running_host}" \
    "${uninstall_fixture}" >/dev/null 2>&1; then
  echo "Uninstall removed missing-App residue while the exact Host process was still running." >&2
  exit 1
fi
[[ -f "${running_missing_app_support}/Data/sentinel" ]] || {
  echo "Uninstall changed missing-App residue before proving the Host was stopped." >&2
  exit 1
}

# A user-owned App is never executable authority for its own deletion, even
# when an arbitrary codesign command reports it valid. The canonical
# uninstaller must still retire an immutable pack tree after proving exact
# product processes absent, without following a nested symbolic link or
# changing personal-data owners.
immutable_home="${test_root}/immutable-home"
immutable_app="${immutable_home}/Library/Input Methods/Linnet.app"
immutable_support="${immutable_home}/Library/Application Support/Linnet"
immutable_pack="${immutable_support}/Data/Packs/english/8-0.4.3"
immutable_external="${test_root}/immutable-external"
mkdir -p "${immutable_app}/Contents/MacOS" "${immutable_pack}/build" \
  "${immutable_support}/Runtime" "${immutable_support}/Build" \
  "${immutable_support}/Downloads" "${immutable_support}/State" \
  "${immutable_support}/Profiles" "${immutable_support}/UserData" \
  "${immutable_support}/Backups" "${immutable_support}/Transactions" \
  "${immutable_external}"
cat >"${immutable_app}/Contents/MacOS/Linnet" <<'SH'
#!/usr/bin/env bash
[[ -z "${LINNET_FAKE_UNINSTALL_HOST_LOG:-}" ]] || \
  printf '%s\n' "$*" >>"${LINNET_FAKE_UNINSTALL_HOST_LOG}"
exit 0
SH
chmod 0755 "${immutable_app}/Contents/MacOS/Linnet"
printf 'immutable generated data\n' >"${immutable_pack}/build/linnet_en.table.bin"
printf 'external sentinel\n' >"${immutable_external}/sentinel"
ln -s "${immutable_external}" "${immutable_pack}/external-link"
printf 'personal sentinel\n' >"${immutable_support}/UserData/sentinel"
printf 'backup sentinel\n' >"${immutable_support}/Backups/sentinel"
printf 'transaction sentinel\n' >"${immutable_support}/Transactions/sentinel"
chmod 0444 "${immutable_pack}/build/linnet_en.table.bin"
chmod 0555 "${immutable_pack}/build" "${immutable_pack}"
immutable_host_log="${test_root}/immutable-host-invocations"
HOME="${immutable_home}" LINNET_FAKE_PS_COMMANDS= \
  LINNET_FAKE_UNINSTALL_HOST_LOG="${immutable_host_log}" \
  "${uninstall_fixture}" >/dev/null
[[ ! -e "${immutable_host_log}" ]] || {
  echo "Uninstall executed user-owned App bytes." >&2
  exit 1
}
[[ ! -e "${immutable_app}" && ! -e "${immutable_support}/Data" && \
  ! -e "${immutable_support}/Runtime" && ! -e "${immutable_support}/Build" && \
  ! -e "${immutable_support}/Downloads" && ! -e "${immutable_support}/State" && \
  ! -e "${immutable_support}/Profiles" ]] || {
  echo "Uninstall left immutable or generated Linnet bytes behind." >&2
  exit 1
}
[[ "$(cat "${immutable_external}/sentinel")" == "external sentinel" ]] || {
  echo "Uninstall traversed a nested symbolic link while retiring immutable data." >&2
  exit 1
}
[[ "$(cat "${immutable_support}/UserData/sentinel")" == "personal sentinel" && \
  "$(cat "${immutable_support}/Backups/sentinel")" == "backup sentinel" && \
  "$(cat "${immutable_support}/Transactions/sentinel")" == "transaction sentinel" ]] || {
  echo "Uninstall changed retained Linnet data while retiring immutable data." >&2
  exit 1
}

# `rm -x` protects traversal below its starting hierarchy; it cannot establish
# that the starting App/support/generated target itself belongs to its parent
# filesystem. Simulate that device mismatch deterministically and require the
# complete preflight to fail before App/data removal or receipt mutation.
for mount_target_kind in app support generated; do
  mount_home="${test_root}/mounted-${mount_target_kind}-home"
  mount_app="${mount_home}/Library/Input Methods/Linnet.app"
  mount_host="${mount_app}/Contents/MacOS/Linnet"
  mount_support="${mount_home}/Library/Application Support/Linnet"
  mount_generated="${mount_support}/Data"
  mount_receipt_log="${test_root}/mounted-${mount_target_kind}-receipts"
  mkdir -p "$(dirname "${mount_host}")" "${mount_generated}" \
    "${mount_home}/Library/Preferences"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${mount_host}"
  chmod 0755 "${mount_host}"
  printf 'app sentinel\n' >"${mount_app}/sentinel"
  printf 'generated sentinel\n' >"${mount_generated}/sentinel"
  printf 'preference sentinel\n' \
    >"${mount_home}/Library/Preferences/io.github.ares-x.inputmethod.Linnet.plist"
  case "${mount_target_kind}" in
    app) mount_target="${mount_app}" ;;
    support) mount_target="${mount_support}" ;;
    generated) mount_target="${mount_generated}" ;;
    *) exit 1 ;;
  esac
  if HOME="${mount_home}" LINNET_FAKE_PS_COMMANDS= \
      LINNET_FAKE_MOUNT_PATH="${mount_target}" \
      LINNET_FAKE_PKGUTIL_LOG="${mount_receipt_log}" \
      "${uninstall_fixture}" >/dev/null 2>&1; then
    echo "Uninstall accepted a mounted ${mount_target_kind} deletion target." >&2
    exit 1
  fi
  [[ "$(cat "${mount_app}/sentinel")" == "app sentinel" && \
    "$(cat "${mount_generated}/sentinel")" == "generated sentinel" && \
    "$(cat "${mount_home}/Library/Preferences/io.github.ares-x.inputmethod.Linnet.plist")" == \
      "preference sentinel" && ! -e "${mount_receipt_log}" ]] || {
    echo "Mounted ${mount_target_kind} preflight mutated App, data, preferences or receipts." >&2
    exit 1
  }
done
rg -Fq '/usr/bin/find -P -x "${path}" -type d -print0' package/uninstall-linnet
rg -Fq '/bin/chmod -h u+wx "${directory}"' package/uninstall-linnet

# CFPreferences leaves one empty physical plist after `defaults delete`. The
# explicit purge owns both the logical domain and that exact current-user file;
# neither may survive, and a replaced preference leaf must fail closed before
# the App or support root is removed.
purge_home="${test_root}/purge-home"
purge_app="${purge_home}/Library/Input Methods/Linnet.app"
purge_support="${purge_home}/Library/Application Support/Linnet"
purge_preferences="${purge_home}/Library/Preferences"
purge_defaults_fixture="${scripts_root}/defaults"
purge_uninstall_fixture="${scripts_root}/purge-uninstall-linnet"
purge_defaults_log="${test_root}/purge-defaults-log"
cat >"${purge_defaults_fixture}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
command="${1:-}"
domain="${2:-}"
case "${command}" in
  read) exit 1 ;;
  delete)
    printf '%s\n' "${command} ${domain}" >>"${LINNET_FAKE_DEFAULTS_LOG:?}"
    mkdir -p "${HOME}/Library/Preferences"
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
      '<plist version="1.0"><dict/></plist>' \
      >"${HOME}/Library/Preferences/${domain}.plist"
    ;;
  *) exit 2 ;;
esac
SH
cp package/uninstall-linnet "${purge_uninstall_fixture}"
chmod 0755 "${purge_defaults_fixture}" "${purge_uninstall_fixture}"
sed -i '' "s#/usr/sbin/pkgutil#${pkgutil_fixture}#g" "${purge_uninstall_fixture}"
sed -i '' "s#/usr/bin/defaults#${purge_defaults_fixture}#g" "${purge_uninstall_fixture}"
sed -i '' "s#/bin/ps#${ps_fixture}#g" "${purge_uninstall_fixture}"
mkdir -p "${purge_app}/Contents/MacOS" "${purge_support}/UserData" \
  "${purge_support}/Runtime/Logs" "${purge_preferences}"
cat >"${purge_app}/Contents/MacOS/Linnet" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod 0755 "${purge_app}/Contents/MacOS/Linnet"
printf 'persistent data\n' >"${purge_support}/UserData/sentinel"
printf 'runtime log\n' >"${purge_support}/Runtime/Logs/sentinel"
for domain in io.github.ares-x.inputmethod.Linnet \
    io.github.ares-x.inputmethod.Linnet.settings; do
  printf 'preference data\n' >"${purge_preferences}/${domain}.plist"
done
HOME="${purge_home}" LINNET_FAKE_DEFAULTS_LOG="${purge_defaults_log}" \
  "${purge_uninstall_fixture}" --purge-user-data >/dev/null
[[ ! -e "${purge_app}" && ! -e "${purge_support}" ]] || {
  echo "Explicit purge left App or Registry-owned support data behind." >&2
  exit 1
}
for domain in io.github.ares-x.inputmethod.Linnet \
    io.github.ares-x.inputmethod.Linnet.settings; do
  [[ ! -e "${purge_preferences}/${domain}.plist" && \
    ! -L "${purge_preferences}/${domain}.plist" ]] || {
    echo "Explicit purge left a physical preference residue." >&2
    exit 1
  }
  grep -Fxq "delete ${domain}" "${purge_defaults_log}"
done
test "$(wc -l <"${purge_defaults_log}" | tr -d ' ')" = 2

unsafe_purge_home="${test_root}/unsafe-purge-home"
unsafe_purge_app="${unsafe_purge_home}/Library/Input Methods/Linnet.app"
unsafe_purge_support="${unsafe_purge_home}/Library/Application Support/Linnet"
unsafe_purge_preferences="${unsafe_purge_home}/Library/Preferences"
unsafe_preference_target="${test_root}/unsafe-preference-target"
mkdir -p "${unsafe_purge_app}/Contents/MacOS" \
  "${unsafe_purge_support}/UserData" "${unsafe_purge_preferences}" \
  "${unsafe_preference_target}"
cat >"${unsafe_purge_app}/Contents/MacOS/Linnet" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod 0755 "${unsafe_purge_app}/Contents/MacOS/Linnet"
printf 'external preference sentinel\n' >"${unsafe_preference_target}/sentinel"
ln -s "${unsafe_preference_target}/sentinel" \
  "${unsafe_purge_preferences}/io.github.ares-x.inputmethod.Linnet.plist"
if HOME="${unsafe_purge_home}" \
    LINNET_FAKE_DEFAULTS_LOG="${test_root}/unsafe-purge-defaults-log" \
    "${purge_uninstall_fixture}" --purge-user-data >/dev/null 2>&1; then
  echo "Explicit purge accepted a symbolic-link preference leaf." >&2
  exit 1
fi
[[ "$(cat "${unsafe_preference_target}/sentinel")" == \
  "external preference sentinel" && -d "${unsafe_purge_app}" && \
  -d "${unsafe_purge_support}" ]] || {
  echo "Explicit purge crossed an unsafe preference boundary." >&2
  exit 1
}

empty_home="${test_root}/already-uninstalled-home"
mkdir -p "${empty_home}/Library"
receipt_log="${test_root}/user-volume-receipts"
HOME="${empty_home}" LINNET_FAKE_PKGUTIL_LOG="${receipt_log}" \
  "${uninstall_fixture}" >/dev/null
for receipt in \
  io.github.ares-x.inputmethod.Linnet.core.pkg \
  io.github.ares-x.inputmethod.Linnet.data.chinese.pkg \
  io.github.ares-x.inputmethod.Linnet.data.english.pkg \
  io.github.ares-x.inputmethod.Linnet.data.lts.pkg \
  io.github.ares-x.inputmethod.Linnet.data.extended.pkg \
  io.github.ares-x.inputmethod.Linnet.profile.pkg; do
  grep -Fxq -- "--volume ${empty_home} --pkg-info ${receipt}" "${receipt_log}"
  grep -Fxq -- "--volume ${empty_home} --forget ${receipt}" "${receipt_log}"
done
test "$(wc -l <"${receipt_log}" | tr -d ' ')" = 12

# Packaging must not invoke LaunchServices' private registration utility.
if rg -n 'LaunchServices\.framework/Support/lsregister|[[:space:]]lsregister[[:space:]]+-[uf]' \
    package/make_package package/make_archive package/verify_package \
    package/uninstall-linnet; then
  echo "A private LaunchServices cleanup path returned." >&2
  exit 1
fi

# Installed user-owned bytes are never a trust or process-lifecycle owner for
# their own removal. Product process absence and filesystem deletion preflight
# must complete without executing or signature-classifying the installed App.
if rg -n '/usr/bin/codesign|"\$\{host_cli\}" --(quit|purge-owned-temporary-state)' \
    package/uninstall-linnet; then
  echo "Uninstall regained an installed-App execution or trust path." >&2
  exit 1
fi
if rg -n 'quitProductProcesses|--purge-owned-temporary-state|forceTerminate\(\)' \
    sources/Main.swift; then
  echo "Host regained an uninstall-only process or cleanup CLI." >&2
  exit 1
fi
test "$(rg -F -c '/bin/rm -rf -x --' package/uninstall-linnet)" -eq 3
rg -Fq 'require_recursive_delete_target' package/uninstall-linnet
if rg -n 'getconf DARWIN_USER_TEMP_DIR|temporary_(root|log_path)' \
    package/uninstall-linnet; then
  echo "Uninstall regained a second runtime-log path owner." >&2
  exit 1
fi
if rg -Fq '/bin/rm -rf --' package/uninstall-linnet; then
  echo "Uninstall recursive deletion lost its filesystem boundary." >&2
  exit 1
fi

echo "Linnet package lifecycle fixtures: PASS"
