#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
verifier="${repo_root}/package/verify_publication_artifacts"
asset_manifest="${repo_root}/package/release_asset_manifest"
publisher="${repo_root}/package/publish_github_release"
workflow="${repo_root}/.github/workflows/release-ci.yml"

fail() {
  echo "verify_publication_owner: $*" >&2
  exit 1
}

for retired in package/publication_plan package/publish_release \
    config/linnet-publication-acceptance.json; do
  [[ ! -e "${repo_root}/${retired}" ]] ||
    fail "retired approval-commit publication path returned: ${retired}"
done

for owner in "${asset_manifest}" "${publisher}"; do
  [[ -f "${owner}" && ! -L "${owner}" && -x "${owner}" ]] ||
    fail "release channel owner is missing: ${owner##*/}"
  bash -n "${owner}"
done

if ! ruby - "${repo_root}/CHANGELOG.md" <<'RUBY'
text = File.read(ARGV.fetch(0))
sections = text.scan(/^## \d+\.\d+\.\d+ — .*?(?=^## \d+\.\d+\.\d+ — |\z)/m)
abort if sections.empty?
forbidden = [
  /\bREADME\b/i,
  /\bCHANGELOG\b/i,
  /\bGitHub Actions\b/i,
  /\bCI\b/,
  /文档/,
  /安装指南/,
  /下载入口/,
  /发布流程/,
  /发布脚本/,
  /构建流程/,
  /源码/,
]
abort if sections.any? { |section| forbidden.any? { |pattern| section.match?(pattern) } }
RUBY
then
  fail "CHANGELOG version notes contain maintainer-only repository work"
fi

if printf '%s\n' config/LinnetProduct.xcconfig |
    "${repo_root}/package/data_release_metadata" check-source-change \
      >/dev/null 2>&1; then
  fail "a Core identity change can still reuse an already-published Catalog sequence"
fi
printf '%s\n' config/LinnetProduct.xcconfig config/linnet-data-releases.json |
  "${repo_root}/package/data_release_metadata" check-source-change >/dev/null

version="$(sed -n 's/^MARKETING_VERSION = \([^[:space:]]*\)$/\1/p' \
  "${repo_root}/config/LinnetProduct.xcconfig")"
catalog_sequence="$("${repo_root}/package/data_release_metadata" get-catalog-sequence \
  "${repo_root}/config/linnet-data-releases.json")"
candidate_expected="$(printf '%s\n' \
  Linnet.pkg \
  "Linnet-${version}-arm64-Core-community-beta.pkg" \
  "Linnet-${version}-Uninstall.command" \
  Linnet-Chinese.linnetpack Linnet-English.linnetpack \
  Linnet-LTS.linnetpack Linnet-Extended.linnetpack \
  Linnet-Data-Channel.json | LC_ALL=C sort)"
public_expected=Linnet.pkg
core_expected="$(printf '%s\n' \
  "Linnet-${version}-arm64-Core-community-beta.pkg" \
  "Linnet-${version}-Uninstall.command" | LC_ALL=C sort)"
data_expected="$(printf '%s\n' \
  Linnet-Chinese.linnetpack Linnet-English.linnetpack \
  Linnet-LTS.linnetpack Linnet-Extended.linnetpack \
  Linnet-Data-Channel.json | LC_ALL=C sort)"
for spec in \
    "candidate:${candidate_expected}" \
    "public:${public_expected}" \
    "core:${core_expected}" \
    "data:${data_expected}"; do
  channel="${spec%%:*}"
  expected="${spec#*:}"
  actual="$("${asset_manifest}" "${channel}" "${version}" "${catalog_sequence}" |
    LC_ALL=C sort)" || fail "cannot project ${channel} release assets"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${channel} release asset inventory differs from the product contract"
done
if "${asset_manifest}" public "${version}" "${catalog_sequence}" |
    rg -q '\.sha256$|Core|linnetpack|Data-Channel'; then
  fail "the stable user Release regained component or checksum assets"
fi
for required in \
    'release create "${tag}" "${assets[@]}"' \
    'release delete "${tag}"' \
    'verify_assets' \
    'release edit "${tag}"' \
    'core-v${version}' \
    'data-${catalog_sequence}' \
    'refs/heads/data-channel' \
    '"${api}/blobs"' \
    '"${api}/trees"' \
    '"${api}/commits"' \
    'force=false'; do
  rg -Fq "${required}" "${publisher}" ||
    fail "the bounded GitHub publication state machine is incomplete: ${required}"
done
if rg -n -- '--clobber|--cleanup-tag|releases/delete' "${publisher}"; then
  fail "the publisher regained a destructive published-asset replacement path"
