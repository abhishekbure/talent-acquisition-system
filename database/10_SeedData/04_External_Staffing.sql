/* ============================================================================
   TAMS - 10_SeedData / 04_External_Staffing.sql
   Demo data for the EXTERNAL staffing flow: customer requests -> submissions ->
   customer decisions -> interviews -> contractors -> placements -> contracts
   (separate PAY and BILL rates) -> assignments -> timesheets -> approvals ->
   invoices -> payments, plus rate cards and compliance.
   Candidates are the SAME Candidate Master rows used by the internal flow.
   Single transaction; skipped if customer requisitions already exist.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF EXISTS (SELECT 1 FROM staff.CustomerRequisitions) BEGIN PRINT 'External staffing data already present - skipped.'; RETURN; END
IF NOT EXISTS (SELECT 1 FROM cand.Candidates) BEGIN RAISERROR('Run 03_Internal_Recruitment.sql first.', 16, 1); RETURN; END

BEGIN TRAN;

DISABLE TRIGGER ALL ON cand.Interviews;
DISABLE TRIGGER ALL ON staff.Contracts;
DISABLE TRIGGER ALL ON [time].Timesheets;
DISABLE TRIGGER ALL ON bill.Invoices;

DECLARE @now    DATETIME2(0) = SYSUTCDATETIME();
DECLARE @today  DATE = CAST(SYSUTCDATETIME() AS DATE);
DECLARE @monday DATE = CAST(DATEADD(DAY, (DATEDIFF(DAY, '19000101', @today) / 7) * 7, '19000101') AS DATE);  -- Monday of this week
DECLARE @yr     CHAR(4) = CAST(YEAR(SYSUTCDATETIME()) AS CHAR(4));
DECLARE @priya INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'PRIYA.MENON@TAMS.LOCAL');
DECLARE @rahul INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'RAHUL.DESAI@TAMS.LOCAL');

/* ---- Customer staffing requests ---- */
INSERT staff.CustomerRequisitions (RequestNo, CustomerId, Title, Description, Positions, SkillsRequired, StartDate, DurationMonths,
                                   MaxBillRate, WorkLocation, Status, AssignedRecruiterUserId, CreatedByUserId, CreatedAt)
SELECT N'CR-' + @yr + N'-' + v.Seq, c.CustomerId, v.Title, v.Descr, v.Positions, v.Skills, DATEADD(DAY, v.StartDays, @today), v.Months,
       v.MaxRate, v.Loc, v.Status, r.UserId, cu.UserId, DATEADD(DAY, v.CreatedDays, @now)
FROM (VALUES
 (N'001', N'APEX',   N'Senior Java Developer', N'Modernise the shipment-tracking microservices.', 2, N'Java, Spring Boot, SQL, REST APIs', -105, 12, 1800, N'Mumbai',  'Sourcing', N'PRIYA.MENON@TAMS.LOCAL', N'ARJUN.SHAH@APEXLOGISTICS.EXAMPLE',       -110),
 (N'002', N'BRIGHT', N'.NET Developer',        N'Maintain and extend the customer billing portal.', 1, N'.NET Framework, C#, SQL Server',    -60, 12, 1600, N'Pune',    'Filled',   N'RAHUL.DESAI@TAMS.LOCAL', N'MEERA.IYER@BRIGHTWAVE.EXAMPLE',          -70),
 (N'003', N'CREST',  N'QA Automation Tester',  N'Build regression automation for the trading UI.',  1, N'Selenium, API testing',            20,  6, 1400, N'Mumbai',  'Open',     NULL,                      N'KABIR.MALHOTRA@CRESTLINE.EXAMPLE',       -1),
 (N'004', N'APEX',   N'Data Analyst',          N'Operational dashboards for fleet utilisation.',    1, N'SQL, Power BI',                    30,  6, 1300, N'Mumbai',  'InReview', N'PRIYA.MENON@TAMS.LOCAL', N'NEHA.VERMA@APEXLOGISTICS.EXAMPLE',       -6)
) v(Seq, CustCode, Title, Descr, Positions, Skills, StartDays, Months, MaxRate, Loc, Status, RecruiterEmail, CreatorEmail, CreatedDays)
JOIN org.Customers c ON c.CustomerCode = v.CustCode
JOIN sec.Users cu ON cu.EmailNormalized = v.CreatorEmail
LEFT JOIN sec.Users r ON r.EmailNormalized = v.RecruiterEmail;

