#!/usr/bin/env bash
# Exercise the shipped runtime without the developer's DYLD search paths.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ "$#" -gt 0 ]] || { echo "usage: $0 APP [APP...]" >&2; exit 2; }
scratch="$(mktemp -d /tmp/linnet-packaged-rime.XXXXXX)"
trap '/bin/rm -r -- "${scratch}"' EXIT
cat >"${scratch}/probe.cc" <<'CPP'
#include <dlfcn.h>
#include <cstdio>
#include <initializer_list>
#include <rime_api.h>

int main(int argc, char** argv) {
  if (argc != 3) return 2;
  void* library = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
  if (!library) { std::fprintf(stderr, "%s\n", dlerror()); return 1; }
  auto get_api = reinterpret_cast<RimeApi*(*)()>(dlsym(library, "rime_get_api"));
  if (!get_api) return 1;
  auto* api = get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = argv[2];
  traits.user_data_dir = argv[2];
  traits.min_log_level = 2;
  traits.log_dir = "";
  api->setup(&traits);
  api->initialize(nullptr);
  bool complete = true;
  for (const char* module : {"lua", "octagram", "predict", "smart_english"}) {
    if (!api->find_module(module)) {
      std::fprintf(stderr, "Missing packaged Rime module: %s\n", module);
      complete = false;
    }
  }
  api->finalize();
  return complete ? 0 : 1;
}
CPP
xcrun clang++ -std=c++17 -I "${repo_root}/librime/src" \
  "${scratch}/probe.cc" -o "${scratch}/probe"
for app in "$@"; do
  runtime="$(cd "${app}/Contents/Frameworks" && pwd -P)/librime.1.dylib"
  env -u DYLD_LIBRARY_PATH -u DYLD_FALLBACK_LIBRARY_PATH \
    -u DYLD_FRAMEWORK_PATH -u DYLD_INSERT_LIBRARIES \
    "${scratch}/probe" "${runtime}" "${scratch}"
  echo "Packaged Rime modules: PASS (${app})"
done
