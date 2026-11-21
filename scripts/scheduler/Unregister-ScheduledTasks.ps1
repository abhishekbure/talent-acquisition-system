<#
.SYNOPSIS
  Removes the TAMS application tasks from Windows Task Scheduler (Phase 12): every task in -TaskPath (default \TAMS\),
  then the folder itself when it is empty. Run history in TAMS (sched.JobExecutionHistory) is kept.
.EXAMPLE
  .\scripts\scheduler\Unregister-ScheduledTasks.ps1
.EXAMPLE
  .\scripts\scheduler\Unregister-ScheduledTasks.ps1 -TaskPath '\TAMS-Test\'
#>
[CmdletBinding()]
param([string]$TaskPath = '\TAMS\')
$ErrorActionPreference = 'Stop'
if ($TaskPath -notmatch '^\\[A-Za-z0-9_-]+\\$') { throw "TaskPath must look like \TAMS\ ." }
$tasks = @(Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue)
foreach ($t in $tasks) {
    if ($t.State -eq 'Running') { Stop-ScheduledTask -TaskPath $TaskPath -TaskName $t.TaskName }
    Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $t.TaskName -Confirm:$false
    Write-Host "removed  $TaskPath$($t.TaskName)"
}
# remove the now empty folder (the ScheduledTasks module has no cmdlet for folders)
try {
    $svc = New-Object -ComObject Schedule.Service; $svc.Connect()
    $folder = $svc.GetFolder($TaskPath.TrimEnd('\'))
    if ($folder.GetTasks(1).Count -eq 0) { $svc.GetFolder('\').DeleteFolder($TaskPath.Trim('\'), 0); Write-Host "removed folder $TaskPath" }
} catch { }
if ($tasks.Count -eq 0) { Write-Host "no tasks in $TaskPath" }
