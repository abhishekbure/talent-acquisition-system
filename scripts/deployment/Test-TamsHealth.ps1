<#
.SYNOPSIS
  Phase 15: verifies that the local TAMS deployment is healthy and prints the evidence. Read-only.
.DESCRIPTION
  Checks SQL Server and SQL Server Agent, the database (online, schema, least-privilege roles, seed users, backups),
  the SQL Server Agent jobs and their recent outcomes, the Windows Task Scheduler tasks, the application's own job runs
  and e-mail queue, the running API (health, security headers, refusal without a token) and the web application it
  serves (page, bundle, Content-Security-Policy, build up to date), the storage folders and the local configuration.
  Every line is PASS, WARN (works, but needs attention) or FAIL (the application is not usable).
  Exit code 0 = no FAIL. Nothing is changed and no secret is printed.
.EXAMPLE
  .\scripts\deployment\Test-TamsHealth.ps1
  .\scripts\deployment\Test-TamsHealth.ps1 -BaseUrl http://localhost:5000 -SkipApi
#>
[CmdletBinding()]
param(
    [string]$Server = 'localhost',
    [string]$Database = 'TalentAcquisitionDB',
    [string]$BaseUrl = 'http://localhost:5000',
    [switch]$SkipApi,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $root 'scripts\database\TamsSql.ps1')
$results = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$Area, [string]$Name, [string]$Level, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ Area = $Area; Check = $Name; Result = $Level; Detail = $Detail }) | Out-Null
}
function Pass([string]$a, [string]$n, [string]$d = '') { Add-Check $a $n 'PASS' $d }
function Judge([string]$a, [string]$n, [bool]$ok, [string]$d, [string]$failLevel = 'FAIL') { Add-Check $a $n $(if ($ok) { 'PASS' } else { $failLevel }) $d }

# ---------------------------------------------------------------- SQL Server
foreach ($svc in @(@{ n = 'MSSQLSERVER'; lvl = 'FAIL' }, @{ n = 'SQLSERVERAGENT'; lvl = 'WARN' })) {
    $s = Get-Service -Name $svc.n -ErrorAction SilentlyContinue
    Judge 'SQL Server' "service $($svc.n) running" ($s -and $s.Status -eq 'Running') $(if ($s) { "$($s.Status), start type $($s.StartType)" } else { 'not installed' }) $svc.lvl
}
$c = $null
try { $c = New-TamsConnection -Server $Server -Timeout 10; Pass 'SQL Server' 'connect (Windows authentication)' (Get-TamsScalar $c "SELECT CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(30)) + ' ' + CAST(SERVERPROPERTY('Edition') AS NVARCHAR(60))") }
catch { Add-Check 'SQL Server' 'connect (Windows authentication)' 'FAIL' $_.Exception.Message }

