<#
.SYNOPSIS
  Phase 14: automated browser end-to-end tests. Real Angular app -> real Web API -> real SQL Server (no mocks).
.DESCRIPTION
  1. Copies TalentAcquisitionDB to TalentAcquisitionDB_E2E (the development database is only read).
  2. Sets ONE random password for every user of the COPY (never shown or stored; handed to the tests in memory).
  3. Writes a throwaway settings file (copy connection string, random JWT secret, temporary outbox / document store /
     backup / log folders, links pointing at the test UI, generous rate limits because the tests sign in often).
  4. Builds the PRODUCTION Angular bundle (ng build) into the temporary folder and starts TalentAcquisition.API.exe --settings on
     http://localhost:5080, which serves that bundle and the API on one address - exactly as the local deployment runs (Phase 15).
     -DevServer instead runs "ng serve" on http://localhost:4300 with a proxy to that API (the Phase 14 set-up).
  5. Runs Playwright (frontend\e2e, installed Chrome, one test at a time). The tests use the console app
     (TalentAcquisition.Scheduler.exe --settings) to deliver e-mail and run tasks, and sqlcmd for set-up and the database trail.
  6. Stops both servers, drops the copy and deletes the temporary folder, also after a failure (unless -Keep).
  Reports: tests\e2e\report (HTML, git-ignored) and tests\e2e\results.json. Exit code = Playwright's (0 = all passed).
.EXAMPLE
  .\scripts\testing\Run-E2E.ps1
  .\scripts\testing\Run-E2E.ps1 -Grep "staffing"       # only tests whose title matches
#>
[CmdletBinding()]
param([string]$Server = 'localhost', [string]$Database = 'TalentAcquisitionDB_E2E', [int]$ApiPort = 5080, [int]$UiPort = 4300,
      [string]$Grep, [switch]$Keep, [switch]$Headed, [switch]$DevServer)
$ErrorActionPreference = 'Stop'
if ($Database -notmatch '^TalentAcquisitionDB_[A-Za-z0-9_]+$') { throw 'Use a disposable copy named TalentAcquisitionDB_<suffix>.' }
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $root 'scripts\database\TamsSql.ps1')
$apiExe = Join-Path $root 'backend\TalentAcquisition.API\bin\Debug\net472\TalentAcquisition.API.exe'
$schedExe = Join-Path $root 'backend\TalentAcquisition.Scheduler\bin\Debug\net472\TalentAcquisition.Scheduler.exe'
foreach ($p in $apiExe, $schedExe) { if (-not (Test-Path $p)) { throw "Build the backend first (dotnet build .\backend\TalentAcquisition.sln): $p" } }

