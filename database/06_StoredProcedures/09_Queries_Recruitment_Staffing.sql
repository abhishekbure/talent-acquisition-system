/* ============================================================================
   TAMS - 06_StoredProcedures / 09_Queries_Recruitment_Staffing.sql     (Phase 4 read side, part 2)
   Applications, interviews, offers, contractors, contracts, assignments, timesheets, invoices.
   RATE VISIBILITY: staff see PayRate and BillRate, a Customer sees BillRate only, a Contractor sees PayRate only.
   ========================================================================== */
USE TalentAcquisitionDB;
GO

/* ---------------- candidate side ---------------- */
CREATE OR ALTER PROCEDURE cand.usp_ListMyApplications @ActorUserId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate';
    DECLARE @cid INT = cand.fn_CandidateIdForUser(@ActorUserId);
    IF @cid IS NULL THROW 50004, N'Candidate profile not found.', 1;
    SELECT a.ApplicationId, a.JobPostingId, jr.JobCode, jr.Title, d.Name AS Department, a.Status, a.AppliedAt, a.UpdatedAt,
           (SELECT MIN(i.StartsAt) FROM cand.Interviews i WHERE i.JobApplicationId = a.ApplicationId AND i.Status IN ('Scheduled', 'Rescheduled') AND i.StartsAt >= SYSUTCDATETIME()) AS NextInterviewAt,
           (SELECT TOP (1) o.OfferId FROM cand.JobOffers o WHERE o.ApplicationId = a.ApplicationId ORDER BY o.OfferId DESC) AS OfferId,
           (SELECT TOP (1) o.Status FROM cand.JobOffers o WHERE o.ApplicationId = a.ApplicationId ORDER BY o.OfferId DESC) AS OfferStatus
    FROM cand.JobApplications a JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId JOIN org.Departments d ON d.DepartmentId = jr.DepartmentId
    WHERE a.CandidateId = @cid ORDER BY a.AppliedAt DESC;
END
GO

-- External opportunities of the logged-in candidate. The customer's name is revealed only once the candidate is in interview / selected.
CREATE OR ALTER PROCEDURE cand.usp_ListMySubmissions @ActorUserId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Contractor';
    DECLARE @cid INT = cand.fn_CandidateIdForUser(@ActorUserId);
    IF @cid IS NULL THROW 50004, N'Candidate profile not found.', 1;
    SELECT s.SubmissionId, cr.Title AS RoleTitle, s.Status, s.SubmittedAt, CASE WHEN s.Status IN ('Interview', 'Selected') THEN cu.Name END AS CustomerName
    FROM staff.SubmittedCandidates s JOIN staff.CustomerRequisitions cr ON cr.CustomerRequisitionId = s.CustomerRequisitionId JOIN org.Customers cu ON cu.CustomerId = s.CustomerId
    WHERE s.CandidateId = @cid AND s.Status <> 'Withdrawn' ORDER BY s.SubmittedAt DESC;
END
GO

CREATE OR ALTER PROCEDURE cand.usp_GetApplication @ActorUserId INT, @ApplicationId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Recruiter,HRManager,Administrator';
    DECLARE @ok BIT = 0;
    IF EXISTS (SELECT 1 FROM cand.JobApplications a JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
               WHERE a.ApplicationId = @ApplicationId AND (a.CandidateId = cand.fn_CandidateIdForUser(@ActorUserId) OR sec.fn_UserHasRole(@ActorUserId, N'HRManager') = 1
                     OR sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 1 OR (sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 1 AND jr.OwnerRecruiterUserId = @ActorUserId)))
        SET @ok = 1;
    IF @ok = 0 THROW 50004, N'Application not found.', 1;
    DECLARE @isStaff BIT = sec.fn_IsStaff(@ActorUserId);
    SELECT a.ApplicationId, a.CandidateId, c.FirstName + N' ' + c.LastName AS CandidateName, CASE WHEN @isStaff = 1 THEN c.Email END AS Email, jr.JobCode, jr.Title, jr.JobRequisitionId, d.Name AS Department,
           a.Status, a.CoverNote, a.AppliedAt, a.RowVer
    FROM cand.JobApplications a JOIN cand.Candidates c ON c.CandidateId = a.CandidateId JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId JOIN org.Departments d ON d.DepartmentId = jr.DepartmentId
    WHERE a.ApplicationId = @ApplicationId;
    SELECT h.OldStatus, h.NewStatus, h.ChangedAt, h.Reason, CASE WHEN @isStaff = 1 THEN u.DisplayName END AS ChangedBy FROM cand.ApplicationStatusHistory h LEFT JOIN sec.Users u ON u.UserId = h.ChangedByUserId WHERE h.ApplicationId = @ApplicationId ORDER BY h.HistoryId;
    SELECT i.InterviewId, i.RoundNo, i.InterviewType, i.StartsAt, i.EndsAt, i.Mode, i.LocationOrLink, i.Status FROM cand.Interviews i WHERE i.JobApplicationId = @ApplicationId ORDER BY i.RoundNo, i.InterviewId;
    SELECT o.OfferId, o.OfferNo, o.Designation, o.OfferedSalary, o.Currency, o.StartDate, o.ExpiresAt, o.Status FROM cand.JobOffers o
    WHERE o.ApplicationId = @ApplicationId AND (@isStaff = 1 OR o.Status IN ('Sent', 'Accepted', 'Declined', 'Expired')) ORDER BY o.OfferId;
