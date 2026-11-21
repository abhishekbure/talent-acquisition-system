/* ============================================================================
   TAMS - 06_StoredProcedures / 05_Staffing_Contracts.sql
   External staffing: customer requests -> submissions -> customer decisions ->
   contractor / placement / contract (pay vs bill rates) / assignment.
   CUSTOMER ISOLATION: a Customer-role caller is resolved to ONE customer from the login, and any id
   that belongs to another customer is answered with 50004 "not found" (never 403), so existence is not revealed.
   ========================================================================== */
USE TalentAcquisitionDB;
GO

-- Queues one notification for every active login of a customer.
CREATE OR ALTER PROCEDURE notify.usp_EnqueueForCustomer
    @CustomerId INT, @TemplateCode VARCHAR(40), @Subject NVARCHAR(300), @Body NVARCHAR(MAX), @DedupeKey NVARCHAR(180),
    @RelatedEntityType VARCHAR(30) = NULL, @RelatedEntityId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @u INT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT UserId FROM org.CustomerUsers WHERE CustomerId = @CustomerId;
    OPEN c; FETCH NEXT FROM c INTO @u;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC notify.usp_Enqueue @TemplateCode, @u, @Subject, @Body, @DedupeKey, @RelatedEntityType, @RelatedEntityId;
        FETCH NEXT FROM c INTO @u;
    END
    CLOSE c; DEALLOCATE c;
END
GO

/* ---------------- customer staffing requests ---------------- */
CREATE OR ALTER PROCEDURE staff.usp_CreateCustomerRequisition
    @ActorUserId INT, @CustomerId INT = NULL, @Title NVARCHAR(200), @Description NVARCHAR(2000) = NULL, @Positions INT = 1,
    @SkillsRequired NVARCHAR(500) = NULL, @StartDate DATE = NULL, @DurationMonths INT = NULL, @MaxBillRate DECIMAL(10,2) = NULL,
    @WorkLocation NVARCHAR(150) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_CreateCustReq; END
        EXEC sec.usp_Authorize @ActorUserId, N'Customer,Recruiter,Administrator';
        DECLARE @isStaff BIT = CASE WHEN sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 1 OR sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 1 THEN 1 ELSE 0 END;
        IF @isStaff = 0
        BEGIN
            DECLARE @mine INT = sec.fn_UserCustomerId(@ActorUserId);
            IF @mine IS NULL THROW 50005, N'This login is not linked to a customer.', 1;
            IF @CustomerId IS NOT NULL AND @CustomerId <> @mine THROW 50004, N'Customer not found.', 1;    -- manipulated CustomerId
            SET @CustomerId = @mine;
        END
        ELSE IF @CustomerId IS NULL THROW 50001, N'CustomerId is required.', 1;
        IF NOT EXISTS (SELECT 1 FROM org.Customers WHERE CustomerId = @CustomerId) THROW 50004, N'Customer not found.', 1;
        IF (SELECT Status FROM org.Customers WHERE CustomerId = @CustomerId) <> 'Active' THROW 50002, N'The customer account is not active.', 1;
        IF LEN(LTRIM(RTRIM(ISNULL(@Title, N'')))) = 0 THROW 50001, N'Title is required.', 1;
        IF ISNULL(@Positions, 0) < 1 THROW 50001, N'Positions must be at least 1.', 1;
        IF @MaxBillRate IS NOT NULL AND @MaxBillRate <= 0 THROW 50001, N'Maximum bill rate must be positive.', 1;
        DECLARE @n INT = NEXT VALUE FOR staff.seq_RequestNo;
        DECLARE @no NVARCHAR(30) = N'CR-' + CAST(YEAR(SYSUTCDATETIME()) AS NVARCHAR(4)) + N'-' + dbo.fn_PadNumber(@n, 3);
        INSERT staff.CustomerRequisitions (RequestNo, CustomerId, Title, Description, Positions, SkillsRequired, StartDate, DurationMonths, MaxBillRate, WorkLocation, Status, CreatedByUserId)
        VALUES (@no, @CustomerId, LTRIM(RTRIM(@Title)), @Description, @Positions, @SkillsRequired, @StartDate, @DurationMonths, @MaxBillRate, @WorkLocation, 'Open', @ActorUserId);
        DECLARE @id INT = SCOPE_IDENTITY();
        DECLARE @mgr INT = (SELECT AccountManagerUserId FROM org.Customers WHERE CustomerId = @CustomerId);
        DECLARE @subj NVARCHAR(300) = N'New staffing request ' + @no + N': ' + @Title;
        EXEC notify.usp_Enqueue 'STAFFING_REQUEST', @mgr, @subj, @subj, N'CRNEW', 'CustomerRequisition', @id;
        IF @own = 1 COMMIT;
        SELECT @id AS CustomerRequisitionId, @no AS RequestNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_CreateCustReq;
        THROW;
    END CATCH
