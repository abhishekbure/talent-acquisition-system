<#
.SYNOPSIS
  Verifies the TAMS development environment and prints actual evidence.
  Exit code 0 = every REQUIRED check passed. Read-only.
#>
[CmdletBinding()]
param([string]$Server = 'localhost')

$results = New-Object System.Collections.Generic.List[object]
function Add-Check([string]$Name, [bool]$Ok, [string]$Detail, [bool]$Required = $true) {
    $results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Required = $Required; Detail = $Detail }) | Out-Null
}
function Get-Ver([string]$Cmd, [string]$CliArg) { try { (& $Cmd $CliArg 2>&1 | Select-Object -First 1).ToString().Trim() } catch { $null } }

# ---- SQL Server services ----
foreach ($svc in 'MSSQLSERVER', 'SQLSERVERAGENT') {
    $s = Get-CimInstance Win32_Service -Filter "Name='$svc'" -ErrorAction SilentlyContinue
    if (-not $s) { Add-Check "Service $svc exists" $false 'not installed' }
    else {
        Add-Check "Service $svc exists" $true $s.DisplayName
        Add-Check "Service $svc running" ($s.State -eq 'Running') $s.State
        Add-Check "Service $svc automatic start" ($s.StartMode -eq 'Auto') $s.StartMode
    }
}
$tcp = Get-NetTCPConnection -State Listen -LocalPort 1433 -ErrorAction SilentlyContinue
Add-Check 'SQL Server listening on TCP 1433' ([bool]$tcp) ($(if ($tcp) { "pid $($tcp[0].OwningProcess)" } else { 'not listening' })) $false

# ---- Connection, version, edition, Agent, sysadmin ----
$sqlOk = $false
try {
    $c = New-Object System.Data.SqlClient.SqlConnection "Server=$Server;Database=master;Integrated Security=SSPI;TrustServerCertificate=True;Connect Timeout=10"
    $c.Open(); $sqlOk = $true
    $cmd = $c.CreateCommand()
    $cmd.CommandText = @"
SELECT @@SERVERNAME AS ServerName, @@VERSION AS FullVersion,
       CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(50)) AS ProductVersion,
       CAST(SERVERPROPERTY('ProductLevel') AS NVARCHAR(50)) AS ProductLevel,
       CAST(SERVERPROPERTY('Edition') AS NVARCHAR(100)) AS Edition,
       CAST(SERVERPROPERTY('EngineEdition') AS INT) AS EngineEdition,
       IS_SRVROLEMEMBER('sysadmin') AS IsSysadmin,
       SUSER_SNAME() AS LoginName
"@
    $r = $cmd.ExecuteReader(); [void]$r.Read()
    $info = @{}; 0..($r.FieldCount - 1) | ForEach-Object { $info[$r.GetName($_)] = $r.GetValue($_) }; $r.Close()
    Add-Check 'Windows-auth connection to default instance' $true "$($info.ServerName) as $($info.LoginName)"
    Add-Check 'Windows account is sysadmin' ($info.IsSysadmin -eq 1) "IS_SRVROLEMEMBER = $($info.IsSysadmin)"
    Add-Check 'SQL Server version' ($info.ProductVersion -like '15.*') "$($info.ProductVersion) $($info.ProductLevel)"
    Add-Check 'SQL Server edition supports Agent' ($info.Edition -match 'Developer|Enterprise|Standard') "$($info.Edition) (EngineEdition=$($info.EngineEdition))"
    $cmd.CommandText = "SELECT servicename, status_desc, startup_type_desc FROM sys.dm_server_services"
    $r = $cmd.ExecuteReader(); $svcs = @(); while ($r.Read()) { $svcs += "$($r.GetString(0)) [$($r.GetString(1)), $($r.GetString(2))]" }; $r.Close()
    $agentOk = [bool]($svcs | Where-Object { $_ -match 'Agent.*Running' })
    Add-Check 'SQL Server Agent running (per sys.dm_server_services)' $agentOk ($svcs -join '; ')
    $cmd.CommandText = "SELECT name, state_desc FROM sys.databases ORDER BY name"
    $r = $cmd.ExecuteReader(); $dbs = @(); while ($r.Read()) { $dbs += "$($r.GetString(0)) ($($r.GetString(1)))" }; $r.Close()
    Add-Check 'Databases visible' $true ($dbs -join ', ') $false
    $c.Close()
    $global:TamsSqlInfo = $info
} catch { Add-Check 'Windows-auth connection to default instance' $false $_.Exception.Message }

# ---- Development tools ----
$nodeV = Get-Ver node '--version'; Add-Check 'Node.js' ($nodeV -match '^v(20\.(1[9]|[2-9]\d)|22\.(1[2-9]|[2-9]\d)|24)') $nodeV
$npmV  = Get-Ver npm '--version';  Add-Check 'npm' ([bool]$npmV) $npmV
$gitV  = Get-Ver git '--version';  Add-Check 'Git' ([bool]$gitV) $gitV
$dnV   = try { (dotnet --list-sdks 2>$null | Select-Object -First 1) } catch { $null }; Add-Check '.NET SDK (builds net472 projects)' ([bool]$dnV) $dnV
$pack  = Test-Path "${env:ProgramFiles(x86)}\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.7.2"
Add-Check '.NET Framework 4.7.2 targeting pack' $pack ($(if ($pack) { 'present' } else { 'missing' }))
$sqlcmd = Get-Command sqlcmd -ErrorAction SilentlyContinue; Add-Check 'sqlcmd' ([bool]$sqlcmd) ($(if ($sqlcmd) { $sqlcmd.Source } else { 'not installed (optional; scripts use SqlClient)' })) $false
$ssms = Get-ChildItem 'C:\Program Files*\Microsoft SQL Server Management Studio*' -ErrorAction SilentlyContinue | Select-Object -First 1
Add-Check 'SSMS' ([bool]$ssms) ($(if ($ssms) { $ssms.FullName } else { 'not installed (optional)' })) $false
$vsw = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = if (Test-Path $vsw) { (& $vsw -latest -property displayName 2>$null) } else { $null }
Add-Check 'Visual Studio' ([bool]$vs) ($(if ($vs) { $vs } else { 'not installed (not required: OWIN self-host + dotnet build, decision D2)' })) $false
$ng = Get-Command ng -ErrorAction SilentlyContinue
Add-Check 'Angular CLI (global)' ([bool]$ng) ($(if ($ng) { $ng.Source } else { 'not global (per-project npx @angular/cli@20, decision D3)' })) $false
foreach ($port in 4200, 5000) {
    $busy = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
    Add-Check "Port $port free for TAMS" (-not $busy) ($(if ($busy) { "in use by pid $($busy[0].OwningProcess)" } else { 'free' })) $false
}

$results | ForEach-Object { "{0,-5} {1}{2}  -- {3}" -f ($(if ($_.Ok) { 'PASS' } else { 'FAIL' })), $_.Name, ($(if (-not $_.Required) { ' (optional)' } else { '' })), $_.Detail }
$bad = @($results | Where-Object { $_.Required -and -not $_.Ok })
"{0} required check(s) failed, {1} optional item(s) not satisfied." -f $bad.Count, @($results | Where-Object { -not $_.Required -and -not $_.Ok }).Count
if ($bad.Count) { exit 1 } else { exit 0 }
