# ST Windows Runner
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir

Write-Host "=== ST On-Screen Hover Translator for Windows 11 ===" -ForegroundColor Cyan

$PythonExe = Join-Path $ScriptDir ".venv\Scripts\python.exe"

if (-not (Test-Path $PythonExe)) {
    Write-Host "[ST] Creating virtual environment with uv..." -ForegroundColor Yellow
    uv venv .venv
    Write-Host "[ST] Installing dependencies from requirements.txt..." -ForegroundColor Yellow
    uv pip install --python $PythonExe -r requirements.txt
}

Write-Host "[ST] Launching ST Translator..." -ForegroundColor Green
& $PythonExe -m st_windows.main
