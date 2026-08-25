#!/usr/bin/env bash

# Frozen-candidate acceptance. Development builds do not call this gate. Each
# behavior owner is exercised once; package expansion and installed workflows
# remain separate acceptance classes.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

fail() {
  echo "verify_product: $1" >&2
  exit 1
}

assert_clean_checkout() {
  local status
  status="$(git status --porcelain=v1 --untracked-files=all)"
  [[ -z "${status}" ]] || fail "frozen product acceptance requires a clean checkout"
}

[[ "${1:-release}" == release && "$#" -le 1 ]] || {
  echo "Usage: tests/verify_product.sh [release]" >&2
  exit 2
}

app="${repo_root}/build/Build/Products/Release/Linnet.app"
settings="${repo_root}/build/Build/Products/Release/Settings.app"
[[ -d "${app}" && ! -L "${app}" && -d "${settings}" && ! -L "${settings}" ]] || {
  echo "verify_product: frozen Release App and Settings App are required" >&2
  exit 1
}

frozen_revision="$(git rev-parse --verify HEAD^{commit})"
assert_clean_checkout
tests/verify_candidate_native_idle.sh
signing_profile="$(plutil -extract LinnetCodeSigningProfile raw -o - \
  "${app}/Contents/Info.plist")"
[[ "${signing_profile}" == community-cms ]] ||
  fail "candidate signing profile is invalid"
candidate_identity="$(scripts/linnet-code-identity verify-product \
  "${app}" "${settings}")"
candidate_revision="$(ruby -rjson -e '
  identity = JSON.parse(ARGV.fetch(0))
  print identity.fetch("candidate_revision")
' "${candidate_identity}")"
[[ "${candidate_revision}" == "${frozen_revision}" ]] ||
  fail "finalized App revision does not match the frozen checkout"

scratch="$(mktemp -d /tmp/linnet-candidate-gate.XXXXXX)"
reports="${HOME}/Library/Logs/DiagnosticReports"
cleanup() {
  [[ "${scratch}" == /tmp/linnet-candidate-gate.* ]] && /bin/rm -rf -- "${scratch}"
}
trap cleanup EXIT INT TERM

snapshot_reports() {
  local output="$1"
  if [[ -d "${reports}" ]]; then
    find "${reports}" -maxdepth 1 -type f \
      \( -iname '*Linnet*' -o -iname '*Squirrel*' -o -iname '*rime*' \) \
      -print | LC_ALL=C sort >"${output}"
  else
    : >"${output}"
  fi
}
snapshot_reports "${scratch}/reports.before"

while IFS= read -r binary; do
  [[ "$(lipo -archs "${binary}")" == arm64 ]] || {
    echo "verify_product: non-arm64 candidate binary: ${binary}" >&2
    exit 1
  }
done < <(find "${app}" "${settings}" -type f -print | while IFS= read -r path; do
  file -b "${path}" | grep -q 'Mach-O' && printf '%s\n' "${path}"
done)

info="${app}/Contents/Info.plist"
bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "${info}")"
[[ "${bundle_identifier}" == io.github.ares-x.inputmethod.Linnet ]]
[[ "$(plutil -extract TISInputSourceID raw -o - "${info}")" == \
  "${bundle_identifier}" ]] || {
  echo "verify_product: the sole input source ID must equal the bundle identifier" >&2
  exit 1
}
[[ "$(plutil -extract TISIntendedLanguage raw -o - "${info}")" == zh-Hans ]]
for repertoire_info in resources/Info.plist "${info}"; do
  [[ "$(plutil -extract tsInputMethodCharacterRepertoireKey json -o - \
    "${repertoire_info}")" == '["Hans","Hant"]' ]] || {
    echo "verify_product: input-method repertoire must be exact Hans/Hant scripts: ${repertoire_info}" >&2
    exit 1
  }
done
[[ "$(plutil -extract tsInputMethodIconFileKey raw -o - "${info}")" == linnet.pdf ]]
connection_name="$(plutil -extract InputMethodConnectionName raw -o - "${info}")"
[[ "${connection_name}" == "${bundle_identifier}.Connection" ]] || {
  echo "verify_product: IMK connection must match the system bundle connection" >&2
  exit 1
}
for retired in ComponentInputModeDict PrimaryInputModeIdentifier; do
  ! plutil -extract "${retired}" raw -o - "${info}" >/dev/null 2>&1
done

tests/verify_runtime_footprint.sh
tests/verify_lua_lifetime.sh
tests/verify_release_metadata.sh
tests/verify_data_release_baseline.sh
tests/verify_chinese_upstream_workflow.sh
ruby scripts/upstream-sync verify
tests/verify_chinese_source_projection.sh
tests/verify_locked_release_asset.sh
tests/verify_english_data_projection.sh
ruby tests/generate_m2_fixtures.rb --check
tests/verify_visible_settings_fixture.sh --verify
tests/verify_swift_units.sh
tests/verify_package_architecture.sh
LINNET_LIFECYCLE_CANDIDATE_APP="${app}" tests/verify_package_lifecycle.sh
tests/verify_publication_owner.sh
tests/verify_chinese_grammar.sh
ruby tests/verify_profile_golden.rb
tests/verify_chinese_learning_policy.sh
tests/verify_rime_runtime.sh
APP_PATH="${app}" LANGUAGE_DATA_ROOT="${repo_root}/data/plum" \
  tests/verify_input_process_offline.sh
scripts/build-privacy scan "${app}"

snapshot_reports "${scratch}/reports.after"
comm -13 "${scratch}/reports.before" "${scratch}/reports.after" \
  >"${scratch}/reports.added"
[[ ! -s "${scratch}/reports.added" ]] || {
  echo "verify_product: candidate verification created DiagnosticReports:" >&2
  cat "${scratch}/reports.added" >&2
  exit 1
}

[[ "$(git rev-parse --verify HEAD^{commit})" == "${frozen_revision}" ]] ||
  fail "checkout revision changed during product acceptance"
assert_clean_checkout
final_candidate_identity="$(scripts/linnet-code-identity verify-product \
  "${app}" "${settings}")"
[[ "${final_candidate_identity}" == "${candidate_identity}" ]] ||
  fail "finalized App identity changed during product acceptance"
git diff --check
echo "verify_product: PASS (C/E + candidate-App P evidence; V/I/R NOT_EXERCISED; zero new crashes)"
