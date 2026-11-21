/* ============================================================================
   TAMS - 06_StoredProcedures / 01_Security_Notify.sql
   CONVENTIONS used by every procedure in this folder
   * First parameter of every write/read-for-a-user procedure is @ActorUserId (taken from the
     validated token by the API, NEVER from the client). Authorisation is re-checked here.
   * sec.usp_Authorize verifies the role AND stamps CONTEXT_INFO so triggers can audit the actor.
   * Errors use THROW with these numbers (the API maps them to HTTP status):
       50001 validation (400)  50002 business rule (422)  50003 duplicate / conflict (409)
       50004 not found OR outside the caller's scope (404)  50005 forbidden (403)
       50006 concurrency conflict (409)  50010 append-only violation
   * A procedure owns its transaction only when none is open (@own); otherwise it uses a
     SAVEPOINT, so procedures compose and tests can wrap them in a rolled-back transaction.
   ========================================================================== */
USE TalentAcquisitionDB;
GO

/* ---------------- authorisation helper ---------------- */
CREATE OR ALTER PROCEDURE sec.usp_Authorize @ActorUserId INT, @Roles NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;
    IF @ActorUserId IS NULL OR NOT EXISTS
       (SELECT 1 FROM sec.UserRoles ur
        JOIN sec.Roles r ON r.RoleId = ur.RoleId
        JOIN sec.Users u ON u.UserId = ur.UserId AND u.IsActive = 1
        WHERE ur.UserId = @ActorUserId AND CHARINDEX(N',' + r.RoleName + N',', N',' + @Roles + N',') > 0)
        THROW 50005, N'Forbidden: the caller does not have a role permitted for this operation.', 1;
    DECLARE @ci VARBINARY(128) = CAST(@ActorUserId AS BINARY(4));
    SET CONTEXT_INFO @ci;
END
GO

/* ---------------- authentication support ---------------- */
CREATE OR ALTER PROCEDURE sec.usp_GetUserForLogin @Email NVARCHAR(256)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.UserId, u.Email, u.DisplayName, u.PasswordHash, u.PasswordSalt, u.HashIterations, u.IsActive, u.LockoutUntil, u.EmailVerifiedAt,
           Roles = STUFF((SELECT N',' + r.RoleName FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId
                          WHERE ur.UserId = u.UserId ORDER BY r.RoleName FOR XML PATH(N'')), 1, 1, N''),
           CustomerId   = (SELECT CustomerId   FROM org.CustomerUsers WHERE UserId = u.UserId),
           CandidateId  = (SELECT CandidateId  FROM cand.Candidates   WHERE UserId = u.UserId),
           ContractorId = (SELECT ContractorId FROM staff.Contractors WHERE UserId = u.UserId)
    FROM sec.Users u
    WHERE u.EmailNormalized = UPPER(LTRIM(RTRIM(@Email)));
END
GO

-- Writes audit.LoginHistory, maintains the failed-attempt counter and locks the account for 15 minutes after 5 failures.
-- @CountFailure = 0 records a refused sign-in that is not a guessing attempt (right password, e-mail not yet verified).
CREATE OR ALTER PROCEDURE sec.usp_RecordLoginAttempt
    @Email NVARCHAR(256), @Success BIT, @FailureReason NVARCHAR(100) = NULL, @IpAddress VARCHAR(45) = NULL, @UserAgent NVARCHAR(300) = NULL,
    @CountFailure BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @uid INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = UPPER(LTRIM(RTRIM(@Email))));
    INSERT audit.LoginHistory (UserId, Email, Success, FailureReason, IpAddress, UserAgent)
    VALUES (@uid, LEFT(@Email, 256), @Success, @FailureReason, @IpAddress, @UserAgent);
    IF @uid IS NOT NULL AND (@Success = 1 OR @CountFailure = 1)
    BEGIN
        IF @Success = 1
            UPDATE sec.Users SET FailedLoginCount = 0, LockoutUntil = NULL, LastLoginAt = SYSUTCDATETIME() WHERE UserId = @uid;
        ELSE
            UPDATE sec.Users SET FailedLoginCount = FailedLoginCount + 1,
                                 LockoutUntil = CASE WHEN FailedLoginCount + 1 >= 5 THEN DATEADD(MINUTE, 15, SYSUTCDATETIME()) ELSE LockoutUntil END
            WHERE UserId = @uid;
    END
    SELECT LockoutUntil, FailedLoginCount FROM sec.Users WHERE UserId = @uid;
