$cwd = Get-Location
$build_dir = ".cmake"
$bin_dir = ".bin"

try {
    # Remove all .txt files in the build folder
    Remove-Item -Path "$build_dir\*.txt" -ErrorAction SilentlyContinue

    # Create build folder if it doesn't exist
    if (-not (Test-Path -Path "$build_dir")) {
        New-Item -ItemType Directory -Path "$build_dir" | Out-Null
    }

    # Change directory to build and remove PartoutProject* folders/files
    Set-Location -Path "$build_dir"
    Get-ChildItem -Path "PartoutProject*" -Recurse -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # Run CMake with ninja for Swift
    cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -DPP_BUILD_USE_OPENSSL=ON -DPP_BUILD_LIBRARY=ON ..

    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    cmake --build .
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Set-Location -Path $cwd
}
