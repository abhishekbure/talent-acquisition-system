/* ============================================================================
   TAMS - 12_Tests / 04_Query_Scope_Tests.sql        (Phase 4 read side)
   Proves that every list/detail/dashboard procedure applies the caller's scope:
   own customer / own contractor / own candidate / role, and that RATES are visible only to the right role.
   Runs inside a transaction that is rolled back.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;
DECLARE @r TABLE (Id INT IDENTITY(1,1), Name NVARCHAR(220), Ok BIT, Detail NVARCHAR(300));
DECLARE @e INT, @n INT, @n2 INT;
DECLARE @admin INT  = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ADMIN@TAMS.LOCAL'),   @priya INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'PRIYA.MENON@TAMS.LOCAL'),
        @rahul INT  = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'RAHUL.DESAI@TAMS.LOCAL'), @anita INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ANITA.KAPOOR@TAMS.LOCAL'),
        @arjun INT  = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ARJUN.SHAH@APEXLOGISTICS.EXAMPLE'), @meera INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'MEERA.IYER@BRIGHTWAVE.EXAMPLE'),
        @ravi INT   = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'RAVI.KUMAR@CONTRACTOR.EXAMPLE'), @sneha INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'SNEHA.PILLAI@CONTRACTOR.EXAMPLE'),
        @ananya INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ANANYA.SHARMA@CANDIDATE.EXAMPLE'), @rohan INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ROHAN.GUPTA@CANDIDATE.EXAMPLE'),
        @divya INT  = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'DIVYA.REDDY@CANDIDATE.EXAMPLE');
DECLARE @apex INT = (SELECT CustomerId FROM org.Customers WHERE CustomerCode = N'APEX'), @bright INT = (SELECT CustomerId FROM org.Customers WHERE CustomerCode = N'BRIGHT');

BEGIN TRANSACTION;

-- ---------- identity ----------
CREATE TABLE #me (UserId INT, Email NVARCHAR(256), DisplayName NVARCHAR(150), LastLoginAt DATETIME2(0), Roles NVARCHAR(400), CustomerId INT, CustomerName NVARCHAR(200), CandidateId INT, ContractorId INT, UnreadNotifications INT);
INSERT #me EXEC sec.usp_GetMe @arjun;
INSERT @r VALUES (N'Q01 GetMe returns the caller''s roles and linked customer (and nothing else)', IIF(EXISTS (SELECT 1 FROM #me WHERE Roles = N'Customer' AND CustomerId = @apex AND CandidateId IS NULL AND ContractorId IS NULL), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC sec.usp_ListUsers @priya; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q02 user administration is Administrator-only (recruiter => 50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));
CREATE TABLE #u (UserId INT, Email NVARCHAR(256), DisplayName NVARCHAR(150), IsActive BIT, LastLoginAt DATETIME2(0), FailedLoginCount INT, LockoutUntil DATETIME2(0), CreatedAt DATETIME2(0), Roles NVARCHAR(400), CustomerName NVARCHAR(200), TotalCount INT);
INSERT #u EXEC sec.usp_ListUsers @admin;
INSERT @r VALUES (N'Q03 admin lists all 15 seeded users with their roles and a total count', IIF((SELECT MAX(TotalCount) FROM #u) = 15 AND EXISTS (SELECT 1 FROM #u WHERE Email = N'priya.menon@tams.local' AND Roles = N'Recruiter'), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC sec.usp_AssignRole @admin, @ananya, N'Customer', 1; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q04 Customer/Candidate/Contractor roles cannot be granted by hand (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));
EXEC sec.usp_AssignRole @admin, @sneha, N'HRManager', 1;      -- (any user other than the recruiters used below)
SET @e = 0; BEGIN TRY EXEC sec.usp_AssignRole @admin, @sneha, N'HRManager', 1; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q05 assigning a role works once; a duplicate is refused (50003)', IIF(@e = 50003 AND sec.fn_UserHasRole(@sneha, N'HRManager') = 1, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC sec.usp_AssignRole @admin, @admin, N'Administrator', 0; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q06 an administrator cannot remove their own Administrator role (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));

-- ---------- customers ----------
CREATE TABLE #cu (CustomerId INT, CustomerCode NVARCHAR(20), Name NVARCHAR(200), Industry NVARCHAR(100), Status VARCHAR(15), BillingEmail NVARCHAR(256), PaymentTermsDays INT, AccountManager NVARCHAR(150), OutstandingBalance DECIMAL(12,2));
INSERT #cu EXEC org.usp_ListCustomers @meera;
INSERT @r VALUES (N'Q07 ISOLATION: a customer''s customer list contains only itself', IIF((SELECT COUNT(*) FROM #cu) = 1 AND EXISTS (SELECT 1 FROM #cu WHERE CustomerId = @bright), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC org.usp_GetCustomer @meera, @apex; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q08 ISOLATION: reading another customer''s record by id => 50004', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
DELETE #cu; INSERT #cu EXEC org.usp_ListCustomers @priya;
INSERT @r VALUES (N'Q09 staff see all 3 customers with their outstanding balance', IIF((SELECT COUNT(*) FROM #cu) = 3 AND EXISTS (SELECT 1 FROM #cu WHERE CustomerId = @apex AND OutstandingBalance = bill.fn_CustomerOutstandingBalance(@apex)), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC org.usp_UpsertCustomer @priya, NULL, N'ZZ', N'ZZ Corp'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q10 creating customers is Administrator-only (50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC org.usp_UpsertCustomer @admin, NULL, N'apex', N'Another Name'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q11 a duplicate customer code is refused (50003)', IIF(@e = 50003, 1, 0), CONCAT(N'err=', @e));
EXEC org.usp_UpsertCustomer @admin, NULL, N'zzcorp', N'ZZ Corp', N'Testing';
INSERT @r VALUES (N'Q12 admin creates a customer (code upper-cased)', IIF(EXISTS (SELECT 1 FROM org.Customers WHERE CustomerCode = N'ZZCORP'), 1, 0), N'');

-- ---------- RATE VISIBILITY ----------
CREATE TABLE #ct (ContractId INT, ContractNo NVARCHAR(30), CustomerId INT, CustomerName NVARCHAR(200), ContractorId INT, ContractorNo NVARCHAR(20), ContractorName NVARCHAR(250), StartDate DATE, EndDate DATE, Status VARCHAR(12), DaysToExpiry INT, RowVer BINARY(8), PayRate DECIMAL(10,2), BillRate DECIMAL(10,2), Currency CHAR(3));
INSERT #ct EXEC staff.usp_ListContracts @ravi;
INSERT @r VALUES (N'Q13 RATES: a contractor sees only THEIR OWN contract and only the PAY rate (bill rate hidden)', IIF((SELECT COUNT(*) FROM #ct) = 1 AND EXISTS (SELECT 1 FROM #ct WHERE PayRate = 1250 AND BillRate IS NULL), 1, 0), N'');
DELETE #ct; INSERT #ct EXEC staff.usp_ListContracts @arjun;
INSERT @r VALUES (N'Q14 RATES: a customer sees only ITS contracts and only the BILL rate (pay rate hidden)', IIF((SELECT COUNT(*) FROM #ct) = 1 AND NOT EXISTS (SELECT 1 FROM #ct WHERE CustomerId <> @apex) AND EXISTS (SELECT 1 FROM #ct WHERE BillRate = 1700 AND PayRate IS NULL), 1, 0), N'');
DELETE #ct; INSERT #ct EXEC staff.usp_ListContracts @priya;
INSERT @r VALUES (N'Q15 RATES: staff see both rates on every contract', IIF((SELECT COUNT(*) FROM #ct) = 2 AND NOT EXISTS (SELECT 1 FROM #ct WHERE PayRate IS NULL OR BillRate IS NULL), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC staff.usp_ListContracts @meera, 'Active', @apex; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q16 ISOLATION: asking for another customer''s contracts by id => 50004', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
DECLARE @apexContract INT = (SELECT ContractId FROM staff.Contracts WHERE CustomerId = @apex), @brightContract INT = (SELECT ContractId FROM staff.Contracts WHERE CustomerId = @bright);
SET @e = 0; BEGIN TRY EXEC staff.usp_GetContract @meera, @apexContract; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q17 ISOLATION: a customer cannot open another customer''s contract (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC staff.usp_GetContract @sneha, @apexContract; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q18 ISOLATION: a contractor cannot open another contractor''s contract (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC staff.usp_GetContract @arjun, @apexContract; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q19 a customer CAN open its own contract', IIF(@e = 0, 1, 0), CONCAT(N'err=', @e));
CREATE TABLE #co (ContractorId INT, ContractorNo NVARCHAR(20), ContractorName NVARCHAR(250), Email NVARCHAR(256), Status VARCHAR(10), ActiveAssignments INT, CurrentCustomer NVARCHAR(200));
INSERT #co EXEC staff.usp_ListContractors @meera;
INSERT @r VALUES (N'Q20 ISOLATION: a customer sees only contractors placed with it, without their e-mail', IIF((SELECT COUNT(*) FROM #co) = 1 AND NOT EXISTS (SELECT 1 FROM #co WHERE Email IS NOT NULL OR CurrentCustomer <> N'Brightwave Telecom'), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC staff.usp_ListContractors @ravi; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q21 a contractor cannot list contractors (50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));

-- ---------- timesheets and invoices ----------
CREATE TABLE #ts (TimesheetId INT, AssignmentId INT, CustomerId INT, CustomerName NVARCHAR(200), ContractorId INT, ContractorNo NVARCHAR(20), ContractorName NVARCHAR(250), RoleTitle NVARCHAR(150), WeekStartDate DATE, Status VARCHAR(10), TotalHours DECIMAL(6,2), SubmittedAt DATETIME2(0), RowVer BINARY(8));
INSERT #ts EXEC [time].usp_ListTimesheets @ravi;
INSERT @r VALUES (N'Q22 ISOLATION: a contractor sees only their own 5 timesheets', IIF((SELECT COUNT(*) FROM #ts) = 5 AND NOT EXISTS (SELECT 1 FROM #ts WHERE ContractorNo <> N'CTR-0001'), 1, 0), N'');
DELETE #ts; INSERT #ts EXEC [time].usp_ListTimesheets @meera;
INSERT @r VALUES (N'Q23 ISOLATION: a customer sees only its own customer''s timesheets', IIF((SELECT COUNT(*) FROM #ts) = 5 AND NOT EXISTS (SELECT 1 FROM #ts WHERE CustomerId <> @bright), 1, 0), N'');
DECLARE @apexTs INT = (SELECT TOP 1 TimesheetId FROM [time].Timesheets WHERE CustomerId = @apex ORDER BY TimesheetId);
SET @e = 0; BEGIN TRY EXEC [time].usp_GetTimesheet @meera, @apexTs; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q24 ISOLATION: a customer cannot open another customer''s timesheet (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC [time].usp_GetTimesheet @sneha, @apexTs; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q25 ISOLATION: a contractor cannot open another contractor''s timesheet (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
DECLARE @apexInv INT = (SELECT TOP 1 InvoiceId FROM bill.Invoices WHERE CustomerId = @apex ORDER BY InvoiceId);
SET @e = 0; BEGIN TRY EXEC bill.usp_GetInvoice @meera, @apexInv; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q26 ISOLATION: a customer cannot open another customer''s invoice (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC bill.usp_GetInvoice @arjun, @apexInv; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q27 a customer CAN open its own invoice', IIF(@e = 0, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC bill.usp_GetInvoice @ravi, @apexInv; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q28 a contractor cannot read invoices at all (50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));

-- ---------- candidate side ----------
CREATE TABLE #ma (ApplicationId INT, JobPostingId INT, JobCode NVARCHAR(30), Title NVARCHAR(200), Department NVARCHAR(100), Status VARCHAR(12), AppliedAt DATETIME2(0), UpdatedAt DATETIME2(0), NextInterviewAt DATETIME2(0), OfferId INT, OfferStatus VARCHAR(16));
INSERT #ma EXEC cand.usp_ListMyApplications @rohan;
INSERT @r VALUES (N'Q29 ISOLATION: a candidate sees only their own 2 applications', IIF((SELECT COUNT(*) FROM #ma) = 2 AND EXISTS (SELECT 1 FROM #ma WHERE NextInterviewAt IS NOT NULL), 1, 0), N'');
DECLARE @ananyaApp INT = (SELECT a.ApplicationId FROM cand.JobApplications a WHERE a.CandidateId = cand.fn_CandidateIdForUser(@ananya));
SET @e = 0; BEGIN TRY EXEC cand.usp_GetApplication @rohan, @ananyaApp; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q30 ISOLATION: a candidate cannot open another candidate''s application (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
DECLARE @rohanInterview INT = (SELECT TOP 1 i.InterviewId FROM cand.Interviews i JOIN cand.JobApplications a ON a.ApplicationId = i.JobApplicationId WHERE a.CandidateId = cand.fn_CandidateIdForUser(@rohan) ORDER BY i.InterviewId);
INSERT @r VALUES (N'Q31 interview scope: the candidate, the HR manager and the owning recruiter can see it; another candidate and another customer cannot',
    IIF(cand.fn_CanSeeInterview(@rohan, @rohanInterview) = 1 AND cand.fn_CanSeeInterview(@anita, @rohanInterview) = 1 AND cand.fn_CanSeeInterview(@priya, @rohanInterview) = 1
        AND cand.fn_CanSeeInterview(@divya, @rohanInterview) = 0 AND cand.fn_CanSeeInterview(@meera, @rohanInterview) = 0 AND cand.fn_CanSeeInterview(@arjun, @rohanInterview) = 0, 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC cand.usp_GetInterview @divya, @rohanInterview; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q32 ISOLATION: another candidate cannot open the interview (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
CREATE TABLE #iv (InterviewId INT, StartsAt DATETIME2(0), EndsAt DATETIME2(0), RoundNo TINYINT, InterviewType VARCHAR(15), Mode VARCHAR(10), LocationOrLink NVARCHAR(300), Status VARCHAR(12), RowVer BINARY(8), Opportunity VARCHAR(8), JobApplicationId INT, SubmittedCandidateId INT, CustomerId INT, CandidateId INT, CandidateName NVARCHAR(250), RoleTitle NVARCHAR(200), CustomerName NVARCHAR(200), Panel NVARCHAR(MAX), FeedbackCount INT);
INSERT #iv EXEC cand.usp_ListInterviews @arjun;
INSERT @r VALUES (N'Q33 ISOLATION: a customer''s interview list contains only its own customer''s interviews', IIF((SELECT COUNT(*) FROM #iv) >= 1 AND NOT EXISTS (SELECT 1 FROM #iv WHERE CustomerId IS NULL OR CustomerId <> @apex), 1, 0), CONCAT(N'rows=', (SELECT COUNT(*) FROM #iv)));
DELETE #iv; INSERT #iv EXEC cand.usp_ListInterviews @divya;
INSERT @r VALUES (N'Q34 a candidate''s interview list contains only their own interviews', IIF((SELECT COUNT(*) FROM #iv) >= 1 AND NOT EXISTS (SELECT 1 FROM #iv WHERE CandidateId <> cand.fn_CandidateIdForUser(@divya)), 1, 0), N'');
CREATE TABLE #mo (OfferId INT, OfferNo NVARCHAR(30), Designation NVARCHAR(150), OfferedSalary DECIMAL(12,2), Currency CHAR(3), StartDate DATE, ExpiresAt DATETIME2(0), Status VARCHAR(16), SentAt DATETIME2(0), RespondedAt DATETIME2(0), JobTitle NVARCHAR(200), DaysToExpiry INT);
INSERT #mo EXEC cand.usp_ListMyOffers @divya;
INSERT @r VALUES (N'Q35 a candidate does not see offers that are still internal (pending approval)', IIF(NOT EXISTS (SELECT 1 FROM #mo WHERE Status IN ('Draft', 'PendingApproval', 'Approved', 'Rejected')), 1, 0), N'');
CREATE TABLE #pj (JobPostingId INT, JobCode NVARCHAR(30), Title NVARCHAR(200), Department NVARCHAR(100), Location NVARCHAR(100), EmploymentType VARCHAR(15), Openings INT, PostedAt DATETIME2(0), ClosesAt DATETIME2(0), Summary NVARCHAR(500), MinExperienceYears DECIMAL(4,1), SalaryMin DECIMAL(12,2), SalaryMax DECIMAL(12,2), AlreadyApplied INT, TotalCount INT);
INSERT #pj EXEC rec.usp_ListPublishedJobs @rohan;
INSERT @r VALUES (N'Q36 published jobs show the candidate''s own "already applied" state', IIF((SELECT COUNT(*) FROM #pj) = 2 AND NOT EXISTS (SELECT 1 FROM #pj WHERE AlreadyApplied = 0), 1, 0), CONCAT(N'rows=', (SELECT COUNT(*) FROM #pj)));
DELETE #pj; INSERT #pj EXEC rec.usp_ListPublishedJobs @divya;
INSERT @r VALUES (N'Q37 ...and a different candidate sees one job as applied, one not', IIF((SELECT COUNT(*) FROM #pj WHERE AlreadyApplied = 1) = 1 AND (SELECT COUNT(*) FROM #pj WHERE AlreadyApplied = 0) = 1, 1, 0), N'');

-- ---------- staff scoping ----------
CREATE TABLE #ap (ApplicationId INT, CandidateId INT, CandidateName NVARCHAR(250), Email NVARCHAR(256), TotalExperienceYears DECIMAL(4,1), JobRequisitionId INT, JobCode NVARCHAR(30), Title NVARCHAR(200), Status VARCHAR(12), AppliedAt DATETIME2(0), RowVer BINARY(8), AgeDays INT, TotalCount INT);
INSERT #ap EXEC cand.usp_ListApplications @priya;
SET @n = (SELECT COUNT(*) FROM #ap); DELETE #ap; INSERT #ap EXEC cand.usp_ListApplications @rahul; SET @n2 = (SELECT COUNT(*) FROM #ap);
DELETE #ap; INSERT #ap EXEC cand.usp_ListApplications @admin;
INSERT @r VALUES (N'Q38 a recruiter sees applicants of THEIR OWN jobs only (6 + 5 = the 11 an administrator sees)', IIF(@n = 6 AND @n2 = 5 AND (SELECT COUNT(*) FROM #ap) = 11, 1, 0), CONCAT(@n, N'/', @n2));
SET @e = 0; BEGIN TRY EXEC cand.usp_ListApplications @divya; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q39 a candidate cannot list other people''s applications (50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));
CREATE TABLE #er (EmployeeRequisitionId INT, RequisitionNo NVARCHAR(30), Title NVARCHAR(200), Department NVARCHAR(100), Location NVARCHAR(100), Headcount INT, EmploymentType VARCHAR(15), BudgetMax DECIMAL(12,2), RequiredByDate DATE, Status VARCHAR(12), RequestedBy NVARCHAR(150), RequestedByUserId INT, SubmittedAt DATETIME2(0), CreatedAt DATETIME2(0), RowVer BINARY(8), OpeningsPlanned INT, TotalCount INT);
INSERT #er EXEC hr.usp_ListEmployeeRequisitions @priya;
SET @n = (SELECT COUNT(*) FROM #er WHERE Status <> 'Approved'); DELETE #er; INSERT #er EXEC hr.usp_ListEmployeeRequisitions @anita;
INSERT @r VALUES (N'Q40 a recruiter sees only APPROVED hiring requests; HR sees all 6', IIF(@n = 0 AND (SELECT COUNT(*) FROM #er) = 6, 1, 0), CONCAT(@n, N'/', (SELECT COUNT(*) FROM #er)));
CREATE TABLE #em (EmployeeId INT, EmployeeNo NVARCHAR(20), EmployeeName NVARCHAR(250), Email NVARCHAR(256), Department NVARCHAR(100), JobTitle NVARCHAR(150), StartDate DATE, Status VARCHAR(12), Salary DECIMAL(12,2), Manager NVARCHAR(150), OnboardingDone INT, OnboardingTotal INT, TotalCount INT);
SET @e = 0; BEGIN TRY INSERT #em EXEC hr.usp_ListEmployees @priya; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q41 employee records (incl. salary) are HR/Admin-only (recruiter => 50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));
INSERT #em EXEC hr.usp_ListEmployees @anita;
INSERT @r VALUES (N'Q42 HR sees the employee with salary and onboarding progress', IIF(EXISTS (SELECT 1 FROM #em WHERE EmployeeNo = N'EMP-0001' AND Salary = 2600000 AND OnboardingTotal = 7 AND OnboardingDone = 2), 1, 0), N'');

-- ---------- notifications ----------
INSERT notify.NotificationQueue (TemplateCode, RecipientUserId, ToEmail, Subject, Body, DedupeKey) VALUES ('T', @divya, N'divya.reddy@candidate.example', N'for divya', N'b', N'zz-q-1'), ('T', @rohan, N'rohan.gupta@candidate.example', N'for rohan', N'b', N'zz-q-2');
CREATE TABLE #nt (NotificationId BIGINT, TemplateCode VARCHAR(40), Subject NVARCHAR(300), Body NVARCHAR(MAX), IsRead BIT, CreatedAt DATETIME2(0), RelatedEntityType VARCHAR(30), RelatedEntityId INT, EmailStatus VARCHAR(12), EmailedAt DATETIME2(0), UnreadCount INT);
INSERT #nt EXEC notify.usp_ListMyNotifications @divya;
INSERT @r VALUES (N'Q43 ISOLATION: a user sees only their own notifications', IIF(EXISTS (SELECT 1 FROM #nt WHERE Subject = N'for divya') AND NOT EXISTS (SELECT 1 FROM #nt WHERE Subject = N'for rohan'), 1, 0), N'');
EXEC notify.usp_MarkRead @divya;
INSERT @r VALUES (N'Q44 mark-read affects only the caller''s notifications', IIF(NOT EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE RecipientUserId = @divya AND IsRead = 0) AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE RecipientUserId = @rohan AND IsRead = 0), 1, 0), N'');

-- ---------- dashboards (computed, scoped) ----------
CREATE TABLE #d (MetricKey VARCHAR(40), Label NVARCHAR(100), Value DECIMAL(18,2), Unit VARCHAR(10));
DECLARE @vikram INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'VIKRAM.NAIR@TAMS.LOCAL');
SET @e = 0; BEGIN TRY EXEC report.usp_Dashboard @arjun, N'Administrator'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q45 a dashboard for a role the caller does not hold is refused (50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));
INSERT #d EXEC report.usp_Dashboard @arjun, N'Customer';
INSERT @r VALUES (N'Q46 customer dashboard is scoped: outstanding balance equals fn_CustomerOutstandingBalance(Apex), timesheets-to-approve equals its own count',
    IIF(EXISTS (SELECT 1 FROM #d WHERE MetricKey = 'outstanding' AND Value = bill.fn_CustomerOutstandingBalance(@apex)) AND EXISTS (SELECT 1 FROM #d WHERE MetricKey = 'timesheets' AND Value = (SELECT COUNT(*) FROM [time].Timesheets WHERE CustomerId = @apex AND Status = 'Submitted')), 1, 0), N'');
DELETE #d; INSERT #d EXEC report.usp_Dashboard @meera, N'Customer';
INSERT @r VALUES (N'Q47 ...and a different customer gets different numbers (Brightwave outstanding = 30,800)', IIF(EXISTS (SELECT 1 FROM #d WHERE MetricKey = 'outstanding' AND Value = 30800), 1, 0), N'');
DELETE #d; INSERT #d EXEC report.usp_Dashboard @ravi, N'Contractor';
INSERT @r VALUES (N'Q48 contractor dashboard: 1 assignment, 1 draft, 1 awaiting approval, hours this month computed', IIF(EXISTS (SELECT 1 FROM #d WHERE MetricKey = 'assignments' AND Value = 1) AND EXISTS (SELECT 1 FROM #d WHERE MetricKey = 'draft' AND Value = 1) AND EXISTS (SELECT 1 FROM #d WHERE MetricKey = 'awaiting' AND Value = 1) AND EXISTS (SELECT 1 FROM #d WHERE MetricKey = 'hoursMonth'), 1, 0), N'');
DELETE #d; INSERT #d EXEC report.usp_Dashboard @rohan, N'Candidate';
INSERT @r VALUES (N'Q49 candidate dashboard: 2 applications, 2 active, upcoming interviews counted (internal + external)', IIF(EXISTS (SELECT 1 FROM #d WHERE MetricKey = 'applications' AND Value = 2) AND EXISTS (SELECT 1 FROM #d WHERE MetricKey = 'interviews' AND Value = 2), 1, 0), N'');
DELETE #d; INSERT #d EXEC report.usp_Dashboard @priya, N'Recruiter';
INSERT @r VALUES (N'Q50 recruiter dashboard (Priya): 1 open job of hers, 4 active applicants on her jobs, 1 contract expiring within 30 days', IIF(EXISTS (SELECT 1 FROM #d WHERE MetricKey = 'openJobs' AND Value = 1) AND EXISTS (SELECT 1 FROM #d WHERE MetricKey = 'applicants' AND Value = 4) AND EXISTS (SELECT 1 FROM #d WHERE MetricKey = 'expiring' AND Value = 1), 1, 0), N'');
DELETE #d; INSERT #d EXEC report.usp_Dashboard @vikram, N'HRManager';
INSERT @r VALUES (N'Q51 HR dashboard (Vikram): 1 hiring request awaiting HIS approval (not his own), 1 employee, 1 onboarding', IIF(EXISTS (SELECT 1 FROM #d WHERE MetricKey = 'pendingRequests' AND Value = 1) AND EXISTS (SELECT 1 FROM #d WHERE MetricKey = 'employees' AND Value = 1) AND EXISTS (SELECT 1 FROM #d WHERE MetricKey = 'onboarding' AND Value = 1), 1, 0), N'');
DELETE #d; INSERT #d EXEC report.usp_Dashboard @admin, N'Administrator';
INSERT @r VALUES (N'Q52 admin dashboard: user and customer counts equal the real counts (4 customers = 3 seeded + 1 created in Q12)', IIF(EXISTS (SELECT 1 FROM #d WHERE MetricKey = 'users' AND Value = (SELECT COUNT(*) FROM sec.Users)) AND EXISTS (SELECT 1 FROM #d WHERE MetricKey = 'customers' AND Value = 4), 1, 0), N'');

-- ---------- draft invoices are internal ----------
DECLARE @dummyGen INT = (SELECT TOP (1) GeneratedByUserId FROM bill.Invoices);
INSERT bill.Invoices (InvoiceNo, CustomerId, PeriodStart, PeriodEnd, Currency, TaxRate, Status, GeneratedByUserId) VALUES (N'INV-ZZ-DRAFT', @apex, '20260101', '20260107', 'INR', 18, 'Draft', @dummyGen);
DECLARE @draftInv INT = SCOPE_IDENTITY();
CREATE TABLE #iv2 (InvoiceId INT, InvoiceNo NVARCHAR(30), CustomerId INT, CustomerName NVARCHAR(200), PeriodStart DATE, PeriodEnd DATE, IssueDate DATE, DueDate DATE, Status VARCHAR(15), Currency CHAR(3), Subtotal DECIMAL(12,2), TaxAmount DECIMAL(12,2), Total DECIMAL(12,2), AmountPaid DECIMAL(12,2), Balance DECIMAL(12,2), DaysOverdue INT);
INSERT #iv2 EXEC bill.usp_ListInvoices @arjun;
SET @e = 0; BEGIN TRY EXEC bill.usp_GetInvoice @arjun, @draftInv; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q55 a customer does not see its own DRAFT invoice in the list or by id (404) until it is issued', IIF(NOT EXISTS (SELECT 1 FROM #iv2 WHERE InvoiceId = @draftInv) AND EXISTS (SELECT 1 FROM #iv2) AND @e = 50004, 1, 0), CONCAT(N'err=', @e));
DELETE #iv2; INSERT #iv2 EXEC bill.usp_ListInvoices @priya, @apex;
INSERT @r VALUES (N'Q56 staff do see the draft', IIF(EXISTS (SELECT 1 FROM #iv2 WHERE InvoiceId = @draftInv), 1, 0), N'');

-- ---------- staff directory (interview panels) ----------
CREATE TABLE #sd (UserId INT, DisplayName NVARCHAR(150), Roles NVARCHAR(400));
INSERT #sd EXEC sec.usp_ListStaffDirectory @priya;
INSERT @r VALUES (N'Q53 staff directory lists exactly the active staff users, with staff roles only and no customer/candidate users',
    IIF((SELECT COUNT(*) FROM #sd) = (SELECT COUNT(DISTINCT ur.UserId) FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId JOIN sec.Users u ON u.UserId = ur.UserId WHERE u.IsActive = 1 AND r.RoleName IN (N'Recruiter', N'HRManager', N'Administrator'))
        AND NOT EXISTS (SELECT 1 FROM #sd WHERE UserId IN (@arjun, @rohan, @ravi)) AND NOT EXISTS (SELECT 1 FROM #sd WHERE Roles LIKE N'%Customer%' OR Roles LIKE N'%Candidate%'), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC sec.usp_ListStaffDirectory @arjun; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'Q54 customers cannot read the staff directory (50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));

IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT @r VALUES (N'Z01 the suite left no trace', IIF((SELECT COUNT(*) FROM org.Customers) = 3 AND NOT EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE DedupeKey LIKE N'zz-q-%') AND @@TRANCOUNT = 0, 1, 0), N'');

DECLARE @line NVARCHAR(500);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT CASE WHEN Ok = 1 THEN N'PASS  ' ELSE N'FAIL  ' END + Name + CASE WHEN Ok = 0 THEN N'  -> ' + Detail ELSE N'' END FROM @r ORDER BY Id;
OPEN c; FETCH NEXT FROM c INTO @line; WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c INTO @line; END CLOSE c; DEALLOCATE c;
DECLARE @total INT = (SELECT COUNT(*) FROM @r), @passed INT = (SELECT COUNT(*) FROM @r WHERE Ok = 1);
PRINT CONCAT(N'--- Query/scope tests: ', @passed, N' passed, ', @total - @passed, N' failed, ', @total, N' total ---');
IF @passed <> @total RAISERROR(N'Query/scope tests FAILED', 16, 1);
GO
