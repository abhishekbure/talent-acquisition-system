/* ============================================================================
   TAMS - 06_StoredProcedures / 04_Interviews_Offers_Employees.sql
   Interviews (internal AND external), offers, employee creation and onboarding.
   ========================================================================== */
USE TalentAcquisitionDB;
GO

/* ---------------- interviews ---------------- */
-- Exactly one of @JobApplicationId (internal) / @SubmittedCandidateId (external). A Customer user can schedule only for
-- THEIR OWN customer's submissions; panel members are validated against the interview's side.
CREATE OR ALTER PROCEDURE cand.usp_ScheduleInterview
    @ActorUserId INT, @JobApplicationId INT = NULL, @SubmittedCandidateId INT = NULL, @RoundNo TINYINT = 1,
    @InterviewType VARCHAR(15) = 'Technical', @StartsAt DATETIME2(0), @EndsAt DATETIME2(0), @Mode VARCHAR(10) = 'Video',
    @LocationOrLink NVARCHAR(300) = NULL, @Notes NVARCHAR(1000) = NULL, @Panel dbo.IdList READONLY,
    @LeadUserId INT = NULL                         -- lead interviewer; must be on the panel (default: lowest user id)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_SchedInterview; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator,Customer';
        IF (@JobApplicationId IS NULL AND @SubmittedCandidateId IS NULL) OR (@JobApplicationId IS NOT NULL AND @SubmittedCandidateId IS NOT NULL)
            THROW 50001, N'Specify exactly one of JobApplicationId or SubmittedCandidateId.', 1;
        IF @StartsAt <= SYSUTCDATETIME() THROW 50001, N'The interview must start in the future.', 1;
        IF @EndsAt <= @StartsAt THROW 50001, N'The interview must end after it starts.', 1;
        IF @Mode NOT IN ('Onsite', 'Video', 'Phone') OR @InterviewType NOT IN ('Screening', 'Technical', 'HR', 'Managerial', 'Customer') THROW 50001, N'Invalid mode or interview type.', 1;
        IF NOT EXISTS (SELECT 1 FROM @Panel) THROW 50001, N'At least one interviewer is required.', 1;
        IF EXISTS (SELECT 1 FROM @Panel p WHERE NOT EXISTS (SELECT 1 FROM sec.Users u WHERE u.UserId = p.Id AND u.IsActive = 1)) THROW 50001, N'The panel contains an unknown or inactive user.', 1;
        IF @LeadUserId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @Panel WHERE Id = @LeadUserId) THROW 50001, N'The lead interviewer must be a member of the panel.', 1;

        DECLARE @cust INT = NULL, @cuser INT, @title NVARCHAR(200), @iid INT;
        IF @JobApplicationId IS NOT NULL
        BEGIN
            IF sec.fn_UserHasRole(@ActorUserId, N'Customer') = 1 AND sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 0
               AND sec.fn_UserHasRole(@ActorUserId, N'HRManager') = 0 AND sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0
                THROW 50004, N'Application not found.', 1;
            DECLARE @astatus VARCHAR(12);
            SELECT @astatus = a.Status, @cuser = c.UserId, @title = jr.Title
            FROM cand.JobApplications a WITH (UPDLOCK) JOIN cand.Candidates c ON c.CandidateId = a.CandidateId
            JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
            WHERE a.ApplicationId = @JobApplicationId;
            IF @astatus IS NULL THROW 50004, N'Application not found.', 1;
            IF @astatus NOT IN ('Shortlisted', 'Interview') THROW 50002, N'Interviews can only be scheduled for Shortlisted or Interview-stage applications.', 1;
            IF EXISTS (SELECT 1 FROM cand.Interviews WHERE JobApplicationId = @JobApplicationId AND RoundNo = @RoundNo AND Status IN ('Scheduled', 'Rescheduled', 'Completed'))
                THROW 50003, N'This round is already scheduled or completed for the application.', 1;
            IF EXISTS (SELECT 1 FROM @Panel p WHERE NOT EXISTS (SELECT 1 FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId
                       WHERE ur.UserId = p.Id AND r.RoleName IN (N'Recruiter', N'HRManager', N'Administrator')))
                THROW 50001, N'Internal interviews can only have Recruiter, HR Manager or Administrator interviewers.', 1;
            INSERT cand.Interviews (JobApplicationId, RoundNo, InterviewType, StartsAt, EndsAt, Mode, LocationOrLink, Notes, ScheduledByUserId)
            VALUES (@JobApplicationId, @RoundNo, @InterviewType, @StartsAt, @EndsAt, @Mode, @LocationOrLink, @Notes, @ActorUserId);
            SET @iid = SCOPE_IDENTITY();
            IF @astatus = 'Shortlisted'
            BEGIN
                UPDATE cand.JobApplications SET Status = 'Interview', UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @ActorUserId WHERE ApplicationId = @JobApplicationId;
                UPDATE h SET Reason = N'Interview scheduled' FROM cand.ApplicationStatusHistory h
                WHERE h.HistoryId = (SELECT MAX(HistoryId) FROM cand.ApplicationStatusHistory WHERE ApplicationId = @JobApplicationId AND Reason IS NULL);
            END
        END
        ELSE
        BEGIN
            DECLARE @sstatus VARCHAR(12);
            SELECT @sstatus = s.Status, @cust = s.CustomerId, @cuser = c.UserId, @title = cr.Title
            FROM staff.SubmittedCandidates s WITH (UPDLOCK) JOIN cand.Candidates c ON c.CandidateId = s.CandidateId
            JOIN staff.CustomerRequisitions cr ON cr.CustomerRequisitionId = s.CustomerRequisitionId
            WHERE s.SubmissionId = @SubmittedCandidateId;
            IF @sstatus IS NULL THROW 50004, N'Submission not found.', 1;
            DECLARE @isStaff BIT = CASE WHEN sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 1 OR sec.fn_UserHasRole(@ActorUserId, N'HRManager') = 1
                                          OR sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 1 THEN 1 ELSE 0 END;
            IF @isStaff = 0 AND ISNULL(sec.fn_UserCustomerId(@ActorUserId), -1) <> @cust THROW 50004, N'Submission not found.', 1;   -- another customer's data
            IF @sstatus NOT IN ('Shortlisted', 'Interview') THROW 50002, N'Interviews can only be scheduled for Shortlisted candidates.', 1;
            IF EXISTS (SELECT 1 FROM cand.Interviews WHERE SubmittedCandidateId = @SubmittedCandidateId AND RoundNo = @RoundNo AND Status IN ('Scheduled', 'Rescheduled', 'Completed'))
                THROW 50003, N'This round is already scheduled or completed for the submission.', 1;
            IF EXISTS (SELECT 1 FROM @Panel p
                       WHERE NOT EXISTS (SELECT 1 FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId WHERE ur.UserId = p.Id AND r.RoleName IN (N'Recruiter', N'HRManager', N'Administrator'))
                         AND NOT EXISTS (SELECT 1 FROM org.CustomerUsers cu WHERE cu.UserId = p.Id AND cu.CustomerId = @cust))
                THROW 50001, N'External interviews can only have staff or this customer''s own users on the panel.', 1;
            INSERT cand.Interviews (SubmittedCandidateId, CustomerId, RoundNo, InterviewType, StartsAt, EndsAt, Mode, LocationOrLink, Notes, ScheduledByUserId)
            VALUES (@SubmittedCandidateId, @cust, @RoundNo, @InterviewType, @StartsAt, @EndsAt, @Mode, @LocationOrLink, @Notes, @ActorUserId);
            SET @iid = SCOPE_IDENTITY();
            IF @sstatus = 'Shortlisted' UPDATE staff.SubmittedCandidates SET Status = 'Interview', UpdatedAt = SYSUTCDATETIME() WHERE SubmissionId = @SubmittedCandidateId;
        END
        INSERT cand.InterviewPanels (InterviewId, UserId, IsLead) SELECT @iid, Id, CASE WHEN Id = COALESCE(@LeadUserId, (SELECT MIN(Id) FROM @Panel)) THEN 1 ELSE 0 END FROM @Panel;
        -- times in the business time zone (KI-028); the data stays in UTC
        DECLARE @subj NVARCHAR(300) = N'Interview invitation: ' + @title + N' on ' + dbo.fn_BusinessTime(@StartsAt);
        DECLARE @body NVARCHAR(1000) = @subj + N'.' + NCHAR(10) + N'Ends: ' + dbo.fn_BusinessTime(@EndsAt) + NCHAR(10) + N'Mode: ' + @Mode
            + CASE WHEN NULLIF(LTRIM(@LocationOrLink), N'') IS NULL THEN N'' ELSE NCHAR(10) + N'Where: ' + @LocationOrLink END;
        DECLARE @key NVARCHAR(180) = N'INTV:' + CAST(@iid AS NVARCHAR(12)) + N':' + CONVERT(NVARCHAR(16), @StartsAt, 120);
        EXEC notify.usp_Enqueue 'INTERVIEW_INVITE', @cuser, @subj, @body, @key, 'Interview', @iid;
        IF @own = 1 COMMIT;
        SELECT @iid AS InterviewId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_SchedInterview;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE cand.usp_RescheduleInterview
    @ActorUserId INT, @InterviewId INT, @StartsAt DATETIME2(0), @EndsAt DATETIME2(0), @Mode VARCHAR(10) = NULL, @LocationOrLink NVARCHAR(300) = NULL, @RowVer BINARY(8) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_ReschedInterview; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator,Customer';
        DECLARE @status VARCHAR(12), @cust INT, @rv BINARY(8), @cuser INT, @iApp INT, @iSub INT;
        SELECT @status = i.Status, @cust = i.CustomerId, @rv = i.RowVer, @iApp = i.JobApplicationId, @iSub = i.SubmittedCandidateId,
               @cuser = (SELECT c.UserId FROM cand.Candidates c WHERE c.CandidateId = COALESCE(
                          (SELECT a.CandidateId FROM cand.JobApplications a WHERE a.ApplicationId = i.JobApplicationId),
                          (SELECT s.CandidateId FROM staff.SubmittedCandidates s WHERE s.SubmissionId = i.SubmittedCandidateId)))
        FROM cand.Interviews i WITH (UPDLOCK, HOLDLOCK) WHERE i.InterviewId = @InterviewId;
        IF @status IS NULL THROW 50004, N'Interview not found.', 1;
        DECLARE @isStaff BIT = CASE WHEN sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 1 OR sec.fn_UserHasRole(@ActorUserId, N'HRManager') = 1
                                      OR sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 1 THEN 1 ELSE 0 END;
        IF @isStaff = 0 AND (@cust IS NULL OR ISNULL(sec.fn_UserCustomerId(@ActorUserId), -1) <> @cust) THROW 50004, N'Interview not found.', 1;
        IF @status NOT IN ('Scheduled', 'Rescheduled') THROW 50002, N'Only a Scheduled or Rescheduled interview can be moved.', 1;
        IF @RowVer IS NOT NULL AND @RowVer <> @rv THROW 50006, N'The interview was changed by someone else. Reload and try again.', 1;
        IF @StartsAt <= SYSUTCDATETIME() OR @EndsAt <= @StartsAt THROW 50001, N'The new time must be in the future and end after it starts.', 1;
        IF @Mode IS NOT NULL AND @Mode NOT IN ('Onsite', 'Video', 'Phone') THROW 50001, N'Invalid mode.', 1;
        UPDATE cand.Interviews SET StartsAt = @StartsAt, EndsAt = @EndsAt, Mode = ISNULL(@Mode, Mode), LocationOrLink = ISNULL(@LocationOrLink, LocationOrLink),
               Status = 'Rescheduled', UpdatedAt = SYSUTCDATETIME() WHERE InterviewId = @InterviewId;
        DECLARE @subj NVARCHAR(300) = N'Interview rescheduled to ' + dbo.fn_BusinessTime(@StartsAt);
        DECLARE @key NVARCHAR(180) = N'INTV:' + CAST(@InterviewId AS NVARCHAR(12)) + N':' + CONVERT(NVARCHAR(16), @StartsAt, 120);
        EXEC notify.usp_Enqueue 'INTERVIEW_INVITE', @cuser, @subj, @subj, @key, 'Interview', @InterviewId;
        IF @own = 1 COMMIT;
        SELECT InterviewId, Status, StartsAt, EndsAt, RowVer FROM cand.Interviews WHERE InterviewId = @InterviewId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_ReschedInterview;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE cand.usp_CancelInterview @ActorUserId INT, @InterviewId INT, @Reason NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_CancelInterview; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator,Customer';
        DECLARE @status VARCHAR(12), @cust INT;
        SELECT @status = Status, @cust = CustomerId FROM cand.Interviews WITH (UPDLOCK, HOLDLOCK) WHERE InterviewId = @InterviewId;
        IF @status IS NULL THROW 50004, N'Interview not found.', 1;
        IF (sec.fn_UserHasRole(@ActorUserId, N'Recruiter') = 0 AND sec.fn_UserHasRole(@ActorUserId, N'HRManager') = 0 AND sec.fn_UserHasRole(@ActorUserId, N'Administrator') = 0)
           AND (@cust IS NULL OR ISNULL(sec.fn_UserCustomerId(@ActorUserId), -1) <> @cust) THROW 50004, N'Interview not found.', 1;
        IF @status NOT IN ('Scheduled', 'Rescheduled') THROW 50002, N'Only a Scheduled or Rescheduled interview can be cancelled.', 1;
        UPDATE cand.Interviews SET Status = 'Cancelled', Notes = LEFT(ISNULL(Notes + N' | ', N'') + N'Cancelled: ' + ISNULL(@Reason, N'no reason given'), 1000), UpdatedAt = SYSUTCDATETIME()
        WHERE InterviewId = @InterviewId;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_CancelInterview;
        THROW;
    END CATCH
