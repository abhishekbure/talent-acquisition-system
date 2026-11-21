<#
.SYNOPSIS
  Backs up a database (FULL, COMPRESSION, CHECKSUM), verifies the backup and RESTOREs it under another name.
  Used to create a disposable copy for concurrency / performance tests, and as the backup-and-restore demonstration.
  Never touches the source data and refuses to overwrite an existing target unless -Force is given.
#>
[CmdletBinding()]
param(
    [string]$Server = 'localhost',
    [string]$Source = 'TalentAcquisitionDB',
    [Parameter(Mandatory)][string]$Target,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\TamsSql.ps1"
$c = New-TamsConnection -Server $Server
try {
    if ($Target -eq $Source) { throw 'Target must differ from Source.' }
    if ($null -ne (Get-TamsScalar $c "SELECT DB_ID(@n)" @{ n = $Target })) {
        if (-not $Force) { throw "Database $Target already exists. Use -Force to replace this disposable copy." }
        Invoke-TamsNonQuery $c "ALTER DATABASE [$Target] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$Target];"
    }
    $bkDir  = Get-TamsScalar $c "SELECT CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS NVARCHAR(400))"
    $dataDir = Get-TamsScalar $c "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(400))"
    $logDir = Get-TamsScalar $c "SELECT CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS NVARCHAR(400))"
    $bak = Join-Path $bkDir "$Source`_copy_source.bak"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # COPY_ONLY: a test copy's backup must never become the base of the scheduled differential/log backups (Phase 11)
    Invoke-TamsNonQuery $c "BACKUP DATABASE [$Source] TO DISK = N'$bak' WITH COPY_ONLY, INIT, COMPRESSION, CHECKSUM, STATS = 100, NAME = N'$Source copy source';"
    Write-Host ("  backup   : {0} ({1} ms)" -f $bak, $sw.ElapsedMilliseconds)
    Invoke-TamsNonQuery $c "RESTORE VERIFYONLY FROM DISK = N'$bak' WITH CHECKSUM;"
    Write-Host '  verify   : RESTORE VERIFYONLY with CHECKSUM succeeded'
    $files = Invoke-TamsQuery $c "RESTORE FILELISTONLY FROM DISK = N'$bak';"
    $moves = @()
    foreach ($f in $files.Rows) {
        $ext = if ($f['Type'] -eq 'L') { '.ldf' } else { '.mdf' }
        $dir = if ($f['Type'] -eq 'L') { $logDir } else { $dataDir }
        $moves += "MOVE N'$($f['LogicalName'])' TO N'$(Join-Path $dir ($Target + '_' + $f['LogicalName'] + $ext))'"
    }
    $sw.Restart()
    Invoke-TamsNonQuery $c ("RESTORE DATABASE [$Target] FROM DISK = N'$bak' WITH " + ($moves -join ', ') + ", RECOVERY, STATS = 100;")
    Write-Host ("  restore  : {0} ({1} ms)" -f $Target, $sw.ElapsedMilliseconds)
    $q = "SELECT (SELECT COUNT(*) FROM [{0}].cand.Candidates) c, (SELECT COUNT(*) FROM [{0}].bill.Invoices) i, (SELECT COUNT(*) FROM [{0}].audit.AuditLogs) a"
    $s = Invoke-TamsQuery $c ($q -f $Source); $t = Invoke-TamsQuery $c ($q -f $Target)
    $same = ($s.Rows[0].c -eq $t.Rows[0].c) -and ($s.Rows[0].i -eq $t.Rows[0].i) -and ($s.Rows[0].a -eq $t.Rows[0].a)
    Write-Host ("  compare  : source candidates/invoices/audit = {0}/{1}/{2}; copy = {3}/{4}/{5} => {6}" -f $s.Rows[0].c, $s.Rows[0].i, $s.Rows[0].a, $t.Rows[0].c, $t.Rows[0].i, $t.Rows[0].a, $(if ($same) { 'IDENTICAL' } else { 'DIFFERENT' }))
    if (-not $same) { throw 'The restored copy does not match the source.' }
}
finally { $c.Close() }
