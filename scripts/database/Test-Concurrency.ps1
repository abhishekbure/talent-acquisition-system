<#
.SYNOPSIS
  Real multi-connection tests of locking, blocking, deadlocks, isolation levels and the concurrency
  guards in the stored procedures. Runs against a DISPOSABLE restored copy (Copy-Database.ps1), never the live database.
  Races are made deterministic: connection A holds its locks inside an open transaction while connection B
  starts the competing operation; a third (monitor) connection proves B is really BLOCKED before A commits.
  Exit code 0 = all checks passed.
#>
[CmdletBinding()]
param(
    [string]$Server = 'localhost',
    [string]$Source = 'TalentAcquisitionDB',
    [string]$Copy = 'TalentAcquisitionDB_ConcTest',
    [switch]$KeepCopy
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\TamsSql.ps1"

Write-Host "== creating a disposable copy: $Copy" -ForegroundColor Cyan
& "$PSScriptRoot\Copy-Database.ps1" -Server $Server -Source $Source -Target $Copy -Force | Out-Host

$results = New-Object System.Collections.ArrayList
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    [void]$results.Add([pscustomobject]@{ Name = $Name; Ok = $Ok })
    Write-Host ("{0}  {1}{2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $(if (-not $Ok -and $Detail) { "  -> $Detail" } else { '' }))
}
function Uid($c, [string]$email) { [int](Get-TamsScalar $c "SELECT UserId FROM sec.Users WHERE EmailNormalized = UPPER(@e)" @{ e = $email }) }
function Wait-Blocked($Monitor, [int]$Blocked, [int]$By, [int]$Seconds = 10) {
    $until = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $until) {
        $b = Get-TamsScalar $Monitor "SELECT blocking_session_id FROM sys.dm_exec_requests WHERE session_id = @s" @{ s = $Blocked }
        if ($b -eq $By) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

$A = New-TamsConnection $Server $Copy; $B = New-TamsConnection $Server $Copy; $M = New-TamsConnection $Server $Copy
try {
    $spA = [int](Get-TamsScalar $A 'SELECT @@SPID'); $spB = [int](Get-TamsScalar $B 'SELECT @@SPID')
    $priya = Uid $M 'priya.menon@tams.local'; $rohan = Uid $M 'rohan.gupta@candidate.example'
    $today = "CAST(SYSUTCDATETIME() AS DATE)"

    # ---------------------------------------------------------------------------------------------
    Write-Host "`n== C1 two payments race on the same invoice (UPDLOCK,HOLDLOCK serialises them)" -ForegroundColor Cyan
    $inv = [int](Get-TamsScalar $M "SELECT InvoiceId FROM bill.Invoices WHERE InvoiceNo LIKE N'INV-%-0002'")
    $before = Get-TamsScalar $M "SELECT COUNT(*) FROM bill.Payments WHERE InvoiceId = $inv"
    Invoke-TamsNonQuery $A 'BEGIN TRANSACTION;'
    Invoke-TamsNonQuery $A "DECLARE @d DATE = $today; EXEC bill.usp_RecordPayment @ActorUserId = $priya, @InvoiceId = $inv, @Amount = 20000, @PaidOn = @d;"
    $hB = Start-TamsAsync $B "DECLARE @d DATE = $today; EXEC bill.usp_RecordPayment @ActorUserId = $priya, @InvoiceId = $inv, @Amount = 20000, @PaidOn = @d;"
    Check 'C1a the second payment is BLOCKED by the first (observed in sys.dm_exec_requests)' (Wait-Blocked $M $spB $spA)
    Invoke-TamsNonQuery $A 'COMMIT;'
    $rb = Wait-TamsAsync $hB
    Check 'C1b after the first commits, the second sees the new balance and is refused (50002) - no over-payment' ($rb.Done -and -not $rb.Ok -and $rb.Number -eq 50002) "number=$($rb.Number) $($rb.Message)"
    $row = (Invoke-TamsQuery $M "SELECT COUNT(*) n, SUM(Amount) s FROM bill.Payments WHERE InvoiceId = $inv").Rows[0]
    $total = Get-TamsScalar $M "SELECT Total FROM bill.Invoices WHERE InvoiceId = $inv"
    Check 'C1c exactly ONE of the two payments was recorded and the total paid never exceeds the invoice' (($row.n -eq $before + 1) -and ($row.s -le $total)) "payments=$($row.n) sum=$($row.s) total=$total"

    # ---------------------------------------------------------------------------------------------
    Write-Host "`n== C2 lock timeout" -ForegroundColor Cyan
    Invoke-TamsNonQuery $A 'BEGIN TRANSACTION;'
    Invoke-TamsNonQuery $A "DECLARE @d DATE = $today; EXEC bill.usp_RecordPayment @ActorUserId = $priya, @InvoiceId = $inv, @Amount = 500, @PaidOn = @d;"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Try-TamsNonQuery $B "SET LOCK_TIMEOUT 1500; DECLARE @d DATE = $today; EXEC bill.usp_RecordPayment @ActorUserId = $priya, @InvoiceId = $inv, @Amount = 500, @PaidOn = @d;"
    Check 'C2a a waiter with SET LOCK_TIMEOUT gives up with error 1222 after ~1.5 s instead of waiting forever' (($r.Number -eq 1222) -and ($sw.ElapsedMilliseconds -ge 1200) -and ($sw.ElapsedMilliseconds -lt 8000)) "number=$($r.Number) ms=$($sw.ElapsedMilliseconds)"
    Invoke-TamsNonQuery $B 'SET LOCK_TIMEOUT -1;'     # session settings persist on a connection: restore "wait forever"
    Invoke-TamsNonQuery $A 'ROLLBACK;'
    Check 'C2b rolling back the holder releases the lock and leaves no payment behind' ((Get-TamsScalar $M "SELECT COUNT(*) FROM bill.Payments WHERE InvoiceId = $inv") -eq ($before + 1))

    # ---------------------------------------------------------------------------------------------
    Write-Host "`n== C3 deadlock: detection, victim selection and retry" -ForegroundColor Cyan
    $ids = Invoke-TamsQuery $M 'SELECT TOP 2 JobDefinitionId FROM sched.JobDefinitions ORDER BY JobDefinitionId'
    $r1 = [int]$ids.Rows[0][0]; $r2 = [int]$ids.Rows[1][0]
    Invoke-TamsNonQuery $A 'BEGIN TRANSACTION;'; Invoke-TamsNonQuery $B 'BEGIN TRANSACTION;'
    Invoke-TamsNonQuery $A "UPDATE sched.JobDefinitions SET Description = N'A first' WHERE JobDefinitionId = $r1;"
    Invoke-TamsNonQuery $B "UPDATE sched.JobDefinitions SET Description = N'B first' WHERE JobDefinitionId = $r2;"
    $hA = Start-TamsAsync $A "UPDATE sched.JobDefinitions SET Description = N'A second' WHERE JobDefinitionId = $r2;" 60
    Check 'C3a A is blocked waiting for B (one half of the cycle)' (Wait-Blocked $M $spA $spB)
    $hB = Start-TamsAsync $B "UPDATE sched.JobDefinitions SET Description = N'B second' WHERE JobDefinitionId = $r1;" 60
    $ra = Wait-TamsAsync $hA 40000; $rb = Wait-TamsAsync $hB 40000
    $victims = @($ra, $rb | Where-Object { $_.Number -eq 1205 })
    Check 'C3b SQL Server detects the deadlock and kills exactly ONE session (error 1205) while the other completes' (($victims.Count -eq 1) -and (@($ra, $rb | Where-Object { $_.Ok }).Count -eq 1)) "A=$($ra.Number) B=$($rb.Number)"
    $winner = if ($ra.Ok) { $A } else { $B }; $victim = if ($ra.Ok) { $B } else { $A }
    Check 'C3c the victim''s transaction was rolled back automatically (no open transaction left)' ((Get-TamsScalar $victim 'SELECT @@TRANCOUNT') -eq 0)
    Invoke-TamsNonQuery $winner 'COMMIT;'
    # RETRY: the victim simply repeats its whole transaction (this is what the C# data layer will do on 1205)
    $attempts = 0; $ok = $false
    while (-not $ok -and $attempts -lt 3) {
        $attempts++
        $t = Try-TamsNonQuery $victim "BEGIN TRANSACTION; UPDATE sched.JobDefinitions SET Description = N'retry 1' WHERE JobDefinitionId = $r1; UPDATE sched.JobDefinitions SET Description = N'retry 2' WHERE JobDefinitionId = $r2; COMMIT;"
        if ($t.Ok) { $ok = $true } elseif ($t.Number -ne 1205) { break }
    }
    Check 'C3d retrying the victim''s transaction after the winner committed succeeds' ($ok -and ((Get-TamsScalar $M "SELECT Description FROM sched.JobDefinitions WHERE JobDefinitionId = $r1") -eq 'retry 1')) "attempts=$attempts"

    # ---------------------------------------------------------------------------------------------
    Write-Host "`n== C4 isolation levels" -ForegroundColor Cyan
    Invoke-TamsNonQuery $M "UPDATE sched.JobDefinitions SET Description = N'base' WHERE JobDefinitionId = $r1;"
    # READ COMMITTED: non-repeatable read
    Invoke-TamsNonQuery $A 'SET TRANSACTION ISOLATION LEVEL READ COMMITTED; BEGIN TRANSACTION;'
    $v1 = Get-TamsScalar $A "SELECT Description FROM sched.JobDefinitions WHERE JobDefinitionId = $r1"
    Invoke-TamsNonQuery $B "UPDATE sched.JobDefinitions SET Description = N'changed by B' WHERE JobDefinitionId = $r1;"
    $v2 = Get-TamsScalar $A "SELECT Description FROM sched.JobDefinitions WHERE JobDefinitionId = $r1"
    Invoke-TamsNonQuery $A 'COMMIT;'
    Check 'C4a READ COMMITTED allows a non-repeatable read (second read in the same transaction sees the other session''s commit)' (($v1 -eq 'base') -and ($v2 -eq 'changed by B')) "$v1 -> $v2"
    # REPEATABLE READ: writer is blocked
    Invoke-TamsNonQuery $A 'SET TRANSACTION ISOLATION LEVEL REPEATABLE READ; BEGIN TRANSACTION;'
    [void](Get-TamsScalar $A "SELECT Description FROM sched.JobDefinitions WHERE JobDefinitionId = $r1")
    $t = Try-TamsNonQuery $B "SET LOCK_TIMEOUT 1000; UPDATE sched.JobDefinitions SET Description = N'blocked write' WHERE JobDefinitionId = $r1;"
    Invoke-TamsNonQuery $B 'SET LOCK_TIMEOUT -1;'
    Invoke-TamsNonQuery $A 'COMMIT; SET TRANSACTION ISOLATION LEVEL READ COMMITTED;'
    Check 'C4b REPEATABLE READ keeps its read locks, so a concurrent writer is blocked (lock timeout 1222)' ($t.Number -eq 1222) "number=$($t.Number)"
    # SNAPSHOT: reader neither blocks nor sees changes
    Invoke-TamsNonQuery $M "ALTER DATABASE [$Copy] SET ALLOW_SNAPSHOT_ISOLATION ON;"
    Invoke-TamsNonQuery $A 'SET TRANSACTION ISOLATION LEVEL SNAPSHOT; BEGIN TRANSACTION;'
    $s1 = Get-TamsScalar $A "SELECT Description FROM sched.JobDefinitions WHERE JobDefinitionId = $r1"
    $w = Try-TamsNonQuery $B "SET LOCK_TIMEOUT 1000; UPDATE sched.JobDefinitions SET Description = N'written during snapshot' WHERE JobDefinitionId = $r1;"
    $s2 = Get-TamsScalar $A "SELECT Description FROM sched.JobDefinitions WHERE JobDefinitionId = $r1"
    Invoke-TamsNonQuery $B 'SET LOCK_TIMEOUT -1;'
    Invoke-TamsNonQuery $A 'COMMIT; SET TRANSACTION ISOLATION LEVEL READ COMMITTED;'
    $s3 = Get-TamsScalar $A "SELECT Description FROM sched.JobDefinitions WHERE JobDefinitionId = $r1"
    Check 'C4c SNAPSHOT: the writer is NOT blocked, and the snapshot reader keeps seeing its original version until it commits' ($w.Ok -and ($s1 -eq $s2) -and ($s3 -eq 'written during snapshot')) "$s1 | $s2 | $s3 | writerOk=$($w.Ok)"
    # READ UNCOMMITTED: dirty read
    Invoke-TamsNonQuery $A "BEGIN TRANSACTION; UPDATE sched.JobDefinitions SET Description = N'DIRTY' WHERE JobDefinitionId = $r1;"
    Invoke-TamsNonQuery $B 'SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;'
    $dirty = Get-TamsScalar $B "SELECT Description FROM sched.JobDefinitions WHERE JobDefinitionId = $r1"
    Invoke-TamsNonQuery $A 'ROLLBACK;'
    $clean = Get-TamsScalar $B "SELECT Description FROM sched.JobDefinitions WHERE JobDefinitionId = $r1"
    Invoke-TamsNonQuery $B 'SET TRANSACTION ISOLATION LEVEL READ COMMITTED;'
    Check 'C4d READ UNCOMMITTED shows a DIRTY read of data that is later rolled back (why the app never uses it)' (($dirty -eq 'DIRTY') -and ($clean -ne 'DIRTY')) "$dirty -> $clean"

    # ---------------------------------------------------------------------------------------------
    Write-Host "`n== C5 duplicate candidate submission race (customer requisition row locked)" -ForegroundColor Cyan
    $cr = [int](Get-TamsScalar $M "SELECT CustomerRequisitionId FROM staff.CustomerRequisitions WHERE RequestNo LIKE N'CR-%-004'")
    $cg = [int](Get-TamsScalar $M "SELECT CandidateId FROM cand.Candidates WHERE EmailNormalized = N'GAURAV.SINGH@CANDIDATE.EXAMPLE'")
    Invoke-TamsNonQuery $A 'BEGIN TRANSACTION;'
    Invoke-TamsNonQuery $A "EXEC staff.usp_SubmitCandidateToCustomer @ActorUserId = $priya, @CustomerRequisitionId = $cr, @CandidateId = $cg, @ProposedBillRate = 1200;"
    $hB = Start-TamsAsync $B "EXEC staff.usp_SubmitCandidateToCustomer @ActorUserId = $priya, @CustomerRequisitionId = $cr, @CandidateId = $cg, @ProposedBillRate = 1200;"
    Check 'C5a the competing submission is BLOCKED while the first is uncommitted' (Wait-Blocked $M $spB $spA)
    Invoke-TamsNonQuery $A 'COMMIT;'
    $rb = Wait-TamsAsync $hB
    Check 'C5b the second submission is refused as a duplicate (50003) and exactly one live row exists' ($rb.Number -eq 50003 -and ((Get-TamsScalar $M "SELECT COUNT(*) FROM staff.SubmittedCandidates WHERE CustomerRequisitionId = $cr AND CandidateId = $cg AND Status <> 'Withdrawn'") -eq 1)) "number=$($rb.Number)"

    # ---------------------------------------------------------------------------------------------
    Write-Host "`n== C6 double-billing race (two invoice generations for the same approved timesheets)" -ForegroundColor Cyan
    $bright = [int](Get-TamsScalar $M "SELECT CustomerId FROM org.Customers WHERE CustomerCode = N'BRIGHT'")
    $invBefore = [int](Get-TamsScalar $M "SELECT COUNT(*) FROM bill.Invoices WHERE CustomerId = $bright")
    $gen = "DECLARE @s DATE = DATEADD(DAY, -60, $today), @e DATE = $today; EXEC bill.usp_GenerateInvoice @ActorUserId = $priya, @CustomerId = $bright, @PeriodStart = @s, @PeriodEnd = @e;"
    Invoke-TamsNonQuery $A 'BEGIN TRANSACTION;'; Invoke-TamsNonQuery $A $gen
    $hB = Start-TamsAsync $B $gen
    Check 'C6a the competing invoice run is BLOCKED on the same timesheets' (Wait-Blocked $M $spB $spA)
    Invoke-TamsNonQuery $A 'COMMIT;'
    $rb = Wait-TamsAsync $hB
    $invAfter = [int](Get-TamsScalar $M "SELECT COUNT(*) FROM bill.Invoices WHERE CustomerId = $bright")
    $dups = [int](Get-TamsScalar $M 'SELECT COUNT(*) - COUNT(DISTINCT TimesheetEntryId) FROM bill.InvoiceLines')
    Check 'C6b only ONE invoice was created; the loser finds nothing left to bill (50002); no time entry is billed twice' (($rb.Number -eq 50002) -and ($invAfter -eq $invBefore + 1) -and ($dups -eq 0)) "number=$($rb.Number) invoices +$($invAfter - $invBefore) duplicateLines=$dups"

    # ---------------------------------------------------------------------------------------------
    Write-Host "`n== C7 optimistic concurrency (row version)" -ForegroundColor Cyan
    $rv = (Invoke-TamsQuery $M "SELECT RowVer FROM cand.Candidates WHERE UserId = $rohan").Rows[0][0]
    $hex = '0x' + (($rv | ForEach-Object { $_.ToString('X2') }) -join '')
    $upd = "EXEC cand.usp_UpdateCandidate @ActorUserId = $rohan, @RowVer = $hex, @FirstName = N'Rohan', @LastName = N'Gupta', @Summary = N'concurrency test';"
    $t1 = Try-TamsNonQuery $A $upd; $t2 = Try-TamsNonQuery $B $upd
    Check 'C7 two editors read the same version: the first save wins, the second is refused (50006) instead of silently overwriting' ($t1.Ok -and ($t2.Number -eq 50006)) "first=$($t1.Ok) second=$($t2.Number)"
}
finally {
    foreach ($c in @($A, $B, $M)) { try { $c.Close() } catch {} }
    [System.Data.SqlClient.SqlConnection]::ClearAllPools()
    if (-not $KeepCopy) {
        $x = New-TamsConnection $Server
        try { Invoke-TamsNonQuery $x "IF DB_ID(N'$Copy') IS NOT NULL BEGIN ALTER DATABASE [$Copy] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$Copy]; END"; Write-Host "(disposable copy $Copy dropped)" } finally { $x.Close() }
    }
}
$bad = @($results | Where-Object { -not $_.Ok })
Write-Host ("--- Concurrency tests: {0} passed, {1} failed, {2} total ---" -f ($results.Count - $bad.Count), $bad.Count, $results.Count) -ForegroundColor $(if ($bad.Count) { 'Red' } else { 'Green' })
if ($bad.Count) { exit 1 } else { exit 0 }
