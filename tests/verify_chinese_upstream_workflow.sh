#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
workflow="${repo_root}/.github/workflows/chinese-upstream-sync.yml"
reporter="${repo_root}/scripts/upstream-sync"
retired_relay="${repo_root}/.github/workflows/chinese-upstream-review.yml"
retired_duplicate_report="${repo_root}/.github/workflows/upstream-check.yml"

[[ ! -e "${retired_relay}" ]] || {
  echo "The retired Chinese update artifact relay still exists." >&2
  exit 1
}
[[ ! -e "${retired_duplicate_report}" ]] || {
  echo "The duplicate scheduled upstream report still exists." >&2
  exit 1
}
ruby -ryaml -e 'YAML.load_file(ARGV.fetch(0))' "${workflow}"
ruby -e '
  canonical = File.expand_path(ARGV.fetch(0))
  owners = Dir.glob(File.join(File.dirname(canonical), "*.{yml,yaml}"))
    .each_with_object({}) do |path, result|
      count = File.read(path).scan("ruby scripts/upstream-sync report").length
      result[File.expand_path(path)] = count if count.positive?
    end
  abort "scheduled upstream report owners: #{owners}" unless owners == {canonical => 1}
' "${workflow}"
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
' "${reporter}"

echo "Chinese upstream workflow: PASS (read-only standard upstream report; no Python composer)"
