/* ============================================================================
   TAMS - 06_StoredProcedures / 02_Requisitions_Jobs.sql
   Internal flow, part 1: department hiring requests -> approval -> job -> approval -> posting.
   ========================================================================== */
USE TalentAcquisitionDB;
GO

CREATE OR ALTER PROCEDURE hr.usp_CreateEmployeeRequisition
    @ActorUserId INT, @DepartmentId INT, @LocationId INT = NULL, @Title NVARCHAR(200), @Headcount INT = 1,
    @EmploymentType VARCHAR(15) = 'FullTime', @Justification NVARCHAR(1000) = NULL, @BudgetMax DECIMAL(12,2) = NULL,
    @RequiredByDate DATE = NULL, @Submit BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_CreateEmpReq; END
        EXEC sec.usp_Authorize @ActorUserId, N'HRManager,Administrator';
        IF LEN(LTRIM(RTRIM(ISNULL(@Title, N'')))) = 0 THROW 50001, N'Title is required.', 1;
        IF ISNULL(@Headcount, 0) < 1 THROW 50001, N'Headcount must be at least 1.', 1;
        IF @EmploymentType NOT IN ('FullTime', 'PartTime', 'Intern') THROW 50001, N'Invalid employment type.', 1;
        IF NOT EXISTS (SELECT 1 FROM org.Departments WHERE DepartmentId = @DepartmentId AND IsActive = 1) THROW 50001, N'Unknown or inactive department.', 1;
        IF @LocationId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM org.Locations WHERE LocationId = @LocationId AND IsActive = 1) THROW 50001, N'Unknown or inactive location.', 1;
        DECLARE @n INT = NEXT VALUE FOR hr.seq_RequisitionNo;
        DECLARE @no NVARCHAR(30) = N'ER-' + CAST(YEAR(SYSUTCDATETIME()) AS NVARCHAR(4)) + N'-' + dbo.fn_PadNumber(@n, 3);
        INSERT hr.EmployeeRequisitions (RequisitionNo, DepartmentId, LocationId, Title, Headcount, EmploymentType, Justification, BudgetMax,
                                        RequiredByDate, Status, RequestedByUserId, SubmittedAt)
        VALUES (@no, @DepartmentId, @LocationId, LTRIM(RTRIM(@Title)), @Headcount, @EmploymentType, @Justification, @BudgetMax, @RequiredByDate,
                CASE WHEN @Submit = 1 THEN 'Submitted' ELSE 'Draft' END, @ActorUserId, CASE WHEN @Submit = 1 THEN SYSUTCDATETIME() END);
        DECLARE @id INT = SCOPE_IDENTITY();
        IF @own = 1 COMMIT;
        SELECT @id AS EmployeeRequisitionId, @no AS RequisitionNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_CreateEmpReq;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE hr.usp_SubmitEmployeeRequisition @ActorUserId INT, @EmployeeRequisitionId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_SubmitEmpReq; END
        EXEC sec.usp_Authorize @ActorUserId, N'HRManager,Administrator';
        DECLARE @status VARCHAR(12), @req INT;
        SELECT @status = Status, @req = RequestedByUserId FROM hr.EmployeeRequisitions WITH (UPDLOCK) WHERE EmployeeRequisitionId = @EmployeeRequisitionId;
        IF @status IS NULL THROW 50004, N'Hiring request not found.', 1;
        IF @req <> @ActorUserId AND sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0 THROW 50005, N'Only the requester can submit this hiring request.', 1;
        IF @status <> 'Draft' THROW 50002, N'Only a Draft hiring request can be submitted.', 1;
        UPDATE hr.EmployeeRequisitions SET Status = 'Submitted', SubmittedAt = SYSUTCDATETIME(), UpdatedAt = SYSUTCDATETIME() WHERE EmployeeRequisitionId = @EmployeeRequisitionId;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_SubmitEmpReq;
        THROW;
    END CATCH
END
GO

