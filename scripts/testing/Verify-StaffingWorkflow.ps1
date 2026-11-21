<#
.SYNOPSIS
  Verifies, directly in the database, the record trail left by one external-staffing run done through the UI
  (customer request -> recruiter -> submissions -> customer decisions -> interview -> contract -> timesheets -> invoice -> payments).
  Read-only. Use it on the disposable copy the walkthrough ran against.
.EXAMPLE
  .\scripts\testing\Verify-StaffingWorkflow.ps1 -Database TalentAcquisitionDB_E2E -RequestTitle 'Data Engineer (E2E)' -ContractorEmail tara.menon@candidate.example
#>
[CmdletBinding()]
param(
    [string]$Server = 'localhost',
    [Parameter(Mandatory)][string]$Database,
    [Parameter(Mandatory)][string]$RequestTitle,
    [Parameter(Mandatory)][string]$ContractorEmail
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\database\TamsSql.ps1')

$sql = @'
SET NOCOUNT ON;
DECLARE @r TABLE (Id INT IDENTITY(1,1), Name NVARCHAR(400), Ok BIT, Detail NVARCHAR(400));
DECLARE @req INT = (SELECT TOP (1) CustomerRequisitionId FROM staff.CustomerRequisitions WHERE Title = @title ORDER BY CustomerRequisitionId DESC);
DECLARE @cust INT = (SELECT CustomerId FROM staff.CustomerRequisitions WHERE CustomerRequisitionId = @req);
DECLARE @cand INT = (SELECT CandidateId FROM cand.Candidates WHERE EmailNormalized = UPPER(@email));
DECLARE @user INT = (SELECT UserId FROM cand.Candidates WHERE CandidateId = @cand);
DECLARE @sub INT = (SELECT SubmissionId FROM staff.SubmittedCandidates WHERE CustomerRequisitionId = @req AND CandidateId = @cand);
DECLARE @ctr INT = (SELECT ContractorId FROM staff.Contractors WHERE CandidateId = @cand);
DECLARE @pl INT = (SELECT PlacementId FROM staff.Placements WHERE SubmissionId = @sub);
DECLARE @k INT = (SELECT ContractId FROM staff.Contracts WHERE PlacementId = @pl);
DECLARE @asg INT = (SELECT TOP (1) AssignmentId FROM staff.Assignments WHERE ContractId = @k ORDER BY AssignmentId);
DECLARE @iv INT = (SELECT TOP (1) InterviewId FROM cand.Interviews WHERE SubmittedCandidateId = @sub ORDER BY InterviewId DESC);
DECLARE @inv INT = (SELECT TOP (1) l.InvoiceId FROM bill.InvoiceLines l JOIN [time].TimesheetEntries e ON e.EntryId = l.TimesheetEntryId JOIN [time].Timesheets t ON t.TimesheetId = e.TimesheetId WHERE t.AssignmentId = @asg);
DECLARE @custUsers TABLE (UserId INT PRIMARY KEY); INSERT @custUsers SELECT UserId FROM org.CustomerUsers WHERE CustomerId = @cust;

INSERT @r SELECT N'S01 request raised by a user of that customer, accepted by a recruiter, now Filled',
    IIF(cr.Status = 'Filled' AND cr.CreatedByUserId IN (SELECT UserId FROM @custUsers) AND sec.fn_UserHasRole(cr.AssignedRecruiterUserId, N'Recruiter') = 1, 1, 0), cr.RequestNo
    FROM staff.CustomerRequisitions cr WHERE cr.CustomerRequisitionId = @req;
INSERT @r VALUES (N'S02 two submissions: the chosen candidate Selected, the other Rejected with a reason recorded by the customer',
    IIF((SELECT COUNT(*) FROM staff.SubmittedCandidates WHERE CustomerRequisitionId = @req) = 2
        AND (SELECT Status FROM staff.SubmittedCandidates WHERE SubmissionId = @sub) = 'Selected'
        AND EXISTS (SELECT 1 FROM staff.SubmittedCandidates s JOIN staff.CustomerCandidateDecisions d ON d.SubmissionId = s.SubmissionId
                    WHERE s.CustomerRequisitionId = @req AND s.SubmissionId <> @sub AND s.Status = 'Rejected' AND d.Decision = 'Reject' AND LEN(d.Comments) > 0 AND d.DecidedByUserId IN (SELECT UserId FROM @custUsers)), 1, 0), N'');
INSERT @r VALUES (N'S03 customer decisions for the chosen candidate: Shortlist then Select, both by the customer''s own user',
    IIF((SELECT STUFF((SELECT N'|' + Decision FROM staff.CustomerCandidateDecisions WHERE SubmissionId = @sub ORDER BY DecisionId FOR XML PATH(N'')), 1, 1, N'')) = N'Shortlist|Select'
        AND NOT EXISTS (SELECT 1 FROM staff.CustomerCandidateDecisions WHERE SubmissionId = @sub AND (DecidedByUserId NOT IN (SELECT UserId FROM @custUsers) OR CustomerId <> @cust)), 1, 0),
    (SELECT STUFF((SELECT N'|' + Decision FROM staff.CustomerCandidateDecisions WHERE SubmissionId = @sub ORDER BY DecisionId FOR XML PATH(N'')), 1, 1, N'')));
INSERT @r VALUES (N'S04 external interview Completed, owned by that customer, panel = the customer''s own users, feedback from each panel member',
    IIF((SELECT Status FROM cand.Interviews WHERE InterviewId = @iv) = 'Completed' AND (SELECT CustomerId FROM cand.Interviews WHERE InterviewId = @iv) = @cust
        AND NOT EXISTS (SELECT 1 FROM cand.InterviewPanels WHERE InterviewId = @iv AND UserId NOT IN (SELECT UserId FROM @custUsers))
        AND (SELECT COUNT(*) FROM cand.InterviewFeedback WHERE InterviewId = @iv) = (SELECT COUNT(*) FROM cand.InterviewPanels WHERE InterviewId = @iv), 1, 0), CONCAT(N'interview=', @iv));
INSERT @r VALUES (N'S05 contractor created from the shared candidate record, linked to the candidate''s own login, which now holds the Contractor role',
    IIF(@ctr IS NOT NULL AND (SELECT UserId FROM staff.Contractors WHERE ContractorId = @ctr) = @user AND sec.fn_UserHasRole(@user, N'Contractor') = 1 AND sec.fn_UserHasRole(@user, N'Candidate') = 1, 1, 0),
    (SELECT ContractorNo FROM staff.Contractors WHERE ContractorId = @ctr));
INSERT @r SELECT N'S06 contract Active for that customer: pay 1,100 / bill 1,450 (bill >= pay, bill <= customer maximum), one rate row, one Active assignment',
    IIF(ct.Status = 'Active' AND ct.CustomerId = @cust AND r.PayRate = 1100 AND r.BillRate = 1450 AND r.BillRate >= r.PayRate
        AND r.BillRate <= (SELECT MaxBillRate FROM staff.CustomerRequisitions WHERE CustomerRequisitionId = @req)
        AND (SELECT COUNT(*) FROM staff.ContractRates WHERE ContractId = @k) = 1 AND (SELECT COUNT(*) FROM staff.Assignments WHERE ContractId = @k AND Status = 'Active') = 1, 1, 0), ct.ContractNo
    FROM staff.Contracts ct JOIN staff.ContractRates r ON r.ContractId = ct.ContractId WHERE ct.ContractId = @k;
INSERT @r VALUES (N'S07 the two refused contract attempts left nothing behind (exactly one placement and one contract for the submission)',
    IIF((SELECT COUNT(*) FROM staff.Placements WHERE SubmissionId = @sub) = 1 AND (SELECT COUNT(*) FROM staff.Contracts c JOIN staff.Placements p ON p.PlacementId = c.PlacementId WHERE p.SubmissionId = @sub) = 1, 1, 0), N'');
INSERT @r VALUES (N'S08 two weekly timesheets, 40 h each, both Invoiced; approvals by the customer''s user',
    IIF((SELECT COUNT(*) FROM [time].Timesheets WHERE AssignmentId = @asg) = 2 AND NOT EXISTS (SELECT 1 FROM [time].Timesheets WHERE AssignmentId = @asg AND (Status <> 'Invoiced' OR TotalHours <> 40))
        AND NOT EXISTS (SELECT 1 FROM [time].TimesheetApprovals a JOIN [time].Timesheets t ON t.TimesheetId = a.TimesheetId WHERE t.AssignmentId = @asg AND a.ApprovedByUserId NOT IN (SELECT UserId FROM @custUsers)), 1, 0),
    (SELECT STUFF((SELECT N'|' + CONVERT(NVARCHAR(10), WeekStartDate, 120) + N' ' + Status FROM [time].Timesheets WHERE AssignmentId = @asg ORDER BY WeekStartDate FOR XML PATH(N'')), 1, 1, N'')));
INSERT @r VALUES (N'S09 the second week was rejected once with a reason, then approved after correction (rejection kept in the append-only trail)',
    IIF(EXISTS (SELECT 1 FROM [time].TimesheetRejections rj JOIN [time].Timesheets t ON t.TimesheetId = rj.TimesheetId WHERE t.AssignmentId = @asg AND LEN(rj.Reason) > 0
                AND EXISTS (SELECT 1 FROM [time].TimesheetApprovals ap WHERE ap.TimesheetId = rj.TimesheetId AND ap.ApprovedAt >= rj.RejectedAt)), 1, 0), N'');
INSERT @r SELECT N'S10 invoice Paid: subtotal 116,000 + tax 20,880 = 136,880; 10 lines, every one at the BILL rate 1,450 and tied to this assignment''s entries',
    IIF(i.Status = 'Paid' AND i.CustomerId = @cust AND i.Subtotal = 116000 AND i.TaxAmount = 20880 AND i.Total = 136880
        AND (SELECT COUNT(*) FROM bill.InvoiceLines WHERE InvoiceId = i.InvoiceId) = 10 AND NOT EXISTS (SELECT 1 FROM bill.InvoiceLines WHERE InvoiceId = i.InvoiceId AND BillRate <> 1450)
        AND NOT EXISTS (SELECT 1 FROM bill.InvoiceLines l JOIN [time].TimesheetEntries e ON e.EntryId = l.TimesheetEntryId JOIN [time].Timesheets t ON t.TimesheetId = e.TimesheetId WHERE l.InvoiceId = i.InvoiceId AND t.AssignmentId <> @asg), 1, 0), i.InvoiceNo
    FROM bill.Invoices i WHERE i.InvoiceId = @inv;
INSERT @r VALUES (N'S11 payments: two (partial + final), together exactly the total; outstanding balance 0',
    IIF((SELECT COUNT(*) FROM bill.Payments WHERE InvoiceId = @inv) = 2 AND (SELECT SUM(Amount) FROM bill.Payments WHERE InvoiceId = @inv) = (SELECT Total FROM bill.Invoices WHERE InvoiceId = @inv)
        AND bill.fn_InvoiceBalance(@inv) = 0, 1, 0), N'');
INSERT @r VALUES (N'S12 notifications queued: new request to recruiters, customer decision to the recruiter, contract and both timesheet outcomes to the contractor',
    IIF(EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE TemplateCode = 'STAFFING_REQUEST' AND RelatedEntityId = @req)
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE TemplateCode = 'SUBMISSION_DECISION' AND RelatedEntityId = @sub)
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE TemplateCode = 'CONTRACT_CREATED' AND RecipientUserId = @user)
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE TemplateCode = 'TIMESHEET_REJECTED' AND RecipientUserId = @user)
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE TemplateCode = 'TIMESHEET_APPROVED' AND RecipientUserId = @user), 1, 0),
    CONCAT((SELECT COUNT(*) FROM notify.NotificationQueue WHERE RecipientUserId = @user), N' for the contractor'));
