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

$requiredArtifacts = @(
    "bin\partout.dll",
    "bin\wintun.dll",
    "lib\partout.lib"
)

foreach ($artifact in $requiredArtifacts) {
    $path = Get-RequiredArtifact -Root $installRoot -RelativePath $artifact
    Assert-X64Artifact -Dumpbin $dumpbin -Path $path
}
