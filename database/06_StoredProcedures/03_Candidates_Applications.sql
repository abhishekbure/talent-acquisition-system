/* ============================================================================
   TAMS - 06_StoredProcedures / 03_Candidates_Applications.sql
   Shared Candidate Master + internal job applications.
   ========================================================================== */
USE TalentAcquisitionDB;
GO

-- Recruiter / HR / Admin create a candidate. A duplicate e-mail is rejected with the existing CandidateId in the message (409).
CREATE OR ALTER PROCEDURE cand.usp_CreateCandidate
    @ActorUserId INT, @FirstName NVARCHAR(100), @LastName NVARCHAR(100), @Email NVARCHAR(256), @Phone NVARCHAR(30) = NULL,
    @CurrentTitle NVARCHAR(150) = NULL, @CurrentEmployer NVARCHAR(150) = NULL, @TotalExperienceYears DECIMAL(4,1) = 0,
    @ExpectedSalary DECIMAL(12,2) = NULL, @NoticePeriodDays INT = NULL, @Summary NVARCHAR(1000) = NULL, @SourceId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_CreateCand; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator';
        SET @Email = LTRIM(RTRIM(@Email));
        IF @Email IS NULL OR @Email NOT LIKE N'%_@_%._%' THROW 50001, N'A valid e-mail address is required.', 1;
        IF LEN(LTRIM(RTRIM(ISNULL(@FirstName, N'')))) = 0 OR LEN(LTRIM(RTRIM(ISNULL(@LastName, N'')))) = 0 THROW 50001, N'First and last name are required.', 1;
        IF @TotalExperienceYears < 0 OR @TotalExperienceYears > 60 THROW 50001, N'Experience must be between 0 and 60 years.', 1;
        DECLARE @existing INT = (SELECT CandidateId FROM cand.Candidates WHERE EmailNormalized = UPPER(@Email));
        IF @existing IS NOT NULL
        BEGIN
            DECLARE @m NVARCHAR(200) = N'A candidate with this e-mail already exists (CandidateId=' + CAST(@existing AS NVARCHAR(12)) + N').';
            THROW 50003, @m, 1;
        END
        INSERT cand.Candidates (FirstName, LastName, Email, EmailNormalized, Phone, CurrentTitle, CurrentEmployer, TotalExperienceYears,
                                ExpectedSalary, NoticePeriodDays, Summary, SourceId, CreatedByUserId)
        VALUES (LTRIM(RTRIM(@FirstName)), LTRIM(RTRIM(@LastName)), @Email, UPPER(@Email), @Phone, @CurrentTitle, @CurrentEmployer, @TotalExperienceYears,
                @ExpectedSalary, @NoticePeriodDays, @Summary, @SourceId, @ActorUserId);
        DECLARE @id INT = SCOPE_IDENTITY();
        IF @own = 1 COMMIT;
        SELECT @id AS CandidateId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_CreateCand;
        THROW;
    END CATCH
END
GO

