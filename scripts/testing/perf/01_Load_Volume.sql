/* ============================================================================
   TAMS - Phase 13 performance test: synthetic VOLUME for a disposable *_PerfTest copy (never the development database).
   About three years of activity for a mid-sized company:
     2,000 job requisitions + postings, 100,000 candidates, 300,000 applications (+ status history), ~74,000 interviews
     (+ panel + feedback), ~12,000 offers, 3,000 customer requests, 15,000 submissions, 3,000 contractors / placements /
     contracts / rates / assignments, ~78,000 weekly timesheets with ~390,000 entries, monthly invoices with their lines
     and payments.
   Every row satisfies the real constraints (keys, checks, filtered unique indexes). The audit triggers are switched off
   while this back-filled history is inserted (it is not user activity) and switched on again at the end; the
   application status-history trigger stays on, so the history table gets its 300,000 rows the normal way.
   Run through scripts\testing\Test-Performance.ps1 (Invoke-SqlScripts replaces the database name).
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON; SET XACT_ABORT ON;
IF DB_NAME() NOT LIKE N'%[_]PerfTest' THROW 50001, N'The volume loader only runs on a *_PerfTest copy.', 1;
GO
IF DB_NAME() NOT LIKE N'%[_]PerfTest' THROW 50001, N'The volume loader only runs on a *_PerfTest copy.', 1;
DISABLE TRIGGER cand.trg_Candidates_Audit ON cand.Candidates;
DISABLE TRIGGER rec.trg_JobRequisitions_Audit ON rec.JobRequisitions;
DISABLE TRIGGER cand.trg_Interviews_Audit ON cand.Interviews;
DISABLE TRIGGER cand.trg_JobOffers_Audit ON cand.JobOffers;
DISABLE TRIGGER staff.trg_Contracts_Audit ON staff.Contracts;
DISABLE TRIGGER [time].trg_Timesheets_Audit ON [time].Timesheets;
DISABLE TRIGGER bill.trg_Invoices_Audit ON bill.Invoices;
IF OBJECT_ID(N'dbo.zz_N') IS NOT NULL DROP TABLE dbo.zz_N;
CREATE TABLE dbo.zz_N (n INT NOT NULL PRIMARY KEY);
INSERT dbo.zz_N (n) SELECT TOP (300000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_objects a CROSS JOIN sys.all_objects b;
GO

DECLARE @now DATETIME2(0) = SYSUTCDATETIME(), @today DATE = CAST(SYSUTCDATETIME() AS DATE);
DECLARE @t0 DATETIME2(3) = SYSDATETIME();
DECLARE @admin INT = (SELECT TOP 1 ur.UserId FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId WHERE r.RoleName = N'Administrator' ORDER BY ur.UserId);
DECLARE @rec TABLE (i INT IDENTITY(0,1) PRIMARY KEY, UserId INT);
INSERT @rec (UserId) SELECT ur.UserId FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId WHERE r.RoleName = N'Recruiter' ORDER BY ur.UserId;
DECLARE @staff TABLE (i INT IDENTITY(0,1) PRIMARY KEY, UserId INT);
INSERT @staff (UserId) SELECT DISTINCT ur.UserId FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId WHERE r.RoleName IN (N'Recruiter', N'HRManager', N'Administrator');
DECLARE @dep TABLE (i INT IDENTITY(0,1) PRIMARY KEY, Id INT);  INSERT @dep (Id) SELECT DepartmentId FROM org.Departments ORDER BY DepartmentId;
DECLARE @src TABLE (i INT IDENTITY(0,1) PRIMARY KEY, Id INT);  INSERT @src (Id) SELECT SourceId FROM rec.RecruitmentSources ORDER BY SourceId;
DECLARE @cust TABLE (i INT IDENTITY(0,1) PRIMARY KEY, Id INT, UserId INT);
INSERT @cust (Id, UserId) SELECT c.CustomerId, (SELECT MIN(cu.UserId) FROM org.CustomerUsers cu WHERE cu.CustomerId = c.CustomerId) FROM org.Customers c ORDER BY c.CustomerId;
DECLARE @nrec INT = (SELECT COUNT(*) FROM @rec), @nstaff INT = (SELECT COUNT(*) FROM @staff), @ndep INT = (SELECT COUNT(*) FROM @dep),
        @nsrc INT = (SELECT COUNT(*) FROM @src), @ncust INT = (SELECT COUNT(*) FROM @cust);
DECLARE @empReq INT = (SELECT MIN(EmployeeRequisitionId) FROM hr.EmployeeRequisitions);

/* ---- job requisitions + postings (2,000) ---- */
DECLARE @jr0 INT = ISNULL((SELECT MAX(JobRequisitionId) FROM rec.JobRequisitions), 0);
INSERT rec.JobRequisitions (EmployeeRequisitionId, JobCode, Title, DepartmentId, EmploymentType, Openings, Status, OwnerRecruiterUserId, OpenedAt, ClosesBy, ClosedAt, CreatedAt, CreatedByUserId)
SELECT @empReq, N'PERF-' + RIGHT(N'00000' + CAST(n AS NVARCHAR(6)), 5),
       CHOOSE(n % 6 + 1, N'Software Engineer', N'Data Analyst', N'QA Engineer', N'Product Manager', N'DevOps Engineer', N'Business Analyst') + N' ' + CAST(n AS NVARCHAR(6)),
       d.Id, 'FullTime', 1 + n % 3,
       CASE WHEN n % 20 < 12 THEN 'Open' WHEN n % 20 < 17 THEN 'Closed' WHEN n % 20 < 19 THEN 'Filled' ELSE 'OnHold' END,
       r.UserId, DATEADD(DAY, -(n % 1095), @now), CAST(DATEADD(DAY, 60 - (n % 1095), @now) AS DATE),
       CASE WHEN n % 20 BETWEEN 12 AND 18 AND n % 1095 > 45 THEN DATEADD(DAY, 45 - (n % 1095), @now) END,
       DATEADD(DAY, -(n % 1095) - 3, @now), r.UserId
