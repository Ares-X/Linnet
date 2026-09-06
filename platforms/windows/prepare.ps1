param(
  [Parameter(Mandatory = $true)]
  [string]$DataRoot,
  [Parameter(Mandatory = $true)]
  [string]$EmbeddedLuaHeader,
  [Parameter(Mandatory = $true)]
  [string]$WeaselConfig,
  [Parameter(Mandatory = $true)]
  [string]$ThemePreviewRoot,
  [Parameter(Mandatory = $true)]
  [string]$InputPolicyRoot,
  [string]$BuildRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$LockPath = Join-Path $RepoRoot "upstreams.lock.json"
$Lock = Get-Content -Raw -LiteralPath $LockPath | ConvertFrom-Json
if (-not $BuildRoot) {
  $BuildRoot = Join-Path $RepoRoot "build\windows"
}
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$ExpectedBuildRoot = [IO.Path]::GetFullPath((Join-Path $RepoRoot "build\windows"))
if ($BuildRoot -ne $ExpectedBuildRoot) {
  throw "Windows preparation may only replace $ExpectedBuildRoot"
}

function Invoke-Native {
  param([string]$File, [string[]]$Arguments)
  & $File @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$File failed with exit code $LASTEXITCODE"
  }
}

function Assert-GitSnapshot {
  param([string]$Path, [string]$Commit, [string]$Tree = "")
  if (-not (Test-Path -LiteralPath (Join-Path $Path ".git"))) {
    throw "Missing initialized snapshot: $Path"
  }
  $ActualCommit = (& git -C $Path rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0 -or $ActualCommit -ne $Commit) {
    throw "Unexpected commit in $Path"
  }
  if ($Tree) {
    $ActualTree = (& git -C $Path rev-parse "HEAD^{tree}").Trim()
    if ($LASTEXITCODE -ne 0 -or $ActualTree -ne $Tree) {
      throw "Unexpected tree in $Path"
    }
  }
  $Dirty = @(& git -C $Path status --porcelain --untracked-files=all)
  if ($LASTEXITCODE -ne 0 -or $Dirty.Count -ne 0) {
    throw "Refusing dirty upstream snapshot: $Path"
  }
}

function Copy-Tree {
  param([string]$Source, [string]$Destination)
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  & robocopy $Source $Destination /MIR /NFL /NDL /NJH /NJS /NP `
    /XD .git build debug dist msbuild `
    /XF .git env.bat
  if ($LASTEXITCODE -gt 7) {
    throw "robocopy failed for $Source"
  }
  $global:LASTEXITCODE = 0
}

function Copy-DataTree {
  param([string]$Source, [string]$Destination)
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  & robocopy $Source $Destination /MIR /NFL /NDL /NJH /NJS /NP
  if ($LASTEXITCODE -gt 7) {
    throw "robocopy failed for staged data $Source"
  }
  $global:LASTEXITCODE = 0
}

function Export-LockedGitCommit {
  param(
    [string]$Name,
    [string]$Repository,
    [string]$Commit,
    [string]$Destination
  )
  $Cache = Join-Path $BuildRoot "source-cache\$Name"
  New-Item -ItemType Directory -Force -Path $Cache | Out-Null
  Invoke-Native git @("-C", $Cache, "init", "--quiet")
  Invoke-Native git @("-C", $Cache, "remote", "add", "origin", $Repository)
  Invoke-Native git @("-C", $Cache, "fetch", "--quiet", "--depth", "1", "origin", $Commit)
  $Archive = Join-Path $BuildRoot "$Name.tar"
  Invoke-Native git @("-C", $Cache, "archive", "--format=tar", "-o", $Archive, $Commit)
  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  Invoke-Native tar @("-xf", $Archive, "-C", $Destination)
  Remove-Item -LiteralPath $Archive
}