fi

publication_fixture="$(mktemp -d "${TMPDIR:-/tmp}/linnet-publication-owner.XXXXXX")"
cleanup() {
  [[ "${publication_fixture}" == "${TMPDIR:-/tmp}/linnet-publication-owner."* ]] &&
    rm -rf -- "${publication_fixture}"
}
trap cleanup EXIT
fixture_assets="${publication_fixture}/assets"
fake_bin="${publication_fixture}/bin"
fake_state="${publication_fixture}/state"
mkdir -p "${fixture_assets}" "${fake_bin}" "${fake_state}"
while IFS= read -r asset; do
  printf 'fixture:%s\n' "${asset}" >"${fixture_assets}/${asset}"
done < <("${asset_manifest}" candidate "${version}" "${catalog_sequence}")
cat >"${fake_bin}/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_GH_STATE:?}"
printf '%s\n' "$*" >>"${state}/calls.log"
if [[ "${1:-}" == api ]]; then
  shift
  method=GET
  input=""
  endpoint=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --method) method="$2"; shift 2 ;;
      --input) input="$2"; shift 2 ;;
      --jq) shift 2 ;;
      -f|-F) shift 2 ;;
      *) [[ -z "${endpoint}" ]] && endpoint="$1"; shift ;;
    esac
  done
  branch="${state}/data-channel"
  mkdir -p "${branch}/blobs" "${branch}/trees" "${branch}/commits"
  case "${method}:${endpoint}" in
    GET:repos/Ares-X/Linnet/git/ref/heads/data-channel)
      if [[ ! -f "${branch}/ref" ]]; then
        printf '%s\n' '{"message":"Not Found","status":"404"}'
        exit 1
      fi
      cat "${branch}/ref"
      ;;
    GET:repos/Ares-X/Linnet/git/commits/*)
      cat "${branch}/commits/${endpoint##*/}"
      ;;
    GET:repos/Ares-X/Linnet/git/trees/*)
      cat "${branch}/trees/${endpoint##*/}"
      ;;
    GET:repos/Ares-X/Linnet/git/blobs/*)
      base64 <"${branch}/blobs/${endpoint##*/}" | tr -d '\n'
      ;;
    POST:repos/Ares-X/Linnet/git/blobs)
      sha="$(ruby -rjson -rbase64 -e '
        document = JSON.parse(File.read(ARGV.fetch(0)))
        bytes = Base64.strict_decode64(document.fetch("content"))
        File.binwrite(ARGV.fetch(1), bytes)
        print Digest::SHA1.hexdigest(bytes)
      ' -rdigest "${input}" "${branch}/pending-blob")"
      mv "${branch}/pending-blob" "${branch}/blobs/${sha}"
      printf '%s\n' "${sha}"
      ;;
    POST:repos/Ares-X/Linnet/git/trees)
      blob="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("tree").fetch(0).fetch("sha")' "${input}")"
      sha="$(printf 'tree:%s' "${blob}" | shasum | awk '{print $1}')"
      printf '%s\n' "${blob}" >"${branch}/trees/${sha}"
      printf '%s\n' "${sha}"
      ;;
    POST:repos/Ares-X/Linnet/git/commits)
      ruby -rjson -e '
        document = JSON.parse(File.read(ARGV.fetch(0)))
        parents = document.fetch("parents", [])
        abort unless parents.all? { |parent| parent.match?(/\A[0-9a-f]{40}\z/) }
      ' "${input}"
      tree="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("tree")' "${input}")"
      count=1
      [[ ! -f "${branch}/commit-count" ]] || count=$(( $(cat "${branch}/commit-count") + 1 ))
      printf '%s\n' "${count}" >"${branch}/commit-count"
      sha="$(printf 'commit:%s:%s' "${tree}" "${count}" | shasum | awk '{print $1}')"
      printf '%s\n' "${tree}" >"${branch}/commits/${sha}"
      printf '%s\n' "${sha}"
      ;;
    POST:repos/Ares-X/Linnet/git/refs|PATCH:repos/Ares-X/Linnet/git/refs/heads/data-channel)
      sha="$(printf '%s\n' "$*" | sed -n 's/.*sha=\([^ ]*\).*/\1/p')"
      [[ -n "${sha}" ]] || sha="$(ls -t "${branch}/commits" | head -1)"
      printf '%s\n' "${sha}" >"${branch}/ref"
      ;;
    *) exit 2 ;;
  esac
  exit 0
