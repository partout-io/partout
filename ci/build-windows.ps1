Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Import-VsDevCmdEnvironment {
    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    if (-not $programFilesX86) {
        throw "ProgramFiles(x86) environment variable is not set"
    }

    $vsWhere = Join-Path $programFilesX86 "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vsWhere)) {
        throw "vswhere.exe not found: $vsWhere"
    }

    $vsRoot = & $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $vsRoot) {
        throw "Visual Studio with MSVC tools not found"
    }

    $vsDevCmd = Join-Path $vsRoot "Common7\Tools\VsDevCmd.bat"
    if (-not (Test-Path $vsDevCmd)) {
        throw "VsDevCmd.bat not found: $vsDevCmd"
    }

    cmd /s /c "`"$vsDevCmd`" -arch=amd64 -host_arch=amd64 >nul && set" | ForEach-Object {
        if ($_ -match "^(.*?)=(.*)$") {
            $name = $matches[1]
            if ($name -and -not $name.StartsWith("=")) {
                Set-Item -Path "Env:$name" -Value $matches[2]
            }
        }
    }
}

function Get-RequiredCommandPath {
    param([Parameter(Mandatory = $true)][string] $Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "$Name not found on PATH"
    }
    return $command.Source
}

function Write-Artifact {
    param([Parameter(Mandatory = $true)][string] $Path)

    $item = Get-Item $Path
    Write-Host "$Path : $($item.Length) bytes"
}

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent $scriptDir
Set-Location $repoRoot

Import-VsDevCmdEnvironment

$swiftExe = Get-RequiredCommandPath "swift.exe"
$toolchainBin = Split-Path $swiftExe -Parent
$usrDir = Split-Path $toolchainBin -Parent
$toolchainDir = Split-Path $usrDir -Parent
$toolchainsDir = Split-Path $toolchainDir -Parent
$swiftRoot = Split-Path $toolchainsDir -Parent

if (-not $env:SDKROOT -or -not (Test-Path $env:SDKROOT)) {
    $sdkPath = Get-ChildItem (Join-Path $swiftRoot "Platforms\*\Windows.platform\Developer\SDKs\Windows.sdk") -Directory | Select-Object -First 1
    if (-not $sdkPath) {
        throw "Windows.sdk not found under Swift install root: $swiftRoot"
    }
    $env:SDKROOT = $sdkPath.FullName
}

$targetInfo = swift -print-target-info | ConvertFrom-Json
$runtimePaths = @($targetInfo.paths.runtimeLibraryPaths | Where-Object { Test-Path $_ })
if ($runtimePaths.Count -eq 0) {
    throw "Swift runtime paths not found"
}

$env:PATH = "$toolchainBin;$($runtimePaths -join ';');$env:PATH"

$clangCl = Join-Path $toolchainBin "clang-cl.exe"
if (-not (Test-Path $clangCl)) {
    throw "clang-cl.exe not found: $clangCl"
}

$ninjaExe = Get-RequiredCommandPath "ninja.exe"
$linkExe = Get-RequiredCommandPath "link.exe"
$libExe = Get-RequiredCommandPath "lib.exe"

swift --version
cmake --version
ninja --version
& $clangCl --version

$buildDir = Join-Path $repoRoot ".cmake"
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null

$compilerWrapper = Join-Path $buildDir "clang-cl-wrapper.cmd"
$compilerWrapperContent = @"
@echo off
setlocal EnableDelayedExpansion
set "args="
:collect
if "%~1"=="" goto run
if "%~1"=="--" (
    set "args=!args! -Wno-error=unknown-argument -Wno-error /EHsc /std:c++17 --"
    shift
    goto collect_after_dash
)
set "args=!args! %1"
shift
goto collect
:collect_after_dash
if "%~1"=="" goto run
set "args=!args! %1"
shift
goto collect_after_dash
:run
"$clangCl" !args!
exit /b %ERRORLEVEL%
"@
Set-Content -Path $compilerWrapper -Value $compilerWrapperContent -Encoding Ascii

Push-Location $buildDir
try {
    cmake -G Ninja `
        -DCMAKE_MAKE_PROGRAM="$ninjaExe" `
        -DCMAKE_C_COMPILER="$compilerWrapper" `
        -DCMAKE_CXX_COMPILER="$compilerWrapper" `
        -DCMAKE_LINKER="$linkExe" `
        -DCMAKE_AR="$libExe" `
        -DCMAKE_SHARED_LINKER_FLAGS="-Xlinker /machine:x64" `
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY `
        -DPP_BUILD_USE_OPENSSL=OFF `
        -DPP_BUILD_USE_MBEDTLS=OFF `
        -DPP_BUILD_USE_OPENVPN=OFF `
        -DPP_BUILD_USE_WIREGUARD=OFF `
        -DPP_BUILD_LIBRARY=ON `
        -DPP_BUILD_STATIC=OFF `
        ..
    if ($LASTEXITCODE -ne 0) {
        throw "CMake configure failed"
    }

    cmake --build . --verbose
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed"
    }
} finally {
    Pop-Location
}

$requiredArtifacts = @(
    "bin\windows-amd64\partout\libpartout.dll",
    "bin\windows-amd64\partout\partout.lib"
)

foreach ($artifact in $requiredArtifacts) {
    if (-not (Test-Path $artifact)) {
        throw "Missing artifact: $artifact"
    }
    Write-Artifact $artifact
}

$optionalArtifacts = @(
    "bin\windows-amd64\partout\libpartout_c.lib"
)

foreach ($artifact in $optionalArtifacts) {
    if (Test-Path $artifact) {
        Write-Artifact $artifact
    }
}

dumpbin /headers "bin\windows-amd64\partout\libpartout.dll" | Select-String "machine"
dumpbin /headers "bin\windows-amd64\partout\partout.lib" | Select-String "machine"