END
GO

-- Recruiter reviews/accepts a request (Open -> InReview) and is assigned to it.
CREATE OR ALTER PROCEDURE staff.usp_AcceptCustomerRequisition @ActorUserId INT, @CustomerRequisitionId INT, @AssignedRecruiterUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_AcceptCustReq; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,Administrator';
        DECLARE @status VARCHAR(12), @assigned INT, @cust INT;
        SELECT @status = Status, @assigned = AssignedRecruiterUserId, @cust = CustomerId FROM staff.CustomerRequisitions WITH (UPDLOCK, HOLDLOCK) WHERE CustomerRequisitionId = @CustomerRequisitionId;
        IF @status IS NULL THROW 50004, N'Staffing request not found.', 1;
        IF @status NOT IN ('Open', 'InReview') THROW 50002, N'Only an Open or InReview request can be accepted or reassigned.', 1;
        IF @assigned IS NOT NULL AND @assigned <> @ActorUserId AND sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0 THROW 50004, N'Staffing request not found.', 1;
        DECLARE @rec INT = ISNULL(@AssignedRecruiterUserId, @ActorUserId);
        IF sec.fn_UserHasRole(@rec, N'Recruiter') = 0 THROW 50001, N'The assignee must be an active Recruiter.', 1;
        UPDATE staff.CustomerRequisitions SET Status = 'InReview', AssignedRecruiterUserId = @rec, UpdatedAt = SYSUTCDATETIME() WHERE CustomerRequisitionId = @CustomerRequisitionId;
        EXEC notify.usp_EnqueueForCustomer @cust, 'STAFFING_ACCEPTED', N'Your staffing request has been accepted and a recruiter is assigned.', N'Your staffing request is now being sourced.', N'CRACCEPT', 'CustomerRequisition', @CustomerRequisitionId;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_AcceptCustReq;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE staff.usp_CancelCustomerRequisition @ActorUserId INT, @CustomerRequisitionId INT, @Reason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_CancelCustReq; END
        EXEC sec.usp_Authorize @ActorUserId, N'Customer,Administrator';
        DECLARE @status VARCHAR(12), @cust INT;
        SELECT @status = Status, @cust = CustomerId FROM staff.CustomerRequisitions WITH (UPDLOCK, HOLDLOCK) WHERE CustomerRequisitionId = @CustomerRequisitionId;
        IF @status IS NULL THROW 50004, N'Staffing request not found.', 1;
        IF sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0 AND ISNULL(sec.fn_UserCustomerId(@ActorUserId), -1) <> @cust THROW 50004, N'Staffing request not found.', 1;
        IF @status IN ('Filled', 'Cancelled') THROW 50002, N'A Filled or already Cancelled request cannot be cancelled.', 1;
        UPDATE staff.SubmittedCandidates SET Status = 'Withdrawn', UpdatedAt = SYSUTCDATETIME()
        WHERE CustomerRequisitionId = @CustomerRequisitionId AND Status IN ('Submitted', 'Shortlisted', 'Interview');
        UPDATE staff.CustomerRequisitions SET Status = 'Cancelled', UpdatedAt = SYSUTCDATETIME() WHERE CustomerRequisitionId = @CustomerRequisitionId;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_CancelCustReq;
        THROW;
    END CATCH
END
GO

