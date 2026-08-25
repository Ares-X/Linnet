#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${project_root}"

target="${1:-release}"
case "${target}" in
    release|debug|archive) ;;
    *)
        echo "Usage: ./action-build.sh [release|debug|archive]" >&2
        exit 2
        ;;
esac

if [[ "${target}" == archive ]]; then
    export LINNET_CANDIDATE_REVISION="${LINNET_CANDIDATE_REVISION:-$(git rev-parse --verify HEAD^{commit})}"
fi

# The content-addressed preparation step initializes the native runtime and
# stages locked language data. Ordinary development remains unsigned. The
# public archive uses the fixed community CMS identity and unlocks its dedicated
# Keychain from the protected local password file without an interactive prompt.
./action-install.sh

case "${target}" in
    release|debug) make "${target}" ;;
    archive) make archive ;;
esac
