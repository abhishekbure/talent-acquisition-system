/* ============================================================================
   TAMS - 12_Tests / 02_Functions_Views_Triggers_Procedures_Tests.sql   (Phase 3)
   Exercises every function, view, trigger and stored procedure through REAL workflows.
   The whole suite runs inside ONE outer transaction that is ROLLED BACK at the end, so the
   seed data is left untouched (procedures use savepoints when a transaction is already open).
   Results are kept in a TABLE VARIABLE because temp tables would be rolled back as well.
   Prints PASS/FAIL per test and raises an error if any test fails.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;
SET XACT_ABORT OFF;

DECLARE @r TABLE (Id INT IDENTITY(1,1), Name NVARCHAR(220), Ok BIT, Detail NVARCHAR(500));
DECLARE @e INT, @m NVARCHAR(2000), @n INT, @n2 INT, @s NVARCHAR(300), @d DECIMAL(14,2);
DECLARE @start DATETIME2(0) = SYSUTCDATETIME();
DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
DECLARE @monday DATE = CAST(DATEADD(DAY, (DATEDIFF(DAY, '19000101', @today) / 7) * 7, '19000101') AS DATE);
DECLARE @h32 VARBINARY(64) = CAST(REPLICATE('A', 32) AS VARBINARY(64)), @s32 VARBINARY(32) = CAST(REPLICATE('B', 32) AS VARBINARY(32));

DECLARE @admin INT  = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ADMIN@TAMS.LOCAL');
DECLARE @priya INT  = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'PRIYA.MENON@TAMS.LOCAL');
DECLARE @rahul INT  = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'RAHUL.DESAI@TAMS.LOCAL');
DECLARE @anita INT  = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ANITA.KAPOOR@TAMS.LOCAL');
DECLARE @vikram INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'VIKRAM.NAIR@TAMS.LOCAL');
DECLARE @arjun INT  = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ARJUN.SHAH@APEXLOGISTICS.EXAMPLE');
DECLARE @neha INT   = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'NEHA.VERMA@APEXLOGISTICS.EXAMPLE');
DECLARE @meera INT  = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'MEERA.IYER@BRIGHTWAVE.EXAMPLE');
DECLARE @kabir INT  = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'KABIR.MALHOTRA@CRESTLINE.EXAMPLE');
DECLARE @ravi INT   = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'RAVI.KUMAR@CONTRACTOR.EXAMPLE');
DECLARE @sneha INT  = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'SNEHA.PILLAI@CONTRACTOR.EXAMPLE');
DECLARE @ananya INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ANANYA.SHARMA@CANDIDATE.EXAMPLE');
DECLARE @rohan INT  = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ROHAN.GUPTA@CANDIDATE.EXAMPLE');
DECLARE @divya INT  = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'DIVYA.REDDY@CANDIDATE.EXAMPLE');
DECLARE @karan INT  = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'KARAN.JOSHI@CANDIDATE.EXAMPLE');
DECLARE @apex INT = (SELECT CustomerId FROM org.Customers WHERE CustomerCode = N'APEX'), @bright INT = (SELECT CustomerId FROM org.Customers WHERE CustomerCode = N'BRIGHT'),
        @crest INT = (SELECT CustomerId FROM org.Customers WHERE CustomerCode = N'CREST');
DECLARE @engDept INT = (SELECT DepartmentId FROM org.Departments WHERE Name = N'Engineering');

BEGIN TRANSACTION;

/* ============================== F. FUNCTIONS ============================== */
INSERT @r VALUES (N'F01 fn_PadNumber pads and never truncates', IIF(dbo.fn_PadNumber(7, 4) = N'0007' AND dbo.fn_PadNumber(12345, 4) = N'12345', 1, 0), N'');
INSERT @r VALUES (N'F02 fn_SplitCsv trims, skips empties (recursive CTE)',
    IIF((SELECT COUNT(*) FROM dbo.fn_SplitCsv(N' C# , ,SQL Server,REST APIs,')) = 3
        AND EXISTS (SELECT 1 FROM dbo.fn_SplitCsv(N' C# , ,SQL Server') WHERE Item = N'C#'), 1, 0), N'');
INSERT @r VALUES (N'F03 fn_SearchCandidates requires ALL skills (C#+SQL Server, >=5y => 4 people)',
    IIF((SELECT COUNT(*) FROM cand.fn_SearchCandidates(NULL, N'C#,SQL Server', 5, NULL, 'Active')) = 4, 1, 0), N'');
INSERT @r VALUES (N'F04 fn_SearchCandidates free text + status filter',
    IIF((SELECT COUNT(*) FROM cand.fn_SearchCandidates(N'Pillai', NULL, NULL, NULL, 'Active')) = 1
        AND (SELECT COUNT(*) FROM cand.fn_SearchCandidates(NULL, NULL, NULL, NULL, 'Blacklisted')) = 0, 1, 0), N'');
SET @d = (SELECT cand.fn_ExperienceYears(CandidateId) FROM cand.Candidates WHERE EmailNormalized = N'RAVI.KUMAR@CONTRACTOR.EXAMPLE');
INSERT @r VALUES (N'F05 fn_ExperienceYears sums employment periods (~9.0)', IIF(@d BETWEEN 8.8 AND 9.2, 1, 0), CONCAT(N'value=', @d));
SET @n = (SELECT ContractId FROM staff.Contracts WHERE ContractNo LIKE N'CON-%-001');
INSERT @r VALUES (N'F06 fn_ContractDurationDays / fn_DaysToContractExpiry',
    IIF(staff.fn_ContractDurationDays(@n) = DATEDIFF(DAY, (SELECT StartDate FROM staff.Contracts WHERE ContractId = @n), (SELECT EndDate FROM staff.Contracts WHERE ContractId = @n)) + 1
        -- seeded 20 days ahead of the build day; compare with the calendar so the check does not fail on later days (KI-020)
        AND staff.fn_DaysToContractExpiry(@n) = DATEDIFF(DAY, CAST(SYSUTCDATETIME() AS DATE), (SELECT EndDate FROM staff.Contracts WHERE ContractId = @n))
        AND staff.fn_DaysToContractExpiry(@n) BETWEEN -400 AND 20, 1, 0), CONCAT(N'toExpiry=', staff.fn_DaysToContractExpiry(@n)));
SET @n = (SELECT a.ApplicationId FROM cand.JobApplications a JOIN cand.Candidates c ON c.CandidateId = a.CandidateId WHERE c.EmailNormalized = N'ANANYA.SHARMA@CANDIDATE.EXAMPLE');
INSERT @r VALUES (N'F07 fn_TimeToHireDays = 28 for the hired application, NULL otherwise',
    IIF(cand.fn_TimeToHireDays(@n) = 28 AND cand.fn_TimeToHireDays((SELECT MIN(ApplicationId) FROM cand.JobApplications WHERE Status = 'Interview')) IS NULL, 1, 0), CONCAT(N'tth=', cand.fn_TimeToHireDays(@n)));
INSERT @r VALUES (N'F08 fn_ApplicationAgeDays (finished app ages to last change)', IIF(cand.fn_ApplicationAgeDays(@n) = 28, 1, 0), CONCAT(N'age=', cand.fn_ApplicationAgeDays(@n)));
INSERT @r VALUES (N'F09 fn_CustomerOutstandingBalance per customer (Apex 80240, Brightwave 30800, Crestline 0)',
    IIF(bill.fn_CustomerOutstandingBalance(@apex) = 80240 AND bill.fn_CustomerOutstandingBalance(@bright) = 30800 AND bill.fn_CustomerOutstandingBalance(@crest) = 0, 1, 0),
    CONCAT(bill.fn_CustomerOutstandingBalance(@apex), N'/', bill.fn_CustomerOutstandingBalance(@bright), N'/', bill.fn_CustomerOutstandingBalance(@crest)));
INSERT @r VALUES (N'F10 fn_EffectiveRate keeps PAY and BILL separate',
    IIF(EXISTS (SELECT 1 FROM staff.fn_EffectiveRate((SELECT ContractId FROM staff.Contracts WHERE ContractNo LIKE N'CON-%-001'), @today) WHERE PayRate = 1250 AND BillRate = 1700), 1, 0), N'');
INSERT @r VALUES (N'F11 fn_UserHasRole / fn_UserCustomerId / fn_CandidateIdForUser / fn_ContractorIdForUser',
    IIF(sec.fn_UserHasRole(@anita, N'HRManager') = 1 AND sec.fn_UserHasRole(@anita, N'Recruiter') = 0 AND sec.fn_UserCustomerId(@arjun) = @apex
        AND cand.fn_CandidateIdForUser(@rohan) IS NOT NULL AND staff.fn_ContractorIdForUser(@ravi) IS NOT NULL AND staff.fn_ContractorIdForUser(@rohan) IS NULL, 1, 0), N'');

/* ============================== V. VIEWS ============================== */
INSERT @r VALUES (N'V01 vw_RecruitmentPipeline totals equal the real application counts',
    IIF(NOT EXISTS (SELECT 1 FROM report.vw_RecruitmentPipeline v
        WHERE v.Total <> (SELECT COUNT(*) FROM cand.JobApplications a JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId WHERE p.JobRequisitionId = v.JobRequisitionId)), 1, 0), N'');
INSERT @r VALUES (N'V02 customer-facing contractor view exposes NO pay rate',
    IIF(NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'report.vw_ActiveContractors') AND name LIKE N'%Pay%')
        AND NOT EXISTS (SELECT 1 FROM sys.columns c JOIN sys.views v ON v.object_id = c.object_id WHERE SCHEMA_NAME(v.schema_id) = N'report' AND c.name = N'PayRate'), 1, 0), N'');
INSERT @r VALUES (N'V03 vw_CustomerInvoices balance agrees with fn_InvoiceBalance',
    IIF(NOT EXISTS (SELECT 1 FROM report.vw_CustomerInvoices WHERE Status <> 'Void' AND Balance <> bill.fn_InvoiceBalance(InvoiceId)), 1, 0), N'');
INSERT @r VALUES (N'V04 all 11 required views return rows without error',
    IIF((SELECT COUNT(*) FROM report.vw_OpenRequisitions) > 0 AND (SELECT COUNT(*) FROM report.vw_RecruitmentPipeline) > 0
        AND (SELECT COUNT(*) FROM report.vw_CandidateApplicationStatus) > 0 AND (SELECT COUNT(*) FROM report.vw_UpcomingInterviews) > 0
        AND (SELECT COUNT(*) FROM report.vw_PendingOffers) > 0 AND (SELECT COUNT(*) FROM report.vw_ActiveEmployees) > 0
        AND (SELECT COUNT(*) FROM report.vw_ActiveContractors) > 0 AND (SELECT COUNT(*) FROM report.vw_ExpiringContracts) > 0
        AND (SELECT COUNT(*) FROM report.vw_PendingTimesheets) > 0 AND (SELECT COUNT(*) FROM report.vw_CustomerInvoices) > 0
        AND (SELECT COUNT(*) FROM report.vw_RecruitmentPerformance) > 0, 1, 0), N'');