/* ---------------- submissions and customer decisions ---------------- */
CREATE OR ALTER PROCEDURE staff.usp_SubmitCandidateToCustomer
    @ActorUserId INT, @CustomerRequisitionId INT, @CandidateId INT, @ProposedBillRate DECIMAL(10,2) = NULL, @Notes NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_SubmitCand; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,Administrator';
        DECLARE @status VARCHAR(12), @cust INT, @assigned INT, @max DECIMAL(10,2), @title NVARCHAR(200);
        SELECT @status = Status, @cust = CustomerId, @assigned = AssignedRecruiterUserId, @max = MaxBillRate, @title = Title
        FROM staff.CustomerRequisitions WITH (UPDLOCK, HOLDLOCK) WHERE CustomerRequisitionId = @CustomerRequisitionId;
        IF @status IS NULL THROW 50004, N'Staffing request not found.', 1;
        IF @status NOT IN ('Open', 'InReview', 'Sourcing') THROW 50002, N'Candidates can only be submitted to an Open, InReview or Sourcing request.', 1;
        IF @assigned IS NOT NULL AND @assigned <> @ActorUserId AND sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0 THROW 50004, N'Staffing request not found.', 1;
        IF NOT EXISTS (SELECT 1 FROM cand.Candidates WHERE CandidateId = @CandidateId) THROW 50004, N'Candidate not found.', 1;
        IF (SELECT Status FROM cand.Candidates WHERE CandidateId = @CandidateId) <> 'Active' THROW 50002, N'Only an Active candidate can be submitted.', 1;
        IF @ProposedBillRate IS NOT NULL AND (@ProposedBillRate <= 0 OR (@max IS NOT NULL AND @ProposedBillRate > @max)) THROW 50002, N'The proposed bill rate must be positive and within the customer''s maximum.', 1;
        IF EXISTS (SELECT 1 FROM staff.SubmittedCandidates WHERE CustomerRequisitionId = @CustomerRequisitionId AND CandidateId = @CandidateId AND Status <> 'Withdrawn')
            THROW 50003, N'This candidate has already been submitted for this request.', 1;
        BEGIN TRY
            INSERT staff.SubmittedCandidates (CustomerRequisitionId, CustomerId, CandidateId, ProposedBillRate, SubmittedByUserId, Notes)
            VALUES (@CustomerRequisitionId, @cust, @CandidateId, @ProposedBillRate, @ActorUserId, @Notes);
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() IN (2601, 2627) THROW 50003, N'This candidate has already been submitted for this request.', 1;
            THROW;
        END CATCH
        DECLARE @sid INT = SCOPE_IDENTITY();
        UPDATE staff.CustomerRequisitions SET Status = 'Sourcing', AssignedRecruiterUserId = ISNULL(AssignedRecruiterUserId, @ActorUserId), UpdatedAt = SYSUTCDATETIME() WHERE CustomerRequisitionId = @CustomerRequisitionId;
        DECLARE @subj NVARCHAR(300) = N'A new candidate was submitted for ' + @title;
        DECLARE @key NVARCHAR(180) = N'SUBMIT:' + CAST(@sid AS NVARCHAR(12));
        EXEC notify.usp_EnqueueForCustomer @cust, 'CANDIDATE_SUBMITTED', @subj, @subj, @key, 'Submission', @sid;
        IF @own = 1 COMMIT;
        SELECT @sid AS SubmissionId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_SubmitCand;
        THROW;
    END CATCH
END
GO

