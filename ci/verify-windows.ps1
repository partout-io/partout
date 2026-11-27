param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $InstallDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RequiredCommandPath {
    param([Parameter(Mandatory = $true)][string] $Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "$Name not found on PATH"
    }
    return $command.Source
}

function Get-RequiredArtifact {
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $RelativePath
    )

    $path = Join-Path $Root $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing artifact: $path"
    }

    $item = Get-Item -LiteralPath $path
    if ($item.Length -le 0) {
        throw "Empty artifact: $path"
    }

    Write-Host "$RelativePath : $($item.Length) bytes"
    return $item.FullName
}

function Assert-X64Artifact {
    param(
        [Parameter(Mandatory = $true)][string] $Dumpbin,
        [Parameter(Mandatory = $true)][string] $Path
    )

    $headers = & $Dumpbin /headers $Path
    if ($LASTEXITCODE -ne 0) {
        throw "dumpbin failed for: $Path"
    }

    $headerText = $headers -join "`n"
    if ($headerText -notmatch "(?i)(8664 machine|machine \((x64|amd64)\))") {
        throw "Artifact is not x64: $Path"
    }
}

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
Set-Location $repoRoot

$installRoot = (Resolve-Path -LiteralPath $InstallDir).Path
$dumpbin = Get-RequiredCommandPath "dumpbin.exe"
Write-Host "Using dumpbin: $dumpbin"
Write-Host "Verifying install directory: $installRoot"

$exports = (& $dumpbin /exports (Join-Path $installRoot "bin\partout.dll")) -join "`n"
if ($LASTEXITCODE -ne 0) { throw "Cannot inspect DLL exports" }
$hasCHeader = Test-Path -LiteralPath (Join-Path $installRoot "include\partout.h")
if ($exports -match '\bpartout_version\b') {
    if (-not $hasCHeader) { throw "The Wintun SDK must install partout.h" }
    if ($exports -match '\s\?\S+') { throw "The Wintun DLL must not export C++ symbols" }
} else {
    if ($hasCHeader) { throw "The WinRT SDK must not install the internal C ABI header" }
    if ($exports -match '\s+partout_\w+') { throw "The WinRT DLL must not export C ABI symbols" }
    if ($exports -notmatch 'VpnChannelRuntime') { throw "Missing WinRT C++ runtime exports" }
}

$requiredArtifacts = @(
    "bin\partout.dll",
    "lib\partout.lib"
)
if (Test-Path -LiteralPath (Join-Path $installRoot "include\partout\models")) {
    $requiredArtifacts += "lib\partout-models.lib"
}

foreach ($artifact in $requiredArtifacts) {
    $path = Get-RequiredArtifact -Root $installRoot -RelativePath $artifact
    Assert-X64Artifact -Dumpbin $dumpbin -Path $path
}
