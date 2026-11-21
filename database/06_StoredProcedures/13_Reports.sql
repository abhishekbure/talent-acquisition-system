/* ============================================================================
   TAMS - 06_StoredProcedures / 13_Reports.sql   (Phase 10)
   Parameterised reports. Every report procedure has the same parameters
     (@ActorUserId, @FromDate, @ToDate, @CustomerId, @Days)
   and checks the caller's role itself (report.usp_ReportScope); report.usp_RunReport is the single entry point used by
   the API and authorises against the catalog report.ReportDefinitions first.
   * Date range: inclusive calendar days; NULL = open-ended. The catalog says which date each report filters.
   * Staffing reports are customer-scoped: a Customer user always gets their own company (a different @CustomerId is
     "not found", 50004); staff may filter by any customer. Pay rates and margins are never returned to a Customer.
   * Column names are PascalCase; the API turns them into labels. Suffix Pct = percentage.
   ========================================================================== */
USE TalentAcquisitionDB;
GO

/* ---------------- shared checks ---------------- */
CREATE OR ALTER PROCEDURE report.usp_ReportScope
    @ActorUserId INT, @Roles NVARCHAR(200), @FromDate DATE, @ToDate DATE, @CustomerScoped BIT, @CustomerId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, @Roles;
    IF @FromDate IS NOT NULL AND @ToDate IS NOT NULL AND @FromDate > @ToDate THROW 50001, N'The start date must not be after the end date.', 1;
    IF @FromDate < '2000-01-01' OR @ToDate > '2100-12-31' THROW 50001, N'Dates must lie between 2000 and 2100.', 1;
    IF @CustomerScoped = 0 BEGIN SET @CustomerId = NULL; RETURN; END
    IF sec.fn_IsStaff(@ActorUserId) = 1
    BEGIN
        IF @CustomerId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM org.Customers WHERE CustomerId = @CustomerId) THROW 50004, N'Customer not found.', 1;
    END
    ELSE
    BEGIN
        DECLARE @own INT = sec.fn_UserCustomerId(@ActorUserId);
        IF @own IS NULL OR (@CustomerId IS NOT NULL AND @CustomerId <> @own) THROW 50004, N'Customer not found.', 1;
        SET @CustomerId = @own;
    END
END
GO

/* ============================== RECRUITMENT (Recruiter, HR Manager, Administrator) ============================== */
CREATE OR ALTER PROCEDURE report.usp_Rpt_OpenRequisitions @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'Recruiter,HRManager,Administrator', @FromDate, @ToDate, 0, @CustomerId OUTPUT;
    DECLARE @f DATETIME2(0) = @FromDate, @t DATETIME2(0) = DATEADD(DAY, 1, @ToDate);
    SELECT v.JobCode, v.Title, v.Department, v.Location, v.Openings, v.OwnerRecruiter AS Recruiter, v.OpenedAt, v.ClosesBy, v.DaysOpen,
           v.ApplicationCount AS Applications,
           (SELECT COUNT(*) FROM cand.JobApplications a JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId
             WHERE p.JobRequisitionId = v.JobRequisitionId AND a.Status NOT IN ('Hired', 'Rejected', 'Withdrawn')) AS InProgress,
           v.HiredCount AS Hired,
           CASE WHEN v.Openings > v.HiredCount THEN v.Openings - v.HiredCount ELSE 0 END AS PositionsLeft
    FROM report.vw_OpenRequisitions v
    WHERE (@f IS NULL OR v.OpenedAt >= @f) AND (@t IS NULL OR v.OpenedAt < @t)
    ORDER BY v.OpenedAt, v.JobCode;
END
GO

CREATE OR ALTER PROCEDURE report.usp_Rpt_ApplicationsByStatus @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'Recruiter,HRManager,Administrator', @FromDate, @ToDate, 0, @CustomerId OUTPUT;
    DECLARE @f DATETIME2(0) = @FromDate, @t DATETIME2(0) = DATEADD(DAY, 1, @ToDate);
    WITH s AS (SELECT * FROM (VALUES ('Applied', 1), ('Screening', 2), ('Shortlisted', 3), ('Interview', 4), ('Selected', 5),
                                     ('OfferStage', 6), ('Hired', 7), ('Rejected', 8), ('Withdrawn', 9)) v (Status, Seq)),
         a AS (SELECT Status, COUNT(*) AS N FROM cand.JobApplications
               WHERE (@f IS NULL OR AppliedAt >= @f) AND (@t IS NULL OR AppliedAt < @t) GROUP BY Status)
    SELECT s.Status, ISNULL(a.N, 0) AS Applications,
           CAST(CASE WHEN SUM(ISNULL(a.N, 0)) OVER () = 0 THEN 0 ELSE 100.0 * ISNULL(a.N, 0) / SUM(ISNULL(a.N, 0)) OVER () END AS DECIMAL(5,1)) AS SharePct
    FROM s LEFT JOIN a ON a.Status = s.Status
    ORDER BY s.Seq;
END
GO

CREATE OR ALTER PROCEDURE report.usp_Rpt_Pipeline @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'Recruiter,HRManager,Administrator', @FromDate, @ToDate, 0, @CustomerId OUTPUT;
    DECLARE @f DATETIME2(0) = @FromDate, @t DATETIME2(0) = DATEADD(DAY, 1, @ToDate);
    SELECT jr.JobCode, jr.Title, jr.Status AS JobStatus, u.DisplayName AS Recruiter,
           COUNT(a.ApplicationId) AS Total,
           COUNT(CASE WHEN a.Status = 'Applied' THEN 1 END)     AS Applied,
           COUNT(CASE WHEN a.Status = 'Screening' THEN 1 END)   AS Screening,
           COUNT(CASE WHEN a.Status = 'Shortlisted' THEN 1 END) AS Shortlisted,
           COUNT(CASE WHEN a.Status = 'Interview' THEN 1 END)   AS Interview,
           COUNT(CASE WHEN a.Status = 'Selected' THEN 1 END)    AS Selected,
           COUNT(CASE WHEN a.Status = 'OfferStage' THEN 1 END)  AS OfferStage,
           COUNT(CASE WHEN a.Status = 'Hired' THEN 1 END)       AS Hired,
           COUNT(CASE WHEN a.Status = 'Rejected' THEN 1 END)    AS Rejected,
           COUNT(CASE WHEN a.Status = 'Withdrawn' THEN 1 END)   AS Withdrawn
    FROM rec.JobRequisitions jr
    LEFT JOIN sec.Users u ON u.UserId = jr.OwnerRecruiterUserId
    LEFT JOIN (rec.JobPostings p JOIN cand.JobApplications a ON a.JobPostingId = p.JobPostingId
                                     AND (@f IS NULL OR a.AppliedAt >= @f) AND (@t IS NULL OR a.AppliedAt < @t))
           ON p.JobRequisitionId = jr.JobRequisitionId
    WHERE jr.Status <> 'Draft'
    GROUP BY jr.JobRequisitionId, jr.JobCode, jr.Title, jr.Status, u.DisplayName
    ORDER BY jr.JobCode;