-- one direct SQL edit moved the interview time (an interview cannot be waited for); every other change carries the acting user
INSERT @r VALUES (N'S13 audit: contract, timesheet and invoice changes all name the acting user; the interview''s only unattributed change is the test-clock edit',
    IIF(NOT EXISTS (SELECT 1 FROM audit.AuditLogs WHERE ChangedByUserId IS NULL AND ((TableName = N'staff.Contracts' AND RecordId = CAST(@k AS NVARCHAR(50)))
            OR (TableName = N'bill.Invoices' AND RecordId = CAST(@inv AS NVARCHAR(50)))
            OR (TableName = N'time.Timesheets' AND RecordId IN (SELECT CAST(TimesheetId AS NVARCHAR(50)) FROM [time].Timesheets WHERE AssignmentId = @asg))))
        AND (SELECT COUNT(*) FROM audit.AuditLogs WHERE TableName = N'cand.Interviews' AND RecordId = CAST(@iv AS NVARCHAR(50)) AND ChangedByUserId IS NULL) <= 1, 1, 0),
    CONCAT((SELECT COUNT(*) FROM audit.AuditLogs WHERE TableName IN (N'staff.Contracts', N'bill.Invoices', N'time.Timesheets') AND ChangedByUserId IS NOT NULL
            AND RecordId IN (CAST(@k AS NVARCHAR(50)), CAST(@inv AS NVARCHAR(50)))), N' contract/invoice audit rows'));