function Apply-LockedPatch {
  param([string]$Target, [string]$RelativePath, [string]$Sha256)
  $Patch = Join-Path $RepoRoot $RelativePath
  $Actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Patch).Hash.ToLowerInvariant()
  if ($Actual -ne $Sha256) {
    throw "Locked patch digest differs: $RelativePath (expected=$Sha256 actual=$Actual)"
  }
  $Target = [IO.Path]::GetFullPath($Target)
  $Directory = [IO.Path]::GetRelativePath($RepoRoot, $Target).Replace('\', '/')
  if ([IO.Path]::IsPathRooted($Directory) -or $Directory -eq '..' -or `
      $Directory.StartsWith('../')) {
    throw "Locked patch target escapes the repository: $Target"
  }
  Invoke-Native git @("-C", $RepoRoot, "apply", "--check", "--ignore-space-change", `
    "--directory=$Directory", $Patch)
  Invoke-Native git @("-C", $RepoRoot, "apply", "--ignore-space-change", `
    "--directory=$Directory", $Patch)
  Invoke-Native git @("-C", $RepoRoot, "apply", "--reverse", "--check", `
    "--ignore-space-change", "--directory=$Directory", $Patch)
}

function Replace-RequiredText {
  param(
    [string]$Path,
    [string]$Before,
    [string]$After,
    [Text.Encoding]$Encoding
  )
  $Text = [IO.File]::ReadAllText($Path, $Encoding)
  if (-not $Text.Contains($Before)) {
    throw "Expected upstream resource text is missing in $Path"
  }
  [IO.File]::WriteAllText($Path, $Text.Replace($Before, $After), $Encoding)
}