END
GO

-- Only a member of the interview's panel can submit feedback (once). The interview becomes Completed when every panelist has submitted.
CREATE OR ALTER PROCEDURE cand.usp_SubmitInterviewFeedback
    @ActorUserId INT, @InterviewId INT, @Rating TINYINT, @Recommendation VARCHAR(10), @Strengths NVARCHAR(1000) = NULL, @Concerns NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_Feedback; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator,Customer';
        IF @Rating NOT BETWEEN 1 AND 5 THROW 50001, N'Rating must be 1 to 5.', 1;
        IF @Recommendation NOT IN ('StrongYes', 'Yes', 'No', 'StrongNo') THROW 50001, N'Invalid recommendation.', 1;
        DECLARE @status VARCHAR(12), @start DATETIME2(0);
        SELECT @status = Status, @start = StartsAt FROM cand.Interviews WITH (UPDLOCK, HOLDLOCK) WHERE InterviewId = @InterviewId;
        IF @status IS NULL THROW 50004, N'Interview not found.', 1;
        IF NOT EXISTS (SELECT 1 FROM cand.InterviewPanels WHERE InterviewId = @InterviewId AND UserId = @ActorUserId) THROW 50004, N'Interview not found.', 1;
        IF @status = 'Cancelled' THROW 50002, N'A cancelled interview cannot receive feedback.', 1;
        IF @start > SYSUTCDATETIME() THROW 50002, N'Feedback can only be submitted once the interview has started.', 1;
        IF EXISTS (SELECT 1 FROM cand.InterviewFeedback WHERE InterviewId = @InterviewId AND InterviewerUserId = @ActorUserId) THROW 50003, N'You have already submitted feedback for this interview.', 1;
        INSERT cand.InterviewFeedback (InterviewId, InterviewerUserId, Rating, Recommendation, Strengths, Concerns)
        VALUES (@InterviewId, @ActorUserId, @Rating, @Recommendation, @Strengths, @Concerns);
        IF NOT EXISTS (SELECT 1 FROM cand.InterviewPanels p WHERE p.InterviewId = @InterviewId
                       AND NOT EXISTS (SELECT 1 FROM cand.InterviewFeedback f WHERE f.InterviewId = @InterviewId AND f.InterviewerUserId = p.UserId))
            UPDATE cand.Interviews SET Status = 'Completed', UpdatedAt = SYSUTCDATETIME() WHERE InterviewId = @InterviewId;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_Feedback;
        THROW;
    END CATCH