-- A Candidate updates ONLY their own profile (the id parameter is ignored for candidates); staff must pass @CandidateId.
-- @RowVer enables optimistic concurrency (50006 when the row changed since it was read).
CREATE OR ALTER PROCEDURE cand.usp_UpdateCandidate
    @ActorUserId INT, @CandidateId INT = NULL, @RowVer BINARY(8) = NULL,
    @FirstName NVARCHAR(100), @LastName NVARCHAR(100), @Phone NVARCHAR(30) = NULL, @CurrentTitle NVARCHAR(150) = NULL,
    @CurrentEmployer NVARCHAR(150) = NULL, @TotalExperienceYears DECIMAL(4,1) = 0, @ExpectedSalary DECIMAL(12,2) = NULL,
    @NoticePeriodDays INT = NULL, @Summary NVARCHAR(1000) = NULL, @Status VARCHAR(12) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_UpdateCand; END
        EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Recruiter,HRManager,Administrator';
        DECLARE @staff BIT = CASE WHEN sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 1 OR sec.fn_UserHasRole(@ActorUserId, N'HRManager') = 1
                                    OR sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 1 THEN 1 ELSE 0 END;
        IF @staff = 0 BEGIN SET @CandidateId = cand.fn_CandidateIdForUser(@ActorUserId); IF @CandidateId IS NULL THROW 50004, N'Candidate profile not found.', 1; END
        ELSE IF @CandidateId IS NULL THROW 50001, N'CandidateId is required.', 1;
        IF LEN(LTRIM(RTRIM(ISNULL(@FirstName, N'')))) = 0 OR LEN(LTRIM(RTRIM(ISNULL(@LastName, N'')))) = 0 THROW 50001, N'First and last name are required.', 1;
        IF @TotalExperienceYears < 0 OR @TotalExperienceYears > 60 THROW 50001, N'Experience must be between 0 and 60 years.', 1;
        IF @Status IS NOT NULL AND (@staff = 0 OR @Status NOT IN ('Active', 'Inactive', 'Blacklisted')) THROW 50001, N'Status cannot be changed (staff only: Active, Inactive, Blacklisted).', 1;
        DECLARE @cur BINARY(8);
        SELECT @cur = RowVer FROM cand.Candidates WITH (UPDLOCK, HOLDLOCK) WHERE CandidateId = @CandidateId;
        IF @cur IS NULL THROW 50004, N'Candidate not found.', 1;
        IF @RowVer IS NOT NULL AND @RowVer <> @cur THROW 50006, N'The candidate was changed by someone else. Reload and try again.', 1;
        UPDATE cand.Candidates SET FirstName = LTRIM(RTRIM(@FirstName)), LastName = LTRIM(RTRIM(@LastName)), Phone = @Phone, CurrentTitle = @CurrentTitle,
               CurrentEmployer = @CurrentEmployer, TotalExperienceYears = @TotalExperienceYears, ExpectedSalary = @ExpectedSalary,
               NoticePeriodDays = @NoticePeriodDays, Summary = @Summary, Status = ISNULL(@Status, Status),
               UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @ActorUserId
        WHERE CandidateId = @CandidateId;
        IF @own = 1 COMMIT;
        SELECT CandidateId, RowVer FROM cand.Candidates WHERE CandidateId = @CandidateId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_UpdateCand;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE cand.usp_GetCandidate @ActorUserId INT, @CandidateId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Recruiter,HRManager,Administrator';
    IF sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 0 AND sec.fn_UserHasRole(@ActorUserId, N'HRManager') = 0 AND sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0
        SET @CandidateId = cand.fn_CandidateIdForUser(@ActorUserId);
    IF @CandidateId IS NULL OR NOT EXISTS (SELECT 1 FROM cand.Candidates WHERE CandidateId = @CandidateId) THROW 50004, N'Candidate not found.', 1;
    SELECT c.CandidateId, c.FirstName, c.LastName, c.Email, c.Phone, c.CurrentTitle, c.CurrentEmployer, c.TotalExperienceYears, c.ExpectedSalary,
           c.NoticePeriodDays, c.Summary, c.Status, c.RowVer, cand.fn_ExperienceYears(c.CandidateId) AS ComputedExperienceYears
    FROM cand.Candidates c WHERE c.CandidateId = @CandidateId;
    SELECT SkillName, YearsExperience, ProficiencyLevel FROM cand.fn_CandidateSkills(@CandidateId) ORDER BY SkillName;
    SELECT Institution, Degree, FieldOfStudy, StartYear, EndYear, Grade FROM cand.CandidateEducation WHERE CandidateId = @CandidateId ORDER BY EndYear DESC;
    SELECT Employer, JobTitle, StartDate, EndDate, IsCurrent, Description FROM cand.CandidateExperience WHERE CandidateId = @CandidateId ORDER BY StartDate DESC;
END
GO

CREATE OR ALTER PROCEDURE cand.usp_AddCandidateSkill
    @ActorUserId INT, @CandidateId INT = NULL, @SkillName NVARCHAR(100), @YearsExperience DECIMAL(4,1) = 0, @ProficiencyLevel TINYINT = 3
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_AddSkill; END
        EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Recruiter,HRManager,Administrator';
        IF sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 0 AND sec.fn_UserHasRole(@ActorUserId, N'HRManager') = 0 AND sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0
            SET @CandidateId = cand.fn_CandidateIdForUser(@ActorUserId);
        IF @CandidateId IS NULL OR NOT EXISTS (SELECT 1 FROM cand.Candidates WHERE CandidateId = @CandidateId) THROW 50004, N'Candidate not found.', 1;
        SET @SkillName = LTRIM(RTRIM(@SkillName));
        IF LEN(ISNULL(@SkillName, N'')) = 0 THROW 50001, N'Skill name is required.', 1;
        IF @ProficiencyLevel NOT BETWEEN 1 AND 5 OR @YearsExperience < 0 THROW 50001, N'Proficiency must be 1-5 and years cannot be negative.', 1;
        IF EXISTS (SELECT 1 FROM cand.CandidateSkills WHERE CandidateId = @CandidateId AND SkillName = @SkillName)
            UPDATE cand.CandidateSkills SET YearsExperience = @YearsExperience, ProficiencyLevel = @ProficiencyLevel WHERE CandidateId = @CandidateId AND SkillName = @SkillName;
        ELSE
            INSERT cand.CandidateSkills (CandidateId, SkillName, YearsExperience, ProficiencyLevel) VALUES (@CandidateId, @SkillName, @YearsExperience, @ProficiencyLevel);
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_AddSkill;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE cand.usp_RemoveCandidateSkill @ActorUserId INT, @CandidateId INT = NULL, @SkillName NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Recruiter,HRManager,Administrator';
    IF sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 0 AND sec.fn_UserHasRole(@ActorUserId, N'HRManager') = 0 AND sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0
        SET @CandidateId = cand.fn_CandidateIdForUser(@ActorUserId);
    IF @CandidateId IS NULL OR NOT EXISTS (SELECT 1 FROM cand.Candidates WHERE CandidateId = @CandidateId) THROW 50004, N'Candidate not found.', 1;
    DELETE cand.CandidateSkills WHERE CandidateId = @CandidateId AND SkillName = LTRIM(RTRIM(@SkillName));
    IF @@ROWCOUNT = 0 THROW 50004, N'Skill not found on this candidate.', 1;
