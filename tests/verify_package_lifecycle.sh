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
[[ -f package/installer-scripts/quit-applications-clean.jxa &&
  ! -L package/installer-scripts/quit-applications-clean.jxa ]] || {
  echo "Core update has no pre-payload cooperative process-quiescence owner." >&2
  exit 1
}
cp package/core-installer-scripts/preinstall "${scripts_root}/preinstall"
cp package/installer-scripts/postinstall "${scripts_root}/postinstall"
cp package/installer-scripts/candidate-app-identity.sh \
  "${scripts_root}/candidate-app-identity.sh"
cp package/installer-scripts/quit-applications-clean.jxa \
  "${scripts_root}/quit-applications-clean.jxa"
# The production script has no executable override. This isolated test copy
# redirects only the final Host CLI calls after the real finalized App has passed
# the package-owned identity gate.
sed -i '' 's#^executable="${app_path}/Contents/MacOS/Linnet"$#executable="${LINNET_TEST_EXECUTABLE:-${app_path}/Contents/MacOS/Linnet}"#' \
  "${scripts_root}/postinstall"
fake_osascript="${scripts_root}/fake-osascript"
cat >"${fake_osascript}" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${LINNET_FAKE_QUIESCER_LOG:?}"
if [[ "${LINNET_FAKE_QUIESCER_RESULT:-success}" == success ]]; then
  if [[ -n "${LINNET_FAKE_SELECTION_DOCUMENT:-}" ]]; then
    printf '%s\n' "${LINNET_FAKE_SELECTION_DOCUMENT}"
  else
    printf '%s\n' \
      '{"format":1,"target_input_source_id":"io.github.ares-x.inputmethod.Linnet","was_current":true,"post_quiescence_input_source_id":"com.apple.keylayout.ABC"}'
  fi
else
  exit 1
fi
SH
chmod 755 "${fake_osascript}"
# Production has no command override. The isolated copy records pre-payload
# intent without addressing the currently installed Host or Settings process.
sed -i '' "s#/usr/bin/osascript#${fake_osascript}#" "${scripts_root}/preinstall"
printf '0.1.0\n' >"${scripts_root}/candidate-core-version"

candidate_fixture="${LINNET_LIFECYCLE_CANDIDATE_APP:-${HOME}/Library/Input Methods/Linnet.app}"
candidate_fixture_available=false
candidate_version=0.1.0
candidate_build=1
candidate_revision=0000000000000000000000000000000000000000
candidate_leaf=0000000000000000000000000000000000000000000000000000000000000000
candidate_identity_format=1
candidate_trust_model=
candidate_version_file="${candidate_fixture}/Contents/Resources/LinnetRelease/VERSION.json"
if [[ -d "${candidate_fixture}" && ! -L "${candidate_fixture}" ]] && \
    /usr/bin/codesign --verify --deep --strict "${candidate_fixture}" >/dev/null 2>&1; then
  candidate_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - \
    "${candidate_fixture}/Contents/Info.plist")"
  candidate_build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - \
    "${candidate_fixture}/Contents/Info.plist")"
  candidate_revision="$(/usr/bin/plutil -extract source.candidate_revision raw -o - \
    "${candidate_version_file}")"
  candidate_profile="$(/usr/bin/plutil -extract \
    distribution.application_code_signature.profile raw -o - \
    "${candidate_version_file}")"
  case "${candidate_profile}" in
    uat)
      candidate_leaf="$(/usr/bin/plutil -extract \
        distribution.application_code_signature.leaf_certificate_sha256 raw -o - \
        "${candidate_version_file}")"
      candidate_fixture_available=true
      ;;
    community-adhoc)
      candidate_identity_format=2
      candidate_leaf=
      candidate_trust_model=unsigned-community
      candidate_fixture_available=true
      ;;
  esac
fi

