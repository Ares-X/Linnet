#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixture="$(mktemp -d /tmp/linnet-locked-release-asset.XXXXXX)"
fixture="$(cd "${fixture}" && pwd -P)"
cleanup() {
  case "${fixture}" in
    /private/tmp/linnet-locked-release-asset.*|/tmp/linnet-locked-release-asset.*)
      chmod -R u+w "${fixture}" >/dev/null 2>&1 || true
      find "${fixture}" -depth -delete >/dev/null 2>&1 || true
      ;;
  esac
}
trap cleanup EXIT INT TERM HUP

payload='locked-asset'
payload_sha="$(printf '%s' "${payload}" | shasum -a 256 | awk '{print $1}')"
lock="${fixture}/lock.json"
printf '%s\n' \
  '{"sources":{"model":{"repository":"https://github.com/example/model.git",' \
  '"release":"LTS","asset":"model.gram",' \
  '"asset_id":123,"asset_api_url":"https://api.github.com/repos/example/model/releases/assets/123",' \
  '"bytes":12,"sha256":"'"${payload_sha}"'","pack":{' \
  '"repository":"https://github.com/example/model.git","release":"LTS",' \
  '"asset":"model.gram","asset_id":123,' \
  '"asset_api_url":"https://api.github.com/repos/example/model/releases/assets/123",' \
  '"bytes":12,"sha256":"'"${payload_sha}"'"}}}}' >"${lock}"

fake_bin="${fixture}/bin"
mkdir "${fake_bin}"
fake_curl="${fake_bin}/curl"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'dump=""; output=""; write_status=0; url=""' \
  'while [[ "$#" -gt 0 ]]; do' \
  '  case "$1" in' \
  '    --config) [[ "$2" == - ]]; shift 2 ;;' \
  '    --dump-header) dump="$2"; shift 2 ;;' \
  '    --output) output="$2"; shift 2 ;;' \
  '    --write-out) write_status=1; shift 2 ;;' \
  '    -H|--connect-timeout|--max-time|--proto) shift 2 ;;' \
  '    --silent|--show-error|--fail) shift ;;' \
  '    https://*) url="$1"; shift ;;' \
  '    *) shift ;;' \
  '  esac' \
  'done' \
  'if [[ "${url}" == https://api.github.com/repos/example/model/releases/assets/123 ]]; then' \
  '  if [[ "${FAKE_ASSET_RESPONSE:-redirect}" == direct ]]; then' \
  '    printf "HTTP/1.1 200 OK\r\n\r\n" >"${dump}"' \
  '    printf locked-asset >"${output}"' \
  '    [[ "${write_status}" -eq 0 ]] || printf 200' \
  '  else' \
  '    printf "HTTP/1.1 302 Found\r\nlocation: https://release-assets.githubusercontent.com/fixture/model.gram\r\n\r\n" >"${dump}"' \
  '    [[ "${write_status}" -eq 0 ]] || printf 302' \
  '  fi' \
  'else' \
  '  printf locked-asset >"${output}"' \
  'fi' >"${fake_curl}"
chmod 755 "${fake_curl}"

output="${fixture}/model.gram"
PATH="${fake_bin}:${PATH}" "${repo_root}/scripts/fetch-locked-release-asset" \
  "${lock}" model "${output}" >/dev/null
[[ "$(cat "${output}")" == "${payload}" ]]

direct_output="${fixture}/model-direct.gram"
FAKE_ASSET_RESPONSE=direct PATH="${fake_bin}:${PATH}" \
  "${repo_root}/scripts/fetch-locked-release-asset" \
  "${lock}" model "${direct_output}" >/dev/null
[[ "$(cat "${direct_output}")" == "${payload}" ]]
nested_output="${fixture}/model-nested.gram"
PATH="${fake_bin}:${PATH}" "${repo_root}/scripts/fetch-locked-release-asset" \
  "${lock}" model.pack "${nested_output}" >/dev/null
[[ "$(cat "${nested_output}")" == "${payload}" ]]
if PATH="${fake_bin}:${PATH}" "${repo_root}/scripts/fetch-locked-release-asset" \
    "${lock}" model..pack "${fixture}/unsafe-path.gram" >/dev/null 2>&1; then
  echo "verify_locked_release_asset: unsafe nested source path was accepted" >&2
  exit 1
fi
[[ ! -e "${fixture}/unsafe-path.gram" ]]
if rg -n 'GITHUB_TOKEN|Authorization:' \
    "${repo_root}/scripts/fetch-locked-release-asset"; then
  echo "verify_locked_release_asset: bulk release bytes regained an API credential path" >&2
  exit 1
fi
rg -Fq 'asset_api_url="$(lock_value asset_api_url)"' \
  "${repo_root}/scripts/fetch-locked-release-asset" || {
  echo "verify_locked_release_asset: fetch owner does not use the immutable asset id" >&2
  exit 1
}
if rg -n 'asset_download_url' \
    "${repo_root}/upstreams.lock.json" "${repo_root}/scripts/upstream-sync" \
    "${repo_root}/scripts/fetch-locked-release-asset" "${repo_root}/action-install.sh"; then
  echo "verify_locked_release_asset: mutable release-name download path returned" >&2
  exit 1
fi
rg -Fq 'lmdg_pack_api_url="$(lock_value sources.rime_lmdg_grammar.linnet_pack.asset_api_url)"' \
  "${repo_root}/action-install.sh" || {
  echo "verify_locked_release_asset: build owner does not project the immutable Linnet pack id" >&2
  exit 1
}
rg -Fq '"${lock_file}" rime_lmdg_grammar.linnet_pack "${pack_file}"' \
  "${repo_root}/action-install.sh" || {
  echo "verify_locked_release_asset: build owner bypasses the immutable Linnet pack" >&2
  exit 1
}

bad_lock="${fixture}/bad-lock.json"
sed 's#api.github.com/repos/example/model/releases/assets#mirror.example/example/model#' \
  "${lock}" >"${bad_lock}"
if PATH="${fake_bin}:${PATH}" "${repo_root}/scripts/fetch-locked-release-asset" \
    "${bad_lock}" model "${fixture}/bad.gram" >/dev/null 2>&1; then
  echo "verify_locked_release_asset: malformed asset API URL was accepted" >&2
  exit 1
fi
[[ ! -e "${fixture}/bad.gram" ]]

installer="${repo_root}/action-install.sh"
if rg -Fq 'git submodule --quiet' "${installer}"; then
  echo "verify_locked_release_asset: dependency hydration became silent again" >&2
  exit 1
fi
rg -Fq 'git submodule update --init --depth 1 --jobs 6 --progress' "${installer}" || {
  echo "verify_locked_release_asset: release hydration regained unnecessary history" >&2
  exit 1
}
[[ "$(rg -c '^build_stage [1-6] ' "${installer}")" == 6 ]] || {
  echo "verify_locked_release_asset: the six long build stages are not observable" >&2
  exit 1
}

echo "verify_locked_release_asset: PASS"
