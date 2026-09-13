param(
  [Parameter(Mandatory = $true)][string]$SwiftRoot,
  [Parameter(Mandatory = $true)][string]$Projection
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Swift = (Get-Content -Raw (Join-Path $RepoRoot 'upstreams.lock.json') | ConvertFrom-Json).build_inputs.swift_windows
$Toolchains = @(Get-ChildItem -LiteralPath (Join-Path $SwiftRoot 'Toolchains') -Directory |
  Where-Object Name -EQ "$($Swift.version)+Asserts")
$Runtime = Join-Path $SwiftRoot "Runtimes\$($Swift.version)\usr\bin"
if ($Toolchains.Count -ne 1 -or -not (Test-Path -LiteralPath $Runtime -PathType Container)) {
  throw 'The locked Swift toolchain/runtime is not installed'
}
$CompilerBin = Join-Path $Toolchains[0].FullName 'usr\bin'
$Compiler = Join-Path $CompilerBin 'swiftc.exe'
$SwiftSDK = Join-Path $SwiftRoot "Platforms\$($Swift.version)\Windows.platform\Developer\SDKs\Windows.sdk"
$env:PATH = "$CompilerBin;$Runtime;$env:PATH"
$env:SDKROOT = $SwiftSDK
$Output = Join-Path $Projection 'output'
$Payload = Join-Path $Output 'swift-runtime'
New-Item -ItemType Directory -Force -Path $Payload | Out-Null
$Library = Join-Path $Payload 'LinnetSharedRuntime.dll'
# The authorized Swift SDK already includes zlib. Reuse that static library;
# only its matching upstream C headers/module map are needed by the importer.
$ZlibLibrary = Join-Path (Split-Path $SwiftSDK -Parent) $Swift.zlib.sdk_library
if (-not (Test-Path -LiteralPath $ZlibLibrary -PathType Leaf)) {
  throw 'The locked Swift x64 SDK zlib library is missing'
}
$ZlibModule = Join-Path $Projection 'swift-imports\zlib'
New-Item -ItemType Directory -Force -Path $ZlibModule | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'zlib.modulemap') `
  -Destination (Join-Path $ZlibModule 'module.modulemap')
foreach ($Header in $Swift.zlib.headers) {
  $Destination = Join-Path $ZlibModule $Header.name
  Invoke-WebRequest -Uri $Header.url -OutFile $Destination
  if ((Get-FileHash -Algorithm SHA256 $Destination).Hash.ToLowerInvariant() -ne $Header.sha256) {
    throw "Swift SDK zlib header differs from upstreams.lock.json: $($Header.name)"
  }
}
& $Compiler -v -continue-building-after-errors -swift-version 5 -O -emit-library -module-name LinnetSharedRuntime `
  -sdk $SwiftSDK -o $Library -I $ZlibModule `
  -import-objc-header (Join-Path $PSScriptRoot 'shared_runtime-bridging.h') `
  -Xlinker bcrypt.lib -Xlinker advapi32.lib -Xlinker ws2_32.lib -Xlinker $ZlibLibrary `
  -Xlinker "/IMPLIB:$(Join-Path $Projection 'lib64\LinnetSharedRuntime.lib')" `
  (Join-Path $RepoRoot 'sources\LinnetPackContract.swift') `
  (Join-Path $RepoRoot 'sources\LinnetDataChannel.swift') `
  (Join-Path $RepoRoot 'sources\LinnetDataRegistry.swift') `
  (Join-Path $RepoRoot 'sources\LinnetDataRegistryStorage.swift') `
  (Join-Path $RepoRoot 'sources\LinnetDataRegistryTransactions.swift') `
  (Join-Path $PSScriptRoot 'pack_file.swift') `
  (Join-Path $PSScriptRoot 'registry_storage.swift') `
  (Join-Path $PSScriptRoot 'registry_projection.swift') `
  (Join-Path $PSScriptRoot 'registry_factory.swift') `
  (Join-Path $PSScriptRoot 'input_policy.swift') `
  (Join-Path $RepoRoot 'sources\LinnetSettings\LinnetRimeSyncController.swift') `
  (Join-Path $RepoRoot 'sources\LinnetSettings\LinnetSettingsDownloadSource.swift') `
  (Join-Path $RepoRoot 'sources\LinnetSettings\LinnetSettingsExclusiveFileSink.swift') `
  (Join-Path $RepoRoot 'sources\LinnetSettings\LinnetSettingsDownloadTransport.swift') `
  (Join-Path $RepoRoot 'sources\LinnetSettings\LinnetLanguageDataUpdate.swift') `
  (Join-Path $PSScriptRoot 'data_update.swift') `
  (Join-Path $PSScriptRoot 'shared_runtime.swift') 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) {
  throw "Shared Windows Swift runtime compilation failed (native exit $LASTEXITCODE)"
}

# Package the actual PE dependency closure, not the compiler, SDK, testing
# libraries or unrelated DLLs from PATH. Standard OS DLLs remain OS-owned.
$VSWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$VisualStudio = (& $VSWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
$CRTVersion = Get-ChildItem -LiteralPath (Join-Path $VisualStudio 'VC\Redist\MSVC') -Directory |
  Where-Object Name -Match '^\d+\.\d+\.\d+$' | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
$CRT = Join-Path $CRTVersion.FullName 'x64\Microsoft.VC143.CRT'
$ReadObject = Join-Path $CompilerBin 'llvm-readobj.exe'
$Pending = [Collections.Generic.Queue[string]]::new()
$Pending.Enqueue($Library)
$Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$Seen.Add('LinnetSharedRuntime.dll') | Out-Null
while ($Pending.Count -gt 0) {
  $Binary = $Pending.Dequeue()
  $Imports = @(& $ReadObject --coff-imports $Binary)
  if ($LASTEXITCODE -ne 0) { throw "Cannot inspect DLL dependencies: $Binary" }
  foreach ($Line in $Imports) {
    if ($Line -notmatch '^\s*Name: (.+\.dll)\s*$') { continue }
    $Name = $Matches[1].Trim()
    if (-not $Seen.Add($Name)) { continue }
    $Source = Join-Path $Runtime $Name
    if ($Name -match '^(msvcp\d|vcruntime\d|concrt\d)') {
      $Source = Join-Path $CRT $Name
      if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required app-local VC runtime is missing: $Name"
      }
    }
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
      $Destination = Join-Path $Payload $Name
      Copy-Item -LiteralPath $Source -Destination $Destination
      $Pending.Enqueue($Destination)
    } elseif ($Name -notmatch '^(api-ms-|ext-ms-)' -and
        -not (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\$Name") -PathType Leaf)) {
      throw "Unresolved Swift runtime dependency: $Name"
    }
  }
}

foreach ($License in $Swift.licenses) {
  $Destination = Join-Path $Output "licenses\$($License.name)"
  Invoke-WebRequest -Uri $License.url -OutFile $Destination
  if ((Get-FileHash -Algorithm SHA256 $Destination).Hash.ToLowerInvariant() -ne $License.sha256) {
    throw "Swift license differs from upstreams.lock.json: $($License.name)"
  }
}
$Files = @(Get-ChildItem -LiteralPath $Payload -Filter '*.dll' -File | Sort-Object Name | ForEach-Object {
  [ordered]@{ name = $_.Name; sha256 = (Get-FileHash -Algorithm SHA256 $_.FullName).Hash.ToLowerInvariant() }
})
return [ordered]@{ version = $Swift.version; architecture = 'x64'; files = $Files }