END
GO

CREATE OR ALTER PROCEDURE cand.usp_ListApplications @ActorUserId INT, @JobRequisitionId INT = NULL, @Status VARCHAR(12) = NULL, @Q NVARCHAR(100) = NULL, @Page INT = 1, @PageSize INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator';
    IF @Page < 1 SET @Page = 1; IF @PageSize < 1 OR @PageSize > 200 SET @PageSize = 25;
    DECLARE @mineOnly BIT = CASE WHEN sec.fn_UserHasRole(@ActorUserId, N'HRManager') = 0 AND sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0 THEN 1 ELSE 0 END;
    SET @Q = NULLIF(LTRIM(RTRIM(@Q)), N'');
    -- Phase 13 (measured on 300,000 applications): count once, page the keys, then read details and the age only for the
    -- rows of the page. RECOMPILE lets the optimiser drop the filters that were not given (catch-all search).
    DECLARE @total INT;
    SELECT @total = COUNT(*)
    FROM cand.JobApplications a JOIN cand.Candidates c ON c.CandidateId = a.CandidateId JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
    WHERE (@JobRequisitionId IS NULL OR jr.JobRequisitionId = @JobRequisitionId) AND (@Status IS NULL OR a.Status = @Status) AND (@mineOnly = 0 OR jr.OwnerRecruiterUserId = @ActorUserId)
      AND (@Q IS NULL OR c.FirstName LIKE N'%' + @Q + N'%' OR c.LastName LIKE N'%' + @Q + N'%' OR c.Email LIKE N'%' + @Q + N'%')
    OPTION (RECOMPILE);
    WITH pg AS (
        SELECT a.ApplicationId, a.AppliedAt
        FROM cand.JobApplications a JOIN cand.Candidates c ON c.CandidateId = a.CandidateId JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
        WHERE (@JobRequisitionId IS NULL OR jr.JobRequisitionId = @JobRequisitionId) AND (@Status IS NULL OR a.Status = @Status) AND (@mineOnly = 0 OR jr.OwnerRecruiterUserId = @ActorUserId)
          AND (@Q IS NULL OR c.FirstName LIKE N'%' + @Q + N'%' OR c.LastName LIKE N'%' + @Q + N'%' OR c.Email LIKE N'%' + @Q + N'%')
        ORDER BY a.AppliedAt DESC, a.ApplicationId DESC OFFSET (@Page - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY)
    SELECT a.ApplicationId, a.CandidateId, c.FirstName + N' ' + c.LastName AS CandidateName, c.Email, c.TotalExperienceYears, jr.JobRequisitionId, jr.JobCode, jr.Title, a.Status, a.AppliedAt, a.RowVer,
           cand.fn_ApplicationAgeDays(a.ApplicationId) AS AgeDays, @total AS TotalCount
    FROM pg JOIN cand.JobApplications a ON a.ApplicationId = pg.ApplicationId JOIN cand.Candidates c ON c.CandidateId = a.CandidateId
    JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
    ORDER BY pg.AppliedAt DESC, pg.ApplicationId DESC
    OPTION (RECOMPILE);
END
GO

/* ---------------- interviews ---------------- */
CREATE OR ALTER PROCEDURE cand.usp_ListInterviews @ActorUserId INT, @FromDate DATETIME2(0) = NULL, @ToDate DATETIME2(0) = NULL, @Status VARCHAR(12) = NULL, @Top INT = 500
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Contractor,Customer,Recruiter,HRManager,Administrator';
    DECLARE @isCand BIT = CASE WHEN sec.fn_IsStaff(@ActorUserId) = 0 AND sec.fn_UserCustomerId(@ActorUserId) IS NULL THEN 1 ELSE 0 END;
    -- Phase 13: the visibility rules of cand.fn_CanSeeInterview, inlined with the caller's roles worked out once (the scalar
    -- function ran once per interview: 2.3 million reads / 1.5 s for an administrator over 74,000 interviews)
    DECLARE @allSee BIT = CASE WHEN sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 1 OR sec.fn_UserHasRole(@ActorUserId, N'HRManager') = 1 THEN 1 ELSE 0 END,
            @isRec BIT = sec.fn_UserHasRole(@ActorUserId, N'Recruiter'), @myCustomer INT = sec.fn_UserCustomerId(@ActorUserId), @myCandidate INT = cand.fn_CandidateIdForUser(@ActorUserId);
    IF @Top IS NULL OR @Top < 1 OR @Top > 5000 SET @Top = 500;   -- Phase 13: lists are capped (newest first); the API says when more exist
    SELECT TOP (@Top) i.InterviewId, i.StartsAt, i.EndsAt, i.RoundNo, i.InterviewType, i.Mode, i.LocationOrLink, i.Status, i.RowVer,
           CASE WHEN i.JobApplicationId IS NOT NULL THEN 'Internal' ELSE 'External' END AS Opportunity, i.JobApplicationId, i.SubmittedCandidateId, i.CustomerId,
           c.CandidateId, c.FirstName + N' ' + c.LastName AS CandidateName, COALESCE(jr.Title, cr.Title) AS RoleTitle, cu.Name AS CustomerName,
           STUFF((SELECT N', ' + u.DisplayName FROM cand.InterviewPanels ip JOIN sec.Users u ON u.UserId = ip.UserId WHERE ip.InterviewId = i.InterviewId ORDER BY ip.IsLead DESC, u.DisplayName FOR XML PATH(N'')), 1, 2, N'') AS Panel,
           (SELECT COUNT(*) FROM cand.InterviewFeedback f WHERE f.InterviewId = i.InterviewId) AS FeedbackCount
    FROM cand.Interviews i
    LEFT JOIN cand.JobApplications a ON a.ApplicationId = i.JobApplicationId LEFT JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId LEFT JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
    LEFT JOIN staff.SubmittedCandidates s ON s.SubmissionId = i.SubmittedCandidateId LEFT JOIN staff.CustomerRequisitions cr ON cr.CustomerRequisitionId = s.CustomerRequisitionId LEFT JOIN org.Customers cu ON cu.CustomerId = i.CustomerId
    JOIN cand.Candidates c ON c.CandidateId = COALESCE(a.CandidateId, s.CandidateId)
    WHERE (@allSee = 1
           OR (@isRec = 1 AND (i.ScheduledByUserId = @ActorUserId OR jr.OwnerRecruiterUserId = @ActorUserId OR cr.AssignedRecruiterUserId = @ActorUserId
                               OR EXISTS (SELECT 1 FROM cand.InterviewPanels ip WHERE ip.InterviewId = i.InterviewId AND ip.UserId = @ActorUserId)))
           OR (i.CustomerId IS NOT NULL AND i.CustomerId = @myCustomer)
           OR COALESCE(a.CandidateId, s.CandidateId) = @myCandidate)
      AND (@FromDate IS NULL OR i.StartsAt >= @FromDate) AND (@ToDate IS NULL OR i.StartsAt <= @ToDate) AND (@Status IS NULL OR i.Status = @Status)
      AND (@isCand = 0 OR i.CustomerId IS NULL OR i.Status <> 'Cancelled')
    ORDER BY i.StartsAt DESC, i.InterviewId DESC
    OPTION (RECOMPILE);