function Remove-UpdaterMenuItem {
  param([string]$Path, [string]$Label, [Text.Encoding]$Encoding)
  $Text = [IO.File]::ReadAllText($Path, $Encoding)
  $Pattern = '(?m)^[^\S\r\n]*MENUITEM\s+"' + [Regex]::Escape($Label) + `
    '",\s+ID_WEASELTRAY_CHECKUPDATE\r?$'
  $Updated = [Regex]::Replace($Text, $Pattern, '')
  if ($Updated -eq $Text) {
    throw "Expected updater menu item is missing in $Path"
  }
  [IO.File]::WriteAllText($Path, $Updated, $Encoding)
}

function Remove-ResourceControl {
  param([string]$Path, [string]$ControlId, [Text.Encoding]$Encoding)
  $Text = [IO.File]::ReadAllText($Path, $Encoding)
  $Pattern = '(?m)^[^\r\n]*' + [Regex]::Escape($ControlId) + '[^\r\n]*\r?$'
  $Matches = [Regex]::Matches($Text, $Pattern)
  if ($Matches.Count -ne 3) {
    throw "Expected three localized $ControlId controls in $Path"
  }
  [IO.File]::WriteAllText($Path, [Regex]::Replace($Text, $Pattern, ''), $Encoding)
}

$WeaselSource = Join-Path $RepoRoot $Lock.sources.weasel.submodule_path
$LibrimeSource = Join-Path $RepoRoot $Lock.sources.librime.submodule_path
Assert-GitSnapshot $WeaselSource $Lock.sources.weasel.commit $Lock.sources.weasel.tree
Assert-GitSnapshot $LibrimeSource $Lock.sources.librime.commit
$NestedStatus = & git -C $LibrimeSource submodule status --recursive
if ($LASTEXITCODE -ne 0 -or ($NestedStatus | Where-Object { $_ -match '^[-+U]' })) {
  throw "librime nested dependencies are not at their pinned gitlinks"
}

$DataRoot = (Resolve-Path -LiteralPath $DataRoot).Path
$EmbeddedLuaHeader = (Resolve-Path -LiteralPath $EmbeddedLuaHeader).Path
$WeaselConfig = (Resolve-Path -LiteralPath $WeaselConfig).Path
$ThemePreviewRoot = (Resolve-Path -LiteralPath $ThemePreviewRoot).Path
$InputPolicyRoot = (Resolve-Path -LiteralPath $InputPolicyRoot).Path
$ExpectedThemePreviews = @(
  "color_scheme_linnet_clay_light.png",
  "color_scheme_linnet_glass_light.png",
  "color_scheme_linnet_ink_cinnabar_light.png",
  "color_scheme_linnet_mist_jade_light.png",
  "color_scheme_linnet_moon_jade_light.png",
  "color_scheme_linnet_paper_light.png",
  "color_scheme_linnet_sidecar_light.png"
)
$ActualThemePreviews = @(Get-ChildItem -LiteralPath $ThemePreviewRoot -File |
  Select-Object -ExpandProperty Name | Sort-Object)
if (Compare-Object $ExpectedThemePreviews $ActualThemePreviews) {
  throw "Generated Windows theme preview catalog is not exact"
}
foreach ($RequiredData in @(
  "default.yaml",
  "dicts/cuoyin.dict.yaml",
  "dicts/diming.dict.yaml",
  "dicts/duoyin.dict.yaml",
  "dicts/fangyan.dict.yaml",
  "dicts/huaxue.dict.yaml",
  "dicts/jichu.dict.yaml",
  "dicts/lianxiang.dict.yaml",
  "dicts/mingren.dict.yaml",
  "dicts/renming.dict.yaml",
  "dicts/shici.dict.yaml",
  "dicts/taifeng.dict.yaml",
  "dicts/wuzhong.dict.yaml",
  "dicts/yaopin.dict.yaml",
  "dicts/yiren.dict.yaml",
  "dicts/yixue.dict.yaml",
  "dicts/zi.dict.yaml",
  "dicts/ext.dict.yaml",
  "linnet.english-data-manifest.json",
  "linnet.smart.db",
  "linnet_algebra.yaml",
  "linnet_en.dict.yaml",
  "linnet_english_entities.dict.yaml",
  "linnet_en.schema.yaml",
  "linnet_grammar_active.yaml",
  "linnet_reviewed.dict.yaml",
  "linnet_user.yaml",
  "linnet_zh.dict.yaml",
  "linnet_zh.schema.yaml",
  "linnet_zh_abc.schema.yaml",
  "linnet_zh_flypy.schema.yaml",
  "linnet_zh_jiajia.schema.yaml",
  "linnet_zh_mspy.schema.yaml",
  "linnet_zh_pinyin.schema.yaml",
  "linnet_zh_sogou.schema.yaml",
  "linnet_zh_ziguang.schema.yaml",
  "radical_pinyin.dict.yaml",
  "radical_pinyin.schema.yaml",
  "symbols_caps_v.yaml",
  "symbols_v.yaml",
  "wanxiang-lts-zh-hans.gram",
  "zh-hans-t-essay-bgw.gram"
)) {
  if (-not (Test-Path -LiteralPath (Join-Path $DataRoot "plum\$RequiredData") -PathType Leaf)) {
    throw "Canonical staged Linnet data is incomplete: $RequiredData"
  }
}
foreach ($RequiredOpenCC in @(
  "emoji.json", "emoji.txt", "others.txt", "s2t.json", "t2s.json",
  "STCharacters.ocd2", "STPhrases.ocd2",
  "TSCharacters.ocd2", "TSPhrases.ocd2"
)) {
  if (-not (Test-Path -LiteralPath (Join-Path $DataRoot "opencc\$RequiredOpenCC") -PathType Leaf)) {
    throw "Canonical staged OpenCC data is incomplete: $RequiredOpenCC"
  }
}

if (Test-Path -LiteralPath $BuildRoot) {
  Remove-Item -LiteralPath $BuildRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
$Projection = Join-Path $BuildRoot "weasel"
$Runtime = Join-Path $Projection "librime"
Copy-Tree $WeaselSource $Projection
Copy-Tree $LibrimeSource $Runtime

$Plugins = $Lock.sources.librime.bundled_plugins
foreach ($Name in @("lua", "octagram", "predict")) {
  $Plugin = $Plugins.$Name
  Export-LockedGitCommit "plugin-$Name" $Plugin.repository $Plugin.commit `
    (Join-Path $Runtime "plugins\$($Plugin.source_dir)")
}
$LuaThirdparty = $Plugins.lua.thirdparty
Export-LockedGitCommit "plugin-lua-thirdparty" $LuaThirdparty.repository `
  $LuaThirdparty.commit (Join-Path $Runtime "plugins\lua\$($LuaThirdparty.source_dir)")

Apply-LockedPatch $Runtime `
  $Lock.downstream_patches.librime_core_interactions.path `
  $Lock.downstream_patches.librime_core_interactions.sha256
Apply-LockedPatch (Join-Path $Runtime "plugins\lua") `
  $Lock.downstream_patches.librime_lua_state_lifetime.path `
  $Lock.downstream_patches.librime_lua_state_lifetime.sha256
Apply-LockedPatch (Join-Path $Runtime "plugins\predict") `
  $Lock.downstream_patches.librime_predict_session_state.path `
  $Lock.downstream_patches.librime_predict_session_state.sha256

Copy-Tree (Join-Path $RepoRoot "plugins\smart_english") `
  (Join-Path $Runtime "plugins\smart_english")
