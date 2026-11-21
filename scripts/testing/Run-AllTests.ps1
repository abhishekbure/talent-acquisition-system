<#
.SYNOPSIS
  Phase 14: runs the complete automated test suite with one command and prints one summary.
.DESCRIPTION
  Always (about 6 minutes):
    0. builds the backend (dotnet build)
    1. database tests  - all database\12_Tests suites on a disposable copy TalentAcquisitionDB_SqlTest (dropped afterwards)
    2. backend tests   - the API integration suite (real API over HTTP on its own disposable copy)
    3. frontend tests  - Angular unit tests (ChromeHeadless)
    4. end-to-end      - Playwright through the real web app, API and database (scripts\testing\Run-E2E.ps1)
  Optional:
    -IncludeTasks       Task Scheduler harness (Test-ScheduledTasks.ps1, registers temporary tasks)
    -IncludeAgent       real SQL Server Agent runs (Test-AgentJobs.ps1)
    -IncludePerformance large-volume performance and stress test (Test-Performance.ps1, ~5 minutes)
    -IncludeCleanBuild  builds every script into a NEW database and runs the SQL suites there
  The development database is only read (copied). Exit code 0 = every suite passed.
.EXAMPLE
  .\scripts\testing\Run-AllTests.ps1
  .\scripts\testing\Run-AllTests.ps1 -IncludeTasks -IncludeAgent -IncludePerformance -IncludeCleanBuild
#>
[CmdletBinding()]
param([string]$Server = 'localhost', [switch]$IncludeTasks, [switch]$IncludeAgent, [switch]$IncludePerformance, [switch]$IncludeCleanBuild)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $root 'scripts\database\TamsSql.ps1')
$logs = Join-Path $root 'tests\results'; New-Item -ItemType Directory -Force $logs | Out-Null
$summary = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$suite, [int]$passed, [int]$total, [double]$seconds, [string]$log) {
    $summary.Add([pscustomobject]@{ Suite = $suite; Passed = $passed; Failed = $total - $passed; Total = $total; Minutes = [math]::Round($seconds / 60, 1); Result = $(if ($total -gt 0 -and $passed -eq $total) { 'PASS' } else { 'FAIL' }); Log = $log })
    Write-Host ("   {0}: {1}/{2}" -f $suite, $passed, $total) -ForegroundColor $(if ($total -gt 0 -and $passed -eq $total) { 'Green' } else { 'Red' })
}
function Run-Logged([string]$name, [scriptblock]$block) {
    $log = Join-Path $logs ($name + '.log'); $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "== $name" -ForegroundColor Cyan
    try { & $block *> $log } catch { "THROWN: $($_.Exception.Message)" | Add-Content $log }
    return @{ Log = $log; Seconds = $sw.Elapsed.TotalSeconds; Text = (Get-Content $log -Raw) }
}
function Sum-SqlSuites([string]$text) {
    $p = 0; $t = 0
    foreach ($m in [regex]::Matches($text, '--- .*?: (\d+) passed, (\d+) failed, (\d+) total ---')) { $p += [int]$m.Groups[1].Value; $t += [int]$m.Groups[3].Value }
    return @($p, $t)
}

Write-Host '== build' -ForegroundColor Cyan
dotnet build (Join-Path $root 'backend\TalentAcquisition.sln') -v q -nologo *> (Join-Path $logs 'build.log')
if ($LASTEXITCODE -ne 0) { throw "The backend does not build; see $logs\build.log" }

# 1. database tests on a disposable copy
$db = 'TalentAcquisitionDB_SqlTest'
$r = Run-Logged 'database-tests' {
    & (Join-Path $root 'scripts\database\Copy-Database.ps1') -Server $Server -Target $db -Force
    try { & (Join-Path $root 'scripts\database\Invoke-SqlScripts.ps1') -Server $Server -DatabaseName $db -Path (Join-Path $root 'database\12_Tests') -StopOnError $false }
    finally { $m = New-TamsConnection -Server $Server; try { Invoke-TamsNonQuery $m "IF DB_ID(N'$db') IS NOT NULL BEGIN ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$db]; END" | Out-Null } finally { $m.Close() } }
}
$s = Sum-SqlSuites $r.Text; Add-Result 'Database (9 SQL suites)' $s[0] $s[1] $r.Seconds $r.Log

