<#
.SYNOPSIS
  Phase 12: proves the TAMS application tasks - first by running TalentAcquisition.Scheduler.exe by hand, then through
  Windows Task Scheduler - against a disposable copy of TalentAcquisitionDB. The live database is only read.
.DESCRIPTION
  Uses a temporary folder for the copy's settings file, mail outbox, document store, document backup and logs; registers
  the tasks in the Task Scheduler folder \TAMS-Test\ (pointing at the copy) and removes them, the copy and the folder at the
  end (unless -Keep). Exit code 0 = all checks passed.
#>
[CmdletBinding()]
param([string]$Server = 'localhost', [string]$Database = 'TalentAcquisitionDB_TaskTest', [switch]$Keep)
$ErrorActionPreference = 'Stop'
if ($Database -eq 'TalentAcquisitionDB' -or $Database -notmatch '^[A-Za-z0-9_]{1,80}$') { throw 'Use a disposable copy name.' }
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
. (Join-Path $root 'scripts\database\TamsSql.ps1')
$exe = Join-Path $root 'backend\TalentAcquisition.Scheduler\bin\Debug\net472\TalentAcquisition.Scheduler.exe'
if (-not (Test-Path $exe)) { throw "Build the scheduler first: $exe" }
$taskPath = '\TAMS-Test\'
$work = Join-Path $env:TEMP ('tams-tasktest-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$dirs = @{ outbox = "$work\outbox"; docs = "$work\documents"; docbak = "$work\document-backup"; logs = "$work\logs" }
$dirs.Values | ForEach-Object { New-Item -ItemType Directory -Force $_ | Out-Null }
$results = New-Object System.Collections.Generic.List[object]
function Check([string]$name, [bool]$ok, [string]$detail = '') { $results.Add([pscustomobject]@{ Name = $name; Ok = $ok }); Write-Host ("{0}  {1}{2}" -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $name, $(if (-not $ok -and $detail) { "  -> $detail" } else { '' })) }
function Write-Settings([string]$path, [hashtable]$extra = @{}) {
    $o = [ordered]@{ ConnectionString = "Server=$Server;Database=$Database;Integrated Security=SSPI;TrustServerCertificate=True;Application Name=TalentAcquisition.Scheduler;Connect Timeout=5"
                    MailOutboxPath = $dirs.outbox; DocumentStorePath = $dirs.docs; DocumentBackupPath = $dirs.docbak; LogDirectory = $dirs.logs }
    foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] }
    [IO.File]::WriteAllText($path, ($o | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}
function Run-Exe([string[]]$a) {
    $p = Start-Process -FilePath $exe -ArgumentList $a -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$work\out.txt" -RedirectStandardError "$work\err.txt"
    return @{ Code = $p.ExitCode; Out = (Get-Content "$work\out.txt" -Raw) + (Get-Content "$work\err.txt" -Raw) }
}
$settings = "$work\settings.json"; Write-Settings $settings

Write-Host "== Copying TalentAcquisitionDB to $Database"
& (Join-Path $root 'scripts\database\Copy-Database.ps1') -Server $Server -Target $Database -Force | Out-Null
$d = New-TamsConnection -Server $Server -Database $Database
function LastRun([string]$job) {
    $t = Invoke-TamsQuery $d "SELECT TOP 1 h.ExecutionId, h.Outcome, h.RowsAffected, h.ErrorMessage, h.HostName FROM sched.JobExecutionHistory h JOIN sched.JobDefinitions d ON d.JobDefinitionId = h.JobDefinitionId WHERE d.JobName = @j ORDER BY h.ExecutionId DESC" @{ j = $job }
    if ($t.Rows.Count -eq 0) { return $null } else { return $t.Rows[0] }
}
try {
    # ---- work for the tasks, in the copy and the temporary folders
    $docName = ('{0:N}' -f [Guid]::NewGuid()) + '.pdf'; $liveName = ('{0:N}' -f [Guid]::NewGuid()) + '.pdf'
    foreach ($n in $docName, $liveName) { $sub = Join-Path $dirs.docs $n.Substring(0, 2); New-Item -ItemType Directory -Force $sub | Out-Null; [IO.File]::WriteAllText((Join-Path $sub $n), "%PDF-1.4 test $n") }
    Invoke-TamsNonQuery $d "UPDATE TOP (1) cand.Interviews SET Status = 'Scheduled', StartsAt = DATEADD(HOUR, 5, SYSUTCDATETIME()), EndsAt = DATEADD(HOUR, 6, SYSUTCDATETIME()) WHERE JobApplicationId IS NOT NULL;
        UPDATE TOP (1) cand.JobOffers SET Status = 'Sent', SentAt = DATEADD(DAY, -1, SYSUTCDATETIME()), ExpiresAt = DATEADD(HOUR, 30, SYSUTCDATETIME());
        UPDATE staff.Contracts SET Status = 'Expiring', EndDate = DATEADD(DAY, 10, dbo.fn_BusinessToday()) WHERE ContractNo LIKE N'CON-%-002';
        DELETE FROM report.DailyRecruitmentSummary WHERE SummaryDate = DATEADD(DAY, -1, dbo.fn_BusinessToday());
        INSERT report.DailyRecruitmentSummary (SummaryDate, OpenRequisitions, NewApplications, InterviewsScheduled, OffersExtended, OffersAccepted, ActiveContractors, PendingTimesheets)
        VALUES (DATEADD(DAY, -1, dbo.fn_BusinessToday()), 2, 1, 1, 0, 0, 2, 1);
        DECLARE @u INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'DIVYA.REDDY@CANDIDATE.EXAMPLE');
        INSERT doc.Documents (OwnerType, OwnerId, StoredFileName, OriginalFileName, ContentType, SizeBytes, Sha256, UploadedByUserId, IsDeleted, DeletedAt)
        VALUES ('Candidate', 1, @old, N'deleted long ago.pdf', N'application/pdf', 20, HASHBYTES('SHA2_256', @old), @u, 1, DATEADD(DAY, -40, SYSUTCDATETIME()));" @{ old = $docName }
    $oldMail = Join-Path $dirs.outbox 'old-message.eml'; Set-Content $oldMail 'old'; (Get-Item $oldMail).LastWriteTime = (Get-Date).AddDays(-40)
    $newMail = Join-Path $dirs.outbox 'recent-message.eml'; Set-Content $newMail 'recent'

    Write-Host "== Manual runs of TalentAcquisition.Scheduler.exe"
    $r = Run-Exe @('--check', '--settings', $settings)
    Check "M01 --check validates configuration, folders and database: exit 0" ($r.Code -eq 0 -and $r.Out -match "CHECK OK database=$Database") "$($r.Code) $($r.Out)"
    $r = Run-Exe @('list', '--settings', $settings)
    Check "M02 list shows the 7 tasks" ($r.Code -eq 0 -and ([regex]::Matches($r.Out, '(?m)^\S+-?\S*\s{2,}')).Count -ge 7 -and $r.Out -match 'file-housekeeping') $r.Out
    $a = Run-Exe @('run', 'drop-tables', '--settings', $settings); $b = Run-Exe @('--settings', $settings)
    Check "M03 an unknown task or no command: exit 64 (usage)" ($a.Code -eq 64 -and $b.Code -eq 64) "$($a.Code)/$($b.Code)"
    $bad = "$work\bad.json"; Write-Settings $bad @{ TaskRetryAttempts = 0 }
    $a = Run-Exe @('run', 'offer-reminders', '--settings', $bad); $b = Run-Exe @('run', 'offer-reminders', '--settings', "$work\missing.json")
    Check "M04 invalid configuration or a missing settings file: exit 2 with the reason" ($a.Code -eq 2 -and $a.Out -match 'TaskRetryAttempts' -and $b.Code -eq 2) "$($a.Code)/$($b.Code) $($a.Out)"
    $down = "$work\down.json"; Write-Settings $down @{ ConnectionString = "Server=localhost,1;Database=$Database;Integrated Security=SSPI;Connect Timeout=2"; TaskRetryAttempts = 2 }
    $t0 = Get-Date; $a = Run-Exe @('run', 'offer-reminders', '--settings', $down); $secs = ((Get-Date) - $t0).TotalSeconds
    Check "M05 database unreachable: retried with back-off (logged), then exit 3" ($a.Code -eq 3 -and $a.Out -match 'retrying' -and $secs -ge 2) "$($a.Code) after $([int]$secs)s"

    $expect = @(
        @{ Cmd = 'interview-reminders'; Job = 'Interview reminders'; Min = 1 },
        @{ Cmd = 'offer-reminders'; Job = 'Offer expiry reminders'; Min = 1 },
        @{ Cmd = 'timesheet-reminders'; Job = 'Timesheet reminders'; Min = 0 },
        @{ Cmd = 'contract-expiry-notices'; Job = 'Contract expiry notifications'; Min = 3 },
        @{ Cmd = 'daily-report'; Job = 'Daily report delivery'; Min = 3 }
    )
    $queued = 0
    foreach ($e in $expect) {
        $r = Run-Exe @('run', $e.Cmd, '--settings', $settings); $l = LastRun $e.Job
        $queued += [int]$l.RowsAffected
        Check ("M06 run {0}: exit 0, recorded Succeeded with {1}+ message(s) queued" -f $e.Cmd, $e.Min) ($r.Code -eq 0 -and $l.Outcome -eq 'Succeeded' -and [int]$l.RowsAffected -ge $e.Min) "$($r.Code) $($l.Outcome) rows=$($l.RowsAffected)"
    }
    $before = @(Get-ChildItem $dirs.outbox -Filter *.eml).Count
    $r = Run-Exe @('run', 'process-notifications', '--settings', $settings); $l = LastRun 'Email queue processing'
    $after = @(Get-ChildItem $dirs.outbox -Filter *.eml).Count
    Check "M07 process-notifications: exit 0, the queued reminders are written as .eml files" ($r.Code -eq 0 -and $l.Outcome -eq 'Succeeded' -and ($after - $before) -ge $queued -and $queued -gt 0) "queued=$queued new files=$($after - $before)"

    $r = Run-Exe @('run', 'file-housekeeping', '--settings', $settings); $l = LastRun 'File housekeeping'
    $purged = Get-TamsScalar $d "SELECT COUNT(*) FROM doc.Documents WHERE StoredFileName = @n AND FilePurgedAt IS NOT NULL" @{ n = $docName }
    $okFiles = -not (Test-Path (Join-Path $dirs.docs "$($docName.Substring(0,2))\$docName")) -and (Test-Path (Join-Path $dirs.docbak "$($liveName.Substring(0,2))\$liveName")) `
               -and -not (Test-Path (Join-Path $dirs.docbak "$($docName.Substring(0,2))\$docName")) -and -not (Test-Path $oldMail) -and (Test-Path $newMail)
    Check "M08 file-housekeeping: the 40-day-old deleted document's file is removed (and marked), the old e-mail file deleted, the recent one kept, the store copied to the backup folder" `
        ($r.Code -eq 0 -and $l.Outcome -eq 'Succeeded' -and $purged -eq 1 -and $okFiles) "$($r.Code) $($l.Outcome) purged=$purged files=$okFiles"

    # ---- duplicate-run prevention
    $sem = New-Object System.Threading.Semaphore(1, 1, "Global\TAMS.Scheduler.$Database.process-notifications")
    [void]$sem.WaitOne(0)
    $runsBefore = Get-TamsScalar $d "SELECT COUNT(*) FROM sched.JobExecutionHistory h JOIN sched.JobDefinitions d ON d.JobDefinitionId = h.JobDefinitionId WHERE d.JobName = N'Email queue processing'"
    $r = Run-Exe @('run', 'process-notifications', '--settings', $settings)
    [void]$sem.Release(); $sem.Dispose()
    $runsAfter = Get-TamsScalar $d "SELECT COUNT(*) FROM sched.JobExecutionHistory h JOIN sched.JobDefinitions d ON d.JobDefinitionId = h.JobDefinitionId WHERE d.JobName = N'Email queue processing'"
    Check "M09 a second copy on the same machine exits at once (exit 0) without starting a run" ($r.Code -eq 0 -and $r.Out -match 'another copy' -and $runsAfter -eq $runsBefore) "$($r.Code) runs $runsBefore->$runsAfter"
    Invoke-TamsNonQuery $d "INSERT sched.JobExecutionHistory (JobDefinitionId, HostName) SELECT JobDefinitionId, N'OTHER-PC' FROM sched.JobDefinitions WHERE JobName = N'Daily report delivery'"
    $r = Run-Exe @('run', 'daily-report', '--settings', $settings); $l = LastRun 'Daily report delivery'
    Invoke-TamsNonQuery $d "UPDATE sched.JobExecutionHistory SET Outcome = 'Failed', FinishedAt = SYSUTCDATETIME(), ErrorMessage = N'test lease released' WHERE HostName = N'OTHER-PC' AND Outcome = 'Running'"
    Check "M10 while another machine holds the job's lease the run is Skipped (exit 0) and names that machine" ($r.Code -eq 0 -and $l.Outcome -eq 'Skipped' -and $l.ErrorMessage -match 'OTHER-PC') "$($r.Code) $($l.Outcome) $($l.ErrorMessage)"

    # ---- failure
    Invoke-TamsNonQuery $d "DELETE FROM report.DailyRecruitmentSummary WHERE SummaryDate = DATEADD(DAY, -1, dbo.fn_BusinessToday())"
    $r = Run-Exe @('run', 'daily-report', '--settings', $settings); $l = LastRun 'Daily report delivery'
    $notified = Get-TamsScalar $d "SELECT COUNT(*) FROM notify.NotificationQueue WHERE TemplateCode = 'JOB_FAILED' AND RelatedEntityId = @x" @{ x = [int]$l.ExecutionId }
    Check "M11 a failing task (no summary prepared by SQL Agent): exit 1, recorded Failed with the reason, administrators notified" ($r.Code -eq 1 -and $l.Outcome -eq 'Failed' -and $l.ErrorMessage -match 'Prepare daily recruitment summary' -and $notified -ge 1) "$($r.Code) $($l.Outcome) notified=$notified"

    $json = Get-ChildItem $dirs.logs -Filter 'scheduler-*.jsonl' | Get-Content | ForEach-Object { $_ | ConvertFrom-Json }
    $ok = @($json | Where-Object { $_.task -eq 'daily-report' -and $_.outcome -eq 'Failed' -and $_.run -and $_.error }).Count -ge 1 -and @($json | Where-Object { $_.msg -eq 'succeeded' -and $_.rows -ne $null }).Count -ge 5
    Check "M12 structured log: JSON lines with time, level, task, run, outcome, row counts and the error" $ok "entries=$(@($json).Count)"

    # ---- Windows Task Scheduler
    Write-Host "== Registering the tasks in $taskPath (pointing at the copy) and starting them through Task Scheduler"
    Invoke-TamsNonQuery $d "INSERT report.DailyRecruitmentSummary (SummaryDate, OpenRequisitions, NewApplications, InterviewsScheduled, OffersExtended, OffersAccepted, ActiveContractors, PendingTimesheets)
                            VALUES (DATEADD(DAY, -1, dbo.fn_BusinessToday()), 2, 1, 1, 0, 0, 2, 1);
                            UPDATE TOP (1) cand.Interviews SET Status = 'Scheduled', StartsAt = DATEADD(HOUR, 9, SYSUTCDATETIME()), EndsAt = DATEADD(HOUR, 10, SYSUTCDATETIME()) WHERE JobApplicationId IS NOT NULL;"
    & (Join-Path $root 'scripts\scheduler\Register-ScheduledTasks.ps1') -TaskPath $taskPath -SettingsFile $settings | Out-Null
    $tasks = @(Get-ScheduledTask -TaskPath $taskPath)
    $t1 = $tasks | Where-Object TaskName -eq 'Email queue processing'
    Check "S01 seven tasks registered: hidden wscript launcher, current user only while signed in, no overlapping instances, 30-minute limit" `
        ($tasks.Count -eq 7 -and $t1.Actions[0].Execute -like '*wscript.exe' -and $t1.Actions[0].Arguments -match 'run-hidden\.vbs' -and $t1.Principal.LogonType -eq 'Interactive' `
         -and $t1.Settings.MultipleInstances -eq 'IgnoreNew' -and $t1.Settings.ExecutionTimeLimit -eq 'PT30M') "count=$($tasks.Count)"

    function Start-AndWait([string]$name) {
        $before = (Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName $name).LastRunTime
        Start-ScheduledTask -TaskPath $taskPath -TaskName $name
        $deadline = (Get-Date).AddSeconds(120)
        do { Start-Sleep -Milliseconds 800; $i = Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName $name; $st = (Get-ScheduledTask -TaskPath $taskPath -TaskName $name).State }
        while (($i.LastRunTime -le $before -or $st -eq 'Running' -or $i.LastTaskResult -eq 267009) -and (Get-Date) -lt $deadline)   # 267009 = 0x41301 SCHED_S_TASK_RUNNING, reported until the result is stored
        return $i
    }
    $map = @{ 'Interview reminders' = 'Interview reminders'; 'Offer expiry reminders' = 'Offer expiry reminders'; 'Timesheet reminders' = 'Timesheet reminders'
              'Contract expiry notifications' = 'Contract expiry notifications'; 'Daily report delivery' = 'Daily report delivery'; 'File housekeeping' = 'File housekeeping'; 'Email queue processing' = 'Email queue processing' }
    $host_ = $env:COMPUTERNAME
    foreach ($name in 'Interview reminders', 'Offer expiry reminders', 'Timesheet reminders', 'Contract expiry notifications', 'Daily report delivery', 'Email queue processing', 'File housekeeping') {
        $runsBefore = Get-TamsScalar $d "SELECT COUNT(*) FROM sched.JobExecutionHistory h JOIN sched.JobDefinitions d ON d.JobDefinitionId = h.JobDefinitionId WHERE d.JobName = @j AND h.Outcome IN ('Succeeded', 'Skipped')" @{ j = $map[$name] }
        $i = Start-AndWait $name; $l = LastRun $map[$name]
        $runsAfter = Get-TamsScalar $d "SELECT COUNT(*) FROM sched.JobExecutionHistory h JOIN sched.JobDefinitions d ON d.JobDefinitionId = h.JobDefinitionId WHERE d.JobName = @j AND h.Outcome IN ('Succeeded', 'Skipped')" @{ j = $map[$name] }
        Check ("S02 Task Scheduler ran '{0}': Last Run Result 0, a new run recorded in TAMS from this machine" -f $name) ($i.LastTaskResult -eq 0 -and $runsAfter -gt $runsBefore -and $l.HostName -eq $host_) "result=$($i.LastTaskResult) runs $runsBefore->$runsAfter host=$($l.HostName) outcome=$($l.Outcome)"
    }
    Invoke-TamsNonQuery $d "DELETE FROM report.DailyRecruitmentSummary WHERE SummaryDate = DATEADD(DAY, -1, dbo.fn_BusinessToday())"
    $i = Start-AndWait 'Daily report delivery'; $l = LastRun 'Daily report delivery'
    Check "S03 a failing task shows Last Run Result 1 in Task Scheduler and Failed in TAMS" ($i.LastTaskResult -eq 1 -and $l.Outcome -eq 'Failed') "result=$($i.LastTaskResult) outcome=$($l.Outcome)"
    $i = Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName 'Email queue processing'
    Check "S04 the repeating task has its next run scheduled within 5 minutes" ($i.NextRunTime -gt (Get-Date) -and $i.NextRunTime -le (Get-Date).AddMinutes(5).AddSeconds(5)) "next=$($i.NextRunTime)"
}
finally {
    if (-not $Keep) {
        Write-Host "== Cleaning up"
        & (Join-Path $root 'scripts\scheduler\Unregister-ScheduledTasks.ps1') -TaskPath $taskPath | Out-Null
        $left = @(Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue).Count
        $d.Close()
        $m = New-TamsConnection -Server $Server
        Invoke-TamsNonQuery $m "IF DB_ID(@n) IS NOT NULL BEGIN DECLARE @s NVARCHAR(400) = N'ALTER DATABASE ' + QUOTENAME(@n) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@n) + N';'; EXEC (@s); END" @{ n = $Database }
        $m.Close()
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "   tasks left in ${taskPath}: $left; copy dropped; temporary folder removed"
        Check "Z01 cleanup: no test tasks left" ($left -eq 0)
    }
}
$failed = @($results | Where-Object { -not $_.Ok }).Count
Write-Host ("--- Scheduled task tests: {0} passed, {1} failed, {2} total ---" -f ($results.Count - $failed), $failed, $results.Count)
if ($failed -gt 0) { exit 1 } else { exit 0 }