END
GO

CREATE OR ALTER PROCEDURE cand.usp_GetInterview @ActorUserId INT, @InterviewId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Contractor,Customer,Recruiter,HRManager,Administrator';
    IF cand.fn_CanSeeInterview(@ActorUserId, @InterviewId) = 0 THROW 50004, N'Interview not found.', 1;
    DECLARE @isPanel BIT = CASE WHEN EXISTS (SELECT 1 FROM cand.InterviewPanels WHERE InterviewId = @InterviewId AND UserId = @ActorUserId) THEN 1 ELSE 0 END;
    SELECT i.InterviewId, i.StartsAt, i.EndsAt, i.RoundNo, i.InterviewType, i.Mode, i.LocationOrLink, i.Status, i.Notes, i.RowVer, i.JobApplicationId, i.SubmittedCandidateId, i.CustomerId,
           c.FirstName + N' ' + c.LastName AS CandidateName, COALESCE(jr.Title, cr.Title) AS RoleTitle, @isPanel AS IsPanelMember
    FROM cand.Interviews i LEFT JOIN cand.JobApplications a ON a.ApplicationId = i.JobApplicationId LEFT JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId LEFT JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
    LEFT JOIN staff.SubmittedCandidates s ON s.SubmissionId = i.SubmittedCandidateId LEFT JOIN staff.CustomerRequisitions cr ON cr.CustomerRequisitionId = s.CustomerRequisitionId JOIN cand.Candidates c ON c.CandidateId = COALESCE(a.CandidateId, s.CandidateId)
    WHERE i.InterviewId = @InterviewId;
    SELECT ip.UserId, u.DisplayName, ip.IsLead, CASE WHEN EXISTS (SELECT 1 FROM cand.InterviewFeedback f WHERE f.InterviewId = ip.InterviewId AND f.InterviewerUserId = ip.UserId) THEN 1 ELSE 0 END AS FeedbackGiven
    FROM cand.InterviewPanels ip JOIN sec.Users u ON u.UserId = ip.UserId WHERE ip.InterviewId = @InterviewId ORDER BY ip.IsLead DESC, u.DisplayName;
    -- feedback is internal to the panel / staff / owning customer's panel; the candidate never sees it
    SELECT f.FeedbackId, u.DisplayName AS Interviewer, f.Rating, f.Recommendation, f.Strengths, f.Concerns, f.SubmittedAt
    FROM cand.InterviewFeedback f JOIN sec.Users u ON u.UserId = f.InterviewerUserId
    WHERE f.InterviewId = @InterviewId AND (sec.fn_IsStaff(@ActorUserId) = 1 OR @isPanel = 1) ORDER BY f.SubmittedAt;