fi
[[ "${1:-} ${2:-}" == "release view" || "${1:-} ${2:-}" == "release create" ||
  "${1:-} ${2:-}" == "release edit" || "${1:-} ${2:-}" == "release delete" ||
  "${1:-} ${2:-}" == "release download" ]] || exit 2
action="$2"
tag="${3:-}"
root="${state}/${tag}"
case "${action}" in
  view)
    [[ -f "${root}/status" ]] || exit 1
    read -r draft prerelease <"${root}/status"
    joined=" $* "
    if [[ "${joined}" == *" --json assets "* ]]; then
      cat "${root}/assets"
    elif [[ "${joined}" == *" --jq "* ]]; then
      printf '%s\n' "${draft}"
    else
      printf '{"isDraft":%s,"isPrerelease":%s}\n' "${draft}" "${prerelease}"
    fi
    ;;
  create)
    mkdir -p "${root}"
    : >"${root}/assets"
    shift 3
    while [[ "$#" -gt 0 && "$1" != --* ]]; do
      digest="$(shasum -a 256 "$1" | awk '{print $1}')"
      printf '%s\tsha256:%s\n' "${1##*/}" "${digest}" >>"${root}/assets"
      shift
    done
    LC_ALL=C sort -o "${root}/assets" "${root}/assets"
    prerelease=false
    [[ " $* " == *" --prerelease "* ]] && prerelease=true
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --notes-file)
          cp "$2" "${root}/notes"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    printf 'true %s\n' "${prerelease}" >"${root}/status"
    ;;
  edit)
    read -r _ prerelease <"${root}/status"
    shift 3
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --notes-file)
          cp "$2" "${root}/notes"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    printf 'false %s\n' "${prerelease}" >"${root}/status"
    ;;
  delete)
    rm -rf -- "${root}"
    ;;
  download)
    destination=""
    shift 3
    while [[ "$#" -gt 0 ]]; do
      case "$1" in
        --dir) destination="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [[ -f "${root}/status" && -n "${destination}" ]]
    cp "${FAKE_RELEASE_ASSETS:?}/Linnet-Data-Channel.json" "${destination}/"
    ;;
esac
FAKE_GH
chmod 755 "${fake_bin}/gh"
candidate_revision="$(git -C "${repo_root}" rev-parse HEAD)"
publish_fixture() {
  GITHUB_REPOSITORY=Ares-X/Linnet GH_TOKEN=fixture \
    FAKE_GH_STATE="${fake_state}" FAKE_RELEASE_ASSETS="${fixture_assets}" \
    RUNNER_TEMP="${publication_fixture}" \
    PATH="${fake_bin}:${PATH}" "${publisher}" "$1" "${fixture_assets}" \
      "${version}" "${catalog_sequence}" "${candidate_revision}" >/dev/null
}
publish_fixture data
publish_fixture public
rg -Fq '## 本版本更新' "${fake_state}/v${version}/notes" ||
  fail "the stable Release omitted the version change summary"
rg -Fq '按 Shift 切换中英文不显示光标旁状态提示' "${fake_state}/v${version}/notes" ||
  fail "the stable Release did not consume the current CHANGELOG section"
if rg -Fq '## 0.1.3' "${fake_state}/v${version}/notes"; then
  fail "the stable Release leaked an adjacent CHANGELOG version"
fi
printf 'stale release notes\n' >"${fake_state}/v${version}/notes"
publish_fixture public
rg -Fq '按 Shift 切换中英文不显示光标旁状态提示' "${fake_state}/v${version}/notes" ||
  fail "an exact published Release did not repair stale notes"
[[ "$(grep -c "^release create v${version} " "${fake_state}/calls.log")" == 1 ]] ||
  fail "an exact published stable Release was recreated"
[[ "$(cut -f1 "${fake_state}/v${version}/assets")" == Linnet.pkg ]] ||
  fail "the stable Release published more than the complete installer"
publish_fixture core
rg -Fq '按 Shift 切换中英文不显示光标旁状态提示' \
  "${fake_state}/core-v${version}/notes" ||
  fail "the Core Release omitted the version change summary"
printf 'stale core notes\n' >"${fake_state}/core-v${version}/notes"
publish_fixture core
rg -Fq '按 Shift 切换中英文不显示光标旁状态提示' \
  "${fake_state}/core-v${version}/notes" ||
  fail "an exact published Core Release did not repair stale notes"
[[ "$(grep -c "^release create core-v${version} " "${fake_state}/calls.log")" == 1 ]] ||
  fail "an exact published Core Release was recreated"
[[ "$(cat "${fake_state}/data-channel/commit-count")" == 1 ]] ||
  fail "an exact stable Catalog pointer created duplicate commits"
