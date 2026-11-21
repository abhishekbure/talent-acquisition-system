/* ============================================================================
   TAMS - 07_Functions / 01_Functions.sql
   Scalar and inline table-valued functions. All CREATE OR ALTER (repeatable).
   Functions are created BEFORE stored procedures by Run-DatabaseSetup.ps1.
   ========================================================================== */
USE TalentAcquisitionDB;
GO

/* ---------- generic helpers ---------- */
-- Phase 11: the business calendar day (IST) - what "today" means for nightly jobs (ClosesBy, contract end dates, daily summary).
CREATE OR ALTER FUNCTION dbo.fn_BusinessToday ()
RETURNS DATE
AS
BEGIN
    RETURN CAST((SYSUTCDATETIME() AT TIME ZONE 'UTC') AT TIME ZONE 'India Standard Time' AS DATE);
END
GO

-- Phase 9: notifications whose body carries a one-time secret (sign-in links). Their body is erased once the message is
-- delivered or abandoned (KI-021), they are e-mail only (not in the in-app list) and an administrator cannot re-send them.
CREATE OR ALTER FUNCTION notify.fn_IsSecurityTemplate (@TemplateCode VARCHAR(40))
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN @TemplateCode IN ('PASSWORD_RESET', 'EMAIL_VERIFY') THEN 1 ELSE 0 END;
END
GO

-- Phase 9: times written into notification text use the business time zone (India, IST); data stays in UTC.
-- One place to change if the business moves: the time-zone name below (Windows name, see sys.time_zone_info).
CREATE OR ALTER FUNCTION dbo.fn_BusinessTime (@Utc DATETIME2(0))
RETURNS NVARCHAR(40)
AS
BEGIN
    IF @Utc IS NULL RETURN NULL;
    RETURN FORMAT((@Utc AT TIME ZONE 'UTC') AT TIME ZONE 'India Standard Time', 'dd MMM yyyy, HH:mm', 'en-GB') + N' IST';
END
GO

CREATE OR ALTER FUNCTION dbo.fn_PadNumber (@n BIGINT, @width INT)
RETURNS NVARCHAR(20)
AS
BEGIN
    DECLARE @s NVARCHAR(20) = CAST(@n AS NVARCHAR(20));
    RETURN CASE WHEN LEN(@s) >= @width THEN @s ELSE RIGHT(REPLICATE(N'0', @width) + @s, @width) END;
END
GO

-- Splits a comma-separated list with a recursive CTE (no STRING_SPLIT). Limit: 99 items (default recursion limit).
CREATE OR ALTER FUNCTION dbo.fn_SplitCsv (@list NVARCHAR(MAX))
RETURNS TABLE
AS
RETURN
(
    WITH s AS (
        SELECT CAST(NULL AS NVARCHAR(MAX)) AS Item, CAST(@list + N',' AS NVARCHAR(MAX)) AS Rest
        WHERE @list IS NOT NULL
        UNION ALL
        SELECT CAST(LTRIM(RTRIM(LEFT(Rest, CHARINDEX(N',', Rest) - 1))) AS NVARCHAR(MAX)),
               CAST(SUBSTRING(Rest, CHARINDEX(N',', Rest) + 1, LEN(Rest)) AS NVARCHAR(MAX))
        FROM s WHERE LEN(Rest) > 0
    )
    SELECT Item FROM s WHERE Item IS NOT NULL AND Item <> N''
);
GO

/* ---------- identity / scope helpers ---------- */
CREATE OR ALTER FUNCTION sec.fn_UserHasRole (@UserId INT, @RoleName NVARCHAR(50))
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS (SELECT 1 FROM sec.UserRoles ur
                             JOIN sec.Roles r ON r.RoleId = ur.RoleId
                             JOIN sec.Users u ON u.UserId = ur.UserId AND u.IsActive = 1
                             WHERE ur.UserId = @UserId AND r.RoleName = @RoleName) THEN 1 ELSE 0 END;
END
GO

CREATE OR ALTER FUNCTION sec.fn_UserCustomerId (@UserId INT)
RETURNS INT
AS
BEGIN
    RETURN (SELECT cu.CustomerId FROM org.CustomerUsers cu JOIN sec.Users u ON u.UserId = cu.UserId AND u.IsActive = 1 WHERE cu.UserId = @UserId);
END
GO

CREATE OR ALTER FUNCTION cand.fn_CandidateIdForUser (@UserId INT)
RETURNS INT
AS
BEGIN
    RETURN (SELECT CandidateId FROM cand.Candidates WHERE UserId = @UserId);
END
GO

CREATE OR ALTER FUNCTION staff.fn_ContractorIdForUser (@UserId INT)
RETURNS INT
AS
BEGIN
    RETURN (SELECT ContractorId FROM staff.Contractors WHERE UserId = @UserId AND Status = 'Active');
END
GO

