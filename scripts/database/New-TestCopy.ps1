<#
.SYNOPSIS
  Creates a DISPOSABLE copy of TalentAcquisitionDB for manual / browser end-to-end testing, so clicking through
  workflows never changes the development data.
  1. Copy-Database.ps1 (backup + verify + restore under -Target; the source is only read)
  2. sets ONE random test password on every user of the COPY (PBKDF2-SHA256, 210,000 iterations, per-user salt)
  3. writes that password to test-credentials.local.md in the project root (git-ignored; never printed)
  Refuses to touch TalentAcquisitionDB itself. Drop the copy afterwards with -Drop.
.EXAMPLE
  .\scripts\database\New-TestCopy.ps1 -Target TalentAcquisitionDB_UiCheck
  .\scripts\database\New-TestCopy.ps1 -Target TalentAcquisitionDB_UiCheck -Drop
#>
[CmdletBinding()]
param(
    [string]$Server = 'localhost',
    [Parameter(Mandatory)][string]$Target,
    [switch]$Drop
)
$ErrorActionPreference = 'Stop'
if ($Target -eq 'TalentAcquisitionDB' -or $Target -notmatch '^TalentAcquisitionDB_[A-Za-z0-9_]+$') { throw 'Target must be a disposable copy named TalentAcquisitionDB_<suffix>; the live database is never modified.' }
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
. "$PSScriptRoot\TamsSql.ps1"

if ($Drop) {
    $c = New-TamsConnection -Server $Server
    try { Invoke-TamsNonQuery $c "IF DB_ID(N'$Target') IS NOT NULL BEGIN ALTER DATABASE [$Target] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$Target]; END"; Write-Host "Dropped $Target" }
    finally { $c.Close() }
    return
}

& "$PSScriptRoot\Copy-Database.ps1" -Server $Server -Target $Target -Force

# random password that meets the policy (>= 10 chars, upper, lower, digit)
$alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$bytes = New-Object byte[] 14; $rng.GetBytes($bytes)
$pwd = 'Ui' + (-join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })) + '7a'

$cn = New-Object System.Data.SqlClient.SqlConnection("Server=$Server;Database=$Target;Integrated Security=SSPI;TrustServerCertificate=True")
$cn.Open()
try {
    $ids = New-Object System.Collections.Generic.List[int]
    $cmd = $cn.CreateCommand(); $cmd.CommandText = 'SELECT UserId FROM sec.Users'
    $rd = $cmd.ExecuteReader(); while ($rd.Read()) { $ids.Add($rd.GetInt32(0)) }; $rd.Close()
    foreach ($id in $ids) {
        $salt = New-Object byte[] 32; $rng.GetBytes($salt)
        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pwd, $salt, 210000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $hash = $kdf.GetBytes(32); $kdf.Dispose()
        $up = $cn.CreateCommand()
        $up.CommandText = 'UPDATE sec.Users SET PasswordHash=@h, PasswordSalt=@s, HashIterations=210000, FailedLoginCount=0, LockoutUntil=NULL WHERE UserId=@id'
        [void]$up.Parameters.Add('@h', [System.Data.SqlDbType]::VarBinary, 64); $up.Parameters['@h'].Value = $hash
        [void]$up.Parameters.Add('@s', [System.Data.SqlDbType]::VarBinary, 32); $up.Parameters['@s'].Value = $salt
        [void]$up.Parameters.Add('@id', [System.Data.SqlDbType]::Int); $up.Parameters['@id'].Value = $id
        [void]$up.ExecuteNonQuery()
    }
    Write-Host ("  passwords: set on {0} users of {1} (hash + salt only)" -f $ids.Count, $Target)
}
finally { $cn.Close() }

$file = Join-Path $root 'test-credentials.local.md'
@(
    "# Test credentials for the disposable database $Target",
    '',
    'Git-ignored. Valid ONLY in that copy (every user has this password there). Not a development or production credential.',
    '',
    "| Database | Password |",
    '|---|---|',
    "| $Target | ``$pwd`` |"
) | Set-Content -Path $file -Encoding utf8
Write-Host "  credentials: written to test-credentials.local.md (git-ignored)"
Write-Host "  start the API on it:  `$env:TAMS_CONNECTION_STRING='Server=$Server;Database=$Target;Integrated Security=SSPI;TrustServerCertificate=True'"
