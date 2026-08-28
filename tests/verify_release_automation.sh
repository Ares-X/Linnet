#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

# Structural and mutation-boundary coverage for Action-built, byte-bound
# publication. Candidate construction remains on a macOS GitHub runner.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
control="${repo_root}/scripts/release-control"
stager="${repo_root}/package/stage_github_release"
publisher="${repo_root}/package/publish_github_release"
identity="${repo_root}/package/release_candidate_identity"
release_workflow="${repo_root}/.github/workflows/release-ci.yml"
commit_workflow="${repo_root}/.github/workflows/commit-ci.yml"
pull_request_workflow="${repo_root}/.github/workflows/pull-request-ci.yml"
visible_settings_fixture="${repo_root}/tests/verify_visible_settings_fixture.sh"
policy_docs=(
  "${repo_root}/docs/release.md"
  "${repo_root}/docs/development.md"
  "${repo_root}/docs/product-acceptance.md"
)

fail() {
  echo "verify_release_automation: $*" >&2
  exit 1
}

[[ -f "${release_workflow}" && ! -L "${release_workflow}" ]] ||
  fail "the GitHub release workflow is missing"
for owner in "${control}" "${stager}" "${publisher}" "${identity}"; do
  [[ -f "${owner}" && ! -L "${owner}" && -x "${owner}" ]] ||
    fail "release owner is missing: ${owner##*/}"
  bash -n "${owner}"
done

if rg -n 'uses:[[:space:]]*actions/(upload|download)-artifact@|actions/artifacts' \
    "${repo_root}/.github/workflows" "${stager}" "${publisher}"; then
  fail "the 906 MB Actions artifact upload/download path returned"
fi
if rg -n 'scripts/release-control publish|signs exactly once locally|本地归档.*正式候选|本机.*正式候选' \
    "${policy_docs[@]}"; then
  fail "maintainer documentation regained a local formal-candidate owner"
fi
for required in \
    'macOS GitHub Action' \
    'scripts/release-control authorize' \
    'GitHub Actions artifact 不是发布传输或存储 owner'; do
  rg -Fq -- "${required}" "${policy_docs[@]}" ||
    fail "maintainer documentation is missing the Action release boundary: ${required}"
done
for required in \
    'runs-on: macos-latest' \
    'environment: community-signing' \
    'LINNET_COMMUNITY_CMS_P12_BASE64' \
    'linnet-data-seed/v*-*-*' \
    'Bootstrap an exact future LTS data seed' \
    'scripts/fetch-locked-release-asset upstreams.lock.json' \
    './action-install.sh' \
    'make --no-print-directory archive' \
    'package/verify_publication_artifacts' \
    'for channel in core data public' \
    'package/stage_github_release stage' \
    'package/publish_github_release data-seed' \
    'Linnet manual full CI' \
    '-f event=workflow_dispatch' \
    'runs-on: ubuntu-latest' \
    'package/publish_github_release publish'; do
  rg -Fq -- "${required}" "${release_workflow}" ||
    fail "the Action-owned release chain is incomplete: ${required}"
done
if [[ "$(rg -c '^  build-candidate:$' "${release_workflow}")" -ne 1 ||
      "$(rg -c '^  publish:$' "${release_workflow}")" -ne 1 ]]; then
  fail "release workflow must keep one candidate builder and one publisher"
fi
if rg -n 'workflow_run:|workflow_call:' "${release_workflow}"; then
  fail "release may only start from the two explicit immutable tags"
fi

for required in \
    'usage: scripts/release-control authorize ABSOLUTE_RELEASE_DIRECTORY' \
    'remote get-url origin' \
    'ls-remote --exit-code origin refs/heads/main' \
    'package/verify_publication_artifacts' \
    'package/release_candidate_identity' \
    'linnet-publication/v${version}-${revision}-h${candidate_digest}' \
    'package/stage_github_release" verify'; do
  rg -Fq -- "${required}" "${control}" ||
    fail "local UAT authorization boundary is incomplete: ${required}"
done
if rg -n 'stage_github_release" stage|package/publish_github_release|release (create|upload|edit|delete)|refs/heads/data-channel' \
    "${control}"; then
  fail "the maintainer Mac can still build, upload, or publish release state"
fi
if rg -n -- '--force|push -f|--clobber' "${control}" "${stager}" "${publisher}"; then
  fail "release automation regained destructive replacement"
fi

rg -Fq 'mode}" == verify || "${GITHUB_ACTIONS:-}" == true' "${stager}" ||
  fail "draft mutation is not restricted to GitHub Actions"