cmp -s "${fixture_assets}/Linnet-Data-Channel.json" \
  "${fake_state}/data-channel/blobs/$(cat "${fake_state}/data-channel/trees/$(cat "${fake_state}/data-channel/commits/$(cat "${fake_state}/data-channel/ref")")")" ||
  fail "the data-channel branch did not publish the exact Catalog bytes"
rm -rf -- "${fake_state}/data-${catalog_sequence}"
mkdir -p "${fake_state}/data-${catalog_sequence}"
printf 'true true\n' >"${fake_state}/data-${catalog_sequence}/status"
printf 'stale\tsha256:%064d\n' 0 >"${fake_state}/data-${catalog_sequence}/assets"
publish_fixture data
grep -Fq "release delete data-${catalog_sequence}" "${fake_state}/calls.log" ||
  fail "an interrupted data-channel draft did not enter the bounded retry path"
for spec in core:core-v${version} data:data-${catalog_sequence}; do
  channel="${spec%%:*}"
  tag="${spec#*:}"
  expected="$("${asset_manifest}" "${channel}" "${version}" "${catalog_sequence}")"
  actual="$(cut -f1 "${fake_state}/${tag}/assets")"
  [[ "${actual}" == "${expected}" ]] || fail "${channel} upload bypassed the manifest"
done

if rg -n 'Developer ID|notari[sz]|stapler|Gatekeeper rejected' "${verifier}"; then
  fail "the community artifact owner still requires Apple publisher trust"
fi
rg -Fq 'Status: no signature' "${verifier}" ||
  fail "the public artifact owner does not require an unsigned Installer"
rg -Fq 'manual-user-approval' "${verifier}" ||
  fail "the public artifact owner lost the manual-trust contract"

manual_trust_docs=(
  "${repo_root}/README.md"
  "${repo_root}/package/WELCOME.md"
  "${repo_root}/docs/release.md"
)
if rg -ni 'candidate.*UAT|候选.*UAT' "${repo_root}/package/WELCOME.md"; then
  fail "the public Installer Welcome still contains pre-release acceptance text"
fi
if rg -n 'xattr[[:space:]].*(-d|-c)|spctl[[:space:]].*--master-disable' \
    "${manual_trust_docs[@]}"; then
  fail "manual trust instructions disable or bypass a system security boundary"
fi

ruby -e '
  workflow = File.read(ARGV.fetch(0))
  uses = workflow.scan(/^\s*uses:\s*(\S+)/).flatten
  abort unless uses.all? { |value| value.match?(/@[0-9a-f]{40}\z/) }
  cache_action = "actions/cache@caa296126883cff596d87d8935842f9db880ef25"
  abort unless uses.count(cache_action) == 2
  abort unless workflow.scan(/^\s*submodules:\s*false\s*$/).size == 2
  abort unless workflow.scan(/^\s*key:\s*linnet-build-v1-/).size == 2
  abort unless workflow.scan(/^\s*restore-keys:\s*\|/).size == 2
  %w[
    build/upstreams
    build/dependencies
    data/chinese/grammar
    build/linnet-english-cache
    data/plum/build
  ].each { |path| abort unless workflow.scan(/^\s*#{Regexp.escape(path)}\s*$/).size == 2 }
  abort if workflow.match?(%r{^\s*(?:librime|plum|upstreams/[^/]+)\s*$})
  abort unless workflow.include?("Restored cache bytes are untrusted")
  abort unless workflow.scan(/^\s*run:\s*\.\/action-install\.sh\s*$/).size == 2
  abort unless workflow.include?("make --no-print-directory archive")
  abort if workflow.include?("./action-build.sh archive")
  abort unless workflow.include?("package/verify_publication_artifacts")
  abort unless workflow.include?("package/publish_github_release")
  abort if workflow.include?(%q{"${ARCHIVE_OUTPUT_DIR}"/*})
  data = workflow.index(%q{publish_github_release data}) or abort
  core = workflow.index(%q{publish_github_release core}) or abort
  public_release = workflow.index(%q{publish_github_release public}) or abort
  abort unless data < core && core < public_release
  abort unless workflow.include?(%q{GH_TOKEN: ${{ github.token }}})
  abort unless workflow.match?(/publish-community:.*?contents:\s*write/m)
  abort unless workflow.scan(/^\s*run:\s*brew install ripgrep\s*$/).size == 2
  abort if workflow.match?(/LINNET_CODE_SIGN|notary|Developer ID|publication_plan/)
' "${workflow}" || fail "tag-authorized community workflow is incomplete"

echo "Linnet unsigned community publication owner: PASS"
