#!/usr/bin/env bash
# Run the shipped scripts against an isolated home; never install or register an App.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/linnet-installer-preflight.XXXXXX")"
trap 'rm -rf "${fixture_root}"' EXIT
fixture_home="${fixture_root}/user"
mkdir -p "${fixture_home}/Library" "${fixture_root}/scripts"
chmod 700 "${fixture_home}" "${fixture_home}/Library"
# Only redirect the home binding. All script decisions and platform operations
# remain the shipped implementation; no production test API is required.
ruby - "${repo_root}" "${fixture_root}" "${fixture_home}" <<'RUBY'
root, fixture, home = ARGV
%w[core-installer-scripts/preinstall installer-scripts/complete-postinstall].each do |name|
  source = File.read("#{root}/package/#{name}")
  source = source.sub('user_home="${HOME:-}"', "user_home='#{home}'")
  File.write("#{fixture}/scripts/#{File.basename(name)}", source)
end
RUBY
printf '0.1.20\n' >"${fixture_root}/scripts/candidate-core-version"
printf 'complete\n' >"${fixture_root}/scripts/install-mode"
preinstall="${fixture_root}/scripts/preinstall"
bash "${preinstall}"
mkdir -p "${fixture_home}/Library/Application Support/Linnet/.linnet-complete"
bash "${preinstall}"
mkdir -p "${fixture_home}/Library/Input Methods/Linnet.app/Contents"
printf 'damaged old App\n' >"${fixture_home}/Library/Input Methods/Linnet.app/Contents/Info.plist"
bash "${preinstall}"
printf 'core-update\n' >"${fixture_root}/scripts/install-mode"
bash "${preinstall}"
printf 'complete\n' >"${fixture_root}/scripts/install-mode"
staging="${fixture_home}/Library/Application Support/Linnet/.linnet-complete"
rmdir "${staging}"
ln -s "${fixture_home}" "${staging}"
if bash "${preinstall}" >"${fixture_root}/rejected.log" 2>&1; then
  echo 'preinstall accepted a symlink payload destination' >&2; exit 1
fi
rm "${staging}"
# A successful lifecycle with declined first-use authorization remains a
# successful install. Failed lifecycle installation still propagates failure.
rm -r "${fixture_home}/Library/Input Methods/Linnet.app"
cat >"${fixture_root}/scripts/lifecycle-postinstall" <<SHIM
#!/usr/bin/env bash
set -eu
mkdir -p '${fixture_home}/Library/Input Methods/Linnet.app/Contents/MacOS'
printf '#!/bin/bash\nexit 1\n' >'${fixture_home}/Library/Input Methods/Linnet.app/Contents/MacOS/Linnet'
chmod 700 '${fixture_home}/Library/Input Methods/Linnet.app/Contents/MacOS/Linnet'
SHIM
chmod 700 "${fixture_root}/scripts/lifecycle-postinstall"
printf '{"bundle_identifier":"io.github.ares-x.inputmethod.Linnet"}\n' \
  >"${fixture_root}/scripts/candidate-app-identity.json"
bash "${fixture_root}/scripts/complete-postinstall" >"${fixture_root}/authorization.log" 2>&1
printf '#!/bin/bash\nexit 7\n' >"${fixture_root}/scripts/lifecycle-postinstall"
if bash "${fixture_root}/scripts/complete-postinstall"; then
  echo 'Complete hid a failed lifecycle installation' >&2; exit 1
fi
printf 'Installer script behavior: PASS (fresh, existing staging, damaged App, Core repair, unsafe path, authorization decline, lifecycle failure)\n'
