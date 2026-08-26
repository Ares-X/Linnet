#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

# Structural owner for the web-free candidate and publication control plane.
# The dynamic GitHub mutation state machine remains covered by
# verify_publication_owner.sh.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
workflow="${repo_root}/.github/workflows/release-ci.yml"
control="${repo_root}/scripts/release-control"

fail() {
  echo "verify_release_automation: $*" >&2
  exit 1
}

[[ -f "${workflow}" && ! -L "${workflow}" ]] ||
  fail "release workflow is missing"
[[ -f "${control}" && ! -L "${control}" && -x "${control}" ]] ||
  fail "web-free release control command is missing"
bash -n "${control}"

if rg -n '^\s*workflow_dispatch:|community-publication|needs\.build-candidate\.outputs|\bgh workflow run\b|\bgh run approve\b' \
    "${workflow}" "${control}" || rg -n 'workflow_dispatch' "${control}"; then
  fail "retired web/API publication control returned"
fi

ruby -e '
  workflow = File.read(ARGV.fetch(0))
  control = File.read(ARGV.fetch(1))

  abort unless workflow.match?(/^on:\n  push:\n    tags:\n      - .linnet-candidate\/v\*-\*.\n      - .linnet-publication\/v\*-\*\-a\*.\n/m)
  abort if workflow.match?(/^\s+workflow_run:/)
  abort unless workflow.scan(/^  build-candidate:$/).size == 1
  abort unless workflow.scan(/^  publish-approved:$/).size == 1
  abort unless workflow.scan(/^    environment: community-signing$/).size == 1
  abort unless workflow.scan(/^    environment:/).size == 1
  abort unless workflow.scan(/^\s*make --no-print-directory archive$/).size == 1
  abort unless workflow.scan(%r{^\s*uses: actions/upload-artifact@[0-9a-f]{40}(?:\s+#.*)?$}).size == 1
  abort if workflow.match?(%r{^\s*uses: actions/download-artifact@}m)
  abort unless workflow.scan(/package\/verify_publication_artifacts/).size == 2

  build = workflow[/^  build-candidate:\n(?<body>.*?)(?=^  [a-z][a-z0-9-]*:\n|\z)/m, :body]
  publish = workflow[/^  publish-approved:\n(?<body>.*?)(?=^  [a-z][a-z0-9-]*:\n|\z)/m, :body]
  abort unless build && publish

  abort unless build.include?("startsWith(github.ref, \x27refs/tags/linnet-candidate/\x27)")
  abort unless build.include?(%q{github.event.created == true})
  abort unless build.include?(%q{github.event.deleted == false})
  abort unless build.include?(%q{github.run_attempt == 1})
  abort unless build.include?(%q{group: linnet-release-candidate})
  abort unless build.include?(%q{cancel-in-progress: true})
  abort unless build.match?(/permissions:\s*\n\s*actions:\s*read\s*\n\s*contents:\s*read/)
  abort if build.include?(%q{actions: write})
  abort unless build.include?(%q{candidate_pattern=})
  abort unless build.include?(%q{object.fetch("type") == "commit"})
  abort unless build.include?(%q{actions/workflows/commit-ci.yml/runs})
  abort unless build.include?(%q{run.fetch("path") == ".github/workflows/commit-ci.yml"})
  abort unless build.include?(%q{run.fetch("head_sha") == revision})
  abort unless build.include?(%q{run.fetch("head_branch") == "main"})
  abort unless build.include?(%q{run.fetch("event") == "push"})
  abort unless build.include?(%q{run.fetch("status") == "completed"})
  abort unless build.include?(%q{run.fetch("conclusion") == "success"})
  abort unless build.include?(%q{run.dig("head_repository", "full_name") == "Ares-X/Linnet"})
  abort unless build.include?("accepted.size == 1")
  abort unless build.include?("an unexpired candidate already exists for this revision")
  abort unless build.index("actions/artifacts") <
    build.index("LINNET_COMMUNITY_CMS_P12_BASE64")
  abort unless build.index("git/ref/heads/main") <
    build.index("LINNET_COMMUNITY_CMS_P12_BASE64")
  abort unless build.index("package/verify_publication_artifacts") <
    build.index("actions/upload-artifact")
  abort unless build.index("actions/upload-artifact") <
    build.index(%q{actions/artifacts/${ARTIFACT_ID}/zip})
  abort unless build.include?(%q{[[ "${ARTIFACT_DIGEST}" =~ ^[0-9a-f]{64}$ ]]})
  abort unless build.match?(/actual_digest="\$\(shasum -a 256 "\$\{artifact_zip\}" \| awk /)
  abort if build.include?(%q{actual_digest="sha256:$(shasum})
  abort unless build.include?(%q{test "${actual_digest}" = "${ARTIFACT_DIGEST}"})
  abort unless build.include?(%q{cmp -s "${expected}" "${actual}"})

  abort unless publish.include?("github.event_name == \x27push\x27")
  abort unless publish.include?("github.actor == \x27Ares-X\x27")
  abort unless publish.include?(%q{github.event.created == true})
  abort unless publish.include?(%q{github.event.deleted == false})
  abort unless publish.include?(%q{group: linnet-release-publication})
  abort unless publish.scan(/^\s*queue:\s*max\s*$/).size == 1
  abort unless publish.include?(%q{cancel-in-progress: false})
  abort unless publish.include?(%q{contents: write})
  abort unless publish.include?(%q{object.fetch("type") == "commit"})
  abort unless publish.include?(%q{repos/${GITHUB_REPOSITORY}/actions/artifacts/${artifact_id}})
  abort unless publish.include?(%q{artifact.fetch("expired") == false})
  abort unless publish.include?(%q{run.fetch("path") == ".github/workflows/release-ci.yml"})
  abort unless publish.include?(%q{run.fetch("head_branch") == candidate_tag})
  abort unless publish.include?(%q{run.fetch("event") == "push"})
  abort unless publish.include?(%q{actions/artifacts/${ARTIFACT_ID}/zip})
  abort unless publish.include?(%q{[[ "${ARTIFACT_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]]})
  abort unless publish.include?(%q{actual_digest="sha256:$(shasum})
  abort unless publish.include?(%q{test "${actual_digest}" = "${ARTIFACT_DIGEST}"})
  abort unless publish.include?(%q{steps.approval.outputs.authorization_tag})
  abort if publish.match?(/make --no-print-directory archive|LINNET_COMMUNITY_CMS|LINNET_CODE_SIGN|security import|upload-artifact/)
  release_positions = %w[core data catalog public].map do |channel|
    needle = "package/publish_github_release #{channel}"
    abort unless publish.scan(needle).size == 1
    publish.index(needle)
  end
  abort unless release_positions.each_cons(2).all? { |left, right| left < right }

  abort unless control.include?(%q{request) [[ "$#" -eq 1 ]]})
  abort unless control.include?(%q{fetch|approve) [[ "$#" -eq 2 ]]})
  request = control[/if \[\[ "\$\{command_name\}" == request \]\]; then\n(?<body>.*?)\nfi\n/m, :body]
  post_request = control.split(%q{if [[ "${command_name}" == request ]]; then}, 2).fetch(1)
    .split("\nfi\n", 2).fetch(1)
  abort unless request&.include?(%q{remote_ref_value refs/heads/main "remote main"})
  abort if post_request.include?(%q{refs/heads/main})
  abort unless control.include?(%q{candidate_tag="linnet-candidate/v${version}-${revision}"})
  abort unless control.include?(%q{git/ref/tags/${candidate_tag}})
  abort unless control.include?(%q{actions/artifacts/${artifact_id}/zip})
  abort unless control.include?(%q{remote_identity="$(validate_provenance})
  abort unless control.include?(%q{accepted_release="${fetch_root}/release"})
  abort unless control.include?("package/verify_publication_artifacts")
  abort unless control.include?(%q{approval_tag="linnet-publication/v${version}-${revision}-a${artifact_id}"})
  abort unless control.include?(%q{push origin "${revision}:${candidate_ref}"})
  abort unless control.include?(%q{push origin "${revision}:${approval_ref}"})
  abort if control.match?(/--force|push\s+-f|update-ref\s+-d|push\s+[^\n]*origin\s+["\x27]:refs\/tags/)
  abort if control.match?(/--method\s+(?:POST|PATCH|DELETE)|workflow_dispatch|community-publication|pending_deployments/)
  abort if workflow.match?(/32855610087|Retire the exact legacy|actions\/runs\/\$\{LEGACY_RUN_ID\}\/cancel/)
' "${workflow}" "${control}" ||
  fail "release automation owner is incomplete"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/linnet-release-automation.XXXXXX")"
cleanup() {
  [[ "${fixture}" == "${TMPDIR:-/tmp}/linnet-release-automation."* ]] &&
    rm -rf -- "${fixture}"
}
trap cleanup EXIT
fixture_root="${fixture}/repo"
fake_bin="${fixture}/bin"
artifact_source="${fixture}/artifact-source"
artifact_zip="${fixture}/artifact.zip"
metadata_root="${fixture}/metadata"
fetch_root="${fixture}/fetch-root"
fake_log="${fixture}/calls.log"
mkdir -p "${fixture_root}/scripts" "${fixture_root}/config" \
  "${fixture_root}/package" "${fake_bin}" "${artifact_source}" \
  "${metadata_root}" "${fixture}/mutations"
cp "${control}" "${fixture_root}/scripts/release-control"
printf 'MARKETING_VERSION = 0.1.13\n' \
  >"${fixture_root}/config/LinnetProduct.xcconfig"

fixture_revision="0123456789abcdef0123456789abcdef01234567"
candidate_tag="linnet-candidate/v0.1.13-${fixture_revision}"
artifact_name="linnet-0.1.13-${fixture_revision}"
artifact_files=(
  Linnet.pkg
  Linnet-0.1.13-arm64-Core-community-beta.pkg
  Linnet-0.1.13-Uninstall.command
  Linnet-Chinese.linnetpack
  Linnet-English.linnetpack
  Linnet-Extended.linnetpack
  Linnet-LTS.linnetpack
  Linnet-Data-Channel.json
)
for artifact_file in "${artifact_files[@]}"; do
  printf 'fixture bytes for %s\n' "${artifact_file}" \
    >"${artifact_source}/${artifact_file}"
done
(
  cd "${artifact_source}"
  /usr/bin/zip -q -X "${artifact_zip}" "${artifact_files[@]}"
)
artifact_digest="sha256:$(shasum -a 256 "${artifact_zip}" | awk '{print $1}')"
artifact_size="$(wc -c <"${artifact_zip}" | tr -d ' ')"
ruby -rjson -e '
  root, revision, candidate_tag, artifact_name, digest, size = ARGV
  repository = { "id" => 44, "full_name" => "Ares-X/Linnet" }
  producer = {
    "id" => 991,
    "name" => "Linnet community release",
    "path" => ".github/workflows/release-ci.yml",
    "head_sha" => revision,
    "head_branch" => candidate_tag,
    "event" => "push",
    "status" => "completed",
    "conclusion" => "success",
    "run_attempt" => 1,
    "repository" => repository,
    "head_repository" => repository,
    "actor" => { "login" => "Ares-X" },
    "triggering_actor" => { "login" => "Ares-X" },
  }
  artifact = {
    "id" => 731,
    "name" => artifact_name,
    "size_in_bytes" => Integer(size, 10),
    "expired" => false,
    "digest" => digest,
    "workflow_run" => {
      "id" => 991,
      "head_sha" => revision,
      "head_branch" => candidate_tag,
      "repository_id" => 44,
      "head_repository_id" => 44,
    },
  }
  candidate = {
    "ref" => "refs/tags/#{candidate_tag}",
    "object" => { "type" => "commit", "sha" => revision },
  }
  File.binwrite(File.join(root, "candidate.json"), JSON.pretty_generate(candidate) + "\n")
  File.binwrite(File.join(root, "artifact.json"), JSON.pretty_generate(artifact) + "\n")
  File.binwrite(File.join(root, "producer.json"), JSON.pretty_generate(producer) + "\n")
  File.binwrite(File.join(root, "artifacts.json"),
    JSON.pretty_generate({ "total_count" => 1, "artifacts" => [artifact] }) + "\n")
  duplicate = Marshal.load(Marshal.dump(artifact))
  duplicate["id"] = 732
  File.binwrite(File.join(root, "artifacts-duplicate.json"),
    JSON.pretty_generate({ "total_count" => 2, "artifacts" => [artifact, duplicate] }) + "\n")
' "${metadata_root}" "${fixture_revision}" "${candidate_tag}" \
  "${artifact_name}" "${artifact_digest}" "${artifact_size}"

printf '%s\n' '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[[ "$#" -eq 3 ]]' \
  '[[ -d "$1" && ! -L "$1" ]]' \
  '[[ "$2" == 0.1.13 ]]' \
  '[[ "$3" == "${FAKE_REVISION:?}" ]]' \
  '[[ -x "${LINNET_RELEASE_TOOL:?}" ]]' \
  '[[ "$(find "$1" -mindepth 1 -maxdepth 1 -type f ! -type l | wc -l | tr -d " ")" -eq 8 ]]' \
  '[[ "$(find "$1" -mindepth 1 -maxdepth 1 | wc -l | tr -d " ")" -eq 8 ]]' \
  'printf "verifier %s\n" "$1" >>"${FAKE_LOG:?}"' \
  >"${fixture_root}/package/verify_publication_artifacts"
printf '%s\n' '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'echo "git $*" >>"${FAKE_LOG:?}"' \
  '[[ "${1:-}" == -C ]] && shift 2' \
  'case "${1:-} ${2:-}" in' \
  '  "status --porcelain") [[ -z "${FAKE_DIRTY:-}" ]] || echo " M user-file"; exit 0 ;;' \
  '  "remote get-url") echo git@github.com:Ares-X/Linnet.git; exit 0 ;;' \
  '  "rev-parse --verify") echo "${FAKE_REVISION:?}"; exit 0 ;;' \
  '  "show-ref --verify") exit 1 ;;' \
  '  "push origin")' \
  '    refspec="${3:-}"' \
  '    candidate="${FAKE_REVISION:?}:refs/tags/linnet-candidate/v0.1.13-${FAKE_REVISION}"' \
  '    publication="${FAKE_REVISION}:refs/tags/linnet-publication/v0.1.13-${FAKE_REVISION}-a731"' \
  '    [[ "${refspec}" == "${candidate}" || "${refspec}" == "${publication}" ]]' \
  '    exit 0 ;;' \
  'esac' \
  'if [[ "${1:-}" == ls-remote ]]; then' \
  '  shift' \
  '  exit_when_missing=0' \
  '  if [[ "${1:-}" == --exit-code ]]; then exit_when_missing=1; shift; fi' \
  '  [[ "${1:-}" == origin ]]; shift' \
  '  ref="${1:-}"' \
  '  case "${ref}" in' \
  '    refs/heads/main)' \
  '      printf "%s\\t%s\\n" "${FAKE_MAIN_REVISION:-${FAKE_REVISION:?}}" "${ref}" ;;' \
  '    refs/tags/linnet-candidate/*)' \
  '      if [[ -n "${FAKE_CANDIDATE_PRESENT:-}" ]]; then' \
  '        printf "%s\\t%s\\n" "${FAKE_REVISION:?}" "${ref}"' \
  '      elif [[ "${exit_when_missing}" -eq 1 ]]; then exit 2; fi ;;' \
  '    refs/tags/linnet-publication/*)' \
  '      if [[ -n "${FAKE_PUBLICATION_PRESENT:-}" ]]; then' \
  '        printf "%s\\t%s\\n" "${FAKE_REVISION:?}" "${ref}"' \
  '      elif [[ "${exit_when_missing}" -eq 1 ]]; then exit 2; fi ;;' \
  '    *) exit 91 ;;' \
  '  esac' \
  '  exit 0' \
  'fi' \
  'exit 90' \
  >"${fake_bin}/git"
printf '%s\n' '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'echo "gh $*" >>"${FAKE_LOG:?}"' \
  '[[ "${1:-}" == api ]] || exit 92' \
  'shift' \
  'if [[ "${1:-}" == --method ]]; then [[ "${2:-}" == GET ]]; shift 2; fi' \
  'endpoint="${1:-}"' \
  'case "${endpoint}" in' \
  '  repos/Ares-X/Linnet/git/ref/tags/linnet-candidate/*)' \
  '    /bin/cat "${FAKE_CANDIDATE_JSON:?}" ;;' \
  '  repos/Ares-X/Linnet/actions/artifacts)' \
  '    if [[ -n "${FAKE_DUPLICATE_ARTIFACT:-}" ]]; then' \
  '      /bin/cat "${FAKE_ARTIFACT_LIST_DUPLICATE:?}"' \
  '    else /bin/cat "${FAKE_ARTIFACT_LIST:?}"; fi ;;' \
  '  repos/Ares-X/Linnet/actions/artifacts/731/zip)' \
  '    /bin/cat "${FAKE_ARTIFACT_ZIP:?}" ;;' \
  '  repos/Ares-X/Linnet/actions/artifacts/731)' \
  '    /bin/cat "${FAKE_REMOTE_ARTIFACT_JSON:-${FAKE_ARTIFACT_JSON:?}}" ;;' \
  '  repos/Ares-X/Linnet/actions/runs/991)' \
  '    /bin/cat "${FAKE_REMOTE_PRODUCER_JSON:-${FAKE_PRODUCER_JSON:?}}" ;;' \
  '  *) exit 93 ;;' \
  'esac' \
  >"${fake_bin}/gh"
printf '%s\n' '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'output=""' \
  'while [[ "$#" -gt 0 ]]; do' \
  '  if [[ "$1" == -o ]]; then output="$2"; break; fi' \
  '  shift' \
  'done' \
  '[[ -n "${output}" ]]' \
  'install -m 0755 /dev/null "${output}"' \
  >"${fake_bin}/xcrun"
chmod 755 "${fixture_root}/scripts/release-control" \
  "${fixture_root}/package/verify_publication_artifacts" \
  "${fake_bin}/git" "${fake_bin}/gh" "${fake_bin}/xcrun"

export FAKE_LOG="${fake_log}"
export FAKE_REVISION="${fixture_revision}"
export FAKE_CANDIDATE_JSON="${metadata_root}/candidate.json"
export FAKE_ARTIFACT_JSON="${metadata_root}/artifact.json"
export FAKE_PRODUCER_JSON="${metadata_root}/producer.json"
export FAKE_ARTIFACT_LIST="${metadata_root}/artifacts.json"
export FAKE_ARTIFACT_LIST_DUPLICATE="${metadata_root}/artifacts-duplicate.json"
export FAKE_ARTIFACT_ZIP="${artifact_zip}"
fake_path="${fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin"

: >"${fake_log}"
if FAKE_MAIN_REVISION="ffffffffffffffffffffffffffffffffffffffff" \
    PATH="${fake_path}" "${fixture_root}/scripts/release-control" request \
      >/dev/null 2>&1; then
  fail "candidate request accepted a revision other than current main"
fi
if grep -q '^git .* push origin ' "${fake_log}"; then
  fail "rejected non-main candidate request mutated the remote tag namespace"
fi

: >"${fake_log}"
PATH="${fake_path}" "${fixture_root}/scripts/release-control" request >/dev/null
[[ "$(grep -c "ls-remote origin refs/tags/${candidate_tag}$" "${fake_log}")" -eq 1 &&
   "$(grep -c "push origin ${fixture_revision}:refs/tags/${candidate_tag}$" "${fake_log}")" -eq 1 ]] ||
  fail "candidate request did not perform exactly one absence check and one SSH push"
if grep -q '^gh ' "${fake_log}"; then
  fail "candidate request used GitHub API instead of the SSH owner"
fi

: >"${fake_log}"
FAKE_MAIN_REVISION="ffffffffffffffffffffffffffffffffffffffff" \
  FAKE_CANDIDATE_PRESENT=1 PATH="${fake_path}" \
  "${fixture_root}/scripts/release-control" fetch "${fetch_root}" >/dev/null
[[ -f "${fetch_root}/artifact.zip" && -f "${fetch_root}/artifact.json" &&
   -f "${fetch_root}/producer-run.json" && -f "${fetch_root}/candidate-ref.json" &&
   -d "${fetch_root}/release" ]] || fail "fetch did not materialize its exact root"
[[ "$(grep -c '^verifier ' "${fake_log}")" -eq 1 ]] ||
  fail "fetch did not verify the extracted candidate exactly once"
if grep -q '^git .* push origin ' "${fake_log}"; then
  fail "read-only fetch mutated the remote tag namespace"
fi
if grep -q 'ls-remote.*refs/heads/main' "${fake_log}"; then
  fail "frozen candidate fetch regained latest-main authority"
fi

approve_must_fail() {
  local label="$1"
  local root="$2"
  : >"${fake_log}"
  if FAKE_CANDIDATE_PRESENT=1 PATH="${fake_path}" \
      "${fixture_root}/scripts/release-control" approve "${root}" \
      >/dev/null 2>&1; then
    fail "invalid approval was accepted: ${label}"
  fi
  if grep -q 'push origin .*refs/tags/linnet-publication/' "${fake_log}"; then
    fail "failed approval mutated publication: ${label}"
  fi
}

mutate_provenance() {
  local mode="$1"
  local root="$2"
  ruby -rjson -e '
    mode, root = ARGV
    artifact_path = File.join(root, "artifact.json")
    producer_path = File.join(root, "producer-run.json")
    candidate_path = File.join(root, "candidate-ref.json")
    artifact = JSON.parse(File.binread(artifact_path))
    producer = JSON.parse(File.binread(producer_path))
    candidate = JSON.parse(File.binread(candidate_path))
    case mode
    when "id" then artifact["id"] = 732
    when "name" then artifact["name"] = "linnet-wrong"
    when "revision" then artifact.fetch("workflow_run")["head_sha"] = "f" * 40
    when "run" then artifact.fetch("workflow_run")["id"] = 992
    when "path" then producer["path"] = ".github/workflows/other.yml"
    when "event" then producer["event"] = "workflow_dispatch"
    when "digest" then artifact["digest"] = "sha256:" + ("0" * 64)
    when "expired" then artifact["expired"] = true
    when "annotated" then candidate.fetch("object")["type"] = "tag"
    else abort "unknown mutation"
    end
    File.binwrite(artifact_path, JSON.pretty_generate(artifact) + "\n")
    File.binwrite(producer_path, JSON.pretty_generate(producer) + "\n")
    File.binwrite(candidate_path, JSON.pretty_generate(candidate) + "\n")
  ' "${mode}" "${root}"
}

for mutation in id name revision run path event digest expired annotated; do
  mutation_root="${fixture}/mutations/${mutation}"
  cp -R "${fetch_root}" "${mutation_root}"
  mutate_provenance "${mutation}" "${mutation_root}"
  approve_must_fail "${mutation}" "${mutation_root}"
done

local_bytes_root="${fixture}/mutations/local-bytes"
cp -R "${fetch_root}" "${local_bytes_root}"
printf 'tampered\n' >>"${local_bytes_root}/release/Linnet.pkg"
approve_must_fail local-bytes "${local_bytes_root}"

archive_root="${fixture}/mutations/archive"
cp -R "${fetch_root}" "${archive_root}"
printf 'tampered\n' >>"${archive_root}/artifact.zip"
approve_must_fail archive-digest "${archive_root}"

remote_bad_artifact="${metadata_root}/artifact-remote-bad.json"
ruby -rjson -e '
  artifact = JSON.parse(File.binread(ARGV.fetch(0)))
  artifact["digest"] = "sha256:" + ("0" * 64)
  File.binwrite(ARGV.fetch(1), JSON.pretty_generate(artifact) + "\n")
' "${metadata_root}/artifact.json" "${remote_bad_artifact}"
: >"${fake_log}"
if FAKE_CANDIDATE_PRESENT=1 FAKE_REMOTE_ARTIFACT_JSON="${remote_bad_artifact}" \
    PATH="${fake_path}" "${fixture_root}/scripts/release-control" \
      approve "${fetch_root}" >/dev/null 2>&1; then
  fail "remote artifact metadata mismatch was accepted"
fi
if grep -q 'push origin .*refs/tags/linnet-publication/' "${fake_log}"; then
  fail "remote metadata failure mutated publication"
fi

: >"${fake_log}"
if FAKE_CANDIDATE_PRESENT=1 FAKE_DUPLICATE_ARTIFACT=1 PATH="${fake_path}" \
    "${fixture_root}/scripts/release-control" fetch \
      "${fixture}/duplicate-fetch" >/dev/null 2>&1; then
  fail "duplicate same-revision candidate artifact was accepted"
fi
if grep -q '^git .* push origin ' "${fake_log}"; then
  fail "duplicate discovery mutated the remote tag namespace"
fi

: >"${fake_log}"
FAKE_MAIN_REVISION="ffffffffffffffffffffffffffffffffffffffff" \
  FAKE_CANDIDATE_PRESENT=1 PATH="${fake_path}" \
  "${fixture_root}/scripts/release-control" approve "${fetch_root}" >/dev/null
[[ "$(grep -c '^verifier ' "${fake_log}")" -eq 2 ]] ||
  fail "approval did not verify both accepted and fresh ZIP bytes"
[[ "$(grep -c 'push origin .*refs/tags/linnet-publication/' "${fake_log}")" -eq 1 ]] ||
  fail "approval did not create exactly one SSH publication ref"
if grep -q 'ls-remote.*refs/heads/main' "${fake_log}"; then
  fail "frozen candidate approval regained latest-main authority"
fi

: >"${fake_log}"
if FAKE_DIRTY=1 PATH="${fake_path}" \
    "${fixture_root}/scripts/release-control" request >/dev/null 2>&1; then
  fail "dirty checkout was allowed to request a candidate"
fi
if grep -q '^git .* push origin ' "${fake_log}"; then
  fail "dirty request mutated the remote tag namespace"
fi

echo "Linnet web-free release automation owner: PASS"
