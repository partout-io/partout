@echo off
if "%PROCESSOR_ARCHITECTURE%"=="ARM64" set TARGET=aarch64-windows-gnu
if "%PROCESSOR_ARCHITECTURE%"=="AMD64" set TARGET=x86_64-windows-gnu
if not defined TARGET (
    echo Unsupported PROCESSOR_ARCHITECTURE=%PROCESSOR_ARCHITECTURE%
    exit /b 1
)
where zig >nul 2>nul
if errorlevel 1 (
    echo Zig is required
    exit /b 1
)
nmake /f Makefile.windows DESTDIR="%~1" TARGET=%TARGET% "CC=zig cc -fno-sanitize=undefined" "CXX=zig c++ -fno-sanitize=undefined"