if ($c) {
    try {
        $listen = @(Invoke-TamsQuery $c "SELECT DISTINCT CONVERT(VARCHAR(45), ip_address) ip FROM sys.dm_tcp_listener_states WHERE type_desc = 'TSQL' AND state_desc = 'ONLINE'").Rows | ForEach-Object { $_.ip }
        $public = @($listen | Where-Object { $_ -notin '127.0.0.1', '::1' })
        Judge 'SQL Server' 'SQL Server listens on loopback only (KI-011)' ($public.Count -eq 0) ("TCP listeners: " + ($listen -join ', ')) 'WARN'
    } catch { Add-Check 'SQL Server' 'SQL Server listeners' 'WARN' $_.Exception.Message }

    # ------------------------------------------------------------ database
    $state = Get-TamsScalar $c "SELECT state_desc + '/' + user_access_desc + '/' + recovery_model_desc FROM sys.databases WHERE name = @n" @{ n = $Database }
    Judge 'Database' "$Database exists and is online" ($state -like 'ONLINE/MULTI_USER/*') $(if ($state) { $state } else { 'missing: run scripts\database\Run-DatabaseSetup.ps1' })
    if ($state -like 'ONLINE/*') {
        $d = New-TamsConnection -Server $Server -Database $Database -Timeout 10
        try {
            $obj = (Invoke-TamsQuery $d "SELECT (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0) t, (SELECT COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0) p, (SELECT COUNT(*) FROM sys.objects WHERE type IN ('FN','IF','TF')) f, (SELECT COUNT(*) FROM sys.triggers WHERE parent_class = 1) tr, (SELECT COUNT(*) FROM sys.views WHERE is_ms_shipped = 0) v").Rows[0]
            $schemas = 'sec', 'org', 'cand', 'hr', 'staff', 'time', 'bill', 'doc', 'notify', 'sched', 'report', 'audit'
            $missing = @($schemas | Where-Object { (Get-TamsScalar $d "SELECT COUNT(*) FROM sys.tables WHERE schema_id = SCHEMA_ID(@s)" @{ s = $_ }) -eq 0 })
            Judge 'Database' 'schema installed (all 12 schemas have tables)' ($missing.Count -eq 0 -and $obj.p -gt 100) ("{0} tables, {1} procedures, {2} functions, {3} triggers, {4} views{5}" -f $obj.t, $obj.p, $obj.f, $obj.tr, $obj.v, $(if ($missing) { '; empty schemas: ' + ($missing -join ', ') } else { '' }))
            $roles = Invoke-TamsQuery $d "SELECT r.name, (SELECT COUNT(*) FROM sys.database_permissions p WHERE p.grantee_principal_id = r.principal_id AND p.state = 'G') grants, IS_ROLEMEMBER('db_owner', r.name) owner FROM sys.database_principals r WHERE r.name IN ('tams_app_role','tams_worker_role','tams_report_role')"
            $ownerish = @($roles.Rows | Where-Object { $_.owner -eq 1 })
            Judge 'Database' 'least-privilege roles (app, worker, report) exist; none is db_owner' ($roles.Rows.Count -eq 3 -and $ownerish.Count -eq 0) (($roles.Rows | ForEach-Object { "$($_.name): $($_.grants) grants" }) -join '; ')
            $seed = Invoke-TamsQuery $d "SELECT r.RoleName, SUM(CASE WHEN u.IsActive = 1 THEN 1 ELSE 0 END) active, SUM(CASE WHEN u.IsActive = 1 AND DATALENGTH(u.PasswordHash) <= 1 THEN 1 ELSE 0 END) nopw FROM sec.Roles r LEFT JOIN sec.UserRoles ur ON ur.RoleId = r.RoleId LEFT JOIN sec.Users u ON u.UserId = ur.UserId GROUP BY r.RoleName"
            $empty = @($seed.Rows | Where-Object { $_.active -eq 0 } | ForEach-Object { $_.RoleName })
            Judge 'Database' 'every role has an active user' ($empty.Count -eq 0) (($seed.Rows | ForEach-Object { "$($_.RoleName) $($_.active)" }) -join ', ') 'WARN'
            $nopw = ($seed.Rows | Measure-Object nopw -Sum).Sum
            Judge 'Database' 'development users can sign in (password set)' ($nopw -eq 0) $(if ($nopw -eq 0) { 'hashed passwords only (PBKDF2); the plaintext is only in dev-credentials.local.md' } else { "$nopw users have no password yet: run scripts\database\Set-DevPasswords.ps1" }) 'WARN'
            $rows = (Invoke-TamsQuery $d "SELECT (SELECT COUNT(*) FROM cand.Candidates) c, (SELECT COUNT(*) FROM cand.JobApplications) a, (SELECT COUNT(*) FROM staff.Contracts) k, (SELECT COUNT(*) FROM bill.Invoices) i").Rows[0]
            Pass 'Database' 'business records' ("{0} candidates, {1} applications, {2} contracts, {3} invoices" -f $rows.c, $rows.a, $rows.k, $rows.i)
            $maxdop = Get-TamsScalar $d "SELECT CAST(value AS INT) FROM sys.database_scoped_configurations WHERE name = 'MAXDOP'"
            Judge 'Database' 'database-scoped MAXDOP 4 (Phase 13)' ($maxdop -eq 4) "MAXDOP = $maxdop" 'WARN'

            # application jobs and e-mail queue
            $failed = Invoke-TamsQuery $d "SELECT jd.JobName, COUNT(*) n FROM sched.JobExecutionHistory h JOIN sched.JobDefinitions jd ON jd.JobDefinitionId = h.JobDefinitionId WHERE h.Outcome = 'Failed' AND h.StartedAt >= DATEADD(HOUR, -24, SYSUTCDATETIME()) GROUP BY jd.JobName"
            Judge 'Jobs' 'no failed job runs in the last 24 hours (sched.JobExecutionHistory)' ($failed.Rows.Count -eq 0) $(if ($failed.Rows.Count) { ($failed.Rows | ForEach-Object { "$($_.JobName) x$($_.n)" }) -join '; ' } else { 'none' }) 'WARN'
            $q = (Invoke-TamsQuery $d "SELECT SUM(CASE WHEN Status IN ('Pending','Processing') THEN 1 ELSE 0 END) waiting, SUM(CASE WHEN Status = 'Failed' THEN 1 ELSE 0 END) failed, DATEDIFF(MINUTE, MIN(CASE WHEN Status = 'Pending' THEN CreatedAt END), SYSUTCDATETIME()) oldest FROM notify.NotificationQueue").Rows[0]
            $oldest = if ($q.oldest -is [DBNull]) { 0 } else { [int]$q.oldest }
            $qf = if ($q.failed -is [DBNull]) { 0 } else { [int]$q.failed }; $qw = if ($q.waiting -is [DBNull]) { 0 } else { [int]$q.waiting }
            Judge 'Jobs' 'e-mail queue is being delivered' ($qf -eq 0 -and $oldest -le 30) ("{0} waiting (oldest {1} min), {2} failed - delivered by the 'Email queue processing' task" -f $qw, $oldest, $qf) 'WARN'
        } finally { $d.Close() }

        $bk = Get-TamsScalar $c "SELECT DATEDIFF(HOUR, MAX(backup_finish_date), GETDATE()) FROM msdb.dbo.backupset WHERE database_name = @n AND type = 'D' AND is_copy_only = 0" @{ n = $Database }
        Judge 'Database' 'full backup taken in the last 8 days' ($null -ne $bk -and $bk -le 192) $(if ($null -eq $bk) { 'no full backup yet (SQL Agent job "TAMS - Full database backup" or scripts\database\Backup-TamsDatabase.ps1)' } else { "last full backup $bk hours ago" }) 'WARN'
    }

    # ------------------------------------------------------------ SQL Server Agent jobs
    $prefix = if ($Database -eq 'TalentAcquisitionDB') { 'TAMS - ' } else { "TAMS[$Database] - " }
    $jobs = Invoke-TamsQuery $c "SELECT j.name, j.enabled, (SELECT TOP 1 h.run_status FROM msdb.dbo.sysjobhistory h WHERE h.job_id = j.job_id AND h.step_id = 0 ORDER BY h.instance_id DESC) last_status FROM msdb.dbo.sysjobs j WHERE j.name LIKE @p" @{ p = $prefix.Replace('[', '[[]') + '%' }
    $disabled = @($jobs.Rows | Where-Object { $_.enabled -ne 1 })
    Judge 'SQL Agent' 'TAMS Agent jobs installed and enabled (9)' ($jobs.Rows.Count -eq 9 -and $disabled.Count -eq 0) $(if ($jobs.Rows.Count -eq 0) { 'none: run scripts\database\Install-AgentJobs.ps1' } else { "$($jobs.Rows.Count) jobs, $($disabled.Count) disabled" }) 'WARN'
    $lastFailed = @($jobs.Rows | Where-Object { $_.last_status -is [int] -and $_.last_status -eq 0 } | ForEach-Object { $_.name })
    $never = @($jobs.Rows | Where-Object { $_.last_status -is [DBNull] }).Count
    Judge 'SQL Agent' 'last run of each Agent job succeeded' ($lastFailed.Count -eq 0) $(if ($lastFailed) { 'failed: ' + ($lastFailed -join '; ') } else { "ok ($never not run yet)" }) 'WARN'
    $c.Close()
}

