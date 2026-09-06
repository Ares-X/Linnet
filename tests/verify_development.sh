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
  host_app="${repo_root}/build/Local/Build/Products/Release/Linnet.app"
  standalone_settings="${repo_root}/build/Local/Build/Products/Release/Settings.app"
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

  [[ "$(plutil -extract CFBundleIdentifier raw -o - \
    "${host_app}/Contents/Info.plist")" == \
    io.github.ares-x.inputmethod.Linnet.local-build ]] || {
    echo "verify_development: local Host regained the production identity" >&2
    exit 1
  }
  for settings_app in "${standalone_settings}" "${embedded_settings}"; do
    [[ "$(plutil -extract CFBundleIdentifier raw -o - \
      "${settings_app}/Contents/Info.plist")" == \
      io.github.ares-x.inputmethod.Linnet.local-build.settings ]] || {
      echo "verify_development: local Settings regained the production identity" >&2
      exit 1
    }
  done

# A local unsigned composite has no clean candidate revision to bind. The
# successful composite build owns one completion marker after Xcode, resource
# sanitization and local-identity verification all finish.
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

  build_stamp="${repo_root}/build/Local/Build/Products/Release/.linnet-build-complete"
  [[ -f "${build_stamp}" && ! -L "${build_stamp}" ]] || {
    echo "verify_development: missing successful Release build marker" >&2
    exit 1
  }

  bash -n action-build.sh action-install.sh package/installer-scripts/postinstall \
    package/installer-scripts/complete-postinstall
  tests/verify_runtime_footprint.sh
  tests/verify_visible_settings_fixture.sh --verify local
  tests/verify_release_metadata.sh
  make --no-print-directory english-data-generator
  tests/verify_english_data_projection.sh
  ruby tests/generate_m2_fixtures.rb --check
  APP_PATH="${host_app}" LANGUAGE_DATA_ROOT="${repo_root}/data/plum" \
    tests/verify_input_process_offline.sh
  scripts/build-privacy scan "${host_app}"
fi

run_swift_tests() {
  tests/verify_swift_units.sh
}

run_rime_tests() {
  tests/verify_lua_lifetime.sh
  tests/verify_data_release_baseline.sh
  ruby scripts/upstream-sync verify
  tests/verify_chinese_source_projection.sh
  tests/verify_locked_release_asset.sh
  tests/verify_chinese_grammar.sh
  ruby tests/verify_profile_golden.rb
  tests/verify_chinese_learning_policy.sh
  tests/verify_rime_runtime.sh
}

if [[ "${profile}" == all ]]; then
  # Both suites only read the staged product/runtime and own distinct temporary
  # roots. Keep each suite internally serial while using the two independent
  # process boundaries that actually reduce wall time.
  parallel_pids=()
  stop_parallel() {
    local pid
    for pid in "${parallel_pids[@]}"; do
      kill -TERM "${pid}" 2>/dev/null || true
    done
    for pid in "${parallel_pids[@]}"; do
      wait "${pid}" 2>/dev/null || true
    done
  }
  trap 'stop_parallel; exit 130' INT
  trap 'stop_parallel; exit 143' TERM HUP

  run_swift_tests &
  swift_pid=$!
  parallel_pids+=("${swift_pid}")
  run_rime_tests &
  rime_pid=$!
  parallel_pids+=("${rime_pid}")

  set +e
  wait "${swift_pid}"
  swift_status=$?
  if [[ "${swift_status}" -ne 0 ]]; then
    kill -TERM "${rime_pid}" 2>/dev/null || true
  fi
  wait "${rime_pid}"
  rime_status=$?
  set -e
  parallel_pids=()
  trap - INT TERM HUP
  [[ "${swift_status}" -eq 0 && "${rime_status}" -eq 0 ]] || exit 1
else
  if [[ "${run_swift}" -eq 1 ]]; then
    run_swift_tests
  fi
  if [[ "${run_rime}" -eq 1 ]]; then
    run_rime_tests
  fi
fi

echo "Linnet development gate (${profile}): PASS (no signing or installation)"