$work = Join-Path $env:TEMP ('tams-e2e-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$dirs = @{ outbox = "$work\outbox"; docs = "$work\documents"; docbak = "$work\document-backup"; logs = "$work\logs" }
$dirs.Values | ForEach-Object { New-Item -ItemType Directory -Force $_ | Out-Null }
$api = $null; $ui = $null; $exit = 1
try {
    Write-Host "== Copying TalentAcquisitionDB to $Database"
    & (Join-Path $root 'scripts\database\Copy-Database.ps1') -Server $Server -Target $Database -Force | Out-Null
    $c = New-TamsConnection -Server $Server -Database $Database
    Add-Type -Path (Join-Path $root 'backend\TalentAcquisition.Common\bin\Debug\net472\TalentAcquisition.Common.dll')
    $pw = 'E2e#' + [Guid]::NewGuid().ToString('N').Substring(0, 12) + 'Aa1'
    $h = $null; $s = $null; [TalentAcquisition.Common.PasswordHasher]::Hash($pw, [ref]$h, [ref]$s)
    Invoke-TamsNonQuery $c "UPDATE sec.Users SET PasswordHash = @h, PasswordSalt = @s, HashIterations = 210000, FailedLoginCount = 0, LockoutUntil = NULL" @{ h = $h; s = $s } | Out-Null
    $c.Close()

    $secret = New-Object byte[] 48; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($secret)
    $ui0 = if ($DevServer) { "http://localhost:$UiPort" } else { "http://localhost:$ApiPort" }
    if (-not $DevServer) {
        Write-Host '== Building the production web app (ng build)'
        Push-Location (Join-Path $root 'frontend')
        try { & npx ng build --output-path "$work\web" *> "$work\ui-build.txt"; if ($LASTEXITCODE -ne 0) { throw "ng build failed: $(Get-Content "$work\ui-build.txt" -Raw)" } } finally { Pop-Location }
    }
    $settings = [ordered]@{
        ConnectionString = "Server=$Server;Database=$Database;Integrated Security=SSPI;TrustServerCertificate=True;Application Name=TAMS.E2E;Connect Timeout=15"
        JwtSecret = [Convert]::ToBase64String($secret); ListenUrl = "http://localhost:$ApiPort/"; CorsOrigins = @($ui0)
        MailOutboxPath = $dirs.outbox; DocumentStorePath = $dirs.docs; DocumentBackupPath = $dirs.docbak; LogDirectory = $dirs.logs
        AppBaseUrl = $ui0; VerifyEmailLinkBase = "$ui0/verify-email"; ResetLinkBase = "$ui0/reset-password"
        RateLimitLoginPerMinute = 10000; RateLimitAccountPerMinute = 10000; RateLimitTokenPerMinute = 10000
        WebRoot = $(if ($DevServer) { '' } else { "$work\web\browser" })
    }
    $settingsFile = "$work\settings.json"
    [IO.File]::WriteAllText($settingsFile, ($settings | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
    $proxy = "$work\proxy.json"
    [IO.File]::WriteAllText($proxy, (@{ '/api' = @{ target = "http://localhost:$ApiPort"; secure = $false; changeOrigin = $false; logLevel = 'warn' } } | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding $false))

    Write-Host $(if ($DevServer) { "== Starting the API on port $ApiPort and ng serve on port $UiPort" } else { "== Starting the API with the production web app on port $ApiPort" })
    $api = Start-Process -FilePath $apiExe -ArgumentList @('--settings', "`"$settingsFile`"") -WorkingDirectory (Split-Path $apiExe) -WindowStyle Hidden -PassThru `
                         -RedirectStandardOutput "$work\api.out.txt" -RedirectStandardError "$work\api.err.txt"
    if ($DevServer) {
        $ui = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "npx ng serve --port $UiPort --proxy-config `"$proxy`" --no-open > `"$work\ui.out.txt`" 2>&1") `
                            -WorkingDirectory (Join-Path $root 'frontend') -WindowStyle Hidden -PassThru
    }
    function Wait-Url([string]$url, [int]$seconds) {
        $deadline = (Get-Date).AddSeconds($seconds)
        while ((Get-Date) -lt $deadline) { try { if ((Invoke-WebRequest -UseBasicParsing $url -TimeoutSec 3).StatusCode -eq 200) { return $true } } catch { Start-Sleep -Milliseconds 700 } }
        return $false
    }
    if (-not (Wait-Url "http://localhost:$ApiPort/api/v1/health" 60)) { throw "The API did not start: $(Get-Content "$work\api.err.txt" -Raw)" }
    if (-not (Wait-Url "$ui0/login" 180)) { throw "The web app did not start: $(if ($DevServer) { Get-Content "$work\ui.out.txt" -Raw } else { Get-Content "$work\api.err.txt" -Raw })" }
    if (-not (Wait-Url "$ui0/api/v1/health" 30)) { throw 'The web app does not proxy to the API.' }

    Write-Host '== Running Playwright'
    $env:TAMS_E2E_PASSWORD = $pw; $pw = $null
    $env:TAMS_E2E_BASEURL = $ui0; $env:TAMS_E2E_DB = $Database; $env:TAMS_E2E_SERVER = $Server
    $env:TAMS_E2E_OUTBOX = $dirs.outbox; $env:TAMS_E2E_SETTINGS = $settingsFile; $env:TAMS_E2E_SCHEDULER = $schedExe
    $args2 = @('playwright', 'test'); if ($Grep) { $args2 += @('--grep', $Grep) }; if ($Headed) { $args2 += '--headed' }
    Push-Location (Join-Path $root 'frontend')
    try { & npx @args2; $exit = $LASTEXITCODE } finally { Pop-Location }
}
finally {
    foreach ($n in 'TAMS_E2E_PASSWORD', 'TAMS_E2E_BASEURL', 'TAMS_E2E_DB', 'TAMS_E2E_SERVER', 'TAMS_E2E_OUTBOX', 'TAMS_E2E_SETTINGS', 'TAMS_E2E_SCHEDULER') { Remove-Item "Env:\$n" -ErrorAction SilentlyContinue }
    if ($ui -and -not $ui.HasExited) { & taskkill.exe /PID $ui.Id /T /F 2>&1 | Out-Null }
    if ($api -and -not $api.HasExited) { Stop-Process -Id $api.Id -Force }
    if (-not $Keep) {
        $m = New-TamsConnection -Server $Server
        try { Invoke-TamsNonQuery $m "IF DB_ID(N'$Database') IS NOT NULL BEGIN ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$Database]; END" | Out-Null } finally { $m.Close() }
        Start-Sleep -Milliseconds 500
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
        Write-Host "== Dropped $Database and removed the temporary folder"
    } else { Write-Host "== Kept $Database and $work" }
}
Write-Host ("== Playwright exit code: {0}" -f $exit)
exit $exit