FROM dbo.zz_N JOIN @dep d ON d.i = n % @ndep JOIN @rec r ON r.i = n % @nrec
WHERE n <= 2000;

IF OBJECT_ID(N'dbo.zz_Post') IS NOT NULL DROP TABLE dbo.zz_Post;
CREATE TABLE dbo.zz_Post (i INT NOT NULL PRIMARY KEY, JobPostingId INT NOT NULL, PostedAt DATETIME2(0) NOT NULL);
DECLARE @jp0 INT = ISNULL((SELECT MAX(JobPostingId) FROM rec.JobPostings), 0);
INSERT rec.JobPostings (JobRequisitionId, SourceId, PostedAt, ClosesAt, Status, PostedByUserId, CreatedAt)
SELECT jr.JobRequisitionId, s.Id, jr.OpenedAt, DATEADD(DAY, 60, jr.OpenedAt), CASE WHEN jr.Status = 'Open' THEN 'Published' ELSE 'Closed' END, jr.OwnerRecruiterUserId, jr.OpenedAt
FROM rec.JobRequisitions jr JOIN @src s ON s.i = jr.JobRequisitionId % @nsrc
WHERE jr.JobRequisitionId > @jr0;
INSERT dbo.zz_Post (i, JobPostingId, PostedAt) SELECT ROW_NUMBER() OVER (ORDER BY JobPostingId) - 1, JobPostingId, PostedAt FROM rec.JobPostings WHERE JobPostingId > @jp0;
DECLARE @npost INT = (SELECT COUNT(*) FROM dbo.zz_Post);