INSERT @r VALUES (N'S14 isolation: nothing of this flow is linked to another customer (submissions, interview, contract, timesheets, invoice, payments)',
    IIF(NOT EXISTS (SELECT 1 FROM staff.SubmittedCandidates WHERE CustomerRequisitionId = @req AND CustomerId <> @cust)
        AND NOT EXISTS (SELECT 1 FROM [time].Timesheets WHERE AssignmentId = @asg AND CustomerId <> @cust)
        AND NOT EXISTS (SELECT 1 FROM bill.Payments WHERE InvoiceId = @inv AND CustomerId <> @cust), 1, 0), N'');
SELECT Name, Ok, Detail FROM @r ORDER BY Id;
'@

$c = New-TamsConnection -Server $Server -Database $Database
try { $t = Invoke-TamsQuery $c $sql @{ title = $RequestTitle; email = $ContractorEmail } }
finally { $c.Close() }
$fail = 0
foreach ($row in $t.Rows) {
    $ok = [bool]$row.Ok; if (-not $ok) { $fail++ }
    Write-Output ("{0}  {1}{2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $row.Name, $(if (-not $ok -or $row.Detail) { "  [$($row.Detail)]" } else { '' }))
}
Write-Output ("--- Staffing workflow trail: {0} passed, {1} failed, {2} total ---" -f ($t.Rows.Count - $fail), $fail, $t.Rows.Count)
if ($fail) { exit 1 }
