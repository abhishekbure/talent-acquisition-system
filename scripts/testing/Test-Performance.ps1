<#
.SYNOPSIS
  Phase 13: query performance and index effectiveness on a LARGE disposable copy of TalentAcquisitionDB.
.DESCRIPTION
  1. Copies TalentAcquisitionDB to TalentAcquisitionDB_PerfTest and loads ~2 million rows of synthetic history
     (scripts\testing\perf\01_Load_Volume.sql: 100,000 candidates, 300,000 applications, ~83,000 timesheets, ...).
  2. Runs every report and the API's main list / search / get / dashboard procedures under the API's own database identity
     (EXECUTE AS USER 'tams_app_demo'): one warm-up run, then 3 timed runs; median time, logical reads and rows returned.
     Budgets: list 500 ms, dashboard 1,000 ms, report 2,000 ms, single record 200 ms; a list returning more than 1,000 rows
     is "unbounded".
  3. Index effectiveness: disables chosen indexes one at a time and measures the same call again (reads must drop at least
     3x with the index); lists missing-index suggestions and plans that scan large tables.
  4. A multi-row audited update (2,000 rows) stays under 1 second (audit triggers are linear since Phase 13).
  5. Load: starts the real API (port 5070) on the copy with a random password set on the copy only, signs in six roles and
     runs 16 concurrent clients without pauses for 20 s over lists, dashboards and reports (weighted 4:1, so about 6 % of
     requests are whole-period reports): no failed request; stress p95 within 1.5 s / 4 s. SQL Server, API and load generator
     share this PC, so these are stress figures, not single-user ones.
  The copy is dropped at the end unless -Keep. Only the copy is written; the development database is only read (copied).
  Exit code 0 = all checks passed. Results also go to tests\performance\perf-<date>.csv (git-ignored).
#>
[CmdletBinding()]
param([string]$Server = 'localhost', [string]$Database = 'TalentAcquisitionDB_PerfTest', [switch]$Keep, [switch]$SkipLoad,
      [switch]$SkipApiLoad, [int]$ApiPort = 5070, [int]$LoadWorkers = 16, [int]$LoadSeconds = 20)
$ErrorActionPreference = 'Stop'
if ($Database -notmatch '^[A-Za-z0-9_]{1,80}_PerfTest$') { throw 'The performance copy must be named *_PerfTest.' }
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
. (Join-Path $root 'scripts\database\TamsSql.ps1')
$results = New-Object System.Collections.Generic.List[object]
function Check([string]$name, [bool]$ok, [string]$detail = '') { $results.Add([pscustomobject]@{ Name = $name; Ok = $ok }); Write-Host ("{0}  {1}{2}" -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $name, $(if ($detail) { "  -> $detail" } else { '' })) }

if (-not $SkipLoad) {
    Write-Host "== Copying TalentAcquisitionDB to $Database and loading volume"
    & (Join-Path $root 'scripts\database\Copy-Database.ps1') -Server $Server -Target $Database -Force | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & (Join-Path $root 'scripts\database\Invoke-SqlScripts.ps1') -Server $Server -DatabaseName $Database -Path (Join-Path $root 'scripts\testing\perf\01_Load_Volume.sql') -CommandTimeoutSeconds 3600 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Volume load failed.' }
    Write-Host ("   loaded in {0:n0} s" -f $sw.Elapsed.TotalSeconds)
}