END
GO

/* ---------------- offers ---------------- */
CREATE OR ALTER PROCEDURE cand.usp_ListMyOffers @ActorUserId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate';
    DECLARE @cid INT = cand.fn_CandidateIdForUser(@ActorUserId);
    IF @cid IS NULL THROW 50004, N'Candidate profile not found.', 1;
    SELECT o.OfferId, o.OfferNo, o.Designation, o.OfferedSalary, o.Currency, o.StartDate, o.ExpiresAt, o.Status, o.SentAt, o.RespondedAt, jr.Title AS JobTitle,
           DATEDIFF(DAY, SYSUTCDATETIME(), o.ExpiresAt) AS DaysToExpiry
    FROM cand.JobOffers o JOIN cand.JobApplications a ON a.ApplicationId = o.ApplicationId JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
    WHERE a.CandidateId = @cid AND o.Status IN ('Sent', 'Accepted', 'Declined', 'Expired') ORDER BY o.OfferId DESC;
END
GO

CREATE OR ALTER PROCEDURE cand.usp_ListOffers @ActorUserId INT, @Status VARCHAR(16) = NULL, @Top INT = 500
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator';
    DECLARE @mineOnly BIT = CASE WHEN sec.fn_UserHasRole(@ActorUserId, N'HRManager') = 0 AND sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0 THEN 1 ELSE 0 END;
    IF @Top IS NULL OR @Top < 1 OR @Top > 5000 SET @Top = 500;   -- Phase 13: lists are capped (newest first); the API says when more exist
    SELECT TOP (@Top) o.OfferId, o.OfferNo, o.ApplicationId, c.FirstName + N' ' + c.LastName AS CandidateName, o.Designation, o.OfferedSalary, o.Currency, o.StartDate, o.ExpiresAt, o.Status, u.DisplayName AS CreatedBy, o.CreatedByUserId, o.SentAt, o.RespondedAt,
           DATEDIFF(DAY, SYSUTCDATETIME(), o.ExpiresAt) AS DaysToExpiry
    FROM cand.JobOffers o JOIN cand.JobApplications a ON a.ApplicationId = o.ApplicationId JOIN cand.Candidates c ON c.CandidateId = a.CandidateId JOIN sec.Users u ON u.UserId = o.CreatedByUserId
    JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
    WHERE (@Status IS NULL OR o.Status = @Status) AND (@mineOnly = 0 OR o.CreatedByUserId = @ActorUserId OR jr.OwnerRecruiterUserId = @ActorUserId)
    ORDER BY o.OfferId DESC;
END
GO

