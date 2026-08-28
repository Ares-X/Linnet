#!/usr/bin/env bash

# Fast post-build development gate. It needs staged data and a compiled App but
# no certificate, Keychain, package or installed-product mutation.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

profile="${1:-all}"
case "${profile}" in
  all|app|swift|rime) ;;
  *)
    echo "Usage: tests/verify_development.sh [all|app|swift|rime]" >&2
    exit 2
    ;;
esac

run_app=0
run_swift=0
run_rime=0
case "${profile}" in
  all) run_app=1; run_swift=1; run_rime=1 ;;
  app) run_app=1 ;;
  swift) run_swift=1 ;;
  rime) run_rime=1 ;;
esac

if [[ "${run_app}" -eq 1 ]]; then
  host_app="${repo_root}/build/Build/Products/Release/Linnet.app"
  standalone_settings="${repo_root}/build/Build/Products/Release/Settings.app"
  embedded_settings="${host_app}/Contents/Applications/Settings.app"
  for app in "${host_app}" "${standalone_settings}" "${embedded_settings}"; do
    [[ -d "${app}" && ! -L "${app}" ]] || {
      echo "verify_development: missing unsigned Release App: ${app}" >&2
      exit 1
    }
    [[ ! -e "${app}/Contents/_CodeSignature" &&
       ! -L "${app}/Contents/_CodeSignature" ]] || {
      echo "verify_development: unsigned Release retained a stale signature: ${app}" >&2
      exit 1
    }
  done

# A local unsigned composite has no clean candidate revision to bind. The
# successful composite build owns one completion marker after Xcode, resource
# sanitization and local registration cleanup all finish.
  host_executable="${host_app}/Contents/MacOS/Linnet"
  settings_executables=(
    "${standalone_settings}/Contents/MacOS/Settings"
    "${embedded_settings}/Contents/MacOS/Settings"
  )
  for executable in "${host_executable}" "${settings_executables[@]}"; do
    [[ -f "${executable}" && ! -L "${executable}" && -x "${executable}" ]] || {
      echo "verify_development: missing Release executable: ${executable}" >&2
      exit 1
    }
  done

  build_stamp="${repo_root}/build/Build/Products/Release/.linnet-build-complete"
  [[ -f "${build_stamp}" && ! -L "${build_stamp}" ]] || {
    echo "verify_development: missing successful Release build marker" >&2
    exit 1
  }

verify_inputs_predate() {
  local executable="$1"
  local input
  while IFS= read -r input; do
    [[ -f "${input}" && ! -L "${input}" ]] || continue
    [[ ! "${input}" -nt "${executable}" ]] || {
      echo "verify_development: Release is older than build input: ${input}" >&2
      exit 1
    }
  done
}

  verify_inputs_predate "${build_stamp}" < <(
    {
      git ls-files --cached --others --exclude-standard -- \
        Makefile Linnet.xcodeproj/project.pbxproj config/LinnetProduct.xcconfig \
        sources resources data/linnet data/squirrel.yaml
      find data/plum data/opencc lib -type f -print
    } | LC_ALL=C sort -u
  )

  bash -n action-build.sh action-install.sh package/installer-scripts/postinstall
  tests/verify_runtime_footprint.sh
  LINNET_LIFECYCLE_CANDIDATE_APP="${host_app}" tests/verify_package_lifecycle.sh
  tests/verify_visible_settings_fixture.sh --verify
  tests/verify_release_metadata.sh
  tests/verify_package_architecture.sh
  make --no-print-directory english-data-generator
  tests/verify_english_data_projection.sh
  ruby tests/generate_m2_fixtures.rb --check
  APP_PATH="${host_app}" LANGUAGE_DATA_ROOT="${repo_root}/data/plum" \
    tests/verify_input_process_offline.sh
  scripts/build-privacy scan "${host_app}"
fi

if [[ "${run_swift}" -eq 1 ]]; then
  tests/verify_swift_units.sh
fi

if [[ "${run_rime}" -eq 1 ]]; then
  tests/verify_lua_lifetime.sh
  tests/verify_data_release_baseline.sh
  tests/verify_chinese_upstream_workflow.sh
  ruby scripts/upstream-sync verify
  tests/verify_chinese_source_projection.sh
  tests/verify_locked_release_asset.sh
  tests/verify_chinese_grammar.sh
  ruby tests/verify_profile_golden.rb
  tests/verify_chinese_learning_policy.sh
  tests/verify_rime_runtime.sh
fi

echo "Linnet development gate (${profile}): PASS (no signing or installation)"