END
GO

/* ---------------- offers ---------------- */
CREATE OR ALTER PROCEDURE cand.usp_CreateOffer
    @ActorUserId INT, @ApplicationId INT, @Designation NVARCHAR(150), @OfferedSalary DECIMAL(12,2), @Currency CHAR(3) = 'INR',
    @StartDate DATE, @ExpiresAt DATETIME2(0)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_CreateOffer; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator';
        IF ISNULL(@OfferedSalary, 0) <= 0 THROW 50001, N'Offered salary must be greater than zero.', 1;
        IF LEN(LTRIM(RTRIM(ISNULL(@Designation, N'')))) = 0 THROW 50001, N'Designation is required.', 1;
        IF @StartDate < CAST(SYSUTCDATETIME() AS DATE) THROW 50001, N'Start date cannot be in the past.', 1;
        IF @ExpiresAt <= SYSUTCDATETIME() THROW 50001, N'The offer must expire in the future.', 1;
        DECLARE @status VARCHAR(12);
        SELECT @status = Status FROM cand.JobApplications WITH (UPDLOCK, HOLDLOCK) WHERE ApplicationId = @ApplicationId;
        IF @status IS NULL THROW 50004, N'Application not found.', 1;
        IF @status <> 'Selected' THROW 50002, N'An offer can only be created for a Selected application.', 1;
        IF EXISTS (SELECT 1 FROM cand.JobOffers WHERE ApplicationId = @ApplicationId AND Status NOT IN ('Rejected', 'Declined', 'Expired'))
            THROW 50003, N'A live offer already exists for this application.', 1;
        DECLARE @n INT = NEXT VALUE FOR cand.seq_OfferNo;
        DECLARE @no NVARCHAR(30) = N'OFR-' + CAST(YEAR(SYSUTCDATETIME()) AS NVARCHAR(4)) + N'-' + dbo.fn_PadNumber(@n, 3);
        INSERT cand.JobOffers (ApplicationId, OfferNo, Designation, OfferedSalary, Currency, StartDate, ExpiresAt, Status, CreatedByUserId)
        VALUES (@ApplicationId, @no, LTRIM(RTRIM(@Designation)), @OfferedSalary, @Currency, @StartDate, @ExpiresAt, 'PendingApproval', @ActorUserId);
        DECLARE @oid INT = SCOPE_IDENTITY();
        IF @own = 1 COMMIT;
        SELECT @oid AS OfferId, @no AS OfferNo;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_CreateOffer;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE cand.usp_DecideOffer @ActorUserId INT, @OfferId INT, @Decision VARCHAR(10), @Comments NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_DecideOffer; END
        EXEC sec.usp_Authorize @ActorUserId, N'HRManager,Administrator';
        IF @Decision NOT IN ('Approved', 'Rejected') THROW 50001, N'Decision must be Approved or Rejected.', 1;
        IF @Decision = 'Rejected' AND LEN(LTRIM(RTRIM(ISNULL(@Comments, N'')))) = 0 THROW 50001, N'A reason is required when rejecting.', 1;
        DECLARE @status VARCHAR(16), @creator INT;
        SELECT @status = Status, @creator = CreatedByUserId FROM cand.JobOffers WITH (UPDLOCK, HOLDLOCK) WHERE OfferId = @OfferId;
        IF @status IS NULL THROW 50004, N'Offer not found.', 1;
        IF @status <> 'PendingApproval' THROW 50002, N'Only an offer that is PendingApproval can be approved or rejected.', 1;
        IF @creator = @ActorUserId THROW 50002, N'You cannot approve or reject an offer you created.', 1;
        INSERT cand.OfferApprovals (OfferId, ApproverUserId, Decision, Comments) VALUES (@OfferId, @ActorUserId, @Decision, @Comments);
        UPDATE cand.JobOffers SET Status = @Decision, UpdatedAt = SYSUTCDATETIME() WHERE OfferId = @OfferId;
        DECLARE @subj NVARCHAR(300) = N'Offer ' + (SELECT OfferNo FROM cand.JobOffers WHERE OfferId = @OfferId) + N' ' + LOWER(@Decision);
        EXEC notify.usp_Enqueue 'OFFER_DECISION', @creator, @subj, @Comments, N'OFFDEC', 'JobOffer', @OfferId;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_DecideOffer;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE cand.usp_SendOffer @ActorUserId INT, @OfferId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_SendOffer; END
        EXEC sec.usp_Authorize @ActorUserId, N'Recruiter,HRManager,Administrator';
        DECLARE @status VARCHAR(16), @app INT, @expires DATETIME2(0), @cuser INT, @no NVARCHAR(30);
        SELECT @status = o.Status, @app = o.ApplicationId, @expires = o.ExpiresAt, @no = o.OfferNo, @cuser = c.UserId
        FROM cand.JobOffers o WITH (UPDLOCK, HOLDLOCK) JOIN cand.JobApplications a ON a.ApplicationId = o.ApplicationId JOIN cand.Candidates c ON c.CandidateId = a.CandidateId
        WHERE o.OfferId = @OfferId;
        IF @status IS NULL THROW 50004, N'Offer not found.', 1;
        IF @status <> 'Approved' THROW 50002, N'Only an Approved offer can be sent.', 1;
        IF @expires <= SYSUTCDATETIME() THROW 50002, N'The offer has already expired.', 1;
        UPDATE cand.JobOffers SET Status = 'Sent', SentAt = SYSUTCDATETIME(), UpdatedAt = SYSUTCDATETIME() WHERE OfferId = @OfferId;
        UPDATE cand.JobApplications SET Status = 'OfferStage', UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @ActorUserId WHERE ApplicationId = @app AND Status = 'Selected';
        UPDATE h SET Reason = N'Offer sent' FROM cand.ApplicationStatusHistory h
        WHERE h.HistoryId = (SELECT MAX(HistoryId) FROM cand.ApplicationStatusHistory WHERE ApplicationId = @app AND Reason IS NULL);
        DECLARE @subj NVARCHAR(300) = N'You have a job offer (' + @no + N')';
        EXEC notify.usp_Enqueue 'OFFER_SENT', @cuser, @subj, @subj, N'OFFSENT', 'JobOffer', @OfferId;
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_SendOffer;
        THROW;
    END CATCH
