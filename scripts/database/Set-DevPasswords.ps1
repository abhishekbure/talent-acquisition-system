<#
.SYNOPSIS
  Gives every seeded development user a random password. Only a PBKDF2-SHA256 hash
  (210,000 iterations) and a per-user salt are written to the database. The plaintext
  passwords are written ONCE to an untracked local file (default: dev-credentials.local.md
  in the project root, which .gitignore excludes). Nothing is printed to the console.

  By default only users that still have the unusable seed placeholder hash are updated, so
  re-running does not rotate passwords. Use -Rotate to reset every dev user.
#>
[CmdletBinding()]
param(
    [string]$Server = 'localhost',
    [string]$DatabaseName = 'TalentAcquisitionDB',
    [string]$OutFile = (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 'dev-credentials.local.md'),
    [switch]$Rotate
)
$ErrorActionPreference = 'Stop'
$iterations = 210000
$alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#%+'.ToCharArray()
$rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider

function New-RandomPassword([int]$len = 16) {
    $bytes = New-Object byte[] ($len * 2); $rng.GetBytes($bytes)
    -join (1..$len | ForEach-Object { $alphabet[$bytes[$_] % $alphabet.Length] })
}

$conn = New-Object System.Data.SqlClient.SqlConnection "Server=$Server;Database=$DatabaseName;Integrated Security=SSPI;TrustServerCertificate=True"
$conn.Open()
$sel = $conn.CreateCommand()
$sel.CommandText = @"
SELECT u.UserId, u.Email, u.DisplayName, STUFF((SELECT ', ' + r.RoleName FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId WHERE ur.UserId = u.UserId FOR XML PATH('')), 1, 2, '') AS Roles
FROM sec.Users u WHERE u.IsActive = 1 AND ($(if ($Rotate) { '1=1' } else { 'DATALENGTH(u.PasswordHash) <= 1' })) ORDER BY u.UserId
"@
$rows = @(); $rd = $sel.ExecuteReader(); while ($rd.Read()) { $rows += [pscustomobject]@{ Id = $rd.GetInt32(0); Email = $rd.GetString(1); Name = $rd.GetString(2); Roles = $rd.GetString(3) } }; $rd.Close()

if (-not $rows) { Write-Host 'No users need a password (use -Rotate to reset).'; $conn.Close(); exit 0 }

$lines = @('# TAMS development logins (LOCAL ONLY - never commit)', '',
           "Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') for database **$DatabaseName** on **$Server**.",
           'These are random development passwords. Only a salted PBKDF2 hash is stored in SQL Server.', '',
           '| Role | User | Email | Password |', '|---|---|---|---|')
$tx = $conn.BeginTransaction()
try {
    foreach ($u in $rows) {
        $pwd  = New-RandomPassword
        $salt = New-Object byte[] 32; $rng.GetBytes($salt)
        $kdf  = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pwd, $salt, $iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $hash = $kdf.GetBytes(32); $kdf.Dispose()
        $up = $conn.CreateCommand(); $up.Transaction = $tx
        $up.CommandText = 'UPDATE sec.Users SET PasswordHash=@h, PasswordSalt=@s, HashIterations=@i, FailedLoginCount=0, LockoutUntil=NULL, UpdatedAt=SYSUTCDATETIME() WHERE UserId=@id'
        $pH  = $up.Parameters.Add('@h',  [Data.SqlDbType]::VarBinary, 64); $pH.Value  = $hash
        $pS  = $up.Parameters.Add('@s',  [Data.SqlDbType]::VarBinary, 32); $pS.Value  = $salt
        $pI  = $up.Parameters.Add('@i',  [Data.SqlDbType]::Int);           $pI.Value  = $iterations
        $pUid = $up.Parameters.Add('@id', [Data.SqlDbType]::Int);          $pUid.Value = $u.Id
        [void]$up.ExecuteNonQuery()
        $lines += "| $($u.Roles) | $($u.Name) | $($u.Email) | ``$pwd`` |"
    }
    $tx.Commit()
} catch { $tx.Rollback(); $conn.Close(); throw }
$conn.Close()
Set-Content -Path $OutFile -Value $lines -Encoding UTF8
Write-Host "Passwords set for $($rows.Count) user(s). Credentials written to: $OutFile (untracked, local only)."
