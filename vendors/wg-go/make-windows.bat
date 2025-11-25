@if "%PROCESSOR_ARCHITECTURE%"=="ARM64" set TARGET=aarch64-windows-gnu
@if "%PROCESSOR_ARCHITECTURE%"=="AMD64" set TARGET=x86_64-windows-gnu
@if not defined TARGET (
    echo Unsupported GOARCH=%GOARCH%
    exit /b 1
)
nmake /f Makefile.windows DESTDIR=%~1