-- The customer shortlists / rejects / selects. Only THEIR customer's submissions are visible (anything else = 50004).
CREATE OR ALTER PROCEDURE staff.usp_DecideSubmission @ActorUserId INT, @SubmissionId INT, @Decision VARCHAR(10), @Comments NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_DecideSub; END
        EXEC sec.usp_Authorize @ActorUserId, N'Customer';
        DECLARE @mine INT = sec.fn_UserCustomerId(@ActorUserId);
        IF @mine IS NULL THROW 50005, N'This login is not linked to a customer.', 1;
        IF @Decision NOT IN ('Shortlist', 'Reject', 'Select') THROW 50001, N'Decision must be Shortlist, Reject or Select.', 1;
        IF @Decision = 'Reject' AND LEN(LTRIM(RTRIM(ISNULL(@Comments, N'')))) = 0 THROW 50001, N'A reason is required when rejecting.', 1;
        DECLARE @status VARCHAR(12), @req INT, @rec INT, @title NVARCHAR(200);
        SELECT @status = s.Status, @req = s.CustomerRequisitionId, @rec = s.SubmittedByUserId, @title = cr.Title
        FROM staff.SubmittedCandidates s WITH (UPDLOCK, HOLDLOCK) JOIN staff.CustomerRequisitions cr ON cr.CustomerRequisitionId = s.CustomerRequisitionId
        WHERE s.SubmissionId = @SubmissionId AND s.CustomerId = @mine;                 -- the isolation filter
        IF @status IS NULL THROW 50004, N'Submission not found.', 1;
        IF @Decision = 'Shortlist' AND @status <> 'Submitted' THROW 50002, N'Only a Submitted candidate can be shortlisted.', 1;
        IF @Decision = 'Select' AND @status NOT IN ('Shortlisted', 'Interview') THROW 50002, N'Only a Shortlisted or Interview-stage candidate can be selected.', 1;
        IF @Decision = 'Reject' AND @status NOT IN ('Submitted', 'Shortlisted', 'Interview') THROW 50002, N'This candidate can no longer be rejected.', 1;
        INSERT staff.CustomerCandidateDecisions (SubmissionId, CustomerId, DecidedByUserId, Decision, Comments) VALUES (@SubmissionId, @mine, @ActorUserId, @Decision, @Comments);
        UPDATE staff.SubmittedCandidates SET Status = CASE @Decision WHEN 'Shortlist' THEN 'Shortlisted' WHEN 'Select' THEN 'Selected' ELSE 'Rejected' END, UpdatedAt = SYSUTCDATETIME()
        WHERE SubmissionId = @SubmissionId;
        DECLARE @subj NVARCHAR(300) = N'Customer decision on a submitted candidate for ' + @title + N': ' + @Decision;
        DECLARE @key NVARCHAR(180) = N'SUBDEC:' + CAST(@SubmissionId AS NVARCHAR(12)) + N':' + @Decision;
        EXEC notify.usp_Enqueue 'SUBMISSION_DECISION', @rec, @subj, @Comments, @key, 'Submission', @SubmissionId;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_DecideSub;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE staff.usp_WithdrawSubmission @ActorUserId INT, @SubmissionId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,Administrator';
    DECLARE @status VARCHAR(12);
    SELECT @status = Status FROM staff.SubmittedCandidates WHERE SubmissionId = @SubmissionId;
    IF @status IS NULL THROW 50004, N'Submission not found.', 1;
    IF @status IN ('Selected', 'Withdrawn') THROW 50002, N'A Selected or already Withdrawn submission cannot be withdrawn.', 1;
    UPDATE staff.SubmittedCandidates SET Status = 'Withdrawn', UpdatedAt = SYSUTCDATETIME() WHERE SubmissionId = @SubmissionId;
END
GO

-- Read: a customer sees only its own requests; contact details of a candidate are revealed only after shortlisting.
CREATE OR ALTER PROCEDURE staff.usp_ListCustomerRequisitions @ActorUserId INT, @CustomerId INT = NULL, @Status VARCHAR(12) = NULL, @Top INT = 500
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Customer,Recruiter,Administrator';
    IF sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 0 AND sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0
    BEGIN
        DECLARE @mine INT = sec.fn_UserCustomerId(@ActorUserId);
        IF @mine IS NULL THROW 50005, N'This login is not linked to a customer.', 1;
        IF @CustomerId IS NOT NULL AND @CustomerId <> @mine THROW 50004, N'Customer not found.', 1;
        SET @CustomerId = @mine;
    END
    IF @Top IS NULL OR @Top < 1 OR @Top > 5000 SET @Top = 500;   -- Phase 13: lists are capped (newest first); the API says when more exist
    SELECT TOP (@Top) cr.CustomerRequisitionId, cr.RequestNo, cr.CustomerId, cu.Name AS CustomerName, cr.Title, cr.Positions, cr.Status, cr.StartDate,
           cr.MaxBillRate, cr.AssignedRecruiterUserId, cr.CreatedAt,
           (SELECT COUNT(*) FROM staff.SubmittedCandidates s WHERE s.CustomerRequisitionId = cr.CustomerRequisitionId AND s.Status <> 'Withdrawn') AS Submissions
    FROM staff.CustomerRequisitions cr JOIN org.Customers cu ON cu.CustomerId = cr.CustomerId
    WHERE (@CustomerId IS NULL OR cr.CustomerId = @CustomerId) AND (@Status IS NULL OR cr.Status = @Status)
    ORDER BY cr.CreatedAt DESC;
END
GO