END
GO

CREATE OR ALTER PROCEDURE sec.usp_IssueToken @UserId INT, @Jti UNIQUEIDENTIFIER, @ExpiresAt DATETIME2(0)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT sec.AuthTokens (Jti, UserId, ExpiresAt) VALUES (@Jti, @UserId, @ExpiresAt);
END
GO

-- Returns one row only when the token exists, is unrevoked, unexpired AND the user is still active.
CREATE OR ALTER PROCEDURE sec.usp_ValidateToken @Jti UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    -- Roles are read here on EVERY request, so a role granted (e.g. Contractor when a contract is created) or removed
    -- by an administrator takes effect immediately; the roles inside the token are only a display hint.
    SELECT t.UserId,
           Roles = STUFF((SELECT N',' + r.RoleName FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId
                          WHERE ur.UserId = t.UserId ORDER BY r.RoleName FOR XML PATH(N'')), 1, 1, N'')
    FROM sec.AuthTokens t JOIN sec.Users u ON u.UserId = t.UserId
    WHERE t.Jti = @Jti AND t.RevokedAt IS NULL AND t.ExpiresAt > SYSUTCDATETIME() AND u.IsActive = 1;
END
GO

CREATE OR ALTER PROCEDURE sec.usp_RevokeToken @Jti UNIQUEIDENTIFIER, @Reason NVARCHAR(100) = N'logout'
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE sec.AuthTokens SET RevokedAt = SYSUTCDATETIME(), RevokeReason = @Reason WHERE Jti = @Jti AND RevokedAt IS NULL;
END
GO

CREATE OR ALTER PROCEDURE sec.usp_RevokeUserTokens @UserId INT, @Reason NVARCHAR(100) = N'revoked'
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE sec.AuthTokens SET RevokedAt = SYSUTCDATETIME(), RevokeReason = @Reason WHERE UserId = @UserId AND RevokedAt IS NULL;
END
GO

-- Always succeeds silently for unknown e-mails (no account enumeration). Returns the UserId only if one exists.
CREATE OR ALTER PROCEDURE sec.usp_CreatePasswordReset @Email NVARCHAR(256), @TokenHash VARBINARY(32), @ExpiresAt DATETIME2(0)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @uid INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = UPPER(LTRIM(RTRIM(@Email))) AND IsActive = 1);
    IF @uid IS NOT NULL
    BEGIN
        UPDATE sec.PasswordResetTokens SET UsedAt = SYSUTCDATETIME() WHERE UserId = @uid AND UsedAt IS NULL;   -- invalidate older links
        INSERT sec.PasswordResetTokens (UserId, TokenHash, ExpiresAt) VALUES (@uid, @TokenHash, @ExpiresAt);
    END
    SELECT @uid AS UserId;
END
GO