/* ---------------- staffing: contractors, contracts, assignments ---------------- */
CREATE OR ALTER PROCEDURE staff.usp_ListContractors @ActorUserId INT, @Status VARCHAR(10) = NULL, @Q NVARCHAR(100) = NULL, @Top INT = 500
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Customer,Recruiter,Administrator';
    DECLARE @staff BIT = CASE WHEN sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 1 OR sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 1 THEN 1 ELSE 0 END, @mine INT = sec.fn_UserCustomerId(@ActorUserId);
    IF @staff = 0 AND @mine IS NULL THROW 50005, N'This login is not linked to a customer.', 1;
    IF @Top IS NULL OR @Top < 1 OR @Top > 5000 SET @Top = 500;   -- Phase 13: lists are capped (newest first); the API says when more exist
    SELECT TOP (@Top) k.ContractorId, k.ContractorNo, c.FirstName + N' ' + c.LastName AS ContractorName, CASE WHEN @staff = 1 THEN c.Email END AS Email, k.Status,
           (SELECT COUNT(*) FROM staff.Assignments a WHERE a.ContractorId = k.ContractorId AND a.Status = 'Active' AND (@staff = 1 OR a.CustomerId = @mine)) AS ActiveAssignments,
           (SELECT TOP (1) cu.Name FROM staff.Assignments a JOIN org.Customers cu ON cu.CustomerId = a.CustomerId WHERE a.ContractorId = k.ContractorId AND a.Status = 'Active' AND (@staff = 1 OR a.CustomerId = @mine) ORDER BY a.AssignmentId DESC) AS CurrentCustomer
    FROM staff.Contractors k JOIN cand.Candidates c ON c.CandidateId = k.CandidateId
    WHERE (@Status IS NULL OR k.Status = @Status) AND (@Q IS NULL OR c.FirstName LIKE N'%' + @Q + N'%' OR c.LastName LIKE N'%' + @Q + N'%' OR k.ContractorNo LIKE N'%' + @Q + N'%')
      AND (@staff = 1 OR EXISTS (SELECT 1 FROM staff.Assignments a WHERE a.ContractorId = k.ContractorId AND a.CustomerId = @mine))      -- customers see only contractors placed with them
    ORDER BY k.ContractorId DESC;
END
GO

CREATE OR ALTER PROCEDURE staff.usp_ListContracts @ActorUserId INT, @Status VARCHAR(12) = NULL, @CustomerId INT = NULL, @Top INT = 500
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Contractor,Customer,Recruiter,Administrator';
    DECLARE @staff BIT = CASE WHEN sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 1 OR sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 1 THEN 1 ELSE 0 END;
    DECLARE @mine INT = sec.fn_UserCustomerId(@ActorUserId), @ctr INT = staff.fn_ContractorIdForUser(@ActorUserId);
    IF @staff = 0
    BEGIN
        IF @mine IS NOT NULL AND @CustomerId IS NOT NULL AND @CustomerId <> @mine THROW 50004, N'Customer not found.', 1;
        IF @mine IS NULL AND @ctr IS NULL THROW 50005, N'This login is not linked to a customer or contractor.', 1;
        IF @mine IS NOT NULL SET @CustomerId = @mine;
    END
    IF @Top IS NULL OR @Top < 1 OR @Top > 5000 SET @Top = 500;   -- Phase 13: lists are capped (newest first); the API says when more exist
    SELECT TOP (@Top) ct.ContractId, ct.ContractNo, ct.CustomerId, cu.Name AS CustomerName, k.ContractorId, k.ContractorNo, c.FirstName + N' ' + c.LastName AS ContractorName, ct.StartDate, ct.EndDate, ct.Status,
           DATEDIFF(DAY, CAST(SYSUTCDATETIME() AS DATE), ct.EndDate) AS DaysToExpiry, ct.RowVer,
           CASE WHEN @staff = 1 OR @ctr IS NOT NULL THEN r.PayRate END AS PayRate, CASE WHEN @staff = 1 OR @mine IS NOT NULL THEN r.BillRate END AS BillRate, r.Currency
    FROM staff.Contracts ct JOIN staff.Placements pl ON pl.PlacementId = ct.PlacementId JOIN staff.Contractors k ON k.ContractorId = pl.ContractorId JOIN cand.Candidates c ON c.CandidateId = k.CandidateId JOIN org.Customers cu ON cu.CustomerId = ct.CustomerId
    OUTER APPLY staff.fn_EffectiveRate(ct.ContractId, CAST(SYSUTCDATETIME() AS DATE)) r
    WHERE (@Status IS NULL OR ct.Status = @Status) AND (@CustomerId IS NULL OR ct.CustomerId = @CustomerId) AND (@staff = 1 OR @mine IS NOT NULL OR k.ContractorId = @ctr)
    ORDER BY ct.ContractId DESC;