# ---------------------------------------------------------------- Windows Task Scheduler
$tasks = @(Get-ScheduledTask -TaskPath '\TAMS\' -ErrorAction SilentlyContinue)
if ($tasks.Count -eq 0) { Add-Check 'Task Scheduler' 'TAMS tasks registered (7)' 'WARN' 'not registered: e-mail is not delivered and reminders are not queued until you run scripts\scheduler\Register-ScheduledTasks.ps1 (KI-055)' }
else {
    $info = $tasks | ForEach-Object { $i = $_ | Get-ScheduledTaskInfo; [pscustomobject]@{ Name = $_.TaskName; State = $_.State; Result = $i.LastTaskResult; Ran = $i.LastRunTime } }
    $bad = @($info | Where-Object { $_.Ran -and $_.Ran.Year -gt 2000 -and $_.Result -ne 0 -and $_.Result -ne 267009 })
    Judge 'Task Scheduler' 'TAMS tasks registered (7) and enabled' ($tasks.Count -eq 7 -and @($info | Where-Object State -eq 'Disabled').Count -eq 0) "$($tasks.Count) tasks" 'WARN'
    Judge 'Task Scheduler' 'last result of each task is 0' ($bad.Count -eq 0) $(if ($bad) { ($bad | ForEach-Object { "$($_.Name)=$($_.Result)" }) -join '; ' } else { 'ok' }) 'WARN'
}

# ---------------------------------------------------------------- API and web application
if (-not $SkipApi) {
    $base = $BaseUrl.TrimEnd('/')
    try {
        $r = Invoke-WebRequest -UseBasicParsing "$base/api/v1/health" -TimeoutSec 10
        $h = $r.Content | ConvertFrom-Json
        Judge 'API' "health $base/api/v1/health" ($h.status -eq 'ok' -and $h.database -eq $Database) ("status {0}, database {1}" -f $h.status, $h.database)
        $hdr = 'X-Content-Type-Options', 'X-Frame-Options', 'Referrer-Policy', 'X-Correlation-Id' | Where-Object { -not $r.Headers[$_] }
        Judge 'API' 'security headers on API responses' ($hdr.Count -eq 0) $(if ($hdr) { 'missing: ' + ($hdr -join ', ') } else { 'nosniff, DENY, no-referrer, correlation id' })
        $code = try { (Invoke-WebRequest -UseBasicParsing "$base/api/v1/candidates" -TimeoutSec 10).StatusCode } catch { [int]$_.Exception.Response.StatusCode }
        Judge 'API' 'a request without a token is refused' ($code -eq 401) "GET /api/v1/candidates -> $code"
        try {
            $page = Invoke-WebRequest -UseBasicParsing "$base/" -TimeoutSec 10
            $csp = $page.Headers['Content-Security-Policy']
            Judge 'Web app' "web application served at $base/" ($page.Content -match '<app-root>' -and $csp -match "script-src 'self'") $(if ($csp) { 'index.html with Content-Security-Policy' } else { 'no Content-Security-Policy header' })
            $main = [regex]::Match($page.Content, 'main-[A-Z0-9]+\.js').Value
            $js = Invoke-WebRequest -UseBasicParsing "$base/$main" -TimeoutSec 10
            Judge 'Web app' 'application bundle served' ($js.StatusCode -eq 200 -and $js.Headers['Content-Type'] -like 'text/javascript*') "$main $([math]::Round($js.RawContentLength / 1KB)) KB"
            $deep = Invoke-WebRequest -UseBasicParsing "$base/recruiter/jobs" -TimeoutSec 10
            Judge 'Web app' 'deep links open the app (reload on any page works)' ($deep.Content -match '<app-root>') '/recruiter/jobs -> index.html'
        } catch { Add-Check 'Web app' "web application served at $base/" 'FAIL' "$($_.Exception.Message) - build it (cd frontend; npx ng build) and check WebRoot in appsettings.json" }
    } catch { Add-Check 'API' "health $base/api/v1/health" 'FAIL' "not reachable ($($_.Exception.Message)): start it with scripts\deployment\Start-Tams.ps1" }
}
$index = Join-Path $root 'frontend\dist\tams-web\browser\index.html'
if (Test-Path $index) {
    $built = (Get-Item $index).LastWriteTime
    $newer = @(Get-ChildItem (Join-Path $root 'frontend\src') -Recurse -File | Where-Object { $_.LastWriteTime -gt $built -and $_.Name -notlike '*.spec.ts' })
    Judge 'Web app' 'production build is up to date with the source' ($newer.Count -eq 0) $(if ($newer) { "$($newer.Count) source files changed since the build ($built): Start-Tams.ps1 rebuilds it" } else { "built $built" }) 'WARN'
} else { Add-Check 'Web app' 'production build exists' 'FAIL' 'frontend\dist\tams-web\browser missing: Start-Tams.ps1 builds it' }

# ---------------------------------------------------------------- files and configuration
foreach ($f in 'documents', 'mail-outbox') {
    $p = Join-Path $root "storage\$f"; $ok = $false
    $probe = if (Test-Path $p) { $p } else { Join-Path $root 'storage' }      # the API and the sender create the folder on first use
    try { $t = Join-Path $probe ('.health-' + [Guid]::NewGuid().ToString('N')); [IO.File]::WriteAllText($t, 'x'); Remove-Item $t; $ok = $true } catch { }
    Judge 'Files' "storage\$f writable" $ok $(if (Test-Path $p) { $p } else { "$p (created on first use)" })
}
$local = Join-Path $root 'backend\TalentAcquisition.API\appsettings.local.json'
$secretOk = $false; if (Test-Path $local) { try { $j = Get-Content $local -Raw | ConvertFrom-Json; $secretOk = ([Convert]::FromBase64String($j.JwtSecret)).Length -ge 32 } catch { } }
Judge 'Config' 'API signing secret configured (appsettings.local.json, git-ignored)' $secretOk $(if ($secretOk) { 'present (not displayed)' } else { 'missing or weak: run scripts\setup\New-LocalConfig.ps1' })
foreach ($exe in 'TalentAcquisition.API', 'TalentAcquisition.Scheduler') {
    $p = Join-Path $root "backend\$exe\bin\Debug\net472\$exe.exe"
    Judge 'Config' "$exe built" (Test-Path $p) $(if (Test-Path $p) { (Get-Item $p).LastWriteTime.ToString('yyyy-MM-dd HH:mm') } else { 'run: dotnet build .\backend\TalentAcquisition.sln' })
}
Judge 'Config' 'development logins file present (dev-credentials.local.md, git-ignored)' (Test-Path (Join-Path $root 'dev-credentials.local.md')) 'contents not read' 'WARN'

# ---------------------------------------------------------------- report
if (-not $Quiet) { $results | Format-Table Result, Area, Check, Detail -AutoSize -Wrap | Out-String -Width 220 | Write-Host }
$fail = @($results | Where-Object Result -eq 'FAIL').Count; $warn = @($results | Where-Object Result -eq 'WARN').Count
Write-Host ("--- Health: {0} passed, {1} warnings, {2} failed, {3} checks ---" -f @($results | Where-Object Result -eq 'PASS').Count, $warn, $fail, $results.Count) -ForegroundColor $(if ($fail) { 'Red' } elseif ($warn) { 'Yellow' } else { 'Green' })
if ($fail) { exit 1 } else { exit 0 }
