#!/usr/bin/env bash

# Content-addressed compiler boundary for standalone Swift owner tests.
# Cached binaries are acceleration only: every invocation still executes the test.

linnet_swift_cache_init() {
  LINNET_SWIFT_CACHE_REPO="$1"
  LINNET_SWIFT_CACHE_SCRATCH="$2"
  LINNET_SWIFT_COMPILER="$(xcrun --find swiftc)"
  LINNET_MACOS_SDK="$(xcrun --show-sdk-path)"
  LINNET_SWIFT_CACHE_ROOT="${LINNET_SWIFT_UNIT_CACHE_ROOT:-${LINNET_SWIFT_CACHE_REPO}/build/swift-unit-cache}"
  mkdir -p "${LINNET_SWIFT_CACHE_SCRATCH}" "${LINNET_SWIFT_CACHE_ROOT}"
  [[ -d "${LINNET_SWIFT_CACHE_ROOT}" && ! -L "${LINNET_SWIFT_CACHE_ROOT}" ]] || {
    echo "Swift test cache root is unsafe: ${LINNET_SWIFT_CACHE_ROOT}" >&2
    return 1
  }

  LINNET_SWIFT_ENVIRONMENT_FINGERPRINT="$({
    "${LINNET_SWIFT_COMPILER}" -version 2>&1
    xcodebuild -version
    printf 'sdk=%s\n' "${LINNET_MACOS_SDK}"
    if [[ -d "${LINNET_SWIFT_CACHE_REPO}/librime/dist/include" ]]; then
      find "${LINNET_SWIFT_CACHE_REPO}/librime/dist/include" -type f -print |
        LC_ALL=C sort | while IFS= read -r header; do
          shasum -a 256 "${header}"
        done
    fi
    for library in \
        "${LINNET_SWIFT_CACHE_REPO}/lib/librime.1.dylib" \
        "${LINNET_SWIFT_CACHE_REPO}/tests/swift_test_cache.sh"; do
      [[ -f "${library}" && ! -L "${library}" ]] && shasum -a 256 "${library}"
    done
  } | shasum -a 256 | awk '{print $1}')"
}

linnet_swift_compile() {
  local name="$1"
  shift
  [[ "${name}" =~ ^[a-z0-9-]+$ ]] || {
    echo "Invalid Swift test cache name: ${name}" >&2
    return 1
  }

  local fingerprint
  fingerprint="$({
    printf 'environment=%s\n' "${LINNET_SWIFT_ENVIRONMENT_FINGERPRINT}"
    local argument
    for argument in "$@"; do
      printf 'argument=%q\n' "${argument}"
      if [[ -f "${argument}" && ! -L "${argument}" ]]; then
        shasum -a 256 "${argument}"
      fi
    done
  } | shasum -a 256 | awk '{print $1}')"

  local cached_binary="${LINNET_SWIFT_CACHE_ROOT}/${name}"
  local cached_key="${cached_binary}.key"
  local cached_digest="${cached_binary}.sha256"
  local output="${LINNET_SWIFT_CACHE_SCRATCH}/${name}"
  local cache_valid=false
  if [[ -f "${cached_binary}" && ! -L "${cached_binary}" && -x "${cached_binary}" &&
    -f "${cached_key}" && ! -L "${cached_key}" &&
    -f "${cached_digest}" && ! -L "${cached_digest}" &&
    "$(<"${cached_key}")" == "${fingerprint}" ]] &&
    (cd "${LINNET_SWIFT_CACHE_ROOT}" && shasum -a 256 -c "${name}.sha256" >/dev/null 2>&1); then
    cache_valid=true
  fi

  if [[ "${cache_valid}" == true ]]; then
    cp "${cached_binary}" "${output}"
    echo "Swift test compile cache: HIT ${name}"
  else
    "${LINNET_SWIFT_COMPILER}" "$@" -o "${output}"
    cp "${output}" "${cached_binary}"
    chmod u+x "${cached_binary}"
    (cd "${LINNET_SWIFT_CACHE_ROOT}" && shasum -a 256 "${name}" >"${name}.sha256.next")
    printf '%s\n' "${fingerprint}" >"${cached_key}.next"
    mv "${cached_digest}.next" "${cached_digest}"
    mv "${cached_key}.next" "${cached_key}"
    echo "Swift test compile cache: MISS ${name}"
  fi
  LINNET_SWIFT_COMPILED_BINARY="${output}"
}
