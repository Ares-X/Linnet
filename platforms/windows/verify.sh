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
test "$(rg -F -c 'Delete  "$R1\licenses\*.*"' "${scratch}/output/install.nsi")" -eq 1
test "$(rg -F -c 'RMDir  "$INSTDIR\licenses"' "${scratch}/output/install.nsi")" -eq 1
test "$(rg -F -c 'RMDir   "$R1\licenses"' "${scratch}/output/install.nsi")" -eq 1
test "$(rg -F -c 'Delete  "$INSTDIR\data\dicts\*.*"' "${scratch}/output/install.nsi")" -eq 1
test "$(rg -F -c 'Delete  "$R1\data\dicts\*.*"' "${scratch}/output/install.nsi")" -eq 1

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
rg -Fq 'Function .onInstFailed' "${scratch}/output/install.nsi"
test "$(rg -F -c 'Call CleanupFailedCandidate' \
  "${scratch}/output/install.nsi")" -eq 3
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
rg -Fq '"linnet_zh_sogou", "linnet_zh_ziguang"' \
  platforms/windows/runtime_smoke.cc
test "$(rg -F -c 'Invoke-CheckedProcess $Installer @("/S")' \
  platforms/windows/preflight.ps1)" -eq 1
rg -Fq 'Invoke-CheckedProcess $Installer @("/S", "/T")' \
  platforms/windows/preflight.ps1
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
rg -Fq 'Invoke-CheckedProcess (Join-Path $InstallRoot "uninstall.exe") @("/S")' \
  platforms/windows/preflight.ps1

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
