<#
.SYNOPSIS
  Phase 3.5 demonstrations with MEASURED output, run on a disposable restored copy so the live database is never loaded
  with synthetic rows: execution plans (seek vs scan), statistics (histogram, stale vs refreshed), CTEs (numbers generator,
  recursive weeks), temp tables vs table variables (estimates), window functions on the real seed data.
#>
[CmdletBinding()]
param([string]$Server = 'localhost', [string]$Source = 'TalentAcquisitionDB', [string]$Copy = 'TalentAcquisitionDB_PerfTest', [int]$Rows = 300000, [switch]$KeepCopy)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\TamsSql.ps1"
$ns = 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'

& "$PSScriptRoot\Copy-Database.ps1" -Server $Server -Source $Source -Target $Copy -Force | Out-Host
$c = New-TamsConnection $Server $Copy

# Executes SQL with STATISTICS IO/TIME/XML on and returns reads, ms, row count and plan operators (estimated vs actual rows).
function Measure-Query([string]$Sql) {
    $script:msgs = New-Object System.Collections.ArrayList
    $handler = [System.Data.SqlClient.SqlInfoMessageEventHandler] { param($s, $e) [void]$script:msgs.Add($e.Message) }
    $c.add_InfoMessage($handler)
    $plans = @(); $rows = 0
    try {
        $cmd = $c.CreateCommand(); $cmd.CommandTimeout = 600
        $cmd.CommandText = "SET STATISTICS IO ON; SET STATISTICS TIME ON; SET STATISTICS XML ON; $Sql; SET STATISTICS XML OFF; SET STATISTICS TIME OFF; SET STATISTICS IO OFF;"
        $swq = [Diagnostics.Stopwatch]::StartNew()
        $r = $cmd.ExecuteReader()
        do {
            if ($r.FieldCount -eq 1 -and $r.GetName(0) -like 'Microsoft SQL Server*Showplan') { while ($r.Read()) { $plans += [xml]$r.GetString(0) } }
            else { while ($r.Read()) { $rows++ } }
        } while ($r.NextResult())
        $r.Close(); $swq.Stop()
    } finally { $c.remove_InfoMessage($handler) }
    $text = ($script:msgs -join "`n")
    $reads = ([regex]::Matches($text, 'logical reads (\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Sum).Sum
    $plan = $plans | Select-Object -Last 1
    $mgr = New-Object System.Xml.XmlNamespaceManager($plan.NameTable); $mgr.AddNamespace('p', $ns)
    $ops = foreach ($op in $plan.SelectNodes('//p:RelOp', $mgr)) {
        $act = ($op.SelectNodes('p:RunTimeInformation/p:RunTimeCountersPerThread', $mgr) | ForEach-Object { [double]$_.ActualRows } | Measure-Object -Sum).Sum
        $obj = $op.SelectSingleNode('.//p:Object', $mgr)
        [pscustomobject]@{ Operator = $op.PhysicalOp; Object = $(if ($obj) { ($obj.GetAttribute('Table') + ' ' + $obj.GetAttribute('Index')).Trim() } else { '' }); EstRows = [math]::Round([double]$op.EstimateRows); ActualRows = $act }
    }
    [pscustomobject]@{ Reads = $reads; ElapsedMs = $swq.ElapsedMilliseconds; Rows = $rows; Ops = $ops }
}
function Show([string]$title, $m) {
    Write-Host ("  {0}`n    logical reads = {1}   elapsed = {2} ms" -f $title, $m.Reads, $m.ElapsedMs)
    $m.Ops | Where-Object { $_.Object -ne '' -or $_.Operator -match 'Sort|Join|Aggregate' } | ForEach-Object { Write-Host ("    {0,-26} {1,-52} est={2,8}  actual={3,8}" -f $_.Operator, $_.Object, $_.EstRows, $_.ActualRows) }
}
function Table($sql) { (Invoke-TamsQuery $c $sql | Select-Object -ExpandProperty Rows | Format-Table -AutoSize | Out-String).TrimEnd() }

try {
    Write-Host "`n=== 1. CTE as a numbers generator: loading $Rows synthetic notification rows (set-based, 100k per batch)" -ForegroundColor Cyan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($b = 0; $b -lt [math]::Ceiling($Rows / 100000); $b++) {
        Invoke-TamsNonQuery $c @"
WITH n AS (SELECT TOP (100000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT notify.NotificationQueue (TemplateCode, ToEmail, Subject, Body, DedupeKey, Status, NextAttemptAt)
SELECT 'PERF', CONCAT(N'user', i + $($b * 100000), N'@perf.example'), N'perf', N'perf', CONCAT(N'PERF-', i + $($b * 100000)),
       CASE WHEN i % 200 = 0 THEN 'Pending' WHEN i % 400 = 1 THEN 'Failed' ELSE 'Sent' END,
       DATEADD(MINUTE, -(i % 100000), SYSUTCDATETIME())
FROM n;
"@
    }
    $cnt = Get-TamsScalar $c "SELECT COUNT(*) FROM notify.NotificationQueue"
    Write-Host ("  inserted; table now has {0:N0} rows ({1} ms). Pending = {2:N0}" -f $cnt, $sw.ElapsedMilliseconds, (Get-TamsScalar $c "SELECT COUNT(*) FROM notify.NotificationQueue WHERE Status = 'Pending'"))
    Invoke-TamsNonQuery $c 'UPDATE STATISTICS notify.NotificationQueue WITH FULLSCAN;'

    Write-Host "`n=== 2. Execution plans: index SEEK vs forced clustered SCAN (the worker query of the e-mail processor)" -ForegroundColor Cyan
    $q = "SELECT TOP (50) NotificationId, ToEmail FROM notify.NotificationQueue {0} WHERE Status = 'Pending' AND NextAttemptAt <= SYSUTCDATETIME() ORDER BY NextAttemptAt"
    [void](Measure-Query ($q -f ''))                       # warm up
    $seek = Measure-Query ($q -f ''); $scan = Measure-Query ($q -f 'WITH (INDEX(0))')
    Show 'with IX_NotifQ_Status_Next (optimizer choice)' $seek
    Show 'forced WITH (INDEX(0)) = clustered index scan' $scan
    Write-Host ("  => the index reads {0}x fewer pages ({1} vs {2})" -f [math]::Round($scan.Reads / [math]::Max($seek.Reads, 1)), $seek.Reads, $scan.Reads)

    Write-Host "`n=== 3. Statistics: histogram, then STALE vs REFRESHED estimates" -ForegroundColor Cyan
    $h = Invoke-TamsQuery $c "DBCC SHOW_STATISTICS ('notify.NotificationQueue', 'IX_NotifQ_Status_Next') WITH HISTOGRAM;"
    Write-Host '  histogram of the leading column (Status):'; Write-Host (($h.Rows | Select-Object -First 6 RANGE_HI_KEY, EQ_ROWS, RANGE_ROWS | Format-Table -AutoSize | Out-String).TrimEnd())
    $sq = "SELECT SUM(CAST(LEN(ToEmail) AS BIGINT)) FROM notify.NotificationQueue WHERE Status = 'Pending'"   # needs the row data, so the plan depends on how many 'Pending' rows are ESTIMATED
    Show 'fresh statistics' (Measure-Query $sq)
    Invoke-TamsNonQuery $c "ALTER DATABASE [$Copy] SET AUTO_UPDATE_STATISTICS OFF;"
    Invoke-TamsNonQuery $c @"
WITH n AS (SELECT TOP (150000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT notify.NotificationQueue (TemplateCode, ToEmail, Subject, Body, DedupeKey, Status, NextAttemptAt)
SELECT 'PERF2', N'x@perf.example', N'p', N'p', CONCAT(N'PERF2-', i), 'Pending', SYSUTCDATETIME() FROM n;
"@
    Show '150,000 more Pending rows inserted, auto-update OFF => STALE statistics' (Measure-Query $sq)
    Invoke-TamsNonQuery $c 'UPDATE STATISTICS notify.NotificationQueue WITH FULLSCAN;'
    Show 'after UPDATE STATISTICS WITH FULLSCAN => estimate corrected' (Measure-Query $sq)
    Invoke-TamsNonQuery $c "ALTER DATABASE [$Copy] SET AUTO_UPDATE_STATISTICS ON;"

    Write-Host "`n=== 4. Temp table vs table variable (100,000 ids joined to the queue)" -ForegroundColor Cyan
    $tv = "DECLARE @t TABLE (Id BIGINT PRIMARY KEY); INSERT @t SELECT TOP (100000) NotificationId FROM notify.NotificationQueue; SELECT COUNT(*) FROM @t t JOIN notify.NotificationQueue q ON q.NotificationId = t.Id"
    $tt = "CREATE TABLE #t (Id BIGINT PRIMARY KEY); INSERT #t SELECT TOP (100000) NotificationId FROM notify.NotificationQueue; SELECT COUNT(*) FROM #t t JOIN notify.NotificationQueue q ON q.NotificationId = t.Id; DROP TABLE #t"
    Invoke-TamsNonQuery $c "ALTER DATABASE [$Copy] SET COMPATIBILITY_LEVEL = 130;"
    Show 'table variable, compatibility level 130 (classic behaviour: fixed guess)' (Measure-Query $tv)
    Invoke-TamsNonQuery $c "ALTER DATABASE [$Copy] SET COMPATIBILITY_LEVEL = 150;"
    Show 'table variable, compatibility level 150 (deferred compilation)' (Measure-Query $tv)
    Show 'temp table (has real statistics)' (Measure-Query $tt)

    Write-Host "`n=== 5. Window functions on the real seed data" -ForegroundColor Cyan
    Write-Host '  running invoice total per customer (SUM OVER, ROWS UNBOUNDED PRECEDING):'
    Write-Host (Table "SELECT CustomerName, InvoiceNo, Total, SUM(Total) OVER (PARTITION BY CustomerId ORDER BY InvoiceId ROWS UNBOUNDED PRECEDING) AS RunningTotal FROM report.vw_CustomerInvoices ORDER BY CustomerName, InvoiceId")
    Write-Host '  days spent in each status per application (LAG + ROW_NUMBER, first 8 rows):'
    Write-Host (Table "SELECT TOP 8 ApplicationId, NewStatus, ChangedAt, DATEDIFF(DAY, LAG(ChangedAt) OVER (PARTITION BY ApplicationId ORDER BY HistoryId), ChangedAt) AS DaysSincePrevious, ROW_NUMBER() OVER (PARTITION BY ApplicationId ORDER BY HistoryId DESC) AS RecencyRank FROM cand.ApplicationStatusHistory ORDER BY ApplicationId, HistoryId")
    Write-Host '  recruiters ranked by hires then applications (RANK):'
    Write-Host (Table "SELECT Recruiter, Applications, Hires, RANK() OVER (ORDER BY Hires DESC, Applications DESC) AS Rnk FROM report.vw_RecruitmentPerformance")

    Write-Host "`n=== 6. Recursive CTE: last 8 weeks of timesheet hours (zero-filled) " -ForegroundColor Cyan
    Write-Host (Table @"
WITH w AS (SELECT CAST(DATEADD(DAY, (DATEDIFF(DAY, '19000101', CAST(SYSUTCDATETIME() AS DATE)) / 7) * 7, '19000101') AS DATE) AS WeekStart, 0 AS n
           UNION ALL SELECT DATEADD(WEEK, -1, WeekStart), n + 1 FROM w WHERE n < 7)
SELECT w.WeekStart, ISNULL(SUM(t.TotalHours), 0) AS Hours, COUNT(t.TimesheetId) AS Timesheets
FROM w LEFT JOIN [time].Timesheets t ON t.WeekStartDate = w.WeekStart GROUP BY w.WeekStart ORDER BY w.WeekStart
"@)
}
finally {
    try { $c.Close() } catch {}
    [System.Data.SqlClient.SqlConnection]::ClearAllPools()
    if (-not $KeepCopy) {
        $x = New-TamsConnection $Server
        try { Invoke-TamsNonQuery $x "IF DB_ID(N'$Copy') IS NOT NULL BEGIN ALTER DATABASE [$Copy] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$Copy]; END"; Write-Host "`n(disposable copy $Copy dropped)" } finally { $x.Close() }
    }
}