END
GO

-- Paged search of the shared candidate master. ALL listed skills must match.
CREATE OR ALTER PROCEDURE cand.usp_SearchCandidates
    @ActorUserId INT, @Q NVARCHAR(100) = NULL, @SkillsCsv NVARCHAR(MAX) = NULL, @MinExp DECIMAL(4,1) = NULL, @MaxExp DECIMAL(4,1) = NULL,
    @Status VARCHAR(12) = NULL, @Page INT = 1, @PageSize INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator';
    IF @Page < 1 SET @Page = 1;
    IF @PageSize < 1 OR @PageSize > 200 SET @PageSize = 25;
    SET @Q = NULLIF(LTRIM(RTRIM(@Q)), N'');
    -- Phase 13 (measured on 100,000 candidates): count once instead of COUNT(*) OVER () (which spooled every match);
    -- RECOMPILE so the optimiser drops the filters that were not given (catch-all search). Free text is matched in ONE pass
    -- into a temp table (name / e-mail / title, or a skill) - the same rule as cand.fn_SearchCandidates - and then joined:
    -- left inside the OR, the optimiser probed the skills table once per candidate (430,000+ reads).
    DECLARE @total INT;
    IF @Q IS NULL
    BEGIN
        SELECT @total = COUNT(*) FROM cand.fn_SearchCandidates(NULL, @SkillsCsv, @MinExp, @MaxExp, @Status) OPTION (RECOMPILE);
        SELECT s.CandidateId, s.FirstName, s.LastName, s.Email, s.Phone, s.CurrentTitle, s.CurrentEmployer, s.TotalExperienceYears,
               s.ExpectedSalary, s.NoticePeriodDays, s.Status, @total AS TotalCount
        FROM cand.fn_SearchCandidates(NULL, @SkillsCsv, @MinExp, @MaxExp, @Status) s
        ORDER BY s.LastName, s.FirstName, s.CandidateId
        OFFSET (@Page - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
        OPTION (RECOMPILE);
        RETURN;
    END
    DECLARE @pat NVARCHAR(110) = N'%' + UPPER(@Q) + N'%';
    CREATE TABLE #hit (CandidateId INT NOT NULL PRIMARY KEY);
    INSERT #hit (CandidateId)
    SELECT c.CandidateId FROM cand.Candidates c
    WHERE UPPER(c.FirstName) COLLATE Latin1_General_BIN2 LIKE @pat OR UPPER(c.LastName) COLLATE Latin1_General_BIN2 LIKE @pat
       OR UPPER(c.Email) COLLATE Latin1_General_BIN2 LIKE @pat OR UPPER(c.CurrentTitle) COLLATE Latin1_General_BIN2 LIKE @pat
    UNION
    SELECT k.CandidateId FROM cand.CandidateSkills k WHERE UPPER(k.SkillName) COLLATE Latin1_General_BIN2 LIKE @pat;
    -- the filtered matches with their sort columns, then count and page from that small set (a single plan shape whatever
    -- the text: the optimiser otherwise walked the name index and probed #hit for every candidate)
    CREATE TABLE #res (CandidateId INT NOT NULL PRIMARY KEY, LastName NVARCHAR(100) NOT NULL, FirstName NVARCHAR(100) NOT NULL);
    INSERT #res (CandidateId, LastName, FirstName)
    SELECT s.CandidateId, s.LastName, s.FirstName FROM cand.fn_SearchCandidates(NULL, @SkillsCsv, @MinExp, @MaxExp, @Status) s JOIN #hit h ON h.CandidateId = s.CandidateId
    OPTION (RECOMPILE);
    SET @total = (SELECT COUNT(*) FROM #res);
    WITH pg AS (SELECT CandidateId, LastName, FirstName FROM #res ORDER BY LastName, FirstName, CandidateId OFFSET (@Page - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY)
    SELECT c.CandidateId, c.FirstName, c.LastName, c.Email, c.Phone, c.CurrentTitle, c.CurrentEmployer, c.TotalExperienceYears,
           c.ExpectedSalary, c.NoticePeriodDays, c.Status, @total AS TotalCount
    FROM pg JOIN cand.Candidates c ON c.CandidateId = pg.CandidateId
    ORDER BY pg.LastName, pg.FirstName, pg.CandidateId;
END
GO

/* ---------------- applications ---------------- */
CREATE OR ALTER PROCEDURE cand.usp_CreateApplication @ActorUserId INT, @JobPostingId INT, @CoverNote NVARCHAR(1000) = NULL, @SourceId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_CreateApp; END
        EXEC sec.usp_Authorize @ActorUserId, N'Candidate';
        DECLARE @cid INT = cand.fn_CandidateIdForUser(@ActorUserId);
        IF @cid IS NULL THROW 50004, N'Candidate profile not found.', 1;
        IF (SELECT Status FROM cand.Candidates WHERE CandidateId = @cid) <> 'Active' THROW 50002, N'Your candidate profile is not active.', 1;
        DECLARE @pstatus VARCHAR(10), @jstatus VARCHAR(20), @closes DATETIME2(0), @owner INT, @title NVARCHAR(200);
        SELECT @pstatus = p.Status, @jstatus = jr.Status, @closes = p.ClosesAt, @owner = jr.OwnerRecruiterUserId, @title = jr.Title
        FROM rec.JobPostings p JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId WHERE p.JobPostingId = @JobPostingId;
        IF @pstatus IS NULL THROW 50004, N'Job posting not found.', 1;
        IF @pstatus <> 'Published' OR @jstatus <> 'Open' OR (@closes IS NOT NULL AND @closes <= SYSUTCDATETIME()) THROW 50002, N'This job is no longer accepting applications.', 1;
        IF EXISTS (SELECT 1 FROM cand.JobApplications WHERE CandidateId = @cid AND JobPostingId = @JobPostingId AND Status <> 'Withdrawn')
            THROW 50003, N'You have already applied for this job.', 1;
        BEGIN TRY
            INSERT cand.JobApplications (CandidateId, JobPostingId, SourceId, CoverNote, UpdatedByUserId)
            VALUES (@cid, @JobPostingId, ISNULL(@SourceId, (SELECT SourceId FROM rec.JobPostings WHERE JobPostingId = @JobPostingId)), @CoverNote, @ActorUserId);
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() IN (2601, 2627) THROW 50003, N'You have already applied for this job.', 1;
            THROW;
        END CATCH
        DECLARE @aid INT = SCOPE_IDENTITY();
        UPDATE h SET Reason = N'Application received' FROM cand.ApplicationStatusHistory h
        WHERE h.HistoryId = (SELECT MAX(HistoryId) FROM cand.ApplicationStatusHistory WHERE ApplicationId = @aid AND Reason IS NULL);
        DECLARE @subj NVARCHAR(300) = N'New application for ' + @title;
        EXEC notify.usp_Enqueue 'APPLICATION_RECEIVED', @owner, @subj, @subj, N'APPNEW', 'JobApplication', @aid;
        IF @own = 1 COMMIT;
        SELECT @aid AS ApplicationId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_CreateApp;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE cand.usp_WithdrawApplication @ActorUserId INT, @ApplicationId INT, @Reason NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_WithdrawApp; END
        EXEC sec.usp_Authorize @ActorUserId, N'Candidate';
        DECLARE @cid INT = cand.fn_CandidateIdForUser(@ActorUserId), @status VARCHAR(12);
        SELECT @status = Status FROM cand.JobApplications WITH (UPDLOCK, HOLDLOCK) WHERE ApplicationId = @ApplicationId AND CandidateId = @cid;
        IF @status IS NULL THROW 50004, N'Application not found.', 1;      -- someone else's application looks like a missing one
        IF @status IN ('Hired', 'Rejected', 'Withdrawn') THROW 50002, N'This application is already finished and cannot be withdrawn.', 1;
        UPDATE cand.JobApplications SET Status = 'Withdrawn', UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @ActorUserId WHERE ApplicationId = @ApplicationId;
        UPDATE h SET Reason = ISNULL(@Reason, N'Withdrawn by candidate') FROM cand.ApplicationStatusHistory h
        WHERE h.HistoryId = (SELECT MAX(HistoryId) FROM cand.ApplicationStatusHistory WHERE ApplicationId = @ApplicationId AND Reason IS NULL);
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_WithdrawApp;
        THROW;
    END CATCH
END
GO

-- Manual pipeline moves. OfferStage / Hired / Withdrawn are set only by the offer and candidate procedures.
CREATE OR ALTER PROCEDURE cand.usp_ChangeApplicationStatus
    @ActorUserId INT, @ApplicationId INT, @NewStatus VARCHAR(12), @Reason NVARCHAR(500) = NULL, @RowVer BINARY(8) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_ChangeAppStatus; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,Administrator';
        DECLARE @allowed TABLE (FromS VARCHAR(12), ToS VARCHAR(12));
        INSERT @allowed VALUES ('Applied','Screening'),('Applied','Rejected'),('Screening','Shortlisted'),('Screening','Rejected'),
                               ('Shortlisted','Interview'),('Shortlisted','Rejected'),('Interview','Selected'),('Interview','Shortlisted'),
                               ('Interview','Rejected'),('Selected','Rejected');
        DECLARE @cur VARCHAR(12), @rv BINARY(8), @cand INT, @owner INT, @title NVARCHAR(200);
        SELECT @cur = a.Status, @rv = a.RowVer, @cand = a.CandidateId, @owner = jr.OwnerRecruiterUserId, @title = jr.Title
        FROM cand.JobApplications a WITH (UPDLOCK, HOLDLOCK)
        JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
        WHERE a.ApplicationId = @ApplicationId;
        IF @cur IS NULL THROW 50004, N'Application not found.', 1;
        IF sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0 AND @owner <> @ActorUserId THROW 50004, N'Application not found.', 1;   -- recruiters work their own jobs
        IF @RowVer IS NOT NULL AND @RowVer <> @rv THROW 50006, N'The application was changed by someone else. Reload and try again.', 1;
        IF NOT EXISTS (SELECT 1 FROM @allowed WHERE FromS = @cur AND ToS = @NewStatus)
        BEGIN
            DECLARE @m NVARCHAR(200) = N'Status change ' + @cur + N' -> ' + ISNULL(@NewStatus, N'?') + N' is not allowed.';
            THROW 50002, @m, 1;
        END
        IF @NewStatus = 'Rejected' AND LEN(LTRIM(RTRIM(ISNULL(@Reason, N'')))) = 0 THROW 50001, N'A reason is required when rejecting.', 1;
        UPDATE cand.JobApplications SET Status = @NewStatus, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @ActorUserId WHERE ApplicationId = @ApplicationId;
        IF @Reason IS NOT NULL
            UPDATE h SET Reason = @Reason FROM cand.ApplicationStatusHistory h
            WHERE h.HistoryId = (SELECT MAX(HistoryId) FROM cand.ApplicationStatusHistory WHERE ApplicationId = @ApplicationId AND Reason IS NULL);
        DECLARE @cuser INT = (SELECT UserId FROM cand.Candidates WHERE CandidateId = @cand);
        DECLARE @subj NVARCHAR(300) = N'Your application for ' + @title + N' is now: ' + @NewStatus;
        DECLARE @key NVARCHAR(180) = N'APPSTATUS:' + CAST(@ApplicationId AS NVARCHAR(12)) + N':' + @NewStatus;
        EXEC notify.usp_Enqueue 'APPLICATION_STATUS', @cuser, @subj, @subj, @key, 'JobApplication', @ApplicationId;
        IF @own = 1 COMMIT;
        SELECT ApplicationId, Status, RowVer FROM cand.JobApplications WHERE ApplicationId = @ApplicationId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_ChangeAppStatus;
        THROW;
    END CATCH
END
GO

-- Convenience: moves an application to Shortlisted (passing through Screening when it is still Applied).
CREATE OR ALTER PROCEDURE cand.usp_ShortlistApplication @ActorUserId INT, @ApplicationId INT, @Reason NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_Shortlist; END
        DECLARE @cur VARCHAR(12) = (SELECT Status FROM cand.JobApplications WHERE ApplicationId = @ApplicationId);
        IF @cur = 'Applied' EXEC cand.usp_ChangeApplicationStatus @ActorUserId, @ApplicationId, 'Screening', N'Screened';
        EXEC cand.usp_ChangeApplicationStatus @ActorUserId, @ApplicationId, 'Shortlisted', @Reason;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_Shortlist;
        THROW;
    END CATCH
END
GO