/* ---------------- e-mail ownership (Phase 9, closes KI-014) ---------------- */
-- Internal (called inside the caller's transaction): marks the address as proven and, for a candidate login, links the
-- recruiter-created candidate record with the same address (deliberately NOT done at registration) or creates one.
CREATE OR ALTER PROCEDURE sec.usp_CompleteEmailVerification @UserId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @email NVARCHAR(256), @display NVARCHAR(150), @addr NVARCHAR(256);
    SELECT @email = EmailNormalized, @addr = Email, @display = LTRIM(RTRIM(DisplayName)) FROM sec.Users WITH (UPDLOCK) WHERE UserId = @UserId;
    IF @email IS NULL RETURN;
    UPDATE sec.Users SET EmailVerifiedAt = SYSUTCDATETIME(), UpdatedAt = SYSUTCDATETIME() WHERE UserId = @UserId AND EmailVerifiedAt IS NULL;
    IF sec.fn_UserHasRole(@UserId, N'Candidate') = 1 AND NOT EXISTS (SELECT 1 FROM cand.Candidates WHERE UserId = @UserId)
    BEGIN
        DECLARE @ci VARBINARY(128) = CAST(@UserId AS BINARY(4)); SET CONTEXT_INFO @ci;
        DECLARE @cid INT = (SELECT CandidateId FROM cand.Candidates WITH (UPDLOCK, HOLDLOCK) WHERE EmailNormalized = @email AND UserId IS NULL);
        IF @cid IS NOT NULL
            UPDATE cand.Candidates SET UserId = @UserId, UpdatedAt = SYSUTCDATETIME(), UpdatedByUserId = @UserId WHERE CandidateId = @cid;
        ELSE
        BEGIN
            DECLARE @sp INT = CHARINDEX(N' ', @display);
            INSERT cand.Candidates (UserId, FirstName, LastName, Email, EmailNormalized, SourceId, CreatedByUserId)
            SELECT @UserId, CASE WHEN @sp > 0 THEN LEFT(@display, @sp - 1) ELSE @display END,
                   CASE WHEN @sp > 0 THEN LTRIM(SUBSTRING(@display, @sp + 1, 150)) ELSE @display END,
                   @addr, @email, (SELECT SourceId FROM rec.RecruitmentSources WHERE Name = N'Careers Portal'), @UserId;
        END
    END
END
GO

-- Resend: issues a new link for an active, not yet verified account (older links stop working). At most one link per
-- minute per account, so the endpoint cannot be used to flood a mailbox. Returns UserId only when a link was created.
CREATE OR ALTER PROCEDURE sec.usp_CreateEmailVerification @Email NVARCHAR(256), @TokenHash VARBINARY(32), @ExpiresAt DATETIME2(0)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @uid INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = UPPER(LTRIM(RTRIM(@Email))) AND IsActive = 1 AND EmailVerifiedAt IS NULL);
    IF @uid IS NOT NULL AND EXISTS (SELECT 1 FROM sec.EmailVerificationTokens WHERE UserId = @uid AND CreatedAt > DATEADD(SECOND, -60, SYSUTCDATETIME()))
        SET @uid = NULL;
    IF @uid IS NOT NULL
    BEGIN
        IF DATALENGTH(@TokenHash) <> 32 THROW 50001, N'Invalid token hash.', 1;
        UPDATE sec.EmailVerificationTokens SET UsedAt = SYSUTCDATETIME() WHERE UserId = @uid AND UsedAt IS NULL;
        INSERT sec.EmailVerificationTokens (UserId, TokenHash, ExpiresAt) VALUES (@uid, @TokenHash, @ExpiresAt);
    END
    SELECT @uid AS UserId;
END
GO

CREATE OR ALTER PROCEDURE sec.usp_VerifyEmail @TokenHash VARBINARY(32)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_VerifyEmail; END
        DECLARE @vid INT, @uid INT;
        SELECT @vid = VerificationId, @uid = UserId FROM sec.EmailVerificationTokens WITH (UPDLOCK, HOLDLOCK)
        WHERE TokenHash = @TokenHash AND UsedAt IS NULL AND ExpiresAt > SYSUTCDATETIME();
        IF @uid IS NULL THROW 50002, N'The verification link is invalid, already used or has expired. Ask for a new one from the sign-in page.', 1;
        UPDATE sec.EmailVerificationTokens SET UsedAt = SYSUTCDATETIME() WHERE VerificationId = @vid;
        EXEC sec.usp_CompleteEmailVerification @uid;
        IF @own = 1 COMMIT;
        SELECT UserId, Email FROM sec.Users WHERE UserId = @uid;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_VerifyEmail;
        THROW;
    END CATCH
END
GO