CREATE OR ALTER PROCEDURE staff.usp_GetSubmissionsForRequisition @ActorUserId INT, @CustomerRequisitionId INT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Customer,Recruiter,Administrator';
    DECLARE @cust INT = (SELECT CustomerId FROM staff.CustomerRequisitions WHERE CustomerRequisitionId = @CustomerRequisitionId);
    DECLARE @isStaff BIT = CASE WHEN sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 1 OR sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 1 THEN 1 ELSE 0 END;
    IF @cust IS NULL OR (@isStaff = 0 AND ISNULL(sec.fn_UserCustomerId(@ActorUserId), -1) <> @cust) THROW 50004, N'Staffing request not found.', 1;
    SELECT s.SubmissionId, s.CandidateId, c.FirstName, c.LastName, c.CurrentTitle, c.TotalExperienceYears, s.ProposedBillRate, s.Status, s.SubmittedAt, s.Notes,
           CASE WHEN @isStaff = 1 OR s.Status IN ('Shortlisted', 'Interview', 'Selected') THEN c.Email END AS Email,
           CASE WHEN @isStaff = 1 OR s.Status IN ('Shortlisted', 'Interview', 'Selected') THEN c.Phone END AS Phone,
           (SELECT TOP (1) ct.ContractNo FROM staff.Placements pl JOIN staff.Contracts ct ON ct.PlacementId = pl.PlacementId WHERE pl.SubmissionId = s.SubmissionId) AS ContractNo
    FROM staff.SubmittedCandidates s JOIN cand.Candidates c ON c.CandidateId = s.CandidateId
    WHERE s.CustomerRequisitionId = @CustomerRequisitionId
    ORDER BY s.SubmittedAt;
END
GO

/* ---------------- contractors, contracts, assignments ---------------- */
-- Internal worker (no authorisation, no result set): creates the contractor entity for a Candidate Master row.
CREATE OR ALTER PROCEDURE staff.usp_CreateContractorInternal @CandidateId INT, @UserId INT, @CreatedByUserId INT, @ContractorId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @@TRANCOUNT = 0 THROW 50002, N'usp_CreateContractorInternal must run inside a transaction.', 1;
    IF NOT EXISTS (SELECT 1 FROM cand.Candidates WHERE CandidateId = @CandidateId) THROW 50004, N'Candidate not found.', 1;
    IF (SELECT Status FROM cand.Candidates WHERE CandidateId = @CandidateId) <> 'Active' THROW 50002, N'Only an Active candidate can become a contractor.', 1;
    IF EXISTS (SELECT 1 FROM staff.Contractors WHERE CandidateId = @CandidateId) THROW 50003, N'This candidate is already a contractor.', 1;
    DECLARE @uid INT = ISNULL(@UserId, (SELECT UserId FROM cand.Candidates WHERE CandidateId = @CandidateId));
    IF @uid IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM sec.Users WHERE UserId = @uid AND IsActive = 1) THROW 50001, N'The login for the contractor is unknown or inactive.', 1;
        IF EXISTS (SELECT 1 FROM staff.Contractors WHERE UserId = @uid) THROW 50003, N'That login is already linked to another contractor.', 1;
        IF NOT EXISTS (SELECT 1 FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId WHERE ur.UserId = @uid AND r.RoleName = N'Contractor')
            INSERT sec.UserRoles (UserId, RoleId) SELECT @uid, RoleId FROM sec.Roles WHERE RoleName = N'Contractor';
    END
    DECLARE @n INT = NEXT VALUE FOR staff.seq_ContractorNo;
    INSERT staff.Contractors (ContractorNo, CandidateId, UserId, Status, CreatedByUserId)
    VALUES (N'CTR-' + dbo.fn_PadNumber(@n, 4), @CandidateId, @uid, 'Active', @CreatedByUserId);
    SET @ContractorId = SCOPE_IDENTITY();
END
GO

CREATE OR ALTER PROCEDURE staff.usp_CreateContractor @ActorUserId INT, @CandidateId INT, @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_CreateCtr; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,Administrator';
        DECLARE @cid INT;
        EXEC staff.usp_CreateContractorInternal @CandidateId, @UserId, @ActorUserId, @cid OUTPUT;
        IF @own = 1 COMMIT;
        SELECT ContractorId, ContractorNo FROM staff.Contractors WHERE ContractorId = @cid;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_CreateCtr;
        THROW;
    END CATCH
END
GO