Copy-Item -LiteralPath $EmbeddedLuaHeader `
  -Destination (Join-Path $Runtime "plugins\lua\src\linnet_embedded_lua.h")
$PredictPublic = Join-Path $Runtime "src\rime\predict"
New-Item -ItemType Directory -Force -Path $PredictPublic | Out-Null
Copy-Item -LiteralPath (Join-Path $Runtime "plugins\predict\src\predict_engine.h") `
  -Destination $PredictPublic
Copy-Item -LiteralPath (Join-Path $Runtime "plugins\predict\src\predict_db.h") `
  -Destination $PredictPublic

Apply-LockedPatch $Projection `
  $Lock.downstream_patches.weasel_linnet_windows_projection.path `
  $Lock.downstream_patches.weasel_linnet_windows_projection.sha256

$Utf16 = [Text.UnicodeEncoding]::new($false, $true)
$UpdaterResources = @(
  (Join-Path $Projection "WeaselServer\WeaselServer.rc"),
  (Join-Path $Projection "WeaselTSF\WeaselTSF.rc")
)
foreach ($Resource in $UpdaterResources) {
  foreach ($UpdateLabel in @("检查新版本 (&U)", "檢查新版本 (&U)", "Check for updates (&U)")) {
    Remove-UpdaterMenuItem $Resource $UpdateLabel $Utf16
  }
}
Remove-ResourceControl (Join-Path $Projection "WeaselDeployer\WeaselDeployer.rc") `
  "IDC_GET_SCHEMATA" $Utf16
