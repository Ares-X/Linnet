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
if ruby -ryaml -e '
  steps = YAML.load_file(ARGV.fetch(0)).fetch("jobs").fetch("build-candidate").fetch("steps")
  ui_condition = "steps.request.outputs.mode == '\''candidate'\'' && " \
    "steps.request.outputs.settings_ui == '\''NOT_EXERCISED'\''"
  ui_steps = steps.select { |step| step.fetch("run", "").include?("verify_visible_settings_fixture.sh --ui-test") }
  exit(0) unless ui_steps.size == 1 && ui_steps.first["if"] == ui_condition
  exit(steps.any? do |step|
    source_repeat = step["if"] != "steps.request.outputs.mode == '\''data-seed'\''" &&
      step.fetch("run", "").match?(/verify_development\.sh (swift|rime)|run_periphery\.sh|run_swiftlint\.sh/)
    ui_repeat = step.fetch("run", "").include?("verify_visible_settings_fixture.sh --ui-test") &&
      step["if"] != ui_condition
    source_repeat || ui_repeat
  end ? 0 : 1)
' "${release_workflow}"; then
  fail "candidate Action repeats source/UI tests already verified on the exact local source tree"
fi
for owner in "${control}" "${stager}" "${publisher}" "${identity}"; do
  [[ -f "${owner}" && ! -L "${owner}" && -x "${owner}" ]] ||
    fail "release owner is missing: ${owner##*/}"
  bash -n "${owner}"
done

if rg -n 'actions/artifacts' \
    "${repo_root}/.github/workflows" "${stager}" "${publisher}"; then
  fail "the 906 MB Actions artifact upload/download path returned"
fi
# Diagnostic reports are not product transport. Only the manual UI lane may
# retain its isolated xcresult; no workflow may upload build/package payloads.
ruby -ryaml -e '
  ARGV.each do |path|
    workflow = YAML.load_file(path)
    workflow.fetch("jobs", {}).each_value do |job|
      job.fetch("steps", []).each do |step|
        next unless step.fetch("uses", "").match?(%r{actions/(upload|download)-artifact@})
        allowed = File.basename(path) == "commit-ci.yml" &&
          step["uses"].start_with?("actions/upload-artifact@") &&
          step.fetch("with", {})["path"] == "build/settings-ui-results/" &&
          step.fetch("with", {})["retention-days"] == 3
        abort "only isolated Settings reports may use Actions artifacts: #{path}" unless allowed
      end
    end
  end
' "${repo_root}"/.github/workflows/*.yml
if rg -n 'scripts/release-control publish|signs exactly once locally|本地归档.*正式候选|本机.*正式候选' \
    "${policy_docs[@]}"; then
  fail "maintainer documentation regained a local formal-candidate owner"
fi
for required in \
    'macOS GitHub Action' \
    'scripts/release-control preview' \
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
    'linnet-preview/v*-*-h*' \
    'Bootstrap an exact future LTS data seed' \
    'scripts/fetch-locked-release-asset upstreams.lock.json' \
    './action-install.sh' \
    'scripts/run_swiftlint.sh' \
    'tests/verify_development.sh rime' \
    'scripts/release-control verify-source' \
    'steps.request.outputs.settings_ui' \
    'make --no-print-directory archive' \
    'package/verify_publication_artifacts' \
    'for channel in core data public' \
    'package/stage_github_release stage' \
    'package/publish_github_release data-seed' \
    'runs-on: ubuntu-latest' \
    'package/publish_github_release "${publication_mode}"'; do
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
if rg -n 'Linnet manual full CI|actions/workflows/commit-ci.yml/runs|event=workflow_dispatch' \
    "${release_workflow}"; then
  fail "the candidate builder still depends on a second full-CI workflow"
fi
if [[ "$(rg -c '^[[:space:]]*run: ./action-install\.sh$' \
      "${release_workflow}")" -ne 1 ]]; then
  fail "the candidate workflow must hydrate locked inputs exactly once"
fi

for required in \
    'usage: scripts/release-control authorize ABSOLUTE_RELEASE_DIRECTORY' \
    'usage: scripts/release-control preview ABSOLUTE_RELEASE_DIRECTORY' \
    'remote get-url origin' \
    'ls-remote --exit-code origin refs/heads/main' \
    'package/verify_publication_artifacts' \
    'package/release_candidate_identity' \
    'linnet-publication/v${version}-${revision}-h${candidate_digest}' \
    'linnet-preview/v${version}-${revision}-h${candidate_digest}' \
    'package/stage_github_release" verify'; do
  rg -Fq -- "${required}" "${control}" ||
    fail "local UAT authorization boundary is incomplete: ${required}"
