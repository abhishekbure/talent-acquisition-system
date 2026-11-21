/* ============================================================================
   TAMS - 12_Tests / 07_Report_Tests.sql        (Phase 10)
   Gate "reports match SQL counts": every one of the 19 reports is run through report.usp_RunReport and compared
   with an independent query on the base tables (or an existing function/view computed another way).
   Also: catalog and role visibility, customer isolation, pay-rate secrecy, parameter validation, least privilege.
   Since Phase 13 every run writes an audit row (audit.ReportRuns), so the suite runs in a transaction that is rolled back.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;
DECLARE @r TABLE (Id INT IDENTITY(1,1), Name NVARCHAR(240), Ok BIT, Detail NVARCHAR(400));
DECLARE @e INT, @e2 INT, @e3 INT, @n INT, @n2 INT, @m NVARCHAR(400);
DECLARE @admin INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ADMIN@TAMS.LOCAL'),
        @priya INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'PRIYA.MENON@TAMS.LOCAL'),
        @anita INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ANITA.KAPOOR@TAMS.LOCAL'),
        @arjun INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ARJUN.SHAH@APEXLOGISTICS.EXAMPLE'),
        @ravi  INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'RAVI.KUMAR@CONTRACTOR.EXAMPLE'),
        @divya INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'DIVYA.REDDY@CANDIDATE.EXAMPLE');
DECLARE @apex INT = (SELECT CustomerId FROM org.Customers WHERE CustomerCode = N'APEX'),
        @bright INT = (SELECT CustomerId FROM org.Customers WHERE CustomerCode = N'BRIGHT');
DECLARE @apexName NVARCHAR(200) = (SELECT Name FROM org.Customers WHERE CustomerId = @apex);
DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
DECLARE @runsBefore BIGINT = ISNULL((SELECT MAX(ReportRunId) FROM audit.ReportRuns), 0);
BEGIN TRANSACTION;

CREATE TABLE #list (ReportCode VARCHAR(40), Category VARCHAR(20), Title NVARCHAR(100), Description NVARCHAR(400), DateFilter NVARCHAR(100), UsesDays BIT,
                    CustomerScoped BIT, CanFilterCustomer BIT, ChartLabel SYSNAME NULL, ChartValue SYSNAME NULL, ChartAggregate VARCHAR(5));
CREATE TABLE #openreq (JobCode NVARCHAR(400), Title NVARCHAR(400), Department NVARCHAR(400), Location NVARCHAR(400), Openings INT, Recruiter NVARCHAR(400),
                       OpenedAt DATETIME2(0), ClosesBy DATE, DaysOpen INT, Applications INT, InProgress INT, Hired INT, PositionsLeft INT);
CREATE TABLE #abs (Status NVARCHAR(40), Applications INT, SharePct DECIMAL(9,1));
CREATE TABLE #pipe (JobCode NVARCHAR(400), Title NVARCHAR(400), JobStatus NVARCHAR(40), Recruiter NVARCHAR(400), Total INT, Applied INT, Screening INT,
                    Shortlisted INT, Interview INT, Selected INT, OfferStage INT, Hired INT, Rejected INT, Withdrawn INT);
CREATE TABLE #src (Source NVARCHAR(400), SourceType NVARCHAR(40), Applications INT, Candidates INT, Interviewed INT, Hired INT, HireRatePct DECIMAL(9,1));
CREATE TABLE #ivc (JobCode NVARCHAR(400), Title NVARCHAR(400), Interviews INT, Completed INT, CancelledOrNoShow INT, CandidatesInterviewed INT,
                   FeedbackGiven INT, PositiveFeedback INT, ReachedOffer INT, Hired INT, ConversionPct DECIMAL(9,1));
CREATE TABLE #offer ([Month] CHAR(7), Offers INT, Sent INT, Accepted INT, Declined INT, Expired INT, StillOpen INT, RejectedInternally INT, AcceptancePct DECIMAL(9,1));
CREATE TABLE #tth (Candidate NVARCHAR(400), JobCode NVARCHAR(400), Title NVARCHAR(400), Department NVARCHAR(400), Source NVARCHAR(400),
                   AppliedAt DATETIME2(0), HiredAt DATETIME2(0), DaysToHire INT);
CREATE TABLE #perf (Recruiter NVARCHAR(400), OpenJobs INT, Applications INT, Interviews INT, OffersCreated INT, OffersAccepted INT, Hires INT,
                    AvgDaysToHire DECIMAL(9,1), StaffingSubmissions INT, Placements INT);
CREATE TABLE #creq (RequestNo NVARCHAR(400), Customer NVARCHAR(400), Title NVARCHAR(400), Positions INT, Status NVARCHAR(40), CreatedAt DATETIME2(0), StartDate DATE,
                    MaxBillRate DECIMAL(18,2), Recruiter NVARCHAR(400), Submissions INT, Shortlisted INT, Selected INT, Placed INT);
CREATE TABLE #subs (RequestNo NVARCHAR(400), Customer NVARCHAR(400), Request NVARCHAR(400), Candidate NVARCHAR(400), ProposedBillRate DECIMAL(18,2),
                    Status NVARCHAR(40), SubmittedAt DATETIME2(0), SubmittedBy NVARCHAR(400), LastDecision NVARCHAR(40), DecidedAt DATETIME2(0));
CREATE TABLE #plS (PlacementDate DATE, ContractNo NVARCHAR(400), Customer NVARCHAR(400), Contractor NVARCHAR(400), Role NVARCHAR(400), StartDate DATE, EndDate DATE,
                   ContractStatus NVARCHAR(40), BillRate DECIMAL(18,2), PayRate DECIMAL(18,2), MarginPct DECIMAL(9,1));
CREATE TABLE #plC (PlacementDate DATE, ContractNo NVARCHAR(400), Customer NVARCHAR(400), Contractor NVARCHAR(400), Role NVARCHAR(400), StartDate DATE, EndDate DATE,
                   ContractStatus NVARCHAR(40), BillRate DECIMAL(18,2));
CREATE TABLE #act (ContractorNo NVARCHAR(400), Contractor NVARCHAR(400), Customer NVARCHAR(400), Role NVARCHAR(400), ContractNo NVARCHAR(400), StartDate DATE,
                   EndDate DATE, ContractStatus NVARCHAR(40), BillRate DECIMAL(18,2));
CREATE TABLE #exp (ContractNo NVARCHAR(400), Customer NVARCHAR(400), ContractorNo NVARCHAR(400), Contractor NVARCHAR(400), Role NVARCHAR(400), StartDate DATE,
                   EndDate DATE, Status NVARCHAR(40), DaysToExpiry INT);
CREATE TABLE #pts (Customer NVARCHAR(400), ContractorNo NVARCHAR(400), Contractor NVARCHAR(400), Role NVARCHAR(400), WeekStartDate DATE, TotalHours DECIMAL(9,2),
                   SubmittedAt DATETIME2(0), DaysWaiting INT);
CREATE TABLE #inv (InvoiceNo NVARCHAR(400), Customer NVARCHAR(400), PeriodStart DATE, PeriodEnd DATE, IssueDate DATE, DueDate DATE, Status NVARCHAR(40),
                   Total DECIMAL(18,2), AmountPaid DECIMAL(18,2), Balance DECIMAL(18,2), DaysOverdue INT);
CREATE TABLE #out (Customer NVARCHAR(400), OpenInvoices INT, Outstanding DECIMAL(18,2), NotYetDue DECIMAL(18,2), O1 DECIMAL(18,2), O2 DECIMAL(18,2),
                   O3 DECIMAL(18,2), O4 DECIMAL(18,2), OldestDueDate DATE);
CREATE TABLE #onb (EmployeeNo NVARCHAR(400), Employee NVARCHAR(400), Department NVARCHAR(400), JobTitle NVARCHAR(400), StartDate DATE, Status NVARCHAR(40),
                   TasksDone INT, TasksTotal INT, CompletePct DECIMAL(9,1), OverdueTasks INT, NextTask NVARCHAR(400), NextDue DATE);
CREATE TABLE #dept (Department NVARCHAR(400), HiringRequests INT, ApprovedPositions INT, OpenJobs INT, Applications INT, Hires INT, AvgDaysToHire DECIMAL(9,1), Headcount INT);
CREATE TABLE #rs (RequisitionNo NVARCHAR(400), Title NVARCHAR(400), Department NVARCHAR(400), Headcount INT, Status NVARCHAR(40), RequestedBy NVARCHAR(400),
                  SubmittedAt DATETIME2(0), DecidedBy NVARCHAR(400), DecidedAt DATETIME2(0), DaysWaiting INT, JobsCreated INT, Hired INT);

/* ============================== CATALOG AND ROLES ============================== */
INSERT @r VALUES (N'C01 the catalog holds the 19 required reports (8 recruitment, 8 staffing, 3 HR), each backed by an existing procedure',
    IIF((SELECT COUNT(*) FROM report.ReportDefinitions) = 19
        AND (SELECT COUNT(*) FROM report.ReportDefinitions WHERE Category = 'Recruitment') = 8
        AND (SELECT COUNT(*) FROM report.ReportDefinitions WHERE Category = 'Staffing') = 8
        AND (SELECT COUNT(*) FROM report.ReportDefinitions WHERE Category = 'HR') = 3
        AND NOT EXISTS (SELECT 1 FROM report.ReportDefinitions WHERE OBJECT_ID(N'report.' + QUOTENAME(ProcedureName), N'P') IS NULL), 1, 0), N'');