$c = New-TamsConnection -Server $Server -Database $Database
try {
    $counts = Invoke-TamsQuery $c "SELECT (SELECT COUNT_BIG(*) FROM cand.Candidates) AS Candidates, (SELECT COUNT_BIG(*) FROM cand.JobApplications) AS Applications, (SELECT COUNT_BIG(*) FROM [time].TimesheetEntries) AS Entries, (SELECT COUNT_BIG(*) FROM bill.InvoiceLines) AS Lines"
    $r0 = $counts.Rows[0]
    Check "V01 the copy holds large volumes (>=100k candidates, >=300k applications, >=300k timesheet entries and invoice lines)" ($r0.Candidates -ge 100000 -and $r0.Applications -ge 300000 -and $r0.Entries -ge 300000 -and $r0.Lines -ge 300000) ("{0} / {1} / {2} / {3}" -f $r0.Candidates, $r0.Applications, $r0.Entries, $r0.Lines)

    function Uid([string]$email) { return [int](Get-TamsScalar $c "SELECT UserId FROM sec.Users WHERE EmailNormalized = UPPER(@e)" @{ e = $email }) }
    $admin = Uid 'admin@tams.local'; $rec = Uid 'priya.menon@tams.local'; $hr = Uid 'vikram.nair@tams.local'
    $cust = Uid 'arjun.shah@apexlogistics.example'; $ctr = Uid 'ravi.kumar@contractor.example'; $cand = Uid 'rohan.gupta@candidate.example'
    $busyJob = [int](Get-TamsScalar $c "SELECT TOP 1 p.JobRequisitionId FROM cand.JobApplications a JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId GROUP BY p.JobRequisitionId ORDER BY COUNT(*) DESC")
    $perfCand = [int](Get-TamsScalar $c "SELECT MAX(CandidateId) FROM cand.Candidates")
    $perfApp = [int](Get-TamsScalar $c "SELECT MAX(ApplicationId) FROM cand.JobApplications")
    $bigInvoice = [int](Get-TamsScalar $c "SELECT TOP 1 InvoiceId FROM bill.InvoiceLines GROUP BY InvoiceId ORDER BY COUNT(*) DESC")
    $bigTs = [int](Get-TamsScalar $c "SELECT MAX(TimesheetId) FROM [time].Timesheets")
    $bigContract = [int](Get-TamsScalar $c "SELECT MAX(ContractId) FROM staff.Contracts")
    $monday = (Get-TamsScalar $c "SELECT CONVERT(CHAR(10), DATEADD(DAY, -(DATEDIFF(DAY, '19000101', CAST(SYSUTCDATETIME() AS DATE)) % 7), CAST(SYSUTCDATETIME() AS DATE)), 120)")
    $nextMonday = ([datetime]::ParseExact($monday, 'yyyy-MM-dd', $null)).AddDays(7).ToString('yyyy-MM-dd')
    $custId = [int](Get-TamsScalar $c "SELECT TOP 1 CustomerId FROM org.CustomerUsers WHERE UserId = @u" @{ u = $cust })

    # one connection under the API's identity, with I/O statistics captured from the info messages
    $app = New-TamsConnection -Server $Server -Database $Database
    $script:msgs = New-Object System.Collections.Generic.List[string]
    $app.add_InfoMessage({ param($s, $e) foreach ($er in $e.Errors) { $script:msgs.Add($er.Message) } })
    Invoke-TamsNonQuery $app "EXECUTE AS USER = 'tams_app_demo';" | Out-Null

    function Run-Once([string]$sql) {
        $script:msgs.Clear()
        $cmd = $app.CreateCommand(); $cmd.CommandText = "SET STATISTICS IO ON; " + $sql + "; SET STATISTICS IO OFF;"; $cmd.CommandTimeout = 300
        $sw = [Diagnostics.Stopwatch]::StartNew(); $rows = 0
        $rd = $cmd.ExecuteReader()
        try { do { while ($rd.Read()) { $rows++ } } while ($rd.NextResult()) } finally { $rd.Close() }
        $ms = $sw.Elapsed.TotalMilliseconds
        $reads = 0; $byTable = @{}
        foreach ($m in $script:msgs) { foreach ($x in [regex]::Matches($m, "Table '([^']+)'\. Scan count \d+, logical reads (\d+)")) { $n = [long]$x.Groups[2].Value; $reads += $n; $byTable[$x.Groups[1].Value] = $(if ($byTable.ContainsKey($x.Groups[1].Value)) { $byTable[$x.Groups[1].Value] } else { 0 }) + $n } }
        return [pscustomobject]@{ Ms = $ms; Reads = $reads; Rows = $rows; ByTable = $byTable }
    }
    $measured = New-Object System.Collections.Generic.List[object]
    function Measure-Call([string]$name, [string]$kind, [string]$sql) {
        try {
            Run-Once $sql | Out-Null
            $runs = @(1..3 | ForEach-Object { Run-Once $sql })
            $med = ($runs | Sort-Object Ms)[1]
            $o = [pscustomobject]@{ Name = $name; Kind = $kind; MedianMs = [math]::Round($med.Ms, 1); Reads = $runs[2].Reads; Rows = $runs[2].Rows; Error = $null }
        } catch { $o = [pscustomobject]@{ Name = $name; Kind = $kind; MedianMs = -1; Reads = -1; Rows = -1; Error = $_.Exception.InnerException.Message } }
        $measured.Add($o); return $o
    }

    Write-Host "== Measuring (median of 3 after a warm-up, as tams_app_demo)"
    $codes = Invoke-TamsQuery $c "SELECT ReportCode, Category FROM report.ReportDefinitions ORDER BY SortOrder"
    foreach ($row in $codes.Rows) {
        Measure-Call ("report " + $row.ReportCode + " (admin)") 'report' "EXEC report.usp_RunReport @ActorUserId = $admin, @ReportCode = '$($row.ReportCode)'" | Out-Null
        if ($row.Category -eq 'Staffing') { Measure-Call ("report " + $row.ReportCode + " (customer)") 'report' "EXEC report.usp_RunReport @ActorUserId = $cust, @ReportCode = '$($row.ReportCode)'" | Out-Null }
    }
    foreach ($d in @(@($admin, 'Administrator'), @($rec, 'Recruiter'), @($hr, 'HRManager'), @($cust, 'Customer'), @($ctr, 'Contractor'), @($cand, 'Candidate'))) {
        Measure-Call ("dashboard " + $d[1]) 'dashboard' "EXEC report.usp_Dashboard @ActorUserId = $($d[0]), @Role = '$($d[1])'" | Out-Null
    }
    $lists = [ordered]@{
        'candidate search by name'            = "EXEC cand.usp_SearchCandidates @ActorUserId = $rec, @Q = N'Sharma', @Page = 1, @PageSize = 25"
        'candidate search by e-mail'          = "EXEC cand.usp_SearchCandidates @ActorUserId = $rec, @Q = N'perf.c77777@candidate.example', @Page = 1, @PageSize = 25"
        'candidate search min experience'     = "EXEC cand.usp_SearchCandidates @ActorUserId = $rec, @MinExp = 5, @Page = 1, @PageSize = 25"
        'candidate search deep page (2,000)'  = "EXEC cand.usp_SearchCandidates @ActorUserId = $rec, @Page = 2000, @PageSize = 25"
        'applications of the busiest job'     = "EXEC cand.usp_ListApplications @ActorUserId = $admin, @JobRequisitionId = $busyJob, @Page = 1, @PageSize = 25"
        'applications by status (admin)'      = "EXEC cand.usp_ListApplications @ActorUserId = $admin, @Status = 'Applied', @Page = 1, @PageSize = 25"
        'jobs (recruiter, open)'              = "EXEC rec.usp_ListJobs @ActorUserId = $rec, @Status = 'Open', @Page = 1, @PageSize = 25"
        'published jobs search (candidate)'   = "EXEC rec.usp_ListPublishedJobs @ActorUserId = $cand, @Q = N'Engineer', @Page = 1, @PageSize = 25"
        'interviews this week'                = "EXEC cand.usp_ListInterviews @ActorUserId = $rec, @FromDate = '$monday', @ToDate = '$nextMonday'"
        'interviews (no filter, admin)'       = "EXEC cand.usp_ListInterviews @ActorUserId = $admin"
        'offers (recruiter)'                  = "EXEC cand.usp_ListOffers @ActorUserId = $rec"
        'contracts (recruiter)'               = "EXEC staff.usp_ListContracts @ActorUserId = $rec"
        'contracts (customer)'                = "EXEC staff.usp_ListContracts @ActorUserId = $cust"
        'contractors (recruiter)'             = "EXEC staff.usp_ListContractors @ActorUserId = $rec"
        'customer requests (recruiter)'       = "EXEC staff.usp_ListCustomerRequisitions @ActorUserId = $rec"
        'assignments (recruiter)'             = "EXEC staff.usp_ListAssignments @ActorUserId = $rec"
        'timesheets submitted (recruiter)'    = "EXEC [time].usp_ListTimesheets @ActorUserId = $rec, @Status = 'Submitted'"
        'timesheets (customer)'               = "EXEC [time].usp_ListTimesheets @ActorUserId = $cust"
        'pending timesheets (customer)'       = "EXEC [time].usp_ListPendingTimesheets @ActorUserId = $cust"
        'invoices (recruiter)'                = "EXEC bill.usp_ListInvoices @ActorUserId = $rec"
        'invoices (customer)'                 = "EXEC bill.usp_ListInvoices @ActorUserId = $cust"
        'audit log page'                      = "EXEC audit.usp_ListAuditLogs @ActorUserId = $admin, @Page = 1, @PageSize = 25"
        'users page'                          = "EXEC sec.usp_ListUsers @ActorUserId = $admin, @Page = 1, @PageSize = 25"
        'contractor''s own timesheets'         = "EXEC [time].usp_GetMyTimesheets @ActorUserId = $ctr, @Top = 20"
        'my notifications'                    = "EXEC notify.usp_ListMyNotifications @ActorUserId = $rec, @UnreadOnly = 0, @Top = 50"
    }
    foreach ($k in $lists.Keys) { Measure-Call ("list " + $k) 'list' $lists[$k] | Out-Null }
    $gets = [ordered]@{
        'candidate'                 = "EXEC cand.usp_GetCandidate @ActorUserId = $rec, @CandidateId = $perfCand"
        'application'               = "EXEC cand.usp_GetApplication @ActorUserId = $admin, @ApplicationId = $perfApp"
        'contract'                  = "EXEC staff.usp_GetContract @ActorUserId = $rec, @ContractId = $bigContract"
        'timesheet'                 = "EXEC [time].usp_GetTimesheet @ActorUserId = $rec, @TimesheetId = $bigTs"
        'invoice with most lines'   = "EXEC bill.usp_GetInvoice @ActorUserId = $rec, @InvoiceId = $bigInvoice"
        'customer balance'          = "EXEC bill.usp_GetCustomerBalance @ActorUserId = $rec, @CustomerId = $custId"
    }

    foreach ($k in $gets.Keys) { Measure-Call ("get " + $k) 'get' $gets[$k] | Out-Null }

    $budget = @{ list = 500; dashboard = 1000; report = 2000; get = 200 }
    $measured | Sort-Object Kind, Name | Format-Table Kind, Name, MedianMs, Reads, Rows, Error -AutoSize | Out-String -Width 220 | Write-Host
    $failedCalls = @($measured | Where-Object { $_.Error })
    Check "P01 every measured call ran without error ($($measured.Count) calls)" ($failedCalls.Count -eq 0) (($failedCalls | ForEach-Object { $_.Name + ': ' + $_.Error }) -join ' | ')
    foreach ($kind in 'report', 'dashboard', 'list', 'get') {
        $slow = @($measured | Where-Object { $_.Kind -eq $kind -and -not $_.Error -and $_.MedianMs -gt $budget[$kind] })
        $n = @($measured | Where-Object { $_.Kind -eq $kind }).Count
        Check ("P02 every {0} ({1}) answers within {2} ms on the large copy" -f $kind, $n, $budget[$kind]) ($slow.Count -eq 0) (($slow | ForEach-Object { "{0} {1:n0} ms" -f $_.Name, $_.MedianMs }) -join ' | ')
    }
    $unbounded = @($measured | Where-Object { $_.Kind -eq 'list' -and $_.Rows -gt 1000 })
    Check "P03 no list returns more than 1,000 rows (lists are paged or capped)" ($unbounded.Count -eq 0) (($unbounded | ForEach-Object { "{0}: {1:n0} rows" -f $_.Name, $_.Rows }) -join ' | ')

    Write-Host "== Index effectiveness (reads with the index vs. with it disabled)"
    $proofs = @(
        @('cand.JobApplications', 'IX_JobApps_Posting_Status', $lists['applications of the busiest job']),
        @('cand.ApplicationStatusHistory', 'IX_AppHist_App_At', $gets['application']),
        @('[time].Timesheets',    'IX_Timesheets_Contractor_Week', $lists['contractor''s own timesheets']),
        @('bill.InvoiceLines',    'IX_InvLines_Invoice', $gets['invoice with most lines'])
    )
    foreach ($p in $proofs) {
        $with = Run-Once $p[2]; $with = Run-Once $p[2]
        Invoke-TamsNonQuery $c "ALTER INDEX [$($p[1])] ON $($p[0]) DISABLE;" | Out-Null
        try { $without = Run-Once $p[2]; $without = Run-Once $p[2] }
        finally { Invoke-TamsNonQuery $c "ALTER INDEX [$($p[1])] ON $($p[0]) REBUILD;" -Timeout 900 | Out-Null }
        # compare the reads on the indexed table itself (the rest of the query is the same either way)
        $tbl = ($p[0] -split '\.')[-1].Trim('[', ']')
        $w = $with.ByTable[$tbl]; $wo = $without.ByTable[$tbl]
        $factor = if ($w -gt 0) { [math]::Round($wo / $w, 1) } else { 0 }
        Check ("I01 {0} cuts the reads on {1} at least 3x" -f $p[1], $tbl) ($factor -ge 3) ("{1}: with {2:n0} reads, without {3:n0} ({4}x); whole call {5:n0} -> {6:n0} reads, {7:n0} -> {8:n0} ms" -f $p[1], $tbl, $w, $wo, $factor, $with.Reads, $without.Reads, $with.Ms, $without.Ms)
    }

    $missing = Invoke-TamsQuery $c @"
SELECT TOP 10 d.statement AS TableName, ISNULL(d.equality_columns, '') AS Eq, ISNULL(d.inequality_columns, '') AS Ineq, ISNULL(d.included_columns, '') AS Incl,
       s.user_seeks, CAST(s.avg_user_impact AS INT) AS ImpactPct, CAST(s.avg_total_user_cost * s.avg_user_impact * (s.user_seeks + s.user_scans) AS BIGINT) AS Score
FROM sys.dm_db_missing_index_details d JOIN sys.dm_db_missing_index_groups g ON g.index_handle = d.index_handle
JOIN sys.dm_db_missing_index_group_stats s ON s.group_handle = g.index_group_handle
WHERE d.database_id = DB_ID() ORDER BY Score DESC
"@
    Write-Host "Missing-index suggestions recorded by SQL Server during the run:"
    $missing | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
    $strong = @($missing.Rows | Where-Object { $_.ImpactPct -ge 80 -and $_.user_seeks -ge 3 })
    Check "I02 SQL Server suggests no high-impact missing index (>= 80 % improvement, used 3+ times) for the workload" ($strong.Count -eq 0) (($strong | ForEach-Object { "$($_.TableName) eq=[$($_.Eq)] ineq=[$($_.Ineq)] impact=$($_.ImpactPct)% seeks=$($_.user_seeks)" }) -join ' | ')

    $scans = Invoke-TamsQuery $c @"
WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT TOP 15 OBJECT_SCHEMA_NAME(qp.objectid, qp.dbid) + '.' + OBJECT_NAME(qp.objectid, qp.dbid) AS ProcName,
       op.n.value('(@PhysicalOp)[1]', 'varchar(40)') AS Op, op.n.value('(*/Object/@Table)[1]', 'nvarchar(200)') AS TableName,
       op.n.value('(*/Object/@Index)[1]', 'nvarchar(200)') AS IndexName, CAST(op.n.value('(@EstimateRows)[1]', 'float') AS BIGINT) AS EstRows, qs.execution_count AS Execs, qs.total_logical_reads / qs.execution_count AS AvgReads
FROM sys.dm_exec_query_stats qs CROSS APPLY sys.dm_exec_query_plan(qs.plan_handle) qp
CROSS APPLY qp.query_plan.nodes('//RelOp[@PhysicalOp = "Clustered Index Scan" or @PhysicalOp = "Index Scan" or @PhysicalOp = "Table Scan"]') op(n)
WHERE qp.dbid = DB_ID() AND qp.objectid IS NOT NULL AND op.n.value('(@EstimateRows)[1]', 'float') >= 50000
ORDER BY qs.total_logical_reads / qs.execution_count DESC
"@
    Write-Host "Plans of the measured procedures that scan 50,000+ rows (expected for whole-period reports):"
    $scans | Format-Table -AutoSize | Out-String -Width 250 | Write-Host

    Write-Host "== Audited multi-row change"
    Invoke-TamsNonQuery $app "REVERT;" | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Invoke-TamsNonQuery $c "BEGIN TRAN; UPDATE TOP (2000) cand.Candidates SET UpdatedAt = SYSUTCDATETIME() WHERE CandidateId > 1000; ROLLBACK;" | Out-Null
    $ms = $sw.Elapsed.TotalMilliseconds
    Check "A01 one statement changing 2,000 audited rows (2,000 audit rows written) takes under 1 second" ($ms -lt 1000) ("{0:n0} ms" -f $ms)
    $app.Close()

    if (-not $SkipApiLoad) {
        Write-Host "== API under load (real API process on the large copy, $LoadWorkers concurrent clients for $LoadSeconds s)"
        $apiExe = Join-Path $root 'backend\TalentAcquisition.API\bin\Debug\net472\TalentAcquisition.API.exe'
        if (-not (Test-Path $apiExe)) { throw "Build the API first: $apiExe" }
        # a random password for this run, set on the COPY only (never shown or stored)
        Add-Type -Path (Join-Path $root 'backend\TalentAcquisition.Common\bin\Debug\net472\TalentAcquisition.Common.dll')
        $pw = 'Pf#' + [Guid]::NewGuid().ToString('N').Substring(0, 12) + 'Aa1'
        $h = $null; $sa = $null; [TalentAcquisition.Common.PasswordHasher]::Hash($pw, [ref]$h, [ref]$sa)
        Invoke-TamsNonQuery $c "UPDATE sec.Users SET PasswordHash = @h, PasswordSalt = @s, HashIterations = 210000, FailedLoginCount = 0, LockoutUntil = NULL" @{ h = $h; s = $sa } | Out-Null
        $secret = New-Object byte[] 48; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($secret)
        $base = "http://localhost:$ApiPort/"
        $env:TAMS_CONNECTION_STRING = "Server=$Server;Database=$Database;Integrated Security=SSPI;TrustServerCertificate=True;Application Name=TAMS.PerfTest;Max Pool Size=200"
        $env:TAMS_LISTEN_URL = $base; $env:TAMS_JWT_SECRET = [Convert]::ToBase64String($secret)
        $proc = Start-Process -FilePath $apiExe -WorkingDirectory (Split-Path $apiExe) -WindowStyle Hidden -PassThru
        Remove-Item Env:\TAMS_CONNECTION_STRING, Env:\TAMS_LISTEN_URL, Env:\TAMS_JWT_SECRET
        try {
            $up = $false; for ($i = 0; $i -lt 60 -and -not $up; $i++) { try { $up = (Invoke-WebRequest -UseBasicParsing "$($base)api/v1/health" -TimeoutSec 2).StatusCode -eq 200 } catch { [Threading.Thread]::Sleep(500) } }
            if (-not $up) { throw 'The API did not start.' }
            $tokens = @{}
            foreach ($u in @(@('admin', 'admin@tams.local'), @('rec', 'priya.menon@tams.local'), @('hr', 'vikram.nair@tams.local'), @('cust', 'arjun.shah@apexlogistics.example'), @('ctr', 'ravi.kumar@contractor.example'), @('cand', 'rohan.gupta@candidate.example'))) {
                $r = Invoke-RestMethod -Method Post -Uri "$($base)api/v1/auth/login" -ContentType 'application/json' -Body (@{ email = $u[1]; password = $pw } | ConvertTo-Json)
                $tokens[$u[0]] = $r.token
            }
            $pw = $null
            Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System; using System.Collections.Generic; using System.Diagnostics; using System.Linq; using System.Net.Http; using System.Threading.Tasks;
public class LoadResult { public string Name; public string Kind; public List<double> Ms = new List<double>(); public int NonSuccess; public int ServerErrors; }
public static class TamsLoad {
    public static List<LoadResult> Run(string baseUrl, Dictionary<string, string> tokens, string[][] endpoints, int workers, int seconds) {
        System.Net.ServicePointManager.DefaultConnectionLimit = 256;
        var http = new HttpClient(); http.Timeout = TimeSpan.FromSeconds(60);
        var results = endpoints.Select(e => new LoadResult { Name = e[0], Kind = e[1] }).ToList();
        var until = DateTime.UtcNow.AddSeconds(seconds);
        // weighted mix: lists and dashboards 4 shares each, whole-period reports 1 share each (people run reports occasionally)
        var pick = new List<int>(); for (int i = 0; i < endpoints.Length; i++) { int wt = endpoints[i][1] == "report" ? 1 : 4; for (int j = 0; j < wt; j++) pick.Add(i); }
        var tasks = new List<Task>(); var next = new int[1];   // one shared position in the weighted mix: exact shares
        for (int w = 0; w < workers; w++) {
            tasks.Add(Task.Run(async () => {
                while (DateTime.UtcNow < until) {
                    int k = pick[(int)((uint)System.Threading.Interlocked.Increment(ref next[0]) % (uint)pick.Count)]; var e = endpoints[k];
                    var req = new HttpRequestMessage(HttpMethod.Get, baseUrl + e[3]);
                    req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", tokens[e[2]]);
                    var sw = Stopwatch.StartNew();
                    var res = await http.SendAsync(req).ConfigureAwait(false);
                    await res.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
                    sw.Stop();
                    var r = results[k];
                    lock (r) { r.Ms.Add(sw.Elapsed.TotalMilliseconds); if (!res.IsSuccessStatusCode) r.NonSuccess++; if ((int)res.StatusCode >= 500) r.ServerErrors++; }
                }
            }));
        }
        Task.WaitAll(tasks.ToArray());
        return results;
    }
    public static double Pct(List<double> v, double p) { if (v.Count == 0) return 0; var s = v.OrderBy(x => x).ToList(); return s[Math.Min(s.Count - 1, (int)Math.Ceiling(p * s.Count) - 1)]; }
}
'@
            $endpoints = [string[][]]@(
                @('candidates search', 'list', 'rec', 'api/v1/candidates?q=Sharma'), @('applications by status', 'list', 'rec', 'api/v1/applications?status=Applied'),
                @('jobs', 'list', 'rec', 'api/v1/jobs?status=Open'), @('interviews this week', 'list', 'rec', "api/v1/interviews?from=$monday&to=$nextMonday"),
                @('offers', 'list', 'rec', 'api/v1/offers'), @('recruiter dashboard', 'list', 'rec', 'api/v1/dashboards/Recruiter'),
                @('customer timesheets', 'list', 'cust', 'api/v1/timesheets'), @('customer invoices', 'list', 'cust', 'api/v1/invoices'),
                @('customer contracts', 'list', 'cust', 'api/v1/contracts'), @('customer dashboard', 'list', 'cust', 'api/v1/dashboards/Customer'),
                @('published jobs', 'list', 'cand', 'api/v1/public/jobs?q=Engineer'), @('my applications', 'list', 'cand', 'api/v1/applications/mine'),
                @('contractor timesheets', 'list', 'ctr', 'api/v1/timesheets/mine'), @('HR dashboard', 'list', 'hr', 'api/v1/dashboards/HRManager'),
                @('admin users', 'list', 'admin', 'api/v1/users'),
                @('report pipeline', 'report', 'admin', 'api/v1/reports/pipeline'), @('report interview-conversion', 'report', 'rec', 'api/v1/reports/interview-conversion'),
                @('report sourcing', 'report', 'admin', 'api/v1/reports/sourcing'), @('report placements (customer)', 'report', 'cust', 'api/v1/reports/placements'))
            $tok = New-Object 'System.Collections.Generic.Dictionary[string,string]'; foreach ($k in $tokens.Keys) { $tok[$k] = $tokens[$k] }
            $waitSql = "SELECT wait_type, wait_time_ms, waiting_tasks_count FROM sys.dm_os_wait_stats WHERE wait_type NOT LIKE 'SLEEP%' AND wait_type NOT LIKE '%QUEUE%' AND wait_type NOT IN ('BROKER_TASK_STOP','CHECKPOINT_QUEUE','CLR_AUTO_EVENT','DIRTY_PAGE_POLL','HADR_FILESTREAM_IOMGR_IOCOMPLETION','LAZYWRITER_SLEEP','REQUEST_FOR_DEADLOCK_SEARCH','SP_SERVER_DIAGNOSTICS_SLEEP','SQLTRACE_INCREMENTAL_FLUSH_SLEEP','WAITFOR','XE_DISPATCHER_WAIT','XE_TIMER_EVENT','QDS_PERSIST_TASK_MAIN_LOOP_SLEEP','QDS_ASYNC_QUEUE','FT_IFTS_SCHEDULER_IDLE_WAIT','BROKER_EVENTHANDLER','BROKER_TRANSMITTER')"
            $w0 = @{}; foreach ($r in (Invoke-TamsQuery $c $waitSql).Rows) { $w0[$r.wait_type] = [long]$r.wait_time_ms }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $load = [TamsLoad]::Run($base, $tok, $endpoints, $LoadWorkers, $LoadSeconds)
            $secs = $sw.Elapsed.TotalSeconds
            $waits = foreach ($r in (Invoke-TamsQuery $c $waitSql).Rows) { $d = [long]$r.wait_time_ms - $(if ($w0.ContainsKey($r.wait_type)) { $w0[$r.wait_type] } else { 0 }); if ($d -gt 0) { [pscustomobject]@{ Wait = $r.wait_type; Ms = $d } } }
            Write-Host "SQL Server waits during the load (top 8, ms summed over all tasks):"
            $waits | Sort-Object Ms -Descending | Select-Object -First 8 | Format-Table -AutoSize | Out-String | Write-Host
            $rows = $load | ForEach-Object { [pscustomobject]@{ Endpoint = $_.Name; Kind = $_.Kind; Requests = $_.Ms.Count; P50 = [math]::Round([TamsLoad]::Pct($_.Ms, 0.5), 1); P95 = [math]::Round([TamsLoad]::Pct($_.Ms, 0.95), 1); Max = [math]::Round(($_.Ms | Measure-Object -Maximum).Maximum, 1); NonSuccess = $_.NonSuccess; ServerErrors = $_.ServerErrors } }
            $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
            $total = ($rows | Measure-Object Requests -Sum).Sum
            Write-Host ("   {0:n0} requests in {1:n1} s = {2:n0} requests/s" -f $total, $secs, ($total / $secs))
            $bad = @($rows | Where-Object { $_.NonSuccess -gt 0 })
            Check "L01 under load every request succeeded (no 4xx/5xx; $total requests from $LoadWorkers concurrent clients)" ($bad.Count -eq 0) (($bad | ForEach-Object { "$($_.Endpoint): $($_.NonSuccess) failed ($($_.ServerErrors) 5xx)" }) -join ' | ')
            $slowL = @($rows | Where-Object { ($_.Kind -eq 'list' -and $_.P95 -gt 1500) -or ($_.Kind -eq 'report' -and $_.P95 -gt 4000) })
            Check "L02 under stress (16 clients without pauses, all on this PC) the 95th percentile stays within 1.5 s for lists/dashboards and 4 s for reports" ($slowL.Count -eq 0) (($slowL | ForEach-Object { "$($_.Endpoint) p95 $($_.P95) ms" }) -join ' | ')
            Check "L03 every endpoint was exercised at least 10 times" (@($rows | Where-Object { $_.Requests -lt 10 }).Count -eq 0) (($rows | Where-Object { $_.Requests -lt 10 } | ForEach-Object { "$($_.Endpoint): $($_.Requests)" }) -join ' | ')
        }
        finally { if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force } }
    }

    $outDir = Join-Path $root 'tests\performance'; New-Item -ItemType Directory -Force $outDir | Out-Null
    $csv = Join-Path $outDir ("perf-{0:yyyyMMdd-HHmm}.csv" -f (Get-Date))
    $measured | Export-Csv -NoTypeInformation -Path $csv -Encoding UTF8
    Write-Host "Measurements written to $csv"
}
finally {
    $c.Close()
    if (-not $Keep) {
        $m = New-TamsConnection -Server $Server
        try { Invoke-TamsNonQuery $m "IF DB_ID(N'$Database') IS NOT NULL BEGIN ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$Database]; END" | Out-Null; Write-Host "== Dropped $Database" } finally { $m.Close() }
    }
}
$passed = @($results | Where-Object Ok).Count
Write-Host ("--- Performance tests: {0} passed, {1} failed, {2} total ---" -f $passed, ($results.Count - $passed), $results.Count)
if ($passed -ne $results.Count) { exit 1 } else { exit 0 }