/* ============================== S. SECURITY PROCEDURES ============================== */
SET @e = 0; BEGIN TRY EXEC hr.usp_CreateEmployeeRequisition @divya, @engDept, NULL, N'x'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'S01 a Candidate calling an HR procedure is forbidden (50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));

SET @e = 0; BEGIN TRY EXEC sec.usp_RegisterCandidate N'zz.new@candidate.example', N'Zed', N'Newman', NULL, @h32, @s32; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); SET @m = ERROR_MESSAGE(); END CATCH
INSERT @r VALUES (N'S02 candidate self-registration creates login + role + candidate master',
    IIF(@e = 0 AND EXISTS (SELECT 1 FROM cand.Candidates c JOIN sec.Users u ON u.UserId = c.UserId JOIN sec.UserRoles ur ON ur.UserId = u.UserId JOIN sec.Roles r ON r.RoleId = ur.RoleId
                           WHERE c.EmailNormalized = N'ZZ.NEW@CANDIDATE.EXAMPLE' AND r.RoleName = N'Candidate'), 1, 0), CONCAT(N'err=', @e, N' ', @m));
SET @e = 0; BEGIN TRY EXEC sec.usp_RegisterCandidate N'ZZ.NEW@candidate.example', N'Zed', N'Again', NULL, @h32, @s32; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'S03 duplicate registration rejected (50003)', IIF(@e = 50003, 1, 0), CONCAT(N'err=', @e));

