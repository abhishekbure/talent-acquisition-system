<#
.SYNOPSIS
  Phase 15: starts the complete local TAMS deployment with one command and verifies it.
.DESCRIPTION
  1. SQL Server       - checks that SQL Server and SQL Server Agent are running (starts them when this window may).
  2. Database         - creates TalentAcquisitionDB with schema and seed data ONLY if it does not exist, then gives the seeded
                        development users random passwords (hash in the database, plaintext only in dev-credentials.local.md).
                        An existing database is never dropped, overwritten or re-seeded.
  3. Configuration    - creates the git-ignored appsettings.local.json with a new signing secret if it is missing.
  4. Build            - builds the backend (dotnet build) and, when the source changed, the production Angular bundle (ng build).
  5. API + web app    - starts TalentAcquisition.API.exe hidden; it serves the API and the web application on
                        http://localhost:5000 (one address, loopback only). A previous instance started by this script is restarted.
  6. -Dev             - additionally runs "ng serve" on http://localhost:4200 (live reload, proxy to the API) for UI work.
  7. Background jobs  - reports the SQL Server Agent jobs and Task Scheduler tasks; -InstallAgentJobs / -RegisterTasks install them.
  8. Health           - runs Test-TamsHealth.ps1 and opens the browser (unless -NoBrowser).
  Stop everything this script started with scripts\deployment\Stop-Tams.ps1. Logs: .run\ (git-ignored) and the API's logs folder.
.EXAMPLE
  .\scripts\deployment\Start-Tams.ps1
.EXAMPLE
  .\scripts\deployment\Start-Tams.ps1 -Dev -NoBrowser
.EXAMPLE
  .\scripts\deployment\Start-Tams.ps1 -InstallAgentJobs -RegisterTasks
.EXAMPLE
  .\scripts\deployment\Start-Tams.ps1 -DatabaseName TalentAcquisitionDB_Restored -Port 5090     # a restored copy beside the normal app
  (a missing database of that name is created and seeded; its logins go to dev-credentials.<name>.local.md)
#>
[CmdletBinding()]
param(
    [string]$Server = 'localhost',
    [switch]$Dev,
    [switch]$SkipBuild,
    [switch]$NoBrowser,
    [switch]$InstallAgentJobs,
    [switch]$RegisterTasks,
    # another database / port (for example a restored copy next to the normal instance); links in e-mails follow the port
    [string]$DatabaseName = 'TalentAcquisitionDB',
    [ValidateRange(1024, 65535)][int]$Port = 5000
)
$ErrorActionPreference = 'Stop'
if ($DatabaseName -notmatch '^[A-Za-z0-9_]{1,100}$') { throw 'Invalid database name.' }
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $root 'scripts\database\TamsSql.ps1')
$Database = $DatabaseName
$standard = $Database -eq 'TalentAcquisitionDB' -and $Port -eq 5000
if ($RegisterTasks -and -not $standard) { throw '-RegisterTasks is only for TalentAcquisitionDB on port 5000 (the tasks in \TAMS\ serve that instance).' }
$base = "http://localhost:$Port"
$run = Join-Path $root '.run'; New-Item -ItemType Directory -Force $run | Out-Null
$stateFile = Join-Path $run $(if ($Port -eq 5000) { 'tams.json' } else { "tams-$Port.json" })    # one state file per instance (port)
$apiArgs = @()
$credName = if ($Database -eq 'TalentAcquisitionDB') { 'dev-credentials.local.md' } else { "dev-credentials.$Database.local.md" }
if (-not $standard) {
    # a settings file for this instance only (git-ignored .run folder): its database, its address and the links it e-mails
    $settingsFile = Join-Path $run "settings-$Port.json"
    [IO.File]::WriteAllText($settingsFile, ([ordered]@{
        ConnectionString = "Server=$Server;Database=$Database;Integrated Security=SSPI;TrustServerCertificate=True;Application Name=TalentAcquisition.API;Connect Timeout=15"
        ListenUrl = "$base/"; AppBaseUrl = $base; ResetLinkBase = "$base/reset-password"; VerifyEmailLinkBase = "$base/verify-email"
    } | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    $apiArgs = @('--settings', $settingsFile)
}
$apiExe = Join-Path $root 'backend\TalentAcquisition.API\bin\Debug\net472\TalentAcquisition.API.exe'
function Step([string]$t) { Write-Host "== $t" -ForegroundColor Cyan }
function Note([string]$t, [string]$color = 'Gray') { Write-Host "   $t" -ForegroundColor $color }
function Test-Url([string]$url) { try { return (Invoke-WebRequest -UseBasicParsing $url -TimeoutSec 3).StatusCode -eq 200 } catch { return $false } }
function Wait-Url([string]$url, [int]$seconds, $proc) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) { if (Test-Url $url) { return $true }; if ($proc -and $proc.HasExited) { return $false }; Start-Sleep -Milliseconds 700 }
    return $false
}
function Read-State { if (Test-Path $stateFile) { try { return Get-Content $stateFile -Raw | ConvertFrom-Json } catch { } }; return $null }

