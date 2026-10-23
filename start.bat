@echo off
setlocal enabledelayedexpansion
title GCST Suite Launcher
cd /d "%~dp0"

if not "%~1"=="" (
    if /i "%~1"=="all" goto :LAUNCH_ALL
    if /i "%~1"=="gc" goto :LAUNCH_GC
    if /i "%~1"=="st" goto :LAUNCH_ST
    if /i "%~1"=="stop" goto :STOP_ALL
    echo [!] Unknown option: %~1
    echo Usage: start.bat [all ^| gc ^| st ^| stop]
    pause
    exit /b 1
)

:MENU
cls
echo ============================================================
echo      GCST - Unified AI Desktop Suite Launcher
echo ============================================================
echo   [1] Launch Both (GC + ST) in Background
echo   [2] Launch GC Only (British Grammar & Spell Checker)
echo   [3] Launch ST Only (On-Screen Hover Translator)
echo   [4] Stop Running GCST Processes
echo   [5] Exit
echo ============================================================
set /p "CHOICE=Enter choice [1-5]: "

if "%CHOICE%"=="1" goto :LAUNCH_ALL
if "%CHOICE%"=="2" goto :LAUNCH_GC
if "%CHOICE%"=="3" goto :LAUNCH_ST
if "%CHOICE%"=="4" goto :STOP_ALL
if "%CHOICE%"=="5" exit /b 0

echo [!] Invalid selection. Please choose 1, 2, 3, 4, or 5.
timeout /t 2 >nul
goto :MENU

:LAUNCH_ALL
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" -Component All
goto :DONE

:LAUNCH_GC
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" -Component GC
goto :DONE

:LAUNCH_ST
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start.ps1" -Component ST
goto :DONE

:STOP_ALL
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop.ps1" -Component All
goto :DONE

:DONE
if "%~1"=="" (
    echo.
    echo Press any key to return to menu, or close this window...
    pause >nul
    goto :MENU
)