/* ---- Recruiter submits shared-master candidates to customers ---- */
DECLARE @sub TABLE (Email NVARCHAR(256), ReqSeq NCHAR(3), SubmissionId INT, CustomerId INT, PRIMARY KEY (Email, ReqSeq));

INSERT staff.SubmittedCandidates (CustomerRequisitionId, CustomerId, CandidateId, ProposedBillRate, Status, SubmittedByUserId, SubmittedAt, Notes)
SELECT cr.CustomerRequisitionId, cr.CustomerId, c.CandidateId, v.Rate, v.Status, u.UserId, DATEADD(DAY, v.Days, @now), v.Notes
FROM (VALUES
 (N'ravi.kumar@contractor.example',   N'001', 1700, 'Selected',    N'PRIYA.MENON@TAMS.LOCAL', -100, N'9 years Java, available in 15 days.'),
 (N'rohan.gupta@candidate.example',   N'001', 1750, 'Interview',   N'PRIYA.MENON@TAMS.LOCAL',   -9, N'Strong backend profile; also in our internal pipeline.'),
 (N'aditya.rao@candidate.example',    N'001', 1650, 'Rejected',    N'PRIYA.MENON@TAMS.LOCAL',  -95, N'Full stack developer with Java exposure.'),
 (N'sneha.pillai@contractor.example', N'002', 1500, 'Selected',    N'RAHUL.DESAI@TAMS.LOCAL',  -62, N'7 years .NET, telecom domain.'),
 (N'imran.qureshi@candidate.example', N'002', 1550, 'Rejected',    N'RAHUL.DESAI@TAMS.LOCAL',  -60, N'DevOps background with .NET build experience.'),
 (N'pooja.nambiar@candidate.example', N'004', 1250, 'Submitted',   N'PRIYA.MENON@TAMS.LOCAL',   -3, N'3 years SQL and Power BI.'),
 (N'lakshmi.iyer@candidate.example',  N'004', 1300, 'Submitted',   N'PRIYA.MENON@TAMS.LOCAL',   -3, N'7 years business analysis, strong SQL.')
) v(Email, ReqSeq, Rate, Status, SubmitterEmail, Days, Notes)
JOIN cand.Candidates c ON c.EmailNormalized = UPPER(v.Email)
JOIN staff.CustomerRequisitions cr ON cr.RequestNo = N'CR-' + @yr + N'-' + v.ReqSeq
JOIN sec.Users u ON u.EmailNormalized = v.SubmitterEmail;

INSERT @sub (Email, ReqSeq, SubmissionId, CustomerId)
SELECT c.EmailNormalized, RIGHT(cr.RequestNo, 3), s.SubmissionId, s.CustomerId
FROM staff.SubmittedCandidates s
JOIN cand.Candidates c ON c.CandidateId = s.CandidateId
JOIN staff.CustomerRequisitions cr ON cr.CustomerRequisitionId = s.CustomerRequisitionId;