/* ---- candidates (100,000) ---- */
DECLARE @c0 INT = ISNULL((SELECT MAX(CandidateId) FROM cand.Candidates), 0);
INSERT cand.Candidates (FirstName, LastName, Email, EmailNormalized, Phone, CurrentTitle, CurrentEmployer, TotalExperienceYears, ExpectedSalary, NoticePeriodDays, SourceId, Status, CreatedAt, CreatedByUserId)
SELECT CHOOSE(n % 20 + 1, N'Aarav', N'Vivaan', N'Aditya', N'Vihaan', N'Arjun', N'Sai', N'Reyansh', N'Ayaan', N'Krishna', N'Ishaan',
                          N'Saanvi', N'Aanya', N'Aadhya', N'Aaradhya', N'Ananya', N'Pari', N'Anika', N'Navya', N'Diya', N'Myra'),
       CHOOSE((n / 20) % 20 + 1, N'Sharma', N'Verma', N'Gupta', N'Kumar', N'Singh', N'Patel', N'Reddy', N'Nair', N'Iyer', N'Menon',
                          N'Joshi', N'Rao', N'Das', N'Bose', N'Kapoor', N'Mehta', N'Shah', N'Pillai', N'Desai', N'Malhotra'),
       N'perf.c' + CAST(n AS NVARCHAR(7)) + N'@candidate.example', N'PERF.C' + CAST(n AS NVARCHAR(7)) + N'@CANDIDATE.EXAMPLE',
       N'+91 9' + RIGHT(N'000000000' + CAST(n AS NVARCHAR(9)), 9),
       CHOOSE(n % 6 + 1, N'Software Engineer', N'Data Analyst', N'QA Engineer', N'Product Manager', N'DevOps Engineer', N'Business Analyst'),
       CHOOSE(n % 5 + 1, N'Infosys', N'TCS', N'Wipro', N'HCL', N'Startup'),
       n % 25, 300000 + (n % 50) * 20000, 30 * (n % 4), s.Id, CASE WHEN n % 50 = 0 THEN 'Inactive' ELSE 'Active' END,
       DATEADD(DAY, -(n % 1095), @now), r.UserId
FROM dbo.zz_N JOIN @src s ON s.i = n % @nsrc JOIN @rec r ON r.i = n % @nrec
WHERE n <= 100000;