DECLARE @vis NVARCHAR(200) = N'';
INSERT #list EXEC report.usp_ListReports @admin; SET @vis += CONCAT(N'admin=', @@ROWCOUNT); DELETE #list;
INSERT #list EXEC report.usp_ListReports @priya; SET @vis += CONCAT(N' recruiter=', (SELECT COUNT(*) FROM #list), N'/', (SELECT COUNT(*) FROM #list WHERE Category = 'HR'));
SET @n = (SELECT COUNT(*) FROM #list WHERE CanFilterCustomer = 1); DELETE #list;
INSERT #list EXEC report.usp_ListReports @anita; SET @vis += CONCAT(N' hr=', (SELECT COUNT(*) FROM #list), N'/', (SELECT COUNT(*) FROM #list WHERE Category = 'Staffing')); DELETE #list;
INSERT #list EXEC report.usp_ListReports @arjun; SET @vis += CONCAT(N' customer=', (SELECT COUNT(*) FROM #list), N'/', (SELECT COUNT(*) FROM #list WHERE Category = 'Staffing'));
SET @n2 = (SELECT COUNT(*) FROM #list WHERE CanFilterCustomer = 1); DELETE #list;
INSERT #list EXEC report.usp_ListReports @ravi; SET @vis += CONCAT(N' contractor=', (SELECT COUNT(*) FROM #list)); DELETE #list;
INSERT #list EXEC report.usp_ListReports @divya; SET @vis += CONCAT(N' candidate=', (SELECT COUNT(*) FROM #list)); DELETE #list;
INSERT @r VALUES (N'C02 each role is offered exactly its reports (admin 19, recruiter 16 without HR, HR 11 without staffing, customer the 8 staffing ones, none for contractors/candidates); only staff may pick a customer',
    IIF(@vis = N'admin=19 recruiter=16/0 hr=11/0 customer=8/8 contractor=0 candidate=0' AND @n = 8 AND @n2 = 0, 1, 0), @vis);

SET @e = 0;  BEGIN TRY EXEC report.usp_RunReport @arjun, 'pipeline'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
SET @e2 = 0; BEGIN TRY EXEC report.usp_RunReport @anita, 'placements'; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
SET @e3 = 0; BEGIN TRY EXEC report.usp_RunReport @divya, 'time-to-hire'; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'C03 a customer cannot run recruitment reports, HR cannot run staffing reports, a candidate runs none (50005)', IIF(@e = 50005 AND @e2 = 50005 AND @e3 = 50005, 1, 0), CONCAT(N'err=', @e, N'/', @e2, N'/', @e3));
SET @e = 0;  BEGIN TRY EXEC report.usp_RunReport @admin, 'no-such-report'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
SET @e2 = 0; BEGIN TRY EXEC report.usp_Rpt_Pipeline @arjun; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'C04 an unknown report is 404 (50004); calling a report procedure directly still checks the role (50005)', IIF(@e = 50004 AND @e2 = 50005, 1, 0), CONCAT(N'err=', @e, N'/', @e2));
SET @e = 0;  BEGIN TRY EXEC report.usp_RunReport @admin, 'pipeline', '2026-02-01', '2026-01-01'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
SET @e2 = 0; BEGIN TRY EXEC report.usp_RunReport @admin, 'expiring-contracts', NULL, NULL, NULL, 0; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
SET @e3 = 0; BEGIN TRY EXEC report.usp_RunReport @admin, 'pipeline', '1900-01-01', NULL; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'C05 parameters are validated: start after end, days outside 1-365 and absurd dates are refused (50001)', IIF(@e = 50001 AND @e2 = 50001 AND @e3 = 50001, 1, 0), CONCAT(N'err=', @e, N'/', @e2, N'/', @e3));

