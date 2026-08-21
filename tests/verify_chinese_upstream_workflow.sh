#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
workflow="${repo_root}/.github/workflows/chinese-upstream-sync.yml"
release_workflow="${repo_root}/.github/workflows/release-ci.yml"
reporter="${repo_root}/scripts/upstream-sync"
retired_relay="${repo_root}/.github/workflows/chinese-upstream-review.yml"

[[ ! -e "${retired_relay}" ]] || {
  echo "The retired Chinese update artifact relay still exists." >&2
  exit 1
}
ruby -ryaml -e 'YAML.load_file(ARGV.fetch(0))' "${workflow}"
ruby -e '
  workflow = File.read(ARGV.fetch(0))
  abort "a persistent repository update cache returned" if
    workflow.include?("data/chinese/cache")
  abort "the retired artifact relay returned" if
    workflow.match?(/handoff|workflow_run|upload-artifact|download-artifact/)
  abort "a Python setup or Chinese composer returned to upstream monitoring" if
    workflow.match?(/setup-python|(?:^|\s)(?:python3|pip)(?:\s|$)|update_upstreams|verify_generated/)
  abort "the read-only monitor does not use the canonical lock reporter" unless
    workflow.scan("ruby scripts/upstream-sync report").length == 1
  abort "the monitor checkout is not exact enough to resolve locked tags" unless
    workflow.include?("fetch-depth: 0") && workflow.include?("submodules: false")
  abort "upstream monitoring regained repository mutation authority" if
    workflow.match?(/contents:\s*write|pull-requests:\s*write|git push|gh pr create/)
  abort "review drift is not surfaced through one issue boundary" unless
    workflow.match?(/issues:\s*write/) && workflow.include?("gh issue create")
' "${workflow}"
ruby -e '
  reporter = File.read(ARGV.fetch(0))
  release = File.read(ARGV.fetch(1))
  local_verifier = reporter[/def verify_local\(lock\).*?\nend/m]
  abort "the local verifier still depends on developer-only upstream tags" unless
    local_verifier && !local_verifier.include?("tag_ref")
  abort "the LTS asset still bypasses the remote release identity owner" unless
    reporter.include?("releases/tags/") &&
      reporter.include?("digest") &&
      reporter.include?("asset_id") &&
      reporter.include?("browser_download_url")
  abort "the upstream report still presents mutable release assets as unconditionally locked" if
    reporter.include?(%q{grammar.fetch("sha256")[0, 12], grammar.fetch("release"), "locked"})
  report = release.index("ruby scripts/upstream-sync report")
  prepare = release.index("./action-install.sh")
  archive = release.index("make --no-print-directory archive")
  abort "release validation no longer checks locked upstream identities before the expensive build" unless
    report && prepare && archive && report < prepare && prepare < archive
' "${reporter}" "${release_workflow}"

echo "Chinese upstream workflow: PASS (read-only standard upstream report; no Python composer)"