-- A completed reset also proves the address (the link went to that mailbox), so it verifies the account too: someone who
-- registered another person's address first can be displaced by that person through "Forgot password".
CREATE OR ALTER PROCEDURE sec.usp_ConsumePasswordReset
    @TokenHash VARBINARY(32), @NewPasswordHash VARBINARY(64), @NewPasswordSalt VARBINARY(32), @Iterations INT = 210000
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_ConsumeReset; END
        DECLARE @uid INT, @rid INT;
        SELECT @rid = ResetId, @uid = UserId FROM sec.PasswordResetTokens WITH (UPDLOCK, HOLDLOCK)
        WHERE TokenHash = @TokenHash AND UsedAt IS NULL AND ExpiresAt > SYSUTCDATETIME();
        IF @uid IS NULL THROW 50002, N'The password reset link is invalid or has expired.', 1;
        IF DATALENGTH(@NewPasswordHash) <> 32 OR DATALENGTH(@NewPasswordSalt) <> 32 THROW 50001, N'Invalid password hash material.', 1;
        UPDATE sec.PasswordResetTokens SET UsedAt = SYSUTCDATETIME() WHERE ResetId = @rid;
        UPDATE sec.Users SET PasswordHash = @NewPasswordHash, PasswordSalt = @NewPasswordSalt, HashIterations = @Iterations,
                             FailedLoginCount = 0, LockoutUntil = NULL, UpdatedAt = SYSUTCDATETIME() WHERE UserId = @uid;
        EXEC sec.usp_RevokeUserTokens @uid, N'password reset';
        EXEC sec.usp_CompleteEmailVerification @uid;
        IF @own = 1 COMMIT;
        SELECT @uid AS UserId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_ConsumeReset;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE sec.usp_ChangePassword
    @ActorUserId INT, @NewPasswordHash VARBINARY(64), @NewPasswordSalt VARBINARY(32), @Iterations INT = 210000
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Contractor,Customer,Recruiter,HRManager,Administrator';
    IF DATALENGTH(@NewPasswordHash) <> 32 OR DATALENGTH(@NewPasswordSalt) <> 32 THROW 50001, N'Invalid password hash material.', 1;
    UPDATE sec.Users SET PasswordHash = @NewPasswordHash, PasswordSalt = @NewPasswordSalt, HashIterations = @Iterations, UpdatedAt = SYSUTCDATETIME()
    WHERE UserId = @ActorUserId;
END
GO