CREATE OR ALTER FUNCTION sec.fn_IsStaff (@UserId INT)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS (SELECT 1 FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId JOIN sec.Users u ON u.UserId = ur.UserId AND u.IsActive = 1
                             WHERE ur.UserId = @UserId AND r.RoleName IN (N'Recruiter', N'HRManager', N'Administrator')) THEN 1 ELSE 0 END;
END
GO

-- SCOPE of an interview: the candidate's own, the owning customer's, or staff (HR/Admin all; a recruiter only where involved).
CREATE OR ALTER FUNCTION cand.fn_CanSeeInterview (@UserId INT, @InterviewId INT)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS (
        SELECT 1 FROM cand.Interviews i
        LEFT JOIN cand.JobApplications a ON a.ApplicationId = i.JobApplicationId
        LEFT JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId
        LEFT JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
        LEFT JOIN staff.SubmittedCandidates s ON s.SubmissionId = i.SubmittedCandidateId
        LEFT JOIN staff.CustomerRequisitions cr ON cr.CustomerRequisitionId = s.CustomerRequisitionId
        WHERE i.InterviewId = @InterviewId AND (
              sec.fn_UserHasRole(@UserId, N'Administrator') = 1 OR sec.fn_UserHasRole(@UserId, N'HRManager') = 1
           OR (sec.fn_UserHasRole(@UserId, N'Recruiter') = 1 AND (i.ScheduledByUserId = @UserId OR jr.OwnerRecruiterUserId = @UserId OR cr.AssignedRecruiterUserId = @UserId
                 OR EXISTS (SELECT 1 FROM cand.InterviewPanels ip WHERE ip.InterviewId = i.InterviewId AND ip.UserId = @UserId)))
           OR (i.CustomerId IS NOT NULL AND i.CustomerId = sec.fn_UserCustomerId(@UserId))
           OR COALESCE(a.CandidateId, s.CandidateId) = cand.fn_CandidateIdForUser(@UserId))) THEN 1 ELSE 0 END;
END
GO

/* ---------- business calculations ---------- */
-- Sum of employment periods (overlaps are not merged). Open-ended jobs run to today.
CREATE OR ALTER FUNCTION cand.fn_ExperienceYears (@CandidateId INT)
RETURNS DECIMAL(4,1)
AS
BEGIN
    DECLARE @days INT = (SELECT SUM(DATEDIFF(DAY, StartDate, ISNULL(EndDate, CAST(SYSUTCDATETIME() AS DATE))))
                         FROM cand.CandidateExperience WHERE CandidateId = @CandidateId);
    RETURN CAST(ROUND(ISNULL(@days, 0) / 365.25, 1) AS DECIMAL(4,1));
END
GO

CREATE OR ALTER FUNCTION staff.fn_ContractDurationDays (@ContractId INT)
RETURNS INT
AS
BEGIN
    RETURN (SELECT DATEDIFF(DAY, StartDate, EndDate) + 1 FROM staff.Contracts WHERE ContractId = @ContractId);
END
GO

-- Negative result = already expired.
CREATE OR ALTER FUNCTION staff.fn_DaysToContractExpiry (@ContractId INT)
RETURNS INT
AS
BEGIN
    RETURN (SELECT DATEDIFF(DAY, CAST(SYSUTCDATETIME() AS DATE), EndDate) FROM staff.Contracts WHERE ContractId = @ContractId);
END
GO

-- Open applications age to "now"; finished ones age to their last status change.
CREATE OR ALTER FUNCTION cand.fn_ApplicationAgeDays (@ApplicationId INT)
RETURNS INT
AS
BEGIN
    DECLARE @applied DATETIME2(0), @status VARCHAR(12), @last DATETIME2(0);
    SELECT @applied = AppliedAt, @status = Status FROM cand.JobApplications WHERE ApplicationId = @ApplicationId;
    IF @applied IS NULL RETURN NULL;
    SELECT @last = MAX(ChangedAt) FROM cand.ApplicationStatusHistory WHERE ApplicationId = @ApplicationId;
    RETURN DATEDIFF(DAY, @applied, CASE WHEN @status IN ('Hired','Rejected','Withdrawn') AND @last IS NOT NULL THEN @last ELSE SYSUTCDATETIME() END);
END
GO

-- Days from application to the 'Hired' status change; NULL if not hired.
CREATE OR ALTER FUNCTION cand.fn_TimeToHireDays (@ApplicationId INT)
RETURNS INT
AS
BEGIN
    RETURN (SELECT DATEDIFF(DAY, a.AppliedAt, MIN(h.ChangedAt))
            FROM cand.JobApplications a
            JOIN cand.ApplicationStatusHistory h ON h.ApplicationId = a.ApplicationId AND h.NewStatus = 'Hired'
            WHERE a.ApplicationId = @ApplicationId
            GROUP BY a.AppliedAt);
END
GO