INSERT staff.CustomerCandidateDecisions (SubmissionId, CustomerId, DecidedByUserId, Decision, Comments, DecidedAt)
SELECT s.SubmissionId, s.CustomerId, u.UserId, v.Decision, v.Comments, DATEADD(DAY, v.Days, @now)
FROM (VALUES
 (N'ravi.kumar@contractor.example',   N'001', N'ARJUN.SHAH@APEXLOGISTICS.EXAMPLE',  'Shortlist', N'Good profile, please arrange an interview.', -98),
 (N'ravi.kumar@contractor.example',   N'001', N'ARJUN.SHAH@APEXLOGISTICS.EXAMPLE',  'Select',    N'Selected after interview.',                  -93),
 (N'rohan.gupta@candidate.example',   N'001', N'ARJUN.SHAH@APEXLOGISTICS.EXAMPLE',  'Shortlist', N'Please schedule a technical round.',          -7),
 (N'aditya.rao@candidate.example',    N'001', N'ARJUN.SHAH@APEXLOGISTICS.EXAMPLE',  'Reject',    N'Insufficient Java depth.',                   -92),
 (N'sneha.pillai@contractor.example', N'002', N'MEERA.IYER@BRIGHTWAVE.EXAMPLE',     'Shortlist', N'Looks suitable.',                            -58),
 (N'sneha.pillai@contractor.example', N'002', N'MEERA.IYER@BRIGHTWAVE.EXAMPLE',     'Select',    N'Selected - please proceed with the contract.',-55),
 (N'imran.qureshi@candidate.example', N'002', N'MEERA.IYER@BRIGHTWAVE.EXAMPLE',     'Reject',    N'Skills do not match the role.',              -54)
) v(Email, ReqSeq, DeciderEmail, Decision, Comments, Days)
JOIN @sub s ON s.Email = UPPER(v.Email) AND s.ReqSeq = v.ReqSeq
JOIN sec.Users u ON u.EmailNormalized = v.DeciderEmail;

/* ---- External interviews (tied to the submission and the customer) ---- */
DECLARE @eiv TABLE (Email NVARCHAR(256), InterviewId INT PRIMARY KEY);

INSERT cand.Interviews (SubmittedCandidateId, CustomerId, RoundNo, InterviewType, StartsAt, EndsAt, Mode, LocationOrLink, Status, ScheduledByUserId, CreatedAt)
SELECT s.SubmissionId, s.CustomerId, 1, 'Customer',
       DATEADD(HOUR, v.Hour, CAST(DATEADD(DAY, v.Days, @today) AS DATETIME2(0))),
       DATEADD(HOUR, v.Hour + 1, CAST(DATEADD(DAY, v.Days, @today) AS DATETIME2(0))),
       'Video', v.Link, v.Status, u.UserId, DATEADD(DAY, v.Days - 3, @now)
FROM (VALUES
 (N'ravi.kumar@contractor.example',   N'001', -96, 9,  N'https://meet.apexlogistics.example/room/1', 'Completed', N'PRIYA.MENON@TAMS.LOCAL'),
 (N'rohan.gupta@candidate.example',   N'001',   3, 11, N'https://meet.apexlogistics.example/room/2', 'Scheduled', N'PRIYA.MENON@TAMS.LOCAL'),
 (N'sneha.pillai@contractor.example', N'002', -57, 14, N'https://meet.brightwave.example/room/9',   'Completed', N'RAHUL.DESAI@TAMS.LOCAL')
) v(Email, ReqSeq, Days, Hour, Link, Status, SchedEmail)
JOIN @sub s ON s.Email = UPPER(v.Email) AND s.ReqSeq = v.ReqSeq
JOIN sec.Users u ON u.EmailNormalized = v.SchedEmail;

INSERT @eiv (Email, InterviewId)
SELECT c.EmailNormalized, i.InterviewId
FROM cand.Interviews i
JOIN staff.SubmittedCandidates s ON s.SubmissionId = i.SubmittedCandidateId
JOIN cand.Candidates c ON c.CandidateId = s.CandidateId;