/* ---------------- registration and user administration ---------------- */
-- Candidate self-registration. The login starts UNVERIFIED and cannot sign in until the e-mailed link is used (KI-014).
-- If a recruiter already created a Candidate Master row for the same e-mail (and nobody has claimed it), the login is linked
-- to it only when the address is verified (sec.usp_CompleteEmailVerification) - never at registration - so knowing someone's
-- address is not enough to take over their candidate record. Otherwise the candidate record is created now.
CREATE OR ALTER PROCEDURE sec.usp_RegisterCandidate
    @Email NVARCHAR(256), @FirstName NVARCHAR(100), @LastName NVARCHAR(100), @Phone NVARCHAR(30) = NULL,
    @PasswordHash VARBINARY(64), @PasswordSalt VARBINARY(32), @Iterations INT = 210000,
    @VerifyTokenHash VARBINARY(32) = NULL, @VerifyExpiresAt DATETIME2(0) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_RegisterCand; END
        SET @Email = LTRIM(RTRIM(@Email));
        IF @Email IS NULL OR @Email NOT LIKE N'%_@_%._%' THROW 50001, N'A valid e-mail address is required.', 1;
        IF LEN(LTRIM(RTRIM(ISNULL(@FirstName, N'')))) = 0 OR LEN(LTRIM(RTRIM(ISNULL(@LastName, N'')))) = 0 THROW 50001, N'First and last name are required.', 1;
        IF DATALENGTH(@PasswordHash) <> 32 OR DATALENGTH(@PasswordSalt) <> 32 THROW 50001, N'Invalid password hash material.', 1;
        IF EXISTS (SELECT 1 FROM sec.Users WHERE EmailNormalized = UPPER(@Email)) THROW 50003, N'An account with this e-mail address already exists.', 1;

        INSERT sec.Users (Email, EmailNormalized, DisplayName, PasswordHash, PasswordSalt, HashIterations)
        VALUES (@Email, UPPER(@Email), LTRIM(RTRIM(@FirstName)) + N' ' + LTRIM(RTRIM(@LastName)), @PasswordHash, @PasswordSalt, @Iterations);
        DECLARE @uid INT = SCOPE_IDENTITY();
        INSERT sec.UserRoles (UserId, RoleId) SELECT @uid, RoleId FROM sec.Roles WHERE RoleName = N'Candidate';
        DECLARE @ci VARBINARY(128) = CAST(@uid AS BINARY(4)); SET CONTEXT_INFO @ci;

        IF @VerifyTokenHash IS NOT NULL
        BEGIN
            IF DATALENGTH(@VerifyTokenHash) <> 32 OR @VerifyExpiresAt IS NULL THROW 50001, N'Invalid verification token.', 1;
            INSERT sec.EmailVerificationTokens (UserId, TokenHash, ExpiresAt) VALUES (@uid, @VerifyTokenHash, @VerifyExpiresAt);
        END

        DECLARE @cid INT = NULL;
        IF NOT EXISTS (SELECT 1 FROM cand.Candidates WITH (UPDLOCK, HOLDLOCK) WHERE EmailNormalized = UPPER(@Email))
        BEGIN
            INSERT cand.Candidates (UserId, FirstName, LastName, Email, EmailNormalized, Phone, SourceId, CreatedByUserId)
            SELECT @uid, LTRIM(RTRIM(@FirstName)), LTRIM(RTRIM(@LastName)), @Email, UPPER(@Email), @Phone,
                   (SELECT SourceId FROM rec.RecruitmentSources WHERE Name = N'Careers Portal'), @uid;
            SET @cid = SCOPE_IDENTITY();
        END
        IF @own = 1 COMMIT;
        SELECT @uid AS UserId, @cid AS CandidateId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_RegisterCand;
        THROW;
    END CATCH
END
GO

-- Administrator creates staff / customer / contractor logins. Candidates self-register; contractor profiles come from staff.usp_CreateContractor.
CREATE OR ALTER PROCEDURE sec.usp_CreateUser
    @ActorUserId INT, @Email NVARCHAR(256), @DisplayName NVARCHAR(150), @PasswordHash VARBINARY(64), @PasswordSalt VARBINARY(32),
    @Iterations INT = 210000, @RoleName NVARCHAR(50), @CustomerId INT = NULL, @DepartmentId INT = NULL,
    @JobTitle NVARCHAR(100) = NULL, @IsHiringManager BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_CreateUser; END
        EXEC sec.usp_Authorize @ActorUserId, N'Administrator';
        SET @Email = LTRIM(RTRIM(@Email));
        IF @Email IS NULL OR @Email NOT LIKE N'%_@_%._%' THROW 50001, N'A valid e-mail address is required.', 1;
        IF LEN(LTRIM(RTRIM(ISNULL(@DisplayName, N'')))) = 0 THROW 50001, N'Display name is required.', 1;
        IF DATALENGTH(@PasswordHash) <> 32 OR DATALENGTH(@PasswordSalt) <> 32 THROW 50001, N'Invalid password hash material.', 1;
        IF @RoleName NOT IN (N'Recruiter', N'HRManager', N'Administrator', N'Customer', N'Contractor') THROW 50001, N'Role must be Recruiter, HRManager, Administrator, Customer or Contractor.', 1;
        IF EXISTS (SELECT 1 FROM sec.Users WHERE EmailNormalized = UPPER(@Email)) THROW 50003, N'An account with this e-mail address already exists.', 1;
        IF @RoleName = N'Customer' AND NOT EXISTS (SELECT 1 FROM org.Customers WHERE CustomerId = @CustomerId) THROW 50001, N'A valid CustomerId is required for a Customer user.', 1;

        -- accounts created by an administrator are vouched for by that administrator: no verification step
        INSERT sec.Users (Email, EmailNormalized, DisplayName, PasswordHash, PasswordSalt, HashIterations, EmailVerifiedAt)
        VALUES (@Email, UPPER(@Email), LTRIM(RTRIM(@DisplayName)), @PasswordHash, @PasswordSalt, @Iterations, SYSUTCDATETIME());
        DECLARE @uid INT = SCOPE_IDENTITY();
        INSERT sec.UserRoles (UserId, RoleId) SELECT @uid, RoleId FROM sec.Roles WHERE RoleName = @RoleName;
        IF @RoleName = N'Customer'
            INSERT org.CustomerUsers (UserId, CustomerId, JobTitle) VALUES (@uid, @CustomerId, @JobTitle);
        ELSE IF @RoleName IN (N'Recruiter', N'HRManager', N'Administrator')
            INSERT org.OrganizationUsers (UserId, OrganizationId, DepartmentId, JobTitle, IsHiringManager)
            SELECT @uid, (SELECT TOP 1 OrganizationId FROM org.Organizations ORDER BY OrganizationId), @DepartmentId, @JobTitle, @IsHiringManager;
        IF @own = 1 COMMIT;
        SELECT @uid AS UserId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_CreateUser;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE sec.usp_SetUserActive @ActorUserId INT, @UserId INT, @IsActive BIT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_SetUserActive; END
        EXEC sec.usp_Authorize @ActorUserId, N'Administrator';
        IF NOT EXISTS (SELECT 1 FROM sec.Users WHERE UserId = @UserId) THROW 50004, N'User not found.', 1;
        IF @UserId = @ActorUserId AND @IsActive = 0 THROW 50002, N'You cannot deactivate your own account.', 1;
        UPDATE sec.Users SET IsActive = @IsActive, UpdatedAt = SYSUTCDATETIME() WHERE UserId = @UserId;
        IF @IsActive = 0 EXEC sec.usp_RevokeUserTokens @UserId, N'user deactivated';
        IF @own = 1 COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_SetUserActive;
        THROW;
    END CATCH