if rg -n 'release edit|release delete|refs/heads/data-channel|--latest' "${stager}"; then
  fail "the candidate stager can still publish a channel"
fi
rg -Fq 'mode}" == verify || "${GITHUB_ACTIONS:-}" == true' "${publisher}" ||
  fail "public release mutation is not restricted to GitHub Actions"
rg -Fq -- '--pattern Linnet-Data-Channel.json' "${publisher}" ||
  fail "publisher does not limit its download to the tiny Catalog"
if [[ "$(rg -c '^[[:space:]]*gh release download ' "${publisher}")" -ne 1 ]]; then
  fail "publisher regained a large release download path"
fi
if rg -n 'release (create|upload|delete)|--clobber|force=true' "${publisher}"; then
  fail "publisher can recreate or replace staged candidate bytes"
fi

for workflow in "${commit_workflow}" "${pull_request_workflow}" "${release_workflow}"; do
  ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "${workflow}" ||
    fail "workflow YAML is invalid: ${workflow##*/}"
done
rg -Fq 'name: Linnet manual full CI' "${commit_workflow}" ||
  fail "main full CI is not explicitly manual"
rg -Fq 'workflow_dispatch:' "${commit_workflow}" ||
  fail "main full CI lost its manual trigger"
if rg -n '^[[:space:]]*push:' "${commit_workflow}"; then
  fail "every main push still spends the full CI matrix"
fi
for workflow in "${commit_workflow}" "${pull_request_workflow}"; do
  rg -Fq 'profile: [app, swift, rime]' "${workflow}" ||
    fail "CI did not retire the duplicate settings-ui product job"
  rg -Fq 'tests/verify_visible_settings_fixture.sh --ui-test' "${workflow}" ||
    fail "settings UI acceptance disappeared instead of moving into app"
done
if rg -n 'only_testing=\(\)|"\$\{only_testing\[@\]\}"' \
    "${visible_settings_fixture}"; then
  fail "the full Settings UI suite can still become a false-green empty-array launch"
fi
for required in \
    'ui_test_completed=false' \
    'ui_test_completed=true' \
    'UI suite did not reach its completed boundary'; do
  rg -Fq -- "${required}" "${visible_settings_fixture}" ||
    fail "the Settings UI launcher lost its false-green completion guard: ${required}"
done

rg -Fq 'linnet-pack-tool: $(LINNET_PACK_TOOL)' "${repo_root}/Makefile" ||
  fail "canonical release CLI target is missing"
if [[ "$(rg -c '\$\(LINNET_PACK_TOOL_SOURCES\) -o \$\(LINNET_PACK_TOOL\)' \
      "${repo_root}/Makefile")" -ne 1 ]]; then
  fail "release CLI must compile exactly once per Make invocation"
fi
if rg -n 'swiftc|LinnetPackTool\.swift' \
    "${repo_root}/package/make_package" "${repo_root}/package/make_archive"; then
  fail "package or archive assembly recompiles the release CLI"
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
  "${fixture_repo}/config" "${release_dir}" "${fake_bin}" "${fixture}/tmp"
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
[[ "$#" -eq 3 && "$1" == "${FAKE_RELEASE_DIR:?}" ]]
[[ "$2" == 0.1.8 && "$3" == "${FAKE_REVISION:?}" ]]
[[ -x "${LINNET_RELEASE_TOOL:?}" ]]
echo "artifact verify" >>"${FAKE_LOG:?}"
FAKE_VERIFY
cat >"${fixture_repo}/package/release_candidate_identity" <<'FAKE_IDENTITY'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 3 && "$1" == "${FAKE_RELEASE_DIR:?}" ]]
[[ "$2" == 0.1.8 && "$3" == 29 ]]
printf 'sha256:%064d\n' 0
FAKE_IDENTITY
cat >"${fixture_repo}/package/stage_github_release" <<'FAKE_STAGE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 6 && "$1" == verify ]]
[[ "$2" == core || "$2" == data || "$2" == public ]]
[[ "$3" == "${FAKE_RELEASE_DIR:?}" ]]
[[ "$4" == 0.1.8 && "$5" == 29 && "$6" == "${FAKE_REVISION:?}" ]]
echo "verify $2" >>"${FAKE_LOG:?}"
FAKE_STAGE

