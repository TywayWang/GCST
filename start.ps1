<#
.SYNOPSIS
    Master launcher for the GCST Desktop Suite (GC Grammar Checker & ST Hover Translator).
.PARAMETER Component
    Component to launch: "All", "GC", or "ST". Default is "All".
.PARAMETER NoWait
    Launch processes detached in background and exit. Default is true.
#>
param(
    [ValidateSet("All", "GC", "ST")]
    [string]$Component = "All",
    [switch]$Foreground = $false
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir

$gcDir = Join-Path $ScriptDir "GC"
$stDir = Join-Path $ScriptDir "ST"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  GCST Suite - Unified AI Desktop Suite                     " -ForegroundColor Cyan
Write-Host "  GC: British English Grammar Checker                       " -ForegroundColor DarkCyan
Write-Host "  ST: Real-Time On-Screen Hover Translator                  " -ForegroundColor DarkCyan
Write-Host "============================================================" -ForegroundColor Cyan

# 1. Health probe for local Ollama
Write-Host "`n[1/3] Probing local Ollama service (127.0.0.1:11434)..." -ForegroundColor Yellow
try {
    $response = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -Method Get -TimeoutSec 3 -ErrorAction Stop
    $models = $response.models | ForEach-Object { $_.name }
    Write-Host "  [OK] Ollama is online! Available models: $($models.Count)" -ForegroundColor Green
    if ($models -contains "gemma4:e4b") {
        Write-Host "  [OK] Model 'gemma4:e4b' is available." -ForegroundColor Green
    } else {
        Write-Host "  [!] Notice: 'gemma4:e4b' was not found in local models list. Ensure it is pulled with: ollama pull gemma4:e4b" -ForegroundColor DarkYellow
    }
} catch {
    Write-Host "  [!] Warning: Ollama service is not responding at 127.0.0.1:11434." -ForegroundColor Red
    Write-Host "      Please ensure Ollama is started with: ollama serve" -ForegroundColor DarkGray
}

# 2. Launch GC
if ($Component -in @("All", "GC")) {
    Write-Host "`n[2/3] Preparing GC (British Grammar & Spell Checker)..." -ForegroundColor Yellow
    
    # Verify node_modules
    $electronBin = Join-Path $gcDir "node_modules\.bin\electron.cmd"
    if (-not (Test-Path $electronBin)) {
        Write-Host "  [*] Installing GC dependencies via npm..." -ForegroundColor Cyan
        Push-Location $gcDir
        npm install
        Pop-Location
    }

    # Verify KeyMonitor hook
    $keyMonitorBin = Join-Path $gcDir "bin\KeyMonitor.exe"
    if (-not (Test-Path $keyMonitorBin)) {
        Write-Host "  [*] Compiling GC KeyMonitor.exe hook..." -ForegroundColor Cyan
        Push-Location $gcDir
        npm run compile-hook
        Pop-Location
    }

    Write-Host "  [->] Launching GC..." -ForegroundColor Green
    if ($Foreground -and $Component -eq "GC") {
        Push-Location $gcDir
        npm start
        Pop-Location
    } else {
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "npm start" -WorkingDirectory $gcDir -WindowStyle Hidden
        Write-Host "  [OK] GC launched in background (active in system tray / desktop HUD)." -ForegroundColor Green
    }
}

# 3. Launch ST
if ($Component -in @("All", "ST")) {
    Write-Host "`n[3/3] Preparing ST (On-Screen Hover Translator)..." -ForegroundColor Yellow

    $pythonExe = Join-Path $stDir ".venv\Scripts\python.exe"
    $pythonwExe = Join-Path $stDir ".venv\Scripts\pythonw.exe"

    if (-not (Test-Path $pythonExe)) {
        Write-Host "  [*] Creating ST virtual environment with uv..." -ForegroundColor Cyan
        Push-Location $stDir
        uv venv .venv
        uv pip install --python $pythonExe -r requirements.txt
        Pop-Location
    }

    Write-Host "  [->] Launching ST..." -ForegroundColor Green
    if ($Foreground -and $Component -eq "ST") {
        Push-Location $stDir
        & $pythonExe -m st_windows.main
        Pop-Location
    } else {
        Start-Process -FilePath $pythonwExe -ArgumentList "-m", "st_windows.main" -WorkingDirectory $stDir -WindowStyle Hidden
        Write-Host "  [OK] ST launched in background (active in GCST suite / hover detection)." -ForegroundColor Green
    }
}

Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host "  GCST components active!                                  " -ForegroundColor Green
Write-Host "  To stop: run stop.bat or 'powershell .\stop.ps1'         " -ForegroundColor DarkGray
Write-Host "============================================================" -ForegroundColor Cyan