/* ============================== RECRUITMENT: reports match independent counts ============================== */
INSERT #openreq EXEC report.usp_RunReport @admin, 'open-requisitions';
INSERT @r VALUES (N'R01 open requisitions = the open jobs, with each job''s application, in-progress and hired counts',
    IIF((SELECT COUNT(*) FROM #openreq) = (SELECT COUNT(*) FROM rec.JobRequisitions WHERE Status = 'Open') AND (SELECT COUNT(*) FROM #openreq) > 0
        AND NOT EXISTS (SELECT 1 FROM #openreq o JOIN rec.JobRequisitions j ON j.JobCode = o.JobCode
                        WHERE o.Applications <> (SELECT COUNT(*) FROM cand.JobApplications a JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId WHERE p.JobRequisitionId = j.JobRequisitionId)
                           OR o.Hired <> (SELECT COUNT(*) FROM cand.JobApplications a JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId WHERE p.JobRequisitionId = j.JobRequisitionId AND a.Status = 'Hired')
                           OR o.InProgress + o.Hired + (SELECT COUNT(*) FROM cand.JobApplications a JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId
                                                         WHERE p.JobRequisitionId = j.JobRequisitionId AND a.Status IN ('Rejected', 'Withdrawn')) <> o.Applications), 1, 0),
    CONCAT(N'rows=', (SELECT COUNT(*) FROM #openreq)));

INSERT #abs EXEC report.usp_RunReport @admin, 'applications-by-status';
INSERT @r VALUES (N'R02 applications by status: one row per stage, each equal to a direct count, shares adding up to 100 %',
    IIF((SELECT COUNT(*) FROM #abs) = 9 AND (SELECT SUM(Applications) FROM #abs) = (SELECT COUNT(*) FROM cand.JobApplications)
        AND NOT EXISTS (SELECT 1 FROM #abs x WHERE x.Applications <> (SELECT COUNT(*) FROM cand.JobApplications a WHERE a.Status = x.Status))
        AND ABS((SELECT SUM(SharePct) FROM #abs) - 100) <= 0.5, 1, 0), CONCAT(N'sum=', (SELECT SUM(Applications) FROM #abs), N' share=', (SELECT SUM(SharePct) FROM #abs)));
DELETE #abs; INSERT #abs EXEC report.usp_RunReport @admin, 'applications-by-status', '2099-01-01', '2099-12-31';
SET @n = (SELECT SUM(Applications) FROM #abs);
DECLARE @first DATE = (SELECT CAST(MIN(AppliedAt) AS DATE) FROM cand.JobApplications);
DELETE #abs; INSERT #abs EXEC report.usp_RunReport @admin, 'applications-by-status', @first, @first;
INSERT @r VALUES (N'R03 the date range filters: a future range gives zero, a one-day range gives exactly that day''s applications (inclusive end day)',
    IIF(@n = 0 AND (SELECT SUM(Applications) FROM #abs) = (SELECT COUNT(*) FROM cand.JobApplications WHERE CAST(AppliedAt AS DATE) = @first) AND (SELECT SUM(Applications) FROM #abs) > 0, 1, 0),
    CONCAT(N'future=', @n, N' day=', (SELECT SUM(Applications) FROM #abs)));

INSERT #pipe EXEC report.usp_RunReport @admin, 'pipeline';
INSERT @r VALUES (N'R04 pipeline: totals and every stage per job match the existing pipeline view (computed independently)',
    IIF((SELECT SUM(Total) FROM #pipe) = (SELECT COUNT(*) FROM cand.JobApplications)
        AND NOT EXISTS (SELECT 1 FROM #pipe x JOIN report.vw_RecruitmentPipeline v ON v.JobCode = x.JobCode
                        WHERE x.Total <> v.Total OR x.Applied <> v.Applied OR x.Screening <> v.Screening OR x.Shortlisted <> v.Shortlisted OR x.Interview <> v.Interview
                           OR x.Selected <> v.Selected OR x.OfferStage <> v.OfferStage OR x.Hired <> v.Hired OR x.Rejected <> v.Rejected OR x.Withdrawn <> v.Withdrawn)
        AND (SELECT COUNT(*) FROM #pipe) = (SELECT COUNT(*) FROM rec.JobRequisitions WHERE Status <> 'Draft'), 1, 0), CONCAT(N'total=', (SELECT SUM(Total) FROM #pipe)));

INSERT #src EXEC report.usp_RunReport @admin, 'sourcing';
INSERT @r VALUES (N'R05 sourcing: applications and hires across sources add up to all applications and all hires; LinkedIn matches a direct count',
    IIF((SELECT SUM(Applications) FROM #src) = (SELECT COUNT(*) FROM cand.JobApplications)
        AND (SELECT SUM(Hired) FROM #src) = (SELECT COUNT(*) FROM cand.JobApplications WHERE Status = 'Hired')
        AND (SELECT Applications FROM #src WHERE Source = N'LinkedIn') = (SELECT COUNT(*) FROM cand.JobApplications a JOIN cand.Candidates c ON c.CandidateId = a.CandidateId
                                                                         JOIN rec.RecruitmentSources s ON s.SourceId = COALESCE(a.SourceId, c.SourceId) WHERE s.Name = N'LinkedIn'), 1, 0),
    CONCAT(N'sum=', (SELECT SUM(Applications) FROM #src)));

INSERT #ivc EXEC report.usp_RunReport @admin, 'interview-conversion';
INSERT @r VALUES (N'R06 interview conversion: interviews, completed ones and feedback add up to the internal interviews and their feedback',
    IIF((SELECT SUM(Interviews) FROM #ivc) = (SELECT COUNT(*) FROM cand.Interviews WHERE JobApplicationId IS NOT NULL)
        AND (SELECT SUM(Completed) FROM #ivc) = (SELECT COUNT(*) FROM cand.Interviews WHERE JobApplicationId IS NOT NULL AND Status = 'Completed')
        AND (SELECT SUM(FeedbackGiven) FROM #ivc) = (SELECT COUNT(*) FROM cand.InterviewFeedback f JOIN cand.Interviews i ON i.InterviewId = f.InterviewId WHERE i.JobApplicationId IS NOT NULL)
        AND (SELECT SUM(CandidatesInterviewed) FROM #ivc) = (SELECT COUNT(DISTINCT JobApplicationId) FROM cand.Interviews WHERE JobApplicationId IS NOT NULL AND Status = 'Completed')
        AND NOT EXISTS (SELECT 1 FROM #ivc WHERE ReachedOffer > CandidatesInterviewed OR ConversionPct <> CAST(CASE WHEN CandidatesInterviewed = 0 THEN 0 ELSE 100.0 * ReachedOffer / CandidatesInterviewed END AS DECIMAL(9,1))), 1, 0),
    CONCAT(N'interviews=', (SELECT SUM(Interviews) FROM #ivc)));

INSERT #offer EXEC report.usp_RunReport @admin, 'offer-acceptance';
INSERT @r VALUES (N'R07 offer acceptance: offers, accepted, declined and open add up to the offers table',
    IIF((SELECT SUM(Offers) FROM #offer) = (SELECT COUNT(*) FROM cand.JobOffers)
        AND (SELECT SUM(Accepted) FROM #offer) = (SELECT COUNT(*) FROM cand.JobOffers WHERE Status = 'Accepted')
        AND (SELECT SUM(Declined) FROM #offer) = (SELECT COUNT(*) FROM cand.JobOffers WHERE Status = 'Declined')
        AND (SELECT SUM(Offers) FROM #offer) = (SELECT SUM(Accepted + Declined + Expired + StillOpen + RejectedInternally) FROM #offer), 1, 0),
    CONCAT(N'offers=', (SELECT SUM(Offers) FROM #offer)));

INSERT #tth EXEC report.usp_RunReport @admin, 'time-to-hire';
INSERT @r VALUES (N'R08 time to hire: one row per hire, and the days equal cand.fn_TimeToHireDays',
    IIF((SELECT COUNT(*) FROM #tth) = (SELECT COUNT(*) FROM cand.JobApplications WHERE Status = 'Hired') AND (SELECT COUNT(*) FROM #tth) > 0
        AND (SELECT SUM(DaysToHire) FROM #tth) = (SELECT SUM(cand.fn_TimeToHireDays(ApplicationId)) FROM cand.JobApplications WHERE Status = 'Hired'), 1, 0),
    CONCAT(N'rows=', (SELECT COUNT(*) FROM #tth)));

INSERT #perf EXEC report.usp_RunReport @admin, 'recruiter-performance';
INSERT @r VALUES (N'R09 recruiter performance: applications, hires, submissions and placements per recruiter match the existing performance view',
    IIF((SELECT COUNT(*) FROM #perf) = (SELECT COUNT(*) FROM report.vw_RecruitmentPerformance v JOIN sec.Users u ON u.UserId = v.RecruiterUserId WHERE u.IsActive = 1)
        AND NOT EXISTS (SELECT 1 FROM #perf p JOIN report.vw_RecruitmentPerformance v ON v.Recruiter = p.Recruiter
                        WHERE p.Applications <> v.Applications OR p.Hires <> ISNULL(v.Hires, 0) OR p.StaffingSubmissions <> v.StaffingSubmissions
                           OR p.Placements <> v.Placements OR p.OffersCreated <> v.OffersCreated OR p.OffersAccepted <> v.OffersAccepted), 1, 0),
    CONCAT(N'rows=', (SELECT COUNT(*) FROM #perf)));

/* ============================== STAFFING: counts, customer isolation, pay-rate secrecy ============================== */
INSERT #creq EXEC report.usp_RunReport @admin, 'staffing-requests';
SET @n = (SELECT COUNT(*) FROM #creq); SET @n2 = (SELECT SUM(Submissions) FROM #creq);
DELETE #creq; INSERT #creq EXEC report.usp_RunReport @arjun, 'staffing-requests';
INSERT @r VALUES (N'S01 staffing requests: all requests with their submissions for staff; a customer gets only its own requests',
    IIF(@n = (SELECT COUNT(*) FROM staff.CustomerRequisitions) AND @n2 = (SELECT COUNT(*) FROM staff.SubmittedCandidates)
        AND (SELECT COUNT(*) FROM #creq) = (SELECT COUNT(*) FROM staff.CustomerRequisitions WHERE CustomerId = @apex) AND (SELECT COUNT(*) FROM #creq) > 0
        AND NOT EXISTS (SELECT 1 FROM #creq WHERE Customer <> @apexName), 1, 0), CONCAT(N'all=', @n, N' apex=', (SELECT COUNT(*) FROM #creq)));

INSERT #subs EXEC report.usp_RunReport @admin, 'submissions';
SET @n = (SELECT COUNT(*) FROM #subs);
DELETE #subs; INSERT #subs EXEC report.usp_RunReport @priya, 'submissions', NULL, NULL, @bright;
SET @n2 = (SELECT COUNT(*) FROM #subs);
DELETE #subs; INSERT #subs EXEC report.usp_RunReport @arjun, 'submissions';
INSERT @r VALUES (N'S02 submissions: all for staff, a staff filter by customer works, and a customer sees only its own',
    IIF(@n = (SELECT COUNT(*) FROM staff.SubmittedCandidates) AND @n2 = (SELECT COUNT(*) FROM staff.SubmittedCandidates WHERE CustomerId = @bright)
        AND (SELECT COUNT(*) FROM #subs) = (SELECT COUNT(*) FROM staff.SubmittedCandidates WHERE CustomerId = @apex) AND NOT EXISTS (SELECT 1 FROM #subs WHERE Customer <> @apexName), 1, 0),
    CONCAT(N'all=', @n, N' bright=', @n2, N' apex=', (SELECT COUNT(*) FROM #subs)));

SET @e = 0;  BEGIN TRY EXEC report.usp_RunReport @arjun, 'submissions', NULL, NULL, @bright; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
SET @e2 = 0; BEGIN TRY EXEC report.usp_RunReport @priya, 'submissions', NULL, NULL, -5; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
SET @e3 = 0; BEGIN TRY DELETE #subs; INSERT #subs EXEC report.usp_RunReport @arjun, 'submissions', NULL, NULL, @apex; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'S03 ISOLATION: a customer asking for another customer''s data is "not found" (50004), as is an unknown customer for staff; its own id works',
    IIF(@e = 50004 AND @e2 = 50004 AND @e3 = 0 AND (SELECT COUNT(*) FROM #subs) > 0, 1, 0), CONCAT(N'err=', @e, N'/', @e2, N'/', @e3));

INSERT #plS EXEC report.usp_RunReport @admin, 'placements';
SET @e = 0; BEGIN TRY INSERT #plC EXEC report.usp_RunReport @arjun, 'placements'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); SET @m = ERROR_MESSAGE(); END CATCH
INSERT @r VALUES (N'S04 placements: every active placement with its current rates and margin for staff; a customer''s result has no pay rate or margin columns and only its own placements',
    IIF((SELECT COUNT(*) FROM #plS) = (SELECT COUNT(*) FROM staff.Placements WHERE Status <> 'Cancelled') AND (SELECT COUNT(*) FROM #plS) > 0
        AND NOT EXISTS (SELECT 1 FROM #plS WHERE PayRate IS NULL OR PayRate > BillRate OR MarginPct <> CAST(100.0 * (BillRate - PayRate) / BillRate AS DECIMAL(9,1)))
        AND @e = 0 AND (SELECT COUNT(*) FROM #plC) = (SELECT COUNT(*) FROM staff.Placements WHERE Status <> 'Cancelled' AND CustomerId = @apex)
        AND NOT EXISTS (SELECT 1 FROM #plC WHERE Customer <> @apexName), 1, 0), CONCAT(N'err=', @e, N' ', @m));

INSERT #act EXEC report.usp_RunReport @admin, 'active-contractors';
SET @n = (SELECT COUNT(*) FROM #act);
DELETE #act; INSERT #act EXEC report.usp_RunReport @arjun, 'active-contractors';
INSERT @r VALUES (N'S05 active contractors equal the active-contractor view; a customer sees only contractors working for it',
    IIF(@n = (SELECT COUNT(*) FROM report.vw_ActiveContractors) AND @n > 0
        AND (SELECT COUNT(*) FROM #act) = (SELECT COUNT(*) FROM report.vw_ActiveContractors WHERE CustomerId = @apex) AND NOT EXISTS (SELECT 1 FROM #act WHERE Customer <> @apexName), 1, 0),
    CONCAT(N'all=', @n, N' apex=', (SELECT COUNT(*) FROM #act)));

INSERT #exp EXEC report.usp_RunReport @admin, 'expiring-contracts';
SET @n = (SELECT COUNT(*) FROM #exp);
DELETE #exp; INSERT #exp EXEC report.usp_RunReport @admin, 'expiring-contracts', NULL, NULL, NULL, 365;
INSERT @r VALUES (N'S06 expiring contracts: the default 30 days equals the expiring-contracts view; a 365-day window counts directly and nothing lies beyond it',
    IIF(@n = (SELECT COUNT(*) FROM report.vw_ExpiringContracts)
        AND (SELECT COUNT(*) FROM #exp) = (SELECT COUNT(*) FROM staff.Contracts WHERE Status IN ('Active', 'Expiring') AND EndDate <= DATEADD(DAY, 365, @today))
        AND NOT EXISTS (SELECT 1 FROM #exp WHERE DaysToExpiry > 365), 1, 0), CONCAT(N'30d=', @n, N' 365d=', (SELECT COUNT(*) FROM #exp)));

INSERT #pts EXEC report.usp_RunReport @admin, 'pending-timesheets';
SET @n = (SELECT COUNT(*) FROM #pts); SET @n2 = (SELECT SUM(TotalHours) FROM #pts);
DELETE #pts; INSERT #pts EXEC report.usp_RunReport @arjun, 'pending-timesheets';
INSERT @r VALUES (N'S07 pending timesheets: all submitted timesheets and their hours; a customer sees only its own',
    IIF(@n = (SELECT COUNT(*) FROM [time].Timesheets WHERE Status = 'Submitted') AND @n2 = (SELECT SUM(TotalHours) FROM [time].Timesheets WHERE Status = 'Submitted')
        AND (SELECT COUNT(*) FROM #pts) = (SELECT COUNT(*) FROM [time].Timesheets WHERE Status = 'Submitted' AND CustomerId = @apex), 1, 0),
    CONCAT(N'all=', @n, N' apex=', (SELECT COUNT(*) FROM #pts)));

INSERT #inv EXEC report.usp_RunReport @admin, 'customer-invoices';
SET @n = (SELECT COUNT(*) FROM #inv);
DELETE #inv; INSERT #inv EXEC report.usp_RunReport @arjun, 'customer-invoices';
INSERT @r VALUES (N'S08 customer invoices: every invoice for staff with balance = total - payments; a customer sees only its own issued invoices (no drafts)',
    IIF(@n = (SELECT COUNT(*) FROM bill.Invoices)
        AND (SELECT COUNT(*) FROM #inv) = (SELECT COUNT(*) FROM bill.Invoices WHERE CustomerId = @apex AND Status <> 'Draft')
        AND NOT EXISTS (SELECT 1 FROM #inv WHERE Status = 'Draft' OR Customer <> @apexName)
        AND NOT EXISTS (SELECT 1 FROM #inv x JOIN bill.Invoices i ON i.InvoiceNo = x.InvoiceNo
                        WHERE i.Status <> 'Void' AND x.Balance <> i.Total - ISNULL((SELECT SUM(Amount) FROM bill.Payments p WHERE p.InvoiceId = i.InvoiceId), 0)), 1, 0),
    CONCAT(N'all=', @n, N' apex=', (SELECT COUNT(*) FROM #inv)));

INSERT #out EXEC report.usp_RunReport @admin, 'outstanding-payments';
INSERT @r VALUES (N'S09 outstanding payments: each customer''s outstanding amount equals bill.fn_CustomerOutstandingBalance and its ageing buckets add up to it',
    IIF((SELECT COUNT(*) FROM #out) = (SELECT COUNT(*) FROM org.Customers c WHERE EXISTS (SELECT 1 FROM bill.Invoices i WHERE i.CustomerId = c.CustomerId AND i.Status IN ('Issued', 'PartiallyPaid')))
        AND NOT EXISTS (SELECT 1 FROM #out o JOIN org.Customers c ON c.Name = o.Customer
                        WHERE o.Outstanding <> bill.fn_CustomerOutstandingBalance(c.CustomerId) OR o.Outstanding <> o.NotYetDue + o.O1 + o.O2 + o.O3 + o.O4)
        AND (SELECT COUNT(*) FROM #out) > 0, 1, 0), CONCAT(N'rows=', (SELECT COUNT(*) FROM #out)));
DELETE #out; INSERT #out EXEC report.usp_RunReport @arjun, 'outstanding-payments';
INSERT @r VALUES (N'S10 a customer''s outstanding-payments report holds only its own balance', IIF((SELECT COUNT(*) FROM #out) <= 1 AND NOT EXISTS (SELECT 1 FROM #out WHERE Customer <> @apexName)
    AND ISNULL((SELECT SUM(Outstanding) FROM #out), 0) = bill.fn_CustomerOutstandingBalance(@apex), 1, 0), N'');

/* ============================== HR ============================== */
INSERT #onb EXEC report.usp_RunReport @anita, 'onboarding';
INSERT @r VALUES (N'H01 onboarding: every current employee with tasks done/total and overdue tasks equal to direct counts',
    IIF((SELECT COUNT(*) FROM #onb) = (SELECT COUNT(*) FROM hr.Employees WHERE Status <> 'Terminated') AND (SELECT COUNT(*) FROM #onb) > 0
        AND NOT EXISTS (SELECT 1 FROM #onb o JOIN hr.Employees e ON e.EmployeeNo = o.EmployeeNo
                        WHERE o.TasksTotal <> (SELECT COUNT(*) FROM hr.EmployeeOnboarding t WHERE t.EmployeeId = e.EmployeeId)
                           OR o.TasksDone <> (SELECT COUNT(*) FROM hr.EmployeeOnboarding t WHERE t.EmployeeId = e.EmployeeId AND t.Status IN ('Completed', 'Waived'))
                           OR o.OverdueTasks <> (SELECT COUNT(*) FROM hr.EmployeeOnboarding t WHERE t.EmployeeId = e.EmployeeId AND t.Status NOT IN ('Completed', 'Waived') AND t.DueDate < @today)), 1, 0),
    CONCAT(N'rows=', (SELECT COUNT(*) FROM #onb)));

INSERT #dept EXEC report.usp_RunReport @anita, 'department-hiring';
INSERT @r VALUES (N'H02 department hiring: hires add up to the time-to-hire report, hiring requests and applications to their tables, headcount to current employees',
    IIF((SELECT SUM(Hires) FROM #dept) = (SELECT COUNT(*) FROM #tth)
        AND (SELECT SUM(HiringRequests) FROM #dept) = (SELECT COUNT(*) FROM hr.EmployeeRequisitions)
        AND (SELECT SUM(Applications) FROM #dept) = (SELECT COUNT(*) FROM cand.JobApplications)
        AND (SELECT SUM(Headcount) FROM #dept) = (SELECT COUNT(*) FROM hr.Employees WHERE Status IN ('Onboarding', 'Active', 'OnLeave')), 1, 0),
    CONCAT(N'hires=', (SELECT SUM(Hires) FROM #dept)));

INSERT #rs EXEC report.usp_RunReport @anita, 'requisition-status';
INSERT @r VALUES (N'H03 approved and pending requisitions: exactly the approved and submitted hiring requests; pending ones show days waiting and no decision',
    IIF((SELECT COUNT(*) FROM #rs) = (SELECT COUNT(*) FROM hr.EmployeeRequisitions WHERE Status IN ('Submitted', 'Approved'))
        AND (SELECT COUNT(*) FROM #rs WHERE Status = 'Pending') = (SELECT COUNT(*) FROM hr.EmployeeRequisitions WHERE Status = 'Submitted')
        AND NOT EXISTS (SELECT 1 FROM #rs WHERE Status = 'Pending' AND (DaysWaiting IS NULL OR DecidedBy IS NOT NULL))
        AND NOT EXISTS (SELECT 1 FROM #rs WHERE Status = 'Approved' AND DecidedBy IS NULL), 1, 0), CONCAT(N'rows=', (SELECT COUNT(*) FROM #rs)));

/* ============================== AUDIT (Phase 13, KI-043) ============================== */
DECLARE @runMark BIGINT = ISNULL((SELECT MAX(ReportRunId) FROM audit.ReportRuns), 0);
DELETE #rs; INSERT #rs EXEC report.usp_RunReport @anita, 'requisition-status', '2026-01-01', '2026-12-31', NULL, NULL, 'csv';
SET @e = 0;  BEGIN TRY EXEC report.usp_RunReport @arjun, 'pipeline'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
SET @e2 = 0; BEGIN TRY EXEC report.usp_RunReport @admin, 'pipeline', '2026-02-01', '2026-01-01'; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
SET @e3 = 0; BEGIN TRY EXEC report.usp_RunReport @admin, 'pipeline', NULL, NULL, NULL, NULL, 'pdf'; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'A01 a successful run is recorded with actor, report, filters and format; refused, invalid and unknown-format runs are not (50005/50001); every report run earlier in this suite was recorded',
    IIF((SELECT COUNT(*) FROM audit.ReportRuns WHERE ReportRunId > @runMark) = 1
        AND EXISTS (SELECT 1 FROM audit.ReportRuns WHERE ReportRunId > @runMark AND ActorUserId = @anita AND ReportCode = 'requisition-status'
                    AND OutputFormat = 'csv' AND FromDate = '2026-01-01' AND ToDate = '2026-12-31' AND CustomerId IS NULL)
        AND @e = 50005 AND @e2 = 50001 AND @e3 = 50001
        AND (SELECT COUNT(*) FROM audit.ReportRuns WHERE ReportRunId > @runsBefore AND ReportRunId <= @runMark) >= 19, 1, 0),
    CONCAT(N'new=', (SELECT COUNT(*) FROM audit.ReportRuns WHERE ReportRunId > @runMark), N' earlier=', (SELECT COUNT(*) FROM audit.ReportRuns WHERE ReportRunId > @runsBefore AND ReportRunId <= @runMark),
           N' err=', @e, N'/', @e2, N'/', @e3));

/* ============================== LEAST PRIVILEGE ============================== */
EXECUTE AS USER = 'tams_app_demo';
SET @e = 0;  BEGIN TRY DELETE #abs; INSERT #abs EXEC report.usp_RunReport @admin, 'applications-by-status'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
SET @e2 = 0; BEGIN TRY SELECT @n = COUNT(*) FROM cand.JobApplications; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
REVERT;
INSERT @r VALUES (N'P01 the application role runs reports through the procedures but cannot read the base tables (229)',
    IIF(@e = 0 AND @e2 = 229 AND (SELECT SUM(Applications) FROM #abs) = (SELECT COUNT(*) FROM cand.JobApplications), 1, 0), CONCAT(N'exec=', @e, N' select=', @e2));

IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
-- append-only: a THROW in a trigger dooms the transaction, so this probe gets a throw-away transaction of its own
DECLARE @e4 INT = 0, @e5 INT = 0;
BEGIN TRANSACTION;
INSERT audit.ReportRuns (ReportCode, ActorUserId, OutputFormat) VALUES ('pipeline', @admin, 'view');
BEGIN TRY UPDATE audit.ReportRuns SET ReportCode = 'tampered' WHERE ReportRunId = SCOPE_IDENTITY(); END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
BEGIN TRANSACTION;
INSERT audit.ReportRuns (ReportCode, ActorUserId, OutputFormat) VALUES ('pipeline', @admin, 'view');
BEGIN TRY DELETE audit.ReportRuns WHERE ReportRunId = SCOPE_IDENTITY(); END TRY BEGIN CATCH SET @e5 = ERROR_NUMBER(); END CATCH
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT @r VALUES (N'A02 the report-run record is append-only: changing or deleting it is refused (50010)', IIF(@e4 = 50010 AND @e5 = 50010, 1, 0), CONCAT(N'err=', @e4, N'/', @e5));
INSERT @r VALUES (N'Z01 the suite left no trace (its audit rows were rolled back)', IIF(@@TRANCOUNT = 0 AND ISNULL((SELECT MAX(ReportRunId) FROM audit.ReportRuns), 0) = @runsBefore, 1, 0), N'');

DECLARE @line NVARCHAR(700);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT CASE WHEN Ok = 1 THEN N'PASS  ' ELSE N'FAIL  ' END + Name + CASE WHEN Ok = 0 THEN N'  -> ' + ISNULL(Detail, N'') ELSE N'' END FROM @r ORDER BY Id;
OPEN c; FETCH NEXT FROM c INTO @line; WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c INTO @line; END CLOSE c; DEALLOCATE c;
DECLARE @total INT = (SELECT COUNT(*) FROM @r), @passed INT = (SELECT COUNT(*) FROM @r WHERE Ok = 1);
PRINT CONCAT(N'--- Report tests: ', @passed, N' passed, ', @total - @passed, N' failed, ', @total, N' total ---');
IF @passed <> @total RAISERROR(N'Report tests FAILED', 16, 1);
GO
