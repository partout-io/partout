$cwd = Get-Location
$build_dir = ".cmake"
$bin_dir = "bin"

try {
    # Remove all .txt files in the build folder
    Remove-Item -Path "$build_dir\*.txt" -ErrorAction SilentlyContinue

    # Create build folder if it doesn't exist
    if (-not (Test-Path -Path "$build_dir")) {
        New-Item -ItemType Directory -Path "$build_dir" | Out-Null
    }

    # Change directory to build
    Set-Location -Path "$build_dir"

    # Run CMake
    #cmake -G "Visual Studio 17 2022" -DPP_BUILD_USE_OPENSSL=ON -DPP_BUILD_USE_WGGO=ON -DPP_BUILD_LIBRARY=ON ..
    cmake -G "Ninja" -DPP_BUILD_USE_OPENSSL=ON -DPP_BUILD_USE_WGGO=ON -DPP_BUILD_LIBRARY=ON ..

    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    cmake --build .
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Set-Location -Path $cwd
}
