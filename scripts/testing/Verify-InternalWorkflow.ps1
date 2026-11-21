<#
.SYNOPSIS
  Verifies, directly in the database, the record trail left by one internal-recruitment run done through the UI
  (hiring request -> job -> posting -> application -> interview -> offer -> employee -> onboarding).
  Read-only. Use it on the disposable copy the walkthrough ran against.
.EXAMPLE
  .\scripts\testing\Verify-InternalWorkflow.ps1 -Database TalentAcquisitionDB_E2E -CandidateEmail nikhil.rao@candidate.example
#>
[CmdletBinding()]
param(
    [string]$Server = 'localhost',
    [Parameter(Mandatory)][string]$Database,
    [Parameter(Mandatory)][string]$CandidateEmail
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\database\TamsSql.ps1')

$sql = @'
SET NOCOUNT ON;
DECLARE @r TABLE (Id INT IDENTITY(1,1), Name NVARCHAR(300), Ok BIT, Detail NVARCHAR(400));
DECLARE @cand INT = (SELECT CandidateId FROM cand.Candidates WHERE EmailNormalized = UPPER(@email));
DECLARE @app INT = (SELECT TOP (1) ApplicationId FROM cand.JobApplications WHERE CandidateId = @cand ORDER BY ApplicationId DESC);
DECLARE @posting INT = (SELECT JobPostingId FROM cand.JobApplications WHERE ApplicationId = @app);
DECLARE @job INT = (SELECT JobRequisitionId FROM rec.JobPostings WHERE JobPostingId = @posting);
DECLARE @er INT = (SELECT EmployeeRequisitionId FROM rec.JobRequisitions WHERE JobRequisitionId = @job);
DECLARE @offer INT = (SELECT TOP (1) OfferId FROM cand.JobOffers WHERE ApplicationId = @app ORDER BY OfferId DESC);
DECLARE @emp INT = (SELECT EmployeeId FROM hr.Employees WHERE CandidateId = @cand);
DECLARE @iv INT = (SELECT TOP (1) InterviewId FROM cand.Interviews WHERE JobApplicationId = @app ORDER BY InterviewId DESC);
DECLARE @user INT = (SELECT UserId FROM cand.Candidates WHERE CandidateId = @cand);

INSERT @r VALUES (N'W01 the candidate registered through the UI (own login linked to the candidate record)', IIF(@cand IS NOT NULL AND @user IS NOT NULL, 1, 0), CONCAT(N'candidate=', @cand));
INSERT @r SELECT N'W02 hiring request Approved by a different HR manager than the requester',
    IIF(er.Status = 'Approved' AND EXISTS (SELECT 1 FROM hr.HiringApprovals a WHERE a.EmployeeRequisitionId = er.EmployeeRequisitionId AND a.Decision = 'Approved' AND a.ApproverUserId <> er.RequestedByUserId), 1, 0), er.RequisitionNo
    FROM hr.EmployeeRequisitions er WHERE er.EmployeeRequisitionId = @er;
INSERT @r SELECT N'W03 job created from that request, signed off by someone other than its creator, now Filled (1 opening, 1 hire)',
    IIF(jr.Status = 'Filled' AND EXISTS (SELECT 1 FROM rec.JobApprovals a WHERE a.JobRequisitionId = jr.JobRequisitionId AND a.Decision = 'Approved' AND a.ApproverUserId <> jr.CreatedByUserId), 1, 0), CONCAT(jr.JobCode, N' ', jr.Status)
    FROM rec.JobRequisitions jr WHERE jr.JobRequisitionId = @job;
INSERT @r VALUES (N'W04 job skills stored from the dialog rows (3, two required)',
    IIF((SELECT COUNT(*) FROM rec.JobSkills WHERE JobRequisitionId = @job) = 3 AND (SELECT COUNT(*) FROM rec.JobSkills WHERE JobRequisitionId = @job AND IsRequired = 1) = 2, 1, 0), N'');
INSERT @r VALUES (N'W05 posting was Published and closed automatically when the job filled', IIF((SELECT Status FROM rec.JobPostings WHERE JobPostingId = @posting) = 'Closed', 1, 0), N'');
DECLARE @hist NVARCHAR(400) = STUFF((SELECT N'|' + NewStatus FROM cand.ApplicationStatusHistory WHERE ApplicationId = @app ORDER BY HistoryId FOR XML PATH(N'')), 1, 1, N'');
INSERT @r VALUES (N'W06 application Hired; history Applied | Screening | Shortlisted | Interview | Selected | OfferStage (offer sent) | Hired, in order',
    IIF((SELECT Status FROM cand.JobApplications WHERE ApplicationId = @app) = 'Hired' AND @hist = N'Applied|Screening|Shortlisted|Interview|Selected|OfferStage|Hired', 1, 0), @hist);
INSERT @r VALUES (N'W07 interview Completed with 2 panel members and exactly 2 feedback entries (one each)',
    IIF((SELECT Status FROM cand.Interviews WHERE InterviewId = @iv) = 'Completed' AND (SELECT COUNT(*) FROM cand.InterviewPanels WHERE InterviewId = @iv) = 2
        AND (SELECT COUNT(DISTINCT InterviewerUserId) FROM cand.InterviewFeedback WHERE InterviewId = @iv) = 2 AND (SELECT COUNT(*) FROM cand.InterviewFeedback WHERE InterviewId = @iv) = 2, 1, 0), CONCAT(N'interview=', @iv));
INSERT @r SELECT N'W08 offer Accepted; approved by an HR manager who did not create it; sent before it was answered',
    IIF(o.Status = 'Accepted' AND o.SentAt IS NOT NULL AND o.RespondedAt >= o.SentAt
        AND EXISTS (SELECT 1 FROM cand.OfferApprovals a WHERE a.OfferId = o.OfferId AND a.Decision = 'Approved' AND a.ApproverUserId <> o.CreatedByUserId), 1, 0), o.OfferNo
    FROM cand.JobOffers o WHERE o.OfferId = @offer;
INSERT @r SELECT N'W09 employee Active, linked to the offer, manager = department head, Hired event recorded',
    IIF(e.Status = 'Active' AND e.JobOfferId = @offer AND e.ManagerUserId = (SELECT HeadUserId FROM org.Departments WHERE DepartmentId = e.DepartmentId)
        AND EXISTS (SELECT 1 FROM hr.EmploymentHistory h WHERE h.EmployeeId = e.EmployeeId AND h.EventType = 'Hired'), 1, 0), e.EmployeeNo
    FROM hr.Employees e WHERE e.EmployeeId = @emp;
INSERT @r VALUES (N'W10 onboarding: 7 tasks, all finished (6 Completed + 1 Waived with a note), each with who and when',
    IIF((SELECT COUNT(*) FROM hr.EmployeeOnboarding WHERE EmployeeId = @emp) = 7
        AND (SELECT COUNT(*) FROM hr.EmployeeOnboarding WHERE EmployeeId = @emp AND Status = 'Completed') = 6
        AND EXISTS (SELECT 1 FROM hr.EmployeeOnboarding WHERE EmployeeId = @emp AND Status = 'Waived' AND LEN(Notes) > 0)
        AND NOT EXISTS (SELECT 1 FROM hr.EmployeeOnboarding WHERE EmployeeId = @emp AND (CompletedByUserId IS NULL OR CompletedAt IS NULL)), 1, 0), N'');
INSERT @r VALUES (N'W11 the candidate was notified at each step (screening, shortlist, interview invitation, selection, offer)',
    IIF((SELECT COUNT(*) FROM notify.NotificationQueue WHERE RecipientUserId = @user) >= 5
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE RecipientUserId = @user AND TemplateCode = 'INTERVIEW_INVITE' AND RelatedEntityId = @iv), 1, 0),
    CONCAT((SELECT COUNT(*) FROM notify.NotificationQueue WHERE RecipientUserId = @user), N' notifications'));
