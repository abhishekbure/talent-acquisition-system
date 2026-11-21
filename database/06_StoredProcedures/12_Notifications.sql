/* ============================================================================
   TAMS - 06_StoredProcedures / 12_Notifications.sql   (Phase 9)
   Delivery of notify.NotificationQueue by a worker (TalentAcquisition.Scheduler process-notifications):
     claim (lease) -> send -> mark sent | mark failed (retry with back-off, give up after MaxAttempts).
   * Several workers may run at once: a claim takes rows with UPDLOCK + READPAST, so no row is handed to two workers.
   * A claimed row is leased: NextAttemptAt holds the lease expiry. A worker that dies leaves the row 'Processing';
     the next claim after the lease expires records the lost attempt and makes the row due again.
   * Mark-sent / mark-failed only apply to the attempt the worker was given (Status 'Processing' AND Attempts = @AttemptNo),
     so a worker whose lease was taken over cannot overwrite the newer attempt's outcome.
   * Delivery is at-least-once: a worker that hangs past its lease and then sends anyway can duplicate one e-mail.
   * Bodies of security messages (notify.fn_IsSecurityTemplate: one-time sign-in links) are erased once the message is
     sent, given up or cancelled (KI-021).
   ========================================================================== */
USE TalentAcquisitionDB;
GO

CREATE OR ALTER PROCEDURE notify.usp_ClaimBatch @BatchSize INT = 20, @LeaseSeconds INT = 300
AS
BEGIN
    SET NOCOUNT ON;
    IF @BatchSize IS NULL OR @BatchSize NOT BETWEEN 1 AND 500 THROW 50001, N'BatchSize must be between 1 and 500.', 1;
    IF @LeaseSeconds IS NULL OR @LeaseSeconds NOT BETWEEN 30 AND 3600 THROW 50001, N'LeaseSeconds must be between 30 and 3600.', 1;
    SET XACT_ABORT ON;
    DECLARE @now DATETIME2(0) = SYSUTCDATETIME();
    DECLARE @removed NVARCHAR(200) = N'[Removed: this message contained a one-time link and is no longer stored.]';
    DECLARE @lost TABLE (NotificationId BIGINT PRIMARY KEY, AttemptNo INT NOT NULL);
    DECLARE @claimed TABLE (NotificationId BIGINT PRIMARY KEY);

    BEGIN TRANSACTION;
    -- 1. leases that ran out: the attempt is lost; retry at once, or give up if the attempts are used up
    UPDATE q SET Status        = CASE WHEN q.Attempts >= q.MaxAttempts THEN 'Failed' ELSE 'Pending' END,
                 NextAttemptAt = @now,
                 ProcessedAt   = CASE WHEN q.Attempts >= q.MaxAttempts THEN @now END,
                 Body          = CASE WHEN q.Attempts >= q.MaxAttempts AND notify.fn_IsSecurityTemplate(q.TemplateCode) = 1 THEN @removed ELSE q.Body END
    OUTPUT inserted.NotificationId, inserted.Attempts INTO @lost
    FROM notify.NotificationQueue q WITH (UPDLOCK, READPAST, ROWLOCK)
    WHERE q.Status = 'Processing' AND q.NextAttemptAt <= @now;
    INSERT notify.NotificationHistory (NotificationId, AttemptNo, Outcome, ErrorMessage)
    SELECT NotificationId, AttemptNo, 'Failed', N'The worker did not report back before its lease expired.' FROM @lost;

    -- 2. recipients deactivated after the message was queued are not contacted
    UPDATE q SET Status = 'Cancelled', ProcessedAt = @now,
                 Body = CASE WHEN notify.fn_IsSecurityTemplate(q.TemplateCode) = 1 THEN @removed ELSE q.Body END
    FROM notify.NotificationQueue q WITH (UPDLOCK, READPAST, ROWLOCK)
    JOIN sec.Users u ON u.UserId = q.RecipientUserId
    WHERE q.Status = 'Pending' AND q.NextAttemptAt <= @now AND u.IsActive = 0;

    -- 3. claim the oldest due messages
    WITH due AS (
        SELECT TOP (@BatchSize) q.Status, q.Attempts, q.NextAttemptAt, q.NotificationId
        FROM notify.NotificationQueue q WITH (UPDLOCK, READPAST, ROWLOCK)
        WHERE q.Status = 'Pending' AND q.NextAttemptAt <= @now AND q.Attempts < q.MaxAttempts
        ORDER BY q.NextAttemptAt, q.NotificationId)
    UPDATE due SET Status = 'Processing', Attempts = Attempts + 1, NextAttemptAt = DATEADD(SECOND, @LeaseSeconds, @now)
    OUTPUT inserted.NotificationId INTO @claimed;
    COMMIT;

    SELECT q.NotificationId, q.Attempts AS AttemptNo, q.MaxAttempts, q.TemplateCode, q.ToEmail, u.DisplayName AS RecipientName,
           q.Subject, q.Body, q.RelatedEntityType, q.RelatedEntityId, q.CreatedAt
    FROM @claimed c
    JOIN notify.NotificationQueue q ON q.NotificationId = c.NotificationId
    LEFT JOIN sec.Users u ON u.UserId = q.RecipientUserId
    ORDER BY q.NotificationId;
