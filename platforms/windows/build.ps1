param(
  [Parameter(Mandatory = $true)]
  [string]$BoostRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Projection = Join-Path $RepoRoot "build\windows\weasel"
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot "build\windows\prepared.json") -PathType Leaf)) {
  throw "Run platforms/windows/prepare.ps1 first"
}
$BoostRoot = (Resolve-Path -LiteralPath $BoostRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $BoostRoot "boost") -PathType Container)) {
  throw "BOOST_ROOT does not contain Boost headers"
}

$ProductConfig = Get-Content -LiteralPath (Join-Path $RepoRoot "config\LinnetProduct.xcconfig")
$Version = (($ProductConfig | Select-String '^MARKETING_VERSION = ([^ ]+)$').Matches.Groups[1].Value)
$Build = (($ProductConfig | Select-String '^CURRENT_PROJECT_VERSION = ([^ ]+)$').Matches.Groups[1].Value)
$VersionParts = $Version.Split('.')
if ($VersionParts.Count -ne 3 -or -not $Build) {
  throw "Invalid canonical Linnet product version"
}

$Prepared = Get-Content -Raw -LiteralPath `
  (Join-Path $RepoRoot "build\windows\prepared.json") | ConvertFrom-Json
$Lock = Get-Content -Raw -LiteralPath `
  (Join-Path $RepoRoot "upstreams.lock.json") | ConvertFrom-Json
$Manifest = [ordered]@{
  format = 1
  product = "Linnet"
  platform = "windows"
  version = $Version
  build = $Build
  frontend = [ordered]@{ name = "Weasel"; commit = $Prepared.weasel_commit }
  runtime = [ordered]@{ name = "librime"; commit = $Prepared.librime_commit }
  weasel_config_sha256 = $Prepared.weasel_config_sha256
  upstream_updater = "disabled"
}
$Manifest | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 `
  -LiteralPath (Join-Path $Projection "output\linnet-windows-manifest.json")

$EnvFile = @"
@echo off
set "WEASEL_ROOT=$Projection"
set "BOOST_ROOT=$BoostRoot"
set "BJAM_TOOLSET=msvc-14.3"
set "CMAKE_GENERATOR=Visual Studio 17 2022"
set "PLATFORM_TOOLSET=v143"
"@
[IO.File]::WriteAllText((Join-Path $Projection "env.bat"), $EnvFile, [Text.Encoding]::ASCII)

$env:WEASEL_ROOT = $Projection
$env:BOOST_ROOT = $BoostRoot
$env:VERSION_MAJOR = $VersionParts[0]
$env:VERSION_MINOR = $VersionParts[1]
$env:VERSION_PATCH = $VersionParts[2]
$env:WEASEL_VERSION = $Version
$env:WEASEL_BUILD = $Build
$env:FILE_VERSION = "$Version.$Build"
$env:RELEASE_BUILD = "1"
$env:LINNET_DATA_READY = "1"
$env:RIME_PLUGINS = "lua octagram predict smart_english"
$env:common_cmake_flags = "-DBUILD_MERGED_PLUGINS:BOOL=ON -DBUILD_TOOLS:BOOL=OFF"

$BoostLicense = Join-Path $BoostRoot $Lock.build_inputs.boost_headers.license_path
$BoostLicenseDigest = (Get-FileHash -Algorithm SHA256 -LiteralPath $BoostLicense).Hash.ToLowerInvariant()
if ($BoostLicenseDigest -ne $Lock.build_inputs.boost_headers.license_sha256) {
  throw "Boost license differs from upstreams.lock.json"
}
Copy-Item -LiteralPath $BoostLicense -Destination `
  (Join-Path $Projection "output\licenses\Boost-BSL-1.0.txt")

Push-Location $Projection
try {
  & cmd.exe /d /c "build.bat boost librime weasel installer arm64"
  if ($LASTEXITCODE -ne 0) {
    throw "Windows build failed with exit code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}

& msbuild.exe (Join-Path $PSScriptRoot "runtime-smoke.vcxproj") `
  /m /nologo /verbosity:minimal `
  /p:Configuration=Release /p:Platform=x64 `
  "/p:ProjectionRoot=$Projection"
if ($LASTEXITCODE -ne 0) {
  throw "Windows runtime smoke probe compilation failed with exit code $LASTEXITCODE"
}

& msbuild.exe (Join-Path $PSScriptRoot "runtime-smoke.vcxproj") `
  /m /nologo /verbosity:minimal `
  /p:Configuration=Release /p:Platform=Win32 `
  "/p:ProjectionRoot=$Projection"
if ($LASTEXITCODE -ne 0) {
  throw "Windows Win32 runtime smoke probe compilation failed with exit code $LASTEXITCODE"
}

$Installer = Join-Path $Projection "output\archives\Linnet-Windows-$Version.$Build-installer.exe"
foreach ($Artifact in @(
  $Installer,
  (Join-Path $Projection "output\rime.dll"),
  (Join-Path $Projection "output\Win32\rime.dll"),
  (Join-Path $Projection "output\weaselx64.dll"),
  (Join-Path $Projection "output\weaselARM.dll"),
  (Join-Path $Projection "output\weaselARM64.dll"),
  (Join-Path $Projection "output\weaselARM64X.dll"),
  (Join-Path $Projection "output\weaselARM.ime"),
  (Join-Path $Projection "output\weaselARM64.ime"),
  (Join-Path $Projection "output\weaselARM64X.ime"),
  (Join-Path $Projection "output\WeaselServer.exe"),
  (Join-Path $Projection "output\Win32\WeaselServer.exe"),
  (Join-Path $Projection "output\LinnetRuntimeSmoke.exe"),
  (Join-Path $Projection "output\Win32\LinnetRuntimeSmoke.exe")
)) {
  if (-not (Test-Path -LiteralPath $Artifact -PathType Leaf)) {
    throw "Expected Windows artifact is missing: $Artifact"
  }
}
if (Get-ChildItem -LiteralPath (Join-Path $Projection "output\archives") `
    -Filter '*weasel*installer.exe') {
  throw "Upstream-branded installer escaped the Linnet release projection"
}
Write-Host "Windows installer: $Installer"