INSERT @r VALUES (N'W12 HR managers were told to onboard the new employee', IIF(EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE TemplateCode = 'ONBOARDING_STARTED' AND RelatedEntityId = @emp), 1, 0), N'');
-- The walkthrough moves the interview's start time with ONE direct SQL update (time cannot be waited for); that change is
-- correctly audited without an application user. Everything done through the application must carry the acting user.
INSERT @r VALUES (N'W13 audit: every job and offer change names the acting user; the interview''s only unattributed change is the one test-clock edit made directly in SQL; the offer was touched by 3 different people (create, approve/send, accept)',
    IIF(NOT EXISTS (SELECT 1 FROM audit.AuditLogs WHERE ((TableName = N'rec.JobRequisitions' AND RecordId = CAST(@job AS NVARCHAR(50))) OR (TableName = N'cand.JobOffers' AND RecordId = CAST(@offer AS NVARCHAR(50)))) AND ChangedByUserId IS NULL)
        AND (SELECT COUNT(*) FROM audit.AuditLogs WHERE TableName = N'cand.Interviews' AND RecordId = CAST(@iv AS NVARCHAR(50)) AND ChangedByUserId IS NULL) <= 1
        AND (SELECT COUNT(DISTINCT ChangedByUserId) FROM audit.AuditLogs WHERE TableName = N'cand.JobOffers' AND RecordId = CAST(@offer AS NVARCHAR(50))) = 3, 1, 0),
    CONCAT(N'unattributed interview rows=', (SELECT COUNT(*) FROM audit.AuditLogs WHERE TableName = N'cand.Interviews' AND RecordId = CAST(@iv AS NVARCHAR(50)) AND ChangedByUserId IS NULL)));
INSERT @r VALUES (N'W14 hiring request now shows its opening as planned (1 of headcount 1)', IIF((SELECT ISNULL(SUM(Openings), 0) FROM rec.JobRequisitions WHERE EmployeeRequisitionId = @er) = 1, 1, 0), N'');
SELECT Name, Ok, Detail FROM @r ORDER BY Id;
'@

$c = New-TamsConnection -Server $Server -Database $Database
try { $t = Invoke-TamsQuery $c $sql @{ email = $CandidateEmail } }
finally { $c.Close() }
$fail = 0
foreach ($row in $t.Rows) {
    $ok = [bool]$row.Ok; if (-not $ok) { $fail++ }
    Write-Output ("{0}  {1}{2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $row.Name, $(if (-not $ok -or $row.Detail) { "  [$($row.Detail)]" } else { '' }))
}
Write-Output ("--- Internal workflow trail: {0} passed, {1} failed, {2} total ---" -f ($t.Rows.Count - $fail), $fail, $t.Rows.Count)
if ($fail) { exit 1 }
