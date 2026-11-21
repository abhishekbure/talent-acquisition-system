<#
.SYNOPSIS
  Phase 15: proves the one-command start-up from nothing: a fresh copy of the project (no builds, no local configuration,
  no credentials, no database) is started with Start-Tams.ps1 and checked, then everything is removed again.
.DESCRIPTION
  1. Copies the project to a temporary folder WITHOUT bin/obj, dist, .angular, .run, test output, storage contents,
     appsettings.local.json and dev-credentials*.local.md (what a fresh checkout lacks). frontend\node_modules is linked
     (directory junction) instead of copied or downloaded, so "npm ci" itself is not exercised.
  2. Runs Start-Tams.ps1 -DatabaseName TalentAcquisitionDB_CleanDeploy -Port 5091 -NoBrowser in that copy: it must create and
     seed the database, generate the secret and the development passwords, build backend and web app, start and pass health.
  3. Checks the result through HTTP: health, web app, sign-in with a generated development password (read from the copy's
     credentials file in memory, never printed), role-scoped data, and Stop-Tams.ps1.
  4. Drops the database and deletes the folder (the junction is removed as a link; the real node_modules is untouched).
  The normal instance (TalentAcquisitionDB on port 5000) is not touched and may keep running. Exit code 0 = every check passed.