-- Approve / reject a submitted hiring request. The approver can never be the requester (four-eyes).
CREATE OR ALTER PROCEDURE hr.usp_DecideEmployeeRequisition
    @ActorUserId INT, @EmployeeRequisitionId INT, @Decision VARCHAR(10), @Comments NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_DecideEmpReq; END
        EXEC sec.usp_Authorize @ActorUserId, N'HRManager,Administrator';
        IF @Decision NOT IN ('Approved', 'Rejected') THROW 50001, N'Decision must be Approved or Rejected.', 1;
        IF @Decision = 'Rejected' AND LEN(LTRIM(RTRIM(ISNULL(@Comments, N'')))) = 0 THROW 50001, N'A reason is required when rejecting.', 1;
        DECLARE @status VARCHAR(12), @req INT;
        SELECT @status = Status, @req = RequestedByUserId FROM hr.EmployeeRequisitions WITH (UPDLOCK, HOLDLOCK) WHERE EmployeeRequisitionId = @EmployeeRequisitionId;
        IF @status IS NULL THROW 50004, N'Hiring request not found.', 1;
        IF @status <> 'Submitted' THROW 50002, N'Only a Submitted hiring request can be approved or rejected.', 1;
        IF @req = @ActorUserId THROW 50002, N'You cannot approve or reject your own hiring request.', 1;
        INSERT hr.HiringApprovals (EmployeeRequisitionId, ApproverUserId, Decision, Comments) VALUES (@EmployeeRequisitionId, @ActorUserId, @Decision, @Comments);
        UPDATE hr.EmployeeRequisitions SET Status = @Decision, UpdatedAt = SYSUTCDATETIME() WHERE EmployeeRequisitionId = @EmployeeRequisitionId;
        DECLARE @subj NVARCHAR(300) = N'Hiring request ' + (SELECT RequisitionNo FROM hr.EmployeeRequisitions WHERE EmployeeRequisitionId = @EmployeeRequisitionId) + N' ' + LOWER(@Decision);
        EXEC notify.usp_Enqueue 'HIRING_DECISION', @req, @subj, @Comments, N'HIREQ', 'EmployeeRequisition', @EmployeeRequisitionId;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_DecideEmpReq;
        THROW;
    END CATCH
END
GO

