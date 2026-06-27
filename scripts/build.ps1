$cwd = Get-Location
$build_dir = ".cmake"
$bin_dir = "bin"
$vendor_source = $null
$vendor_prebuilt_url = $null

$index = 0
while ($index -lt $args.Count) {
    switch ($args[$index]) {
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

try {
    # Create build folder if it doesn't exist
    if (-not (Test-Path -Path "$build_dir")) {
        New-Item -ItemType Directory -Path "$build_dir" | Out-Null
    }

    # Change directory to build
    Set-Location -Path "$build_dir"

    # Run CMake
    $cmake_opts = @(
        "-G", "Ninja",
        "-DPP_BUILD_USE_OPENSSL=ON",
        "-DPP_BUILD_USE_OPENVPN=ON",
        "-DPP_BUILD_USE_WIREGUARD=ON",
        "-DPP_BUILD_LIBRARY=ON"
    )
    if ($vendor_source) {
        $cmake_opts += "-DPP_BUILD_VENDOR_SOURCE=$vendor_source"
    }
    if ($vendor_prebuilt_url) {
        $cmake_opts += "-DPP_BUILD_VENDOR_PREBUILT_URL=$vendor_prebuilt_url"
    }
    cmake @cmake_opts ..

    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    cmake --build .
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Set-Location -Path $cwd
}
