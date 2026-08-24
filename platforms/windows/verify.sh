#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${repo_root}"

ruby scripts/upstream-sync verify

weasel_commit="$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("sources", "weasel", "commit")' upstreams.lock.json)"
gitlink="$(git ls-files --stage -- upstreams/weasel | awk '{print $2}')"
[[ "${gitlink}" == "${weasel_commit}" ]] || {
  echo "Windows frontend gitlink differs from the lock." >&2
  exit 1
}

while IFS= read -r locked_patch; do
  [[ "$(git check-attr eol -- "${locked_patch}")" == \
      "${locked_patch}: eol: lf" ]] || {
    echo "Locked patch checkout bytes are not fixed to LF: ${locked_patch}" >&2
    exit 1
  }
done < <(ruby -rjson -e '
  JSON.parse(File.read(ARGV.fetch(0))).fetch("downstream_patches").each_value do |item|
    puts item.fetch("path")
  end
' upstreams.lock.json)

scratch="$(mktemp -d "${TMPDIR:-/tmp}/linnet-weasel-verify.XXXXXX")"
cleanup() {
  find "${scratch}" -depth -delete
}
trap cleanup EXIT
git -C upstreams/weasel archive "${weasel_commit}" | tar -xf - -C "${scratch}"
git -C "${scratch}" apply --check --ignore-space-change \
  "${repo_root}/platforms/windows/patches/weasel-linnet.patch"
git -C "${scratch}" apply --ignore-space-change \
  "${repo_root}/platforms/windows/patches/weasel-linnet.patch"

projection_repo="${scratch}/projection-repo"
projection_root="${projection_repo}/build/windows/weasel"
git init --quiet "${projection_repo}"
mkdir -p "${projection_root}"
git -C upstreams/weasel archive "${weasel_commit}" | tar -xf - -C "${projection_root}"
git -C "${projection_repo}" apply --check --ignore-space-change \
  --directory=build/windows/weasel \
  "${repo_root}/platforms/windows/patches/weasel-linnet.patch"
git -C "${projection_repo}" apply --ignore-space-change \
  --directory=build/windows/weasel \
  "${repo_root}/platforms/windows/patches/weasel-linnet.patch"
git -C "${projection_repo}" apply --reverse --check --ignore-space-change \
  --directory=build/windows/weasel \
  "${repo_root}/platforms/windows/patches/weasel-linnet.patch"
rg -Fq 'if %build_data% == 1 goto linnet_data_error' \
  "${projection_root}/build.bat"

generated_weasel="${scratch}/linnet-generated-weasel.yaml"
generated_previews="${scratch}/linnet-theme-previews"
scripts/project-windows-weasel-config platforms/windows/weasel.base.yaml \
  data/squirrel.yaml "${generated_weasel}" "${generated_previews}"
ruby -ryaml -rzlib -e '
  source = YAML.safe_load(File.binread(ARGV.fetch(0)), aliases: false)
  windows = YAML.safe_load(File.binread(ARGV.fetch(1)), aliases: false)
  expected = source.fetch("preset_color_schemes").keys.grep(
    /\Alinnet_.+_(?:light|dark)\z/
  )
  actual = windows.fetch("preset_color_schemes").keys
  abort "Windows theme catalog differs from Linnet" unless actual == expected
  abort "Windows theme colors are not declared as canonical ARGB" unless
    actual.all? do |name|
      windows.fetch("preset_color_schemes").fetch(name).fetch("color_format") == "argb"
    end
  shared_colors = %w[
    back_color border_color text_color candidate_text_color label_color
    comment_text_color hilited_text_color hilited_back_color
    hilited_candidate_text_color hilited_candidate_back_color
    hilited_comment_text_color
  ]
  expected.each do |name|
    source_scheme = source.fetch("preset_color_schemes").fetch(name)
    windows_scheme = windows.fetch("preset_color_schemes").fetch(name)
    shared_colors.each do |key|
      next unless source_scheme.key?(key)
      abort "Windows theme color differs: #{name}/#{key}" unless
        windows_scheme.fetch(key) == source_scheme.fetch(key)
    end
    abort "Windows highlighted label differs: #{name}" unless
      windows_scheme.fetch("hilited_label_color") ==
        source_scheme.fetch("hilited_candidate_label_color")
  end
  expected.grep(/_light\z/).each do |name|
    png = File.binread(File.join(ARGV.fetch(2), "color_scheme_#{name}.png"))
    offset = 8
    compressed = +"".b
    while offset < png.bytesize
      length = png.byteslice(offset, 4).unpack1("N")
      type = png.byteslice(offset + 4, 4)
      compressed << png.byteslice(offset + 8, length) if type == "IDAT"
      offset += 12 + length
    end
    pixels = Zlib::Inflate.inflate(compressed)
    rgba = pixels.byteslice(10 * (1 + 320 * 4) + 1 + 10 * 4, 4).bytes
    color = source.fetch("preset_color_schemes").fetch(name).fetch("back_color")
    expected_rgba = [(color >> 16) & 0xff, (color >> 8) & 0xff, color & 0xff,
                     color > 0xffffff ? (color >> 24) & 0xff : 0xff]
    abort "Windows preview color channels differ: #{name}" unless
      rgba == expected_rgba
  end
  abort "Windows dark theme owner is missing" unless
    windows.dig("style", "color_scheme_dark") == "linnet_paper_dark"
' data/squirrel.yaml "${generated_weasel}" "${generated_previews}"
[[ "$(find "${generated_previews}" -type f -name 'color_scheme_linnet_*_light.png' | wc -l | tr -d ' ')" == 7 ]] || {
  echo "Windows theme preview catalog is incomplete." >&2
  exit 1
}
while IFS= read -r preview; do
  [[ "$(od -An -tx1 -N8 "${preview}" | tr -d ' \n')" == 89504e470d0a1a0a ]] || {
    echo "Invalid Windows theme preview: ${preview}" >&2
    exit 1
  }
done < <(find "${generated_previews}" -type f -name '*.png' | sort)
second_weasel="${scratch}/linnet-generated-weasel-second.yaml"
second_previews="${scratch}/linnet-theme-previews-second"
scripts/project-windows-weasel-config platforms/windows/weasel.base.yaml \
  data/squirrel.yaml "${second_weasel}" "${second_previews}"
cmp "${generated_weasel}" "${second_weasel}"
diff -qr "${generated_previews}" "${second_previews}" >/dev/null
rg -Fq '#define WEASEL_REG_KEY L"Software\\Linnet"' \
  "${scratch}/include/WeaselConstants.h"
rg -Fq '#define WEASEL_IPC_PIPE_NAME L"LinnetNamedPipe"' \
  "${scratch}/include/WeaselIPC.h"
rg -Fq 'L"%AppData%\\Linnet"' \
  "${scratch}/RimeWithWeasel/WeaselUtility.cpp"
rg -Fq 'rime.linnet.windows' \
  "${scratch}/RimeWithWeasel/RimeWithWeasel.cpp"
if rg -Fq 'find_module("smart_english")' \
    "${scratch}/RimeWithWeasel/RimeWithWeasel.cpp"; then
  echo "The Weasel frontend retained a duplicate runtime-module gate." >&2
  exit 1
fi
rg -Fq 'L"\\linnet" + ext' "${scratch}/WeaselSetup/imesetup.cpp"
rg -Fq '660F0020-8849-43B3-8FB0-806CF516F3B0' \
  "${scratch}/WeaselTSF/Globals.cpp"
rg -Fq 'constexpr char kLinnetPrefix[] = "linnet_"' \
  "${scratch}/WeaselDeployer/UIStyleSettings.cpp"
rg -Fq 'customize_string(settings_, "style/color_scheme_dark"' \
  "${scratch}/WeaselDeployer/UIStyleSettings.cpp"
rg -Fq 'File "linnet-windows-manifest.json"' "${scratch}/output/install.nsi"
rg -Fq 'File /r "licenses\*.*"' "${scratch}/output/install.nsi"
rg -Fq 'File "data\*.db"' "${scratch}/output/install.nsi"
rg -Fq 'File "data\*.json"' "${scratch}/output/install.nsi"
rg -Fq 'File "data\opencc\*.txt"' "${scratch}/output/install.nsi"
rg -Fq 'File "data\dicts\*.yaml"' "${scratch}/output/install.nsi"
rg -Fq 'return deployment_succeeded ? 0 : 1;' \
  "${scratch}/WeaselDeployer/Configurator.cpp"
rg -Fq 'ExecWait '\''"$INSTDIR\WeaselDeployer.exe" /deploy'\'' $R3' \
  "${scratch}/output/install.nsi"
rg -Fq 'IntCmp $R3 0 deploy_done' "${scratch}/output/install.nsi"
rg -Fq 'ExecWait '\''"$INSTDIR\WeaselSetup.exe" $R2'\'' $R3' \
  "${scratch}/output/install.nsi"
rg -Fq 'SetErrorLevel $R3' "${scratch}/output/install.nsi"
rg -Fq 'L"%APPDATA%\\Linnet"' "${scratch}/WeaselSetup/WeaselSetup.cpp"
test "$(rg -F -c 'StrCpy $INSTDIR "$PROGRAMFILES64\Linnet"' \
  "${scratch}/output/install.nsi")" -eq 3
test "$(rg -F -c 'StrCpy $INSTDIR "$PROGRAMFILES\Linnet"' \
  "${scratch}/output/install.nsi")" -eq 2
if rg -Fq 'StrCpy $INSTDIR "$PROGRAMFILES64\Rime"' \
    "${scratch}/output/install.nsi" || \
   rg -Fq 'StrCpy $INSTDIR "$PROGRAMFILES\Rime"' \
    "${scratch}/output/install.nsi"; then
  echo "The Windows installer still shares upstream Rime's program directory." >&2
  exit 1
fi
rg -Fq 'old_frontend_removed:' "${scratch}/output/install.nsi"
rg -Fq 'uninstall_frontend_removed:' "${scratch}/output/install.nsi"
rg -Fq 'GetExitCodeProcess(shExInfo.hProcess, &exit_code)' \
  "${scratch}/WeaselSetup/imesetup.cpp"
rg -Fq 'if (ret == ERROR_SUCCESS)' "${scratch}/WeaselSetup/imesetup.cpp"
if rg -Fq 'if (ret = ERROR_SUCCESS)' "${scratch}/WeaselSetup/imesetup.cpp"; then
  echo "The legacy IME layout detector still assigns instead of comparing." >&2
  exit 1
fi
test "$(rg -F -c 'Delete  "$INSTDIR\licenses\*.*"' "${scratch}/output/install.nsi")" -eq 1
test "$(rg -F -c 'RMDir  "$INSTDIR\licenses"' "${scratch}/output/install.nsi")" -eq 1
test "$(rg -F -c 'Delete  "$INSTDIR\data\dicts\*.*"' "${scratch}/output/install.nsi")" -eq 1
ruby -e '
  source = File.binread(ARGV.fetch(0))
  prepare = source[/old_frontend_removed:(.*?)\ndone:/m]
  abort "upgrade preservation state is missing" unless prepare
  destructive = /\b(?:DeleteRegKey|DeleteRegValue|Delete|RMDir)\b/
  abort "upgrade destroys the prior package before commit" if prepare.match?(destructive)
  commit = source.index("deploy_done:") or abort "deployment commit state is missing"
  metadata = source.index(%(WriteRegStr HKLM "${REG_UNINST_KEY}" "DisplayName")) or
    abort "public install metadata owner is missing"
  abort "public install metadata precedes deployment commit" unless commit < metadata
' "${scratch}/output/install.nsi"

ruby -e '
  source = File.binread(ARGV.fetch(0))
  body = source[/int uninstall_ime_file\(.+?\n}\r?\n\r?\n/m]
  abort "TSF uninstall owner is missing" unless body
  redirect = body.index("Wow64DisableWow64FsRedirection")
  unregister = body.index("retval += func(imePath, false, true")
  abort "64-bit TSF unregister runs in the redirected 32-bit view" unless
    redirect && unregister && redirect < unregister
' "${scratch}/WeaselSetup/imesetup.cpp"

if rg -n 'win_sparkle_|check_update\(|L"/update"|rime-install\.bat' \
    "${scratch}/WeaselServer" "${scratch}/WeaselSetup" \
    "${scratch}/WeaselDeployer" "${scratch}/output/install.nsi"; then
  echo "An upstream updater or second data installer remains authoritative." >&2
  exit 1
fi
if rg -n 'Software\\\\Rime\\\\[Ww]easel|WeaselNamedPipe|rime\.weasel' \
    "${scratch}/RimeWithWeasel" "${scratch}/WeaselDeployer" \
    "${scratch}/WeaselServer" "${scratch}/WeaselSetup" \
    "${scratch}/WeaselTSF" "${scratch}/include"; then
  echo "An upstream Weasel identity namespace remains in the Linnet projection." >&2
  exit 1
fi
if rg -n 'WEASEL_WER_KEY|[Ww]easel-backup|[Ll]innet-backup|RIME_REG_KEY' \
    "${scratch}/WeaselSetup" "${scratch}/include" \
    "${scratch}/output/install.nsi"; then
  echo "A shared crash-dump, stale-data backup, or upstream registry owner remains." >&2
  exit 1
fi
rg -Fq 'LocalDumps\\LinnetServer.exe' "${scratch}/WeaselSetup/imesetup.cpp"
rg -Fq 'L"LinnetServer.exe"' "${scratch}/WeaselSetup/imesetup.cpp"
rg -Fq 'InstallAndRememberProfile' "${scratch}/WeaselSetup/WeaselSetup.cpp"
rg -Fq 'File /oname=LinnetServer.exe "WeaselServer.exe"' \
  "${scratch}/output/install.nsi"
rg -Fq 'Function CleanupFailedCandidate' "${scratch}/output/install.nsi"
rg -Fq 'Function RestorePriorFrontend' "${scratch}/output/install.nsi"
rg -Fq 'Function .onInstFailed' "${scratch}/output/install.nsi"
test "$(rg -F -c 'Call CleanupFailedCandidate' \
  "${scratch}/output/install.nsi")" -eq 4
rg -Fq 'Rename "$LinnetPriorRoot" "$LinnetRollbackRoot"' \
  "${scratch}/output/install.nsi"
rg -Fq 'Rename "$LinnetUserDataRoot\build" "$LinnetUserBuildRollback"' \
  "${scratch}/output/install.nsi"
rg -Fq 'Rename "$LinnetUserBuildRollback" "$LinnetUserDataRoot\build"' \
  "${scratch}/output/install.nsi"
rg -Fq 'ExecWait '\''"$LinnetPriorRoot\WeaselSetup.exe" /t'\'' $R5' \
  "${scratch}/output/install.nsi"
rg -Fq 'ExecWait '\''"$LinnetPriorRoot\WeaselSetup.exe" /s'\'' $R5' \
  "${scratch}/output/install.nsi"
test "$(rg -F -c 'SetErrorLevel 5' "${scratch}/output/install.nsi")" -eq 5
rg -Fq 'StrCpy $LinnetRollbackFailed 1' "${scratch}/output/install.nsi"
ruby -e '
  source = File.binread(ARGV.fetch(0))
  unregister = source[/old_server_stopped:(.*?)old_frontend_removed:/m] or
    abort "old frontend unregister failure state is missing"
  required = [
    %(StrCpy $R4 $R3),
    %(Call RestorePriorFrontend),
    %(Pop $R5),
    %(SetErrorLevel 5),
    %(unregister_failure_restored:),
    %(SetErrorLevel $R4),
  ]
  missing = required.reject { |line| unregister.include?(line) }
  abort "unregister failure bypasses prior frontend restoration: #{missing.join(", ")}" unless
    missing.empty?
  cleanup = source[/Function CleanupFailedCandidate(.*?)FunctionEnd/m] or
    abort "candidate cleanup owner is missing"
  abort "rollback restore failures can still report the original candidate error" unless
    cleanup.scan(%(StrCpy $LinnetRollbackFailed 1)).length == 3
' "${scratch}/output/install.nsi"
if rg -n '\$INSTDIR\\WeaselServer\.exe|\$R1\\WeaselServer\.exe' \
    "${scratch}/output/install.nsi"; then
  echo "The installed process identity still uses WeaselServer.exe." >&2
  exit 1
fi
if rg -n 'get_schemata_|IDC_GET_SCHEMATA' \
    "${scratch}/WeaselDeployer/SwitcherSettingsDialog.cpp" \
    "${scratch}/WeaselDeployer/SwitcherSettingsDialog.h" \
    "${scratch}/WeaselDeployer/resource.h"; then
  echo "The removed schema downloader retained dead source code." >&2
  exit 1
fi
if rg -n 'ID_WEASELTRAY_CHECKUPDATE' \
    "${scratch}/include/resource.h" "${scratch}/WeaselServer/resource.h"; then
  echo "The removed updater retained dead command identifiers." >&2
  exit 1
fi

rg -Fq 'set(plugin_modules "smart_english" PARENT_SCOPE)' \
  plugins/smart_english/CMakeLists.txt
rg -Fq '$env:RIME_PLUGINS = "lua octagram predict smart_english"' \
  platforms/windows/build.ps1
rg -Fq 'Copy-DataTree (Join-Path $DataRoot "plum")' \
  platforms/windows/prepare.ps1
rg -Fq 'Copy-Item -LiteralPath (Join-Path $RepoRoot "LICENSE.txt")' \
  platforms/windows/prepare.ps1
if rg -Fq 'Join-Path $RepoRoot "LICENSE")' platforms/windows/prepare.ps1; then
  echo "Windows packaging still references the nonexistent root LICENSE path." >&2
  exit 1
fi
rg -Fq '$Dirty = @(& git -C $Path status --porcelain --untracked-files=all)' \
  platforms/windows/prepare.ps1
if rg -n 'status --porcelain[^\r\n]*\)\.Trim\(\)' \
    platforms/windows/prepare.ps1; then
  echo "A clean upstream snapshot still becomes null before validation." >&2
  exit 1
fi
rg -Fq 'Copy-Item -LiteralPath $WeaselConfig' \
  platforms/windows/prepare.ps1
rg -Fq '"--directory=$Directory", $Patch' platforms/windows/prepare.ps1
rg -Fq '"--reverse", "--check"' platforms/windows/prepare.ps1
if rg -Fq 'Push-Location $Target' platforms/windows/prepare.ps1; then
  echo "Locked patches can silently miss the untracked Windows projection." >&2
  exit 1
fi
test "$(rg -F -c '$global:LASTEXITCODE = 0' \
  platforms/windows/prepare.ps1)" -eq 2
rg -Fq 'weasel_config_sha256 = $Prepared.weasel_config_sha256' \
  platforms/windows/build.ps1
if rg -n 'features\.json|portable_features|required_target_acceptance|data_owner|runtime_owner' \
    platforms/windows --glob '!verify.sh'; then
  echo "Windows retained a duplicate feature or acceptance ledger." >&2
  exit 1
fi
for feature_source in \
  data/plum/linnet.smart.db \
  data/plum/linnet_en.schema.yaml \
  data/plum/linnet_zh.schema.yaml \
  data/plum/radical_pinyin.schema.yaml \
  data/plum/wanxiang-lts-zh-hans.gram \
  data/opencc/emoji.json \
  data/opencc/s2t.json; do
  [[ -s "${feature_source}" ]] || {
    echo "Portable feature source is missing: ${feature_source}" >&2
    exit 1
  }
done
ruby -ryaml -e '
  root = ARGV.fetch(0)
  dictionary = YAML.safe_load(File.binread(File.join(root, "linnet_zh.dict.yaml")),
                              aliases: false)
  missing = dictionary.fetch("import_tables").each_with_object([]) do |table, result|
    if table.start_with?("dicts/")
      relative = "#{table}.dict.yaml"
      result << relative unless File.file?(File.join(root, relative))
    end
  end
  abort "Chinese dictionary imports missing tables: #{missing.join(", ")}" unless
    missing.empty?
' data/plum
ruby -rjson -e '
  root = ARGV.fetch(0)
  referenced = []
  walk = lambda do |value|
    case value
    when Hash
      referenced << value["file"] if value["file"].is_a?(String)
      value.each_value { |child| walk.call(child) }
    when Array
      value.each { |child| walk.call(child) }
    end
  end
  Dir.glob(File.join(root, "*.json")).sort.each do |path|
    walk.call(JSON.parse(File.binread(path)))
  end
  missing = referenced.uniq.reject { |name| File.file?(File.join(root, name)) }
  abort "OpenCC package references missing data: #{missing.join(", ")}" unless
    missing.empty?
' data/opencc
rg -Fq '"Weasel-GPL-3.0-only.txt"' platforms/windows/prepare.ps1
rg -Fq '(Join-Path $Projection "WeaselTSF\WeaselTSF.rc")' \
  platforms/windows/prepare.ps1
rg -Fq 'Remove-ResourceControl (Join-Path $Projection "WeaselDeployer\WeaselDeployer.rc")' \
  platforms/windows/prepare.ps1
rg -Fq '@("WeaselTSF\WeaselTSF.rc", "Weasel TSF", "Linnet TSF")' \
  platforms/windows/prepare.ps1
rg -Fq '@("WeaselServer\WeaselServer.rc", "Weasel Server", "Linnet Input Service")' \
  platforms/windows/prepare.ps1
rg -Fq 'VALUE "InternalName", "LinnetServer"' platforms/windows/prepare.ps1
rg -Fq 'VALUE "OriginalFilename", "LinnetServer.exe"' \
  platforms/windows/prepare.ps1
test "$(rg -F -c 'VALUE "CompanyName", "Linnet contributors"' \
  platforms/windows/prepare.ps1)" -eq 7
rg -Fq '@("WeaselDeployer\WeaselDeployer.rc", "Weasel Deployer", "Linnet Deployer")' \
  platforms/windows/prepare.ps1
rg -Fq '@("WeaselSetup\WeaselSetup.rc", "WeaselSetup Module", "Linnet Setup")' \
  platforms/windows/prepare.ps1
rg -Fq "Enable automatic update check', \"\")" \
  platforms/windows/prepare.ps1
rg -Fq 'upstream_updater = "disabled"' platforms/windows/build.ps1
rg -Fq '$WindowsSDK = "10.0.22621.0"' platforms/windows/build.ps1
rg -Fq 'set CMAKE_GENERATOR="Visual Studio 17 2022"' \
  platforms/windows/build.ps1
rg -Fq 'set "WindowsTargetPlatformVersion=$WindowsSDK"' \
  platforms/windows/build.ps1
rg -Fq -- '-DCMAKE_SYSTEM_VERSION:STRING=$WindowsSDK' \
  platforms/windows/build.ps1
test "$(rg -F -c '"/p:WindowsTargetPlatformVersion=$WindowsSDK"' \
  platforms/windows/build.ps1)" -eq 2
rg -Fq 'runtime-smoke.vcxproj' platforms/windows/build.ps1
rg -Fq '/p:Configuration=Release /p:Platform=Win32' platforms/windows/build.ps1
rg -Fq 'build.bat boost librime weasel installer arm64' platforms/windows/build.ps1
BUILD_BAT="${scratch}/build.bat" ruby -e '
  source = File.binread(ENV.fetch("BUILD_BAT"))
  %w[x64 Win32].each do |platform|
    call = /call :build_librime_platform #{platform} [^\r\n]+\r?\n  if errorlevel 1 goto error/
    abort "#{platform} librime failure can escape the parent build" unless
      source.match?(call)
  end
'
rg -Fq 'Boost-BSL-1.0.txt' platforms/windows/build.ps1
rg -Fq 'Darts-clone-BSD-3-Clause.txt' platforms/windows/prepare.ps1
rg -Fq 'platforms/windows/preflight.ps1' .github/workflows/windows-build.yml
ruby -e '
  workflow = File.binread(ARGV.fetch(0))
  canonical = workflow.index("git config --global core.autocrlf false") or abort
  hydrate = workflow.index("git submodule update --init --depth 1") or abort
  abort unless canonical < hydrate
' .github/workflows/windows-build.yml
if rg -n 'publish-windows:|Attach Windows installer|gh release upload.*[Ww]indows' \
    .github/workflows/release-ci.yml; then
  echo "An unsigned Windows candidate can still reach the public release." >&2
  exit 1
fi
rg -Fq 'needs: [prepare-community, build-windows]' \
  .github/workflows/release-ci.yml
if rg -Fq 'needs: publish-community' .github/workflows/release-ci.yml; then
  echo "Public release still precedes the Windows candidate gate." >&2
  exit 1
fi
rg -Fq 'ExpectComment(api, english, "cloud", "cloud", "klaʊd", "云")' \
  platforms/windows/runtime_smoke.cc
rg -Fq 'ExpectCandidate(api, reverse, "U4e2d", "中")' \
  platforms/windows/runtime_smoke.cc
rg -Fq 'ExpectCandidateContaining(api, pinyin, "nihao", "👋")' \
  platforms/windows/runtime_smoke.cc
rg -Fq 'ExpectPrediction(api, english);' platforms/windows/runtime_smoke.cc
rg -Fq '"linnet_zh_sogou", "linnet_zh_ziguang"' \
  platforms/windows/runtime_smoke.cc
if rg -n -- '-Wait -PassThru' platforms/windows/preflight.ps1; then
  echo "Windows preflight still waits for a persistent descendant process." >&2
  exit 1
fi
rg -Fq '$Process = Start-Process -FilePath $FilePath -ArgumentList $Arguments' \
  platforms/windows/preflight.ps1
rg -Fq '$Process.WaitForExit($TimeoutSeconds * 1000)' \
  platforms/windows/preflight.ps1
rg -Fq '"System32\taskkill.exe") `' platforms/windows/preflight.ps1
if rg -Fq '$Process.Kill($true)' platforms/windows/preflight.ps1; then
  echo "Windows preflight still requires the pwsh-only process-tree API." >&2
  exit 1
fi
rg -Fq 'Write-Host "Windows preflight: $Description"' \
  platforms/windows/preflight.ps1
test "$(rg -F -c -- '-TimeoutSeconds ' platforms/windows/preflight.ps1)" -eq 5
rg -Fq -- '-Description "Install Traditional Chinese candidate" -TimeoutSeconds 120' \
  platforms/windows/preflight.ps1
rg -Fq -- '-Description "Upgrade to Simplified Chinese candidate" -TimeoutSeconds 120' \
  platforms/windows/preflight.ps1
rg -Fq -- '-Description "Reject broken Simplified upgrade and restore prior candidate"' \
  platforms/windows/preflight.ps1
rg -Fq -- '-TimeoutSeconds 120 -ExpectedExitCode 1' platforms/windows/preflight.ps1
rg -Fq 'Assert-Absent "$InstallRoot.linnet-rollback"' \
  platforms/windows/preflight.ps1
rg -Fq 'Assert-File $PreservedUserData' platforms/windows/preflight.ps1
if rg -Fq -- '-Arguments @("/deploy")' platforms/windows/preflight.ps1; then
  echo "Windows preflight duplicates the installer's authoritative deployment." >&2
  exit 1
fi
if rg -Fq -- '-Arguments @("/quit")' platforms/windows/preflight.ps1; then
  echo "Windows preflight duplicates the upstream deploy/uninstall service lifecycle." >&2
  exit 1
fi
if rg -Fq 'Start-Process -FilePath $InstalledServer' platforms/windows/preflight.ps1; then
  echo "Windows preflight restarts the server outside the upstream lifecycle." >&2
  exit 1
fi
rg -Fq '$env:APPDATA = $TestAppData' platforms/windows/preflight.ps1
rg -Fq 'Invoke-RuntimeSmoke $InstalledProbe $InstallRoot' \
  platforms/windows/preflight.ps1
rg -Fq 'Get-LinnetInputMethodTipCount $HantInputMethodTip' \
  platforms/windows/preflight.ps1
rg -Fq 'Get-LinnetInputMethodTipCount $HansInputMethodTip' \
  platforms/windows/preflight.ps1
rg -Fq 'Assert-Absent (Join-Path $InstallRoot "data\build")' \
  platforms/windows/preflight.ps1
rg -Fq '<RuntimeLibrary>MultiThreaded</RuntimeLibrary>' \
  platforms/windows/runtime-smoke.vcxproj
rg -Fq -- '-Arguments @("/S") -Description "Uninstall candidate" -TimeoutSeconds 120' \
  platforms/windows/preflight.ps1

test "$(rg -l 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a' \
  .github/workflows/*.yml | wc -l | tr -d ' ')" -eq 4
test "$(rg -l 'actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c' \
  .github/workflows/*.yml | wc -l | tr -d ' ')" -eq 2
rg -Fq 'microsoft/setup-msbuild@30375c66a4eea26614e0d39710365f22f8b0af57' \
  .github/workflows/windows-build.yml
if rg -n 'actions/(upload|download)-artifact@(ea165f8|d3f86a)|setup-msbuild@6fb022' \
    .github/workflows; then
  echo "A Node 20 Windows CI action pin returned." >&2
  exit 1
fi

ruby -e '
  workflow = File.read(".github/workflows/windows-build.yml")
  step = workflow[/      - name: Verify candidate runtime and install lifecycle\n(.*?)(?=      - name:|      # This is)/m]
  abort "Windows preflight workflow step is missing" unless step
  abort "Windows preflight must use Windows PowerShell for the International module" unless
    step.include?("        shell: powershell\n")
  abort "Windows preflight still runs the incompatible pwsh host" if
    step.include?("        shell: pwsh\n")
'

if rg -n 'linnet\.\*\.old\.\*' platforms/windows/preflight.ps1; then
  echo "Windows preflight still rejects Weasel's scheduled-deletion contract." >&2
  exit 1
fi

ruby -e '
  files = File.binread(ARGV.fetch(0)).scan(/^diff --git a\/(\S+) b\//).flatten
  abort "Windows patch contains repeated incremental file diffs" unless
    files.length == files.uniq.length
' platforms/windows/patches/weasel-linnet.patch

if rg -n 'InputMethodKit|AppKit|SwiftUI|Keychain|iCloud|CloudKit' \
    platforms/windows scripts/project-windows-weasel-config \
    --glob '!verify.sh' --glob '!README.md'; then
  echo "A macOS-only capability crossed into the Windows distribution." >&2
  exit 1
fi

echo "windows structural verification: PASS"