END
GO

CREATE OR ALTER PROCEDURE staff.usp_GetContract @ActorUserId INT, @ContractId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Contractor,Customer,Recruiter,Administrator';
    DECLARE @staff BIT = CASE WHEN sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 1 OR sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 1 THEN 1 ELSE 0 END;
    DECLARE @mine INT = sec.fn_UserCustomerId(@ActorUserId), @ctr INT = staff.fn_ContractorIdForUser(@ActorUserId);
    IF NOT EXISTS (SELECT 1 FROM staff.Contracts ct JOIN staff.Placements pl ON pl.PlacementId = ct.PlacementId
                   WHERE ct.ContractId = @ContractId AND (@staff = 1 OR ct.CustomerId = @mine OR pl.ContractorId = @ctr)) THROW 50004, N'Contract not found.', 1;
    SELECT ct.ContractId, ct.ContractNo, ct.CustomerId, cu.Name AS CustomerName, k.ContractorId, k.ContractorNo, c.FirstName + N' ' + c.LastName AS ContractorName, ct.StartDate, ct.EndDate, ct.Status, ct.Terms, ct.RowVer, staff.fn_ContractDurationDays(ct.ContractId) AS DurationDays
    FROM staff.Contracts ct JOIN staff.Placements pl ON pl.PlacementId = ct.PlacementId JOIN staff.Contractors k ON k.ContractorId = pl.ContractorId JOIN cand.Candidates c ON c.CandidateId = k.CandidateId JOIN org.Customers cu ON cu.CustomerId = ct.CustomerId
    WHERE ct.ContractId = @ContractId;
    SELECT r.ContractRateId, CASE WHEN @staff = 1 OR @ctr IS NOT NULL THEN r.PayRate END AS PayRate, CASE WHEN @staff = 1 OR @mine IS NOT NULL THEN r.BillRate END AS BillRate,
           r.OvertimePayMultiplier, r.OvertimeBillMultiplier, r.Currency, r.EffectiveFrom, r.EffectiveTo
    FROM staff.ContractRates r WHERE r.ContractId = @ContractId ORDER BY r.EffectiveFrom;
    SELECT a.AssignmentId, a.RoleTitle, a.SiteLocation, a.HoursPerWeek, a.StartDate, a.EndDate, a.Status FROM staff.Assignments a WHERE a.ContractId = @ContractId ORDER BY a.AssignmentId;
    SELECT e.PreviousEndDate, e.NewEndDate, e.Reason, e.CreatedAt FROM staff.ContractExtensions e WHERE e.ContractId = @ContractId ORDER BY e.ExtensionId;
END
GO

CREATE OR ALTER PROCEDURE staff.usp_ListAssignments @ActorUserId INT, @Status VARCHAR(10) = NULL, @Top INT = 500
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Contractor,Customer,Recruiter,Administrator';
    DECLARE @staff BIT = CASE WHEN sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 1 OR sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 1 THEN 1 ELSE 0 END;
    DECLARE @mine INT = sec.fn_UserCustomerId(@ActorUserId), @ctr INT = staff.fn_ContractorIdForUser(@ActorUserId);
    IF @staff = 0 AND @mine IS NULL AND @ctr IS NULL THROW 50005, N'This login is not linked to a customer or contractor.', 1;
    IF @Top IS NULL OR @Top < 1 OR @Top > 5000 SET @Top = 500;   -- Phase 13: lists are capped (newest first); the API says when more exist
    SELECT TOP (@Top) a.AssignmentId, a.ContractId, ct.ContractNo, a.CustomerId, cu.Name AS CustomerName, a.ContractorId, k.ContractorNo, c.FirstName + N' ' + c.LastName AS ContractorName,
           a.RoleTitle, a.SiteLocation, a.HoursPerWeek, a.StartDate, a.EndDate, a.Status
    FROM staff.Assignments a JOIN staff.Contracts ct ON ct.ContractId = a.ContractId JOIN org.Customers cu ON cu.CustomerId = a.CustomerId JOIN staff.Contractors k ON k.ContractorId = a.ContractorId JOIN cand.Candidates c ON c.CandidateId = k.CandidateId
    WHERE (@Status IS NULL OR a.Status = @Status) AND (@staff = 1 OR a.CustomerId = @mine OR a.ContractorId = @ctr)
    ORDER BY a.AssignmentId DESC;
