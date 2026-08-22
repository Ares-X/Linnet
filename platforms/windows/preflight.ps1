Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Projection = Join-Path $RepoRoot "build\windows\weasel"
$Output = Join-Path $Projection "output"
$ProductConfig = Get-Content -LiteralPath (Join-Path $RepoRoot "config\LinnetProduct.xcconfig")
$Version = (($ProductConfig | Select-String '^MARKETING_VERSION = ([^ ]+)$').Matches.Groups[1].Value)
$Build = (($ProductConfig | Select-String '^CURRENT_PROJECT_VERSION = ([^ ]+)$').Matches.Groups[1].Value)
$Installer = Join-Path $Output "archives\Linnet-Windows-$Version.$Build-installer.exe"
$Smoke = Join-Path $Output "LinnetRuntimeSmoke.exe"
$Win32Smoke = Join-Path $Output "Win32\LinnetRuntimeSmoke.exe"
$SharedData = Join-Path $Output "data"
$Lock = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "upstreams.lock.json") |
  ConvertFrom-Json
$TemporaryRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$TestRoot = Join-Path $TemporaryRoot `
  ("linnet-windows-preflight-" + [Guid]::NewGuid().ToString("N"))
$SmokeUser = Join-Path $TestRoot "candidate-smoke"
$TestAppData = Join-Path $TestRoot "appdata"
$UserData = Join-Path $TestAppData "Linnet"
$Clsid = "{660F0020-8849-43B3-8FB0-806CF516F3B0}"
$Profile = "{EE2C8B48-FE3C-441F-AB71-D94B8E63573E}"
$HansInputMethodTip = "0804:$Clsid$Profile"
$HantInputMethodTip = "0404:$Clsid$Profile"
$WerPath = "Software\Microsoft\Windows\Windows Error Reporting\LocalDumps\LinnetServer.exe"
$Installed = $false
$InstallRoot = $null

function Get-RegistryValue {
  param(
    [Microsoft.Win32.RegistryHive]$Hive,
    [Microsoft.Win32.RegistryView]$View,
    [string]$Path,
    [string]$Name
  )
  $Base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)
  try {
    $Key = $Base.OpenSubKey($Path)
    if ($null -eq $Key) { return $null }
    try {
      return $Key.GetValue(
        $Name,
        $null,
        [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
      )
    } finally {
      $Key.Dispose()
    }
  } finally {
    $Base.Dispose()
  }
}

function Test-RegistryKey {
  param(
    [Microsoft.Win32.RegistryHive]$Hive,
    [Microsoft.Win32.RegistryView]$View,
    [string]$Path
  )
  $Base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $View)
  try {
    $Key = $Base.OpenSubKey($Path)
    if ($null -eq $Key) { return $false }
    $Key.Dispose()
    return $true
  } finally {
    $Base.Dispose()
  }
}

function Assert-File {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Required installed file is missing: $Path"
  }
}

function Assert-Absent {
  param([string]$Path)
  if (Test-Path -LiteralPath $Path) {
    throw "Forbidden or unremoved path remains: $Path"
  }
}

function Get-LinnetInputMethodTipCount {
  param([string]$ExpectedInputMethodTip)
  $Count = 0
  foreach ($Language in @(Get-WinUserLanguageList)) {
    $Count += @($Language.InputMethodTips | Where-Object {
      $_ -eq $ExpectedInputMethodTip
    }).Count
  }
  return $Count
}

function Invoke-CheckedProcess {
  param([string]$FilePath, [string[]]$Arguments)
  $Process = Start-Process -FilePath $FilePath -ArgumentList $Arguments `
    -Wait -PassThru
  if ($Process.ExitCode -ne 0) {
    throw "$FilePath failed with exit code $($Process.ExitCode)"
  }
}

function Invoke-RuntimeSmoke {
  param(
    [string]$Probe,
    [string]$RuntimeRoot,
    [string]$SharedDataRoot,
    [string]$UserDataRoot,
    [string]$FailureMessage
  )
  $PreviousPath = $env:PATH
  $env:PATH = "$RuntimeRoot;$PreviousPath"
  try {
    & $Probe $SharedDataRoot $UserDataRoot
    if ($LASTEXITCODE -ne 0) {
      throw $FailureMessage
    }
  } finally {
    $env:PATH = $PreviousPath
  }
}