done
for required in \
    'source_tree()' \
    'GIT_INDEX_FILE=' \
    'verify_receipt()' \
    'cat-file tag' \
    'tag --annotate' \
    './action-build.sh release' \
    'scripts/run_swiftlint.sh' \
    'tests/verify_development.sh all' \
    'scripts/run_periphery.sh' \
    'settings_ui=NOT_EXERCISED' \
    'LINNET_ISOLATED_UI_TEST_DESKTOP' \
    'source changed during local verification'; do
  rg -Fq -- "${required}" "${control}" ||
    fail "local source verification owner is incomplete: ${required}"
done
if rg -n 'CI=true|workflow_dispatch|workflow_run|build/swift-unit-cache' "${release_workflow}" ||
    rg -n 'CI=true' "${control}"; then
  fail "candidate verification regained a fake UI environment or redundant test transport"
fi
if rg -n 'stage_github_release" stage|package/publish_github_release|release (create|upload|edit|delete)|refs/heads/data-channel' \
    "${control}"; then
  fail "the maintainer Mac can still build, upload, or publish release state"
fi
if rg -n -- '--force|push -f|--clobber' "${control}" "${stager}" "${publisher}"; then
  fail "release automation regained destructive replacement"
fi

rg -Fq 'mode}" == verify || "${GITHUB_ACTIONS:-}" == true' "${stager}" ||
  fail "draft mutation is not restricted to GitHub Actions"
if rg -n 'release edit|refs/heads/data-channel|--latest' "${stager}"; then
  fail "the candidate stager can still publish a channel"
fi
[[ "$(rg -c '^[[:space:]]*gh release delete "\$\{tag\}" --repo "\$\{repository\}" --yes$' \
      "${stager}")" -eq 1 ]] ||
  fail "the stager must have one exact owned-Draft retirement action"
for required in \
    'if [[ "${channel}" != data ]] || ! cmp -s "${expected}" "${actual}"; then' \
    '[[ "${mode}" == stage ]]' \
    'older Draft is not exact Linnet-owned state' \
    'release.fetch("isDraft")' \
    'release.fetch("targetCommitish") == ARGV.fetch(4)' \
    'only a byte-identical published data seed can be reused'; do
  rg -Fq -- "${required}" "${stager}" ||
    fail "Draft retirement is missing a fail-closed ownership boundary: ${required}"
done
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
  if rg -n 'matrix:|profile: \[app, swift, rime\]' "${workflow}"; then
    fail "CI still duplicates one checkout and hydration across product jobs"
  fi
  [[ "$(rg -c '^[[:space:]]*runs-on: macos-latest$' "${workflow}")" -eq 1 ]] ||
    fail "CI must use one serial macOS job: ${workflow##*/}"
  [[ "$(rg -c 'uses: \./\.github/actions/restore-locked-build-cache' \
        "${workflow}")" -eq 1 ]] ||
    fail "CI must restore locked build inputs once: ${workflow##*/}"
  [[ "$(rg -c '^[[:space:]]*run: \./action-install\.sh$' "${workflow}")" -eq 1 ]] ||
    fail "CI must hydrate locked inputs once: ${workflow##*/}"
  for required in \
      'scripts/run_swiftlint.sh' \
      'tests/verify_development.sh app' \
      'tests/verify_visible_settings_fixture.sh --ui-test' \
      'tests/verify_development.sh swift' \
      'tests/verify_development.sh rime' \
      'scripts/run_periphery.sh'; do
    rg -Fq -- "${required}" "${workflow}" ||
      fail "serial CI lost a required gate: ${workflow##*/}: ${required}"
  done
  ruby -e '
    source = File.binread(ARGV.fetch(0))
    ordered = ARGV.drop(1).map { |needle| source.index(needle) || abort(needle) }
    abort unless ordered == ordered.sort
  ' "${workflow}" \
    'scripts/run_swiftlint.sh' \
    'run: ./action-install.sh' \
    'tests/verify_development.sh app' \
    'tests/verify_development.sh swift' \
    'tests/verify_development.sh rime' \
    'scripts/run_periphery.sh' ||
    fail "CI product gates are not one deterministic serial chain: ${workflow##*/}"
done
rg -Fq 'build/tools' .github/actions/restore-locked-build-cache/action.yml ||
  fail "the pinned Periphery tool is no longer part of the verified build cache"
rg -Fq "scripts/run_periphery.sh" .github/actions/restore-locked-build-cache/action.yml ||
  fail "the build cache key no longer follows the pinned Periphery owner"
rg -Fq 'periphery_binary_sha256=' scripts/run_periphery.sh ||
  fail "cached Periphery bytes have no pinned binary identity"
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
expected_preview_tag="linnet-preview/v0.1.8-${FAKE_REVISION}-h$(printf '%064d' 0)"

: >"${fake_log}"
TMPDIR="${fixture}/tmp" PATH="${fake_path}" \
  "${fixture_repo}/scripts/release-control" preview "${release_dir}" >/dev/null