END
GO

CREATE OR ALTER PROCEDURE staff.usp_GetMyContractor @ActorUserId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Contractor';
    DECLARE @ctr INT = staff.fn_ContractorIdForUser(@ActorUserId);
    IF @ctr IS NULL THROW 50004, N'Contractor profile not found.', 1;
    SELECT k.ContractorId, k.ContractorNo, k.Status, c.FirstName, c.LastName, c.Email, c.Phone FROM staff.Contractors k JOIN cand.Candidates c ON c.CandidateId = k.CandidateId WHERE k.ContractorId = @ctr;
    SELECT a.AssignmentId, a.ContractId, ct.ContractNo, cu.Name AS CustomerName, a.RoleTitle, a.SiteLocation, a.HoursPerWeek, a.StartDate, a.EndDate, a.Status, ct.EndDate AS ContractEnd, r.PayRate, r.Currency
    FROM staff.Assignments a JOIN staff.Contracts ct ON ct.ContractId = a.ContractId JOIN org.Customers cu ON cu.CustomerId = a.CustomerId OUTER APPLY staff.fn_EffectiveRate(a.ContractId, CAST(SYSUTCDATETIME() AS DATE)) r
    WHERE a.ContractorId = @ctr ORDER BY a.AssignmentId DESC;
    SELECT ComplianceId, RecordType, Status, IssuedOn, ExpiresOn, DATEDIFF(DAY, CAST(SYSUTCDATETIME() AS DATE), ExpiresOn) AS DaysToExpiry, Notes, DocumentId FROM staff.ComplianceRecords WHERE ContractorId = @ctr ORDER BY RecordType;
END
GO

CREATE OR ALTER PROCEDURE staff.usp_ListCompliance @ActorUserId INT, @ContractorId INT = NULL, @ExpiringWithinDays INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Contractor,Recruiter,Administrator';
    IF sec.fn_IsStaff(@ActorUserId) = 0 SET @ContractorId = staff.fn_ContractorIdForUser(@ActorUserId);
    SELECT cr.ComplianceId, cr.ContractorId, k.ContractorNo, c.FirstName + N' ' + c.LastName AS ContractorName, cr.RecordType, cr.Status, cr.IssuedOn, cr.ExpiresOn,
           DATEDIFF(DAY, CAST(SYSUTCDATETIME() AS DATE), cr.ExpiresOn) AS DaysToExpiry, cr.DocumentId, cr.Notes
    FROM staff.ComplianceRecords cr JOIN staff.Contractors k ON k.ContractorId = cr.ContractorId JOIN cand.Candidates c ON c.CandidateId = k.CandidateId
    WHERE (@ContractorId IS NULL OR cr.ContractorId = @ContractorId) AND (@ExpiringWithinDays IS NULL OR cr.ExpiresOn <= DATEADD(DAY, @ExpiringWithinDays, CAST(SYSUTCDATETIME() AS DATE)))
    ORDER BY cr.ExpiresOn;
END
GO

/* ---------------- timesheets and invoices ---------------- */
CREATE OR ALTER PROCEDURE [time].usp_ListTimesheets @ActorUserId INT, @Status VARCHAR(10) = NULL, @CustomerId INT = NULL, @ContractorId INT = NULL, @Top INT = 500
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Contractor,Customer,Recruiter,Administrator';
    DECLARE @staff BIT = CASE WHEN sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 1 OR sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 1 THEN 1 ELSE 0 END;
    DECLARE @mine INT = sec.fn_UserCustomerId(@ActorUserId), @ctr INT = staff.fn_ContractorIdForUser(@ActorUserId);
    IF @staff = 0
    BEGIN
        IF @mine IS NOT NULL AND ((@CustomerId IS NOT NULL AND @CustomerId <> @mine)) THROW 50004, N'Customer not found.', 1;
        IF @mine IS NULL AND @ctr IS NULL THROW 50005, N'This login is not linked to a customer or contractor.', 1;
        IF @mine IS NOT NULL SET @CustomerId = @mine; ELSE SET @ContractorId = @ctr;
    END
    IF @Top IS NULL OR @Top < 1 OR @Top > 5000 SET @Top = 500;   -- Phase 13: lists are capped (newest first); the API says when more exist
    SELECT TOP (@Top) t.TimesheetId, t.AssignmentId, t.CustomerId, cu.Name AS CustomerName, t.ContractorId, k.ContractorNo, c.FirstName + N' ' + c.LastName AS ContractorName, a.RoleTitle, t.WeekStartDate, t.Status, t.TotalHours, t.SubmittedAt, t.RowVer
    FROM [time].Timesheets t JOIN staff.Assignments a ON a.AssignmentId = t.AssignmentId JOIN staff.Contractors k ON k.ContractorId = t.ContractorId JOIN cand.Candidates c ON c.CandidateId = k.CandidateId JOIN org.Customers cu ON cu.CustomerId = t.CustomerId
    WHERE (@Status IS NULL OR t.Status = @Status) AND (@CustomerId IS NULL OR t.CustomerId = @CustomerId) AND (@ContractorId IS NULL OR t.ContractorId = @ContractorId)
    ORDER BY t.WeekStartDate DESC, t.TimesheetId DESC;
