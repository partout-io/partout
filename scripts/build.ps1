$ErrorActionPreference = "Stop"

$script_dir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$root_dir = Resolve-Path (Join-Path $script_dir "..")

function Show-CommonHelp {
    foreach ($line in Get-Content -Path (Join-Path $script_dir "build-help.txt")) {
        Write-Host $line
    }
}

function Show-Help {
    @"
Usage: scripts/build.ps1 [options]

Options:
"@ | Write-Host
    Show-CommonHelp
}

if ($args -contains "-h" -or $args -contains "--help") {
    Show-Help
    exit 0
}

Push-Location $root_dir
try {
    $build_dir = ".cmake"
    $bin_dir = "bin"
    $configuration = "Release"
    $generator = "Ninja Multi-Config"
    $vendor_prebuilt_url = $null
    $crypto_selected = $false
    $crypto_openssl = $false
    $crypto_mbedtls = $false
    $do_build = $args.Count -eq 0
    $gen_build = $false
    $install_dir = $null
    $positional_args = @()
    $cmake_opts = @()

    function ConvertTo-CMakeBool($value) {
        if ($value) { "ON" } else { "OFF" }
    }

    function Require-Value($option, $index, $all_args) {
        if (($index + 1) -ge $all_args.Count -or $all_args[$index + 1].StartsWith("-")) {
            Write-Error "$option requires a value"
            exit 1
        }
        $all_args[$index + 1]
    }

    function Add-Crypto($value) {
        $script:crypto_selected = $true
        $script:do_build = $true
        foreach ($crypto in $value.Split(",")) {
            $crypto = $crypto.Trim()
            switch ($crypto) {
                "openssl" {
                    $script:crypto_openssl = $true
                }
                "native" {
                    $script:crypto_mbedtls = $true
                }
                "" {
                    Write-Error "Empty crypto in '$value'"
                    exit 1
                }
                default {
                    Write-Error "Unknown crypto '$crypto'"
                    exit 1
                }
            }
        }
    }

    $index = 0
    while ($index -lt $args.Count) {
        switch ($args[$index]) {
            "-clean" {
                Remove-Item -Path $build_dir, $bin_dir -Recurse -Force -ErrorAction SilentlyContinue
                $index += 1
            }
            "-gen" {
                $do_build = $true
                $gen_build = $true
                $index += 1
            }
            "-install" {
                $install_dir = Require-Value "-install" $index $args
                New-Item -ItemType Directory -Path $install_dir -Force | Out-Null
                $cmake_opts += "-DPP_BUILD_PREFIX=$install_dir"
                $do_build = $true
                $index += 2
            }
            "-crypto" {
                Add-Crypto (Require-Value "-crypto" $index $args)
                $index += 2
            }
            "-openvpn" {
                $cmake_opts += "-DPP_BUILD_USE_OPENVPN=ON"
                $do_build = $true
                $index += 1
            }
            "-wireguard" {
                $cmake_opts += "-DPP_BUILD_USE_WIREGUARD=ON"
                $do_build = $true
                $index += 1
            }
            "-android" {
                $build_dir = ".cmake-android"
                $cmake_opts += "-DCMAKE_TOOLCHAIN_FILE=${env:ANDROID_NDK_HOME}/build/cmake/android.toolchain.cmake"
                $cmake_opts += "-DANDROID_PLATFORM=android-24"
                $cmake_opts += "-DANDROID_ABI=arm64-v8a"
                $index += 1
            }
            "-vendors" {
                $vendor_prebuilt_url = Require-Value "-vendors" $index $args
                $index += 2
            }
            "-gen-models" {
                Write-Error "-gen-models is not supported by build.ps1"
                exit 1
            }
            "-config" {
                Write-Error "-config is not supported by build.ps1"
                exit 1
            }
            "-a" {
                Write-Error "-a has been removed"
                exit 1
            }
            default {
                if ($args[$index].StartsWith("-")) {
                    Write-Error "Unknown option $($args[$index])"
                    exit 1
                }
                $positional_args += $args[$index]
                $index += 1
            }
        }
    }

    if ($crypto_selected) {
        $cmake_opts += "-DPP_BUILD_USE_OPENSSL=$(ConvertTo-CMakeBool $crypto_openssl)"
        $cmake_opts += "-DPP_BUILD_USE_MBEDTLS=$(ConvertTo-CMakeBool $crypto_mbedtls)"
    }

    if ($vendor_prebuilt_url) {
        $cmake_opts += "-DPP_BUILD_VENDOR_PREBUILT_URL=$vendor_prebuilt_url"
    }

    if ($gen_build) {
        if (-not (Test-Path -Path $build_dir)) {
            New-Item -ItemType Directory -Path $build_dir | Out-Null
        }
        $configure_args = @("-G", $generator, "-S", ".", "-B", $build_dir) + $cmake_opts
        & cmake @configure_args
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } elseif ($do_build -and -not (Test-Path -Path (Join-Path $build_dir "CMakeCache.txt") -PathType Leaf)) {
        Write-Error "Build directory is not configured; run scripts/build.ps1 -gen first"
        exit 1
    }

    if ($do_build) {
        & cmake --build $build_dir --config $configuration
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
} finally {
    Pop-Location
}
