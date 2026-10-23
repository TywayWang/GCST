@echo off
setlocal
cd /d "%~dp0"

set "TARGET=All"
if not "%~1"=="" set "TARGET=%~1"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop.ps1" -Component %TARGET%

if "%~1"=="" (
    echo.
    pause
)