# 2. backend
$r = Run-Logged 'backend-tests' { & (Join-Path $root 'scripts\deployment\Run-BackendTests.ps1') -Server $Server }
$trx = Join-Path $root 'tests\backend\TestResults\api-tests.trx'
if (Test-Path $trx) { [xml]$x = Get-Content $trx; $c = $x.TestRun.ResultSummary.Counters; Add-Result 'Backend API integration' ([int]$c.passed) ([int]$c.total) $r.Seconds $r.Log } else { Add-Result 'Backend API integration' 0 1 $r.Seconds $r.Log }

# 3. frontend unit
$r = Run-Logged 'frontend-unit-tests' { Push-Location (Join-Path $root 'frontend'); try { npx ng test --watch=false --browsers=ChromeHeadless } finally { Pop-Location } }
$m = [regex]::Matches($r.Text, 'Executed (\d+) of (\d+)(?: \((\d+) FAILED\))?') | Select-Object -Last 1
if ($m) { $tot = [int]$m.Groups[2].Value; $fail = $(if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { 0 }); if ($r.Text -match 'FAILED|ERROR' -and $fail -eq 0) { $fail = 1 }; Add-Result 'Frontend unit' ($tot - $fail) $tot $r.Seconds $r.Log } else { Add-Result 'Frontend unit' 0 1 $r.Seconds $r.Log }

# 4. end-to-end
$r = Run-Logged 'e2e-tests' { & (Join-Path $root 'scripts\testing\Run-E2E.ps1') -Server $Server }
$json = Join-Path $root 'tests\e2e\results.json'
if (Test-Path $json) { $st = (Get-Content $json -Raw | ConvertFrom-Json).stats; Add-Result 'Browser end-to-end' ([int]$st.expected) ([int]$st.expected + [int]$st.unexpected + [int]$st.flaky) $r.Seconds $r.Log } else { Add-Result 'Browser end-to-end' 0 1 $r.Seconds $r.Log }

# optional
if ($IncludeTasks) { $r = Run-Logged 'task-scheduler' { & (Join-Path $root 'scripts\testing\Test-ScheduledTasks.ps1') -Server $Server }; $s = Sum-SqlSuites $r.Text; Add-Result 'Task Scheduler harness' $s[0] $s[1] $r.Seconds $r.Log }
if ($IncludeAgent) { $r = Run-Logged 'sql-agent' { & (Join-Path $root 'scripts\testing\Test-AgentJobs.ps1') -Server $Server }; $s = Sum-SqlSuites $r.Text; Add-Result 'SQL Server Agent harness' $s[0] $s[1] $r.Seconds $r.Log }
if ($IncludePerformance) { $r = Run-Logged 'performance' { & (Join-Path $root 'scripts\testing\Test-Performance.ps1') -Server $Server }; $s = Sum-SqlSuites $r.Text; Add-Result 'Performance (large copy)' $s[0] $s[1] $r.Seconds $r.Log }
if ($IncludeCleanBuild) {
    $cb = 'TAMS_CleanBuild_AllTests'
    $r = Run-Logged 'clean-build' {
        try { & (Join-Path $root 'scripts\database\Run-DatabaseSetup.ps1') -Server $Server -DatabaseName $cb -IncludeTests }
        finally { $m = New-TamsConnection -Server $Server; try { Invoke-TamsNonQuery $m "IF DB_ID(N'$cb') IS NOT NULL BEGIN ALTER DATABASE [$cb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$cb]; END" | Out-Null } finally { $m.Close() } }
    }
    $s = Sum-SqlSuites $r.Text; Add-Result 'Clean build into a new database' $s[0] $s[1] $r.Seconds $r.Log
}

Write-Host ''
$summary | Format-Table Suite, Passed, Failed, Total, Minutes, Result -AutoSize | Out-String | Write-Host
$allPassed = @($summary | Where-Object Result -eq 'FAIL').Count -eq 0
$grand = ($summary | Measure-Object Total -Sum).Sum; $gp = ($summary | Measure-Object Passed -Sum).Sum
Write-Host ("--- All tests: {0} passed, {1} failed, {2} total --- (logs in tests\results)" -f $gp, ($grand - $gp), $grand) -ForegroundColor $(if ($allPassed) { 'Green' } else { 'Red' })
if ($allPassed) { exit 0 } else { exit 1 }