INSERT cand.InterviewPanels (InterviewId, UserId, IsLead)
SELECT e.InterviewId, u.UserId, v.IsLead
FROM (VALUES
 (N'ravi.kumar@contractor.example',   N'ARJUN.SHAH@APEXLOGISTICS.EXAMPLE', 1), (N'ravi.kumar@contractor.example', N'PRIYA.MENON@TAMS.LOCAL', 0),
 (N'rohan.gupta@candidate.example',   N'ARJUN.SHAH@APEXLOGISTICS.EXAMPLE', 1), (N'rohan.gupta@candidate.example', N'NEHA.VERMA@APEXLOGISTICS.EXAMPLE', 0),
 (N'sneha.pillai@contractor.example', N'MEERA.IYER@BRIGHTWAVE.EXAMPLE',   1), (N'sneha.pillai@contractor.example', N'RAHUL.DESAI@TAMS.LOCAL', 0)
) v(Email, UserEmail, IsLead)
JOIN @eiv e ON e.Email = UPPER(v.Email)
JOIN sec.Users u ON u.EmailNormalized = v.UserEmail;

INSERT cand.InterviewFeedback (InterviewId, InterviewerUserId, Rating, Recommendation, Strengths, Concerns, SubmittedAt)
SELECT e.InterviewId, u.UserId, v.Rating, v.Rec, v.Strengths, v.Concerns, DATEADD(DAY, v.Days, @now)
FROM (VALUES
 (N'ravi.kumar@contractor.example',   N'ARJUN.SHAH@APEXLOGISTICS.EXAMPLE', 5, 'StrongYes', N'Deep Spring Boot and microservice experience.', NULL, -96),
 (N'sneha.pillai@contractor.example', N'MEERA.IYER@BRIGHTWAVE.EXAMPLE',   4, 'Yes',       N'Solid .NET and SQL Server skills.',            NULL, -57),
 (N'sneha.pillai@contractor.example', N'RAHUL.DESAI@TAMS.LOCAL',           4, 'Yes',       N'Good communication.',                          NULL, -57)
) v(Email, InterviewerEmail, Rating, Rec, Strengths, Concerns, Days)
JOIN @eiv e ON e.Email = UPPER(v.Email)
JOIN sec.Users u ON u.EmailNormalized = v.InterviewerEmail;

/* ---- Contractors (separate entity from Employees; reuse Candidate Master row) ---- */
INSERT staff.Contractors (ContractorNo, CandidateId, UserId, Status, CreatedAt, CreatedByUserId)
SELECT v.No, c.CandidateId, c.UserId, 'Active', DATEADD(DAY, v.Days, @now), u.UserId
FROM (VALUES
 (N'CTR-0001', N'ravi.kumar@contractor.example',   -92, N'PRIYA.MENON@TAMS.LOCAL'),
 (N'CTR-0002', N'sneha.pillai@contractor.example', -56, N'RAHUL.DESAI@TAMS.LOCAL')
) v(No, Email, Days, CreatorEmail)
JOIN cand.Candidates c ON c.EmailNormalized = UPPER(v.Email)
JOIN sec.Users u ON u.EmailNormalized = v.CreatorEmail;

INSERT staff.Placements (SubmissionId, CustomerId, ContractorId, PlacementDate, Status, CreatedByUserId, CreatedAt)
SELECT s.SubmissionId, s.CustomerId, ctr.ContractorId, DATEADD(DAY, v.Days, @today), 'Active', u.UserId, DATEADD(DAY, v.Days, @now)
FROM (VALUES
 (N'ravi.kumar@contractor.example',   N'001', N'CTR-0001', -92, N'PRIYA.MENON@TAMS.LOCAL'),
 (N'sneha.pillai@contractor.example', N'002', N'CTR-0002', -56, N'RAHUL.DESAI@TAMS.LOCAL')
) v(Email, ReqSeq, ContractorNo, Days, CreatorEmail)
JOIN @sub s ON s.Email = UPPER(v.Email) AND s.ReqSeq = v.ReqSeq
JOIN staff.Contractors ctr ON ctr.ContractorNo = v.ContractorNo
JOIN sec.Users u ON u.EmailNormalized = v.CreatorEmail;