END
GO

CREATE OR ALTER PROCEDURE report.usp_Rpt_Sourcing @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'Recruiter,HRManager,Administrator', @FromDate, @ToDate, 0, @CustomerId OUTPUT;
    DECLARE @f DATETIME2(0) = @FromDate, @t DATETIME2(0) = DATEADD(DAY, 1, @ToDate);
    -- the application's own source, else the candidate's source
    -- Phase 13: aggregated per source in one pass (the 300,000 applications of the performance copy were first copied into an
    -- indexed table variable: ~600 ms of single-threaded work). Same rules; the report suite reconciles the figures.
    SELECT x.SourceId, COUNT(*) AS Applications, COUNT(DISTINCT x.CandidateId) AS Candidates,
           SUM(x.Interviewed) AS Interviewed, SUM(CASE WHEN x.Status = 'Hired' THEN 1 ELSE 0 END) AS Hired
    INTO #bySource
    FROM (SELECT a.CandidateId, a.Status, COALESCE(a.SourceId, c.SourceId) AS SourceId,
                 CASE WHEN iv.JobApplicationId IS NOT NULL THEN 1 ELSE 0 END AS Interviewed
          FROM cand.JobApplications a JOIN cand.Candidates c ON c.CandidateId = a.CandidateId
          LEFT JOIN (SELECT DISTINCT i.JobApplicationId FROM cand.Interviews i WHERE i.Status = 'Completed' AND i.JobApplicationId IS NOT NULL) iv ON iv.JobApplicationId = a.ApplicationId
          WHERE (@f IS NULL OR a.AppliedAt >= @f) AND (@t IS NULL OR a.AppliedAt < @t)) x
    GROUP BY x.SourceId;

    SELECT x.Source, x.SourceType, x.Applications, x.Candidates, x.Interviewed, x.Hired,
           CAST(CASE WHEN x.Applications = 0 THEN 0 ELSE 100.0 * x.Hired / x.Applications END AS DECIMAL(5,1)) AS HireRatePct
    FROM (SELECT s.Name AS Source, s.SourceType, ISNULL(b.Applications, 0) AS Applications, ISNULL(b.Candidates, 0) AS Candidates,
                 ISNULL(b.Interviewed, 0) AS Interviewed, ISNULL(b.Hired, 0) AS Hired
          FROM rec.RecruitmentSources s LEFT JOIN #bySource b ON b.SourceId = s.SourceId
          WHERE s.IsActive = 1 OR b.Applications > 0
          UNION ALL
          SELECT N'(not recorded)', NULL, b.Applications, b.Candidates, b.Interviewed, b.Hired
          FROM #bySource b WHERE b.SourceId IS NULL AND b.Applications > 0) x
    ORDER BY x.Applications DESC, x.Source;
END
GO

CREATE OR ALTER PROCEDURE report.usp_Rpt_InterviewConversion @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'Recruiter,HRManager,Administrator', @FromDate, @ToDate, 0, @CustomerId OUTPUT;
    DECLARE @f DATETIME2(0) = @FromDate, @t DATETIME2(0) = DATEADD(DAY, 1, @ToDate);
    -- internal recruitment interviews that start in the period
    -- Phase 13: ONE grouped pass, no temporary table (the per-job correlated subqueries over a table variable read 892,000
    -- pages for 74,000 interviews; a temp-table version still wrote 65,000 rows per run and queued under load).
    -- Same definitions: candidates interviewed / reached offer / hired count each completed application once.
    WITH iv AS (
        SELECT i.JobApplicationId AS ApplicationId, p.JobRequisitionId, i.Status, a.Status AS AppStatus,
               CASE WHEN ofr.ApplicationId IS NOT NULL THEN 1 ELSE 0 END AS HasOffer,
               ISNULL(fb.Given, 0) AS Given, ISNULL(fb.Positive, 0) AS Positive
        FROM cand.Interviews i
        JOIN cand.JobApplications a ON a.ApplicationId = i.JobApplicationId
        JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId
        LEFT JOIN (SELECT f.InterviewId, COUNT(*) AS Given, SUM(CASE WHEN f.Recommendation IN ('Yes', 'StrongYes') THEN 1 ELSE 0 END) AS Positive
                   FROM cand.InterviewFeedback f GROUP BY f.InterviewId) fb ON fb.InterviewId = i.InterviewId
        LEFT JOIN (SELECT DISTINCT o.ApplicationId FROM cand.JobOffers o) ofr ON ofr.ApplicationId = a.ApplicationId
        WHERE (@f IS NULL OR i.StartsAt >= @f) AND (@t IS NULL OR i.StartsAt < @t)),
    g AS (
        SELECT JobRequisitionId, COUNT(*) AS Interviews,
               SUM(CASE WHEN Status = 'Completed' THEN 1 ELSE 0 END) AS Completed,
               SUM(CASE WHEN Status IN ('Cancelled', 'NoShow') THEN 1 ELSE 0 END) AS CancelledOrNoShow,
               COUNT(DISTINCT CASE WHEN Status = 'Completed' THEN ApplicationId END) AS CandidatesInterviewed,
               SUM(Given) AS FeedbackGiven, SUM(Positive) AS PositiveFeedback,
               COUNT(DISTINCT CASE WHEN Status = 'Completed' AND (AppStatus IN ('OfferStage', 'Hired') OR HasOffer = 1) THEN ApplicationId END) AS ReachedOffer,
               COUNT(DISTINCT CASE WHEN Status = 'Completed' AND AppStatus = 'Hired' THEN ApplicationId END) AS Hired
        FROM iv GROUP BY JobRequisitionId)
    SELECT jr.JobCode, jr.Title, g.Interviews, g.Completed, g.CancelledOrNoShow, g.CandidatesInterviewed, g.FeedbackGiven, g.PositiveFeedback,
           g.ReachedOffer, g.Hired,
           CAST(CASE WHEN g.CandidatesInterviewed = 0 THEN 0 ELSE 100.0 * g.ReachedOffer / g.CandidatesInterviewed END AS DECIMAL(5,1)) AS ConversionPct
    FROM g JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = g.JobRequisitionId
    ORDER BY jr.JobCode;
END
GO

CREATE OR ALTER PROCEDURE report.usp_Rpt_OfferAcceptance @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'Recruiter,HRManager,Administrator', @FromDate, @ToDate, 0, @CustomerId OUTPUT;
    DECLARE @f DATETIME2(0) = @FromDate, @t DATETIME2(0) = DATEADD(DAY, 1, @ToDate);
    SELECT x.[Month], x.Offers, x.Sent, x.Accepted, x.Declined, x.Expired, x.StillOpen, x.RejectedInternally,
           CAST(CASE WHEN x.Accepted + x.Declined + x.Expired = 0 THEN NULL ELSE 100.0 * x.Accepted / (x.Accepted + x.Declined + x.Expired) END AS DECIMAL(5,1)) AS AcceptancePct
    FROM (SELECT CONVERT(CHAR(7), o.CreatedAt, 126) AS [Month], COUNT(*) AS Offers, COUNT(o.SentAt) AS Sent,
                 COUNT(CASE WHEN o.Status = 'Accepted' THEN 1 END) AS Accepted,
                 COUNT(CASE WHEN o.Status = 'Declined' THEN 1 END) AS Declined,
                 COUNT(CASE WHEN o.Status = 'Expired' THEN 1 END) AS Expired,
                 COUNT(CASE WHEN o.Status IN ('Draft', 'PendingApproval', 'Approved', 'Sent') THEN 1 END) AS StillOpen,
                 COUNT(CASE WHEN o.Status = 'Rejected' THEN 1 END) AS RejectedInternally
          FROM cand.JobOffers o
          WHERE (@f IS NULL OR o.CreatedAt >= @f) AND (@t IS NULL OR o.CreatedAt < @t)
          GROUP BY CONVERT(CHAR(7), o.CreatedAt, 126)) x
    ORDER BY x.[Month];
END
GO

CREATE OR ALTER PROCEDURE report.usp_Rpt_TimeToHire @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'Recruiter,HRManager,Administrator', @FromDate, @ToDate, 0, @CustomerId OUTPUT;
    DECLARE @f DATETIME2(0) = @FromDate, @t DATETIME2(0) = DATEADD(DAY, 1, @ToDate);
    -- same definition as cand.fn_TimeToHireDays: application date to the first change to Hired
    SELECT c.FirstName + N' ' + c.LastName AS Candidate, jr.JobCode, jr.Title, d.Name AS Department, src.Name AS Source,
           a.AppliedAt, h.HiredAt, DATEDIFF(DAY, a.AppliedAt, h.HiredAt) AS DaysToHire
    FROM cand.JobApplications a
    CROSS APPLY (SELECT MIN(x.ChangedAt) AS HiredAt FROM cand.ApplicationStatusHistory x WHERE x.ApplicationId = a.ApplicationId AND x.NewStatus = 'Hired') h
    JOIN cand.Candidates c ON c.CandidateId = a.CandidateId
    JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId
    JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
    JOIN org.Departments d ON d.DepartmentId = jr.DepartmentId
    LEFT JOIN rec.RecruitmentSources src ON src.SourceId = COALESCE(a.SourceId, c.SourceId)
    WHERE a.Status = 'Hired' AND h.HiredAt IS NOT NULL
      AND (@f IS NULL OR h.HiredAt >= @f) AND (@t IS NULL OR h.HiredAt < @t)
    ORDER BY h.HiredAt;
END
GO

CREATE OR ALTER PROCEDURE report.usp_Rpt_RecruiterPerformance @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'Recruiter,HRManager,Administrator', @FromDate, @ToDate, 0, @CustomerId OUTPUT;
    DECLARE @f DATETIME2(0) = @FromDate, @t DATETIME2(0) = DATEADD(DAY, 1, @ToDate);
    SELECT u.DisplayName AS Recruiter,
           (SELECT COUNT(*) FROM rec.JobRequisitions jr WHERE jr.OwnerRecruiterUserId = u.UserId AND jr.Status IN ('Open', 'OnHold')) AS OpenJobs,
           (SELECT COUNT(*) FROM cand.JobApplications a JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
             WHERE jr.OwnerRecruiterUserId = u.UserId AND (@f IS NULL OR a.AppliedAt >= @f) AND (@t IS NULL OR a.AppliedAt < @t)) AS Applications,
           (SELECT COUNT(*) FROM cand.Interviews i JOIN cand.JobApplications a ON a.ApplicationId = i.JobApplicationId JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId
             JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
             WHERE jr.OwnerRecruiterUserId = u.UserId AND (@f IS NULL OR i.StartsAt >= @f) AND (@t IS NULL OR i.StartsAt < @t)) AS Interviews,
           (SELECT COUNT(*) FROM cand.JobOffers o WHERE o.CreatedByUserId = u.UserId AND (@f IS NULL OR o.CreatedAt >= @f) AND (@t IS NULL OR o.CreatedAt < @t)) AS OffersCreated,
           (SELECT COUNT(*) FROM cand.JobOffers o WHERE o.CreatedByUserId = u.UserId AND o.Status = 'Accepted' AND (@f IS NULL OR o.CreatedAt >= @f) AND (@t IS NULL OR o.CreatedAt < @t)) AS OffersAccepted,
           h.Hires, h.AvgDaysToHire,
           (SELECT COUNT(*) FROM staff.SubmittedCandidates s WHERE s.SubmittedByUserId = u.UserId AND (@f IS NULL OR s.SubmittedAt >= @f) AND (@t IS NULL OR s.SubmittedAt < @t)) AS StaffingSubmissions,
           (SELECT COUNT(*) FROM staff.Placements pl WHERE pl.CreatedByUserId = u.UserId AND (@FromDate IS NULL OR pl.PlacementDate >= @FromDate) AND (@ToDate IS NULL OR pl.PlacementDate <= @ToDate)) AS Placements
    FROM sec.Users u
    OUTER APPLY (SELECT COUNT(*) AS Hires, CAST(AVG(CAST(DATEDIFF(DAY, a.AppliedAt, hh.HiredAt) AS DECIMAL(9,2))) AS DECIMAL(9,1)) AS AvgDaysToHire
                 FROM cand.JobApplications a
                 CROSS APPLY (SELECT MIN(x.ChangedAt) AS HiredAt FROM cand.ApplicationStatusHistory x WHERE x.ApplicationId = a.ApplicationId AND x.NewStatus = 'Hired') hh
                 JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
                 WHERE jr.OwnerRecruiterUserId = u.UserId AND a.Status = 'Hired' AND hh.HiredAt IS NOT NULL
                   AND (@f IS NULL OR hh.HiredAt >= @f) AND (@t IS NULL OR hh.HiredAt < @t)) h
    WHERE u.IsActive = 1 AND sec.fn_UserHasRole(u.UserId, N'Recruiter') = 1
    ORDER BY h.Hires DESC, u.DisplayName;
END
GO

/* ============================== STAFFING (Recruiter, Administrator; Customer: own company only) ============================== */
CREATE OR ALTER PROCEDURE report.usp_Rpt_StaffingRequests @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'Recruiter,Administrator,Customer', @FromDate, @ToDate, 1, @CustomerId OUTPUT;
    DECLARE @f DATETIME2(0) = @FromDate, @t DATETIME2(0) = DATEADD(DAY, 1, @ToDate);
    SELECT cr.RequestNo, cu.Name AS Customer, cr.Title, cr.Positions, cr.Status, cr.CreatedAt, cr.StartDate, cr.MaxBillRate, u.DisplayName AS Recruiter,
           (SELECT COUNT(*) FROM staff.SubmittedCandidates s WHERE s.CustomerRequisitionId = cr.CustomerRequisitionId) AS Submissions,
           (SELECT COUNT(*) FROM staff.SubmittedCandidates s WHERE s.CustomerRequisitionId = cr.CustomerRequisitionId AND s.Status IN ('Shortlisted', 'Interview', 'Selected')) AS Shortlisted,
           (SELECT COUNT(*) FROM staff.SubmittedCandidates s WHERE s.CustomerRequisitionId = cr.CustomerRequisitionId AND s.Status = 'Selected') AS Selected,
           (SELECT COUNT(*) FROM staff.Placements pl JOIN staff.SubmittedCandidates s ON s.SubmissionId = pl.SubmissionId
             WHERE s.CustomerRequisitionId = cr.CustomerRequisitionId AND pl.Status <> 'Cancelled') AS Placed
    FROM staff.CustomerRequisitions cr
    JOIN org.Customers cu ON cu.CustomerId = cr.CustomerId
    LEFT JOIN sec.Users u ON u.UserId = cr.AssignedRecruiterUserId
    WHERE (@CustomerId IS NULL OR cr.CustomerId = @CustomerId)
      AND (@f IS NULL OR cr.CreatedAt >= @f) AND (@t IS NULL OR cr.CreatedAt < @t)
    ORDER BY cr.CreatedAt DESC, cr.RequestNo;
END
GO

CREATE OR ALTER PROCEDURE report.usp_Rpt_Submissions @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'Recruiter,Administrator,Customer', @FromDate, @ToDate, 1, @CustomerId OUTPUT;
    DECLARE @f DATETIME2(0) = @FromDate, @t DATETIME2(0) = DATEADD(DAY, 1, @ToDate);
    SELECT cr.RequestNo, cu.Name AS Customer, cr.Title AS Request, c.FirstName + N' ' + c.LastName AS Candidate, s.ProposedBillRate,
           s.Status, s.SubmittedAt, u.DisplayName AS SubmittedBy, d.Decision AS LastDecision, d.DecidedAt
    FROM staff.SubmittedCandidates s
    JOIN staff.CustomerRequisitions cr ON cr.CustomerRequisitionId = s.CustomerRequisitionId
    JOIN cand.Candidates c ON c.CandidateId = s.CandidateId
    JOIN org.Customers cu ON cu.CustomerId = s.CustomerId
    LEFT JOIN sec.Users u ON u.UserId = s.SubmittedByUserId
    OUTER APPLY (SELECT TOP (1) x.Decision, x.DecidedAt FROM staff.CustomerCandidateDecisions x WHERE x.SubmissionId = s.SubmissionId ORDER BY x.DecidedAt DESC, x.DecisionId DESC) d
    WHERE (@CustomerId IS NULL OR s.CustomerId = @CustomerId)
      AND (@f IS NULL OR s.SubmittedAt >= @f) AND (@t IS NULL OR s.SubmittedAt < @t)
    ORDER BY s.SubmittedAt DESC;
END
GO

CREATE OR ALTER PROCEDURE report.usp_Rpt_Placements @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'Recruiter,Administrator,Customer', @FromDate, @ToDate, 1, @CustomerId OUTPUT;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @p TABLE (PlacementDate DATE, ContractNo NVARCHAR(30), Customer NVARCHAR(200), Contractor NVARCHAR(201), Role NVARCHAR(150),
                      StartDate DATE, EndDate DATE, ContractStatus VARCHAR(12), BillRate DECIMAL(12,2), PayRate DECIMAL(12,2), Currency CHAR(3));
    INSERT @p
    SELECT pl.PlacementDate, ct.ContractNo, cu.Name, c.FirstName + N' ' + c.LastName, asg.RoleTitle, ct.StartDate, ct.EndDate, ct.Status, r.BillRate, r.PayRate, r.Currency
    FROM staff.Placements pl
    JOIN org.Customers cu ON cu.CustomerId = pl.CustomerId
    JOIN staff.Contractors k ON k.ContractorId = pl.ContractorId
    JOIN cand.Candidates c ON c.CandidateId = k.CandidateId
    LEFT JOIN staff.Contracts ct ON ct.PlacementId = pl.PlacementId
    OUTER APPLY (SELECT TOP (1) a.RoleTitle FROM staff.Assignments a WHERE a.ContractId = ct.ContractId ORDER BY a.AssignmentId) asg
    -- the rate in force today, otherwise the most recent one
    OUTER APPLY (SELECT TOP (1) x.BillRate, x.PayRate, x.Currency FROM staff.ContractRates x WHERE x.ContractId = ct.ContractId
                 ORDER BY CASE WHEN x.EffectiveFrom <= @today AND (x.EffectiveTo IS NULL OR x.EffectiveTo >= @today) THEN 0 ELSE 1 END, x.EffectiveFrom DESC) r
    WHERE pl.Status <> 'Cancelled' AND (@CustomerId IS NULL OR pl.CustomerId = @CustomerId)
      AND (@FromDate IS NULL OR pl.PlacementDate >= @FromDate) AND (@ToDate IS NULL OR pl.PlacementDate <= @ToDate);

    IF sec.fn_IsStaff(@ActorUserId) = 1
        SELECT PlacementDate, ContractNo, Customer, Contractor, Role, StartDate, EndDate, ContractStatus, BillRate, PayRate,
               CAST(CASE WHEN BillRate > 0 THEN 100.0 * (BillRate - PayRate) / BillRate END AS DECIMAL(5,1)) AS MarginPct
        FROM @p ORDER BY PlacementDate DESC, ContractNo;
    ELSE   -- a customer sees its price, never the contractor's pay or the margin
        SELECT PlacementDate, ContractNo, Customer, Contractor, Role, StartDate, EndDate, ContractStatus, BillRate
        FROM @p ORDER BY PlacementDate DESC, ContractNo;
END
GO

CREATE OR ALTER PROCEDURE report.usp_Rpt_ActiveContractors @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'Recruiter,Administrator,Customer', NULL, NULL, 1, @CustomerId OUTPUT;
    SELECT v.ContractorNo, v.ContractorName AS Contractor, v.CustomerName AS Customer, v.RoleTitle AS Role, v.ContractNo,
           v.StartDate, v.EndDate, v.ContractStatus, v.BillRate
    FROM report.vw_ActiveContractors v
    WHERE (@CustomerId IS NULL OR v.CustomerId = @CustomerId)
    ORDER BY v.CustomerName, v.ContractorNo;
END
GO

CREATE OR ALTER PROCEDURE report.usp_Rpt_ExpiringContracts @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'Recruiter,Administrator,Customer', NULL, NULL, 1, @CustomerId OUTPUT;
    SET @Days = ISNULL(@Days, 30);
    IF @Days NOT BETWEEN 1 AND 365 THROW 50001, N'Days must be between 1 and 365.', 1;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    SELECT ct.ContractNo, cu.Name AS Customer, k.ContractorNo, c.FirstName + N' ' + c.LastName AS Contractor,
           (SELECT TOP (1) a.RoleTitle FROM staff.Assignments a WHERE a.ContractId = ct.ContractId ORDER BY a.AssignmentId) AS Role,
           ct.StartDate, ct.EndDate, ct.Status, DATEDIFF(DAY, @today, ct.EndDate) AS DaysToExpiry
    FROM staff.Contracts ct
    JOIN staff.Placements pl ON pl.PlacementId = ct.PlacementId
    JOIN staff.Contractors k ON k.ContractorId = pl.ContractorId
    JOIN cand.Candidates c ON c.CandidateId = k.CandidateId
    JOIN org.Customers cu ON cu.CustomerId = ct.CustomerId
    WHERE ct.Status IN ('Active', 'Expiring') AND ct.EndDate <= DATEADD(DAY, @Days, @today)
      AND (@CustomerId IS NULL OR ct.CustomerId = @CustomerId)
    ORDER BY ct.EndDate, ct.ContractNo;
END
GO

CREATE OR ALTER PROCEDURE report.usp_Rpt_PendingTimesheets @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'Recruiter,Administrator,Customer', @FromDate, @ToDate, 1, @CustomerId OUTPUT;
    SELECT v.CustomerName AS Customer, v.ContractorNo, v.ContractorName AS Contractor, v.RoleTitle AS Role, v.WeekStartDate, v.TotalHours,
           v.SubmittedAt, v.DaysWaiting
    FROM report.vw_PendingTimesheets v
    WHERE (@CustomerId IS NULL OR v.CustomerId = @CustomerId)
      AND (@FromDate IS NULL OR v.WeekStartDate >= @FromDate) AND (@ToDate IS NULL OR v.WeekStartDate <= @ToDate)
    ORDER BY v.SubmittedAt, v.CustomerName;
END
GO

CREATE OR ALTER PROCEDURE report.usp_Rpt_CustomerInvoices @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'Recruiter,Administrator,Customer', @FromDate, @ToDate, 1, @CustomerId OUTPUT;
    DECLARE @staff BIT = sec.fn_IsStaff(@ActorUserId);
    SELECT v.InvoiceNo, v.CustomerName AS Customer, v.PeriodStart, v.PeriodEnd, v.IssueDate, v.DueDate, v.Status,
           v.Total, v.AmountPaid, v.Balance, v.DaysOverdue
    FROM report.vw_CustomerInvoices v
    WHERE (@CustomerId IS NULL OR v.CustomerId = @CustomerId)
      AND (@staff = 1 OR v.Status <> 'Draft')                          -- customers never see invoices that were not issued
      AND (@FromDate IS NULL OR COALESCE(v.IssueDate, v.PeriodEnd) >= @FromDate) AND (@ToDate IS NULL OR COALESCE(v.IssueDate, v.PeriodEnd) <= @ToDate)
    ORDER BY COALESCE(v.IssueDate, v.PeriodEnd) DESC, v.InvoiceNo;
END
GO

CREATE OR ALTER PROCEDURE report.usp_Rpt_OutstandingPayments @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'Recruiter,Administrator,Customer', NULL, NULL, 1, @CustomerId OUTPUT;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    -- same population as bill.fn_CustomerOutstandingBalance: issued and partly paid invoices
    SELECT cu.Name AS Customer, COUNT(*) AS OpenInvoices, SUM(v.Balance) AS Outstanding,
           SUM(CASE WHEN v.DueDate >= @today THEN v.Balance ELSE 0 END) AS NotYetDue,
           SUM(CASE WHEN DATEDIFF(DAY, v.DueDate, @today) BETWEEN 1 AND 30 THEN v.Balance ELSE 0 END) AS Overdue1To30Days,
           SUM(CASE WHEN DATEDIFF(DAY, v.DueDate, @today) BETWEEN 31 AND 60 THEN v.Balance ELSE 0 END) AS Overdue31To60Days,
           SUM(CASE WHEN DATEDIFF(DAY, v.DueDate, @today) BETWEEN 61 AND 90 THEN v.Balance ELSE 0 END) AS Overdue61To90Days,
           SUM(CASE WHEN DATEDIFF(DAY, v.DueDate, @today) > 90 THEN v.Balance ELSE 0 END) AS OverdueOver90Days,
           MIN(v.DueDate) AS OldestDueDate
    FROM report.vw_CustomerInvoices v
    JOIN org.Customers cu ON cu.CustomerId = v.CustomerId
    WHERE v.Status IN ('Issued', 'PartiallyPaid') AND (@CustomerId IS NULL OR v.CustomerId = @CustomerId)
    GROUP BY cu.CustomerId, cu.Name
    ORDER BY Outstanding DESC, cu.Name;
END
GO

/* ============================== HR (HR Manager, Administrator) ============================== */
CREATE OR ALTER PROCEDURE report.usp_Rpt_Onboarding @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'HRManager,Administrator', @FromDate, @ToDate, 0, @CustomerId OUTPUT;
    DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    SELECT e.EmployeeNo, c.FirstName + N' ' + c.LastName AS Employee, d.Name AS Department, e.JobTitle, e.StartDate, e.Status,
           t.Done AS TasksDone, t.Total AS TasksTotal,
           CAST(CASE WHEN t.Total = 0 THEN 0 ELSE 100.0 * t.Done / t.Total END AS DECIMAL(5,1)) AS CompletePct,
           t.Overdue AS OverdueTasks, nt.TaskName AS NextTask, nt.DueDate AS NextDue
    FROM hr.Employees e
    JOIN cand.Candidates c ON c.CandidateId = e.CandidateId
    JOIN org.Departments d ON d.DepartmentId = e.DepartmentId
    OUTER APPLY (SELECT COUNT(*) AS Total,
                        COUNT(CASE WHEN o.Status IN ('Completed', 'Waived') THEN 1 END) AS Done,
                        COUNT(CASE WHEN o.Status NOT IN ('Completed', 'Waived') AND o.DueDate < @today THEN 1 END) AS Overdue
                 FROM hr.EmployeeOnboarding o WHERE o.EmployeeId = e.EmployeeId) t
    OUTER APPLY (SELECT TOP (1) o.TaskName, o.DueDate FROM hr.EmployeeOnboarding o
                 WHERE o.EmployeeId = e.EmployeeId AND o.Status NOT IN ('Completed', 'Waived') ORDER BY o.DueDate, o.OnboardingId) nt
    WHERE e.Status <> 'Terminated'
      AND (@FromDate IS NULL OR e.StartDate >= @FromDate) AND (@ToDate IS NULL OR e.StartDate <= @ToDate)
    ORDER BY CASE WHEN t.Done < t.Total THEN 0 ELSE 1 END, e.StartDate DESC;
END
GO

CREATE OR ALTER PROCEDURE report.usp_Rpt_DepartmentHiring @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'HRManager,Administrator', @FromDate, @ToDate, 0, @CustomerId OUTPUT;
    DECLARE @f DATETIME2(0) = @FromDate, @t DATETIME2(0) = DATEADD(DAY, 1, @ToDate);
    SELECT d.Name AS Department,
           (SELECT COUNT(*) FROM hr.EmployeeRequisitions r WHERE r.DepartmentId = d.DepartmentId AND (@f IS NULL OR r.CreatedAt >= @f) AND (@t IS NULL OR r.CreatedAt < @t)) AS HiringRequests,
           (SELECT ISNULL(SUM(r.Headcount), 0) FROM hr.EmployeeRequisitions r WHERE r.DepartmentId = d.DepartmentId AND r.Status = 'Approved'
             AND (@f IS NULL OR r.CreatedAt >= @f) AND (@t IS NULL OR r.CreatedAt < @t)) AS ApprovedPositions,
           (SELECT COUNT(*) FROM rec.JobRequisitions j WHERE j.DepartmentId = d.DepartmentId AND j.Status IN ('Open', 'OnHold')) AS OpenJobs,
           (SELECT COUNT(*) FROM cand.JobApplications a JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId JOIN rec.JobRequisitions j ON j.JobRequisitionId = p.JobRequisitionId
             WHERE j.DepartmentId = d.DepartmentId AND (@f IS NULL OR a.AppliedAt >= @f) AND (@t IS NULL OR a.AppliedAt < @t)) AS Applications,
           h.Hires, h.AvgDaysToHire,
           (SELECT COUNT(*) FROM hr.Employees e WHERE e.DepartmentId = d.DepartmentId AND e.Status IN ('Onboarding', 'Active', 'OnLeave')) AS Headcount
    FROM org.Departments d
    OUTER APPLY (SELECT COUNT(*) AS Hires, CAST(AVG(CAST(DATEDIFF(DAY, a.AppliedAt, hh.HiredAt) AS DECIMAL(9,2))) AS DECIMAL(9,1)) AS AvgDaysToHire
                 FROM cand.JobApplications a
                 CROSS APPLY (SELECT MIN(x.ChangedAt) AS HiredAt FROM cand.ApplicationStatusHistory x WHERE x.ApplicationId = a.ApplicationId AND x.NewStatus = 'Hired') hh
                 JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId JOIN rec.JobRequisitions j ON j.JobRequisitionId = p.JobRequisitionId
                 WHERE j.DepartmentId = d.DepartmentId AND a.Status = 'Hired' AND hh.HiredAt IS NOT NULL
                   AND (@f IS NULL OR hh.HiredAt >= @f) AND (@t IS NULL OR hh.HiredAt < @t)) h
    WHERE d.IsActive = 1 OR h.Hires > 0
    ORDER BY h.Hires DESC, d.Name;
END
GO

CREATE OR ALTER PROCEDURE report.usp_Rpt_RequisitionStatus @ActorUserId INT, @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC report.usp_ReportScope @ActorUserId, N'HRManager,Administrator', @FromDate, @ToDate, 0, @CustomerId OUTPUT;
    DECLARE @f DATETIME2(0) = @FromDate, @t DATETIME2(0) = DATEADD(DAY, 1, @ToDate);
    -- "approved and pending" hiring requests; a submitted request is waiting for an HR decision
    SELECT r.RequisitionNo, r.Title, d.Name AS Department, r.Headcount, CASE r.Status WHEN 'Submitted' THEN 'Pending' ELSE r.Status END AS Status,
           rq.DisplayName AS RequestedBy, r.SubmittedAt, ap.DecidedBy, ap.DecidedAt,
           CASE WHEN r.Status = 'Submitted' THEN DATEDIFF(DAY, r.SubmittedAt, SYSUTCDATETIME()) END AS DaysWaiting,
           (SELECT COUNT(*) FROM rec.JobRequisitions j WHERE j.EmployeeRequisitionId = r.EmployeeRequisitionId) AS JobsCreated,
           (SELECT COUNT(*) FROM cand.JobApplications a JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId JOIN rec.JobRequisitions j ON j.JobRequisitionId = p.JobRequisitionId
             WHERE j.EmployeeRequisitionId = r.EmployeeRequisitionId AND a.Status = 'Hired') AS Hired
    FROM hr.EmployeeRequisitions r
    JOIN org.Departments d ON d.DepartmentId = r.DepartmentId
    LEFT JOIN sec.Users rq ON rq.UserId = r.RequestedByUserId
    OUTER APPLY (SELECT TOP (1) u.DisplayName AS DecidedBy, h.DecidedAt FROM hr.HiringApprovals h JOIN sec.Users u ON u.UserId = h.ApproverUserId
                 WHERE h.EmployeeRequisitionId = r.EmployeeRequisitionId ORDER BY h.DecidedAt DESC, h.HiringApprovalId DESC) ap
    WHERE r.Status IN ('Submitted', 'Approved')
      AND (@f IS NULL OR r.CreatedAt >= @f) AND (@t IS NULL OR r.CreatedAt < @t)
    ORDER BY CASE r.Status WHEN 'Submitted' THEN 0 ELSE 1 END, r.SubmittedAt, r.RequisitionNo;
END
GO

/* ============================== catalog ============================== */
MERGE report.ReportDefinitions AS t
USING (VALUES
 ('open-requisitions',     'Recruitment', N'Open requisitions',             N'Jobs that are open now: applications received, in progress and hired, and positions still to fill.', 'usp_Rpt_OpenRequisitions', N'Recruiter,HRManager,Administrator', N'Date the job was opened', 0, 0, 'Title', 'Applications', 'value', 10),
 ('applications-by-status','Recruitment', N'Applications by status',        N'How many applications are at each stage, with each stage''s share.',                                  'usp_Rpt_ApplicationsByStatus', N'Recruiter,HRManager,Administrator', N'Application date', 0, 0, 'Status', 'Applications', 'value', 20),
 ('pipeline',              'Recruitment', N'Recruitment pipeline',          N'For every job, how many of its applications are at each stage.',                                       'usp_Rpt_Pipeline', N'Recruiter,HRManager,Administrator', N'Application date', 0, 0, 'Title', 'Total', 'value', 30),
 ('sourcing',              'Recruitment', N'Candidate sourcing',            N'Where applications come from, and how many of them are interviewed and hired.',                        'usp_Rpt_Sourcing', N'Recruiter,HRManager,Administrator', N'Application date', 0, 0, 'Source', 'Applications', 'value', 40),
 ('interview-conversion',  'Recruitment', N'Interview conversion',          N'Per job: interviews held, feedback, and how many interviewed candidates reached an offer.',            'usp_Rpt_InterviewConversion', N'Recruiter,HRManager,Administrator', N'Interview date', 0, 0, 'Title', 'ConversionPct', 'value', 50),
 ('offer-acceptance',      'Recruitment', N'Offer acceptance',              N'Offers per month and how they ended: accepted, declined, expired or still open.',                       'usp_Rpt_OfferAcceptance', N'Recruiter,HRManager,Administrator', N'Date the offer was created', 0, 0, 'Month', 'Accepted', 'value', 60),
 ('time-to-hire',          'Recruitment', N'Time to hire',                  N'Every hire with the days from application to being hired.',                                              'usp_Rpt_TimeToHire', N'Recruiter,HRManager,Administrator', N'Date hired', 0, 0, 'Candidate', 'DaysToHire', 'value', 70),
 ('recruiter-performance', 'Recruitment', N'Recruiter performance',         N'Per recruiter: applications, interviews, offers and hires on their jobs, plus staffing submissions and placements.', 'usp_Rpt_RecruiterPerformance', N'Recruiter,HRManager,Administrator', N'Date of each activity', 0, 0, 'Recruiter', 'Hires', 'value', 80),
 ('staffing-requests',     'Staffing',    N'Customer staffing requests',    N'Staffing requests with their candidates submitted, shortlisted, selected and placed.',                'usp_Rpt_StaffingRequests', N'Recruiter,Administrator,Customer', N'Date the request was raised', 0, 1, 'Status', NULL, 'count', 110),
 ('submissions',           'Staffing',    N'Candidate submissions',         N'Every candidate submitted to a staffing request, with the customer''s latest decision.',                'usp_Rpt_Submissions', N'Recruiter,Administrator,Customer', N'Submission date', 0, 1, 'Status', NULL, 'count', 120),
 ('placements',            'Staffing',    N'Placements',                    N'Contractors placed with customers and their contract. Customers see their bill rate only.',            'usp_Rpt_Placements', N'Recruiter,Administrator,Customer', N'Placement date', 0, 1, 'Customer', NULL, 'count', 130),
 ('active-contractors',    'Staffing',    N'Active contractors',            N'Contractors working now, with their assignment and bill rate.',                                         'usp_Rpt_ActiveContractors', N'Recruiter,Administrator,Customer', NULL, 0, 1, 'Customer', NULL, 'count', 140),
 ('expiring-contracts',    'Staffing',    N'Expiring contracts',            N'Active contracts that end within the chosen number of days (default 30).',                             'usp_Rpt_ExpiringContracts', N'Recruiter,Administrator,Customer', NULL, 1, 1, 'ContractNo', 'DaysToExpiry', 'value', 150),
 ('pending-timesheets',    'Staffing',    N'Pending timesheets',            N'Timesheets submitted and waiting for the customer''s approval.',                                       'usp_Rpt_PendingTimesheets', N'Recruiter,Administrator,Customer', N'Week start date', 0, 1, 'Customer', NULL, 'count', 160),
 ('customer-invoices',     'Staffing',    N'Customer invoices',             N'Invoices with amounts paid, balance and days overdue. Customers see issued invoices only.',            'usp_Rpt_CustomerInvoices', N'Recruiter,Administrator,Customer', N'Issue date (period end for drafts)', 0, 1, 'Customer', 'Total', 'sum', 170),
 ('outstanding-payments',  'Staffing',    N'Outstanding payments',          N'What each customer still owes on issued invoices, by how long it is overdue.',                         'usp_Rpt_OutstandingPayments', N'Recruiter,Administrator,Customer', NULL, 0, 1, 'Customer', 'Outstanding', 'value', 180),
 ('onboarding',            'HR',          N'Employee onboarding',           N'New employees and how far their onboarding checklist is, with overdue tasks and the next task.',      'usp_Rpt_Onboarding', N'HRManager,Administrator', N'Employee start date', 0, 0, 'Employee', 'CompletePct', 'value', 210),
 ('department-hiring',     'HR',          N'Department hiring',             N'Per department: hiring requests, approved positions, open jobs, applications, hires, time to hire and headcount.', 'usp_Rpt_DepartmentHiring', N'HRManager,Administrator', N'Date of each activity', 0, 0, 'Department', 'Hires', 'value', 220),
 ('requisition-status',    'HR',          N'Approved and pending requisitions', N'Hiring requests waiting for a decision or approved, with who decided and what was hired from them.', 'usp_Rpt_RequisitionStatus', N'HRManager,Administrator', N'Date the request was created', 0, 0, 'Status', NULL, 'count', 230)
) AS s (ReportCode, Category, Title, Description, ProcedureName, Roles, DateFilter, UsesDays, CustomerScoped, ChartLabel, ChartValue, ChartAggregate, SortOrder)
ON t.ReportCode = s.ReportCode
WHEN MATCHED THEN UPDATE SET Category = s.Category, Title = s.Title, Description = s.Description, ProcedureName = s.ProcedureName, Roles = s.Roles,
     DateFilter = s.DateFilter, UsesDays = s.UsesDays, CustomerScoped = s.CustomerScoped, ChartLabel = s.ChartLabel, ChartValue = s.ChartValue,
     ChartAggregate = s.ChartAggregate, SortOrder = s.SortOrder
WHEN NOT MATCHED BY TARGET THEN INSERT (ReportCode, Category, Title, Description, ProcedureName, Roles, DateFilter, UsesDays, CustomerScoped, ChartLabel, ChartValue, ChartAggregate, SortOrder)
     VALUES (s.ReportCode, s.Category, s.Title, s.Description, s.ProcedureName, s.Roles, s.DateFilter, s.UsesDays, s.CustomerScoped, s.ChartLabel, s.ChartValue, s.ChartAggregate, s.SortOrder)
WHEN NOT MATCHED BY SOURCE THEN DELETE;
GO

/* ============================== entry points ============================== */
-- The reports the caller may run (catalog order).
CREATE OR ALTER PROCEDURE report.usp_ListReports @ActorUserId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Contractor,Customer,Recruiter,HRManager,Administrator';
    SELECT d.ReportCode, d.Category, d.Title, d.Description, d.DateFilter, d.UsesDays, d.CustomerScoped,
           CAST(CASE WHEN d.CustomerScoped = 1 AND sec.fn_IsStaff(@ActorUserId) = 1 THEN 1 ELSE 0 END AS BIT) AS CanFilterCustomer,
           d.ChartLabel, d.ChartValue, d.ChartAggregate
    FROM report.ReportDefinitions d
    WHERE EXISTS (SELECT 1 FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId
                  WHERE ur.UserId = @ActorUserId AND CHARINDEX(N',' + r.RoleName + N',', N',' + d.Roles + N',') > 0)
    ORDER BY d.SortOrder;
END
GO

-- Runs one report for the caller: unknown code = 50004, role not allowed = 50005; the report procedure checks again.
CREATE OR ALTER PROCEDURE report.usp_RunReport
    @ActorUserId INT, @ReportCode VARCHAR(40), @FromDate DATE = NULL, @ToDate DATE = NULL, @CustomerId INT = NULL, @Days INT = NULL,
    @Format VARCHAR(10) = 'view'            -- Phase 13: recorded in audit.ReportRuns ('view' = on screen / JSON, 'csv' = exported file)
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Contractor,Customer,Recruiter,HRManager,Administrator';
    IF @Format IS NULL OR @Format NOT IN ('view', 'csv') THROW 50001, N'Format must be view or csv.', 1;
    DECLARE @procName SYSNAME, @roles NVARCHAR(200);
    SELECT @procName = ProcedureName, @roles = Roles FROM report.ReportDefinitions WHERE ReportCode = @ReportCode;
    IF @procName IS NULL THROW 50004, N'Report not found.', 1;
    IF NOT EXISTS (SELECT 1 FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId
                   WHERE ur.UserId = @ActorUserId AND CHARINDEX(N',' + r.RoleName + N',', N',' + @roles + N',') > 0)
        THROW 50005, N'Forbidden: this report is not available to your role.', 1;
    -- the name comes from the catalog (not from the caller) and must be a report procedure of this schema
    IF OBJECT_ID(N'report.' + QUOTENAME(@procName), N'P') IS NULL THROW 50004, N'Report not found.', 1;
    DECLARE @proc NVARCHAR(300) = N'report.' + QUOTENAME(@procName);
    EXEC @proc @ActorUserId = @ActorUserId, @FromDate = @FromDate, @ToDate = @ToDate, @CustomerId = @CustomerId, @Days = @Days;
    -- Phase 13 (KI-043): who looked at which report with which filters. Only runs that returned data are recorded:
    -- refused or invalid runs threw above (and are in the API log).
    INSERT audit.ReportRuns (ReportCode, ActorUserId, OutputFormat, FromDate, ToDate, CustomerId, [Days])
    VALUES (@ReportCode, @ActorUserId, @Format, @FromDate, @ToDate, @CustomerId, @Days);
END
GO