END
GO

-- Returns Updated = 1 when the outcome was recorded, 0 when this attempt no longer owns the row.
CREATE OR ALTER PROCEDURE notify.usp_MarkSent @NotificationId BIGINT, @AttemptNo INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @n INT;
    BEGIN TRANSACTION;
    UPDATE notify.NotificationQueue
       SET Status = 'Sent', ProcessedAt = SYSUTCDATETIME(),
           Body = CASE WHEN notify.fn_IsSecurityTemplate(TemplateCode) = 1 THEN N'[Removed after delivery: this message contained a one-time link.]' ELSE Body END
     WHERE NotificationId = @NotificationId AND Status = 'Processing' AND Attempts = @AttemptNo;
    SET @n = @@ROWCOUNT;
    IF @n = 1 INSERT notify.NotificationHistory (NotificationId, AttemptNo, Outcome) VALUES (@NotificationId, @AttemptNo, 'Sent');
    COMMIT;
    SELECT @n AS Updated;
END
GO

-- Back-off after failed attempt n: 2^(n-1) minutes (1, 2, 4, 8 ...), at most 60. After MaxAttempts the message is Failed.
CREATE OR ALTER PROCEDURE notify.usp_MarkFailed @NotificationId BIGINT, @AttemptNo INT, @Error NVARCHAR(1000)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @now DATETIME2(0) = SYSUTCDATETIME();
    DECLARE @out TABLE (Status VARCHAR(12), NextAttemptAt DATETIME2(0));
    BEGIN TRANSACTION;
    UPDATE notify.NotificationQueue
       SET Status        = CASE WHEN Attempts >= MaxAttempts THEN 'Failed' ELSE 'Pending' END,
           NextAttemptAt = CASE WHEN Attempts >= MaxAttempts THEN @now
                                ELSE DATEADD(MINUTE, CASE WHEN Attempts >= 7 THEN 60 ELSE POWER(2, Attempts - 1) END, @now) END,
           ProcessedAt   = CASE WHEN Attempts >= MaxAttempts THEN @now END,
           Body          = CASE WHEN Attempts >= MaxAttempts AND notify.fn_IsSecurityTemplate(TemplateCode) = 1
                                THEN N'[Removed: this message contained a one-time link and could not be delivered.]' ELSE Body END
    OUTPUT inserted.Status, inserted.NextAttemptAt INTO @out
     WHERE NotificationId = @NotificationId AND Status = 'Processing' AND Attempts = @AttemptNo;
    IF @@ROWCOUNT = 1
        INSERT notify.NotificationHistory (NotificationId, AttemptNo, Outcome, ErrorMessage)
        VALUES (@NotificationId, @AttemptNo, 'Failed', LEFT(ISNULL(NULLIF(LTRIM(@Error), N''), N'Unknown error'), 1000));
    COMMIT;
    SELECT CAST(CASE WHEN EXISTS (SELECT 1 FROM @out) THEN 1 ELSE 0 END AS INT) AS Updated, Status, NextAttemptAt FROM (SELECT 1 x) one LEFT JOIN @out o ON 1 = 1;
END
GO

/* ---------------- administration ---------------- */
CREATE OR ALTER PROCEDURE notify.usp_ListQueue
    @ActorUserId INT, @Status VARCHAR(12) = NULL, @Q NVARCHAR(100) = NULL, @Page INT = 1, @PageSize INT = 25
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Administrator';
    IF @Page < 1 SET @Page = 1; IF @PageSize < 1 OR @PageSize > 200 SET @PageSize = 25;
    -- no bodies here: they can hold personal details and one-time links
    SELECT q.NotificationId, q.TemplateCode, q.ToEmail, u.DisplayName AS RecipientName, q.Subject, q.Status, q.Attempts, q.MaxAttempts,
           q.NextAttemptAt, q.CreatedAt, q.ProcessedAt, q.RelatedEntityType, q.RelatedEntityId,
           CAST(notify.fn_IsSecurityTemplate(q.TemplateCode) AS BIT) AS IsSecurity,
           h.ErrorMessage AS LastError, h.AttemptedAt AS LastAttemptAt,
           COUNT(*) OVER () AS TotalCount
    FROM notify.NotificationQueue q
    LEFT JOIN sec.Users u ON u.UserId = q.RecipientUserId
    OUTER APPLY (SELECT TOP (1) x.ErrorMessage, x.AttemptedAt FROM notify.NotificationHistory x WHERE x.NotificationId = q.NotificationId ORDER BY x.HistoryId DESC) h
    WHERE (@Status IS NULL OR q.Status = @Status)
      AND (@Q IS NULL OR q.ToEmail LIKE N'%' + @Q + N'%' OR q.Subject LIKE N'%' + @Q + N'%' OR q.TemplateCode LIKE N'%' + @Q + N'%')
    ORDER BY q.NotificationId DESC OFFSET (@Page - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

CREATE OR ALTER PROCEDURE notify.usp_ListDeliveryHistory @ActorUserId INT, @NotificationId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Administrator';
    IF NOT EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE NotificationId = @NotificationId) THROW 50004, N'Notification not found.', 1;
    SELECT HistoryId, AttemptNo, Outcome, ErrorMessage, AttemptedAt FROM notify.NotificationHistory WHERE NotificationId = @NotificationId ORDER BY HistoryId;