[[ "$(grep -E '^verify ' "${fake_log}")" == \
  $'verify core\nverify data\nverify public' ]] ||
  fail "local Preview authorization did not reverify the complete candidate"
[[ "$(grep -c "^push ${FAKE_REVISION}:refs/tags/${expected_preview_tag}$" \
    "${fake_log}")" -eq 1 ]] ||
  fail "local Preview authorization did not create one exact byte-bound tag"

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

# Exercise source identity with real Git objects and a local-only bare remote.
# Only expensive tool/test execution is stubbed; these are owner-contract tests,
# not claims that the fixture App or UI was tested.
source_repo="${fixture}/source-repo"
source_remote="${fixture}/source-remote.git"
source_bin="${fixture}/source-bin"
real_git="$(command -v git)"
mkdir -p "${source_repo}/scripts" "${source_repo}/tests" "${source_repo}/config" "${source_bin}"
cp "${control}" "${source_repo}/scripts/release-control"
printf 'build/\n' >"${source_repo}/.gitignore"
printf 'MARKETING_VERSION = 0.1.8\n' >"${source_repo}/config/LinnetProduct.xcconfig"
printf 'base\n' >"${source_repo}/source.txt"
for phase in action-build.sh scripts/run_swiftlint.sh scripts/run_periphery.sh \
    tests/verify_release_automation.sh tests/verify_publication_owner.sh \
    tests/verify_development.sh tests/verify_visible_settings_fixture.sh; do
  cat >"${source_repo}/${phase}" <<'FAKE_SOURCE_PHASE'
#!/usr/bin/env bash
set -euo pipefail
name="${0##*/}"
printf '%s %s\n' "${name}" "$*" >>"${FAKE_SOURCE_LOG:?}"
[[ "${FAKE_FAIL_PHASE:-}" != "${name}" ]] || exit 1
if [[ "${FAKE_CHANGE_SOURCE:-}" == 1 && "${name}" == run_periphery.sh ]]; then
  printf 'changed during verification\n' >>source.txt
fi
FAKE_SOURCE_PHASE
  chmod 755 "${source_repo}/${phase}"
done
for tool in xcodebuild xcrun sw_vers; do
  printf '#!/usr/bin/env bash\necho "fixture-toolchain"\n' >"${source_bin}/${tool}"
done
cat >"${source_bin}/DevToolsSecurity" <<'FAKE_DEVELOPER_MODE'
#!/usr/bin/env bash
printf 'Developer mode is currently %s.\n' "${FAKE_DEVELOPER_MODE:-disabled}"
FAKE_DEVELOPER_MODE
cat >"${source_bin}/git" <<'LOCAL_ONLY_GIT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -C && "${3:-}" == remote && "${4:-}" == get-url ]]; then
  echo git@github.com:Ares-X/Linnet.git
else
  exec "${FAKE_REAL_GIT:?}" "$@"
fi
LOCAL_ONLY_GIT
chmod 755 "${source_bin}/"*
"${real_git}" init -q --initial-branch=main "${source_repo}"
"${real_git}" -C "${source_repo}" config user.name Fixture
"${real_git}" -C "${source_repo}" config user.email fixture@example.invalid
"${real_git}" -C "${source_repo}" config commit.gpgSign false
"${real_git}" -C "${source_repo}" config core.hooksPath /dev/null
dependency_repo="${fixture}/dependency"
"${real_git}" init -q --initial-branch=main "${dependency_repo}"
printf 'dependency\n' >"${dependency_repo}/input.txt"
"${real_git}" -C "${dependency_repo}" add input.txt
"${real_git}" -C "${dependency_repo}" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c commit.gpgSign=false -c core.hooksPath=/dev/null commit -qm dependency
"${real_git}" -C "${source_repo}" -c protocol.file.allow=always submodule add -q \
  "${dependency_repo}" dependencies/pinned
"${real_git}" -C "${source_repo}" add --all
"${real_git}" -C "${source_repo}" commit -qm base
"${real_git}" init -q --bare "${source_remote}"
"${real_git}" -C "${source_repo}" remote add origin "${source_remote}"
source_command="${source_repo}/scripts/release-control"
source_receipt="${source_repo}/build/linnet-source-verification.json"
export FAKE_REAL_GIT="${real_git}" FAKE_SOURCE_LOG="${fixture}/source-calls.log"
source_path="${source_bin}:${PATH}"
printf 'staged\n' >"${source_repo}/source.txt"
"${real_git}" -C "${source_repo}" add source.txt
printf 'working\n' >"${source_repo}/source.txt"
printf 'new\n' >"${source_repo}/addition.txt"
index_before="$(shasum -a 256 "${source_repo}/.git/index")"
LINNET_ISOLATED_UI_TEST_DESKTOP=0 PATH="${source_path}" "${source_command}" verify-local >/dev/null
[[ "$(shasum -a 256 "${source_repo}/.git/index")" == "${index_before}" ]] ||
  fail "source verification changed the real staging index"