function Wait-ForServer {
  param([string]$ExpectedPath)
  for ($Attempt = 0; $Attempt -lt 40; $Attempt++) {
    $Found = Get-Process -Name "LinnetServer" -ErrorAction SilentlyContinue |
      Where-Object {
        try { [IO.Path]::GetFullPath($_.Path) -eq [IO.Path]::GetFullPath($ExpectedPath) }
        catch { $false }
      }
    if ($Found) { return }
    Start-Sleep -Milliseconds 500
  }
  throw "Installed Linnet input service did not stay running"
}

function Wait-ForServerExit {
  param([string]$ExpectedPath)
  for ($Attempt = 0; $Attempt -lt 40; $Attempt++) {
    $Found = Get-Process -Name "LinnetServer" -ErrorAction SilentlyContinue |
      Where-Object {
        try { [IO.Path]::GetFullPath($_.Path) -eq [IO.Path]::GetFullPath($ExpectedPath) }
        catch { $false }
      }
    if (-not $Found) { return }
    Start-Sleep -Milliseconds 500
  }
  throw "Installed Linnet input service did not stop"
}

foreach ($Required in @(
  $Installer,
  $Smoke,
  $Win32Smoke,
  (Join-Path $Output "rime.dll"),
  (Join-Path $Output "Win32\rime.dll")
)) {
  Assert-File $Required
}
if (Test-RegistryKey LocalMachine Registry32 "Software\Linnet") {
  throw "Windows preflight requires a runner without an existing Linnet installation"
}
if (Get-Process -Name "LinnetServer" -ErrorAction SilentlyContinue) {
  throw "Windows preflight requires no live Linnet input service"
}