INSERT staff.Contracts (ContractNo, PlacementId, CustomerId, StartDate, EndDate, Status, Terms, CreatedByUserId, CreatedAt)
SELECT N'CON-' + @yr + N'-' + v.Seq, pl.PlacementId, pl.CustomerId, DATEADD(DAY, v.StartDays, @today), DATEADD(DAY, v.EndDays, @today),
       v.Status, v.Terms, pl.CreatedByUserId, DATEADD(DAY, v.StartDays - 1, @now)
FROM (VALUES
 (N'001', N'CTR-0001', -90,  20, 'Expiring', N'Fixed-term engagement, 40 hours per week, 30 days notice by either party.'),
 (N'002', N'CTR-0002', -56, 180, 'Active',   N'Fixed-term engagement, 40 hours per week, 30 days notice by either party.')
) v(Seq, ContractorNo, StartDays, EndDays, Status, Terms)
JOIN staff.Contractors ctr ON ctr.ContractorNo = v.ContractorNo
JOIN staff.Placements pl ON pl.ContractorId = ctr.ContractorId;

-- PAY rate (what the contractor earns) and BILL rate (what the customer pays) are separate columns
INSERT staff.ContractRates (ContractId, PayRate, BillRate, OvertimePayMultiplier, OvertimeBillMultiplier, Currency, EffectiveFrom, CreatedByUserId)
SELECT ct.ContractId, v.Pay, v.Bill, 1.5, 1.5, 'INR', ct.StartDate, ct.CreatedByUserId
FROM (VALUES (N'001', 1250, 1700), (N'002', 1050, 1500)) v(Seq, Pay, Bill)
JOIN staff.Contracts ct ON ct.ContractNo = N'CON-' + @yr + N'-' + v.Seq;

INSERT staff.ContractExtensions (ContractId, PreviousEndDate, NewEndDate, Reason, ApprovedByUserId, CreatedAt)
SELECT ct.ContractId, DATEADD(DAY, -10, @today), DATEADD(DAY, 20, @today), N'Customer requested a 30-day extension.', @priya, DATEADD(DAY, -15, @now)
FROM staff.Contracts ct WHERE ct.ContractNo = N'CON-' + @yr + N'-001';

INSERT staff.Assignments (ContractId, CustomerId, ContractorId, RoleTitle, SiteLocation, HoursPerWeek, StartDate, EndDate, Status, CreatedAt)
SELECT ct.ContractId, ct.CustomerId, ctr.ContractorId, v.Role, v.Site, 40, ct.StartDate, ct.EndDate, 'Active', ct.CreatedAt
FROM (VALUES
 (N'001', N'CTR-0001', N'Senior Java Developer', N'Apex Logistics - Andheri, Mumbai'),
 (N'002', N'CTR-0002', N'.NET Developer',        N'Brightwave Telecom - Baner, Pune')
) v(Seq, ContractorNo, Role, Site)
JOIN staff.Contracts ct ON ct.ContractNo = N'CON-' + @yr + N'-' + v.Seq
JOIN staff.Contractors ctr ON ctr.ContractorNo = v.ContractorNo;

INSERT staff.ComplianceRecords (ContractorId, RecordType, Status, IssuedOn, ExpiresOn, VerifiedByUserId, VerifiedAt, Notes)
SELECT ctr.ContractorId, v.Type, v.Status, DATEADD(DAY, v.IssuedDays, @today), DATEADD(DAY, v.ExpiresDays, @today),
       CASE WHEN v.Status IN ('Verified','Expired') THEN @priya END,
       CASE WHEN v.Status IN ('Verified','Expired') THEN DATEADD(DAY, v.IssuedDays + 1, @now) END, v.Notes