cat >"${fake_bin}/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -C ]] && shift 2
case "${1:-} ${2:-}" in
  "remote get-url") echo git@github.com:Ares-X/Linnet.git ;;
  "status --porcelain=v1") [[ -z "${FAKE_DIRTY:-}" ]] || echo ' M owned-file' ;;
  "rev-parse --verify") echo "${FAKE_REVISION:?}" ;;
  "ls-remote --exit-code")
    printf '%s\trefs/heads/main\n' \
      "${FAKE_MAIN_REVISION:-${FAKE_REVISION:?}}" ;;
  "ls-remote origin")
    [[ -z "${FAKE_AUTH_PRESENT:-}" ]] ||
      printf '%s\t%s\n' "${FAKE_AUTH_REVISION:-${FAKE_REVISION:?}}" "$3" ;;
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
cat >"${fake_bin}/make" <<'FAKE_MAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == -C ]]
repo="$2"
shift 2
[[ "$1" == --no-print-directory && "$2" == linnet-pack-tool ]]
mkdir -p "${repo}/build"
printf '#!/usr/bin/env bash\nexit 0\n' >"${repo}/build/linnet-pack"
chmod 755 "${repo}/build/linnet-pack"
echo 'make linnet-pack-tool' >>"${FAKE_LOG:?}"
FAKE_MAKE
chmod 755 "${fixture_repo}/scripts/release-control" \
  "${fixture_repo}/package/data_release_metadata" \
  "${fixture_repo}/package/verify_publication_artifacts" \
  "${fixture_repo}/package/release_candidate_identity" \
  "${fixture_repo}/package/stage_github_release" \
  "${fake_bin}/git" "${fake_bin}/gh" "${fake_bin}/make"

export FAKE_REVISION=0123456789abcdef0123456789abcdef01234567
export FAKE_RELEASE_DIR="${release_dir}"
export FAKE_LOG="${fake_log}"
fake_path="${fake_bin}:${PATH}"
expected_tag="linnet-publication/v0.1.8-${FAKE_REVISION}-h$(printf '%064d' 0)"

: >"${fake_log}"
TMPDIR="${fixture}/tmp" PATH="${fake_path}" \
  "${fixture_repo}/scripts/release-control" authorize "${release_dir}" >/dev/null
[[ "$(grep -E '^verify ' "${fake_log}")" == \
  $'verify core\nverify data\nverify public' ]] ||
  fail "local authorization did not reverify all three staged channels"
[[ "$(grep -c "^push ${FAKE_REVISION}:refs/tags/${expected_tag}$" \
    "${fake_log}")" -eq 1 ]] ||
  fail "local authorization did not create one exact byte-bound tag"
[[ "$(grep -c '^make linnet-pack-tool$' "${fake_log}")" -eq 1 ]] ||
  fail "local authorization did not compile its verifier once"

: >"${fake_log}"
FAKE_AUTH_PRESENT=1 TMPDIR="${fixture}/tmp" PATH="${fake_path}" \
  "${fixture_repo}/scripts/release-control" authorize "${release_dir}" >/dev/null
if grep -q '^push ' "${fake_log}"; then
  fail "an existing exact authorization was pushed again"
fi

for rejection in dirty wrong-main wrong-existing-tag; do
  : >"${fake_log}"
  case "${rejection}" in
    dirty)
      if FAKE_DIRTY=1 TMPDIR="${fixture}/tmp" PATH="${fake_path}" \
          "${fixture_repo}/scripts/release-control" authorize "${release_dir}" \
          >/dev/null 2>&1; then
        fail "dirty checkout was accepted"
      fi
      ;;
    wrong-main)
      if FAKE_MAIN_REVISION=ffffffffffffffffffffffffffffffffffffffff \
          TMPDIR="${fixture}/tmp" PATH="${fake_path}" \
          "${fixture_repo}/scripts/release-control" authorize "${release_dir}" \
          >/dev/null 2>&1; then
        fail "non-main revision was accepted"
      fi
      ;;
    wrong-existing-tag)
      if FAKE_AUTH_PRESENT=1 \
          FAKE_AUTH_REVISION=ffffffffffffffffffffffffffffffffffffffff \
          TMPDIR="${fixture}/tmp" PATH="${fake_path}" \
          "${fixture_repo}/scripts/release-control" authorize "${release_dir}" \
          >/dev/null 2>&1; then
        fail "authorization tag owned by another revision was accepted"
      fi
      if grep -q '^push ' "${fake_log}"; then
        fail "conflicting authorization tag was overwritten"
      fi
      ;;
  esac
  if [[ "${rejection}" != wrong-existing-tag && -s "${fake_log}" ]]; then
    fail "early rejection reached a build or remote boundary"
  fi
done

echo "Linnet Action release automation: PASS (macOS build + Draft transport + local authorization + Action publish)"
