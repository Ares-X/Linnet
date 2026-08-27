#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

# Structural and mutation-boundary coverage for local, byte-bound publication.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
control="${repo_root}/scripts/release-control"
publisher="${repo_root}/package/publish_github_release"
identity="${repo_root}/package/release_candidate_identity"
retired_workflow="${repo_root}/.github/workflows/release-ci.yml"

fail() {
  echo "verify_release_automation: $*" >&2
  exit 1
}

[[ ! -e "${retired_workflow}" ]] ||
  fail "the retired GitHub release build workflow returned"
for owner in "${control}" "${publisher}" "${identity}"; do
  [[ -f "${owner}" && ! -L "${owner}" && -x "${owner}" ]] ||
    fail "local publication owner is missing: ${owner##*/}"
  bash -n "${owner}"
done

if rg -n 'release-control (request|fetch|approve)|actions/artifacts|release-ci\.yml|workflow_dispatch' \
    "${control}" "${publisher}"; then
  fail "the retired Actions artifact publication path returned"
fi
for required in \
    'publish ABSOLUTE_RELEASE_DIRECTORY' \
    'remote get-url origin' \
    'ls-remote --exit-code origin refs/heads/main' \
    'package/verify_publication_artifacts' \
    'package/release_candidate_identity' \
    'linnet-publication/v${version}-${revision}-h${BASH_REMATCH[1]}' \
    'for channel in core data catalog public'; do
  rg -Fq "${required}" "${control}" ||
    fail "local publication boundary is incomplete: ${required}"
done
rg -Fq 'publication authorization differs from candidate bytes' "${publisher}" ||
  fail "publisher does not bind authorization to the exact local bytes"
if rg -n -- '--force|push -f|--clobber' "${control}"; then
  fail "local publication regained destructive replacement"
fi

fixture="$(mktemp -d "${TMPDIR:-/tmp}/linnet-release-automation.XXXXXX")"
cleanup() {
  [[ "${fixture}" == "${TMPDIR:-/tmp}/linnet-release-automation."* ]] &&
    find "${fixture}" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP
fixture_repo="${fixture}/repo"
release_dir="${fixture}/release"
fake_bin="${fixture}/bin"
fake_log="${fixture}/calls.log"
mkdir -p "${fixture_repo}/scripts" "${fixture_repo}/package" \
  "${fixture_repo}/config" "${fixture_repo}/sources" "${fixture_repo}/tools" \
  "${release_dir}" "${fake_bin}" "${fixture}/tmp"
cp "${control}" "${fixture_repo}/scripts/release-control"
printf 'MARKETING_VERSION = 0.1.8\n' \
  >"${fixture_repo}/config/LinnetProduct.xcconfig"

cat >"${fixture_repo}/package/data_release_metadata" <<'FAKE_DATA'
#!/usr/bin/env bash
[[ "$1" == get-catalog-sequence ]]
echo 29
FAKE_DATA
cat >"${fixture_repo}/package/verify_publication_artifacts" <<'FAKE_VERIFY'
#!/usr/bin/env bash
set -euo pipefail
[[ "$2" == 0.1.8 && "$3" == "${FAKE_REVISION:?}" ]]
[[ -x "${LINNET_RELEASE_TOOL:?}" ]]
echo "verify $*" >>"${FAKE_LOG:?}"
FAKE_VERIFY
cat >"${fixture_repo}/package/release_candidate_identity" <<'FAKE_IDENTITY'
#!/usr/bin/env bash
set -euo pipefail
[[ "$2" == 0.1.8 && "$3" == 29 ]]
printf 'sha256:%064d\n' 0
FAKE_IDENTITY
cat >"${fixture_repo}/package/publish_github_release" <<'FAKE_PUBLISH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$3" == 0.1.8 && "$4" == 29 && "$5" == "${FAKE_REVISION:?}" ]]
[[ "$6" == "linnet-publication/v0.1.8-${FAKE_REVISION}-h$(printf '%064d' 0)" ]]
echo "publish $1" >>"${FAKE_LOG:?}"
FAKE_PUBLISH

cat >"${fake_bin}/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -C ]] && shift 2
case "${1:-} ${2:-}" in
  "remote get-url") echo git@github.com:Ares-X/Linnet.git ;;
  "status --porcelain=v1") [[ -z "${FAKE_DIRTY:-}" ]] || echo ' M owned-file' ;;
  "rev-parse --verify") echo "${FAKE_REVISION:?}" ;;
  "ls-remote --exit-code")
    printf '%s\trefs/heads/main\n' "${FAKE_MAIN_REVISION:-${FAKE_REVISION:?}}" ;;
  "ls-remote origin")
    [[ -z "${FAKE_AUTH_PRESENT:-}" ]] ||
      printf '%s\t%s\n' "${FAKE_REVISION:?}" "$3" ;;
  "push origin") echo "push $3" >>"${FAKE_LOG:?}" ;;
  *) exit 91 ;;
esac
FAKE_GIT
cat >"${fake_bin}/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'auth status --hostname github.com' ]]
echo 'gh auth' >>"${FAKE_LOG:?}"
FAKE_GH
cat >"${fake_bin}/xcrun" <<'FAKE_XCRUN'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == -o ]]; then output="$2"; break; fi
  shift
done
[[ -n "${output}" ]]
install -m 0755 /dev/null "${output}"
FAKE_XCRUN
chmod 755 "${fixture_repo}/scripts/release-control" \
  "${fixture_repo}/package/data_release_metadata" \
  "${fixture_repo}/package/verify_publication_artifacts" \
  "${fixture_repo}/package/release_candidate_identity" \
  "${fixture_repo}/package/publish_github_release" \
  "${fake_bin}/git" "${fake_bin}/gh" "${fake_bin}/xcrun"

export FAKE_REVISION=0123456789abcdef0123456789abcdef01234567
export FAKE_LOG="${fake_log}"
fake_path="${fake_bin}:${PATH}"

: >"${fake_log}"
TMPDIR="${fixture}/tmp" PATH="${fake_path}" \
  "${fixture_repo}/scripts/release-control" publish "${release_dir}" >/dev/null
expected_tag="linnet-publication/v0.1.8-${FAKE_REVISION}-h$(printf '%064d' 0)"
[[ "$(grep -c "^push ${FAKE_REVISION}:refs/tags/${expected_tag}$" "${fake_log}")" -eq 1 ]] ||
  fail "local publication did not create one exact byte-bound authorization"
[[ "$(grep '^publish ' "${fake_log}")" == $'publish core\npublish data\npublish catalog\npublish public' ]] ||
  fail "local publication channel order is not canonical"

for rejection in dirty wrong-main; do
  : >"${fake_log}"
  if [[ "${rejection}" == dirty ]]; then
    if FAKE_DIRTY=1 TMPDIR="${fixture}/tmp" PATH="${fake_path}" \
        "${fixture_repo}/scripts/release-control" publish "${release_dir}" \
        >/dev/null 2>&1; then
      fail "dirty checkout was accepted"
    fi
  else
    if FAKE_MAIN_REVISION=ffffffffffffffffffffffffffffffffffffffff \
        TMPDIR="${fixture}/tmp" PATH="${fake_path}" \
        "${fixture_repo}/scripts/release-control" publish "${release_dir}" \
        >/dev/null 2>&1; then
      fail "non-main revision was accepted"
    fi
  fi
  [[ ! -s "${fake_log}" ]] || fail "rejected publication reached a mutation boundary"
done

echo "Linnet local release automation: PASS (exact main + eight-byte-set authorization)"