#>
[CmdletBinding()]
param([string]$Server = 'localhost', [int]$Port = 5091, [switch]$Keep)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $root 'scripts\database\TamsSql.ps1')
$db = 'TalentAcquisitionDB_CleanDeploy'
$work = Join-Path $env:TEMP ('tams-clean-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$results = New-Object System.Collections.ArrayList
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') { [void]$results.Add($Ok); Write-Host ("{0}  {1}{2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $(if ($Detail) { "  ($Detail)" } else { '' })) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' }) }
$m = New-TamsConnection -Server $Server
try { if ($null -ne (Get-TamsScalar $m "SELECT DB_ID(@n)" @{ n = $db })) { throw "$db already exists (left from an earlier run?). Drop it first." } } finally { $m.Close() }
$junction = Join-Path $work 'frontend\node_modules'
try {
    Write-Host "== 1. Fresh copy in $work" -ForegroundColor Cyan
    $xd = @('.git', '.run', '.vs', 'bin', 'obj', 'dist', '.angular', 'node_modules', 'TestResults', 'results', 'e2e-artifacts') | ForEach-Object { $_ }
    & robocopy.exe $root $work /E /NFL /NDL /NJH /NJS /NP /XD $xd (Join-Path $root 'tests\e2e') (Join-Path $root 'storage\documents') (Join-Path $root 'storage\mail-outbox') (Join-Path $root 'storage\document-backup') `
        /XF 'appsettings.local.json' 'dev-credentials*.local.md' '*.log' | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
    & cmd.exe /c mklink /J "`"$junction`"" "`"$(Join-Path $root 'frontend\node_modules')`"" | Out-Null
    $leftovers = @(Get-ChildItem $work -Recurse -Force -Directory -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notlike "$junction*" -and $_.Name -in 'bin', 'obj', 'dist', '.angular', '.run' })
    $secrets = @(Get-ChildItem $work -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notlike "$junction*" -and ($_.Name -eq 'appsettings.local.json' -or $_.Name -like 'dev-credentials*') })
    Check 'the copy has no build output, no local configuration and no credentials' ($leftovers.Count -eq 0 -and $secrets.Count -eq 0) "$($leftovers.Count) build folders, $($secrets.Count) secret files"

    Write-Host "== 2. Start-Tams.ps1 in the copy (database $db, port $Port)" -ForegroundColor Cyan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work 'scripts\deployment\Start-Tams.ps1') -DatabaseName $db -Port $Port -NoBrowser *> (Join-Path $env:TEMP "$(Split-Path $work -Leaf)-start.log")
    $code = $LASTEXITCODE; $secs = [int]$sw.Elapsed.TotalSeconds
    $log = Get-Content (Join-Path $env:TEMP "$(Split-Path $work -Leaf)-start.log") -Raw
    Check 'Start-Tams.ps1 succeeded from nothing (health: no FAIL)' ($code -eq 0) "exit $code after $secs s"
    Check 'it created and seeded the database' ($log -match "$db does not exist: creating" -and $log -match 'Database setup completed') ''
    Check 'it generated the signing secret and the development passwords' ((Test-Path (Join-Path $work 'backend\TalentAcquisition.API\appsettings.local.json')) -and (Test-Path (Join-Path $work "dev-credentials.$db.local.md"))) ''
    Check 'it built the backend and the production web app' ((Test-Path (Join-Path $work 'backend\TalentAcquisition.API\bin\Debug\net472\TalentAcquisition.API.exe')) -and (Test-Path (Join-Path $work 'frontend\dist\tams-web\browser\index.html'))) ''
    if ($log -match '--- Health: (\d+) passed, (\d+) warnings, (\d+) failed') { Write-Host "   health: $($Matches[0])" }

    Write-Host '== 3. The started instance' -ForegroundColor Cyan
    $base = "http://localhost:$Port"
    $h = try { Invoke-RestMethod "$base/api/v1/health" -TimeoutSec 10 } catch { $null }
    Check "health on $base reports the new database" ($h -and $h.status -eq 'ok' -and $h.database -eq $db) $(if ($h) { "$($h.status) $($h.database)" } else { 'no answer' })
    $page = try { Invoke-WebRequest -UseBasicParsing "$base/admin/users" -TimeoutSec 10 } catch { $null }
    Check 'the web app is served (deep link) with a Content-Security-Policy' ($page -and $page.Content -match '<app-root>' -and $page.Headers['Content-Security-Policy']) ''
    $cred = Get-Content (Join-Path $work "dev-credentials.$db.local.md") -Raw
    $pw = [regex]::Match($cred, '\| admin@tams\.local \| `([^`]+)` \|').Groups[1].Value
    $login = try { Invoke-RestMethod "$base/api/v1/auth/login" -Method Post -ContentType 'application/json' -Body (@{ email = 'admin@tams.local'; password = $pw } | ConvertTo-Json) -TimeoutSec 15 } catch { $null }
    $pw = $null; $cred = $null
    Check 'the administrator signs in with the generated password' ($login -and $login.token) ''
    if ($login) {
        $users = Invoke-RestMethod "$base/api/v1/users?page=1" -Headers @{ Authorization = "Bearer $($login.token)" }
        $c = New-TamsConnection -Server $Server -Database $db
        try { $n = Get-TamsScalar $c 'SELECT COUNT(*) FROM sec.Users' } finally { $c.Close() }
        Check 'the API returns the seeded users of the new database' ($users.total -eq $n -and $n -gt 0) "$($users.total) via API, $n in SQL"
        $code = try { (Invoke-WebRequest -UseBasicParsing "$base/api/v1/timesheets/mine" -Headers @{ Authorization = "Bearer $($login.token)" }).StatusCode } catch { [int]$_.Exception.Response.StatusCode }
        Check 'role checks are active (administrator refused a contractor endpoint)' ($code -eq 403) "HTTP $code"
    }
    $other = try { (Invoke-RestMethod 'http://localhost:5000/api/v1/health' -TimeoutSec 5).database } catch { 'not running' }
    Write-Host "   (the normal instance on port 5000: $other)"

    Write-Host '== 4. Stop-Tams.ps1 in the copy' -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work 'scripts\deployment\Stop-Tams.ps1') -Port $Port | Out-Host
    Start-Sleep -Seconds 1
    $still = try { Invoke-RestMethod "$base/api/v1/health" -TimeoutSec 3; $true } catch { $false }
    Check 'Stop-Tams.ps1 stopped the API it started' (-not $still) ''
    if ($other -ne 'not running') { $after = try { (Invoke-RestMethod 'http://localhost:5000/api/v1/health' -TimeoutSec 5).database } catch { 'not running' }; Check 'the normal instance on port 5000 kept running' ($after -eq $other) $after }
}
finally {
    if (-not $Keep) {
        if ((Test-Path $junction) -and ((Get-Item $junction -Force).Attributes -match 'ReparsePoint')) { [IO.Directory]::Delete($junction, $false) }   # removes the link only, never the real node_modules
        if (-not (Test-Path $junction) -and (Test-Path $work)) { [IO.Directory]::Delete($work, $true) }
        [IO.File]::Delete((Join-Path $env:TEMP "$(Split-Path $work -Leaf)-start.log"))
        $m = New-TamsConnection -Server $Server
        try { Invoke-TamsNonQuery $m "IF DB_ID(N'$db') IS NOT NULL BEGIN ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$db]; END" | Out-Null } finally { $m.Close() }
        Write-Host "== Removed $work and dropped $db"
    } else { Write-Host "== Kept $work and $db" }
}
$p = @($results | Where-Object { $_ }).Count
Write-Host ("--- Clean deployment: {0} passed, {1} failed, {2} total ---" -f $p, ($results.Count - $p), $results.Count) -ForegroundColor $(if ($p -eq $results.Count) { 'Green' } else { 'Red' })
if ($p -eq $results.Count) { exit 0 } else { exit 1 }
