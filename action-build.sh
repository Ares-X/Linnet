#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
cd "${project_root}"

target="${1:-release}"
case "${target}" in
    release|debug|archive) ;;
    candidate)
        [[ "${LINNET_CODE_SIGN_PROFILE:-}" == uat ]] || {
            echo "${target} requires LINNET_CODE_SIGN_PROFILE=uat" >&2
            exit 2
        }
        scripts/linnet-code-identity preflight
        ;;
    *)
        echo "Usage: ./action-build.sh [release|debug|candidate|archive]" >&2
        exit 2
        ;;
esac

# The content-addressed preparation step initializes the native runtime and
# stages locked language data. Ordinary development and the public community
# archive need no certificate or Keychain. Only the explicit UAT candidate
# lane crosses the external signing boundary above.
./action-install.sh

case "${target}" in
    release|debug) make "${target}" ;;
    candidate) make candidate-verified ;;
    archive) make archive ;;
esac