[[ "$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("profiles").fetch("settings_ui")' \
    "${source_receipt}")" == NOT_EXERCISED ]] || fail "unrun local UI was reported as PASS"
if grep -q '^verify_visible_settings_fixture.sh' "${FAKE_SOURCE_LOG}"; then
  fail "source verification ran UI on a nonisolated desktop"
fi
[[ "$(cat "${FAKE_SOURCE_LOG}")" == \
  $'action-build.sh release\nrun_swiftlint.sh \nverify_release_automation.sh \nverify_publication_owner.sh \nverify_development.sh all\nrun_periphery.sh ' ]] ||
  fail "local source acceptance did not execute each required owner once in order"

"${real_git}" -C "${source_repo}" add --all
"${real_git}" -C "${source_repo}" commit -qm accepted-source
# A merge/rebase-equivalent new commit with the exact same tree reuses acceptance.
"${real_git}" -C "${source_repo}" commit --allow-empty -qm same-source-tree
"${real_git}" -C "${source_repo}" push -q origin HEAD:refs/heads/main
source_revision="$("${real_git}" -C "${source_repo}" rev-parse HEAD)"
source_ref="refs/tags/linnet-candidate/v0.1.8-${source_revision}"
PATH="${source_path}" "${source_command}" candidate >/dev/null
[[ "$(PATH="${source_path}" "${source_command}" verify-source \
    "${source_ref}" "${source_revision}")" == NOT_EXERCISED ]] ||
  fail "the Action did not receive the exact source tree and missing UI status"
PATH="${source_path}" "${source_command}" candidate >/dev/null
[[ "$("${real_git}" -C "${source_repo}" cat-file -t "${source_ref}")" == tag ]] ||
  fail "candidate request used the retired lightweight tag"
printf 'dirty dependency\n' >>"${source_repo}/dependencies/pinned/input.txt"
if PATH="${source_path}" "${source_command}" verify-local >/dev/null 2>&1; then
  fail "a Git tree receipt accepted dirty dependency bytes outside the gitlink"
fi
printf 'dependency\n' >"${source_repo}/dependencies/pinned/input.txt"

for rejected in lightweight wrong-tree missing-profile ui-unknown; do
  bad_ref="refs/tags/linnet-candidate/v0.1.$((20 + ${#rejected}))-${source_revision}"
  # Each fixture has its own ref even when labels have equal lengths.
  "${real_git}" -C "${source_repo}" tag -d "${bad_ref#refs/tags/}" >/dev/null 2>&1 || true
  if [[ "${rejected}" == lightweight ]]; then
    "${real_git}" -C "${source_repo}" tag "${bad_ref#refs/tags/}" "${source_revision}"
  else
    ruby -rjson -e '
      receipt = JSON.parse(File.read(ARGV.fetch(0)))
      case ARGV.fetch(1)
      when "wrong-tree" then receipt["source_tree"] = "f" * 40
      when "missing-profile" then receipt["profiles"].delete("rime")
      when "ui-unknown" then receipt["profiles"]["settings_ui"] = "SKIPPED"
      end
      puts JSON.generate(receipt)
    ' "${source_receipt}" "${rejected}" >"${fixture}/bad-receipt.json"
    "${real_git}" -C "${source_repo}" -c tag.gpgSign=false tag --annotate \
      "${bad_ref#refs/tags/}" "${source_revision}" --file "${fixture}/bad-receipt.json"
  fi
  if PATH="${source_path}" "${source_command}" verify-source "${bad_ref}" \
      "${source_revision}" >/dev/null 2>&1; then
    fail "invalid candidate source proof was accepted: ${rejected}"
  fi
done
for failure in command source-change; do
  if [[ "${failure}" == command ]]; then
    if FAKE_FAIL_PHASE=verify_development.sh PATH="${source_path}" \
        "${source_command}" verify-local >/dev/null 2>&1; then
      fail "failed source tests issued acceptance"
    fi
  elif FAKE_CHANGE_SOURCE=1 PATH="${source_path}" \
      "${source_command}" verify-local >/dev/null 2>&1; then
    fail "a changing source tree issued acceptance"
  fi
  [[ ! -e "${source_receipt}" ]] || fail "failed source verification retained an old receipt"
done
LINNET_ISOLATED_UI_TEST_DESKTOP=1 FAKE_DEVELOPER_MODE=enabled PATH="${source_path}" \
  "${source_command}" verify-local >/dev/null
[[ "$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).fetch("profiles").fetch("settings_ui")' \
    "${source_receipt}")" == PASS ]] || fail "completed isolated UI was not recorded"

echo "Linnet Action release automation: PASS (macOS build + Draft transport + local authorization + Action publish)"