FROM (VALUES
 (N'CTR-0001', 'BackgroundCheck',   'Verified', -95,  270, N'Cleared by third-party screening vendor.'),
 (N'CTR-0001', 'NDA',               'Verified', -92,  273, NULL),
 (N'CTR-0001', 'Identity',          'Verified', -95, 1800, NULL),
 (N'CTR-0002', 'BackgroundCheck',   'Verified', -60,  305, NULL),
 (N'CTR-0002', 'NDA',               'Pending',  -56,   30, N'Awaiting countersigned copy.'),
 (N'CTR-0002', 'Insurance',         'Expired', -375,  -10, N'Renewal certificate requested.')
) v(ContractorNo, Type, Status, IssuedDays, ExpiresDays, Notes)
JOIN staff.Contractors ctr ON ctr.ContractorNo = v.ContractorNo;

/* ---- Rate cards (customer default bill rates) ---- */
INSERT bill.RateCards (CustomerId, RoleCategory, StandardBillRate, Currency, EffectiveFrom)
SELECT c.CustomerId, v.Role, v.Rate, 'INR', DATEADD(DAY, -365, @today)
FROM (VALUES
 (N'APEX',   N'Senior Developer', 1700), (N'APEX',   N'Data Analyst',     1250), (N'APEX',   N'QA Automation', 1400),
 (N'BRIGHT', N'.NET Developer',   1500), (N'BRIGHT', N'Senior Developer', 1800),
 (N'CREST',  N'QA Automation',    1450), (N'CREST',  N'Business Analyst', 1500)
) v(Code, Role, Rate)
JOIN org.Customers c ON c.CustomerCode = v.Code;

/* ---- Timesheets: weekly, per assignment, covering every workflow state ---- */
DECLARE @ts TABLE (TimesheetId INT PRIMARY KEY, ContractorNo NVARCHAR(20), WeekOff INT, WeekStart DATE);

INSERT [time].Timesheets (AssignmentId, ContractorId, CustomerId, WeekStartDate, Status, SubmittedAt, CreatedAt)
SELECT a.AssignmentId, a.ContractorId, a.CustomerId, DATEADD(WEEK, v.WeekOff, @monday), v.Status,
       CASE WHEN v.Status = 'Draft' THEN NULL ELSE DATEADD(HOUR, 17, CAST(DATEADD(DAY, 4, DATEADD(WEEK, v.WeekOff, @monday)) AS DATETIME2(0))) END,
       DATEADD(DAY, 0, CAST(DATEADD(WEEK, v.WeekOff, @monday) AS DATETIME2(0)))
FROM (VALUES
 (N'CTR-0001', -4, 'Invoiced'), (N'CTR-0001', -3, 'Invoiced'), (N'CTR-0001', -2, 'Approved'), (N'CTR-0001', -1, 'Submitted'), (N'CTR-0001', 0, 'Draft'),
 (N'CTR-0002', -4, 'Invoiced'), (N'CTR-0002', -3, 'Approved'), (N'CTR-0002', -2, 'Rejected'), (N'CTR-0002', -1, 'Submitted'), (N'CTR-0002', 0, 'Draft')
) v(ContractorNo, WeekOff, Status)
JOIN staff.Contractors ctr ON ctr.ContractorNo = v.ContractorNo
JOIN staff.Assignments a ON a.ContractorId = ctr.ContractorId;

INSERT @ts (TimesheetId, ContractorNo, WeekOff, WeekStart)
SELECT t.TimesheetId, ctr.ContractorNo, DATEDIFF(WEEK, @monday, t.WeekStartDate), t.WeekStartDate
FROM [time].Timesheets t JOIN staff.Contractors ctr ON ctr.ContractorId = t.ContractorId;

