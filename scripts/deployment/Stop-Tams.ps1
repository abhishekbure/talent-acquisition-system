<#
.SYNOPSIS
  Phase 15: stops the API and the Angular development server started by Start-Tams.ps1.
.DESCRIPTION
  -Port selects the instance (default 5000; Start-Tams.ps1 -Port N records its own .run\tams-N.json).
  Only the processes recorded in .run\tams.json are stopped, and only if they still are the programs that were started
  (process name check). SQL Server, SQL Server Agent jobs and Task Scheduler tasks keep running; they are Windows services
  and scheduled tasks, not part of a session (see README "Stopping").
#>
[CmdletBinding()]
param([switch]$Quiet, [int]$Port = 5000)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$stateFile = Join-Path (Join-Path $root '.run') $(if ($Port -eq 5000) { 'tams.json' } else { "tams-$Port.json" })   # one per instance (Start-Tams.ps1 -Port)
function Say([string]$t) { if (-not $Quiet) { Write-Host $t } }
if (-not (Test-Path $stateFile)) { Say "Nothing to stop on port $Port (no $stateFile`: not started by Start-Tams.ps1)."; exit 0 }
$state = Get-Content $stateFile -Raw | ConvertFrom-Json
if ($state.uiPid) {
    $p = Get-Process -Id $state.uiPid -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq 'cmd') { & taskkill.exe /PID $state.uiPid /T /F 2>&1 | Out-Null; Say "Stopped ng serve (process tree $($state.uiPid))." }
}
if ($state.apiPid) {
    $p = Get-Process -Id $state.apiPid -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq 'TalentAcquisition.API') { Stop-Process -Id $state.apiPid -Force; $p.WaitForExit(10000) | Out-Null; Say "Stopped the API (process $($state.apiPid))." }
    else { Say 'The API was no longer running.' }
}
Remove-Item $stateFile -Force