foreach ($Resource in @(
  "WeaselIME\WeaselIME.rc",
  "WeaselTSF\WeaselTSF.rc",
  "WeaselServer\WeaselServer.rc",
  "WeaselDeployer\WeaselDeployer.rc",
  "WeaselSetup\WeaselSetup.rc"
)) {
  Replace-RequiredText (Join-Path $Projection $Resource) "小狼毫" "Linnet" $Utf16
}
foreach ($Resource in @(
  "WeaselIME\WeaselIME.rc",
  "WeaselTSF\WeaselTSF.rc",
  "WeaselServer\WeaselServer.rc",
  "WeaselDeployer\WeaselDeployer.rc",
  "WeaselSetup\WeaselSetup.rc"
)) {
  $Path = Join-Path $Projection $Resource
  $Text = [IO.File]::ReadAllText($Path, $Utf16)
  $Text = $Text.Replace('VALUE "ProductName", "Weasel"', 'VALUE "ProductName", "Linnet"')
  [IO.File]::WriteAllText($Path, $Text, $Utf16)
}
foreach ($Replacement in @(
  @("WeaselIME\WeaselIME.rc", 'VALUE "CompanyName", "式恕堂"', 'VALUE "CompanyName", "Linnet contributors"'),
  @("WeaselTSF\WeaselTSF.rc", 'VALUE "CompanyName", "式恕堂"', 'VALUE "CompanyName", "Linnet contributors"'),
  @("WeaselTSF\WeaselTSF.rc", 'VALUE "CompanyName", "Shishutang"', 'VALUE "CompanyName", "Linnet contributors"'),
  @("WeaselServer\WeaselServer.rc", 'VALUE "CompanyName", "式恕堂"', 'VALUE "CompanyName", "Linnet contributors"'),
  @("WeaselServer\WeaselServer.rc", 'VALUE "CompanyName", "Shishutang"', 'VALUE "CompanyName", "Linnet contributors"'),
  @("WeaselServer\WeaselServer.rc", 'VALUE "InternalName", "WeaselServer"', 'VALUE "InternalName", "LinnetServer"'),
  @("WeaselServer\WeaselServer.rc", 'VALUE "OriginalFilename", "WeaselServer.exe"', 'VALUE "OriginalFilename", "LinnetServer.exe"'),
  @("WeaselDeployer\WeaselDeployer.rc", 'VALUE "CompanyName", "式恕堂"', 'VALUE "CompanyName", "Linnet contributors"'),
  @("WeaselDeployer\WeaselDeployer.rc", 'VALUE "CompanyName", "Shishutang"', 'VALUE "CompanyName", "Linnet contributors"'),
  @("WeaselTSF\WeaselTSF.rc", "Weasel TSF", "Linnet TSF"),
  @("WeaselServer\WeaselServer.rc", "Weasel Server", "Linnet Input Service"),
  @("WeaselDeployer\WeaselDeployer.rc", "Weasel Deployer", "Linnet Deployer"),
  @("WeaselDeployer\WeaselDeployer.rc", "Install Weasel", "Install Linnet"),
  @("WeaselDeployer\WeaselDeployer.rc", '"Weasel is not used in this way."', '"Linnet is not used in this way."'),
  @("WeaselDeployer\WeaselDeployer.rc", '"Weasel"', '"Linnet"'),
  @("WeaselSetup\WeaselSetup.rc", "WeaselSetup Module", "Linnet Setup"),
  @("WeaselSetup\WeaselSetup.rc", "Uninstall Weasel", "Uninstall Linnet"),
  @("WeaselSetup\WeaselSetup.rc", "Install Weasel", "Install Linnet"),
  @("WeaselSetup\WeaselSetup.rc", "Set Weasel language", "Set Linnet language"),
  @("WeaselSetup\WeaselSetup.rc", '\n/eu  - 启用自动检查更新', ""),
  @("WeaselSetup\WeaselSetup.rc", '\n/du  - 禁用自动检查更新', ""),
  @("WeaselSetup\WeaselSetup.rc", '\n/testing  - 设置更新通道为测试版', ""),
  @("WeaselSetup\WeaselSetup.rc", '\n/release  - 设置更新通道为正式版', ""),
  @("WeaselSetup\WeaselSetup.rc", '\n/eu  - 啟用自動檢查更新', ""),
  @("WeaselSetup\WeaselSetup.rc", '\n/du  - 禁用自動檢查更新', ""),
  @("WeaselSetup\WeaselSetup.rc", '\n/testing  - 設定更新通道為測試版', ""),
  @("WeaselSetup\WeaselSetup.rc", '\n/release  - 設定更新通道為正式版', ""),
  @("WeaselSetup\WeaselSetup.rc", '\n/eu - Enable automatic update check', ""),
  @("WeaselSetup\WeaselSetup.rc", '\n/du - Disable automatic update check', ""),
  @("WeaselSetup\WeaselSetup.rc", '\n/testing - Set update channel to testing', ""),
  @("WeaselSetup\WeaselSetup.rc", '\n/release - Set update channel to release', "")
)) {
  Replace-RequiredText (Join-Path $Projection $Replacement[0]) `
    $Replacement[1] $Replacement[2] $Utf16
}

$OutputData = Join-Path $Projection "output\data"
Copy-DataTree (Join-Path $DataRoot "plum") $OutputData
Copy-DataTree (Join-Path $DataRoot "opencc") (Join-Path $OutputData "opencc")
Copy-Item -LiteralPath $WeaselConfig -Destination (Join-Path $OutputData "weasel.yaml")
foreach ($Policy in @("linnet_windows_defaults.yaml", "linnet_grammar_active.yaml")) {
  Copy-Item -LiteralPath (Join-Path $InputPolicyRoot $Policy) -Destination $OutputData
}
# The compact grammar is only a developer fixture, not a product model.
Remove-Item -LiteralPath (Join-Path $OutputData "zh-hans-t-essay-bgw.gram")
# Rime applies the shared Core defaults before the user's default.custom.yaml.
# The Swift renderer owns these policies; this boundary only adds its include.
Add-Content -LiteralPath (Join-Path $OutputData "default.yaml") -Encoding UTF8 `
  -Value "`n__patch: linnet_windows_defaults:/patch"
Copy-DataTree $ThemePreviewRoot (Join-Path $OutputData "preview")
Copy-Item -LiteralPath (Join-Path $RepoRoot "LICENSE.txt") `
  -Destination (Join-Path $Projection "output\LICENSE.txt")
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "README.md") `
  -Destination (Join-Path $Projection "output\README.txt")
Copy-DataTree (Join-Path $RepoRoot "LICENSES") `
  (Join-Path $Projection "output\licenses")
$RuntimeLicenses = Join-Path $Projection "output\licenses"
$PluginLocks = $Lock.sources.librime.bundled_plugins
$DependencyLocks = $Lock.sources.librime.static_dependencies
$LicenseProjection = @(
  @{ Name = "Weasel-GPL-3.0-only.txt"; Source = (Join-Path $WeaselSource "LICENSE.txt"); Sha256 = $Lock.sources.weasel.license_sha256 },
  @{ Name = "librime-BSD-3-Clause.txt"; Source = (Join-Path $Runtime "LICENSE"); Sha256 = $Lock.sources.librime.license_sha256 },
  @{ Name = "librime-lua-BSD-3-Clause.txt"; Source = (Join-Path $Runtime "plugins\lua\LICENSE"); Sha256 = $PluginLocks.lua.license_sha256 },
  @{ Name = "librime-octagram-GPL-3.0-only.txt"; Source = (Join-Path $Runtime "plugins\octagram\LICENSE"); Sha256 = $PluginLocks.octagram.license_sha256 },
  @{ Name = "librime-predict-BSD-3-Clause.txt"; Source = (Join-Path $Runtime "plugins\predict\LICENSE"); Sha256 = $PluginLocks.predict.license_sha256 },
  @{ Name = "glog-BSD-3-Clause.txt"; Source = (Join-Path $Runtime "deps\glog\COPYING"); Sha256 = $DependencyLocks.glog.license_sha256 },
  @{ Name = "leveldb-BSD-3-Clause.txt"; Source = (Join-Path $Runtime "deps\leveldb\LICENSE"); Sha256 = $DependencyLocks.leveldb.license_sha256 },
  @{ Name = "marisa-trie-BSD-2-Clause.txt"; Source = (Join-Path $Runtime "deps\marisa-trie\COPYING.md"); Sha256 = $DependencyLocks.'marisa-trie'.license_sha256 },
  @{ Name = "OpenCC-Apache-2.0.txt"; Source = (Join-Path $Runtime "deps\opencc\LICENSE"); Sha256 = $DependencyLocks.opencc.license_sha256 },
  @{ Name = "yaml-cpp-MIT.txt"; Source = (Join-Path $Runtime "deps\yaml-cpp\LICENSE"); Sha256 = $DependencyLocks.'yaml-cpp'.license_sha256 },
  @{ Name = "Darts-clone-BSD-3-Clause.txt"; Source = (Join-Path $Runtime $Lock.sources.librime.embedded_components.darts_clone.license_path); Sha256 = $Lock.sources.librime.embedded_components.darts_clone.license_sha256 }
)
foreach ($License in $LicenseProjection) {
  $ActualLicenseDigest = (Get-FileHash -Algorithm SHA256 -LiteralPath $License.Source).Hash.ToLowerInvariant()
  if ($ActualLicenseDigest -ne $License.Sha256) {
    throw "Locked license differs: $($License.Name)"
  }
  Copy-Item -LiteralPath $License.Source `
    -Destination (Join-Path $RuntimeLicenses $License.Name)
}

$Marker = @{
  weasel_commit = $Lock.sources.weasel.commit
  librime_commit = $Lock.sources.librime.commit
  weasel_config_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $WeaselConfig).Hash.ToLowerInvariant()
} | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $BuildRoot "prepared.json"), $Marker)
Write-Host "Prepared root-owned Linnet runtime/data with the locked Weasel frontend."
