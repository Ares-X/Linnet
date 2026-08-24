#!/bin/bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"
swiftlint lint --quiet --strict