-- Creates a job (status PendingApproval) from an APPROVED hiring request. Total openings across live jobs cannot exceed the approved headcount.
CREATE OR ALTER PROCEDURE rec.usp_CreateJob
    @ActorUserId INT, @EmployeeRequisitionId INT, @OwnerRecruiterUserId INT = NULL, @Openings INT = NULL,
    @Summary NVARCHAR(500) = NULL, @Responsibilities NVARCHAR(MAX) = NULL, @Qualifications NVARCHAR(MAX) = NULL,
    @MinExperienceYears DECIMAL(4,1) = 0, @SalaryMin DECIMAL(12,2) = NULL, @SalaryMax DECIMAL(12,2) = NULL, @ClosesBy DATE = NULL,
    @Skills rec.JobSkillList READONLY
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_CreateJob; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator';
        DECLARE @status VARCHAR(12), @head INT, @dept INT, @loc INT, @title NVARCHAR(200), @etype VARCHAR(15);
        SELECT @status = Status, @head = Headcount, @dept = DepartmentId, @loc = LocationId, @title = Title, @etype = EmploymentType
        FROM hr.EmployeeRequisitions WITH (UPDLOCK, HOLDLOCK) WHERE EmployeeRequisitionId = @EmployeeRequisitionId;
        IF @status IS NULL THROW 50004, N'Hiring request not found.', 1;
        IF @status <> 'Approved' THROW 50002, N'A job can only be created from an Approved hiring request.', 1;
        DECLARE @owner INT = ISNULL(@OwnerRecruiterUserId, @ActorUserId);
        IF sec.fn_UserHasRole(@owner, N'Recruiter') = 0 THROW 50001, N'The job owner must be an active Recruiter.', 1;
        DECLARE @used INT = ISNULL((SELECT SUM(Openings) FROM rec.JobRequisitions WHERE EmployeeRequisitionId = @EmployeeRequisitionId AND Status NOT IN ('Closed', 'Expired')), 0);
        SET @Openings = ISNULL(@Openings, @head - @used);
        IF @Openings < 1 OR @used + @Openings > @head THROW 50002, N'Openings exceed the headcount approved on the hiring request.', 1;
        IF @SalaryMin IS NOT NULL AND @SalaryMax IS NOT NULL AND @SalaryMax < @SalaryMin THROW 50001, N'SalaryMax cannot be below SalaryMin.', 1;

        DECLARE @n INT = NEXT VALUE FOR rec.seq_JobCode;
        DECLARE @code NVARCHAR(30) = N'JOB-' + UPPER(LEFT(REPLACE((SELECT Name FROM org.Departments WHERE DepartmentId = @dept), N' ', N''), 2)) + N'-'
                                   + CAST(YEAR(SYSUTCDATETIME()) AS NVARCHAR(4)) + N'-' + dbo.fn_PadNumber(@n, 3);
        INSERT rec.JobRequisitions (EmployeeRequisitionId, JobCode, Title, DepartmentId, LocationId, EmploymentType, Openings, Status, OwnerRecruiterUserId, ClosesBy, CreatedByUserId)
        VALUES (@EmployeeRequisitionId, @code, @title, @dept, @loc, @etype, @Openings, 'PendingApproval', @owner, @ClosesBy, @ActorUserId);
        DECLARE @jid INT = SCOPE_IDENTITY();
        INSERT rec.JobDescriptions (JobRequisitionId, VersionNo, Summary, Responsibilities, Qualifications, MinExperienceYears, SalaryMin, SalaryMax, CreatedByUserId)
        VALUES (@jid, 1, @Summary, @Responsibilities, @Qualifications, @MinExperienceYears, @SalaryMin, @SalaryMax, @ActorUserId);
        INSERT rec.JobSkills (JobRequisitionId, SkillName, IsRequired, MinYears) SELECT @jid, SkillName, IsRequired, MinYears FROM @Skills;
        IF @own = 1 COMMIT;
        SELECT @jid AS JobRequisitionId, @code AS JobCode;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_CreateJob;
        THROW;
    END CATCH
END
GO

-- HR sign-off of the job content (rec.JobApprovals). Approved -> status Approved (ready to publish); Rejected -> back to Draft.
CREATE OR ALTER PROCEDURE rec.usp_DecideJob @ActorUserId INT, @JobRequisitionId INT, @Decision VARCHAR(10), @Comments NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_DecideJob; END
        EXEC sec.usp_Authorize @ActorUserId, N'HRManager,Administrator';
        IF @Decision NOT IN ('Approved', 'Rejected') THROW 50001, N'Decision must be Approved or Rejected.', 1;
        IF @Decision = 'Rejected' AND LEN(LTRIM(RTRIM(ISNULL(@Comments, N'')))) = 0 THROW 50001, N'A reason is required when rejecting.', 1;
        DECLARE @status VARCHAR(20), @owner INT, @creator INT;
        SELECT @status = Status, @owner = OwnerRecruiterUserId, @creator = CreatedByUserId FROM rec.JobRequisitions WITH (UPDLOCK, HOLDLOCK) WHERE JobRequisitionId = @JobRequisitionId;
        IF @status IS NULL THROW 50004, N'Job not found.', 1;
        IF @status <> 'PendingApproval' THROW 50002, N'Only a job that is PendingApproval can be approved or rejected.', 1;
        IF @creator = @ActorUserId THROW 50002, N'You cannot approve a job you created.', 1;
        INSERT rec.JobApprovals (JobRequisitionId, ApproverUserId, Decision, Comments) VALUES (@JobRequisitionId, @ActorUserId, @Decision, @Comments);
        UPDATE rec.JobRequisitions SET Status = CASE WHEN @Decision = 'Approved' THEN 'Approved' ELSE 'Draft' END, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @ActorUserId
        WHERE JobRequisitionId = @JobRequisitionId;
        DECLARE @subj NVARCHAR(300) = N'Job ' + (SELECT JobCode FROM rec.JobRequisitions WHERE JobRequisitionId = @JobRequisitionId) + N' ' + LOWER(@Decision);
        EXEC notify.usp_Enqueue 'JOB_DECISION', @owner, @subj, @Comments, N'JOBAPPR', 'JobRequisition', @JobRequisitionId;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_DecideJob;
        THROW;
    END CATCH