# ------------------------------------------------------------------ 1. SQL Server
Step '1/8 SQL Server'
foreach ($svc in 'MSSQLSERVER', 'SQLSERVERAGENT') {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if (-not $s) { if ($svc -eq 'MSSQLSERVER') { throw 'SQL Server (MSSQLSERVER) is not installed. See documentation\LOCAL_SETUP.md section 2.' } else { Note "$svc is not installed: the nightly jobs will not run" 'Yellow'; continue } }
    if ($s.Status -ne 'Running') {
        try { Start-Service $svc; Note "$svc started" 'Green' }
        catch {
            $msg = "$svc is $($s.Status) and this window may not start services. Open PowerShell as administrator and run: Start-Service $svc"
            if ($svc -eq 'MSSQLSERVER') { throw $msg } else { Note $msg 'Yellow'; continue }
        }
    } else { Note "$svc running" }
}
$m = $null
foreach ($i in 1..20) { try { $m = New-TamsConnection -Server $Server -Timeout 5; break } catch { Start-Sleep -Seconds 1 } }
if (-not $m) { throw "Cannot connect to SQL Server '$Server' with Windows authentication." }

# ------------------------------------------------------------------ 2. Database
Step '2/8 Database'
try { $exists = $null -ne (Get-TamsScalar $m "SELECT DB_ID(@n)" @{ n = $Database }) } finally { $m.Close() }
if ($exists) { Note "$Database exists - left unchanged (scripts\database\Run-DatabaseSetup.ps1 re-applies scripts on request)" }
else {
    Note "$Database does not exist: creating schema, programmable objects and seed data"
    & (Join-Path $root 'scripts\database\Run-DatabaseSetup.ps1') -Server $Server -DatabaseName $Database
    if ($LASTEXITCODE -ne 0) { throw 'Database setup failed (see the output above).' }
    & (Join-Path $root 'scripts\database\Set-DevPasswords.ps1') -Server $Server -DatabaseName $Database -OutFile (Join-Path $root $credName)
    Note "development users have random passwords; see $credName (git-ignored)" 'Green'
}

# ------------------------------------------------------------------ 3. Configuration
Step '3/8 Configuration'
& (Join-Path $root 'scripts\setup\New-LocalConfig.ps1') | ForEach-Object { Note $_ }
foreach ($f in 'documents', 'mail-outbox') { New-Item -ItemType Directory -Force (Join-Path $root "storage\$f") | Out-Null }

# a running instance started by this script is stopped first (its files would be locked by the build)
$state = Read-State
if ($state) { & (Join-Path $PSScriptRoot 'Stop-Tams.ps1') -Port $Port -Quiet }
if (Test-Url "$base/api/v1/health") { throw "Something already answers on $base (an API started by hand?). Stop it, then run this script again." }

# ------------------------------------------------------------------ 4. Build
Step '4/8 Build'
if ($SkipBuild) { Note 'skipped (-SkipBuild)' }
else {
    dotnet build (Join-Path $root 'backend\TalentAcquisition.sln') -v q -nologo *> (Join-Path $run 'build-backend.log')
    if ($LASTEXITCODE -ne 0) { throw "The backend does not build: see $run\build-backend.log" }
    Note 'backend built (Debug)'
    $fe = Join-Path $root 'frontend'
    if (-not (Test-Path (Join-Path $fe 'node_modules'))) {
        Note 'installing frontend packages (npm ci, from package-lock.json)'
        Push-Location $fe; try { npm ci --no-audit --no-fund *> (Join-Path $run 'npm-ci.log') } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { throw "npm ci failed: see $run\npm-ci.log" }
    }
    $index = Join-Path $fe 'dist\tams-web\browser\index.html'
    $inputs = @(Get-ChildItem (Join-Path $fe 'src'), (Join-Path $fe 'public') -Recurse -File) + @(Get-Item (Join-Path $fe 'angular.json'), (Join-Path $fe 'package-lock.json'))
    $stale = -not (Test-Path $index) -or @($inputs | Where-Object { $_.LastWriteTime -gt (Get-Item $index).LastWriteTime -and $_.Name -notlike '*.spec.ts' }).Count -gt 0
    if ($stale) {
        Note 'building the production web app (ng build)'
        Push-Location $fe; try { npx ng build *> (Join-Path $run 'build-frontend.log') } finally { Pop-Location }
        if ($LASTEXITCODE -ne 0) { throw "ng build failed: see $run\build-frontend.log" }
        Note 'web app built: frontend\dist\tams-web\browser'
    } else { Note 'web app build is up to date' }
}
if (-not (Test-Path $apiExe)) { throw "The API is not built: $apiExe" }