-- ONE TRANSACTION: contractor (created if the candidate is not one yet) + placement + contract + rates + assignment.
-- Pay rate (what the contractor earns) and bill rate (what the customer pays) are stored separately; bill must not be below pay.
CREATE OR ALTER PROCEDURE staff.usp_CreateContract
    @ActorUserId INT, @SubmissionId INT, @StartDate DATE, @EndDate DATE, @PayRate DECIMAL(10,2), @BillRate DECIMAL(10,2),
    @OvertimePayMultiplier DECIMAL(4,2) = 1.5, @OvertimeBillMultiplier DECIMAL(4,2) = 1.5, @RoleTitle NVARCHAR(150),
    @SiteLocation NVARCHAR(150) = NULL, @HoursPerWeek DECIMAL(5,2) = 40, @Terms NVARCHAR(2000) = NULL, @Currency CHAR(3) = 'INR'
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_CreateContract; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,Administrator';
        IF @EndDate < @StartDate THROW 50001, N'The end date cannot be before the start date.', 1;
        IF @PayRate < 0 OR @BillRate <= 0 THROW 50001, N'Rates must be positive.', 1;
        IF @BillRate < @PayRate THROW 50002, N'The bill rate cannot be below the contractor pay rate.', 1;
        IF @OvertimePayMultiplier < 1 OR @OvertimeBillMultiplier < 1 THROW 50001, N'Overtime multipliers cannot be below 1.', 1;
        IF @HoursPerWeek NOT BETWEEN 1 AND 80 THROW 50001, N'Hours per week must be between 1 and 80.', 1;
        IF LEN(LTRIM(RTRIM(ISNULL(@RoleTitle, N'')))) = 0 THROW 50001, N'Role title is required.', 1;

        DECLARE @sstatus VARCHAR(12), @cust INT, @cand INT, @req INT, @max DECIMAL(10,2), @positions INT, @reqStatus VARCHAR(12), @assigned INT;
        SELECT @sstatus = s.Status, @cust = s.CustomerId, @cand = s.CandidateId, @req = s.CustomerRequisitionId,
               @max = cr.MaxBillRate, @positions = cr.Positions, @reqStatus = cr.Status, @assigned = cr.AssignedRecruiterUserId
        FROM staff.SubmittedCandidates s WITH (UPDLOCK, HOLDLOCK) JOIN staff.CustomerRequisitions cr ON cr.CustomerRequisitionId = s.CustomerRequisitionId
        WHERE s.SubmissionId = @SubmissionId;
        IF @sstatus IS NULL THROW 50004, N'Submission not found.', 1;
        IF @assigned IS NOT NULL AND @assigned <> @ActorUserId AND sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0 THROW 50004, N'Submission not found.', 1;
        IF @sstatus <> 'Selected' THROW 50002, N'A contract can only be created for a candidate the customer has Selected.', 1;
        IF @reqStatus = 'Cancelled' THROW 50002, N'The staffing request was cancelled.', 1;
        IF @max IS NOT NULL AND @BillRate > @max THROW 50002, N'The bill rate exceeds the customer''s maximum for this request.', 1;
        IF EXISTS (SELECT 1 FROM staff.Placements WHERE SubmissionId = @SubmissionId) THROW 50003, N'A placement already exists for this submission.', 1;

        DECLARE @ctr INT = (SELECT ContractorId FROM staff.Contractors WHERE CandidateId = @cand);
        IF @ctr IS NULL EXEC staff.usp_CreateContractorInternal @cand, NULL, @ActorUserId, @ctr OUTPUT;
        ELSE IF (SELECT Status FROM staff.Contractors WHERE ContractorId = @ctr) <> 'Active' THROW 50002, N'This contractor is not Active.', 1;

        INSERT staff.Placements (SubmissionId, CustomerId, ContractorId, PlacementDate, Status, CreatedByUserId)
        VALUES (@SubmissionId, @cust, @ctr, @StartDate, 'Active', @ActorUserId);
        DECLARE @pid INT = SCOPE_IDENTITY();
        DECLARE @n INT = NEXT VALUE FOR staff.seq_ContractNo;
        DECLARE @no NVARCHAR(30) = N'CON-' + CAST(YEAR(SYSUTCDATETIME()) AS NVARCHAR(4)) + N'-' + dbo.fn_PadNumber(@n, 3);
        INSERT staff.Contracts (ContractNo, PlacementId, CustomerId, StartDate, EndDate, Status, Terms, CreatedByUserId)
        VALUES (@no, @pid, @cust, @StartDate, @EndDate, 'Active', @Terms, @ActorUserId);
        DECLARE @kid INT = SCOPE_IDENTITY();
        INSERT staff.ContractRates (ContractId, PayRate, BillRate, OvertimePayMultiplier, OvertimeBillMultiplier, Currency, EffectiveFrom, CreatedByUserId)
        VALUES (@kid, @PayRate, @BillRate, @OvertimePayMultiplier, @OvertimeBillMultiplier, @Currency, @StartDate, @ActorUserId);
        INSERT staff.Assignments (ContractId, CustomerId, ContractorId, RoleTitle, SiteLocation, HoursPerWeek, StartDate, EndDate, Status)
        VALUES (@kid, @cust, @ctr, LTRIM(RTRIM(@RoleTitle)), @SiteLocation, @HoursPerWeek, @StartDate, @EndDate, 'Active');
        DECLARE @aid INT = SCOPE_IDENTITY();

        IF (SELECT COUNT(*) FROM staff.Placements p JOIN staff.SubmittedCandidates s ON s.SubmissionId = p.SubmissionId
            WHERE s.CustomerRequisitionId = @req AND p.Status IN ('Active', 'Completed')) >= @positions
            UPDATE staff.CustomerRequisitions SET Status = 'Filled', UpdatedAt = SYSUTCDATETIME() WHERE CustomerRequisitionId = @req;

        DECLARE @cuser INT = (SELECT UserId FROM staff.Contractors WHERE ContractorId = @ctr);
        DECLARE @subj NVARCHAR(300) = N'Your contract ' + @no + N' has been created';
        EXEC notify.usp_Enqueue 'CONTRACT_CREATED', @cuser, @subj, @subj, N'CONTRACT', 'Contract', @kid;
        IF @own = 1 COMMIT;
        SELECT @kid AS ContractId, @no AS ContractNo, @pid AS PlacementId, @aid AS AssignmentId, @ctr AS ContractorId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_CreateContract;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE staff.usp_CreateAssignment
    @ActorUserId INT, @ContractId INT, @RoleTitle NVARCHAR(150), @SiteLocation NVARCHAR(150) = NULL, @HoursPerWeek DECIMAL(5,2) = 40,
    @StartDate DATE, @EndDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_CreateAssign; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,Administrator';
        DECLARE @status VARCHAR(12), @cust INT, @ctr INT, @cs DATE, @ce DATE;
        SELECT @status = c.Status, @cust = c.CustomerId, @ctr = p.ContractorId, @cs = c.StartDate, @ce = c.EndDate
        FROM staff.Contracts c WITH (UPDLOCK, HOLDLOCK) JOIN staff.Placements p ON p.PlacementId = c.PlacementId WHERE c.ContractId = @ContractId;
        IF @status IS NULL THROW 50004, N'Contract not found.', 1;
        IF @status NOT IN ('Active', 'Expiring') THROW 50002, N'Assignments can only be added to an Active or Expiring contract.', 1;
        IF @StartDate < @cs OR @StartDate > @ce OR (@EndDate IS NOT NULL AND (@EndDate > @ce OR @EndDate < @StartDate)) THROW 50002, N'Assignment dates must lie within the contract period.', 1;
        IF @HoursPerWeek NOT BETWEEN 1 AND 80 THROW 50001, N'Hours per week must be between 1 and 80.', 1;
        INSERT staff.Assignments (ContractId, CustomerId, ContractorId, RoleTitle, SiteLocation, HoursPerWeek, StartDate, EndDate, Status)
        VALUES (@ContractId, @cust, @ctr, LTRIM(RTRIM(@RoleTitle)), @SiteLocation, @HoursPerWeek, @StartDate, @EndDate, 'Active');
        DECLARE @aid INT = SCOPE_IDENTITY();
        IF @own = 1 COMMIT;
        SELECT @aid AS AssignmentId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_CreateAssign;
        THROW;
    END CATCH