-- Invoice total minus payments (Void invoices carry no balance).
CREATE OR ALTER FUNCTION bill.fn_InvoiceBalance (@InvoiceId INT)
RETURNS DECIMAL(12,2)
AS
BEGIN
    RETURN (SELECT CASE WHEN i.Status = 'Void' THEN 0
                        ELSE i.Total - ISNULL((SELECT SUM(p.Amount) FROM bill.Payments p WHERE p.InvoiceId = i.InvoiceId), 0) END
            FROM bill.Invoices i WHERE i.InvoiceId = @InvoiceId);
END
GO

-- Money the customer still owes on ISSUED / PARTIALLY PAID invoices.
CREATE OR ALTER FUNCTION bill.fn_CustomerOutstandingBalance (@CustomerId INT)
RETURNS DECIMAL(12,2)
AS
BEGIN
    RETURN ISNULL((SELECT SUM(i.Total - ISNULL(p.Paid, 0))
                   FROM bill.Invoices i
                   LEFT JOIN (SELECT InvoiceId, SUM(Amount) AS Paid FROM bill.Payments GROUP BY InvoiceId) p ON p.InvoiceId = i.InvoiceId
                   WHERE i.CustomerId = @CustomerId AND i.Status IN ('Issued', 'PartiallyPaid')), 0);
END
GO

/* ---------- table-valued functions ---------- */
CREATE OR ALTER FUNCTION cand.fn_CandidateSkills (@CandidateId INT)
RETURNS TABLE
AS
RETURN
(
    SELECT SkillName, YearsExperience, ProficiencyLevel
    FROM cand.CandidateSkills WHERE CandidateId = @CandidateId
);
GO

-- Candidate search: free text (name/e-mail/title/skill), ALL listed skills required, experience range, status.
CREATE OR ALTER FUNCTION cand.fn_SearchCandidates
    (@Q NVARCHAR(100), @SkillsCsv NVARCHAR(MAX), @MinExp DECIMAL(4,1), @MaxExp DECIMAL(4,1), @Status VARCHAR(12))
RETURNS TABLE
AS
RETURN
(
    SELECT c.CandidateId, c.FirstName, c.LastName, c.Email, c.Phone, c.CurrentTitle, c.CurrentEmployer,
           c.TotalExperienceYears, c.ExpectedSalary, c.NoticePeriodDays, c.Status
    FROM cand.Candidates c
    -- Phase 13: the candidates with a matching skill are found ONCE and joined, instead of probing the skills table for every
    -- candidate inside the OR (100,000 probes / ~450,000 reads on the performance copy)
    -- Case-insensitive matching on UPPER(...) with a binary collation: same matches as the case-insensitive collation, about
    -- 5x less CPU per row (measured: 230 ms -> 47 ms for a substring search over 100,000 candidates).
    LEFT JOIN (SELECT DISTINCT k.CandidateId FROM cand.CandidateSkills k
               WHERE @Q IS NOT NULL AND UPPER(k.SkillName) COLLATE Latin1_General_BIN2 LIKE N'%' + UPPER(@Q) + N'%') ks ON ks.CandidateId = c.CandidateId
    WHERE (@Status IS NULL OR c.Status = @Status)
      AND (@MinExp IS NULL OR c.TotalExperienceYears >= @MinExp)
      AND (@MaxExp IS NULL OR c.TotalExperienceYears <= @MaxExp)
      AND (@Q IS NULL OR UPPER(c.FirstName) COLLATE Latin1_General_BIN2 LIKE N'%' + UPPER(@Q) + N'%'
           OR UPPER(c.LastName) COLLATE Latin1_General_BIN2 LIKE N'%' + UPPER(@Q) + N'%'
           OR UPPER(c.Email) COLLATE Latin1_General_BIN2 LIKE N'%' + UPPER(@Q) + N'%'
           OR UPPER(c.CurrentTitle) COLLATE Latin1_General_BIN2 LIKE N'%' + UPPER(@Q) + N'%'
           OR ks.CandidateId IS NOT NULL)
      AND NOT EXISTS (SELECT 1 FROM dbo.fn_SplitCsv(@SkillsCsv) s
                      WHERE NOT EXISTS (SELECT 1 FROM cand.CandidateSkills k WHERE k.CandidateId = c.CandidateId AND k.SkillName = s.Item))
);
GO

-- The contract rate row in force on a given work date (pay and bill kept in separate columns).
CREATE OR ALTER FUNCTION staff.fn_EffectiveRate (@ContractId INT, @WorkDate DATE)
RETURNS TABLE
AS
RETURN
(
    SELECT TOP (1) ContractRateId, PayRate, BillRate, OvertimePayMultiplier, OvertimeBillMultiplier, Currency
    FROM staff.ContractRates
    WHERE ContractId = @ContractId AND EffectiveFrom <= @WorkDate AND (EffectiveTo IS NULL OR EffectiveTo >= @WorkDate)
    ORDER BY EffectiveFrom DESC
);
GO
