$cwd = Get-Location
$build_dir = ".cmake"
$bin_dir = "bin"
$configuration = "Debug"
$generator = "Ninja Multi-Config"
$vendor_source = $null
$vendor_prebuilt_url = $null

$index = 0
while ($index -lt $args.Count) {
    switch ($args[$index]) {
        "-config" {
            if (($index + 1) -ge $args.Count -or $args[$index + 1].StartsWith("-")) {
                Write-Error "-config requires a value"
                exit 1
            }
            $configuration = $args[$index + 1]
            $index += 2
        }
        "-generator" {
            if (($index + 1) -ge $args.Count -or $args[$index + 1].StartsWith("-")) {
                Write-Error "-generator requires a value"
                exit 1
            }
            $generator = $args[$index + 1]
            $index += 2
        }
        "-vendors" {
            if (($index + 1) -ge $args.Count -or $args[$index + 1].StartsWith("-")) {
                $index += 1
            } else {
                $vendor_value = $args[$index + 1]
                switch ($vendor_value) {
                    "auto" {
                        $vendor_source = $null
                    }
                    "bundled" {
                        $vendor_source = "bundled"
                    }
                    default {
                        $vendor_prebuilt_url = $vendor_value
                    }
                }
                $index += 2
            }
        }
        default {
            Write-Error "Unknown option $($args[$index])"
            exit 1
        }
    }
}
$is_multi_config = $generator -match "Multi-Config|Visual Studio|Xcode"

try {
    # Create build folder if it doesn't exist
    if (-not (Test-Path -Path "$build_dir")) {
        New-Item -ItemType Directory -Path "$build_dir" | Out-Null
    }

    # Change directory to build
    Set-Location -Path "$build_dir"

    # Run CMake
    $cmake_opts = @(
        "-G", $generator,
        "-DPP_BUILD_USE_OPENSSL=ON",
        "-DPP_BUILD_USE_OPENVPN=ON",
        "-DPP_BUILD_USE_WIREGUARD=ON",
        "-DPP_BUILD_LIBRARY=ON"
    )
    if ($is_multi_config) {
        $cmake_opts += "-DCMAKE_CONFIGURATION_TYPES=$configuration"
    } else {
        $cmake_opts += "-DCMAKE_BUILD_TYPE=$configuration"
    }
    if ($vendor_source) {
        $cmake_opts += "-DPP_BUILD_VENDOR_SOURCE=$vendor_source"
    }
    if ($vendor_prebuilt_url) {
        $cmake_opts += "-DPP_BUILD_VENDOR_PREBUILT_URL=$vendor_prebuilt_url"
    }
    cmake @cmake_opts ..

    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    cmake --build . --config $configuration
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Set-Location -Path $cwd
}
