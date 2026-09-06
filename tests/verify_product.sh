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

run_phase() {
  local label="$1"
  local started="${SECONDS}"
  shift
  printf '==> Candidate verification: %s\n' "${label}"
  "$@"
  printf '<== Candidate verification: PASS in %ss: %s\n' \
    "$((SECONDS - started))" "${label}"
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

app="${repo_root}/build/Candidate.noindex/Release/Linnet.candidate"
settings="${repo_root}/build/Candidate.noindex/Release/Settings.candidate"
[[ -d "${app}" && ! -L "${app}" && -d "${settings}" && ! -L "${settings}" ]] || {
  echo "verify_product: frozen Release App and Settings App are required" >&2
  exit 1
}

frozen_revision="$(git rev-parse --verify HEAD^{commit})"
assert_clean_checkout
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
  local report
  local report_name
  : >"${output}"
  if [[ -d "${reports}" ]]; then
    while IFS= read -r -d '' report; do
      report_name="${report##*/}"
      case "${report_name}" in
      *Linnet* | *Squirrel* | *rime*)
        printf '%s\n' "${report}" >>"${output}"
        ;;
      Settings-*.ips)
        grep -Fq '"bundleID":"io.github.ares-x.inputmethod.Linnet.settings"' \
          "${report}" && printf '%s\n' "${report}" >>"${output}"
        ;;
      esac
    done < <(find "${reports}" -maxdepth 1 -type f -print0)
  fi
  LC_ALL=C sort -o "${output}" "${output}"
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
for no_modes_info in resources/Info.plist "${info}"; do
  ! plutil -extract TISInputSourceID raw -o - "${no_modes_info}" >/dev/null 2>&1 || {
    echo "verify_product: no-modes input method has an explicit competing source ID: ${no_modes_info}" >&2
    exit 1
  }
done
[[ "$(plutil -extract TISIntendedLanguage raw -o - "${info}")" == zh-Hans ]]
for repertoire_info in resources/Info.plist "${info}"; do
  [[ "$(plutil -extract tsInputMethodCharacterRepertoireKey json -o - \
    "${repertoire_info}")" == '["zh-Hans"]' ]] || {
    echo "verify_product: no-modes repertoire must be exact zh-Hans: ${repertoire_info}" >&2
    exit 1
  }
done
[[ "$(plutil -extract tsInputMethodIconFileKey raw -o - "${info}")" == linnet.pdf ]]
[[ "$(plutil -extract InputMethodConnectionName raw -o - resources/Info.plist)" == \
  '$(PRODUCT_NAME)_Connection' ]] || {
  echo "verify_product: source IMK connection must follow the stable product-name contract" >&2
  exit 1
}
connection_name="$(plutil -extract InputMethodConnectionName raw -o - "${info}")"
[[ "${connection_name}" == Linnet_Connection ]] || {
  echo "verify_product: built IMK connection must follow the stable product-name contract" >&2
  exit 1
}
for retired in ComponentInputModeDict PrimaryInputModeIdentifier; do
  ! plutil -extract "${retired}" raw -o - "${info}" >/dev/null 2>&1
done

run_phase "packaged Rime modules" tests/verify_packaged_rime.sh \
  "${app}" "${app}/Contents/Applications/Settings.app" "${settings}"
run_phase "fixed-home signed Settings bundle" \
  tests/verify_visible_settings_fixture.sh --verify candidate
run_phase "offline candidate process" env \
  APP_PATH="${app}" LANGUAGE_DATA_ROOT="${repo_root}/data/plum" \
  tests/verify_input_process_offline.sh
run_phase "candidate privacy boundary" scripts/build-privacy scan "${app}"

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
echo "verify_product: PASS (exact-main C/E reused; candidate-byte P evidence; V/I/R NOT_EXERCISED; zero new crashes)"
