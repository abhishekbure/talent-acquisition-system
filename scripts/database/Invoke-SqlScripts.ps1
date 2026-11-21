<#
.SYNOPSIS
  Runs TAMS T-SQL scripts (split on GO) against a SQL Server instance using .NET SqlClient
  with Windows authentication. No sqlcmd dependency.

.PARAMETER Server        Instance, default 'localhost' (default local instance). LocalDB: '(localdb)\MSSQLLocalDB'.
.PARAMETER DatabaseName  Replaces the literal 'TalentAcquisitionDB' in every script (default: unchanged).
.PARAMETER Path          One or more .sql files or folders (folders: all *.sql in name order).
.PARAMETER StopOnError   Default true. Aborts at the first failing batch.

Prints PRINT/RAISERROR messages. Exit code 0 = all batches succeeded.
Nothing here drops databases or tables.
#>
[CmdletBinding()]
param(
    [string]$Server = 'localhost',
    [string]$DatabaseName = 'TalentAcquisitionDB',
    [Parameter(Mandatory)][string[]]$Path,
    [bool]$StopOnError = $true,
    [int]$CommandTimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'

$files = foreach ($p in $Path) {
    if (Test-Path $p -PathType Container) { Get-ChildItem $p -Filter *.sql -File | Sort-Object Name }
    else { Get-Item $p }
}

$cs = "Server=$Server;Database=master;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=30"
$conn = New-Object System.Data.SqlClient.SqlConnection $cs
$conn.FireInfoMessageEventOnUserErrors = $false
$handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] { param($s, $e) foreach ($m in $e.Errors) { Write-Host "   [sql] $($m.Message)" } }
$conn.add_InfoMessage($handler)
$conn.Open()

$failed = 0; $batches = 0
foreach ($f in $files) {
    $shown = if ($f.FullName.IndexOf('database') -ge 0) { $f.FullName.Substring($f.FullName.IndexOf('database')) } else { $f.Name }
    Write-Host "== $shown" -ForegroundColor Cyan
    $text = [IO.File]::ReadAllText($f.FullName)
    if ($DatabaseName -ne 'TalentAcquisitionDB') { $text = $text.Replace('TalentAcquisitionDB', $DatabaseName) }
    $parts = [regex]::Split($text, '^\s*GO\s*(--.*)?$', [Text.RegularExpressions.RegexOptions]::Multiline -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    foreach ($b in $parts) {
        if ($b -match '^\s*--' -and $b.Trim().Split("`n").Count -eq 1) { continue }
        if ([string]::IsNullOrWhiteSpace($b)) { continue }
        $cmd = $conn.CreateCommand(); $cmd.CommandText = $b; $cmd.CommandTimeout = $CommandTimeoutSeconds
        try { [void]$cmd.ExecuteNonQuery(); $batches++ }
        catch {
            $failed++
            $inner = $_.Exception.InnerException
            Write-Host "   FAILED: $($inner.Message)" -ForegroundColor Red
            if ($inner -is [System.Data.SqlClient.SqlException]) {
                foreach ($er in $inner.Errors) { Write-Host "   (SQL error $($er.Number), line $($er.LineNumber) of the batch, proc '$($er.Procedure)')" -ForegroundColor Red }
                $lines = $b -split "`r?`n"
                $ln = $inner.Errors[0].LineNumber
                if ($ln -ge 1 -and $ln -le $lines.Count) { Write-Host "   >> $($lines[$ln - 1].Trim())" -ForegroundColor Red }
            }
            Write-Host "   Batch starts: $(($b.Trim() -split "`n")[0..2] -join ' | ')" -ForegroundColor DarkRed
            if ($StopOnError) { $conn.Close(); exit 1 }
        }
    }
}
$conn.Close()
Write-Host "Done. Batches executed: $batches, failed: $failed" -ForegroundColor ($(if ($failed) {'Red'} else {'Green'}))
if ($failed) { exit 1 } else { exit 0 }