END
GO

/* ---------------- employee creation (called inside the offer-acceptance transaction) ---------------- */
CREATE OR ALTER PROCEDURE hr.usp_CreateEmployeeFromOffer @OfferId INT, @ActorUserId INT, @EmployeeId INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF @@TRANCOUNT = 0 THROW 50002, N'hr.usp_CreateEmployeeFromOffer must run inside the offer-acceptance transaction.', 1;
    DECLARE @app INT, @cid INT, @dept INT, @loc INT, @job INT, @designation NVARCHAR(150), @salary DECIMAL(12,2), @start DATE, @openings INT;
    SELECT @app = a.ApplicationId, @cid = a.CandidateId, @dept = jr.DepartmentId, @loc = jr.LocationId, @job = jr.JobRequisitionId,
           @designation = o.Designation, @salary = o.OfferedSalary, @start = o.StartDate, @openings = jr.Openings
    FROM cand.JobOffers o JOIN cand.JobApplications a ON a.ApplicationId = o.ApplicationId
    JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
    WHERE o.OfferId = @OfferId;
    IF @app IS NULL THROW 50004, N'Offer not found.', 1;
    IF EXISTS (SELECT 1 FROM hr.Employees WHERE JobOfferId = @OfferId OR CandidateId = @cid) THROW 50003, N'An employee record already exists for this offer or candidate.', 1;

    DECLARE @n INT = NEXT VALUE FOR hr.seq_EmployeeNo;
    INSERT hr.Employees (EmployeeNo, CandidateId, JobOfferId, DepartmentId, LocationId, JobTitle, StartDate, Salary, Status, ManagerUserId)
    VALUES (N'EMP-' + dbo.fn_PadNumber(@n, 4), @cid, @OfferId, @dept, @loc, @designation, @start, @salary, 'Onboarding',
            (SELECT HeadUserId FROM org.Departments WHERE DepartmentId = @dept));
    SET @EmployeeId = SCOPE_IDENTITY();

    INSERT hr.EmployeeOnboarding (EmployeeId, TaskName, Category, DueDate)
    SELECT @EmployeeId, t.TaskName, t.Category, DATEADD(DAY, t.OffsetDays, @start)
    FROM (VALUES (N'Sign employment agreement', 'Admin', -7), (N'Submit identity and address proof', 'Compliance', -5),
                 (N'Bank and payroll setup', 'Payroll', -2), (N'IT equipment provisioning', 'IT', 0),
                 (N'Email and system accounts', 'IT', 0), (N'Orientation session', 'Orientation', 1),
                 (N'Complete compliance training', 'Compliance', 14)) t(TaskName, Category, OffsetDays);

    INSERT hr.EmploymentHistory (EmployeeId, EventType, EffectiveDate, Details, RecordedByUserId)
    VALUES (@EmployeeId, 'Hired', @start, N'Hired through offer ' + (SELECT OfferNo FROM cand.JobOffers WHERE OfferId = @OfferId), @ActorUserId);

    UPDATE cand.JobApplications SET Status = 'Hired', UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @ActorUserId WHERE ApplicationId = @app;
    UPDATE h SET Reason = N'Offer accepted' FROM cand.ApplicationStatusHistory h
    WHERE h.HistoryId = (SELECT MAX(HistoryId) FROM cand.ApplicationStatusHistory WHERE ApplicationId = @app AND Reason IS NULL);

    -- the job is Filled once hires reach its approved openings
    IF (SELECT COUNT(*) FROM cand.JobApplications a JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId
        WHERE p.JobRequisitionId = @job AND a.Status = 'Hired') >= @openings
    BEGIN
        UPDATE rec.JobPostings SET Status = 'Closed' WHERE JobRequisitionId = @job AND Status = 'Published';
        UPDATE rec.JobRequisitions SET Status = 'Filled', ClosedAt = SYSUTCDATETIME(), UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @ActorUserId WHERE JobRequisitionId = @job;
    END

    DECLARE @hr INT, @subj NVARCHAR(300) = N'New employee to onboard (offer ' + (SELECT OfferNo FROM cand.JobOffers WHERE OfferId = @OfferId) + N')';
    DECLARE hrc CURSOR LOCAL FAST_FORWARD FOR SELECT ur.UserId FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId WHERE r.RoleName = N'HRManager';
    OPEN hrc; FETCH NEXT FROM hrc INTO @hr;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC notify.usp_Enqueue 'ONBOARDING_STARTED', @hr, @subj, @subj, N'ONBOARD', 'Employee', @EmployeeId;
        FETCH NEXT FROM hrc INTO @hr;
    END
    CLOSE hrc; DEALLOCATE hrc;
