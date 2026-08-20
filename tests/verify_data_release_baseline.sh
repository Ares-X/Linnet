#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
baseline="${repo_root}/tests/fixtures/data-release-baseline/metadata-sequence-3.json"
[[ -f "${baseline}" && ! -L "${baseline}" ]] || {
  echo "Tracked data-release baseline is missing or unsafe." >&2
  exit 1
}

"${repo_root}/package/data_release_metadata" validate "${baseline}" >/dev/null
"${repo_root}/package/data_release_metadata" check-monotonic \
  "${baseline}" "${repo_root}/config/linnet-data-releases.json" >/dev/null

echo "Linnet data-release monotonic baseline: PASS"