New-Item -ItemType Directory -Path $SmokeUser -Force | Out-Null
New-Item -ItemType Directory -Path $TestAppData -Force | Out-Null
$OldAppData = $env:APPDATA
try {
  $env:APPDATA = $TestAppData
  Invoke-RuntimeSmoke $Win32Smoke (Join-Path $Output "Win32") $SharedData $SmokeUser `
    "Built Windows Win32 rime.dll failed candidate black-box verification"

  try {
    Invoke-CheckedProcess $Installer @("/S", "/T")
    $Installed = $true

  $InstallDir = Get-RegistryValue LocalMachine Registry32 `
    "Software\Linnet" "InstallDir"
  $InstallRoot = Get-RegistryValue LocalMachine Registry32 `
    "Software\Linnet" "WeaselRoot"
  if (-not $InstallDir -or -not $InstallRoot) {
    throw "Installer did not publish canonical Linnet install paths"
  }
  $ExpectedRoot = Join-Path $InstallDir "Linnet-$Version"
  if ([IO.Path]::GetFullPath($InstallRoot) -ne [IO.Path]::GetFullPath($ExpectedRoot)) {
    throw "Installed version root differs from the canonical registry contract"
  }

  foreach ($RelativePath in @(
    "linnet-windows-manifest.json",
    "rime.dll",
    "weasel.dll",
    "weaselx64.dll",
    "WeaselDeployer.exe",
    "LinnetServer.exe",
    "WeaselSetup.exe",
    "uninstall.exe",
    "data\default.yaml",
    "data\dicts\jichu.dict.yaml",
    "data\linnet.smart.db",
    "data\linnet.english-data-manifest.json",
    "data\linnet_en.schema.yaml",
    "data\linnet_zh_pinyin.schema.yaml",
    "data\radical_pinyin.schema.yaml",
    "data\opencc\s2t.json",
    "data\opencc\t2s.json",
    "data\opencc\emoji.json",
    "data\opencc\emoji.txt",
    "data\opencc\others.txt",
    "licenses\Weasel-GPL-3.0-only.txt",
    "licenses\librime-BSD-3-Clause.txt",
    "licenses\Boost-BSL-1.0.txt",
    "licenses\Darts-clone-BSD-3-Clause.txt"
  )) {
    Assert-File (Join-Path $InstallRoot $RelativePath)
  }
  foreach ($Forbidden in @("WinSparkle.dll", "curl.exe", "rime-install.bat")) {
    Assert-Absent (Join-Path $InstallRoot $Forbidden)
  }
  Assert-Absent (Join-Path $InstallRoot "data\build")
  $Previews = @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot "data\preview") `
    -Filter "color_scheme_linnet_*_light.png" -File)
  if ($Previews.Count -ne 7) {
    throw "Installed Linnet theme preview catalog is incomplete"
  }

  $Manifest = Get-Content -Raw -LiteralPath `
    (Join-Path $InstallRoot "linnet-windows-manifest.json") | ConvertFrom-Json
  $InstalledConfigDigest = (Get-FileHash -Algorithm SHA256 -LiteralPath `
    (Join-Path $InstallRoot "data\weasel.yaml")).Hash.ToLowerInvariant()
  if ($Manifest.product -ne "Linnet" -or $Manifest.platform -ne "windows" -or
      $Manifest.version -ne $Version -or $Manifest.build -ne $Build -or
      $Manifest.frontend.commit -ne $Lock.sources.weasel.commit -or
      $Manifest.runtime.commit -ne $Lock.sources.librime.commit -or
      $Manifest.weasel_config_sha256 -ne $InstalledConfigDigest -or
      $Manifest.upstream_updater -ne "disabled") {
    throw "Installed Windows manifest differs from the built candidate"
  }

  $UninstallDisplay = Get-RegistryValue LocalMachine Registry32 `
    "Software\Microsoft\Windows\CurrentVersion\Uninstall\Linnet" "DisplayName"
  if (-not $UninstallDisplay -or $UninstallDisplay -notlike "Linnet*") {
    throw "Linnet uninstall registration is missing"
  }
  $Autorun = Get-RegistryValue LocalMachine Registry64 `
    "Software\Microsoft\Windows\CurrentVersion\Run" "LinnetServer"
  if (-not $Autorun -or $Autorun -notlike "*$InstallRoot*") {
    throw "Linnet service startup registration is missing"
  }
  if (Test-RegistryKey LocalMachine Registry32 "Software\Rime\Weasel") {
    throw "Installer wrote into upstream Weasel's registry owner"
  }
  $DumpFolder = Get-RegistryValue LocalMachine Registry64 $WerPath "DumpFolder"
  if (-not $DumpFolder -or $DumpFolder -notlike "*rime.linnet*") {
    throw "Linnet crash-dump diagnostics are not registered"
  }

  $ClsidPath = "Software\Classes\CLSID\$Clsid\InprocServer32"
  foreach ($View in @(
    [Microsoft.Win32.RegistryView]::Registry32,
    [Microsoft.Win32.RegistryView]::Registry64
  )) {
    $Inproc = Get-RegistryValue LocalMachine $View $ClsidPath ""
    if (-not $Inproc -or [IO.Path]::GetFileName($Inproc) -ne "linnet.dll") {
      throw "Linnet TSF CLSID is missing from $View"
    }
    Assert-File $Inproc
  }
  $ProfilePath = "Software\Microsoft\CTF\TIP\$Clsid\LanguageProfile\0x00000404\$Profile"
  if (-not (Test-RegistryKey LocalMachine Registry32 $ProfilePath) -and
      -not (Test-RegistryKey LocalMachine Registry64 $ProfilePath)) {
    throw "Linnet Traditional Chinese TSF profile is missing"
  }
  if ((Get-LinnetInputMethodTipCount $HantInputMethodTip) -ne 1 -or
      (Get-LinnetInputMethodTipCount $HansInputMethodTip) -ne 0) {
    throw "Linnet Traditional Chinese TSF profile is not uniquely enabled"
  }

  Assert-File (Join-Path $env:windir "System32\linnet.dll")
  Assert-File (Join-Path $env:windir "SysWOW64\linnet.dll")
  $InstalledServer = Join-Path $InstallRoot "LinnetServer.exe"
  Wait-ForServer $InstalledServer
  $ObsoleteSharedData = Join-Path $InstallRoot "data\obsolete-preflight.yaml"
  $PreservedUserData = Join-Path $UserData "preserved-preflight.txt"
  Set-Content -LiteralPath $ObsoleteSharedData -Value "obsolete package data"
  Set-Content -LiteralPath $PreservedUserData -Value "preserve user data"
  Invoke-CheckedProcess $Installer @("/S")
  Assert-Absent $ObsoleteSharedData
  Assert-File $PreservedUserData
  $HansProfilePath = "Software\Microsoft\CTF\TIP\$Clsid\LanguageProfile\0x00000804\$Profile"
  if (-not (Test-RegistryKey LocalMachine Registry32 $HansProfilePath) -and
      -not (Test-RegistryKey LocalMachine Registry64 $HansProfilePath)) {
    throw "Linnet Simplified Chinese TSF profile is missing after upgrade"
  }
  if ((Get-LinnetInputMethodTipCount $HansInputMethodTip) -ne 1 -or
      (Get-LinnetInputMethodTipCount $HantInputMethodTip) -ne 0) {
    throw "Linnet upgrade did not migrate uniquely to the Simplified Chinese TSF profile"
  }
  Wait-ForServer $InstalledServer
  Invoke-CheckedProcess $InstalledServer @("/quit")
  Wait-ForServerExit $InstalledServer
  Invoke-CheckedProcess (Join-Path $InstallRoot "WeaselDeployer.exe") @("/deploy")
  foreach ($Deployed in @(
    "build\default.yaml",
    "build\linnet_en.schema.yaml",
    "build\linnet_zh_pinyin.schema.yaml",
    "build\linnet_en.table.bin",
    "build\linnet_zh.table.bin"
  )) {
    Assert-File (Join-Path $UserData $Deployed)
  }
  $InstalledProbe = Join-Path $TestRoot "LinnetInstalledRuntimeSmoke.exe"
  Copy-Item -LiteralPath $Smoke -Destination $InstalledProbe
  Invoke-RuntimeSmoke $InstalledProbe $InstallRoot `
    (Join-Path $InstallRoot "data") $UserData `
    "Installed Linnet data failed Windows-generated dictionary verification"
  Start-Process -FilePath $InstalledServer
  Wait-ForServer $InstalledServer

  Invoke-CheckedProcess (Join-Path $InstallRoot "uninstall.exe") @("/S")
  for ($Attempt = 0; $Attempt -lt 40 -and (Test-Path -LiteralPath $InstallRoot); $Attempt++) {
    Start-Sleep -Milliseconds 500
  }
  Assert-Absent $InstallRoot
  Assert-Absent (Join-Path $env:windir "System32\linnet.dll")
  Assert-Absent (Join-Path $env:windir "SysWOW64\linnet.dll")
  if (Test-RegistryKey LocalMachine Registry32 "Software\Linnet") {
    throw "Linnet registry root remained after uninstall"
  }
  if (Test-RegistryKey LocalMachine Registry32 `
      "Software\Microsoft\Windows\CurrentVersion\Uninstall\Linnet") {
    throw "Linnet uninstall registration remained after uninstall"
  }
  if (Get-RegistryValue LocalMachine Registry64 `
      "Software\Microsoft\Windows\CurrentVersion\Run" "LinnetServer") {
    throw "Linnet service startup registration remained after uninstall"
  }
  if (Test-RegistryKey LocalMachine Registry64 $WerPath) {
    throw "Linnet crash-dump registration remained after uninstall"
  }
  foreach ($View in @(
    [Microsoft.Win32.RegistryView]::Registry32,
    [Microsoft.Win32.RegistryView]::Registry64
  )) {
    if (Test-RegistryKey LocalMachine $View $ClsidPath) {
      throw "Linnet TSF CLSID remained in $View after uninstall"
    }
  }
  if ((Get-LinnetInputMethodTipCount $HansInputMethodTip) -ne 0 -or
      (Get-LinnetInputMethodTipCount $HantInputMethodTip) -ne 0) {
    throw "Linnet TSF profile remained in the current user's language list"
  }
  if (-not (Test-Path -LiteralPath $UserData -PathType Container)) {
    throw "Uninstall unexpectedly deleted the user's isolated Linnet data"
  }
  $Installed = $false
  } finally {
    if ($Installed -and $InstallRoot -and
        (Test-Path -LiteralPath (Join-Path $InstallRoot "uninstall.exe") -PathType Leaf)) {
      try {
        Invoke-CheckedProcess (Join-Path $InstallRoot "uninstall.exe") @("/S")
      } catch {
        Write-Warning "Emergency CI cleanup could not uninstall Linnet: $_"
      }
    }
  }
} finally {
  $env:APPDATA = $OldAppData
  if (Test-Path -LiteralPath $TestRoot) {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force
  }
}

Write-Host "Windows candidate runtime/install lifecycle: PASS"
