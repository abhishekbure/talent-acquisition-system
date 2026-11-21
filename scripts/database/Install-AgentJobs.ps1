<#
.SYNOPSIS
  Creates, re-creates or removes the TAMS SQL Server Agent jobs for one database (Phase 11).
.DESCRIPTION
  Jobs for TalentAcquisitionDB are named "TAMS - <job>", exactly like sched.JobDefinitions. Jobs for any other database
  (test copies) are named "TAMS[<database>] - <job>" and are created disabled unless -Enable is given, so their
  schedules never fire; they can still be started by hand (sp_start_job).
.EXAMPLE
  .\scripts\database\Install-AgentJobs.ps1                         # TalentAcquisitionDB, scheduled
.EXAMPLE
  .\scripts\database\Install-AgentJobs.ps1 -DatabaseName TalentAcquisitionDB_E2E
.EXAMPLE
  .\scripts\database\Install-AgentJobs.ps1 -DatabaseName TalentAcquisitionDB_E2E -Remove
#>
[CmdletBinding()]
param(
    [string]$DatabaseName = 'TalentAcquisitionDB',
    [string]$Server = 'localhost',
    [switch]$Remove,
    [switch]$Enable,
    [switch]$Disable
)
$ErrorActionPreference = 'Stop'
if ($DatabaseName -notmatch '^[A-Za-z0-9_]{1,100}$') { throw "Invalid database name." }
$live = $DatabaseName -eq 'TalentAcquisitionDB'
$prefix = if ($live) { 'TAMS' } else { "TAMS[$DatabaseName]" }      # no spaces: passed to sqlcmd as -v; the script adds ' - <job>'
$enabled = if ($Disable) { 0 } elseif ($Enable -or $live) { 1 } else { 0 }
$script = Join-Path $PSScriptRoot '..\..\database\11_AgentJobs\01_Create_Agent_Jobs.sql'

# the Agent must be running, otherwise jobs would never execute
$agent = sqlcmd -S $Server -E -h -1 -W -Q "SET NOCOUNT ON; SELECT status_desc FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server Agent%'"
if (($agent | Out-String).Trim() -ne 'Running') { throw "SQL Server Agent is not running (status: $agent). Start it before installing jobs." }

sqlcmd -S $Server -E -I -b -i $script -v DatabaseName="$DatabaseName" JobPrefix="$prefix" Enabled=$enabled Remove=$([int][bool]$Remove)
if ($LASTEXITCODE -ne 0) { throw "Creating the Agent jobs failed (sqlcmd exit $LASTEXITCODE)." }
if (-not $Remove) {
    sqlcmd -S $Server -E -W -s "|" -Q "SET NOCOUNT ON; SELECT j.name, j.enabled, s.next_run_date, s.next_run_time FROM msdb.dbo.sysjobs j LEFT JOIN msdb.dbo.sysjobschedules s ON s.job_id = j.job_id WHERE j.name LIKE '$($prefix.Replace('[','[[]')) - %' ORDER BY j.name"
}