write_candidate_identity() {
  local version="$1"
  local build="$2"
  local revision="$3"
  local leaf="$4"
  local format="${5:-${candidate_identity_format}}"
  local trust_model="${6:-${candidate_trust_model}}"
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
    else abort
    end
    File.binwrite(ARGV.fetch(6), JSON.generate(document) + "\n")
  ' "${format}" "${version}" "${build}" "${revision}" "${leaf}" \
    "${trust_model}" \
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
rg -Fq 'quit-applications-clean.jxa' package/core-installer-scripts/preinstall \
  package/make_package package/verify_package
rg -Fq 'core-update-selection-v1.plist' \
  package/core-installer-scripts/preinstall package/installer-scripts/postinstall
rg -Fq -- '--refresh-core-input-source' \
  package/installer-scripts/postinstall sources/Main.swift
if rg -Fq -- '--select-input-source' package/installer-scripts/postinstall; then
  echo "Core postinstall regained an unconditional input-source selection path." >&2
  exit 1
fi

# The package-owned helper uses exact LaunchServices identities and cooperative
# AppKit termination only. A refused request remains observable until timeout;
# there is no signal, force-quit, activation, enablement, or selection path.
quiescer=package/installer-scripts/quit-applications-clean.jxa
rg -Fq 'runningApplicationsWithBundleIdentifier' "${quiescer}"
rg -Fq 'Boolean(application.terminate)' "${quiescer}"
if rg -Fq 'application.terminate()' "${quiescer}"; then
  echo "Core application quiescence calls a JXA zero-argument method as a function." >&2
  exit 1
fi
rg -Fq 'applications refused to quit' "${quiescer}"
rg -Fq 'function quiesceApplication(bundleIdentifier, timeoutSeconds)' "${quiescer}" || {
  echo "Core application quiescence does not wait for each identity independently." >&2
  exit 1
}
rg -Fq 'quiesceApplication(bundleIdentifier, timeoutSeconds);' "${quiescer}" || {
  echo "Core application quiescence does not preserve the package-owned exit order." >&2
  exit 1
}
rg -Fq 'TISCopyCurrentKeyboardInputSource' "${quiescer}"
rg -Fq 'post_quiescence_input_source_id' "${quiescer}"
if rg -n 'forceTerminate|kill|pkill|killall|activate|enable|select' "${quiescer}"; then
  echo "Core application quiescence gained a forcing or input-state mutation path." >&2
  exit 1
fi
/usr/bin/osascript -l JavaScript "${quiescer}" 1 \
  io.github.ares-x.inputmethod.Linnet.lifecycle-test-source \
  io.github.ares-x.inputmethod.Linnet.lifecycle-test-settings \
  io.github.ares-x.inputmethod.Linnet.lifecycle-test-host >/dev/null
if /usr/bin/osascript -l JavaScript "${quiescer}" 0 \
    io.github.ares-x.inputmethod.Linnet.lifecycle-test-source \
    io.github.ares-x.inputmethod.Linnet.lifecycle-test-settings \
    io.github.ares-x.inputmethod.Linnet.lifecycle-test-host >/dev/null 2>&1; then
  echo "Core application quiescence accepted an invalid deadline." >&2
  exit 1
fi
rg -Fq 'if model.operationActive {' sources/LinnetSettings/SettingsMain.swift
rg -Fq 'return .terminateCancel' sources/LinnetSettings/SettingsMain.swift
rg -Fq 'guard model.pendingChanges else { return .terminateNow }' \
  sources/LinnetSettings/SettingsMain.swift
rg -Fq 'return .terminateLater' sources/LinnetSettings/SettingsMain.swift

copy_candidate_app() {
  local home="$1"
  local destination="${home}/Library/Input Methods/Linnet.app"
  mkdir -p "$(dirname "${destination}")"
  COPYFILE_DISABLE=1 ditto --norsrc --noextattr "${candidate_fixture}" "${destination}"
}

if [[ "${candidate_fixture_available}" == true ]]; then
  identity_home="${test_root}/candidate-identity/home"
  copy_candidate_app "${identity_home}"
  HOME="${identity_home}" "${scripts_root}/candidate-app-identity.sh" existing
  HOME="${identity_home}" "${scripts_root}/candidate-app-identity.sh" installed

  if [[ "${candidate_identity_format}" == 1 ]]; then
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
  if HOME="${identity_home}" "${scripts_root}/candidate-app-identity.sh" existing \
      >/dev/null 2>&1; then
    echo "Candidate identity owner accepted a same-build conflicting revision." >&2
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
  HOME="${identity_home}" "${scripts_root}/candidate-app-identity.sh" existing
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

# Complete owns first registration and still requires one fresh login.  The
# Core-only product is update-only: must-close prompts early, then the Core
# preinstall enforces exact Host/Settings quiescence immediately before payload
# replacement. The post-payload Host boundary catches only an InputMethodKit-
# relaunched Host before refreshing the same TIS identity without logging out.
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
  documents.each do |document|
    close = document.get_elements("pkg-ref/must-close")
    abort "Core payload must have one Apple must-close contract" unless close.length == 1
    ids = close.first.get_elements("app").map { |app| app.attributes["id"] }
    abort "must-close does not own exact Host and Settings identities" unless ids == %w[
      io.github.ares-x.inputmethod.Linnet
      io.github.ares-x.inputmethod.Linnet.settings
    ]
  end
' package/PackageInfo package/Distribution.xml package/Distribution-Core.xml
rg -Fq 'cp -X "${project_root}/package/installer-scripts/postinstall"' \
  package/make_package || {
  echo "Core update lost its post-payload TIS refresh." >&2
  exit 1
}
rg -Fq 'cp -X "${project_root}/package/installer-scripts/quit-applications-clean.jxa"' \
  package/make_package || {
  echo "Core update lost its pre-payload application quiescence owner." >&2
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

write_core_selection_token() {
  local home="$1"
  local was_current="$2"
  local post_quiescence_id="$3"
  local state="${home}/Library/Application Support/Linnet/State"
  mkdir -p "${state}"
  printf '{"format":1,"target_input_source_id":"io.github.ares-x.inputmethod.Linnet","was_current":%s,"post_quiescence_input_source_id":"%s","candidate_revision":"%s","candidate_build":"%s"}\n' \
    "${was_current}" "${post_quiescence_id}" "${candidate_revision}" \
    "${candidate_build}" |
    /usr/bin/plutil -convert binary1 -o \
      "${state}/core-update-selection-v1.plist" -
  chmod 0600 "${state}/core-update-selection-v1.plist"
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

# Postinstall is the distinct post-payload mutation boundary. A canonical tree
# must still invoke the exact lifecycle sequence, while a replaced App or Active
# parent must fail before the first Host CLI call.
if [[ "${candidate_fixture_available}" == true ]]; then
  postinstall_home="${test_root}/postinstall-positive/home"
  postinstall_log="${test_root}/postinstall-positive/host-invocations"
  prepare_signed_postinstall_home "${postinstall_home}"
  HOME="${postinstall_home}" LINNET_FAKE_HOST_LOG="${postinstall_log}" \
    LINNET_TEST_EXECUTABLE="${postinstall_home}/fake-Linnet" \
    "${scripts_root}/postinstall"
  [[ "$(cat "${postinstall_log}")" == \
    $'--quit-host-clean\n--register-input-source\n--enable-input-source' ]] || {
    echo "Complete postinstall did not validate, quiesce, register and enable the sole input source." >&2
    exit 1
  }
fi

# Core refreshes the unchanged TIS identity but must preserve a user's disabled
# state. The package-local mode is the only edition owner; Core therefore never
# invokes enable while Complete still does exactly once above.
printf 'core-update\n' >"${scripts_root}/install-mode"
if [[ "${candidate_fixture_available}" == true ]]; then
  core_postinstall_home="${test_root}/postinstall-core/home"
  core_postinstall_log="${test_root}/postinstall-core/host-invocations"
  prepare_signed_postinstall_home "${core_postinstall_home}"
  write_core_selection_token "${core_postinstall_home}" true com.apple.keylayout.ABC
  HOME="${core_postinstall_home}" LINNET_FAKE_HOST_LOG="${core_postinstall_log}" \
    LINNET_TEST_EXECUTABLE="${core_postinstall_home}/fake-Linnet" \
    "${scripts_root}/postinstall"
  [[ "$(cat "${core_postinstall_log}")" == \
    '--refresh-core-input-source true com.apple.keylayout.ABC' ]] || {
    echo "Core postinstall split quiescence, registration and selection continuity across multiple Host processes." >&2
    exit 1
  }
  [[ ! -e "${core_postinstall_home}/Library/Application Support/Linnet/State/core-update-selection-v1.plist" ]] || {
    echo "Core postinstall retained its one-shot selection token." >&2
    exit 1
  }

  unselected_postinstall_home="${test_root}/postinstall-core-unselected/home"
  unselected_postinstall_log="${test_root}/postinstall-core-unselected/host-invocations"
  prepare_signed_postinstall_home "${unselected_postinstall_home}"
  write_core_selection_token "${unselected_postinstall_home}" false \
    github.dongyuwei.inputmethod.hallelujahInputMethod
  HOME="${unselected_postinstall_home}" \
    LINNET_FAKE_HOST_LOG="${unselected_postinstall_log}" \
    LINNET_TEST_EXECUTABLE="${unselected_postinstall_home}/fake-Linnet" \
    "${scripts_root}/postinstall"
  [[ "$(cat "${unselected_postinstall_log}")" == \
    '--refresh-core-input-source false github.dongyuwei.inputmethod.hallelujahInputMethod' ]] || {
    echo "Core postinstall selected Linnet even though it was not current before update." >&2
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

# Complete is strictly the clean/reinstall product. Preserved personal data is
# not an installed Core, but any App or Active/state residue must fail closed;
# an existing healthy installation is told to use Core instead of earning a
# second logout boundary.
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
app_only_error="${test_root}/complete-app-only/error"
if HOME="${app_only_home}" "${scripts_root}/preinstall" 2>"${app_only_error}"; then
  echo "Complete preinstall accepted an existing App without Active/state." >&2
  exit 1
fi
if [[ "${candidate_fixture_available}" == true ]]; then
  grep -Fq 'Use Linnet Core' "${app_only_error}" || {
    echo "Complete rejection did not direct an existing installation to Core." >&2
    exit 1
  }
fi

active_only_home="${test_root}/complete-active-only/home"
mkdir -p "${active_only_home}/Library/Application Support/Linnet/Runtime/Active" \
  "${active_only_home}/Library/Application Support/Linnet/State"
printf '{}\n' >"${active_only_home}/Library/Application Support/Linnet/Runtime/Active/activation.json"
ln -s ../Runtime/Active/activation.json \
  "${active_only_home}/Library/Application Support/Linnet/State/active.json"
if HOME="${active_only_home}" "${scripts_root}/preinstall" >/dev/null 2>&1; then
  echo "Complete preinstall accepted Active/state residue without an App." >&2
  exit 1
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
quit_log="${test_root}/core-update-quit.log"
if [[ "${candidate_fixture_available}" == true ]]; then
  copy_candidate_app "${user_home}"
fi
LINNET_FAKE_QUIESCER_LOG="${quit_log}" HOME="${user_home}" "${scripts_root}/preinstall"
expected_quiescence="-l JavaScript ${scripts_root}/quit-applications-clean.jxa 30 io.github.ares-x.inputmethod.Linnet io.github.ares-x.inputmethod.Linnet.settings io.github.ares-x.inputmethod.Linnet"
[[ "$(cat "${quit_log}")" == "${expected_quiescence}" ]] || {
  echo "Core preinstall did not quiesce Settings before Host ahead of payload." >&2
  exit 1
}
[[ ! -e "${support_root}/Transactions" && ! -L "${support_root}/Transactions" ]] || {
  echo "Core preinstall created the runtime-owned Transactions directory." >&2
  exit 1
}
selection_state="${support_root}/State/core-update-selection-v1.plist"
[[ -f "${selection_state}" && ! -L "${selection_state}" ]] || {
  echo "Core preinstall did not persist the one-shot input-source selection token." >&2
  exit 1
}
[[ "$(/usr/bin/plutil -extract was_current raw -o - "${selection_state}")" == true ]] || {
  echo "Core preinstall lost the pre-update selected state." >&2
  exit 1
}

: >"${quit_log}"
if LINNET_FAKE_QUIESCER_LOG="${quit_log}" LINNET_FAKE_QUIESCER_RESULT=refuse \
    HOME="${user_home}" "${scripts_root}/preinstall" >/dev/null 2>&1; then
  echo "Core preinstall crossed payload after an application refused clean quit." >&2
  exit 1
fi
[[ "$(cat "${quit_log}")" == "${expected_quiescence}" ]] || {
  echo "Core preinstall did not propagate the clean-quit refusal." >&2
  exit 1
}
: >"${quit_log}"

if [[ "${candidate_fixture_available}" == true ]]; then
  if [[ "${candidate_identity_format}" == 1 ]]; then
    write_candidate_identity "${candidate_version}" "${candidate_build}" \
      "${candidate_revision}" "${wrong_leaf}"
  else
    write_candidate_identity "${candidate_version}" "${candidate_build}" \
      "${candidate_revision}" "" 2 invalid-community-trust
  fi
  if LINNET_FAKE_QUIESCER_LOG="${quit_log}" HOME="${user_home}" \
      "${scripts_root}/preinstall" >/dev/null 2>&1; then
    echo "Core preinstall accepted a conflicting candidate trust identity." >&2
    exit 1
  fi
  [[ ! -e "${quit_log}" || ! -s "${quit_log}" ]] || {
    echo "Core preinstall requested process quiescence before rejecting candidate identity." >&2
    exit 1
  }
  write_candidate_identity "${candidate_version}" "${candidate_build}" \
    "${candidate_revision}" "${candidate_leaf}"
fi

/usr/bin/plutil -replace packs.0.min_core -string 0.1.1 \
  "${support_root}/Runtime/Active/activation.json"
if LINNET_FAKE_QUIESCER_LOG="${quit_log}" HOME="${user_home}" \
    "${scripts_root}/preinstall" >/dev/null 2>&1; then
  echo "Core update accepted language data requiring a newer Core." >&2
  exit 1
fi
/usr/bin/plutil -replace packs.0.min_core -string 0.1.0-rc.1 \
  "${support_root}/Runtime/Active/activation.json"
: >"${quit_log}"
LINNET_FAKE_QUIESCER_LOG="${quit_log}" HOME="${user_home}" "${scripts_root}/preinstall"
[[ "$(cat "${quit_log}")" == "${expected_quiescence}" ]] || {
  echo "Core prerelease compatibility path bypassed process quiescence." >&2
  exit 1
}
/usr/bin/plutil -replace packs.0.min_core -string 0.1.0 \
  "${support_root}/Runtime/Active/activation.json"

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

# The package helper owns only pre-payload cooperative Host/Settings quiescence.
# Main owns the later boundaries: uninstall may force after its grace period,
# while Core postinstall targets only a relaunched Host and never reaches force.
rg -Fq 'settingsBundleIdentifier' sources/Main.swift
test "$(rg -F -c 'runningApplications(withBundleIdentifier:' sources/Main.swift)" -eq 1
rg -Fq 'forceTerminate()' sources/Main.swift
rg -Fq 'case "--quit-host-clean":' sources/Main.swift
rg -Fq 'quitProductProcesses(.uninstall)' sources/Main.swift
rg -Fq 'quitProductProcesses(.hostClean)' sources/Main.swift
if ! ruby -e '
  source = File.read(ARGV.fetch(0))
  policy = source[/enum TerminationPolicy.*?\n  \}/m] or abort "termination policy missing"
  abort "host-clean policy can target Settings" unless
    policy.include?("case .hostClean:") && policy.include?("return [bundleIdentifier]")
  abort "host-clean policy can force terminate" unless
    policy.include?("case .uninstall:") && policy.include?("case .hostClean: return false")
' sources/Main.swift; then
  echo "Host-clean and uninstall no longer share one bounded termination owner." >&2
  exit 1
fi
rg -Fq -- '--purge-owned-temporary-state' sources/Main.swift package/uninstall-linnet
rg -Fq 'logDir' sources/Main.swift
if rg -n 'killall|pkill' package/uninstall-linnet sources/Main.swift; then
  echo "Product uninstall gained a broad process-kill path." >&2
  exit 1
fi
if rg -Fq '"${host_cli}" --disable-input-source' package/uninstall-linnet; then
  echo "Default uninstall mutates Text Input state before preserving user data." >&2
  exit 1
fi

# TIS identity resolution is exact-one and typed. A duplicate or absent source
# must not let postinstall enable an arbitrary first match and report success.
rg -Fq 'case inputSourceCountMismatch(String, Int)' sources/InputSource.swift
rg -Fq 'guard matches.count == 1' sources/InputSource.swift
if rg -Fq 'case inputSourceUnavailable' sources/InputSource.swift; then
  echo "TIS resolution retained a separate zero-match interpretation." >&2
  exit 1
fi

# Every shipped macOS candidate has one new build identity, and the expanded
# package verifier mirrors (rather than contradicts) each product conclusion.
grep -Fqx 'CURRENT_PROJECT_VERSION = 14' config/LinnetProduct.xcconfig
rg -Fq 'if edition == "complete" && kind == "core"' package/verify_package

# The user-owned support root is a deletion trust boundary. A replaced root
# symlink must fail closed without touching any content behind that link.
uninstall_fixture="${scripts_root}/uninstall-linnet"
pkgutil_fixture="${scripts_root}/pkgutil"
cp package/uninstall-linnet "${uninstall_fixture}"
cat >"${pkgutil_fixture}" <<'SH'
#!/usr/bin/env bash
if [[ -n "${LINNET_FAKE_PKGUTIL_LOG:-}" ]]; then
  printf '%s\n' "$*" >>"${LINNET_FAKE_PKGUTIL_LOG}"
  exit 0
fi
exit 1
SH
chmod +x "${uninstall_fixture}" "${pkgutil_fixture}"
sed -i '' "s#/usr/sbin/pkgutil#${pkgutil_fixture}#g" "${uninstall_fixture}"
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

# A damaged installation must never turn the absence of its lifecycle owner
# into permission to delete the remaining App or generated data. The user can
# repair/reinstall the Host first; only a genuinely empty target is idempotent.
damaged_home="${test_root}/damaged-home"
damaged_support="${damaged_home}/Library/Application Support/Linnet"
mkdir -p "${damaged_home}/Library/Input Methods/Linnet.app" \
  "${damaged_support}/Data"
printf 'damaged install sentinel\n' >"${damaged_support}/Data/sentinel"
if HOME="${damaged_home}" "${uninstall_fixture}" >/dev/null 2>&1; then
  echo "Uninstall accepted deletion targets without a trusted Host CLI." >&2
  exit 1
fi
[[ -f "${damaged_support}/Data/sentinel" ]] || {
  echo "Uninstall deleted damaged-install data without terminating the product." >&2
  exit 1
}

# The canonical uninstaller must also tolerate a historical or independently
# hardened pack tree with 0555 directories and 0444 files. It must retire those
# Linnet-owned generated bytes without following a malicious nested symbolic
# link, while retaining all personal-data owners byte-for-byte.
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
HOME="${immutable_home}" "${uninstall_fixture}" >/dev/null
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
mkdir -p "${purge_app}/Contents/MacOS" "${purge_support}/UserData" \
  "${purge_preferences}"
cat >"${purge_app}/Contents/MacOS/Linnet" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod 0755 "${purge_app}/Contents/MacOS/Linnet"
printf 'persistent data\n' >"${purge_support}/UserData/sentinel"
for domain in io.github.ares-x.inputmethod.Linnet \
    io.github.ares-x.inputmethod.Linnet.settings; do
  printf 'preference data\n' >"${purge_preferences}/${domain}.plist"
done
HOME="${purge_home}" LINNET_FAKE_DEFAULTS_LOG="${purge_defaults_log}" \
  "${purge_uninstall_fixture}" --purge-user-data >/dev/null
[[ ! -e "${purge_app}" && ! -e "${purge_support}" ]] || {
  echo "Explicit purge left App or Application Support data behind." >&2
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
    package/report_size package/uninstall-linnet; then
  echo "A private LaunchServices cleanup path returned." >&2
  exit 1
fi

# A failed exact quit must stop the shell before the first App/data deletion.
ruby -e '
  source = File.read(ARGV.fetch(0))
  quit = source.index(%q{"${host_cli}" --quit}) or abort "quit missing"
  purge = source.index(%q{--purge-owned-temporary-state}) or abort "temporary purge missing"
  first_delete = source.index(%q{/bin/rm -rf --}) or abort "delete missing"
  abort "quit is not fail-closed before deletion" unless quit < purge && purge < first_delete
  line = source.lines.find { |candidate| candidate.include?(%q{"${host_cli}" --quit}) }
  abort "quit failure is ignored" if line.include?("|| true")
' package/uninstall-linnet

echo "Linnet package lifecycle fixtures: PASS"
