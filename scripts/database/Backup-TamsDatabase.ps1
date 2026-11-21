<#
.SYNOPSIS
  Phase 15: takes an on-demand full backup of TalentAcquisitionDB (or another database) and verifies it.
.DESCRIPTION
  BACKUP ... WITH COPY_ONLY, COMPRESSION, CHECKSUM into SQL Server's default backup folder (the SQL Server service account
  can always write there), file name <database>_<yyyyMMdd_HHmmss>.bak, followed by RESTORE VERIFYONLY.
  COPY_ONLY: a manual backup never breaks the chain of the scheduled full/differential/log backups (SQL Server Agent jobs).
  The database is only read. Prints the backup file path; restore it with Restore-TamsDatabase.ps1.
.EXAMPLE
  .\scripts\database\Backup-TamsDatabase.ps1
#>
[CmdletBinding()]
param([string]$Server = 'localhost', [string]$DatabaseName = 'TalentAcquisitionDB', [string]$Folder)
$ErrorActionPreference = 'Stop'
if ($DatabaseName -notmatch '^[A-Za-z0-9_]{1,100}$') { throw 'Invalid database name.' }
. "$PSScriptRoot\TamsSql.ps1"
$c = New-TamsConnection -Server $Server
try {
    if ($null -eq (Get-TamsScalar $c "SELECT DB_ID(@n)" @{ n = $DatabaseName })) { throw "Database $DatabaseName does not exist." }
    if (-not $Folder) { $Folder = Get-TamsScalar $c "SELECT CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS NVARCHAR(400))" }
    $file = Join-Path $Folder ("{0}_{1}.bak" -f $DatabaseName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-TamsNonQuery $c "BACKUP DATABASE [$DatabaseName] TO DISK = @f WITH COPY_ONLY, INIT, COMPRESSION, CHECKSUM, NAME = N'$DatabaseName on-demand backup (Backup-TamsDatabase.ps1)';" @{ f = $file }
    Invoke-TamsNonQuery $c "RESTORE VERIFYONLY FROM DISK = @f WITH CHECKSUM;" @{ f = $file }
    $info = (Invoke-TamsQuery $c "SELECT TOP 1 CAST(compressed_backup_size / 1048576.0 AS DECIMAL(10,1)) mb, backup_finish_date FROM msdb.dbo.backupset b JOIN msdb.dbo.backupmediafamily f ON f.media_set_id = b.media_set_id WHERE f.physical_device_name = @f ORDER BY b.backup_set_id DESC" @{ f = $file }).Rows[0]
    Write-Host ("Backup of {0} written and verified in {1:n1} s ({2} MB compressed):" -f $DatabaseName, $sw.Elapsed.TotalSeconds, $info.mb) -ForegroundColor Green
    Write-Host "  $file"
    Write-Host "Restore it with: .\scripts\database\Restore-TamsDatabase.ps1 -BackupFile `"$file`" -DatabaseName <new name>"
    $file
}
finally { $c.Close() }
