<#
.SYNOPSIS
  Registers the TAMS application tasks in Windows Task Scheduler (Phase 12).
.DESCRIPTION
  One task per job in sched.JobDefinitions (Owner = TaskScheduler), in the Task Scheduler folder -TaskPath (default \TAMS\).
  Each task runs  TalentAcquisition.Scheduler.exe run <task>  hidden (scripts\scheduler\run-hidden.vbs), so its exit code is
  the task's "Last Run Result": 0 = succeeded or skipped, 1 = failed (also recorded in TAMS and notified to administrators),
  2 = configuration, 3 = database unreachable.

  The tasks run as the current Windows user, only while that user is signed in (no password is stored). Runs missed while
  signed out start when the user signs in again (StartWhenAvailable). A second instance of the same task is never started
  while one runs (MultipleInstances IgnoreNew), and a run is stopped after 30 minutes.

  Re-running the script replaces the tasks. -SettingsFile makes every task use an extra settings file (for example a test
  database); -Disabled registers them switched off.
.EXAMPLE
  .\scripts\scheduler\Register-ScheduledTasks.ps1
.EXAMPLE
  .\scripts\scheduler\Register-ScheduledTasks.ps1 -TaskPath '\TAMS-Test\' -SettingsFile C:\temp\tams-test.json -Disabled
#>
[CmdletBinding()]
param(
    [string]$TaskPath = '\TAMS\',
    [string]$SettingsFile,
    [string]$Exe,
    [switch]$Disabled
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
if (-not $Exe) { $Exe = Join-Path $root 'backend\TalentAcquisition.Scheduler\bin\Debug\net472\TalentAcquisition.Scheduler.exe' }
if (-not (Test-Path $Exe)) { throw "Scheduler not built: $Exe (run: dotnet build .\backend\TalentAcquisition.sln)" }
if ($TaskPath -notmatch '^\\[A-Za-z0-9_-]+\\$') { throw "TaskPath must look like \TAMS\ ." }
$vbs = Join-Path $PSScriptRoot 'run-hidden.vbs'
if ($SettingsFile) { $SettingsFile = (Resolve-Path $SettingsFile).Path }

# the configuration must be valid before anything is scheduled
$checkArgs = @('--check'); if ($SettingsFile) { $checkArgs += @('--settings', $SettingsFile) }
& $Exe @checkArgs | Out-Host
if ($LASTEXITCODE -ne 0) { throw "TalentAcquisition.Scheduler.exe --check failed (exit $LASTEXITCODE): fix the configuration first." }

$today = (Get-Date).Date
$tasks = @(
    @{ Name = 'Email queue processing';        Command = 'process-notifications';   Trigger = New-ScheduledTaskTrigger -Once -At $today -RepetitionInterval (New-TimeSpan -Minutes 5) },
    @{ Name = 'Interview reminders';           Command = 'interview-reminders';     Trigger = New-ScheduledTaskTrigger -Once -At $today.AddMinutes(2) -RepetitionInterval (New-TimeSpan -Hours 1) },
    @{ Name = 'Daily report delivery';         Command = 'daily-report';            Trigger = New-ScheduledTaskTrigger -Daily -At '07:30' },
    @{ Name = 'Offer expiry reminders';        Command = 'offer-reminders';         Trigger = New-ScheduledTaskTrigger -Daily -At '08:00' },
    @{ Name = 'Contract expiry notifications'; Command = 'contract-expiry-notices'; Trigger = New-ScheduledTaskTrigger -Daily -At '08:30' },
    @{ Name = 'Timesheet reminders';           Command = 'timesheet-reminders';     Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Friday -At '15:00' },
    @{ Name = 'File housekeeping';             Command = 'file-housekeeping';       Trigger = New-ScheduledTaskTrigger -Daily -At '04:15' }
)
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$taskSettings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
                    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Disable:$Disabled
foreach ($t in $tasks) {
    $arguments = "//B //Nologo `"$vbs`" `"$Exe`" run $($t.Command)"
    if ($SettingsFile) { $arguments += " --settings `"$SettingsFile`"" }
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\wscript.exe" -Argument $arguments -WorkingDirectory (Split-Path $Exe)
    $desc = "TAMS: $($t.Name). Runs TalentAcquisition.Scheduler.exe run $($t.Command). History: Administrator > Scheduled jobs. Exit codes: 0 ok/skipped, 1 failed, 2 configuration, 3 database."
    Register-ScheduledTask -TaskPath $TaskPath -TaskName $t.Name -Action $action -Trigger $t.Trigger -Principal $principal -Settings $taskSettings -Description $desc -Force | Out-Null
    Write-Host ("registered  {0}{1}{2}" -f $TaskPath, $t.Name, $(if ($Disabled) { '  (disabled)' } else { '' }))
}
Get-ScheduledTask -TaskPath $TaskPath | ForEach-Object {
    $i = $_ | Get-ScheduledTaskInfo
    [pscustomobject]@{ Task = $_.TaskName; State = $_.State; NextRun = $i.NextRunTime }
} | Sort-Object NextRun | Format-Table -AutoSize | Out-Host
