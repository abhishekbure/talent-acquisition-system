<#
.SYNOPSIS
  Phase 11: proves the TAMS SQL Server Agent jobs by REAL Agent runs on a disposable copy of TalentAcquisitionDB.
.DESCRIPTION
  1. copies TalentAcquisitionDB to -Database (COPY_ONLY backup; the live database is only read);
  2. installs the 9 jobs for the copy (disabled: their schedules never fire) and checks their definition in msdb;
  3. prepares work for them in the copy (a job past its closing date, a contract ending soon, an old sent notification);
  4. starts every job with msdb.dbo.sp_start_job, waits for SQL Server Agent to finish it and reads the Agent job history
     (msdb.dbo.sysjobhistory) and TAMS's own history (sched.JobExecutionHistory / JobExecutionDetails);
  5. restores the FULL + DIFF + LOG backups the jobs wrote into another database and checks the data;
  6. proves the duplicate-run lock (a held lock makes the run "Skipped"), failure handling (Agent reports the failure,
     TAMS records it and notifies administrators, the Windows Application log gets the Agent failure event);
  7. removes the jobs, the restored database, the copy's backup files and backup history, and the copy (unless -Keep).
  Exit code 0 = all checks passed.
#>
[CmdletBinding()]
param([string]$Server = 'localhost', [string]$Database = 'TalentAcquisitionDB_AgentTest', [switch]$Keep)
$ErrorActionPreference = 'Stop'
if ($Database -eq 'TalentAcquisitionDB' -or $Database -notmatch '^[A-Za-z0-9_]{1,80}$') { throw 'Use a disposable copy name.' }
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
. (Join-Path $root 'scripts\database\TamsSql.ps1')
$restored = $Database + '_Restored'
$prefix = "TAMS[$Database] - "
$results = New-Object System.Collections.Generic.List[object]
function Check([string]$name, [bool]$ok, [string]$detail = '') { $results.Add([pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail }); Write-Host ("{0}  {1}{2}" -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $name, $(if (-not $ok -and $detail) { "  -> $detail" } else { '' })) }

Write-Host "== Copying TalentAcquisitionDB to $Database"
& (Join-Path $root 'scripts\database\Copy-Database.ps1') -Server $Server -Target $Database -Force | Out-Null
Write-Host "== Installing the Agent jobs for $Database (disabled)"
& (Join-Path $root 'scripts\database\Install-AgentJobs.ps1') -Server $Server -DatabaseName $Database | Out-Null

