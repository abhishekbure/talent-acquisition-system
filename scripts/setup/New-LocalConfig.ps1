<#
.SYNOPSIS
  Creates backend\TalentAcquisition.API\appsettings.local.json with a freshly generated 64-byte JWT signing secret.
  The file is git-ignored (*.local.*) and is copied next to the API executable at build time.
  Refuses to overwrite an existing file unless -Force (rotating the secret logs everybody out).
#>
[CmdletBinding()]
param([switch]$Force, [string]$ConnectionString)
$ErrorActionPreference = 'Stop'
$target = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 'backend\TalentAcquisition.API\appsettings.local.json'
if ((Test-Path $target) -and -not $Force) { Write-Host "Exists: $target (use -Force to rotate the secret)"; exit 0 }
$bytes = New-Object byte[] 64
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$cfg = [ordered]@{ JwtSecret = [Convert]::ToBase64String($bytes) }
if ($ConnectionString) { $cfg.ConnectionString = $ConnectionString }
($cfg | ConvertTo-Json) | Set-Content -Path $target -Encoding UTF8
Write-Host "Written: $target (secret not displayed)"