# ------------------------------------------------------------------ 5. API + web app
Step "5/8 API and web application on $base"
$startArgs = @{}; if ($apiArgs) { $startArgs.ArgumentList = @('--settings', "`"$settingsFile`"") }   # quoted: the path may contain spaces
# Started through the Windows shell WITHOUT redirection: the API then inherits none of this window's handles. (With
# -RedirectStandardOutput it inherited the caller's output pipe, so "Start-Tams.ps1 > file" or a calling script never finished.)
# The API writes its own log file; on a failed start, --check below prints the reason.
$api = Start-Process @startArgs -FilePath $apiExe -WorkingDirectory (Split-Path $apiExe) -WindowStyle Hidden -PassThru
$null = $api.Handle      # keeps the exit code readable if it stops at once
$newState = [ordered]@{ started = (Get-Date).ToString('s'); apiPid = $api.Id; uiPid = $null }
$newState | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8
if (-not (Wait-Url "$base/api/v1/health" 60 $api)) {
    $why = switch ($api.ExitCode) { 2 { 'invalid configuration' } 3 { 'the database is not reachable' } 4 { "port $Port is in use" } default { 'see the log' } }
    $psi = New-Object Diagnostics.ProcessStartInfo $apiExe
    $psi.Arguments = '--check' + $(if ($apiArgs) { " --settings `"$settingsFile`"" } else { '' })
    $psi.WorkingDirectory = Split-Path $apiExe; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi); $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd(); $p.WaitForExit()
    throw "The API did not start ($why). TalentAcquisition.API.exe --check says: $(($err + ' ' + $out).Trim())"
}
$apiLog = Join-Path (Split-Path $apiExe) 'logs'
Note "API running (process $($api.Id)); log: $apiLog" 'Green'

# ------------------------------------------------------------------ 6. Angular dev server (optional)
Step '6/8 Angular development server'
if ($Dev) {
    $proxy = Join-Path $run 'proxy.json'
    [IO.File]::WriteAllText($proxy, (@{ '/api' = @{ target = $base; secure = $false; changeOrigin = $false; logLevel = 'warn' } } | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding $false))
    $ui = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "npx ng serve --port 4200 --proxy-config `"$proxy`" --no-open > `"$run\ng-serve.log`" 2>&1") -WorkingDirectory (Join-Path $root 'frontend') -WindowStyle Hidden -PassThru
    $newState.uiPid = $ui.Id; $newState | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8
    if (-not (Wait-Url 'http://localhost:4200/' 180 $ui)) { throw "ng serve did not start: $(Get-Content "$run\ng-serve.log" -Raw)" }
    Note "ng serve running on http://localhost:4200 (live reload; /api is proxied to $base)" 'Green'
} else { Note "not started (the production build is served on port $Port; use -Dev for live reload on port 4200)" }

# ------------------------------------------------------------------ 7. Background jobs
Step '7/8 Background jobs'
if ($InstallAgentJobs) { & (Join-Path $root 'scripts\database\Install-AgentJobs.ps1') -Server $Server -DatabaseName $Database | Out-Null; Note 'SQL Server Agent jobs (re)installed' 'Green' }
$c = New-TamsConnection -Server $Server
$jobPrefix = if ($Database -eq 'TalentAcquisitionDB') { 'TAMS - ' } else { "TAMS[[]$Database] - " }
try { $jobs = Get-TamsScalar $c "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name LIKE @p AND enabled = 1" @{ p = $jobPrefix + '%' } } finally { $c.Close() }
Note $(if ($jobs -gt 0) { "SQL Server Agent: $jobs TAMS jobs enabled (they run on their own schedules)" } else { 'SQL Server Agent jobs not installed: run with -InstallAgentJobs' }) $(if ($jobs -gt 0) { 'Gray' } else { 'Yellow' })
if ($RegisterTasks) { & (Join-Path $root 'scripts\scheduler\Register-ScheduledTasks.ps1') | Out-Null; Note 'Task Scheduler tasks registered in \TAMS\' 'Green' }
$tasks = @(Get-ScheduledTask -TaskPath '\TAMS\' -ErrorAction SilentlyContinue).Count
Note $(if ($tasks) { "Task Scheduler: $tasks TAMS tasks registered" } else { 'Task Scheduler tasks not registered: e-mail stays queued until you run with -RegisterTasks (or deliver once: TalentAcquisition.Scheduler.exe run email-queue)' }) $(if ($tasks) { 'Gray' } else { 'Yellow' })

# ------------------------------------------------------------------ 8. Health
Step '8/8 Health check'
& (Join-Path $PSScriptRoot 'Test-TamsHealth.ps1') -Server $Server -Database $Database -BaseUrl $base
$healthy = $LASTEXITCODE -eq 0
Write-Host ''
Write-Host "TAMS is running: $base$(if ($Dev) { '   (live-reload UI: http://localhost:4200)' })" -ForegroundColor $(if ($healthy) { 'Green' } else { 'Yellow' })
Write-Host "  Sign in with a development account from $credName (one per role)."
Write-Host "  Stop:   .\scripts\deployment\Stop-Tams.ps1$(if ($Port -ne 5000) { " -Port $Port" })"
if (-not $NoBrowser) { Start-Process "$(if ($Dev) { 'http://localhost:4200' } else { $base })/" }
if ($healthy) { exit 0 } else { exit 1 }
