#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
verifier="${repo_root}/package/verify_publication_artifacts"
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
  cache_action = "actions/cache@0057852bfaa89a56745cba8c7296529d2fc39830"
  abort unless uses.count(cache_action) == 2
  abort unless workflow.scan(/^\s*submodules:\s*true\s*$/).size == 2
  abort unless workflow.scan(/^\s*key:\s*linnet-build-v1-/).size == 2
  abort unless workflow.scan(/^\s*restore-keys:\s*\|/).size == 2
  %w[
    build/upstreams
    build/dependencies
    data/chinese/grammar
    build/linnet-english-cache
    data/plum/build
    librime/dist
  ].each { |path| abort unless workflow.scan(/^\s*#{Regexp.escape(path)}\s*$/).size == 2 }
  abort unless workflow.include?("Restored cache bytes are untrusted")
  abort unless workflow.scan(/^\s*run:\s*\.\/action-install\.sh\s*$/).size == 2
  abort unless workflow.include?("make --no-print-directory archive")
  abort if workflow.include?("./action-build.sh archive")
  abort unless workflow.include?("package/verify_publication_artifacts")
  abort unless workflow.include?(%q{gh release create "${GITHUB_REF_NAME}"})
  abort unless workflow.include?(%q{GH_TOKEN: ${{ github.token }}})
  abort unless workflow.match?(/publish-community:.*?contents:\s*write/m)
  abort unless workflow.scan(/^\s*run:\s*brew install ripgrep\s*$/).size == 2
  abort if workflow.match?(/LINNET_CODE_SIGN|notary|Developer ID|publication_plan/)
' "${workflow}" || fail "tag-authorized community workflow is incomplete"

echo "Linnet unsigned community publication owner: PASS"