END
GO

/* ---------------- notification queue ---------------- */
-- Idempotent: the same (DedupeKey, recipient) is queued at most once. Unknown/inactive recipients are ignored.
CREATE OR ALTER PROCEDURE notify.usp_Enqueue
    @TemplateCode VARCHAR(40), @RecipientUserId INT, @Subject NVARCHAR(300), @Body NVARCHAR(MAX), @DedupeKey NVARCHAR(180),
    @RelatedEntityType VARCHAR(30) = NULL, @RelatedEntityId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @email NVARCHAR(256) = (SELECT Email FROM sec.Users WHERE UserId = @RecipientUserId AND IsActive = 1);
    IF @email IS NULL RETURN;
    -- the key is scoped to the related entity AND the recipient, so one event notifies each person once, but a new entity always notifies again
    DECLARE @key NVARCHAR(200) = @DedupeKey + N'|' + ISNULL(@RelatedEntityType, N'') + N'#' + ISNULL(CAST(@RelatedEntityId AS NVARCHAR(12)), N'') + N'|u' + CAST(@RecipientUserId AS NVARCHAR(12));
    IF EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE DedupeKey = @key) RETURN;
    BEGIN TRY
        INSERT notify.NotificationQueue (TemplateCode, RecipientUserId, ToEmail, Subject, Body, DedupeKey, RelatedEntityType, RelatedEntityId)
        VALUES (@TemplateCode, @RecipientUserId, @email, @Subject, ISNULL(@Body, @Subject), @key, @RelatedEntityType, @RelatedEntityId);
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (2601, 2627) THROW;   -- lost a race with an identical key: fine
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE notify.usp_MarkRead @ActorUserId INT, @NotificationId BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Contractor,Customer,Recruiter,HRManager,Administrator';
    UPDATE notify.NotificationQueue SET IsRead = 1, ReadAt = SYSUTCDATETIME()
    WHERE RecipientUserId = @ActorUserId AND IsRead = 0 AND (@NotificationId IS NULL OR NotificationId = @NotificationId);
END
GO