END
GO

-- Candidate accepts or declines. ACCEPT is one transaction: offer + employee + onboarding + history + application + job fill.
CREATE OR ALTER PROCEDURE cand.usp_RespondToOffer @ActorUserId INT, @OfferId INT, @Accept BIT, @Note NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_RespondOffer; END
        EXEC sec.usp_Authorize @ActorUserId, N'Candidate';
        DECLARE @status VARCHAR(16), @app INT, @expires DATETIME2(0), @cuserid INT;
        SELECT @status = o.Status, @app = o.ApplicationId, @expires = o.ExpiresAt, @cuserid = c.UserId
        FROM cand.JobOffers o WITH (UPDLOCK, HOLDLOCK) JOIN cand.JobApplications a ON a.ApplicationId = o.ApplicationId JOIN cand.Candidates c ON c.CandidateId = a.CandidateId
        WHERE o.OfferId = @OfferId;
        IF @status IS NULL OR ISNULL(@cuserid, -1) <> @ActorUserId THROW 50004, N'Offer not found.', 1;   -- not the caller's offer
        IF @status <> 'Sent' THROW 50002, N'Only an offer that has been Sent can be accepted or declined.', 1;
        IF @expires <= SYSUTCDATETIME() THROW 50002, N'This offer has expired.', 1;
        DECLARE @eid INT = NULL;
        IF @Accept = 1
        BEGIN
            UPDATE cand.JobOffers SET Status = 'Accepted', RespondedAt = SYSUTCDATETIME(), ResponseNote = @Note, UpdatedAt = SYSUTCDATETIME() WHERE OfferId = @OfferId;
            EXEC hr.usp_CreateEmployeeFromOffer @OfferId, @ActorUserId, @eid OUTPUT;
        END
        ELSE
        BEGIN
            UPDATE cand.JobOffers SET Status = 'Declined', RespondedAt = SYSUTCDATETIME(), ResponseNote = @Note, UpdatedAt = SYSUTCDATETIME() WHERE OfferId = @OfferId;
            UPDATE cand.JobApplications SET Status = 'Rejected', UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @ActorUserId WHERE ApplicationId = @app;
            UPDATE h SET Reason = N'Offer declined by candidate' FROM cand.ApplicationStatusHistory h
            WHERE h.HistoryId = (SELECT MAX(HistoryId) FROM cand.ApplicationStatusHistory WHERE ApplicationId = @app AND Reason IS NULL);
        END
        IF @own = 1 COMMIT;
        SELECT @OfferId AS OfferId, CASE WHEN @Accept = 1 THEN 'Accepted' ELSE 'Declined' END AS Result, @eid AS EmployeeId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_RespondOffer;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE hr.usp_CompleteOnboardingTask @ActorUserId INT, @OnboardingId INT, @Notes NVARCHAR(500) = NULL, @Waive BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_Onboarding; END
        EXEC sec.usp_Authorize @ActorUserId, N'HRManager,Administrator';
        DECLARE @status VARCHAR(12), @emp INT;
        SELECT @status = Status, @emp = EmployeeId FROM hr.EmployeeOnboarding WITH (UPDLOCK, HOLDLOCK) WHERE OnboardingId = @OnboardingId;
        IF @status IS NULL THROW 50004, N'Onboarding task not found.', 1;
        IF @status IN ('Completed', 'Waived') THROW 50002, N'This onboarding task is already finished.', 1;
        UPDATE hr.EmployeeOnboarding SET Status = CASE WHEN @Waive = 1 THEN 'Waived' ELSE 'Completed' END, CompletedByUserId = @ActorUserId,
               CompletedAt = SYSUTCDATETIME(), Notes = @Notes WHERE OnboardingId = @OnboardingId;
        IF NOT EXISTS (SELECT 1 FROM hr.EmployeeOnboarding WHERE EmployeeId = @emp AND Status NOT IN ('Completed', 'Waived'))
            UPDATE hr.Employees SET Status = 'Active', UpdatedAt = SYSUTCDATETIME() WHERE EmployeeId = @emp AND Status = 'Onboarding';
        IF @own = 1 COMMIT;
        SELECT e.EmployeeId, e.Status AS EmployeeStatus FROM hr.Employees e WHERE e.EmployeeId = @emp;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_Onboarding;
        THROW;
    END CATCH
END
GO
