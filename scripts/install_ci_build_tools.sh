#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Linnet CI build tools require macOS." >&2
  exit 1
fi

case "${1:-}" in
  quality)
    tools=(swiftlint ripgrep)
    ;;
  release)
    tools=(ripgrep)
    ;;
  *)
    echo "Usage: $0 {quality|release}" >&2
    exit 2
    ;;
esac

# GitHub's hosted macOS image may contain this unrelated, untrusted tap.
# Remove it before Homebrew evaluates taps so project installs stay warning-free.
if brew tap | grep -Fqx 'aws/tap'; then
  if ! untap_output="$(brew untap aws/tap 2>&1)"; then
    printf '%s\n' "${untap_output}" >&2
    exit 1
  fi
fi

HOMEBREW_NO_AUTO_UPDATE=1 brew install "${tools[@]}"