$m = New-TamsConnection -Server $Server -Database 'msdb'
$d = New-TamsConnection -Server $Server -Database $Database
try {
    $jobs = Invoke-TamsQuery $m "SELECT j.name, j.enabled, c.name AS category, SUSER_SNAME(j.owner_sid) AS owner, s.database_name, s.command,
                                       (SELECT COUNT(*) FROM msdb.dbo.sysjobschedules js WHERE js.job_id = j.job_id) AS schedules
                                FROM msdb.dbo.sysjobs j JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
                                JOIN msdb.dbo.sysjobsteps s ON s.job_id = j.job_id WHERE j.name LIKE @p" @{ p = $prefix.Replace('[', '[[]') + '%' }
    Check "C01 nine Agent jobs exist for the copy: category TAMS, owner sa, one T-SQL step in the copy, one schedule, disabled (schedules cannot fire)" `
        ($jobs.Rows.Count -eq 9 -and @($jobs.Rows | Where-Object { $_.category -ne 'TAMS' -or $_.owner -ne 'sa' -or $_.database_name -ne $Database -or $_.schedules -ne 1 -or $_.enabled -ne 0 }).Count -eq 0) "rows=$($jobs.Rows.Count)"

    # ---- work for the data jobs (in the copy only)
    Invoke-TamsNonQuery $d "UPDATE TOP (1) rec.JobRequisitions SET ClosesBy = DATEADD(DAY, -1, dbo.fn_BusinessToday()) WHERE Status = 'Open';
                            UPDATE staff.Contracts SET Status = 'Active', EndDate = DATEADD(DAY, 10, dbo.fn_BusinessToday()) WHERE ContractNo LIKE N'CON-%-002';
                            DECLARE @u INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'DIVYA.REDDY@CANDIDATE.EXAMPLE');
                            EXEC notify.usp_Enqueue 'TEST_NOTE', @u, N'agent purge probe', N'x', N'AGENTPURGE', 'Test', 1;
                            UPDATE notify.NotificationQueue SET Status = 'Sent', Attempts = 1, ProcessedAt = DATEADD(DAY, -100, SYSUTCDATETIME()) WHERE DedupeKey LIKE N'AGENTPURGE|%';"

    function Run-Job([string]$suffix, [string]$jobName = $null) {
        $name = if ($jobName) { $jobName } else { $prefix + $suffix }
        $before = Get-TamsScalar $m "SELECT ISNULL(MAX(h.instance_id), 0) FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name = @n" @{ n = $name }
        Invoke-TamsNonQuery $m "EXEC msdb.dbo.sp_start_job @job_name = @n" @{ n = $name }
        $deadline = (Get-Date).AddSeconds(240)
        do {
            Start-Sleep -Milliseconds 700
            $h = Invoke-TamsQuery $m "SELECT TOP (1) h.run_status, h.message, h.run_duration FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
                                      WHERE j.name = @n AND h.step_id = 0 AND h.instance_id > @b ORDER BY h.instance_id DESC" @{ n = $name; b = $before }
        } while ($h.Rows.Count -eq 0 -and (Get-Date) -lt $deadline)
        if ($h.Rows.Count -eq 0) { return @{ AgentOk = $false; AgentMessage = 'Agent did not finish within 240 s' } }
        $step = Get-TamsScalar $m "SELECT TOP (1) h.message FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
                                   WHERE j.name = @n AND h.step_id = 1 AND h.instance_id > @b ORDER BY h.instance_id DESC" @{ n = $name; b = $before }
        $t = Invoke-TamsQuery $d "SELECT TOP (1) h.ExecutionId, h.Outcome, h.RowsAffected, h.ErrorMessage,
                                         (SELECT STRING_AGG(x.Message, N' | ') FROM sched.JobExecutionDetails x WHERE x.ExecutionId = h.ExecutionId) AS Details
                                  FROM sched.JobExecutionHistory h JOIN sched.JobDefinitions d ON d.JobDefinitionId = h.JobDefinitionId
                                  WHERE d.JobName = @j ORDER BY h.ExecutionId DESC" @{ j = 'TAMS - ' + $suffix }
        $r = @{ AgentOk = ([int]$h.Rows[0].run_status -eq 1); AgentMessage = [string]$h.Rows[0].message; StepMessage = [string]$step }
        if ($t.Rows.Count -gt 0) { $r.Outcome = [string]$t.Rows[0].Outcome; $r.Rows = $t.Rows[0].RowsAffected; $r.Error = [string]$t.Rows[0].ErrorMessage; $r.Details = [string]$t.Rows[0].Details; $r.ExecutionId = $t.Rows[0].ExecutionId }
        return $r
    }

    Write-Host "== Starting each job through SQL Server Agent"
    $r = Run-Job 'Expire stale requisitions'
    $expired = Get-TamsScalar $d "SELECT COUNT(*) FROM rec.JobRequisitions WHERE Status = 'Expired'"
    Check "A01 Expire stale requisitions: Agent run succeeded, TAMS run Succeeded, the job past its closing date is Expired" ($r.AgentOk -and $r.Outcome -eq 'Succeeded' -and $expired -ge 1) "$($r.AgentMessage) | $($r.Outcome) | expired=$expired"

    $r = Run-Job 'Detect contract expiry'
    $st = Get-TamsScalar $d "SELECT Status FROM staff.Contracts WHERE ContractNo LIKE N'CON-%-002'"
    Check "A02 Detect contract expiry: Agent and TAMS succeeded, the contract ending in 10 days is Expiring" ($r.AgentOk -and $r.Outcome -eq 'Succeeded' -and $st -eq 'Expiring') "$($r.AgentMessage) | $($r.Outcome) | $st"

    $r = Run-Job 'Purge notification queue'
    $left = Get-TamsScalar $d "SELECT COUNT(*) FROM notify.NotificationQueue WHERE DedupeKey LIKE N'AGENTPURGE|%'"
    Check "A03 Purge notification queue: Agent and TAMS succeeded, the 100-day-old sent notification is gone" ($r.AgentOk -and $r.Outcome -eq 'Succeeded' -and $left -eq 0) "$($r.AgentMessage) | $($r.Outcome) | left=$left"

    $r = Run-Job 'Prepare daily recruitment summary'
    $sum = Get-TamsScalar $d "SELECT COUNT(*) FROM report.DailyRecruitmentSummary WHERE SummaryDate = dbo.fn_BusinessToday()"
    Check "A04 Prepare daily recruitment summary: Agent and TAMS succeeded, today's row exists" ($r.AgentOk -and $r.Outcome -eq 'Succeeded' -and $sum -eq 1) "$($r.AgentMessage) | $($r.Outcome) | rows=$sum"

    $r = Run-Job 'Differential database backup'
    Check "A05 the first differential backup becomes a FULL one, because no full backup taken by the job exists yet (restorable chain)" `
        ($r.AgentOk -and $r.Outcome -eq 'Succeeded' -and $r.Details -like '*not taken by this job*' -and $r.Details -like '*_FULL_*') "$($r.AgentMessage) | $($r.Details)"
    $r = Run-Job 'Full database backup'
    Check "A06 Full database backup: Agent and TAMS succeeded; file written and verified" ($r.AgentOk -and $r.Outcome -eq 'Succeeded' -and $r.Details -like '*Wrote and verified*_FULL_*') "$($r.AgentMessage) | $($r.Details)"
    Invoke-TamsNonQuery $d "UPDATE TOP (1) cand.Candidates SET Summary = N'agent-diff-marker' WHERE CandidateId = (SELECT MIN(CandidateId) FROM cand.Candidates)"
    $r = Run-Job 'Differential database backup'
    Check "A07 Differential database backup: a real differential this time" ($r.AgentOk -and $r.Outcome -eq 'Succeeded' -and $r.Details -like '*_DIFF_*' -and $r.Details -notlike '*not taken by this job*') "$($r.AgentMessage) | $($r.Details)"
    Invoke-TamsNonQuery $d "UPDATE TOP (1) cand.Candidates SET Summary = N'agent-log-marker' WHERE CandidateId = (SELECT MIN(CandidateId) FROM cand.Candidates)"
    $r = Run-Job 'Transaction log backup'
    Check "A08 Transaction log backup: Agent and TAMS succeeded" ($r.AgentOk -and $r.Outcome -eq 'Succeeded' -and $r.Details -like '*_LOG_*.trn*') "$($r.AgentMessage) | $($r.Details)"

    $sets = Invoke-TamsQuery $m "SELECT b.type, b.name, f.physical_device_name, b.backup_finish_date FROM msdb.dbo.backupset b JOIN msdb.dbo.backupmediafamily f ON f.media_set_id = b.media_set_id
                                 WHERE b.database_name = @db AND b.name LIKE N'TAMS %' ORDER BY b.backup_finish_date, b.backup_set_id" @{ db = $Database }
    $full = @($sets.Rows | Where-Object { $_.type -eq 'D' })[-1]; $diff = @($sets.Rows | Where-Object { $_.type -eq 'I' })[-1]; $log = @($sets.Rows | Where-Object { $_.type -eq 'L' })[-1]
    Check "A09 msdb backup history shows the TAMS full, differential and log backups, stored under ...\Backup\TAMS\$Database\" `
        ($full -and $diff -and $log -and $full.physical_device_name -like "*\TAMS\$Database\TAMS_$Database`_FULL_*.bak" -and $log.physical_device_name -like '*.trn') "sets=$($sets.Rows.Count)"

    # restore the chain into another database and look for the change made after the differential
    $dataDir = Get-TamsScalar $m "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(400))"
    $files = Invoke-TamsQuery $m "RESTORE FILELISTONLY FROM DISK = @f" @{ f = $full.physical_device_name }
    $move = ($files.Rows | ForEach-Object { "MOVE N'$($_.LogicalName)' TO N'" + (Join-Path $dataDir ("$restored`_" + $_.LogicalName + $(if ($_.Type -eq 'L') { '.ldf' } else { '.mdf' }))) + "'" }) -join ', '
    $rs = Try-TamsNonQuery $m "IF DB_ID(N'$restored') IS NOT NULL BEGIN ALTER DATABASE [$restored] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$restored]; END
                               RESTORE DATABASE [$restored] FROM DISK = N'$($full.physical_device_name)' WITH $move, NORECOVERY, CHECKSUM;
                               RESTORE DATABASE [$restored] FROM DISK = N'$($diff.physical_device_name)' WITH NORECOVERY, CHECKSUM;
                               RESTORE LOG [$restored] FROM DISK = N'$($log.physical_device_name)' WITH RECOVERY, CHECKSUM;" 600
    $marker = if ($rs.Ok) { Get-TamsScalar $m "SELECT COUNT(*) FROM [$restored].cand.Candidates WHERE Summary = N'agent-log-marker'" } else { -1 }
    $same = if ($rs.Ok) { (Get-TamsScalar $m "SELECT COUNT(*) FROM [$restored].cand.JobApplications") -eq (Get-TamsScalar $d "SELECT COUNT(*) FROM cand.JobApplications") } else { $false }
    Check "A10 the FULL + DIFF + LOG files restore into a new database, which contains the change made just before the log backup" ($rs.Ok -and $marker -eq 1 -and $same) "$($rs.Message) marker=$marker"

    $r = Run-Job 'Index maintenance'
    Check "A11 Index maintenance: Agent and TAMS succeeded and the run says what it examined" ($r.AgentOk -and $r.Outcome -eq 'Succeeded' -and $r.Details -like 'Indexes above the thresholds*') "$($r.AgentMessage) | $($r.Details)"
    # the same procedure with every index eligible, to see real REORGANIZE / REBUILD statements work (direct call on the copy)
    Invoke-TamsNonQuery $d "EXEC sched.usp_Job_IndexMaintenance @ReorganizeAbovePct = 0, @RebuildAbovePct = 20, @MinPages = 1"
    $act = Invoke-TamsQuery $d "SELECT TOP (1) h.Outcome, (SELECT COUNT(*) FROM sched.JobExecutionDetails x WHERE x.ExecutionId = h.ExecutionId AND x.Message LIKE N'REBUILD %') AS Rebuilt,
                                       (SELECT COUNT(*) FROM sched.JobExecutionDetails x WHERE x.ExecutionId = h.ExecutionId AND x.Message LIKE N'REORGANIZE %') AS Reorganized
                                FROM sched.JobExecutionHistory h JOIN sched.JobDefinitions d ON d.JobDefinitionId = h.JobDefinitionId WHERE d.JobName = N'TAMS - Index maintenance' ORDER BY h.ExecutionId DESC"
    Check "A12 with every index eligible the job really rebuilds (online) and reorganises indexes and logs each one" ($act.Rows[0].Outcome -eq 'Succeeded' -and ($act.Rows[0].Rebuilt + $act.Rows[0].Reorganized) -gt 0) "outcome=$($act.Rows[0].Outcome) rebuilt=$($act.Rows[0].Rebuilt) reorganized=$($act.Rows[0].Reorganized)"

    $r = Run-Job 'Update statistics'
    Check "A13 Update statistics: Agent and TAMS succeeded, statistics with changes were updated" ($r.AgentOk -and $r.Outcome -eq 'Succeeded' -and $r.Details -like 'Updated *statistics*' -and $r.Rows -gt 0) "$($r.AgentMessage) | $($r.Details)"

    # ---- a second run while one is going: hold the job's lock from another session
    $holder = New-TamsConnection -Server $Server -Database $Database
    Invoke-TamsNonQuery $holder "DECLARE @rc INT; EXEC @rc = sp_getapplock @Resource = N'TAMS - Update statistics', @LockMode = 'Exclusive', @LockOwner = 'Session', @LockTimeout = 0; IF @rc < 0 THROW 50000, 'could not take the lock', 1;"
    $r = Run-Job 'Update statistics'
    $holder.Close()
    Check "A14 a run that starts while another holds the job's lock does nothing and is recorded as Skipped (no double run)" ($r.AgentOk -and $r.Outcome -eq 'Skipped' -and $r.Error -like '*still in progress*') "$($r.AgentMessage) | $($r.Outcome) | $($r.Error)"

    # ---- failure handling: a probe job that runs a job procedure with an invalid parameter
    $probe = $prefix + 'failure probe'
    Invoke-TamsNonQuery $m "IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @n) EXEC msdb.dbo.sp_delete_job @job_name = @n;
                            EXEC msdb.dbo.sp_add_job @job_name = @n, @enabled = 0, @category_name = N'TAMS', @owner_login_name = N'sa', @notify_level_eventlog = 2;
                            EXEC msdb.dbo.sp_add_jobstep @job_name = @n, @step_name = N'Run', @subsystem = N'TSQL', @database_name = @db, @command = N'EXEC sched.usp_Job_DetectContractExpiry @WarningDays = 0;';
                            EXEC msdb.dbo.sp_add_jobserver @job_name = @n, @server_name = N'(local)';" @{ n = $probe; db = $Database }
    $since = Get-Date
    $r = Run-Job 'Detect contract expiry' $probe
    $notified = Get-TamsScalar $d "SELECT COUNT(*) FROM notify.NotificationQueue WHERE TemplateCode = 'JOB_FAILED' AND RelatedEntityId = @x" @{ x = [int]$r.ExecutionId }
    Check "A15 a failing job: Agent reports the step failed with the error text, TAMS records Failed with the error and notifies the administrators" `
        ((-not $r.AgentOk) -and $r.StepMessage -like '*WarningDays*' -and $r.Outcome -eq 'Failed' -and $r.Error -like '*WarningDays*' -and $notified -ge 1) "agent=$($r.AgentOk) step=$($r.StepMessage) outcome=$($r.Outcome) notified=$notified"
    Start-Sleep -Seconds 2
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $since } -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -like 'SQLSERVERAGENT*' -and $_.Id -eq 208 -and $_.Message.Contains($probe) -and $_.Message.Contains('Status: Failed') })   # Contains: the name has [ ], which -like treats as wildcards
    Check "A16 SQL Server Agent wrote the failure to the Windows Application event log" ($ev.Count -ge 1) "events=$($ev.Count)"
    Invoke-TamsNonQuery $m "EXEC msdb.dbo.sp_delete_job @job_name = @n" @{ n = $probe }

    $hist = Get-TamsScalar $m "SELECT COUNT(DISTINCT j.name) FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id WHERE j.name LIKE @p AND h.step_id = 0" @{ p = $prefix.Replace('[', '[[]') + '%' }
    $ours = Get-TamsScalar $d "SELECT COUNT(DISTINCT d.JobDefinitionId) FROM sched.JobExecutionHistory h JOIN sched.JobDefinitions d ON d.JobDefinitionId = h.JobDefinitionId WHERE d.Owner = 'SqlAgent'"
    Check "A17 the SQL Server Agent job history holds runs of all 9 jobs, and TAMS's own history has all 9 too" ($hist -eq 9 -and $ours -eq 9) "agent=$hist tams=$ours"
}
finally {
    if (-not $Keep) {
        Write-Host "== Cleaning up"
        & (Join-Path $root 'scripts\database\Install-AgentJobs.ps1') -Server $Server -DatabaseName $Database -Remove | Out-Null
        $bk = Get-TamsScalar $m "DECLARE @r NVARCHAR(400); EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'BackupDirectory', @r OUTPUT; SELECT @r"
        $dir = (Join-Path $bk "TAMS\$Database")
        $tomorrow = (Get-Date).AddDays(1).ToString('yyyy-MM-ddTHH:mm:ss')
        Invoke-TamsNonQuery $m "EXEC master.dbo.xp_delete_file 0, @dir, N'bak', @c, 0; EXEC master.dbo.xp_delete_file 0, @dir, N'trn', @c, 0;" @{ dir = $dir; c = $tomorrow }
        $d.Close()
        foreach ($db in $restored, $Database) {
            Invoke-TamsNonQuery $m "IF DB_ID(@n) IS NOT NULL BEGIN DECLARE @s NVARCHAR(400) = N'ALTER DATABASE ' + QUOTENAME(@n) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@n) + N';'; EXEC (@s); END
                                    EXEC msdb.dbo.sp_delete_database_backuphistory @database_name = @n;" @{ n = $db }
        }
        $left = Get-TamsScalar $m "SELECT COUNT(*) FROM msdb.dbo.sysjobs WHERE name LIKE @p" @{ p = $prefix.Replace('[', '[[]') + '%' }
        Write-Host "   jobs left for the copy: $left; copy and restored database dropped; their backup files and history removed ($dir is left empty)"
    }
    $m.Close()
}
$failed = @($results | Where-Object { -not $_.Ok }).Count
Write-Host ("--- Agent job tests: {0} passed, {1} failed, {2} total ---" -f ($results.Count - $failed), $failed, $results.Count)
if ($failed -gt 0) { exit 1 } else { exit 0 }