END
GO

-- Administrator: a Failed or Cancelled message is queued again with fresh attempts. Security messages cannot be re-sent
-- (their link is gone or stale); the person asks for a new link instead.
CREATE OR ALTER PROCEDURE notify.usp_RetryNotification @ActorUserId INT, @NotificationId BIGINT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_RetryNotif; END
        EXEC sec.usp_Authorize @ActorUserId, N'Administrator';
        DECLARE @status VARCHAR(12), @tpl VARCHAR(40), @active BIT;
        SELECT @status = q.Status, @tpl = q.TemplateCode, @active = u.IsActive
        FROM notify.NotificationQueue q WITH (UPDLOCK, HOLDLOCK) LEFT JOIN sec.Users u ON u.UserId = q.RecipientUserId
        WHERE q.NotificationId = @NotificationId;
        IF @status IS NULL THROW 50004, N'Notification not found.', 1;
        IF @status NOT IN ('Failed', 'Cancelled') THROW 50002, N'Only a Failed or Cancelled notification can be sent again.', 1;
        IF notify.fn_IsSecurityTemplate(@tpl) = 1 THROW 50002, N'Sign-in links are never re-sent; the person can ask for a new link.', 1;
        IF ISNULL(@active, 0) = 0 THROW 50002, N'The recipient''s account is inactive.', 1;
        UPDATE notify.NotificationQueue SET Status = 'Pending', Attempts = 0, NextAttemptAt = SYSUTCDATETIME(), ProcessedAt = NULL WHERE NotificationId = @NotificationId;
        INSERT audit.AuditLogs (TableName, RecordId, Action, OldValues, NewValues, ChangedByUserId)
        VALUES (N'notify.NotificationQueue', CAST(@NotificationId AS NVARCHAR(50)), 'U', N'<row><Status>' + @status + N'</Status></row>', N'<row><Status>Pending</Status><Attempts>0</Attempts></row>', @ActorUserId);
        IF @own = 1 COMMIT;
        SELECT NotificationId, Status, Attempts, NextAttemptAt FROM notify.NotificationQueue WHERE NotificationId = @NotificationId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_RetryNotif;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE notify.usp_CancelNotification @ActorUserId INT, @NotificationId BIGINT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    BEGIN TRY
        IF @own = 1 BEGIN BEGIN TRANSACTION; END ELSE BEGIN SAVE TRANSACTION sp_CancelNotif; END
        EXEC sec.usp_Authorize @ActorUserId, N'Administrator';
        DECLARE @status VARCHAR(12);
        SELECT @status = Status FROM notify.NotificationQueue WITH (UPDLOCK, HOLDLOCK) WHERE NotificationId = @NotificationId;
        IF @status IS NULL THROW 50004, N'Notification not found.', 1;
        IF @status <> 'Pending' THROW 50002, N'Only a Pending notification can be cancelled (one being sent right now cannot).', 1;
        UPDATE notify.NotificationQueue
           SET Status = 'Cancelled', ProcessedAt = SYSUTCDATETIME(),
               Body = CASE WHEN notify.fn_IsSecurityTemplate(TemplateCode) = 1 THEN N'[Removed: this message contained a one-time link and was cancelled.]' ELSE Body END
         WHERE NotificationId = @NotificationId;
        INSERT audit.AuditLogs (TableName, RecordId, Action, OldValues, NewValues, ChangedByUserId)
        VALUES (N'notify.NotificationQueue', CAST(@NotificationId AS NVARCHAR(50)), 'U', N'<row><Status>Pending</Status></row>', N'<row><Status>Cancelled</Status></row>', @ActorUserId);
        IF @own = 1 COMMIT;
        SELECT NotificationId, Status FROM notify.NotificationQueue WHERE NotificationId = @NotificationId;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_CancelNotif;
        THROW;
    END CATCH
END
GO