<#
.SYNOPSIS
  Backup and restore demonstration including POINT-IN-TIME recovery, on disposable copies only:
  full backup -> normal change -> "accident" (mass update + delete) -> log backup -> restore full + log STOPAT just
  before the accident -> prove the restored copy has the good data while the damaged copy does not.
  Exit code 0 = every check passed.
#>
[CmdletBinding()]
param([string]$Server = 'localhost', [string]$Source = 'TalentAcquisitionDB', [string]$Damaged = 'TalentAcquisitionDB_PitrSource', [string]$Restored = 'TalentAcquisitionDB_PitrRestored')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\TamsSql.ps1"
$results = New-Object System.Collections.ArrayList
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') { [void]$results.Add($Ok); Write-Host ("{0}  {1}{2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $(if (-not $Ok -and $Detail) { "  -> $Detail" } else { '' })) }

Write-Host "== 1. restorable copy of the live database (full backup + VERIFYONLY + restore + row comparison)" -ForegroundColor Cyan
& "$PSScriptRoot\Copy-Database.ps1" -Server $Server -Source $Source -Target $Damaged -Force | Out-Host
$m = New-TamsConnection $Server
$d = New-TamsConnection $Server $Damaged
try {
    $bkDir = Get-TamsScalar $m "SELECT CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS NVARCHAR(400))"
    $dataDir = Get-TamsScalar $m "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(400))"
    $logDir = Get-TamsScalar $m "SELECT CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS NVARCHAR(400))"
    Check 'the database uses the FULL recovery model (required for log backups / point-in-time restore)' ((Get-TamsScalar $m "SELECT recovery_model_desc FROM sys.databases WHERE name = @n" @{ n = $Source }) -eq 'FULL')

    Write-Host "`n== 2. start a log chain: full backup of the working copy" -ForegroundColor Cyan
    $full = Join-Path $bkDir 'tams_pitr_full.bak'; $log = Join-Path $bkDir 'tams_pitr_log.trn'
    Invoke-TamsNonQuery $m "BACKUP DATABASE [$Damaged] TO DISK = N'$full' WITH INIT, COMPRESSION, CHECKSUM;"
    Check 'full backup taken (log chain started)' $true

    Write-Host "`n== 3. normal work, then an ACCIDENT" -ForegroundColor Cyan
    Invoke-TamsNonQuery $d "INSERT sched.JobDefinitions (JobName, Owner, Description) VALUES (N'PITR marker (good data)', 'SqlAgent', N'exists before the accident');"
    Start-Sleep -Seconds 2
    $good = [datetime](Get-TamsScalar $d 'SELECT SYSDATETIME()')          # server LOCAL time - this is what STOPAT expects
    Start-Sleep -Seconds 2
    Invoke-TamsNonQuery $d "UPDATE org.Customers SET Status = 'Inactive'; DELETE sched.JobDefinitions WHERE JobName = N'PITR marker (good data)';"
    Check 'damage done: every customer is Inactive and the marker row is gone' (((Get-TamsScalar $d "SELECT COUNT(*) FROM org.Customers WHERE Status = 'Active'") -eq 0) -and ((Get-TamsScalar $d "SELECT COUNT(*) FROM sched.JobDefinitions WHERE JobName = N'PITR marker (good data)'") -eq 0))
    Invoke-TamsNonQuery $m "BACKUP LOG [$Damaged] TO DISK = N'$log' WITH INIT, COMPRESSION, CHECKSUM;"
    Check 'transaction-log backup taken (contains both the good change and the accident)' $true

    Write-Host "`n== 4. restore: full (NORECOVERY) + log WITH STOPAT = just before the accident" -ForegroundColor Cyan
    if ($null -ne (Get-TamsScalar $m "SELECT DB_ID(@n)" @{ n = $Restored })) { Invoke-TamsNonQuery $m "ALTER DATABASE [$Restored] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$Restored];" }
    $files = Invoke-TamsQuery $m "RESTORE FILELISTONLY FROM DISK = N'$full';"
    $moves = foreach ($f in $files.Rows) { $ext = if ($f['Type'] -eq 'L') { '.ldf' } else { '.mdf' }; $dir = if ($f['Type'] -eq 'L') { $logDir } else { $dataDir }; "MOVE N'$($f['LogicalName'])' TO N'$(Join-Path $dir ($Restored + '_' + $f['LogicalName'] + $ext))'" }
    Invoke-TamsNonQuery $m ("RESTORE DATABASE [$Restored] FROM DISK = N'$full' WITH " + ($moves -join ', ') + ', NORECOVERY;')
    $stop = $good.ToString('yyyy-MM-ddTHH:mm:ss.fff')
    Invoke-TamsNonQuery $m "RESTORE LOG [$Restored] FROM DISK = N'$log' WITH STOPAT = '$stop', RECOVERY;"
    Write-Host "  restored to point in time $stop (server local time)"
    $rc = Get-TamsScalar $m "SELECT COUNT(*) FROM [$Restored].org.Customers WHERE Status = 'Active'"
    $rm = Get-TamsScalar $m "SELECT COUNT(*) FROM [$Restored].sched.JobDefinitions WHERE JobName = N'PITR marker (good data)'"
    Check 'POINT-IN-TIME: the restored database has all 3 customers Active again' ($rc -eq 3) "active=$rc"
    Check 'POINT-IN-TIME: ...and still contains the legitimate change made before the accident' ($rm -eq 1) "markerRows=$rm"
    Check 'the damaged copy still shows the accident (0 active customers), i.e. the restore was a separate, safe copy' ((Get-TamsScalar $d "SELECT COUNT(*) FROM org.Customers WHERE Status = 'Active'") -eq 0)
    $same = Invoke-TamsQuery $m "SELECT (SELECT COUNT(*) FROM [$Restored].cand.Candidates) c, (SELECT COUNT(*) FROM [$Source].cand.Candidates) s"
    Check 'the rest of the data is intact in the restored copy (candidates match the live database)' ($same.Rows[0].c -eq $same.Rows[0].s)
}
finally {
    foreach ($x in @($d, $m)) { try { $x.Close() } catch {} }
    [System.Data.SqlClient.SqlConnection]::ClearAllPools()
    $k = New-TamsConnection $Server
    try { foreach ($n in $Damaged, $Restored) { Invoke-TamsNonQuery $k "IF DB_ID(N'$n') IS NOT NULL BEGIN ALTER DATABASE [$n] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$n]; END" }; Write-Host '(disposable databases dropped)' } finally { $k.Close() }
}
$bad = @($results | Where-Object { -not $_ }).Count
Write-Host ("--- Backup/restore demo: {0} passed, {1} failed, {2} total ---" -f ($results.Count - $bad), $bad, $results.Count) -ForegroundColor $(if ($bad) { 'Red' } else { 'Green' })
if ($bad) { exit 1 } else { exit 0 }