END
GO

-- Renewal: extension record + new end date (+ optional new rates effective today) + assignments follow the contract.
CREATE OR ALTER PROCEDURE staff.usp_RenewContract
    @ActorUserId INT, @ContractId INT, @NewEndDate DATE, @PayRate DECIMAL(10,2) = NULL, @BillRate DECIMAL(10,2) = NULL, @Reason NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_RenewContract; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,Administrator';
        DECLARE @status VARCHAR(12), @old DATE, @plc INT;
        SELECT @status = Status, @old = EndDate, @plc = PlacementId FROM staff.Contracts WITH (UPDLOCK, HOLDLOCK) WHERE ContractId = @ContractId;
        IF @status IS NULL THROW 50004, N'Contract not found.', 1;
        IF @status NOT IN ('Active', 'Expiring', 'Expired') THROW 50002, N'Only an Active, Expiring or Expired contract can be renewed.', 1;
        IF @NewEndDate <= @old THROW 50002, N'The new end date must be after the current end date.', 1;
        DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
        IF @PayRate IS NOT NULL OR @BillRate IS NOT NULL
        BEGIN
            DECLARE @rid INT, @cp DECIMAL(10,2), @cb DECIMAL(10,2), @from DATE, @otp DECIMAL(4,2), @otb DECIMAL(4,2), @cur CHAR(3);
            SELECT TOP (1) @rid = ContractRateId, @cp = PayRate, @cb = BillRate, @from = EffectiveFrom, @otp = OvertimePayMultiplier, @otb = OvertimeBillMultiplier, @cur = Currency
            FROM staff.ContractRates WHERE ContractId = @ContractId AND EffectiveTo IS NULL ORDER BY EffectiveFrom DESC;
            IF @rid IS NULL THROW 50002, N'The contract has no open-ended rate to replace.', 1;
            DECLARE @np DECIMAL(10,2) = ISNULL(@PayRate, @cp), @nb DECIMAL(10,2) = ISNULL(@BillRate, @cb);
            IF @np < 0 OR @nb <= 0 THROW 50001, N'Rates must be positive.', 1;
            IF @nb < @np THROW 50002, N'The bill rate cannot be below the contractor pay rate.', 1;
            IF @np <> @cp OR @nb <> @cb
            BEGIN
                IF @from >= @today UPDATE staff.ContractRates SET PayRate = @np, BillRate = @nb WHERE ContractRateId = @rid;
                ELSE
                BEGIN
                    UPDATE staff.ContractRates SET EffectiveTo = DATEADD(DAY, -1, @today) WHERE ContractRateId = @rid;
                    INSERT staff.ContractRates (ContractId, PayRate, BillRate, OvertimePayMultiplier, OvertimeBillMultiplier, Currency, EffectiveFrom, CreatedByUserId)
                    VALUES (@ContractId, @np, @nb, @otp, @otb, @cur, @today, @ActorUserId);
                END
            END
        END
        INSERT staff.ContractExtensions (ContractId, PreviousEndDate, NewEndDate, Reason, ApprovedByUserId) VALUES (@ContractId, @old, @NewEndDate, @Reason, @ActorUserId);
        UPDATE staff.Contracts SET EndDate = @NewEndDate, Status = 'Active', UpdatedAt = SYSUTCDATETIME() WHERE ContractId = @ContractId;
        UPDATE staff.Assignments SET EndDate = @NewEndDate WHERE ContractId = @ContractId AND Status = 'Active' AND (EndDate IS NULL OR EndDate = @old);
        UPDATE staff.Placements SET Status = 'Active' WHERE PlacementId = @plc AND Status = 'Completed';
        IF @own = 1 COMMIT;
        SELECT ContractId, EndDate, Status FROM staff.Contracts WHERE ContractId = @ContractId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_RenewContract;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE staff.usp_TerminateContract @ActorUserId INT, @ContractId INT, @Reason NVARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_TermContract; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,Administrator';
        IF LEN(LTRIM(RTRIM(ISNULL(@Reason, N'')))) = 0 THROW 50001, N'A reason is required.', 1;
        DECLARE @status VARCHAR(12), @plc INT;
        SELECT @status = Status, @plc = PlacementId FROM staff.Contracts WITH (UPDLOCK, HOLDLOCK) WHERE ContractId = @ContractId;
        IF @status IS NULL THROW 50004, N'Contract not found.', 1;
        IF @status NOT IN ('Active', 'Expiring') THROW 50002, N'Only an Active or Expiring contract can be terminated.', 1;
        DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
        UPDATE staff.Contracts SET Status = 'Terminated', Terms = LEFT(ISNULL(Terms + N' | ', N'') + N'Terminated: ' + @Reason, 2000), UpdatedAt = SYSUTCDATETIME() WHERE ContractId = @ContractId;
        UPDATE staff.Assignments SET Status = 'Completed', EndDate = CASE WHEN EndDate IS NULL OR EndDate > @today THEN @today ELSE EndDate END WHERE ContractId = @ContractId AND Status = 'Active';
        UPDATE staff.Placements SET Status = 'Completed' WHERE PlacementId = @plc;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_TermContract;
        THROW;
    END CATCH
END
GO
