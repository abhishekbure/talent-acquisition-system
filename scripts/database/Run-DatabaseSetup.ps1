<#
.SYNOPSIS
  One-command database setup: creates TalentAcquisitionDB (never drops), schemas, tables,
  constraints, indexes, any stored procedures / functions / triggers / views present,
  seed data, and optionally runs the database tests. Repeatable.

  Examples:
    .\Run-DatabaseSetup.ps1 -IncludeTests
    .\Run-DatabaseSetup.ps1 -Server '(localdb)\MSSQLLocalDB' -DatabaseName TAMS_ScriptCheck -IncludeTests
#>
[CmdletBinding()]
param(
    [string]$Server = 'localhost',
    [string]$DatabaseName = 'TalentAcquisitionDB',
    [switch]$IncludeTests,
    [switch]$SkipSeed
)
$ErrorActionPreference = 'Stop'
$db = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 'database'
$runner = Join-Path $PSScriptRoot 'Invoke-SqlScripts.ps1'

# Functions (07) are created before procedures (06) that call them; triggers/views follow.
$folders = '01_Database','02_Schemas','03_Tables','04_Constraints','05_Indexes','07_Functions','06_StoredProcedures','08_Triggers','09_Views'
if (-not $SkipSeed) { $folders += '10_SeedData' }
if ($IncludeTests)  { $folders += '12_Tests' }

foreach ($f in $folders) {
    $p = Join-Path $db $f
    if (-not (Test-Path $p) -or -not (Get-ChildItem $p -Filter *.sql -ErrorAction SilentlyContinue)) { Write-Host "-- $f : no scripts yet, skipped"; continue }
    & $runner -Server $Server -DatabaseName $DatabaseName -Path $p
    if ($LASTEXITCODE -ne 0) { Write-Host "STOPPED: $f failed." -ForegroundColor Red; exit $LASTEXITCODE }
}
Write-Host 'Database setup completed.' -ForegroundColor Green