-- Mon-Fri, 8 regular hours each; this week's draft only has days that have already passed.
INSERT [time].TimesheetEntries (TimesheetId, WorkDate, Hours, EntryType, IsBillable, Notes)
SELECT t.TimesheetId, DATEADD(DAY, d.n, t.WeekStart), 8, 'Regular', 1, NULL
FROM @ts t CROSS JOIN (VALUES (0),(1),(2),(3),(4)) d(n)
WHERE t.WeekOff < 0 OR DATEADD(DAY, d.n, t.WeekStart) < @today;

-- Overtime on the Friday of one of Ravi's weeks, so overtime billing is exercised
INSERT [time].TimesheetEntries (TimesheetId, WorkDate, Hours, EntryType, IsBillable, Notes)
SELECT t.TimesheetId, DATEADD(DAY, 4, t.WeekStart), 2, 'Overtime', 1, N'Release support'
FROM @ts t WHERE t.ContractorNo = N'CTR-0001' AND t.WeekOff = -2;

UPDATE t SET TotalHours = x.Total
FROM [time].Timesheets t
JOIN (SELECT TimesheetId, SUM(Hours) AS Total FROM [time].TimesheetEntries GROUP BY TimesheetId) x ON x.TimesheetId = t.TimesheetId;

INSERT [time].TimesheetApprovals (TimesheetId, ApprovedByUserId, ApprovedAt, Comments)
SELECT t.TimesheetId, u.UserId, DATEADD(HOUR, 10, CAST(DATEADD(DAY, 8, t.WeekStart) AS DATETIME2(0))), N'Hours verified.'
FROM @ts t
JOIN [time].Timesheets ts ON ts.TimesheetId = t.TimesheetId
JOIN sec.Users u ON u.EmailNormalized = CASE t.ContractorNo WHEN N'CTR-0001' THEN N'ARJUN.SHAH@APEXLOGISTICS.EXAMPLE'
                                                            ELSE N'MEERA.IYER@BRIGHTWAVE.EXAMPLE' END
WHERE ts.Status IN ('Approved', 'Invoiced');

INSERT [time].TimesheetRejections (TimesheetId, RejectedByUserId, Reason, RejectedAt)
SELECT t.TimesheetId, u.UserId, N'Friday hours do not match the site attendance log. Please correct and resubmit.',
       DATEADD(HOUR, 10, CAST(DATEADD(DAY, 8, t.WeekStart) AS DATETIME2(0)))
FROM @ts t JOIN sec.Users u ON u.EmailNormalized = N'MEERA.IYER@BRIGHTWAVE.EXAMPLE'
WHERE t.ContractorNo = N'CTR-0002' AND t.WeekOff = -2;

/* ---- Invoices built from approved billable entries x contract BILL rate ---- */
DECLARE @inv TABLE (Seq NCHAR(4), ContractorNo NVARCHAR(20), WeekOff INT, Status VARCHAR(15), InvoiceId INT);
INSERT @inv (Seq, ContractorNo, WeekOff, Status) VALUES
 (N'0001', N'CTR-0001', -4, 'Paid'),
 (N'0002', N'CTR-0002', -4, 'PartiallyPaid'),
 (N'0003', N'CTR-0001', -3, 'Issued');

INSERT bill.Invoices (InvoiceNo, CustomerId, PeriodStart, PeriodEnd, IssueDate, DueDate, Currency, TaxRate, Status, GeneratedByUserId, CreatedAt)
SELECT N'INV-' + @yr + N'-' + i.Seq, ts.CustomerId, ts.WeekStartDate, DATEADD(DAY, 6, ts.WeekStartDate),
       DATEADD(DAY, 10, ts.WeekStartDate), DATEADD(DAY, 10 + c.PaymentTermsDays, ts.WeekStartDate), 'INR', 18.00, i.Status,
       CASE i.ContractorNo WHEN N'CTR-0001' THEN @priya ELSE @rahul END,
       DATEADD(DAY, 10, CAST(ts.WeekStartDate AS DATETIME2(0)))
