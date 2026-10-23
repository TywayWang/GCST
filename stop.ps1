<#
.SYNOPSIS
    Gracefully stops running instances of GCST components (GC and/or ST).
.PARAMETER Component
    The component(s) to stop: "All", "GC", or "ST". Default is "All".
#>
param(
    [ValidateSet("All", "GC", "ST")]
    [string]$Component = "All"
)

$ErrorActionPreference = "SilentlyContinue"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$gcPathPart = Join-Path $ScriptDir "GC"
$stPathPart = Join-Path $ScriptDir "ST"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  GCST Suite - Process Stopper                              " -ForegroundColor Cyan
Write-Host "  Target: $Component                                        " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$stoppedCount = 0

if ($Component -in @("All", "GC")) {
    Write-Host "[GCST] Searching for running GC processes in $gcPathPart..." -ForegroundColor Yellow
    
    # Target KeyMonitor.exe from GCST/GC/bin
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq "KeyMonitor.exe" -and ($_.ExecutablePath -like "*$gcPathPart*" -or $_.CommandLine -like "*$gcPathPart*")
    } | ForEach-Object {
        Write-Host "  -> Terminating KeyMonitor.exe (PID: $($_.ProcessId))" -ForegroundColor DarkYellow
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        $stoppedCount++
    }

    # Target electron.exe from GCST/GC
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq "electron.exe" -and ($_.ExecutablePath -like "*$gcPathPart*" -or $_.CommandLine -like "*$gcPathPart*")
    } | ForEach-Object {
        Write-Host "  -> Terminating Electron instance (PID: $($_.ProcessId))" -ForegroundColor DarkYellow
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        $stoppedCount++
    }
}

if ($Component -in @("All", "ST")) {
    Write-Host "[GCST] Searching for running ST processes in $stPathPart..." -ForegroundColor Yellow

    # Target pythonw.exe or python.exe running st_windows from GCST/ST
    Get-CimInstance Win32_Process | Where-Object {
        ($_.Name -in @("python.exe", "pythonw.exe")) -and 
        ($_.ExecutablePath -like "*$stPathPart*" -or $_.CommandLine -like "*$stPathPart*" -or ($_.CommandLine -like "*st_windows.main*" -and $_.CommandLine -like "*$ScriptDir*"))
    } | ForEach-Object {
        Write-Host "  -> Terminating ST Python process (PID: $($_.ProcessId))" -ForegroundColor DarkYellow
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        $stoppedCount++
    }
}

if ($stoppedCount -gt 0) {
    Write-Host "[GCST] Successfully stopped $stoppedCount process(es)." -ForegroundColor Green
} else {
    Write-Host "[GCST] No running GCST ($Component) processes were detected." -ForegroundColor DarkGray
}