-- identity values can have gaps (SQL Server's identity cache), so later steps pick candidates through a numbered list
IF OBJECT_ID(N'dbo.zz_Cand') IS NOT NULL DROP TABLE dbo.zz_Cand;
CREATE TABLE dbo.zz_Cand (i INT NOT NULL PRIMARY KEY, CandidateId INT NOT NULL);
INSERT dbo.zz_Cand (i, CandidateId) SELECT ROW_NUMBER() OVER (ORDER BY CandidateId) - 1, CandidateId FROM cand.Candidates WHERE CandidateId > @c0;
DECLARE @ncand INT = (SELECT COUNT(*) FROM dbo.zz_Cand);

/* ---- applications (3 per candidate = 300,000; status history by trigger) ---- */
DECLARE @a0 INT = ISNULL((SELECT MAX(ApplicationId) FROM cand.JobApplications), 0);
INSERT cand.JobApplications (CandidateId, JobPostingId, SourceId, Status, AppliedAt, UpdatedAt)
SELECT c.CandidateId, p.JobPostingId, c.SourceId,
       CASE WHEN x.b < 30 THEN 'Applied' WHEN x.b < 45 THEN 'Screening' WHEN x.b < 55 THEN 'Shortlisted' WHEN x.b < 65 THEN 'Interview'
            WHEN x.b < 68 THEN 'Selected' WHEN x.b < 70 THEN 'OfferStage' WHEN x.b < 72 THEN 'Hired' WHEN x.b < 95 THEN 'Rejected' ELSE 'Withdrawn' END,
       IIF(DATEADD(DAY, (c.k + J.j) % 50, p.PostedAt) > @now, @now, DATEADD(DAY, (c.k + J.j) % 50, p.PostedAt)), NULL
FROM (SELECT CandidateId, SourceId, CandidateId - @c0 AS k FROM cand.Candidates WHERE CandidateId > @c0) c
CROSS JOIN (VALUES (0), (1), (2)) J(j)
JOIN dbo.zz_Post p ON p.i = (c.k * 7 + J.j * 331) % @npost
CROSS APPLY (SELECT (c.k * 13 + J.j * 37) % 100 AS b) x;

/* ---- interviews (+ one panel member, feedback when completed) ---- */
DECLARE @i0 INT = ISNULL((SELECT MAX(InterviewId) FROM cand.Interviews), 0);
INSERT cand.Interviews (JobApplicationId, RoundNo, InterviewType, StartsAt, EndsAt, Mode, Status, ScheduledByUserId, CreatedAt)
SELECT a.ApplicationId, 1, 'Technical', s.StartsAt, DATEADD(HOUR, 1, s.StartsAt), CHOOSE(a.ApplicationId % 3 + 1, 'Video', 'Onsite', 'Phone'),
       CASE WHEN s.StartsAt > @now THEN 'Scheduled' WHEN a.ApplicationId % 25 = 0 THEN 'NoShow' WHEN a.ApplicationId % 30 = 0 THEN 'Cancelled' ELSE 'Completed' END,
       r.UserId, a.AppliedAt
FROM cand.JobApplications a JOIN @rec r ON r.i = a.ApplicationId % @nrec
CROSS APPLY (SELECT DATEADD(DAY, 7 + a.ApplicationId % 10, a.AppliedAt) AS StartsAt) s
WHERE a.ApplicationId > @a0 AND (a.Status IN ('Interview', 'Selected', 'OfferStage', 'Hired') OR (a.Status = 'Rejected' AND a.ApplicationId % 3 = 0));
INSERT cand.InterviewPanels (InterviewId, UserId, IsLead)
SELECT i.InterviewId, st.UserId, 1 FROM cand.Interviews i JOIN @staff st ON st.i = i.InterviewId % @nstaff WHERE i.InterviewId > @i0;
INSERT cand.InterviewFeedback (InterviewId, InterviewerUserId, Rating, Recommendation, SubmittedAt)
SELECT i.InterviewId, p.UserId, i.InterviewId % 5 + 1, CHOOSE(i.InterviewId % 5 + 1, 'StrongNo', 'No', 'Yes', 'Yes', 'StrongYes'), i.EndsAt
FROM cand.Interviews i JOIN cand.InterviewPanels p ON p.InterviewId = i.InterviewId
WHERE i.InterviewId > @i0 AND i.Status = 'Completed';

/* ---- offers for OfferStage / Hired applications ---- */
INSERT cand.JobOffers (ApplicationId, OfferNo, Designation, OfferedSalary, StartDate, ExpiresAt, Status, CreatedByUserId, SentAt, RespondedAt, CreatedAt)
SELECT a.ApplicationId, N'OFR-PERF-' + CAST(a.ApplicationId AS NVARCHAR(10)), N'Engineer', 600000 + (a.ApplicationId % 40) * 25000,
       CAST(DATEADD(DAY, 45, a.AppliedAt) AS DATE), DATEADD(DAY, 35, a.AppliedAt),
       CASE WHEN a.Status = 'Hired' THEN 'Accepted' WHEN a.ApplicationId % 4 = 0 THEN 'Declined' WHEN a.ApplicationId % 4 = 1 THEN 'Expired'
            WHEN a.ApplicationId % 4 = 2 THEN 'PendingApproval' ELSE 'Sent' END,
       r.UserId,
       CASE WHEN a.Status = 'Hired' OR a.ApplicationId % 4 IN (0, 1, 3) THEN DATEADD(DAY, 21, a.AppliedAt) END,
       CASE WHEN a.Status = 'Hired' OR a.ApplicationId % 4 = 0 THEN DATEADD(DAY, 25, a.AppliedAt) END,
       DATEADD(DAY, 20, a.AppliedAt)
FROM cand.JobApplications a JOIN @rec r ON r.i = a.ApplicationId % @nrec
WHERE a.ApplicationId > @a0 AND a.Status IN ('OfferStage', 'Hired');

/* ---- staffing: 3,000 customer requests, 5 submissions each; the first is selected and placed ---- */
DECLARE @cr0 INT = ISNULL((SELECT MAX(CustomerRequisitionId) FROM staff.CustomerRequisitions), 0);
INSERT staff.CustomerRequisitions (RequestNo, CustomerId, Title, Positions, SkillsRequired, StartDate, DurationMonths, MaxBillRate, Status, AssignedRecruiterUserId, CreatedByUserId, CreatedAt)
SELECT N'REQ-PERF-' + CAST(n AS NVARCHAR(6)), cu.Id, CHOOSE(n % 4 + 1, N'Java Developer', N'Data Engineer', N'Tester', N'Support Analyst') + N' ' + CAST(n AS NVARCHAR(6)),
       1 + n % 2, N'Java, SQL', CAST(DATEADD(DAY, 30 - (n % 1000), @now) AS DATE), 3 + n % 10, 2500,
       CASE WHEN n % 10 < 6 THEN 'Filled' WHEN n % 10 < 8 THEN 'Sourcing' WHEN n % 10 < 9 THEN 'Open' ELSE 'Cancelled' END,
       r.UserId, ISNULL(cu.UserId, r.UserId), DATEADD(DAY, -(n % 1000), @now)
FROM dbo.zz_N JOIN @cust cu ON cu.i = n % @ncust JOIN @rec r ON r.i = n % @nrec
WHERE n <= 3000;

DECLARE @s0 INT = ISNULL((SELECT MAX(SubmissionId) FROM staff.SubmittedCandidates), 0);
INSERT staff.SubmittedCandidates (CustomerRequisitionId, CustomerId, CandidateId, ProposedBillRate, Status, SubmittedByUserId, SubmittedAt)
SELECT q.CustomerRequisitionId, q.CustomerId, zc.CandidateId, 2000 + J.j * 50,
       CHOOSE(J.j + 1, 'Selected', 'Shortlisted', 'Rejected', 'Submitted', 'Interview'), q.AssignedRecruiterUserId, DATEADD(DAY, 3 + J.j, q.CreatedAt)
FROM (SELECT *, ROW_NUMBER() OVER (ORDER BY CustomerRequisitionId) - 1 AS k FROM staff.CustomerRequisitions WHERE CustomerRequisitionId > @cr0) q
CROSS JOIN (VALUES (0), (1), (2), (3), (4)) J(j)
JOIN dbo.zz_Cand zc ON zc.i = (q.k * 5 + J.j) % @ncand;

DECLARE @k0 INT = ISNULL((SELECT MAX(ContractorId) FROM staff.Contractors), 0);
INSERT staff.Contractors (ContractorNo, CandidateId, Status, CreatedAt, CreatedByUserId)
SELECT N'CTR-P' + CAST(s.SubmissionId AS NVARCHAR(10)), s.CandidateId, 'Active', DATEADD(DAY, 10, s.SubmittedAt), s.SubmittedByUserId
FROM staff.SubmittedCandidates s WHERE s.SubmissionId > @s0 AND s.Status = 'Selected';

DECLARE @pl0 INT = ISNULL((SELECT MAX(PlacementId) FROM staff.Placements), 0);
INSERT staff.Placements (SubmissionId, CustomerId, ContractorId, PlacementDate, Status, CreatedByUserId, CreatedAt)
SELECT s.SubmissionId, s.CustomerId, k.ContractorId, CAST(DATEADD(DAY, 14, s.SubmittedAt) AS DATE),
       CASE WHEN DATEADD(MONTH, 3 + s.SubmissionId % 10, DATEADD(DAY, 14, s.SubmittedAt)) < @now THEN 'Completed' ELSE 'Active' END,
       s.SubmittedByUserId, DATEADD(DAY, 14, s.SubmittedAt)
FROM staff.SubmittedCandidates s JOIN staff.Contractors k ON k.CandidateId = s.CandidateId AND k.ContractorId > @k0
WHERE s.SubmissionId > @s0 AND s.Status = 'Selected';

DECLARE @ct0 INT = ISNULL((SELECT MAX(ContractId) FROM staff.Contracts), 0);
INSERT staff.Contracts (ContractNo, PlacementId, CustomerId, StartDate, EndDate, Status, CreatedByUserId, CreatedAt)
SELECT N'CON-PERF-' + CAST(p.PlacementId AS NVARCHAR(10)), p.PlacementId, p.CustomerId, p.PlacementDate, e.EndDate,
       CASE WHEN e.EndDate < @today THEN 'Expired' WHEN e.EndDate <= DATEADD(DAY, 30, @today) THEN 'Expiring' ELSE 'Active' END,
       p.CreatedByUserId, p.CreatedAt
FROM staff.Placements p CROSS APPLY (SELECT DATEADD(MONTH, 3 + p.PlacementId % 10, p.PlacementDate) AS EndDate) e
WHERE p.PlacementId > @pl0;

INSERT staff.ContractRates (ContractId, PayRate, BillRate, Currency, EffectiveFrom, CreatedByUserId)
SELECT c.ContractId, 800 + (c.ContractId % 20) * 50, CAST((800 + (c.ContractId % 20) * 50) * 1.3 AS DECIMAL(10,2)), 'INR', c.StartDate, c.CreatedByUserId
FROM staff.Contracts c WHERE c.ContractId > @ct0;

DECLARE @as0 INT = ISNULL((SELECT MAX(AssignmentId) FROM staff.Assignments), 0);
INSERT staff.Assignments (ContractId, CustomerId, ContractorId, RoleTitle, HoursPerWeek, StartDate, EndDate, Status, CreatedAt)
SELECT c.ContractId, c.CustomerId, p.ContractorId, N'Consultant', 40, c.StartDate, c.EndDate, CASE WHEN c.Status = 'Expired' THEN 'Completed' ELSE 'Active' END, c.CreatedAt
FROM staff.Contracts c JOIN staff.Placements p ON p.PlacementId = c.PlacementId
WHERE c.ContractId > @ct0;

/* ---- weekly timesheets (Mon-Fri, 8 h) for every assignment up to last week ---- */
DECLARE @ts0 INT = ISNULL((SELECT MAX(TimesheetId) FROM [time].Timesheets), 0);
INSERT [time].Timesheets (AssignmentId, ContractorId, CustomerId, WeekStartDate, Status, TotalHours, SubmittedAt, CreatedAt)
SELECT a.AssignmentId, a.ContractorId, a.CustomerId, w.WeekStart,
       CASE WHEN w.WeekStart < DATEADD(DAY, -42, @today) THEN 'Invoiced' WHEN w.WeekStart < DATEADD(DAY, -14, @today) THEN 'Approved'
            WHEN a.AssignmentId % 7 = 0 THEN 'Draft' WHEN a.AssignmentId % 11 = 0 THEN 'Rejected' ELSE 'Submitted' END,
       40, CASE WHEN a.AssignmentId % 7 = 0 AND w.WeekStart >= DATEADD(DAY, -14, @today) THEN NULL ELSE DATEADD(DAY, 5, CAST(w.WeekStart AS DATETIME2(0))) END,
       DATEADD(DAY, 4, CAST(w.WeekStart AS DATETIME2(0)))
FROM staff.Assignments a
CROSS APPLY (SELECT DATEADD(DAY, (7 - DATEDIFF(DAY, '19000101', a.StartDate) % 7) % 7, a.StartDate) AS FirstMonday) f
JOIN dbo.zz_N wk ON wk.n <= 60
CROSS APPLY (SELECT DATEADD(WEEK, wk.n - 1, f.FirstMonday) AS WeekStart) w
WHERE a.AssignmentId > @as0 AND w.WeekStart <= a.EndDate AND w.WeekStart <= DATEADD(DAY, -7, @today);

INSERT [time].TimesheetEntries (TimesheetId, WorkDate, Hours, EntryType, IsBillable)
SELECT t.TimesheetId, DATEADD(DAY, d.n - 1, t.WeekStartDate), 8, 'Regular', 1
FROM [time].Timesheets t JOIN dbo.zz_N d ON d.n <= 5 WHERE t.TimesheetId > @ts0;

INSERT [time].TimesheetApprovals (TimesheetId, ApprovedByUserId, ApprovedAt)
SELECT t.TimesheetId, ISNULL(cu.UserId, @admin), DATEADD(DAY, 7, CAST(t.WeekStartDate AS DATETIME2(0)))
FROM [time].Timesheets t JOIN @cust cu ON cu.Id = t.CustomerId WHERE t.TimesheetId > @ts0 AND t.Status IN ('Approved', 'Invoiced');

/* ---- invoices: one per assignment and month of invoiced weeks; one line per entry; payments ---- */
INSERT bill.Invoices (InvoiceNo, CustomerId, PeriodStart, PeriodEnd, IssueDate, DueDate, Currency, Subtotal, TaxRate, TaxAmount, Total, Status, GeneratedByUserId, CreatedAt)
SELECT N'INV-P-' + CAST(g.AssignmentId AS NVARCHAR(10)) + N'-' + CONVERT(NVARCHAR(6), g.M, 112), g.CustomerId, g.M, EOMONTH(g.M),
       DATEADD(DAY, 5, EOMONTH(g.M)), DATEADD(DAY, 35, EOMONTH(g.M)), 'INR', 0, 18, 0, 0,
       CASE WHEN EOMONTH(g.M) < DATEADD(MONTH, -3, @today) THEN 'Paid' WHEN g.AssignmentId % 3 = 0 THEN 'PartiallyPaid' ELSE 'Issued' END,
       @admin, DATEADD(DAY, 5, CAST(EOMONTH(g.M) AS DATETIME2(0)))
FROM (SELECT t.AssignmentId, t.CustomerId, DATEFROMPARTS(YEAR(t.WeekStartDate), MONTH(t.WeekStartDate), 1) AS M
      FROM [time].Timesheets t WHERE t.TimesheetId > @ts0 AND t.Status = 'Invoiced'
      GROUP BY t.AssignmentId, t.CustomerId, DATEFROMPARTS(YEAR(t.WeekStartDate), MONTH(t.WeekStartDate), 1)) g;

INSERT bill.InvoiceLines (InvoiceId, TimesheetEntryId, Description, Hours, BillRate, LineTotal)
SELECT i.InvoiceId, e.EntryId, N'Consultant - ' + CONVERT(NVARCHAR(10), e.WorkDate, 120), e.Hours, r.BillRate, CAST(e.Hours * r.BillRate AS DECIMAL(12,2))
FROM [time].Timesheets t
JOIN [time].TimesheetEntries e ON e.TimesheetId = t.TimesheetId
JOIN staff.Assignments a ON a.AssignmentId = t.AssignmentId
JOIN staff.ContractRates r ON r.ContractId = a.ContractId
JOIN bill.Invoices i ON i.InvoiceNo = N'INV-P-' + CAST(t.AssignmentId AS NVARCHAR(10)) + N'-' + CONVERT(NVARCHAR(6), DATEFROMPARTS(YEAR(t.WeekStartDate), MONTH(t.WeekStartDate), 1), 112)
WHERE t.TimesheetId > @ts0 AND t.Status = 'Invoiced';

UPDATE i SET Subtotal = s.Sub, TaxAmount = CAST(ROUND(s.Sub * 0.18, 2) AS DECIMAL(12,2)), Total = s.Sub + CAST(ROUND(s.Sub * 0.18, 2) AS DECIMAL(12,2))
FROM bill.Invoices i JOIN (SELECT InvoiceId, SUM(LineTotal) AS Sub FROM bill.InvoiceLines GROUP BY InvoiceId) s ON s.InvoiceId = i.InvoiceId
WHERE i.InvoiceNo LIKE N'INV-P-%';

INSERT bill.Payments (InvoiceId, CustomerId, Amount, PaidOn, Method, Reference, RecordedByUserId, RecordedAt)
SELECT i.InvoiceId, i.CustomerId, CASE WHEN i.Status = 'Paid' THEN i.Total ELSE CAST(ROUND(i.Total / 2, 2) AS DECIMAL(12,2)) END,
       DATEADD(DAY, 25, i.IssueDate), 'BankTransfer', N'PERF-' + CAST(i.InvoiceId AS NVARCHAR(10)), @admin, DATEADD(DAY, 25, CAST(i.IssueDate AS DATETIME2(0)))
FROM bill.Invoices i WHERE i.InvoiceNo LIKE N'INV-P-%' AND i.Status IN ('Paid', 'PartiallyPaid') AND i.Total > 0;

PRINT CONCAT(N'Volume loaded in ', DATEDIFF(SECOND, @t0, SYSDATETIME()), N' s');
GO

ENABLE TRIGGER cand.trg_Candidates_Audit ON cand.Candidates;
ENABLE TRIGGER rec.trg_JobRequisitions_Audit ON rec.JobRequisitions;
ENABLE TRIGGER cand.trg_Interviews_Audit ON cand.Interviews;
ENABLE TRIGGER cand.trg_JobOffers_Audit ON cand.JobOffers;
ENABLE TRIGGER staff.trg_Contracts_Audit ON staff.Contracts;
ENABLE TRIGGER [time].trg_Timesheets_Audit ON [time].Timesheets;
ENABLE TRIGGER bill.trg_Invoices_Audit ON bill.Invoices;
DROP TABLE dbo.zz_Post; DROP TABLE dbo.zz_Cand; DROP TABLE dbo.zz_N;
EXEC sys.sp_updatestats;
GO
SELECT 'cand.Candidates' AS TableName, COUNT_BIG(*) AS Rows FROM cand.Candidates UNION ALL SELECT 'cand.JobApplications', COUNT_BIG(*) FROM cand.JobApplications
UNION ALL SELECT 'cand.ApplicationStatusHistory', COUNT_BIG(*) FROM cand.ApplicationStatusHistory UNION ALL SELECT 'cand.Interviews', COUNT_BIG(*) FROM cand.Interviews
UNION ALL SELECT 'cand.JobOffers', COUNT_BIG(*) FROM cand.JobOffers UNION ALL SELECT 'staff.SubmittedCandidates', COUNT_BIG(*) FROM staff.SubmittedCandidates
UNION ALL SELECT 'staff.Contracts', COUNT_BIG(*) FROM staff.Contracts UNION ALL SELECT '[time].Timesheets', COUNT_BIG(*) FROM [time].Timesheets
UNION ALL SELECT '[time].TimesheetEntries', COUNT_BIG(*) FROM [time].TimesheetEntries UNION ALL SELECT 'bill.Invoices', COUNT_BIG(*) FROM bill.Invoices
UNION ALL SELECT 'bill.InvoiceLines', COUNT_BIG(*) FROM bill.InvoiceLines UNION ALL SELECT 'bill.Payments', COUNT_BIG(*) FROM bill.Payments;
GO
