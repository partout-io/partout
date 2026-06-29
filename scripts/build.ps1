$ErrorActionPreference = "Stop"

$script_dir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$root_dir = Resolve-Path (Join-Path $script_dir "..")

Push-Location $root_dir
try {
    $build_dir = ".cmake"
    $bin_dir = "bin"
    $swift_version = "6.3.1"
    $vendor_source = $null
    $vendor_prebuilt_url = $null
    $crypto_selected = $false
    $crypto_openssl = $false
    $crypto_mbedtls = $false
    $do_build = $false
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

    function Get-SourceRelativePath($base_dir, $file) {
        $relative = $file.FullName.Substring($base_dir.Length).TrimStart([char[]]@("\", "/"))
        "./" + ($relative -replace "\\", "/")
    }

    function Update-CMakeFileList {
        $sources_dir = (Resolve-Path "Sources").Path
        $swift_files = Get-ChildItem -Path $sources_dir -Recurse -File |
            Where-Object { $_.Extension -eq ".swift" } |
            ForEach-Object { Get-SourceRelativePath $sources_dir $_ } |
            Sort-Object
        $c_files = Get-ChildItem -Path $sources_dir -Recurse -File |
            Where-Object { $_.Extension -eq ".c" -or $_.Extension -eq ".cc" } |
            ForEach-Object { Get-SourceRelativePath $sources_dir $_ } |
            Sort-Object

        $lines = @("set(PARTOUT_SOURCES")
        $lines += $swift_files
        $lines += ")"
        $lines += "set(PARTOUT_C_SOURCES"
        $lines += $c_files
        $lines += ")"
        Set-Content -Path (Join-Path $sources_dir "files.cmake") -Value $lines -Encoding ASCII
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
                $cmake_opts += "-DCMAKE_INSTALL_PREFIX=$install_dir"
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
            "-l" {
                $cmake_opts += "-DPP_BUILD_LIBRARY=ON"
                $do_build = $true
                $index += 1
            }
            "-android" {
                $build_dir = ".cmake-android"
                $cmake_opts += "-DCMAKE_ANDROID_NDK=$env:ANDROID_NDK_HOME"
                $cmake_opts += "-DANDROID_ABI=arm64-v8a"
                $cmake_opts += "-DANDROID_STL=c++_shared"
                $cmake_opts += "-DSWIFT_VERSION=$swift_version"
                $cmake_opts += "-DCMAKE_TOOLCHAIN_FILE=cmake/swift/swift-android.toolchain.cmake"
                $index += 1
            }
            "-vendors" {
                if (($index + 1) -ge $args.Count -or $args[$index + 1].StartsWith("-")) {
                    $index += 1
                } else {
                    switch ($args[$index + 1]) {
                        "auto" {
                            $vendor_source = $null
                            $vendor_prebuilt_url = $null
                        }
                        "bundled" {
                            $vendor_source = "bundled"
                            $vendor_prebuilt_url = $null
                        }
                        default {
                            $vendor_source = $null
                            $vendor_prebuilt_url = $args[$index + 1]
                        }
                    }
                    $index += 2
                }
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

    if ($vendor_source) {
        $cmake_opts += "-DPP_BUILD_VENDOR_SOURCE=$vendor_source"
    }
    if ($vendor_prebuilt_url) {
        $cmake_opts += "-DPP_BUILD_VENDOR_PREBUILT_URL=$vendor_prebuilt_url"
    } elseif ($env:PP_BUILD_VENDOR_PREBUILT_URL) {
        $cmake_opts += "-DPP_BUILD_VENDOR_PREBUILT_URL=$env:PP_BUILD_VENDOR_PREBUILT_URL"
    }

    if (-not (Test-Path -Path $build_dir)) {
        New-Item -ItemType Directory -Path $build_dir | Out-Null
    }
    if (-not (Test-Path -Path $bin_dir)) {
        New-Item -ItemType Directory -Path $bin_dir | Out-Null
    }

    if ($gen_build) {
        Update-CMakeFileList
        $configure_args = @("-G", "Ninja", "-S", ".", "-B", $build_dir) + $cmake_opts
        & cmake @configure_args
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    if ($do_build) {
        & cmake --build $build_dir
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        if ($install_dir) {
            & cmake --install $build_dir
            if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        }
    }
} finally {
    Pop-Location
}