FROM @inv i
JOIN @ts t ON t.ContractorNo = i.ContractorNo AND t.WeekOff = i.WeekOff
JOIN [time].Timesheets ts ON ts.TimesheetId = t.TimesheetId
JOIN org.Customers c ON c.CustomerId = ts.CustomerId;

UPDATE i SET InvoiceId = bi.InvoiceId
FROM @inv i JOIN bill.Invoices bi ON bi.InvoiceNo = N'INV-' + @yr + N'-' + i.Seq;

INSERT bill.InvoiceLines (InvoiceId, TimesheetEntryId, Description, Hours, BillRate, LineTotal)
SELECT i.InvoiceId, e.EntryId,
       cd.FirstName + N' ' + cd.LastName + N' - ' + a.RoleTitle + N' - ' + CONVERT(NVARCHAR(10), e.WorkDate, 120) + N' (' + e.EntryType + N')',
       e.Hours,
       CASE e.EntryType WHEN 'Overtime' THEN CAST(r.BillRate * r.OvertimeBillMultiplier AS DECIMAL(10,2)) ELSE r.BillRate END,
       CAST(e.Hours * CASE e.EntryType WHEN 'Overtime' THEN CAST(r.BillRate * r.OvertimeBillMultiplier AS DECIMAL(10,2)) ELSE r.BillRate END AS DECIMAL(12,2))
FROM @inv i
JOIN @ts t ON t.ContractorNo = i.ContractorNo AND t.WeekOff = i.WeekOff
JOIN [time].TimesheetEntries e ON e.TimesheetId = t.TimesheetId AND e.IsBillable = 1
JOIN [time].Timesheets ts ON ts.TimesheetId = t.TimesheetId
JOIN staff.Assignments a ON a.AssignmentId = ts.AssignmentId
JOIN staff.ContractRates r ON r.ContractId = a.ContractId AND e.WorkDate >= r.EffectiveFrom AND (r.EffectiveTo IS NULL OR e.WorkDate <= r.EffectiveTo)
JOIN staff.Contractors ctr ON ctr.ContractorId = ts.ContractorId
JOIN cand.Candidates cd ON cd.CandidateId = ctr.CandidateId;

UPDATE inv SET Subtotal = x.Sub,
               TaxAmount = CAST(ROUND(x.Sub * inv.TaxRate / 100.0, 2) AS DECIMAL(12,2)),
               Total = x.Sub + CAST(ROUND(x.Sub * inv.TaxRate / 100.0, 2) AS DECIMAL(12,2))
FROM bill.Invoices inv
JOIN (SELECT InvoiceId, SUM(LineTotal) AS Sub FROM bill.InvoiceLines GROUP BY InvoiceId) x ON x.InvoiceId = inv.InvoiceId;

INSERT bill.Payments (InvoiceId, CustomerId, Amount, PaidOn, Method, Reference, RecordedByUserId, RecordedAt)
SELECT inv.InvoiceId, inv.CustomerId,
       CASE v.Seq WHEN N'0001' THEN inv.Total ELSE 40000.00 END,
       DATEADD(DAY, 20, inv.IssueDate), 'BankTransfer', v.Ref,
       CASE v.Seq WHEN N'0001' THEN @priya ELSE @rahul END,
       DATEADD(DAY, 20, CAST(inv.IssueDate AS DATETIME2(0)))
FROM (VALUES (N'0001', N'NEFT-APX-884201'), (N'0002', N'NEFT-BRW-190377')) v(Seq, Ref)
JOIN bill.Invoices inv ON inv.InvoiceNo = N'INV-' + @yr + N'-' + v.Seq;

ENABLE TRIGGER ALL ON cand.Interviews;
ENABLE TRIGGER ALL ON staff.Contracts;
ENABLE TRIGGER ALL ON [time].Timesheets;
ENABLE TRIGGER ALL ON bill.Invoices;

COMMIT;
PRINT 'External staffing demo data seeded.';
GO