EXEC cand.usp_CreateCandidate @priya, N'Linked', N'Person', N'zz.linked@candidate.example', NULL, N'Analyst';
SET @n = (SELECT CandidateId FROM cand.Candidates WHERE EmailNormalized = N'ZZ.LINKED@CANDIDATE.EXAMPLE');
DECLARE @vtok VARBINARY(32) = HASHBYTES('SHA2_256', N'S04-verify-' + CONVERT(NVARCHAR(36), NEWID()));
EXEC sec.usp_RegisterCandidate N'zz.linked@candidate.example', N'Linked', N'Person', NULL, @h32, @s32, 210000, @vtok, '2099-01-01';
-- Phase 9 (KI-014): the link waits until the e-mail address is proven
DECLARE @s04before INT = (SELECT UserId FROM cand.Candidates WHERE CandidateId = @n);
CREATE TABLE #s04 (UserId INT, Email NVARCHAR(256)); INSERT #s04 EXEC sec.usp_VerifyEmail @vtok;
INSERT @r VALUES (N'S04 registering with a recruiter-created e-mail links to the same candidate only after e-mail verification (no duplicate master row)',
    IIF((SELECT COUNT(*) FROM cand.Candidates WHERE EmailNormalized = N'ZZ.LINKED@CANDIDATE.EXAMPLE') = 1 AND @s04before IS NULL
        AND (SELECT UserId FROM cand.Candidates WHERE CandidateId = @n) = (SELECT UserId FROM #s04), 1, 0), CONCAT(N'before=', @s04before));

SET @n2 =(SELECT COUNT(*) FROM cand.Candidates WHERE EmailNormalized = N'ANANYA.SHARMA@CANDIDATE.EXAMPLE');
SET @e = 0; BEGIN TRY EXEC cand.usp_CreateCandidate @priya, N'Dup', N'Dup', N'ananya.sharma@candidate.example'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); SET @m = ERROR_MESSAGE(); END CATCH
INSERT @r VALUES (N'S05 duplicate candidate e-mail rejected with the existing id (50003)', IIF(@e = 50003 AND @m LIKE N'%CandidateId=%' AND @n2 = 1, 1, 0), LEFT(@m, 150));

-- lockout after 5 failed logins
SET @n = 0; WHILE @n < 5 BEGIN EXEC sec.usp_RecordLoginAttempt N'divya.reddy@candidate.example', 0, N'bad password', '10.0.0.9'; SET @n += 1; END
INSERT @r VALUES (N'S06 five failed logins lock the account for 15 minutes and are written to LoginHistory',
    IIF((SELECT LockoutUntil FROM sec.Users WHERE UserId = @divya) > SYSUTCDATETIME()
        AND (SELECT COUNT(*) FROM audit.LoginHistory WHERE UserId = @divya AND Success = 0 AND AttemptedAt >= @start) = 5, 1, 0), N'');
EXEC sec.usp_RecordLoginAttempt N'divya.reddy@candidate.example', 1;
INSERT @r VALUES (N'S07 a successful login clears the lockout', IIF((SELECT LockoutUntil FROM sec.Users WHERE UserId = @divya) IS NULL AND (SELECT FailedLoginCount FROM sec.Users WHERE UserId = @divya) = 0, 1, 0), N'');

DECLARE @jti UNIQUEIDENTIFIER = NEWID(), @cnt INT;
CREATE TABLE #v (UserId INT, Roles NVARCHAR(400));
EXEC sec.usp_IssueToken @karan, @jti, '2099-01-01';
UPDATE sec.AuthTokens SET IssuedAt = DATEADD(DAY, -2, SYSUTCDATETIME()), ExpiresAt = DATEADD(DAY, -1, SYSUTCDATETIME()) WHERE Jti = @jti;   -- test setup: make it expired
INSERT #v EXEC sec.usp_ValidateToken @jti; SET @n = (SELECT COUNT(*) FROM #v); DELETE #v;
INSERT @r VALUES (N'S08 an expired token is not valid', IIF(@n = 0, 1, 0), CONCAT(N'rows=', @n));
SET @jti = NEWID(); EXEC sec.usp_IssueToken @karan, @jti, '2099-01-01';
INSERT #v EXEC sec.usp_ValidateToken @jti; SET @cnt = (SELECT COUNT(*) FROM #v); DELETE #v;
EXEC sec.usp_RevokeToken @jti;
INSERT #v EXEC sec.usp_ValidateToken @jti; SET @n = (SELECT COUNT(*) FROM #v); DELETE #v;
INSERT @r VALUES (N'S09 token valid until revoked (logout)', IIF(@cnt = 1 AND @n = 0, 1, 0), CONCAT(@cnt, N'/', @n));
SET @jti = NEWID(); EXEC sec.usp_IssueToken @karan, @jti, '2099-01-01';
EXEC sec.usp_SetUserActive @admin, @karan, 0;
INSERT #v EXEC sec.usp_ValidateToken @jti; SET @n = (SELECT COUNT(*) FROM #v); DELETE #v;
INSERT @r VALUES (N'S10 deactivating a user revokes all of that user''s tokens', IIF(@n = 0 AND (SELECT IsActive FROM sec.Users WHERE UserId = @karan) = 0, 1, 0), N'');
EXEC sec.usp_SetUserActive @admin, @karan, 1;
SET @e = 0; BEGIN TRY EXEC sec.usp_SetUserActive @admin, @admin, 0; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'S11 an administrator cannot deactivate themselves (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));

DECLARE @tok VARBINARY(32) = CAST(REPLICATE('T', 32) AS VARBINARY(32));
EXEC sec.usp_CreatePasswordReset N'ravi.kumar@contractor.example', @tok, '2099-01-01';
EXEC sec.usp_ConsumePasswordReset @tok, @h32, @s32;
SET @e = 0; BEGIN TRY EXEC sec.usp_ConsumePasswordReset @tok, @h32, @s32; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'S12 password reset token is single-use (second use 50002) and unknown e-mails reveal nothing',
    IIF(@e = 50002 AND (SELECT COUNT(*) FROM sec.PasswordResetTokens WHERE UsedAt IS NOT NULL AND UserId = @ravi) >= 1, 1, 0), CONCAT(N'err=', @e));
EXEC sec.usp_CreatePasswordReset N'nobody@nowhere.example', @tok, '2099-01-01';
SET @tok = CAST(REPLICATE('E', 32) AS VARBINARY(32));
EXEC sec.usp_CreatePasswordReset N'ravi.kumar@contractor.example', @tok, @today;   -- already expired
SET @e = 0; BEGIN TRY EXEC sec.usp_ConsumePasswordReset @tok, @h32, @s32; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'S13 an expired reset token is rejected (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));

SET @e = 0; BEGIN TRY EXEC sec.usp_CreateUser @priya, N'x.y@z.example', N'Xy', @h32, @s32, 210000, N'Recruiter'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'S14 only an Administrator can create users (recruiter => 50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));
EXEC sec.usp_CreateUser @admin, N'zz.cust@apexlogistics.example', N'ZZ Cust', @h32, @s32, 210000, N'Customer', @apex;
INSERT @r VALUES (N'S15 admin creates a Customer login linked to its customer',
    IIF(EXISTS (SELECT 1 FROM org.CustomerUsers cu JOIN sec.Users u ON u.UserId = cu.UserId WHERE u.EmailNormalized = N'ZZ.CUST@APEXLOGISTICS.EXAMPLE' AND cu.CustomerId = @apex), 1, 0), N'');

/* ============================== I. INTERNAL RECRUITMENT (end to end) ============================== */
-- 1. hiring request
EXEC hr.usp_CreateEmployeeRequisition @vikram, @engDept, NULL, N'ZZ Test Platform Engineer', 1, 'FullTime', N'Test', 3000000, NULL, 1;
DECLARE @er INT = (SELECT EmployeeRequisitionId FROM hr.EmployeeRequisitions WHERE Title = N'ZZ Test Platform Engineer');
INSERT @r VALUES (N'I01 hiring request created and submitted, numbered ER-yyyy-nnn', IIF(@er IS NOT NULL AND (SELECT Status FROM hr.EmployeeRequisitions WHERE EmployeeRequisitionId = @er) = 'Submitted'
    AND (SELECT RequisitionNo FROM hr.EmployeeRequisitions WHERE EmployeeRequisitionId = @er) LIKE N'ER-____-%', 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC hr.usp_DecideEmployeeRequisition @vikram, @er, 'Approved'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I02 the requester cannot approve their own hiring request (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
DECLARE @sk rec.JobSkillList; INSERT @sk (SkillName, IsRequired, MinYears) VALUES (N'C#', 1, 5), (N'SQL Server', 1, 4), (N'Angular', 0, 2);
SET @e = 0; BEGIN TRY EXEC rec.usp_CreateJob @priya, @er, NULL, NULL, N's', NULL, NULL, 0, NULL, NULL, NULL, @sk; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I03 a job cannot be created before the request is approved (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC hr.usp_DecideEmployeeRequisition @anita, @er, 'Rejected', NULL; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I04 rejecting without a reason is refused (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));
EXEC hr.usp_DecideEmployeeRequisition @anita, @er, 'Approved', N'ok';
INSERT @r VALUES (N'I05 HR approves; approval row written', IIF((SELECT Status FROM hr.EmployeeRequisitions WHERE EmployeeRequisitionId = @er) = 'Approved'
    AND EXISTS (SELECT 1 FROM hr.HiringApprovals WHERE EmployeeRequisitionId = @er AND ApproverUserId = @anita AND Decision = 'Approved'), 1, 0), N'');

-- 2. job
EXEC rec.usp_CreateJob @priya, @er, NULL, NULL, N'Platform work', N'Build', N'B.E.', 5, 2500000, 3000000, NULL, @sk;
DECLARE @job INT = (SELECT JobRequisitionId FROM rec.JobRequisitions WHERE EmployeeRequisitionId = @er);
INSERT @r VALUES (N'I06 recruiter creates the job (PendingApproval) with description + 3 skills in one go',
    IIF(@job IS NOT NULL AND (SELECT Status FROM rec.JobRequisitions WHERE JobRequisitionId = @job) = 'PendingApproval'
        AND (SELECT COUNT(*) FROM rec.JobSkills WHERE JobRequisitionId = @job) = 3 AND (SELECT COUNT(*) FROM rec.JobDescriptions WHERE JobRequisitionId = @job) = 1, 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC rec.usp_CreateJob @priya, @er, NULL, 1, N's', NULL, NULL, 0, NULL, NULL, NULL, @sk; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I07 openings beyond the approved headcount are refused (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC rec.usp_PublishJob @priya, @job; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I08 an unapproved job cannot be published (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC rec.usp_DecideJob @priya, @job, 'Approved'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I09 a recruiter cannot sign off job content (50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));
EXEC rec.usp_DecideJob @anita, @job, 'Approved', N'Looks good';
SET @e = 0; BEGIN TRY EXEC rec.usp_PublishJob @rahul, @job; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I10 a recruiter cannot publish another recruiter''s job (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
EXEC rec.usp_PublishJob @priya, @job;
DECLARE @post INT = (SELECT JobPostingId FROM rec.JobPostings WHERE JobRequisitionId = @job AND Status = 'Published');
INSERT @r VALUES (N'I11 publish creates the posting and opens the job', IIF(@post IS NOT NULL AND (SELECT Status FROM rec.JobRequisitions WHERE JobRequisitionId = @job) = 'Open', 1, 0), N'');

-- 3. application
DECLARE @cAnanya INT = cand.fn_CandidateIdForUser(@ananya), @cDivya INT = cand.fn_CandidateIdForUser(@divya);
SET @e = 0; BEGIN TRY EXEC cand.usp_CreateApplication @priya, @post; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I12 only a Candidate can apply (recruiter => 50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));
EXEC cand.usp_CreateApplication @divya, @post, N'Hello';
DECLARE @app INT = (SELECT ApplicationId FROM cand.JobApplications WHERE CandidateId = @cDivya AND JobPostingId = @post);
INSERT @r VALUES (N'I13 candidate applies; trigger writes the first status-history row (with reason)',
    IIF(@app IS NOT NULL AND (SELECT COUNT(*) FROM cand.ApplicationStatusHistory WHERE ApplicationId = @app AND OldStatus IS NULL AND NewStatus = 'Applied' AND Reason IS NOT NULL) = 1, 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC cand.usp_CreateApplication @divya, @post; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I14 duplicate application prevented (50003)', IIF(@e = 50003 AND (SELECT COUNT(*) FROM cand.JobApplications WHERE CandidateId = @cDivya AND JobPostingId = @post) = 1, 1, 0), CONCAT(N'err=', @e));
INSERT @r VALUES (N'I15 recruiter is notified of the new application',
    IIF(EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE RecipientUserId = @priya AND TemplateCode = 'APPLICATION_RECEIVED' AND RelatedEntityId = @app), 1, 0), N'');
EXEC cand.usp_WithdrawApplication @divya, @app, N'changed my mind';
EXEC cand.usp_CreateApplication @divya, @post;
SET @n = (SELECT COUNT(*) FROM cand.JobApplications WHERE CandidateId = @cDivya AND JobPostingId = @post);
INSERT @r VALUES (N'I16 withdraw, then re-apply is allowed (history keeps both)', IIF(@n = 2 AND EXISTS (SELECT 1 FROM cand.ApplicationStatusHistory h JOIN cand.JobApplications a ON a.ApplicationId = h.ApplicationId
    WHERE a.CandidateId = @cDivya AND a.JobPostingId = @post AND h.NewStatus = 'Withdrawn'), 1, 0), CONCAT(N'rows=', @n));
SET @app = (SELECT ApplicationId FROM cand.JobApplications WHERE CandidateId = @cDivya AND JobPostingId = @post AND Status = 'Applied');
SET @e = 0; BEGIN TRY EXEC cand.usp_WithdrawApplication @rohan, @app; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I17 a candidate cannot touch another candidate''s application (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));

-- 4. screening / shortlisting
SET @e = 0; BEGIN TRY EXEC cand.usp_ChangeApplicationStatus @priya, @app, 'Interview'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I18 an illegal status jump (Applied -> Interview) is refused (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC cand.usp_ChangeApplicationStatus @rahul, @app, 'Screening'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I19 a recruiter cannot move another recruiter''s applicants (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC cand.usp_ChangeApplicationStatus @priya, @app, 'Rejected', NULL; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I20 rejecting needs a reason (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));
EXEC cand.usp_ShortlistApplication @priya, @app, N'strong profile';
INSERT @r VALUES (N'I21 shortlist walks Applied -> Screening -> Shortlisted with full history and candidate notifications',
    IIF((SELECT Status FROM cand.JobApplications WHERE ApplicationId = @app) = 'Shortlisted'
        AND (SELECT COUNT(*) FROM cand.ApplicationStatusHistory WHERE ApplicationId = @app) = 3
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE RecipientUserId = @divya AND TemplateCode = 'APPLICATION_STATUS' AND RelatedEntityId = @app), 1, 0), N'');
DECLARE @rv BINARY(8) = (SELECT RowVer FROM cand.JobApplications WHERE ApplicationId = @app);
SET @e = 0; BEGIN TRY EXEC cand.usp_ChangeApplicationStatus @priya, @app, 'Rejected', N'x', 0x0000000000000001; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I22 stale row version is refused (optimistic concurrency, 50006)', IIF(@e = 50006, 1, 0), CONCAT(N'err=', @e));

-- 5. interviews
DECLARE @panel dbo.IdList; INSERT @panel (Id) VALUES (@vikram), (@priya);
DECLARE @t1 DATETIME2(0) = DATEADD(DAY, 3, DATEADD(HOUR, 10, CAST(@today AS DATETIME2(0))));
DECLARE @emptyPanel dbo.IdList; DECLARE @t1end DATETIME2(0) = DATEADD(HOUR, 1, @t1);
SET @e = 0; BEGIN TRY EXEC cand.usp_ScheduleInterview @priya, @app, NULL, 1, 'Technical', @t1, @t1end, 'Video', NULL, NULL, @emptyPanel; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I23 an interview without any interviewer is refused (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));
-- NB: a clearly-past time (not @start: DATETIME2(0) rounds UP, so @start can be up to 0.5 s in the FUTURE and the call would succeed)
DECLARE @pastStart DATETIME2(0) = DATEADD(HOUR, -2, SYSUTCDATETIME()), @pastEnd DATETIME2(0) = DATEADD(HOUR, -1, SYSUTCDATETIME());
SET @e = 0; BEGIN TRY EXEC cand.usp_ScheduleInterview @priya, @app, NULL, 1, 'Technical', @pastStart, @pastEnd, 'Video', NULL, NULL, @panel; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I23b an interview in the past is refused (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));
DECLARE @badPanel dbo.IdList; INSERT @badPanel (Id) VALUES (@arjun);
SET @e = 0; BEGIN TRY EXEC cand.usp_ScheduleInterview @priya, @app, NULL, 1, 'Technical', @t1, @t1, 'Video', NULL, NULL, @badPanel; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I24 end before start refused (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC cand.usp_ScheduleInterview @priya, @app, NULL, 1, 'Technical', @t1, @t1end, 'Video', NULL, NULL, @badPanel; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I25 a customer user cannot sit on an INTERNAL interview panel (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));
EXEC cand.usp_ScheduleInterview @priya, @app, NULL, 1, 'Technical', @t1, @t1end, 'Video', N'https://meet.example/x', NULL, @panel;
DECLARE @iv INT = (SELECT InterviewId FROM cand.Interviews WHERE JobApplicationId = @app AND RoundNo = 1);
INSERT @r VALUES (N'I26 interview scheduled: panel stored, application moves to Interview, invitation queued',
    IIF(@iv IS NOT NULL AND (SELECT COUNT(*) FROM cand.InterviewPanels WHERE InterviewId = @iv) = 2 AND (SELECT Status FROM cand.JobApplications WHERE ApplicationId = @app) = 'Interview'
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE RecipientUserId = @divya AND TemplateCode = 'INTERVIEW_INVITE' AND RelatedEntityId = @iv), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC cand.usp_ScheduleInterview @priya, @app, NULL, 1, 'Technical', @t1, @t1end, 'Video', NULL, NULL, @panel; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I27 the same round cannot be scheduled twice (50003)', IIF(@e = 50003, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC cand.usp_SubmitInterviewFeedback @vikram, @iv, 4, 'Yes'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I28 feedback before the interview has started is refused (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
DECLARE @t2 DATETIME2(0) = DATEADD(DAY, 4, @t1);
SET @e = 0; BEGIN TRY EXEC cand.usp_RescheduleInterview @priya, @iv, @t2, @t2; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I28b rescheduling with end = start is refused (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));
DECLARE @t2end DATETIME2(0) = DATEADD(HOUR, 1, @t2);
SET @e = 0; BEGIN TRY EXEC cand.usp_RescheduleInterview @priya, @iv, @t2, @t2end; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I29 interview rescheduled: status Rescheduled and a new invitation queued',
    IIF((SELECT Status FROM cand.Interviews WHERE InterviewId = @iv) = 'Rescheduled' AND (SELECT StartsAt FROM cand.Interviews WHERE InterviewId = @iv) = @t2
        AND (SELECT COUNT(*) FROM notify.NotificationQueue WHERE RecipientUserId = @divya AND TemplateCode = 'INTERVIEW_INVITE' AND RelatedEntityId = @iv) >= 2, 1, 0), CONCAT(N'err=', @e));
UPDATE cand.Interviews SET StartsAt = DATEADD(HOUR, -3, SYSUTCDATETIME()), EndsAt = DATEADD(HOUR, -2, SYSUTCDATETIME()) WHERE InterviewId = @iv;   -- test setup: interview is now in the past
SET @e = 0; BEGIN TRY EXEC cand.usp_SubmitInterviewFeedback @anita, @iv, 4, 'Yes'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I30 only panel members can submit feedback (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
EXEC cand.usp_SubmitInterviewFeedback @vikram, @iv, 5, 'StrongYes', N'Excellent', NULL;
INSERT @r VALUES (N'I31 first panelist feedback keeps the interview open', IIF((SELECT Status FROM cand.Interviews WHERE InterviewId = @iv) = 'Rescheduled', 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC cand.usp_SubmitInterviewFeedback @vikram, @iv, 3, 'Yes'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I32 feedback can be submitted only once per interviewer (50003)', IIF(@e = 50003, 1, 0), CONCAT(N'err=', @e));
EXEC cand.usp_SubmitInterviewFeedback @priya, @iv, 4, 'Yes';
INSERT @r VALUES (N'I33 when every panelist has submitted, the interview becomes Completed', IIF((SELECT Status FROM cand.Interviews WHERE InterviewId = @iv) = 'Completed', 1, 0), N'');

-- 6. selection -> offer -> acceptance -> employee
EXEC cand.usp_ChangeApplicationStatus @priya, @app, 'Selected', N'Panel recommends hire';
DECLARE @appNotSelected INT = (SELECT MIN(ApplicationId) FROM cand.JobApplications WHERE Status = 'Applied'), @farFuture DATETIME2(0) = '2099-01-01';
SET @e = 0; BEGIN TRY EXEC cand.usp_CreateOffer @priya, @appNotSelected, N'x', 100, 'INR', @today, @farFuture; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I34 an offer needs a Selected application (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
DECLARE @exp DATETIME2(0) = DATEADD(DAY, 10, SYSUTCDATETIME()), @startD DATE = DATEADD(DAY, 30, @today);
EXEC cand.usp_CreateOffer @priya, @app, N'Platform Engineer', 2800000, 'INR', @startD, @exp;
DECLARE @off INT = (SELECT OfferId FROM cand.JobOffers WHERE ApplicationId = @app);
INSERT @r VALUES (N'I35 offer created PendingApproval with a generated OFR number', IIF(@off IS NOT NULL AND (SELECT Status FROM cand.JobOffers WHERE OfferId = @off) = 'PendingApproval' AND (SELECT OfferNo FROM cand.JobOffers WHERE OfferId = @off) LIKE N'OFR-____-%', 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC cand.usp_CreateOffer @priya, @app, N'Platform Engineer', 2800000, 'INR', @startD, @exp; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I36 only one live offer per application (50003)', IIF(@e = 50003, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC cand.usp_DecideOffer @priya, @off, 'Approved'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I37 a recruiter cannot approve offers (50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC cand.usp_SendOffer @priya, @off; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I38 an unapproved offer cannot be sent (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
EXEC cand.usp_DecideOffer @vikram, @off, 'Approved', N'ok';
EXEC cand.usp_SendOffer @priya, @off;
INSERT @r VALUES (N'I39 offer approved and sent: application moves to OfferStage, candidate notified',
    IIF((SELECT Status FROM cand.JobOffers WHERE OfferId = @off) = 'Sent' AND (SELECT Status FROM cand.JobApplications WHERE ApplicationId = @app) = 'OfferStage'
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE RecipientUserId = @divya AND TemplateCode = 'OFFER_SENT' AND RelatedEntityId = @off), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC cand.usp_RespondToOffer @rohan, @off, 1; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I40 another candidate cannot answer my offer (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
SET @n = (SELECT COUNT(*) FROM hr.Employees);
EXEC cand.usp_RespondToOffer @divya, @off, 1, N'Accepted!';
DECLARE @emp INT = (SELECT EmployeeId FROM hr.Employees WHERE JobOfferId = @off);
INSERT @r VALUES (N'I41 ACCEPT is one transaction: offer Accepted + employee + 7 onboarding tasks + history + application Hired',
    IIF((SELECT COUNT(*) FROM hr.Employees) = @n + 1 AND @emp IS NOT NULL AND (SELECT Status FROM cand.JobOffers WHERE OfferId = @off) = 'Accepted'
        AND (SELECT COUNT(*) FROM hr.EmployeeOnboarding WHERE EmployeeId = @emp) = 7 AND EXISTS (SELECT 1 FROM hr.EmploymentHistory WHERE EmployeeId = @emp AND EventType = 'Hired')
        AND (SELECT Status FROM cand.JobApplications WHERE ApplicationId = @app) = 'Hired' AND (SELECT Status FROM hr.Employees WHERE EmployeeId = @emp) = 'Onboarding', 1, 0), N'');
INSERT @r VALUES (N'I42 employee is a separate entity from contractors but shares the candidate master row',
    IIF((SELECT CandidateId FROM hr.Employees WHERE EmployeeId = @emp) = @cDivya AND NOT EXISTS (SELECT 1 FROM staff.Contractors WHERE CandidateId = @cDivya), 1, 0), N'');
INSERT @r VALUES (N'I43 filling the only opening closes the job and its posting',
    IIF((SELECT Status FROM rec.JobRequisitions WHERE JobRequisitionId = @job) = 'Filled' AND (SELECT Status FROM rec.JobPostings WHERE JobPostingId = @post) = 'Closed', 1, 0), N'');
INSERT @r VALUES (N'I44 time-to-hire function works on the new hire and HR is notified',
    IIF(cand.fn_TimeToHireDays(@app) IS NOT NULL AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE RecipientUserId = @anita AND TemplateCode = 'ONBOARDING_STARTED' AND RelatedEntityId = @emp), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC cand.usp_RespondToOffer @divya, @off, 1; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I45 an offer cannot be answered twice (50002) and no second employee appears', IIF(@e = 50002 AND (SELECT COUNT(*) FROM hr.Employees WHERE JobOfferId = @off) = 1, 1, 0), CONCAT(N'err=', @e));

-- 7. onboarding
DECLARE @ob INT = (SELECT MIN(OnboardingId) FROM hr.EmployeeOnboarding WHERE EmployeeId = @emp);
SET @e = 0; BEGIN TRY EXEC hr.usp_CompleteOnboardingTask @divya, @ob; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I46 only HR/Admin can complete onboarding tasks (50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));
DECLARE @oi INT; DECLARE oc CURSOR LOCAL FAST_FORWARD FOR SELECT OnboardingId FROM hr.EmployeeOnboarding WHERE EmployeeId = @emp ORDER BY OnboardingId;
OPEN oc; FETCH NEXT FROM oc INTO @oi; WHILE @@FETCH_STATUS = 0 BEGIN EXEC hr.usp_CompleteOnboardingTask @anita, @oi; FETCH NEXT FROM oc INTO @oi; END CLOSE oc; DEALLOCATE oc;
INSERT @r VALUES (N'I47 completing every task activates the employee', IIF((SELECT Status FROM hr.Employees WHERE EmployeeId = @emp) = 'Active', 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC hr.usp_CompleteOnboardingTask @anita, @ob; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I48 a finished task cannot be completed again (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));

-- 8. decline path + four-eyes on seeded offer 003 (Divya's seeded application is on the QA job; her seeded offer is PendingApproval)
DECLARE @off3 INT = (SELECT OfferId FROM cand.JobOffers WHERE OfferNo LIKE N'OFR-%-003');
DECLARE @app3 INT = (SELECT ApplicationId FROM cand.JobOffers WHERE OfferId = @off3);
EXEC cand.usp_DecideOffer @anita, @off3, 'Rejected', N'Salary too high';
EXEC cand.usp_CreateOffer @anita, @app3, N'QA Automation Engineer', 1600000, 'INR', @startD, @exp;
DECLARE @off3b INT = (SELECT OfferId FROM cand.JobOffers WHERE ApplicationId = @app3 AND Status = 'PendingApproval');
SET @e = 0; BEGIN TRY EXEC cand.usp_DecideOffer @anita, @off3b, 'Approved'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'I49 FOUR-EYES: the person who created an offer cannot approve it (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
EXEC cand.usp_DecideOffer @vikram, @off3b, 'Approved';
EXEC cand.usp_SendOffer @anita, @off3b;
EXEC cand.usp_RespondToOffer @divya, @off3b, 0, N'Found another job';
INSERT @r VALUES (N'I50 declining: offer Declined, application Rejected with reason, no employee created',
    IIF((SELECT Status FROM cand.JobOffers WHERE OfferId = @off3b) = 'Declined' AND (SELECT Status FROM cand.JobApplications WHERE ApplicationId = @app3) = 'Rejected'
        AND EXISTS (SELECT 1 FROM cand.ApplicationStatusHistory WHERE ApplicationId = @app3 AND NewStatus = 'Rejected' AND Reason = N'Offer declined by candidate')
        AND NOT EXISTS (SELECT 1 FROM hr.Employees WHERE JobOfferId = @off3b), 1, 0), N'');

-- 9. rollback of a multi-step operation: accepting fails in the LAST step (employee already exists for the candidate)
DECLARE @off2 INT = (SELECT OfferId FROM cand.JobOffers WHERE OfferNo LIKE N'OFR-%-002');   -- Karan's seeded Sent offer
DECLARE @app2 INT = (SELECT ApplicationId FROM cand.JobOffers WHERE OfferId = @off2);
DECLARE @cKaran INT = cand.fn_CandidateIdForUser(@karan);
INSERT hr.Employees (EmployeeNo, CandidateId, JobOfferId, DepartmentId, JobTitle, StartDate, Salary)
VALUES (N'EMP-ZZ', @cKaran, @off3, @engDept, N'conflict', @today, 1);          -- test setup: makes hr.usp_CreateEmployeeFromOffer fail
DECLARE @obBefore INT = (SELECT COUNT(*) FROM hr.EmployeeOnboarding);
SET @e = 0; BEGIN TRY EXEC cand.usp_RespondToOffer @karan, @off2, 1; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); SET @m = ERROR_MESSAGE(); END CATCH
INSERT @r VALUES (N'I51 ROLLBACK: a failure in the last step undoes the earlier steps (offer still Sent, application still OfferStage, no tasks added)',
    IIF(@e = 50003 AND (SELECT Status FROM cand.JobOffers WHERE OfferId = @off2) = 'Sent' AND (SELECT Status FROM cand.JobApplications WHERE ApplicationId = @app2) = 'OfferStage'
        AND (SELECT COUNT(*) FROM hr.EmployeeOnboarding) = @obBefore, 1, 0), CONCAT(N'err=', @e, N' ', LEFT(@m, 100)));
DELETE hr.Employees WHERE EmployeeNo = N'EMP-ZZ';

/* ============================== X. EXTERNAL STAFFING + CUSTOMER ISOLATION ============================== */
EXEC staff.usp_CreateCustomerRequisition @kabir, NULL, N'ZZ Test QA Contractor', N'Regression', 1, N'Selenium', NULL, 6, 1500, N'Mumbai';
DECLARE @cr INT = (SELECT CustomerRequisitionId FROM staff.CustomerRequisitions WHERE Title = N'ZZ Test QA Contractor');
INSERT @r VALUES (N'X01 customer creates a request; its customer is taken from the LOGIN (Crestline), numbered CR-yyyy-nnn',
    IIF(@cr IS NOT NULL AND (SELECT CustomerId FROM staff.CustomerRequisitions WHERE CustomerRequisitionId = @cr) = @crest AND (SELECT Status FROM staff.CustomerRequisitions WHERE CustomerRequisitionId = @cr) = 'Open', 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC staff.usp_CreateCustomerRequisition @kabir, @apex, N'ZZ Forged'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X02 ISOLATION: a customer forging another customer''s CustomerId is refused as "not found" (50004)', IIF(@e = 50004 AND NOT EXISTS (SELECT 1 FROM staff.CustomerRequisitions WHERE Title = N'ZZ Forged'), 1, 0), CONCAT(N'err=', @e));
CREATE TABLE #lr (CustomerRequisitionId INT, RequestNo NVARCHAR(30), CustomerId INT, CustomerName NVARCHAR(200), Title NVARCHAR(200), Positions INT, Status VARCHAR(12), StartDate DATE, MaxBillRate DECIMAL(10,2), AssignedRecruiterUserId INT, CreatedAt DATETIME2(0), Submissions INT);
INSERT #lr EXEC staff.usp_ListCustomerRequisitions @meera;
INSERT @r VALUES (N'X03 ISOLATION: Brightwave''s list contains only Brightwave requests', IIF((SELECT COUNT(*) FROM #lr) >= 1 AND NOT EXISTS (SELECT 1 FROM #lr WHERE CustomerId <> @bright), 1, 0), CONCAT(N'rows=', (SELECT COUNT(*) FROM #lr)));
DELETE #lr; INSERT #lr EXEC staff.usp_ListCustomerRequisitions @neha;
INSERT @r VALUES (N'X04 a second login of the SAME customer sees the same customer''s requests (Apex only)', IIF((SELECT COUNT(*) FROM #lr) >= 2 AND NOT EXISTS (SELECT 1 FROM #lr WHERE CustomerId <> @apex), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC staff.usp_ListCustomerRequisitions @meera, @apex; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X05 ISOLATION: asking for another customer''s list by id => 50004', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC staff.usp_GetSubmissionsForRequisition @meera, @cr; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X06 ISOLATION: reading another customer''s submissions => 50004', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC staff.usp_AcceptCustomerRequisition @kabir, @cr; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X07 a customer cannot act as recruiter (50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));
EXEC staff.usp_AcceptCustomerRequisition @rahul, @cr;
INSERT @r VALUES (N'X08 recruiter accepts: InReview and assigned', IIF((SELECT Status FROM staff.CustomerRequisitions WHERE CustomerRequisitionId = @cr) = 'InReview' AND (SELECT AssignedRecruiterUserId FROM staff.CustomerRequisitions WHERE CustomerRequisitionId = @cr) = @rahul, 1, 0), N'');
DECLARE @cGaurav INT = (SELECT CandidateId FROM cand.Candidates WHERE EmailNormalized = N'GAURAV.SINGH@CANDIDATE.EXAMPLE');
SET @e = 0; BEGIN TRY EXEC staff.usp_SubmitCandidateToCustomer @priya, @cr, @cGaurav, 1400; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X09 a recruiter not assigned to the request cannot submit to it (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC staff.usp_SubmitCandidateToCustomer @rahul, @cr, @cGaurav, 1600; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X10 a proposed bill rate above the customer maximum is refused (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
EXEC staff.usp_SubmitCandidateToCustomer @rahul, @cr, @cGaurav, 1450, N'Strong automation skills';
DECLARE @sub INT = (SELECT SubmissionId FROM staff.SubmittedCandidates WHERE CustomerRequisitionId = @cr AND CandidateId = @cGaurav);
INSERT @r VALUES (N'X11 shared candidate master: the SAME candidate (internal applicant) is submitted externally; request moves to Sourcing; customer notified',
    IIF(@sub IS NOT NULL AND (SELECT Status FROM staff.CustomerRequisitions WHERE CustomerRequisitionId = @cr) = 'Sourcing'
        AND EXISTS (SELECT 1 FROM cand.JobApplications WHERE CandidateId = @cGaurav) AND (SELECT COUNT(*) FROM cand.Candidates WHERE EmailNormalized = N'GAURAV.SINGH@CANDIDATE.EXAMPLE') = 1
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE RecipientUserId = @kabir AND TemplateCode = 'CANDIDATE_SUBMITTED' AND RelatedEntityId = @sub), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC staff.usp_SubmitCandidateToCustomer @rahul, @cr, @cGaurav, 1450; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X12 duplicate submission prevented (50003)', IIF(@e = 50003, 1, 0), CONCAT(N'err=', @e));
CREATE TABLE #sub (SubmissionId INT, CandidateId INT, FirstName NVARCHAR(100), LastName NVARCHAR(100), CurrentTitle NVARCHAR(150), TotalExperienceYears DECIMAL(4,1), ProposedBillRate DECIMAL(10,2), Status VARCHAR(12), SubmittedAt DATETIME2(0), Notes NVARCHAR(1000), Email NVARCHAR(256), Phone NVARCHAR(30), ContractNo NVARCHAR(30));
INSERT #sub EXEC staff.usp_GetSubmissionsForRequisition @kabir, @cr;
INSERT @r VALUES (N'X13 customer sees the submission but NOT the candidate''s contact details before shortlisting', IIF(EXISTS (SELECT 1 FROM #sub WHERE SubmissionId = @sub AND Email IS NULL AND Phone IS NULL), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC staff.usp_DecideSubmission @arjun, @sub, 'Shortlist'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X14 ISOLATION: another customer''s login cannot decide on this submission (50004)', IIF(@e = 50004 AND (SELECT Status FROM staff.SubmittedCandidates WHERE SubmissionId = @sub) = 'Submitted', 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC staff.usp_DecideSubmission @kabir, @sub, 'Select'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X15 cannot Select before Shortlist (50002); reject needs reason (50001)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC staff.usp_DecideSubmission @kabir, @sub, 'Reject', N''; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X16 rejecting without a reason is refused (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));
EXEC staff.usp_DecideSubmission @kabir, @sub, 'Shortlist', N'Looks good';
DELETE #sub; INSERT #sub EXEC staff.usp_GetSubmissionsForRequisition @kabir, @cr;
INSERT @r VALUES (N'X17 customer shortlists; contact details now visible; decision row stored',
    IIF(EXISTS (SELECT 1 FROM #sub WHERE SubmissionId = @sub AND Status = 'Shortlisted' AND Email IS NOT NULL) AND EXISTS (SELECT 1 FROM staff.CustomerCandidateDecisions WHERE SubmissionId = @sub AND Decision = 'Shortlist'), 1, 0), N'');

DECLARE @cpanel dbo.IdList; INSERT @cpanel (Id) VALUES (@kabir), (@rahul);
DECLARE @apanel dbo.IdList; INSERT @apanel (Id) VALUES (@arjun), (@rahul);
SET @e = 0; BEGIN TRY EXEC cand.usp_ScheduleInterview @arjun, NULL, @sub, 1, 'Customer', @t1, @t1end, 'Video', NULL, NULL, @apanel; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X18 ISOLATION: another customer cannot schedule interviews for this submission (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC cand.usp_ScheduleInterview @rahul, NULL, @sub, 1, 'Customer', @t1, @t1end, 'Video', NULL, NULL, @apanel; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X19 ISOLATION: another customer''s user on the panel is refused (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));
EXEC cand.usp_ScheduleInterview @kabir, NULL, @sub, 1, 'Customer', @t1, @t1end, 'Video', N'https://meet.example/c', NULL, @cpanel;
DECLARE @eiv INT = (SELECT InterviewId FROM cand.Interviews WHERE SubmittedCandidateId = @sub);
INSERT @r VALUES (N'X20 the customer schedules an external interview; it carries the customer id; submission -> Interview',
    IIF(@eiv IS NOT NULL AND (SELECT CustomerId FROM cand.Interviews WHERE InterviewId = @eiv) = @crest AND (SELECT Status FROM staff.SubmittedCandidates WHERE SubmissionId = @sub) = 'Interview', 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC cand.usp_RescheduleInterview @meera, @eiv, @t2, @t2; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X21 ISOLATION: another customer cannot reschedule it (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
UPDATE cand.Interviews SET StartsAt = DATEADD(HOUR, -3, SYSUTCDATETIME()), EndsAt = DATEADD(HOUR, -2, SYSUTCDATETIME()) WHERE InterviewId = @eiv;
EXEC cand.usp_SubmitInterviewFeedback @kabir, @eiv, 5, 'StrongYes', N'Great', NULL;
EXEC cand.usp_SubmitInterviewFeedback @rahul, @eiv, 4, 'Yes';
INSERT @r VALUES (N'X22 customer and recruiter both give feedback; interview Completed', IIF((SELECT Status FROM cand.Interviews WHERE InterviewId = @eiv) = 'Completed' AND (SELECT COUNT(*) FROM cand.InterviewFeedback WHERE InterviewId = @eiv) = 2, 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC staff.usp_CreateContract @rahul, @sub, @today, '2099-12-31', 1100, 1450, 1.5, 1.5, N'QA'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X23 no contract before the customer has SELECTED the candidate (50002)', IIF(@e = 50002 AND NOT EXISTS (SELECT 1 FROM staff.Placements WHERE SubmissionId = @sub), 1, 0), CONCAT(N'err=', @e));
EXEC staff.usp_DecideSubmission @kabir, @sub, 'Select', N'Selected';
SET @n = (SELECT COUNT(*) FROM staff.Contractors);
SET @e = 0; BEGIN TRY EXEC staff.usp_CreateContract @rahul, @sub, @today, '2099-12-31', 1600, 1450, 1.5, 1.5, N'QA'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X24 a bill rate below the pay rate is refused (50002) and nothing is created', IIF(@e = 50002 AND (SELECT COUNT(*) FROM staff.Contractors) = @n AND NOT EXISTS (SELECT 1 FROM staff.Placements WHERE SubmissionId = @sub), 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC staff.usp_CreateContract @rahul, @sub, @today, '2099-12-31', 1100, 1600, 1.5, 1.5, N'QA'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X25 a bill rate above the customer''s maximum is refused (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC staff.usp_CreateContract @priya, @sub, @today, '2099-12-31', 1100, 1450, 1.5, 1.5, N'QA'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X26 a recruiter who is not assigned to the request cannot contract it (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
EXEC staff.usp_CreateContract @rahul, @sub, @today, '2099-12-31', 1100, 1450, 1.5, 1.5, N'QA Automation Tester', N'Crestline, Mumbai', 40, N'Terms';
DECLARE @ctrNew INT = (SELECT ContractorId FROM staff.Contractors WHERE CandidateId = @cGaurav), @kid INT = (SELECT c.ContractId FROM staff.Contracts c JOIN staff.Placements p ON p.PlacementId = c.PlacementId WHERE p.SubmissionId = @sub);
INSERT @r VALUES (N'X27 CONTRACT = one transaction: contractor + placement + contract + rates + assignment, all for the customer',
    IIF(@ctrNew IS NOT NULL AND @kid IS NOT NULL AND EXISTS (SELECT 1 FROM staff.ContractRates WHERE ContractId = @kid AND PayRate = 1100 AND BillRate = 1450)
        AND EXISTS (SELECT 1 FROM staff.Assignments WHERE ContractId = @kid AND ContractorId = @ctrNew AND CustomerId = @crest) AND (SELECT CustomerId FROM staff.Contracts WHERE ContractId = @kid) = @crest, 1, 0), N'');
INSERT @r VALUES (N'X28 the contractor is a SEPARATE entity from employees yet shares the candidate master; the request is Filled',
    IIF((SELECT CandidateId FROM staff.Contractors WHERE ContractorId = @ctrNew) = @cGaurav AND NOT EXISTS (SELECT 1 FROM hr.Employees WHERE CandidateId = @cGaurav)
        AND (SELECT Status FROM staff.CustomerRequisitions WHERE CustomerRequisitionId = @cr) = 'Filled', 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC staff.usp_CreateContract @rahul, @sub, @today, '2099-12-31', 1100, 1450, 1.5, 1.5, N'QA'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X29 a second placement for the same submission is refused (50003)', IIF(@e = 50003, 1, 0), CONCAT(N'err=', @e));

/* ----- timesheets (contractor Ravi, customer Apex) ----- */
DECLARE @ravCtr INT = staff.fn_ContractorIdForUser(@ravi), @snehaCtr INT = staff.fn_ContractorIdForUser(@sneha);
DECLARE @raviAsg INT = (SELECT AssignmentId FROM staff.Assignments WHERE ContractorId = @ravCtr), @snehaAsg INT = (SELECT AssignmentId FROM staff.Assignments WHERE ContractorId = @snehaCtr);
DECLARE @w5 DATE = DATEADD(WEEK, -5, @monday), @w6 DATE = DATEADD(WEEK, -6, @monday);
DECLARE @ent [time].TimesheetEntryList;
INSERT @ent (WorkDate, Hours) VALUES (@w5, 8), (DATEADD(DAY,1,@w5), 8), (DATEADD(DAY,2,@w5), 8), (DATEADD(DAY,3,@w5), 8), (DATEADD(DAY,4,@w5), 8);
SET @e = 0; BEGIN TRY EXEC [time].usp_SaveTimesheet @ravi, @w5, @ent, @snehaAsg; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X30 ISOLATION: a contractor cannot save time against ANOTHER contractor''s assignment (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
DECLARE @tuesday DATE = DATEADD(DAY, 1, @w5), @farWeek DATE = DATEADD(WEEK, 2, @monday);
SET @e = 0; BEGIN TRY EXEC [time].usp_SaveTimesheet @ravi, @tuesday, @ent, @raviAsg; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X31 a week that does not start on Monday is refused (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC [time].usp_SaveTimesheet @ravi, @farWeek, @ent, @raviAsg; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X32 a future week is refused (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
DECLARE @bad [time].TimesheetEntryList; INSERT @bad (WorkDate, Hours) VALUES (@w5, 25);
SET @e = 0; BEGIN TRY EXEC [time].usp_SaveTimesheet @ravi, @w5, @bad, @raviAsg; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X33 more than 24 hours in an entry is refused (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));
DECLARE @bad2 [time].TimesheetEntryList; INSERT @bad2 (WorkDate, Hours) VALUES (DATEADD(DAY, 9, @w5), 8);
SET @e = 0; BEGIN TRY EXEC [time].usp_SaveTimesheet @ravi, @w5, @bad2, @raviAsg; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X34 an entry outside the selected week is refused (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));
EXEC [time].usp_SaveTimesheet @ravi, @w5, @ent, @raviAsg;
DECLARE @ts5 INT = (SELECT TimesheetId FROM [time].Timesheets WHERE AssignmentId = @raviAsg AND WeekStartDate = @w5);
INSERT @r VALUES (N'X35 timesheet saved as Draft with 40 hours and the right customer', IIF((SELECT TotalHours FROM [time].Timesheets WHERE TimesheetId = @ts5) = 40 AND (SELECT Status FROM [time].Timesheets WHERE TimesheetId = @ts5) = 'Draft' AND (SELECT CustomerId FROM [time].Timesheets WHERE TimesheetId = @ts5) = @apex, 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC [time].usp_SubmitTimesheet @sneha, @ts5; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X36 ISOLATION: another contractor cannot submit my timesheet (50004)', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
EXEC [time].usp_SubmitTimesheet @ravi, @ts5;
INSERT @r VALUES (N'X37 submit: status Submitted and the CUSTOMER is notified (all its users)', IIF((SELECT Status FROM [time].Timesheets WHERE TimesheetId = @ts5) = 'Submitted'
    AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE RecipientUserId = @arjun AND TemplateCode = 'TIMESHEET_SUBMITTED' AND RelatedEntityId = @ts5)
    AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE RecipientUserId = @neha AND TemplateCode = 'TIMESHEET_SUBMITTED' AND RelatedEntityId = @ts5)
    AND NOT EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE RecipientUserId = @meera AND TemplateCode = 'TIMESHEET_SUBMITTED' AND RelatedEntityId = @ts5), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC [time].usp_SaveTimesheet @ravi, @w5, @ent, @raviAsg; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X38 a Submitted timesheet cannot be edited (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC [time].usp_ApproveTimesheet @meera, @ts5; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X39 ISOLATION: another customer cannot approve it (50004)', IIF(@e = 50004 AND (SELECT Status FROM [time].Timesheets WHERE TimesheetId = @ts5) = 'Submitted', 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC [time].usp_ApproveTimesheet @ravi, @ts5; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X40 a contractor cannot approve their own timesheet (50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));
EXEC [time].usp_ApproveTimesheet @neha, @ts5, N'ok';
INSERT @r VALUES (N'X41 customer approves; approval row written; contractor notified', IIF((SELECT Status FROM [time].Timesheets WHERE TimesheetId = @ts5) = 'Approved'
    AND EXISTS (SELECT 1 FROM [time].TimesheetApprovals WHERE TimesheetId = @ts5 AND ApprovedByUserId = @neha) AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE RecipientUserId = @ravi AND TemplateCode = 'TIMESHEET_APPROVED' AND RelatedEntityId = @ts5), 1, 0), N'');

-- rejection and resubmission
DECLARE @ent6 [time].TimesheetEntryList; INSERT @ent6 (WorkDate, Hours) VALUES (@w6, 8), (DATEADD(DAY,1,@w6), 8);
EXEC [time].usp_SaveTimesheet @ravi, @w6, @ent6, @raviAsg;
DECLARE @ts6 INT = (SELECT TimesheetId FROM [time].Timesheets WHERE AssignmentId = @raviAsg AND WeekStartDate = @w6);
EXEC [time].usp_SubmitTimesheet @ravi, @ts6;
SET @e = 0; BEGIN TRY EXEC [time].usp_RejectTimesheet @arjun, @ts6, N'  '; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X42 rejecting a timesheet needs a reason (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));
EXEC [time].usp_RejectTimesheet @arjun, @ts6, N'Wednesday is missing';
INSERT @r VALUES (N'X43 rejection stored with its reason; status Rejected', IIF((SELECT Status FROM [time].Timesheets WHERE TimesheetId = @ts6) = 'Rejected' AND EXISTS (SELECT 1 FROM [time].TimesheetRejections WHERE TimesheetId = @ts6 AND Reason = N'Wednesday is missing'), 1, 0), N'');
INSERT @ent6 (WorkDate, Hours) VALUES (DATEADD(DAY,2,@w6), 8);
EXEC [time].usp_SaveTimesheet @ravi, @w6, @ent6, @raviAsg;
INSERT @r VALUES (N'X44 contractor corrects a Rejected timesheet: it returns to Draft with 24 hours', IIF((SELECT Status FROM [time].Timesheets WHERE TimesheetId = @ts6) = 'Draft' AND (SELECT TotalHours FROM [time].Timesheets WHERE TimesheetId = @ts6) = 24, 1, 0), N'');
EXEC [time].usp_SubmitTimesheet @ravi, @ts6;
INSERT @r VALUES (N'X45 resubmission works; rejection history is kept', IIF((SELECT Status FROM [time].Timesheets WHERE TimesheetId = @ts6) = 'Submitted' AND (SELECT COUNT(*) FROM [time].TimesheetRejections WHERE TimesheetId = @ts6) = 1, 1, 0), N'');
CREATE TABLE #pt (TimesheetId INT, CustomerId INT, CustomerName NVARCHAR(200), ContractorId INT, ContractorNo NVARCHAR(20), ContractorName NVARCHAR(250), RoleTitle NVARCHAR(150), WeekStartDate DATE, TotalHours DECIMAL(6,2), SubmittedAt DATETIME2(0), DaysWaiting INT);
INSERT #pt EXEC [time].usp_ListPendingTimesheets @meera;
INSERT @r VALUES (N'X46 ISOLATION: Brightwave''s pending list never contains Apex timesheets', IIF(NOT EXISTS (SELECT 1 FROM #pt WHERE CustomerId <> @bright) AND NOT EXISTS (SELECT 1 FROM #pt WHERE TimesheetId = @ts6), 1, 0), N'');

/* ----- invoicing ----- */
DECLARE @ravContract INT = (SELECT ContractId FROM staff.Assignments WHERE AssignmentId = @raviAsg);
DECLARE @pStart DATE = DATEADD(DAY, -60, @today), @invBefore INT = (SELECT COUNT(*) FROM bill.Invoices);
UPDATE staff.ContractRates SET EffectiveFrom = DATEADD(DAY, 10, @today) WHERE ContractId = @ravContract;   -- test setup: break the rate to force a failure
SET @e = 0; BEGIN TRY EXEC bill.usp_GenerateInvoice @priya, @apex, @pStart, @today; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); SET @m = ERROR_MESSAGE(); END CATCH
INSERT @r VALUES (N'X47 INVOICE FAILURE: no rate in force => refused (50002), no invoice and no lines left behind', IIF(@e = 50002 AND (SELECT COUNT(*) FROM bill.Invoices) = @invBefore AND @m LIKE N'No contract rate%', 1, 0), LEFT(CONCAT(N'err=', @e, N' ', @m), 200));
UPDATE staff.ContractRates SET EffectiveFrom = (SELECT StartDate FROM staff.Contracts WHERE ContractId = @ravContract) WHERE ContractId = @ravContract;   -- repair
EXEC bill.usp_GenerateInvoice @priya, @apex, @pStart, @today;
DECLARE @inv INT = (SELECT MAX(InvoiceId) FROM bill.Invoices WHERE CustomerId = @apex);
SET @d = (SELECT Total FROM bill.Invoices WHERE InvoiceId = @inv);
INSERT @r VALUES (N'X48 INVOICE RETRY after the failure is fixed: Draft invoice; 82 hours billed at the BILL rate (1700; overtime 2550) = subtotal 141,100 + 18% tax = 166,498',
    IIF((SELECT Status FROM bill.Invoices WHERE InvoiceId = @inv) = 'Draft' AND (SELECT SUM(Hours) FROM bill.InvoiceLines WHERE InvoiceId = @inv) = 82
        AND (SELECT Subtotal FROM bill.Invoices WHERE InvoiceId = @inv) = 141100 AND @d = 166498 AND NOT EXISTS (SELECT 1 FROM bill.InvoiceLines WHERE InvoiceId = @inv AND BillRate NOT IN (1700, 2550)), 1, 0), CONCAT(N'total=', @d));
INSERT @r VALUES (N'X49 only APPROVED timesheets were billed (Submitted ones were not), and each billed once',
    IIF(NOT EXISTS (SELECT 1 FROM bill.InvoiceLines l JOIN [time].TimesheetEntries e ON e.EntryId = l.TimesheetEntryId JOIN [time].Timesheets t ON t.TimesheetId = e.TimesheetId WHERE l.InvoiceId = @inv AND t.Status <> 'Approved')
        AND NOT EXISTS (SELECT 1 FROM bill.InvoiceLines l JOIN [time].TimesheetEntries e ON e.EntryId = l.TimesheetEntryId WHERE e.TimesheetId = @ts6), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC bill.usp_GenerateInvoice @priya, @apex, @pStart, @today; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X50 DOUBLE BILLING prevented: generating again finds nothing to invoice (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC bill.usp_GenerateInvoice @arjun, @apex, @pStart, @today; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X51 a customer cannot generate invoices (50005)', IIF(@e = 50005, 1, 0), CONCAT(N'err=', @e));
EXEC bill.usp_VoidInvoice @priya, @inv, N'regenerate test';
INSERT @r VALUES (N'X52 voiding a Draft invoice releases its lines', IIF((SELECT Status FROM bill.Invoices WHERE InvoiceId = @inv) = 'Void' AND NOT EXISTS (SELECT 1 FROM bill.InvoiceLines WHERE InvoiceId = @inv), 1, 0), N'');
EXEC bill.usp_GenerateInvoice @priya, @apex, @pStart, @today;
SET @inv = (SELECT MAX(InvoiceId) FROM bill.Invoices WHERE CustomerId = @apex);
SET @e = 0; BEGIN TRY EXEC bill.usp_RecordPayment @priya, @inv, 100, @today; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X53 payment on a Draft invoice is refused (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
EXEC bill.usp_IssueInvoice @priya, @inv;
INSERT @r VALUES (N'X54 issue: Issued with due date = issue + 30 days; billed timesheets become Invoiced; customer notified',
    IIF((SELECT Status FROM bill.Invoices WHERE InvoiceId = @inv) = 'Issued' AND (SELECT DueDate FROM bill.Invoices WHERE InvoiceId = @inv) = DATEADD(DAY, 30, @today)
        AND (SELECT Status FROM [time].Timesheets WHERE TimesheetId = @ts5) = 'Invoiced' AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE RecipientUserId = @arjun AND TemplateCode = 'INVOICE_ISSUED' AND RelatedEntityId = @inv), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC bill.usp_RecordPayment @priya, @inv, 999999, @today; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X55 a payment above the outstanding balance is refused (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
SET @n = (SELECT COUNT(*) FROM bill.Payments);
EXEC bill.usp_RecordPayment @priya, @inv, 66498, @today, 'BankTransfer', N'NEFT-TEST-1';
INSERT @r VALUES (N'X56 partial payment: PartiallyPaid and the balance falls to 100,000', IIF((SELECT Status FROM bill.Invoices WHERE InvoiceId = @inv) = 'PartiallyPaid' AND bill.fn_InvoiceBalance(@inv) = 100000, 1, 0), CONCAT(N'bal=', bill.fn_InvoiceBalance(@inv)));
SET @e = 0; BEGIN TRY EXEC bill.usp_VoidInvoice @priya, @inv, N'x'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X57 an invoice with payments cannot be voided (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
SET @d = bill.fn_CustomerOutstandingBalance(@apex);
EXEC bill.usp_RecordPayment @priya, @inv, 100000, @today;
INSERT @r VALUES (N'X58 final payment: Paid, balance 0; the customer''s outstanding balance drops by exactly 100,000',
    IIF((SELECT Status FROM bill.Invoices WHERE InvoiceId = @inv) = 'Paid' AND bill.fn_InvoiceBalance(@inv) = 0 AND bill.fn_CustomerOutstandingBalance(@apex) = @d - 100000, 1, 0), CONCAT(N'outstanding=', bill.fn_CustomerOutstandingBalance(@apex)));
SET @e = 0; BEGIN TRY EXEC bill.usp_RecordPayment @priya, @inv, 1, @today; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X59 a paid invoice accepts no more payments (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
CREATE TABLE #inv (InvoiceId INT, InvoiceNo NVARCHAR(30), CustomerId INT, CustomerName NVARCHAR(200), PeriodStart DATE, PeriodEnd DATE, IssueDate DATE, DueDate DATE, Status VARCHAR(15), Currency CHAR(3), Subtotal DECIMAL(12,2), TaxAmount DECIMAL(12,2), Total DECIMAL(12,2), AmountPaid DECIMAL(12,2), Balance DECIMAL(12,2), DaysOverdue INT);
INSERT #inv EXEC bill.usp_ListInvoices @meera;
INSERT @r VALUES (N'X60 ISOLATION: Brightwave sees only its own invoices', IIF((SELECT COUNT(*) FROM #inv) >= 1 AND NOT EXISTS (SELECT 1 FROM #inv WHERE CustomerId <> @bright), 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC bill.usp_ListInvoices @meera, @apex; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X61 ISOLATION: requesting another customer''s invoices by id => 50004', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC bill.usp_GetCustomerBalance @meera, @apex; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X62 ISOLATION: another customer''s balance => 50004', IIF(@e = 50004, 1, 0), CONCAT(N'err=', @e));
DELETE #inv; INSERT #inv EXEC bill.usp_ListInvoices @priya;
INSERT @r VALUES (N'X63 staff see every customer''s invoices', IIF(EXISTS (SELECT 1 FROM #inv WHERE CustomerId = @apex) AND EXISTS (SELECT 1 FROM #inv WHERE CustomerId = @bright), 1, 0), N'');

/* ----- contract renewal / termination ----- */
SET @e = 0; BEGIN TRY EXEC staff.usp_RenewContract @priya, @ravContract, @today; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X64 renewal to an earlier date is refused (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
SET @e = 0; BEGIN TRY EXEC staff.usp_RenewContract @priya, @ravContract, '2099-01-01', 2000, 1500; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X65 renewal with bill below pay is refused (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));
SET @n = (SELECT COUNT(*) FROM staff.ContractExtensions WHERE ContractId = @ravContract);
EXEC staff.usp_RenewContract @priya, @ravContract, '2099-01-01', 1300, 1800, N'Customer extension';
INSERT @r VALUES (N'X66 renewal: extension recorded, contract Active again, assignment follows, NEW rates from today while old rates are kept for history',
    IIF((SELECT COUNT(*) FROM staff.ContractExtensions WHERE ContractId = @ravContract) = @n + 1 AND (SELECT Status FROM staff.Contracts WHERE ContractId = @ravContract) = 'Active'
        AND (SELECT EndDate FROM staff.Assignments WHERE AssignmentId = @raviAsg) = '2099-01-01' AND (SELECT COUNT(*) FROM staff.ContractRates WHERE ContractId = @ravContract) = 2
        AND EXISTS (SELECT 1 FROM staff.fn_EffectiveRate(@ravContract, @today) WHERE PayRate = 1300 AND BillRate = 1800)
        AND EXISTS (SELECT 1 FROM staff.fn_EffectiveRate(@ravContract, DATEADD(DAY, -30, @today)) WHERE PayRate = 1250 AND BillRate = 1700), 1, 0), N'');
DECLARE @snehaContract INT = (SELECT ContractId FROM staff.Assignments WHERE AssignmentId = @snehaAsg);
EXEC staff.usp_TerminateContract @rahul, @snehaContract, N'Customer ended the engagement';
INSERT @r VALUES (N'X67 termination: contract Terminated, assignment Completed, placement Completed',
    IIF((SELECT Status FROM staff.Contracts WHERE ContractId = @snehaContract) = 'Terminated' AND (SELECT Status FROM staff.Assignments WHERE AssignmentId = @snehaAsg) = 'Completed'
        AND (SELECT p.Status FROM staff.Placements p JOIN staff.Contracts c ON c.PlacementId = p.PlacementId WHERE c.ContractId = @snehaContract) = 'Completed', 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC staff.usp_TerminateContract @rahul, @snehaContract, N'again'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'X68 a terminated contract cannot be terminated or renewed (50002)', IIF(@e = 50002, 1, 0), CONCAT(N'err=', @e));

/* ============================== T. TRIGGERS ============================== */
SET @n = (SELECT COUNT(*) FROM audit.AuditLogs WHERE TableName = N'cand.Candidates');
EXEC cand.usp_UpdateCandidate @divya, NULL, NULL, N'Divya', N'Reddy', N'+91 99999 00000', N'Senior QA', N'Kiran Tech', 5, 1700000, 30, N'Updated';
INSERT @r VALUES (N'T01 audit trigger: a candidate update writes ONE audit row with old+new values and the ACTING USER (from CONTEXT_INFO)',
    IIF((SELECT COUNT(*) FROM audit.AuditLogs WHERE TableName = N'cand.Candidates') = @n + 1
        AND EXISTS (SELECT 1 FROM audit.AuditLogs WHERE TableName = N'cand.Candidates' AND RecordId = CAST(@cDivya AS NVARCHAR(20)) AND Action = 'U' AND ChangedByUserId = @divya AND OldValues IS NOT NULL AND NewValues IS NOT NULL AND ChangedAt >= DATEADD(SECOND, -1, @start)), 1, 0), N'');
SET @n = (SELECT COUNT(*) FROM audit.AuditLogs WHERE TableName = N'cand.Candidates' AND Action = 'U');
UPDATE cand.Candidates SET Phone = Phone WHERE CandidateId IN (SELECT TOP 3 CandidateId FROM cand.Candidates ORDER BY CandidateId);
INSERT @r VALUES (N'T02 MULTI-ROW safe: one UPDATE touching 3 candidates writes exactly 3 audit rows', IIF((SELECT COUNT(*) FROM audit.AuditLogs WHERE TableName = N'cand.Candidates' AND Action = 'U') = @n + 3, 1, 0), N'');
SET @n = (SELECT COUNT(*) FROM audit.AuditLogs WHERE TableName = N'cand.Candidates' AND Action = 'I');
INSERT cand.Candidates (FirstName, LastName, Email, EmailNormalized) VALUES (N'Multi', N'One', N'zz.m1@x.example', N'ZZ.M1@X.EXAMPLE'), (N'Multi', N'Two', N'zz.m2@x.example', N'ZZ.M2@X.EXAMPLE');
INSERT @r VALUES (N'T03 MULTI-ROW safe: inserting 2 candidates in one statement writes 2 audit rows (action I)', IIF((SELECT COUNT(*) FROM audit.AuditLogs WHERE TableName = N'cand.Candidates' AND Action = 'I') = @n + 2, 1, 0), N'');
DELETE cand.Candidates WHERE EmailNormalized IN (N'ZZ.M1@X.EXAMPLE', N'ZZ.M2@X.EXAMPLE');
INSERT @r VALUES (N'T04 delete audited with old values and no new values', IIF((SELECT COUNT(*) FROM audit.AuditLogs WHERE TableName = N'cand.Candidates' AND Action = 'D' AND OldValues LIKE N'%zz.m%' AND NewValues IS NULL) = 2, 1, 0), N'');

DECLARE @bePost INT = (SELECT p.JobPostingId FROM rec.JobPostings p JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId WHERE jr.JobCode LIKE N'JOB-BE-%-001');
DECLARE @cKaranId INT = cand.fn_CandidateIdForUser(@karan);
SET @n = (SELECT COUNT(*) FROM cand.ApplicationStatusHistory);
INSERT cand.JobApplications (CandidateId, JobPostingId) VALUES (@cDivya, @bePost), (@cKaranId, @bePost);
INSERT @r VALUES (N'T05 MULTI-ROW safe: inserting 2 applications writes 2 status-history rows (OldStatus NULL)', IIF((SELECT COUNT(*) FROM cand.ApplicationStatusHistory) = @n + 2
    AND (SELECT COUNT(*) FROM cand.ApplicationStatusHistory h JOIN cand.JobApplications a ON a.ApplicationId = h.ApplicationId WHERE a.JobPostingId = @bePost AND a.CandidateId IN (@cDivya, @cKaranId) AND h.OldStatus IS NULL) = 2, 1, 0), N'');
SET @n = (SELECT COUNT(*) FROM cand.ApplicationStatusHistory);
UPDATE cand.JobApplications SET Status = 'Screening' WHERE JobPostingId = @bePost AND CandidateId IN (@cDivya, @cKaranId);
SET @n2 = (SELECT COUNT(*) FROM cand.ApplicationStatusHistory);
UPDATE cand.JobApplications SET Status = 'Screening' WHERE JobPostingId = @bePost AND CandidateId IN (@cDivya, @cKaranId);
INSERT @r VALUES (N'T06 history only for REAL status changes: a 2-row status update writes 2 rows; repeating it writes none', IIF(@n2 = @n + 2 AND (SELECT COUNT(*) FROM cand.ApplicationStatusHistory) = @n2, 1, 0), N'');
INSERT @r VALUES (N'T12 every audited table received audit rows from the workflows above (candidates, jobs, interviews, offers, contracts, timesheets, invoices)',
    IIF((SELECT COUNT(DISTINCT TableName) FROM audit.AuditLogs WHERE TableName IN (N'cand.Candidates', N'rec.JobRequisitions', N'cand.Interviews', N'cand.JobOffers', N'staff.Contracts', N'time.Timesheets', N'bill.Invoices')
        AND ChangedAt >= DATEADD(SECOND, -1, @start)) = 7, 1, 0),
    (SELECT STUFF((SELECT N',' + TableName FROM (SELECT DISTINCT TableName FROM audit.AuditLogs WHERE ChangedAt >= DATEADD(SECOND, -1, @start) AND TableName NOT LIKE N'(DDL)%') q FOR XML PATH('')), 1, 1, N'')));
CREATE TABLE dbo.zz_ddl_probe (x INT);
INSERT @r VALUES (N'T13 DDL trigger logs schema changes (CREATE_TABLE seen in the audit log)', IIF(EXISTS (SELECT 1 FROM audit.AuditLogs WHERE TableName = N'(DDL) dbo.zz_ddl_probe' AND RecordId = N'CREATE_TABLE'), 1, 0), N'');
DROP TABLE dbo.zz_ddl_probe;

/* ============================== finish: undo everything, then report ============================== */
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

INSERT @r VALUES (N'Z01 the suite left no trace: seed counts unchanged and no test rows remain',
    IIF((SELECT COUNT(*) FROM cand.Candidates) = 15 AND (SELECT COUNT(*) FROM hr.Employees) = 1 AND (SELECT COUNT(*) FROM bill.Invoices) = 3
        AND NOT EXISTS (SELECT 1 FROM staff.CustomerRequisitions WHERE Title LIKE N'ZZ %') AND NOT EXISTS (SELECT 1 FROM hr.EmployeeRequisitions WHERE Title LIKE N'ZZ %')
        AND NOT EXISTS (SELECT 1 FROM sec.Users WHERE EmailNormalized LIKE N'ZZ.%') AND @@TRANCOUNT = 0, 1, 0), CONCAT(N'cand=', (SELECT COUNT(*) FROM cand.Candidates), N' emp=', (SELECT COUNT(*) FROM hr.Employees), N' inv=', (SELECT COUNT(*) FROM bill.Invoices)));

/* ===== append-only guards: a THROW inside a trigger dooms the transaction, so each case gets its own throw-away transaction ===== */
DECLARE @hid INT = (SELECT MIN(HistoryId) FROM cand.ApplicationStatusHistory), @hstat VARCHAR(12), @hcount INT = (SELECT COUNT(*) FROM cand.ApplicationStatusHistory);
SET @hstat = (SELECT NewStatus FROM cand.ApplicationStatusHistory WHERE HistoryId = @hid);
DECLARE @acount INT = (SELECT COUNT(*) FROM audit.AuditLogs), @rcount INT = (SELECT COUNT(*) FROM [time].TimesheetRejections), @ecount INT = (SELECT COUNT(*) FROM hr.EmploymentHistory);

BEGIN TRANSACTION; SET @e = 0;
BEGIN TRY UPDATE cand.ApplicationStatusHistory SET NewStatus = 'Hired' WHERE HistoryId = @hid; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT @r VALUES (N'T07 status history is APPEND-ONLY: changing a past status is rejected (50010) and nothing changes', IIF(@e = 50010 AND (SELECT NewStatus FROM cand.ApplicationStatusHistory WHERE HistoryId = @hid) = @hstat, 1, 0), CONCAT(N'err=', @e));
BEGIN TRANSACTION; SET @e = 0;
BEGIN TRY UPDATE cand.ApplicationStatusHistory SET Reason = N'rewritten history' WHERE HistoryId = @hid; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT @r VALUES (N'T08 an existing history Reason cannot be rewritten (only an empty Reason may be filled) (50010)', IIF(@e = 50010 AND (SELECT Reason FROM cand.ApplicationStatusHistory WHERE HistoryId = @hid) IS NOT NULL AND (SELECT Reason FROM cand.ApplicationStatusHistory WHERE HistoryId = @hid) <> N'rewritten history', 1, 0), CONCAT(N'err=', @e));
BEGIN TRANSACTION; SET @e = 0;
BEGIN TRY DELETE cand.ApplicationStatusHistory WHERE HistoryId = @hid; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT @r VALUES (N'T09 status history rows cannot be deleted (50010)', IIF(@e = 50010 AND (SELECT COUNT(*) FROM cand.ApplicationStatusHistory) = @hcount, 1, 0), CONCAT(N'err=', @e));
BEGIN TRANSACTION; SET @e = 0;
BEGIN TRY UPDATE audit.AuditLogs SET TableName = N'x' WHERE AuditId = (SELECT MAX(AuditId) FROM audit.AuditLogs); END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT @r VALUES (N'T10 the audit log is append-only: UPDATE rejected (50010)', IIF(@e = 50010 AND NOT EXISTS (SELECT 1 FROM audit.AuditLogs WHERE TableName = N'x'), 1, 0), CONCAT(N'err=', @e));
BEGIN TRANSACTION; SET @e = 0;
BEGIN TRY DELETE audit.AuditLogs; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT @r VALUES (N'T11 the audit log is append-only: DELETE rejected (50010)', IIF(@e = 50010 AND (SELECT COUNT(*) FROM audit.AuditLogs) >= @acount, 1, 0), CONCAT(N'err=', @e));
BEGIN TRANSACTION; SET @e = 0;
BEGIN TRY UPDATE [time].TimesheetRejections SET Reason = N'edited'; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT @r VALUES (N'T12b timesheet rejections are append-only (50010)', IIF(@e = 50010 AND NOT EXISTS (SELECT 1 FROM [time].TimesheetRejections WHERE Reason = N'edited'), 1, 0), CONCAT(N'err=', @e));
BEGIN TRANSACTION; SET @e = 0;
BEGIN TRY DELETE hr.EmploymentHistory; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT @r VALUES (N'T12c employment history is append-only (50010)', IIF(@e = 50010 AND (SELECT COUNT(*) FROM hr.EmploymentHistory) = @ecount, 1, 0), CONCAT(N'err=', @e));

DECLARE @line NVARCHAR(700);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT CASE WHEN Ok = 1 THEN N'PASS  ' ELSE N'FAIL  ' END + Name + CASE WHEN Ok = 0 AND Detail <> N'' THEN N'  -> ' + Detail ELSE N'' END FROM @r ORDER BY Id;
OPEN c; FETCH NEXT FROM c INTO @line;
WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c INTO @line; END
CLOSE c; DEALLOCATE c;
DECLARE @total INT = (SELECT COUNT(*) FROM @r), @passed INT = (SELECT COUNT(*) FROM @r WHERE Ok = 1);
PRINT CONCAT(N'--- Phase 3 tests: ', @passed, N' passed, ', @total - @passed, N' failed, ', @total, N' total ---');
IF @passed <> @total RAISERROR(N'Phase 3 tests FAILED', 16, 1);
GO