END
GO

CREATE OR ALTER PROCEDURE [time].usp_GetTimesheet @ActorUserId INT, @TimesheetId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Contractor,Customer,Recruiter,Administrator';
    DECLARE @staff BIT = CASE WHEN sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 1 OR sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 1 THEN 1 ELSE 0 END;
    IF NOT EXISTS (SELECT 1 FROM [time].Timesheets WHERE TimesheetId = @TimesheetId AND (@staff = 1 OR CustomerId = sec.fn_UserCustomerId(@ActorUserId) OR ContractorId = staff.fn_ContractorIdForUser(@ActorUserId)))
        THROW 50004, N'Timesheet not found.', 1;
    SELECT t.TimesheetId, t.AssignmentId, t.CustomerId, cu.Name AS CustomerName, t.ContractorId, c.FirstName + N' ' + c.LastName AS ContractorName, a.RoleTitle, t.WeekStartDate, t.Status, t.TotalHours, t.SubmittedAt, t.RowVer
    FROM [time].Timesheets t JOIN staff.Assignments a ON a.AssignmentId = t.AssignmentId JOIN staff.Contractors k ON k.ContractorId = t.ContractorId JOIN cand.Candidates c ON c.CandidateId = k.CandidateId JOIN org.Customers cu ON cu.CustomerId = t.CustomerId
    WHERE t.TimesheetId = @TimesheetId;
    SELECT e.EntryId, e.WorkDate, e.Hours, e.EntryType, e.IsBillable, e.Notes FROM [time].TimesheetEntries e WHERE e.TimesheetId = @TimesheetId ORDER BY e.WorkDate, e.EntryType;
    SELECT 'Approved' AS Outcome, u.DisplayName AS ByUser, ap.ApprovedAt AS At, ap.Comments AS Detail FROM [time].TimesheetApprovals ap JOIN sec.Users u ON u.UserId = ap.ApprovedByUserId WHERE ap.TimesheetId = @TimesheetId
    UNION ALL SELECT 'Rejected', u.DisplayName, rj.RejectedAt, rj.Reason FROM [time].TimesheetRejections rj JOIN sec.Users u ON u.UserId = rj.RejectedByUserId WHERE rj.TimesheetId = @TimesheetId ORDER BY At;
END
GO

CREATE OR ALTER PROCEDURE bill.usp_GetInvoice @ActorUserId INT, @InvoiceId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Customer,Recruiter,Administrator';
    DECLARE @staff BIT = CASE WHEN sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 1 OR sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 1 THEN 1 ELSE 0 END;
    -- customers see their own invoices once issued; a Draft is internal until the recruiter issues it
    IF NOT EXISTS (SELECT 1 FROM bill.Invoices WHERE InvoiceId = @InvoiceId AND (@staff = 1 OR (CustomerId = sec.fn_UserCustomerId(@ActorUserId) AND Status <> 'Draft'))) THROW 50004, N'Invoice not found.', 1;
    SELECT InvoiceId, InvoiceNo, CustomerId, CustomerName, PeriodStart, PeriodEnd, IssueDate, DueDate, Status, Currency, Subtotal, TaxAmount, Total, AmountPaid, Balance, DaysOverdue FROM report.vw_CustomerInvoices WHERE InvoiceId = @InvoiceId;
    SELECT l.InvoiceLineId, l.Description, l.Hours, l.BillRate, l.LineTotal FROM bill.InvoiceLines l WHERE l.InvoiceId = @InvoiceId ORDER BY l.InvoiceLineId;
    SELECT p.PaymentId, p.Amount, p.PaidOn, p.Method, p.Reference, p.RecordedAt FROM bill.Payments p WHERE p.InvoiceId = @InvoiceId ORDER BY p.PaymentId;
END
GO