END
GO

-- Publishes an Approved job: creates the posting and opens the job. A recruiter may only publish jobs they own.
CREATE OR ALTER PROCEDURE rec.usp_PublishJob @ActorUserId INT, @JobRequisitionId INT, @SourceId INT = NULL, @ClosesAt DATETIME2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_PublishJob; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator';
        DECLARE @status VARCHAR(20), @owner INT;
        SELECT @status = Status, @owner = OwnerRecruiterUserId FROM rec.JobRequisitions WITH (UPDLOCK, HOLDLOCK) WHERE JobRequisitionId = @JobRequisitionId;
        IF @status IS NULL THROW 50004, N'Job not found.', 1;
        IF @owner <> @ActorUserId AND sec.fn_UserHasRole(@ActorUserId, N'HRManager') = 0 AND sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0
            THROW 50004, N'Job not found.', 1;
        IF @status <> 'Approved' THROW 50002, N'Only an Approved job can be published.', 1;
        IF EXISTS (SELECT 1 FROM rec.JobPostings WHERE JobRequisitionId = @JobRequisitionId AND Status = 'Published') THROW 50003, N'This job already has a published posting.', 1;
        IF @ClosesAt IS NOT NULL AND @ClosesAt <= SYSUTCDATETIME() THROW 50001, N'ClosesAt must be in the future.', 1;
        IF @SourceId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM rec.RecruitmentSources WHERE SourceId = @SourceId AND IsActive = 1) THROW 50001, N'Unknown recruitment source.', 1;
        SET @SourceId = ISNULL(@SourceId, (SELECT SourceId FROM rec.RecruitmentSources WHERE Name = N'Careers Portal'));
        INSERT rec.JobPostings (JobRequisitionId, SourceId, PostedAt, ClosesAt, Status, PostedByUserId)
        VALUES (@JobRequisitionId, @SourceId, SYSUTCDATETIME(), @ClosesAt, 'Published', @ActorUserId);
        DECLARE @pid INT = SCOPE_IDENTITY();
        UPDATE rec.JobRequisitions SET Status = 'Open', OpenedAt = SYSUTCDATETIME(), UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @ActorUserId WHERE JobRequisitionId = @JobRequisitionId;
        IF @own = 1 COMMIT;
        SELECT @pid AS JobPostingId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_PublishJob;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE rec.usp_CloseJob @ActorUserId INT, @JobRequisitionId INT, @Reason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_CloseJob; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator';
        DECLARE @status VARCHAR(20), @owner INT;
        SELECT @status = Status, @owner = OwnerRecruiterUserId FROM rec.JobRequisitions WITH (UPDLOCK, HOLDLOCK) WHERE JobRequisitionId = @JobRequisitionId;
        IF @status IS NULL THROW 50004, N'Job not found.', 1;
        IF @owner <> @ActorUserId AND sec.fn_UserHasRole(@ActorUserId, N'HRManager') = 0 AND sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0
            THROW 50004, N'Job not found.', 1;
        IF @status IN ('Closed', 'Expired', 'Filled') THROW 50002, N'The job is already finished.', 1;
        UPDATE rec.JobPostings SET Status = 'Closed' WHERE JobRequisitionId = @JobRequisitionId AND Status IN ('Draft', 'Published');
        UPDATE rec.JobRequisitions SET Status = 'Closed', ClosedAt = SYSUTCDATETIME(), UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @ActorUserId WHERE JobRequisitionId = @JobRequisitionId;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_CloseJob;
        THROW;
    END CATCH
END
GO
