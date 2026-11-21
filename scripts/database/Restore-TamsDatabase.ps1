<#
.SYNOPSIS
  Phase 15: restores a TAMS backup (.bak), by default under a NEW database name so nothing existing is touched.
.DESCRIPTION
  1. RESTORE VERIFYONLY WITH CHECKSUM - an unreadable or damaged backup is refused before anything happens.
  2. If the target database exists, the script STOPS unless -Replace is given. With -Replace it first takes a COPY_ONLY safety
     backup of the database being overwritten (path printed), closes its connections and restores WITH REPLACE.
     Overwriting TalentAcquisitionDB additionally requires typing its name when asked (or -Confirm:$false in automation).
  3. Restores with MOVE to <data folder>\<target>_<logical name>.mdf/.ldf, so a copy never collides with the original's files.
  4. Checks the result: online, the least-privilege database users and roles present, row counts of key tables.
  The application, SQL Server Agent jobs and Task Scheduler tasks use TalentAcquisitionDB; a copy under another name is for
  inspection or testing (point an API at it with: TalentAcquisition.API.exe --settings <file with ConnectionString>).
.EXAMPLE
  .\scripts\database\Restore-TamsDatabase.ps1 -BackupFile 'C:\...\Backup\TalentAcquisitionDB_20261120_230000.bak' -DatabaseName TalentAcquisitionDB_Restored
.EXAMPLE
  .\scripts\database\Restore-TamsDatabase.ps1 -BackupFile 'C:\...\Backup\TalentAcquisitionDB_20261120_230000.bak' -DatabaseName TalentAcquisitionDB -Replace
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$Server = 'localhost',
    [Parameter(Mandatory)][string]$BackupFile,
    [string]$DatabaseName = 'TalentAcquisitionDB_Restored',
    [switch]$Replace
)
$ErrorActionPreference = 'Stop'
if ($DatabaseName -notmatch '^[A-Za-z0-9_]{1,100}$') { throw 'Invalid database name.' }
. "$PSScriptRoot\TamsSql.ps1"
$c = New-TamsConnection -Server $Server
try {
    Write-Host "== Verifying $BackupFile"
    Invoke-TamsNonQuery $c "RESTORE VERIFYONLY FROM DISK = @f WITH CHECKSUM;" @{ f = $BackupFile }
    $hdr = (Invoke-TamsQuery $c "RESTORE HEADERONLY FROM DISK = @f;" @{ f = $BackupFile }).Rows[0]
    Write-Host ("   backup of {0}, taken {1}, SQL Server {2}.{3}" -f $hdr.DatabaseName, $hdr.BackupFinishDate, $hdr.SoftwareVersionMajor, $hdr.SoftwareVersionMinor)

    $exists = $null -ne (Get-TamsScalar $c "SELECT DB_ID(@n)" @{ n = $DatabaseName })
    if ($exists) {
        if (-not $Replace) { throw "Database $DatabaseName already exists and was NOT changed. Restore under another name (-DatabaseName), or add -Replace to overwrite it (its current data is lost; a safety backup is taken first)." }
        if (-not $PSCmdlet.ShouldProcess($DatabaseName, 'Overwrite with the backup (current data is replaced)')) { throw 'Cancelled; nothing was changed.' }
        if ($DatabaseName -eq 'TalentAcquisitionDB' -and $ConfirmPreference -ne 'None' -and -not $PSBoundParameters.ContainsKey('Confirm')) {
            $typed = Read-Host "Type TalentAcquisitionDB to confirm that the development database will be overwritten"
            if ($typed -cne 'TalentAcquisitionDB') { throw 'Not confirmed; nothing was changed.' }
        }
        $safety = & "$PSScriptRoot\Backup-TamsDatabase.ps1" -Server $Server -DatabaseName $DatabaseName | Select-Object -Last 1
        Write-Host "   safety backup of the current $DatabaseName : $safety" -ForegroundColor Yellow
        Invoke-TamsNonQuery $c "ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;"
    }
    $dataDir = Get-TamsScalar $c "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(400))"
    $logDir = Get-TamsScalar $c "SELECT CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS NVARCHAR(400))"
    $moves = foreach ($f in (Invoke-TamsQuery $c "RESTORE FILELISTONLY FROM DISK = @f;" @{ f = $BackupFile }).Rows) {
        $ext = if ($f['Type'] -eq 'L') { '.ldf' } else { '.mdf' }
        $dir = if ($f['Type'] -eq 'L') { $logDir } else { $dataDir }
        "MOVE N'$($f['LogicalName'].Replace("'", "''"))' TO N'$((Join-Path $dir ($DatabaseName + '_' + $f['LogicalName'] + $ext)).Replace("'", "''"))'"
    }
    Write-Host "== Restoring as $DatabaseName"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { Invoke-TamsNonQuery $c ("RESTORE DATABASE [$DatabaseName] FROM DISK = @f WITH " + ($moves -join ', ') + $(if ($exists) { ', REPLACE' } else { '' }) + ', RECOVERY;') @{ f = $BackupFile } }
    finally { if ($exists) { Invoke-TamsNonQuery $c "IF DB_ID(N'$DatabaseName') IS NOT NULL ALTER DATABASE [$DatabaseName] SET MULTI_USER;" } }
    Write-Host ("   restored in {0:n1} s" -f $sw.Elapsed.TotalSeconds)

    $d = New-TamsConnection -Server $Server -Database $DatabaseName
    try {
        $users = @((Invoke-TamsQuery $d "SELECT name FROM sys.database_principals WHERE name IN ('tams_app_demo','tams_worker_demo','tams_report_demo','tams_app_role','tams_worker_role','tams_report_role')").Rows | ForEach-Object { $_.name })
        $r = (Invoke-TamsQuery $d "SELECT DATABASEPROPERTYEX(DB_NAME(), 'Status') st, (SELECT COUNT(*) FROM sec.Users) u, (SELECT COUNT(*) FROM cand.Candidates) c, (SELECT COUNT(*) FROM bill.Invoices) i, (SELECT COUNT(*) FROM audit.AuditLogs) a").Rows[0]
        $ok = $r.st -eq 'ONLINE' -and $users.Count -eq 6
        Write-Host ("   {0}: {1}; least-privilege users and roles {2}/6; {3} users, {4} candidates, {5} invoices, {6} audit rows" -f $DatabaseName, $r.st, $users.Count, $r.u, $r.c, $r.i, $r.a) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
        if (-not $ok) { throw 'The restored database is incomplete.' }
    } finally { $d.Close() }
}
finally { $c.Close() }
