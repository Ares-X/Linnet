#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

# One lifecycle boundary for native candidate tests. The installed input method
# runs from a different immutable App and does not share this worktree or the
# tests' temporary user directories, so it remains available. Candidate build
# tools, probes, or a Host/Settings executable under this exact worktree block
# overlapping native matrices.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

candidate_processes="$(ps -axo pid=,command= | awk '
  {
    pid = $1
    line = $0
    sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", line)
    executable = line
    sub(/[[:space:]].*$/, "", executable)
    basename = executable
    sub(/^.*\//, "", basename)
    if (basename ~ /^(rime_deployer|rime_dict_manager|rime-smoke(\..*)?|rime_golden_probe|auto_phrase_probe|Linnet|Squirrel|Settings)$/) {
      print pid "\t" line
    }
  }
')"

blocked=0
unknown_processes=
while IFS=$'\t' read -r process_id command_line; do
  [[ -n "${process_id}" ]] || continue
  executable="${command_line%%[[:space:]]*}"
  owns_candidate=0
  if [[ "${executable}" == "${repo_root}/"* ]]; then
    owns_candidate=1
  else
    lsof_output=
    if lsof_output="$(/usr/sbin/lsof -nP -a -p "${process_id}" -Ffn 2>/dev/null)"; then
      if printf '%s\n' "${lsof_output}" | awk -v prefix="n${repo_root}/" '
          /^f/ { descriptor = substr($0, 2); next }
          # A test or build can inherit stdio logs under this worktree without
          # loading its runtime. Actual executables, mappings and resource
          # descriptors still establish candidate ownership.
          descriptor != "cwd" && descriptor !~ /^[012]$/ &&
            index($0, prefix) == 1 { found = 1 }
          END { exit(found ? 0 : 1) }
        '; then
        owns_candidate=1
      fi
    elif kill -0 "${process_id}" 2>/dev/null; then
      unknown_processes+="$(printf '%6s %s\n' "${process_id}" "${command_line}")"
    fi
  fi
  if [[ "${owns_candidate}" -eq 1 ]]; then
    printf '%6s %s\n' "${process_id}" "${command_line}" >&2
    blocked=1
  fi
done <<<"${candidate_processes}"

if [[ "${blocked}" -eq 1 ]]; then
  echo "An exact candidate native owner blocks this isolated matrix." >&2
  exit 2
fi
if [[ -n "${unknown_processes}" ]]; then
  printf '%s\n' "${unknown_processes}" >&2
  echo "ENVIRONMENT_INVALID: a live native owner could not be inspected." >&2
  exit 3
fi
