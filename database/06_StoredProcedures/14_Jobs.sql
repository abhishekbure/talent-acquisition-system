/* ============================================================================
   TAMS - 06_StoredProcedures / 14_Jobs.sql   (Phase 11)
   Database-side scheduled work, run by SQL Server Agent jobs (database/11_AgentJobs/01_Create_Agent_Jobs.sql).
   Every job procedure:
     * starts through sched.usp_JobBegin: one row in sched.JobExecutionHistory per run, and an exclusive application
       lock per job, so a second run while one is still going is recorded as "Skipped" and does nothing;
       a job switched off in sched.JobDefinitions (IsEnabled = 0) is also "Skipped";
     * logs what it did in sched.JobExecutionDetails;
     * ends through sched.usp_JobEnd with Succeeded / Failed, rows affected and the error text. A failure is re-raised,
       so the Agent job step fails and shows in Agent history too, and administrators get an in-app notification.
   These procedures are for the Agent (sysadmin) only: the application role is DENIED EXECUTE on them.
   Data jobs change statuses as the system, so audit rows show no TAMS user (ChangedByUserId NULL; DbUser = Agent).
   ========================================================================== */
USE TalentAcquisitionDB;
GO

/* ---------------- the Agent job catalogue (definitions shown on the admin Scheduled-jobs page) ---------------- */
MERGE sched.JobDefinitions AS t
USING (VALUES
 (N'TAMS - Expire stale requisitions',         N'Expire open jobs past their closing date and close job postings past theirs; tell the owning recruiter', N'Daily 01:00'),
 (N'TAMS - Detect contract expiry',            N'Mark contracts ending within 30 days Expiring, ended ones Expired (assignments and placements Completed)', N'Daily 01:15'),
 (N'TAMS - Purge notification queue',          N'Delete handled notifications and used sign-in tokens older than 90 days', N'Weekly Sun 02:00'),
 (N'TAMS - Prepare daily recruitment summary', N'Write today''s figures (IST day) to report.DailyRecruitmentSummary', N'Daily 23:30'),
 (N'TAMS - Full database backup',              N'Full backup with checksum and verification; deletes TAMS backups older than 14 days', N'Weekly Sun 03:00'),
 (N'TAMS - Differential database backup',      N'Differential backup (a full one when no TAMS full backup is the base yet)', N'Daily Mon-Sat 03:00'),
 (N'TAMS - Transaction log backup',            N'Log backup (the database uses the FULL recovery model)', N'Every 30 minutes'),
 (N'TAMS - Index maintenance',                 N'Reorganise indexes fragmented over 10 %, rebuild (online) over 30 %; indexes of 100+ pages', N'Weekly Sun 03:30'),
 (N'TAMS - Update statistics',                 N'Update statistics that changed since their last update', N'Daily 02:30')
) AS s (JobName, Description, ScheduleDescription)
ON t.JobName = s.JobName
WHEN MATCHED THEN UPDATE SET Description = s.Description, ScheduleDescription = s.ScheduleDescription, Owner = 'SqlAgent'
WHEN NOT MATCHED BY TARGET THEN INSERT (JobName, Owner, Description, ScheduleDescription) VALUES (s.JobName, 'SqlAgent', s.Description, s.ScheduleDescription);
GO

/* ---------------- run bookkeeping ---------------- */
-- Returns 0 = go ahead, 1 = skipped (already running elsewhere, or switched off). Always creates the history row.
CREATE OR ALTER PROCEDURE sched.usp_JobBegin @JobName NVARCHAR(100), @ExecutionId BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @def INT, @enabled BIT;
    SELECT @def = JobDefinitionId, @enabled = IsEnabled FROM sched.JobDefinitions WHERE JobName = @JobName AND Owner = 'SqlAgent';
    IF @def IS NULL THROW 50004, N'Unknown scheduled job.', 1;
    IF @enabled = 0
    BEGIN
        INSERT sched.JobExecutionHistory (JobDefinitionId, FinishedAt, Outcome, RowsAffected, ErrorMessage)
        VALUES (@def, SYSUTCDATETIME(), 'Skipped', 0, N'The job is switched off in sched.JobDefinitions.');
        SET @ExecutionId = SCOPE_IDENTITY(); RETURN 1;
    END
    DECLARE @rc INT;
    EXEC @rc = sp_getapplock @Resource = @JobName, @LockMode = 'Exclusive', @LockOwner = 'Session', @LockTimeout = 0;
    IF @rc < 0
    BEGIN
        INSERT sched.JobExecutionHistory (JobDefinitionId, FinishedAt, Outcome, RowsAffected, ErrorMessage)
        VALUES (@def, SYSUTCDATETIME(), 'Skipped', 0, N'Another run of this job is still in progress.');
        SET @ExecutionId = SCOPE_IDENTITY(); RETURN 1;
    END
    INSERT sched.JobExecutionHistory (JobDefinitionId) VALUES (@def);       -- Outcome 'Running'
    SET @ExecutionId = SCOPE_IDENTITY();
    RETURN 0;
END
GO

-- Failure reporting shared by SQL Agent jobs and the Task Scheduler console app: every active administrator gets an
-- in-app notification (and its e-mail copy), once per failed run.
CREATE OR ALTER PROCEDURE sched.usp_NotifyJobFailure @ExecutionId BIGINT, @JobName NVARCHAR(100), @Error NVARCHAR(2000)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @a INT, @subj NVARCHAR(300) = N'Scheduled job failed: ' + @JobName,
            @body NVARCHAR(MAX) = N'Run #' + CAST(@ExecutionId AS NVARCHAR(20)) + N' of "' + @JobName + N'" failed at ' + dbo.fn_BusinessTime(SYSUTCDATETIME())
                                 + N'.' + NCHAR(10) + N'Error: ' + ISNULL(LEFT(@Error, 1500), N'(none)') + NCHAR(10) + N'See Administrator > Scheduled jobs.';
    DECLARE adm CURSOR LOCAL FAST_FORWARD FOR
        SELECT u.UserId FROM sec.Users u WHERE u.IsActive = 1 AND sec.fn_UserHasRole(u.UserId, N'Administrator') = 1;
    OPEN adm; FETCH NEXT FROM adm INTO @a;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC notify.usp_Enqueue 'JOB_FAILED', @a, @subj, @body, N'JOBFAIL', 'JobExecution', @ExecutionId;
        FETCH NEXT FROM adm INTO @a;
    END
    CLOSE adm; DEALLOCATE adm;
END
GO
CREATE OR ALTER PROCEDURE sched.usp_JobLog @ExecutionId BIGINT, @Message NVARCHAR(1000), @Level VARCHAR(7) = 'Info'
AS
BEGIN
    SET NOCOUNT ON;
    INSERT sched.JobExecutionDetails (ExecutionId, Level, Message) VALUES (@ExecutionId, @Level, LEFT(@Message, 1000));
END
GO

CREATE OR ALTER PROCEDURE sched.usp_JobEnd @ExecutionId BIGINT, @JobName NVARCHAR(100), @Outcome VARCHAR(10), @RowsAffected INT, @Error NVARCHAR(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE sched.JobExecutionHistory SET FinishedAt = SYSUTCDATETIME(), Outcome = @Outcome, RowsAffected = @RowsAffected, ErrorMessage = LEFT(@Error, 2000)
    WHERE ExecutionId = @ExecutionId;
    IF APPLOCK_MODE('public', @JobName, 'Session') <> 'NoLock' EXEC sp_releaseapplock @Resource = @JobName, @LockOwner = 'Session';
    IF @Outcome = 'Failed' EXEC sched.usp_NotifyJobFailure @ExecutionId, @JobName, @Error;
END
GO

/* ============================== data jobs ============================== */
CREATE OR ALTER PROCEDURE sched.usp_Job_ExpireRequisitions @AsOf DATE = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @job NVARCHAR(100) = N'TAMS - Expire stale requisitions', @exec BIGINT, @rc INT, @rows INT = 0;
    DECLARE @logMsg NVARCHAR(1000);
    EXEC @rc = sched.usp_JobBegin @job, @exec OUTPUT;
    IF @rc <> 0 RETURN 0;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END, @sp BIT = 0;
    BEGIN TRY
        SET @AsOf = ISNULL(@AsOf, dbo.fn_BusinessToday());
        DECLARE @now DATETIME2(0) = SYSUTCDATETIME();
        DECLARE @jobs TABLE (JobRequisitionId INT PRIMARY KEY, JobCode NVARCHAR(30), Title NVARCHAR(150), Owner INT, ClosesBy DATE);
        DECLARE @posts TABLE (JobPostingId INT PRIMARY KEY);
        IF @own = 1 BEGIN TRANSACTION; ELSE BEGIN SAVE TRANSACTION sp_JobExpire; SET @sp = 1; END
        UPDATE rec.JobRequisitions SET Status = 'Expired', ClosedAt = @now, UpdatedAt = @now
        OUTPUT inserted.JobRequisitionId, inserted.JobCode, inserted.Title, inserted.OwnerRecruiterUserId, inserted.ClosesBy INTO @jobs
        WHERE Status IN ('Open', 'OnHold') AND ClosesBy < @AsOf;
        -- postings of expired jobs, and any posting whose own closing time has passed
        UPDATE p SET Status = 'Closed', ClosesAt = CASE WHEN p.ClosesAt IS NULL OR p.ClosesAt > @now THEN @now ELSE p.ClosesAt END
        OUTPUT inserted.JobPostingId INTO @posts
        FROM rec.JobPostings p
        WHERE p.Status = 'Published' AND (p.JobRequisitionId IN (SELECT JobRequisitionId FROM @jobs) OR p.ClosesAt < @now);
        IF @own = 1 COMMIT;

        SET @rows = (SELECT COUNT(*) FROM @jobs) + (SELECT COUNT(*) FROM @posts);
        DECLARE @id INT, @code NVARCHAR(30), @title NVARCHAR(150), @ownerId INT, @closes DATE, @open INT, @subj NVARCHAR(300), @body NVARCHAR(600);
        DECLARE j CURSOR LOCAL FAST_FORWARD FOR SELECT JobRequisitionId, JobCode, Title, Owner, ClosesBy FROM @jobs;
        OPEN j; FETCH NEXT FROM j INTO @id, @code, @title, @ownerId, @closes;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @open = (SELECT COUNT(*) FROM cand.JobApplications a JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId
                         WHERE p.JobRequisitionId = @id AND a.Status NOT IN ('Hired', 'Rejected', 'Withdrawn'));
            BEGIN SET @logMsg = N'Expired ' + @code + N' "' + @title + N'" (closing date ' + CONVERT(NVARCHAR(10), @closes, 120) + N'; ' + CAST(@open AS NVARCHAR(10)) + N' applications still open)'; EXEC sched.usp_JobLog @exec, @logMsg; END
            SELECT @subj = N'Job ' + @code + N' has expired', @body = N'"' + @title + N'" passed its closing date (' + CONVERT(NVARCHAR(10), @closes, 120)
                    + N') and was set to Expired; its posting no longer accepts applications. Applications still open: ' + CAST(@open AS NVARCHAR(10)) + N'.';
            EXEC notify.usp_Enqueue 'JOB_EXPIRED', @ownerId, @subj, @body, N'JOBEXP', 'JobRequisition', @id;
            FETCH NEXT FROM j INTO @id, @code, @title, @ownerId, @closes;
        END
        CLOSE j; DEALLOCATE j;
        IF (SELECT COUNT(*) FROM @posts) > 0 BEGIN SET @logMsg = N'Closed job postings: ' + (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @posts); EXEC sched.usp_JobLog @exec, @logMsg; END
        EXEC sched.usp_JobEnd @exec, @job, 'Succeeded', @rows;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND @sp = 1 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_JobExpire;   -- only a savepoint this run created
        DECLARE @err NVARCHAR(2000) = ERROR_MESSAGE();
        IF XACT_STATE() <> -1 EXEC sched.usp_JobEnd @exec, @job, 'Failed', 0, @err;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE sched.usp_Job_DetectContractExpiry @AsOf DATE = NULL, @WarningDays INT = 30
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @job NVARCHAR(100) = N'TAMS - Detect contract expiry', @exec BIGINT, @rc INT, @rows INT = 0;
    DECLARE @logMsg NVARCHAR(1000);
    EXEC @rc = sched.usp_JobBegin @job, @exec OUTPUT;
    IF @rc <> 0 RETURN 0;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END, @sp BIT = 0;
    BEGIN TRY
        IF @WarningDays IS NULL OR @WarningDays NOT BETWEEN 1 AND 365 THROW 50001, N'WarningDays must be between 1 and 365.', 1;
        SET @AsOf = ISNULL(@AsOf, dbo.fn_BusinessToday());
        DECLARE @now DATETIME2(0) = SYSUTCDATETIME();
        DECLARE @chg TABLE (ContractId INT, ContractNo NVARCHAR(30), OldStatus VARCHAR(12), NewStatus VARCHAR(12), EndDate DATE);
        IF @own = 1 BEGIN TRANSACTION; ELSE BEGIN SAVE TRANSACTION sp_JobContracts; SET @sp = 1; END
        -- ended: Expired, and their work ends with them
        UPDATE staff.Contracts SET Status = 'Expired', UpdatedAt = @now
        OUTPUT inserted.ContractId, inserted.ContractNo, deleted.Status, inserted.Status, inserted.EndDate INTO @chg
        WHERE Status IN ('Active', 'Expiring') AND EndDate < @AsOf;
        UPDATE staff.Assignments SET Status = 'Completed' WHERE Status = 'Active' AND ContractId IN (SELECT ContractId FROM @chg WHERE NewStatus = 'Expired');
        SET @rows += @@ROWCOUNT;
        UPDATE pl SET Status = 'Completed' FROM staff.Placements pl JOIN staff.Contracts ct ON ct.PlacementId = pl.PlacementId
        WHERE pl.Status = 'Active' AND ct.ContractId IN (SELECT ContractId FROM @chg WHERE NewStatus = 'Expired');
        SET @rows += @@ROWCOUNT;
        -- ending soon: Expiring
        UPDATE staff.Contracts SET Status = 'Expiring', UpdatedAt = @now
        OUTPUT inserted.ContractId, inserted.ContractNo, deleted.Status, inserted.Status, inserted.EndDate INTO @chg
        WHERE Status = 'Active' AND EndDate BETWEEN @AsOf AND DATEADD(DAY, @WarningDays, @AsOf);
        -- extended past the window again (a renewal moved the end date): back to Active
        UPDATE staff.Contracts SET Status = 'Active', UpdatedAt = @now
        OUTPUT inserted.ContractId, inserted.ContractNo, deleted.Status, inserted.Status, inserted.EndDate INTO @chg
        WHERE Status = 'Expiring' AND EndDate > DATEADD(DAY, @WarningDays, @AsOf);
        IF @own = 1 COMMIT;

        SET @rows += (SELECT COUNT(*) FROM @chg);
        DECLARE @msg NVARCHAR(400);
        DECLARE c CURSOR LOCAL FAST_FORWARD FOR
            SELECT ContractNo + N': ' + OldStatus + N' -> ' + NewStatus + N' (ends ' + CONVERT(NVARCHAR(10), EndDate, 120) + N')' FROM @chg ORDER BY EndDate;
        OPEN c; FETCH NEXT FROM c INTO @msg;
        WHILE @@FETCH_STATUS = 0 BEGIN EXEC sched.usp_JobLog @exec, @msg; FETCH NEXT FROM c INTO @msg; END
        CLOSE c; DEALLOCATE c;
        EXEC sched.usp_JobEnd @exec, @job, 'Succeeded', @rows;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND @sp = 1 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_JobContracts;   -- only a savepoint this run created
        DECLARE @err NVARCHAR(2000) = ERROR_MESSAGE();
        IF XACT_STATE() <> -1 EXEC sched.usp_JobEnd @exec, @job, 'Failed', 0, @err;
        THROW;
    END CATCH
END
GO

-- Handled notifications (sent, given up, cancelled) and used or expired sign-in tokens older than the retention period.
-- Messages still waiting to be sent are never deleted. Works in batches to keep transactions and locks short.
CREATE OR ALTER PROCEDURE sched.usp_Job_PurgeNotifications @RetentionDays INT = 90, @BatchSize INT = 5000
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @job NVARCHAR(100) = N'TAMS - Purge notification queue', @exec BIGINT, @rc INT, @rows INT = 0;
    DECLARE @logMsg NVARCHAR(1000);
    EXEC @rc = sched.usp_JobBegin @job, @exec OUTPUT;
    IF @rc <> 0 RETURN 0;
    DECLARE @own BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END, @sp BIT = 0;
    BEGIN TRY
        IF @RetentionDays IS NULL OR @RetentionDays < 7 THROW 50001, N'RetentionDays must be at least 7.', 1;
        IF @BatchSize IS NULL OR @BatchSize NOT BETWEEN 100 AND 50000 THROW 50001, N'BatchSize must be between 100 and 50000.', 1;
        DECLARE @cutoff DATETIME2(0) = DATEADD(DAY, -@RetentionDays, SYSUTCDATETIME());
        DECLARE @ids TABLE (NotificationId BIGINT PRIMARY KEY);
        DECLARE @n INT = 1, @msgs INT = 0, @hist INT = 0, @tok INT = 0;
        WHILE @n > 0
        BEGIN
            DELETE @ids;
            INSERT @ids SELECT TOP (@BatchSize) NotificationId FROM notify.NotificationQueue
            WHERE Status IN ('Sent', 'Failed', 'Cancelled') AND ProcessedAt < @cutoff ORDER BY NotificationId;
            SET @n = @@ROWCOUNT;
            IF @n > 0
            BEGIN
                IF @own = 1 BEGIN TRANSACTION; ELSE BEGIN SAVE TRANSACTION sp_JobPurge; SET @sp = 1; END
                DELETE h FROM notify.NotificationHistory h JOIN @ids i ON i.NotificationId = h.NotificationId; SET @hist += @@ROWCOUNT;
                DELETE q FROM notify.NotificationQueue q JOIN @ids i ON i.NotificationId = q.NotificationId; SET @msgs += @@ROWCOUNT;
                IF @own = 1 COMMIT; ELSE SET @sp = 0;
            END
        END
        IF @own = 1 BEGIN TRANSACTION; ELSE BEGIN SAVE TRANSACTION sp_JobPurge; SET @sp = 1; END
        DELETE FROM sec.PasswordResetTokens WHERE (UsedAt IS NOT NULL OR ExpiresAt < SYSUTCDATETIME()) AND CreatedAt < @cutoff; SET @tok += @@ROWCOUNT;
        DELETE FROM sec.EmailVerificationTokens WHERE (UsedAt IS NOT NULL OR ExpiresAt < SYSUTCDATETIME()) AND CreatedAt < @cutoff; SET @tok += @@ROWCOUNT;
        IF @own = 1 COMMIT;
        SET @rows = @msgs + @hist + @tok;
        BEGIN SET @logMsg = N'Older than ' + CONVERT(NVARCHAR(10), @cutoff, 120) + N': deleted ' + CAST(@msgs AS NVARCHAR(10)) + N' notifications, '
             + CAST(@hist AS NVARCHAR(10)) + N' delivery-history rows, ' + CAST(@tok AS NVARCHAR(10)) + N' used/expired sign-in tokens.'; EXEC sched.usp_JobLog @exec, @logMsg; END
        EXEC sched.usp_JobEnd @exec, @job, 'Succeeded', @rows;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() = -1 ROLLBACK TRANSACTION; ELSE IF @own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION; ELSE IF @own = 0 AND @sp = 1 AND XACT_STATE() = 1 ROLLBACK TRANSACTION sp_JobPurge;   -- only a savepoint this run created
        DECLARE @err NVARCHAR(2000) = ERROR_MESSAGE();
        IF XACT_STATE() <> -1 EXEC sched.usp_JobEnd @exec, @job, 'Failed', 0, @err;
        THROW;
    END CATCH
END
GO

-- One row per business day (IST). Re-running a day replaces its row (idempotent).
CREATE OR ALTER PROCEDURE sched.usp_Job_DailyRecruitmentSummary @SummaryDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT OFF;
    DECLARE @job NVARCHAR(100) = N'TAMS - Prepare daily recruitment summary', @exec BIGINT, @rc INT;
    DECLARE @logMsg NVARCHAR(1000);
    EXEC @rc = sched.usp_JobBegin @job, @exec OUTPUT;
    IF @rc <> 0 RETURN 0;
    BEGIN TRY
        SET @SummaryDate = ISNULL(@SummaryDate, dbo.fn_BusinessToday());
        IF @SummaryDate > dbo.fn_BusinessToday() THROW 50001, N'A summary cannot be prepared for a future day.', 1;
        -- the IST day as a UTC range
        DECLARE @f DATETIME2(0) = CAST((CAST(@SummaryDate AS DATETIME2(0)) AT TIME ZONE 'India Standard Time') AT TIME ZONE 'UTC' AS DATETIME2(0));
        DECLARE @t DATETIME2(0) = DATEADD(DAY, 1, @f);
        DECLARE @open INT = (SELECT COUNT(*) FROM rec.JobRequisitions WHERE Status = 'Open'),
                @apps INT = (SELECT COUNT(*) FROM cand.JobApplications WHERE AppliedAt >= @f AND AppliedAt < @t),
                @ivs INT = (SELECT COUNT(*) FROM cand.Interviews WHERE CreatedAt >= @f AND CreatedAt < @t),
                @sent INT = (SELECT COUNT(*) FROM cand.JobOffers WHERE SentAt >= @f AND SentAt < @t),
                @acc INT = (SELECT COUNT(*) FROM cand.JobOffers WHERE Status = 'Accepted' AND RespondedAt >= @f AND RespondedAt < @t),
                @ctr INT = (SELECT COUNT(DISTINCT a.ContractorId) FROM staff.Assignments a JOIN staff.Contractors k ON k.ContractorId = a.ContractorId
                            WHERE a.Status = 'Active' AND k.Status = 'Active'),
                @ts INT = (SELECT COUNT(*) FROM [time].Timesheets WHERE Status = 'Submitted');
        MERGE report.DailyRecruitmentSummary AS t
        USING (SELECT @SummaryDate AS SummaryDate) AS s ON t.SummaryDate = s.SummaryDate
        WHEN MATCHED THEN UPDATE SET OpenRequisitions = @open, NewApplications = @apps, InterviewsScheduled = @ivs, OffersExtended = @sent,
                                     OffersAccepted = @acc, ActiveContractors = @ctr, PendingTimesheets = @ts, GeneratedAt = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT (SummaryDate, OpenRequisitions, NewApplications, InterviewsScheduled, OffersExtended, OffersAccepted, ActiveContractors, PendingTimesheets)
             VALUES (@SummaryDate, @open, @apps, @ivs, @sent, @acc, @ctr, @ts);
        BEGIN SET @logMsg = N'Summary for ' + CONVERT(NVARCHAR(10), @SummaryDate, 120) + N' (IST): open jobs ' + CAST(@open AS NVARCHAR(10)) + N', new applications ' + CAST(@apps AS NVARCHAR(10))
             + N', interviews scheduled ' + CAST(@ivs AS NVARCHAR(10)) + N', offers sent ' + CAST(@sent AS NVARCHAR(10)) + N', accepted ' + CAST(@acc AS NVARCHAR(10))
             + N', active contractors ' + CAST(@ctr AS NVARCHAR(10)) + N', pending timesheets ' + CAST(@ts AS NVARCHAR(10)) + N'.'; EXEC sched.usp_JobLog @exec, @logMsg; END
        EXEC sched.usp_JobEnd @exec, @job, 'Succeeded', 1;
    END TRY
    BEGIN CATCH
        DECLARE @err NVARCHAR(2000) = ERROR_MESSAGE();
        IF XACT_STATE() <> -1 EXEC sched.usp_JobEnd @exec, @job, 'Failed', 0, @err;
        THROW;
    END CATCH
END
GO

/* ============================== maintenance jobs (cannot run inside a user transaction) ============================== */
-- FULL / DIFF / LOG backup of this database into {instance backup folder}\TAMS\{database}\, with CHECKSUM and COMPRESSION,
-- then RESTORE VERIFYONLY. A DIFF or LOG needs a full backup taken by this job as its base: when the newest full backup
-- of the database was taken by something else (or never), a FULL is taken instead, so the chain is always restorable
-- from these files. After a successful backup, TAMS backup files older than @RetentionDays are deleted from that folder.
-- Folder creation and clean-up use xp_create_subdir / xp_delete_file, the extended procedures SQL Server's own
-- maintenance plans use; xp_delete_file only removes SQL Server backup files.
CREATE OR ALTER PROCEDURE sched.usp_Job_BackupDatabase @BackupType VARCHAR(4) = 'FULL', @RetentionDays INT = 14, @RootDirectory NVARCHAR(260) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @job NVARCHAR(100) = CASE @BackupType WHEN 'DIFF' THEN N'TAMS - Differential database backup' WHEN 'LOG' THEN N'TAMS - Transaction log backup' ELSE N'TAMS - Full database backup' END;
    DECLARE @logMsg NVARCHAR(1000);
    DECLARE @exec BIGINT, @rc INT;
    EXEC @rc = sched.usp_JobBegin @job, @exec OUTPUT;
    IF @rc <> 0 RETURN 0;
    BEGIN TRY
        IF @@TRANCOUNT > 0 THROW 50002, N'A backup cannot run inside a transaction.', 1;
        IF @BackupType NOT IN ('FULL', 'DIFF', 'LOG') THROW 50001, N'BackupType must be FULL, DIFF or LOG.', 1;
        IF @RetentionDays IS NULL OR @RetentionDays < 2 THROW 50001, N'RetentionDays must be at least 2.', 1;
        DECLARE @db SYSNAME = DB_NAME();
        IF @RootDirectory IS NULL EXEC master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'BackupDirectory', @RootDirectory OUTPUT;
        IF @RootDirectory IS NULL OR @RootDirectory LIKE N'%''%' OR @RootDirectory LIKE N'%..%' THROW 50001, N'Invalid backup directory.', 1;
        DECLARE @dir NVARCHAR(400) = @RootDirectory + CASE WHEN RIGHT(@RootDirectory, 1) = N'\' THEN N'' ELSE N'\' END + N'TAMS\' + @db;
        EXEC master.dbo.xp_create_subdir @dir;

        DECLARE @type VARCHAR(4) = @BackupType;
        IF @type = 'LOG' AND (SELECT recovery_model_desc FROM sys.databases WHERE name = @db) = 'SIMPLE'
        BEGIN
            BEGIN SET @logMsg = N'The database uses the SIMPLE recovery model: no log backup is needed.'; EXEC sched.usp_JobLog @exec, @logMsg; END
            EXEC sched.usp_JobEnd @exec, @job, 'Succeeded', 0; RETURN 0;
        END
        IF @type IN ('DIFF', 'LOG')
        BEGIN
            DECLARE @lastFull NVARCHAR(128) = (SELECT TOP (1) name FROM msdb.dbo.backupset WHERE database_name = @db AND type = 'D' AND is_copy_only = 0 ORDER BY backup_finish_date DESC);
            IF @lastFull IS NULL OR @lastFull NOT LIKE N'TAMS FULL %'
            BEGIN
                BEGIN SET @logMsg = N'The newest full backup was not taken by this job, so a FULL backup is taken first to start a restorable chain.'; EXEC sched.usp_JobLog @exec, @logMsg, 'Warning'; END
                SET @type = 'FULL';
            END
        END
        DECLARE @stamp NVARCHAR(20) = FORMAT(SYSUTCDATETIME(), 'yyyyMMdd_HHmmss') + N'Z';
        DECLARE @file NVARCHAR(500) = @dir + N'\TAMS_' + @db + N'_' + @type + N'_' + @stamp + CASE @type WHEN 'LOG' THEN N'.trn' ELSE N'.bak' END;
        DECLARE @name NVARCHAR(128) = N'TAMS ' + @type + N' ' + @stamp;
        DECLARE @sql NVARCHAR(MAX) = CASE @type WHEN 'LOG' THEN N'BACKUP LOG ' ELSE N'BACKUP DATABASE ' END + QUOTENAME(@db) + N' TO DISK = @file WITH CHECKSUM, COMPRESSION, INIT, NAME = @name'
                                   + CASE @type WHEN 'DIFF' THEN N', DIFFERENTIAL' ELSE N'' END + N';';
        DECLARE @t0 DATETIME2(3) = SYSUTCDATETIME();
        EXEC sys.sp_executesql @sql, N'@file NVARCHAR(500), @name NVARCHAR(128)', @file, @name;
        RESTORE VERIFYONLY FROM DISK = @file WITH CHECKSUM;
        DECLARE @size DECIMAL(18,1) = (SELECT TOP (1) compressed_backup_size / 1048576.0 FROM msdb.dbo.backupset WHERE database_name = @db AND name = @name ORDER BY backup_set_id DESC);
        BEGIN SET @logMsg = N'Wrote and verified ' + @file + N' (' + CAST(@size AS NVARCHAR(20)) + N' MB compressed, ' + CAST(DATEDIFF(MILLISECOND, @t0, SYSUTCDATETIME()) AS NVARCHAR(12)) + N' ms).'; EXEC sched.usp_JobLog @exec, @logMsg; END

        DECLARE @cutoff NVARCHAR(19) = CONVERT(NVARCHAR(19), DATEADD(DAY, -@RetentionDays, GETDATE()), 126);
        EXEC master.dbo.xp_delete_file 0, @dir, N'bak', @cutoff, 0;
        EXEC master.dbo.xp_delete_file 0, @dir, N'trn', @cutoff, 0;
        BEGIN SET @logMsg = N'Removed TAMS backup files of this database older than ' + CAST(@RetentionDays AS NVARCHAR(10)) + N' days from ' + @dir + N'.'; EXEC sched.usp_JobLog @exec, @logMsg; END
        EXEC sched.usp_JobEnd @exec, @job, 'Succeeded', 1;
    END TRY
    BEGIN CATCH
        DECLARE @err NVARCHAR(2000) = ERROR_MESSAGE();
        EXEC sched.usp_JobEnd @exec, @job, 'Failed', 0, @err;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE sched.usp_Job_IndexMaintenance @ReorganizeAbovePct FLOAT = 10, @RebuildAbovePct FLOAT = 30, @MinPages INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @job NVARCHAR(100) = N'TAMS - Index maintenance', @exec BIGINT, @rc INT, @done INT = 0, @failed INT = 0;
    DECLARE @logMsg NVARCHAR(1000);
    EXEC @rc = sched.usp_JobBegin @job, @exec OUTPUT;
    IF @rc <> 0 RETURN 0;
    BEGIN TRY
        IF @@TRANCOUNT > 0 THROW 50002, N'Index maintenance cannot run inside a transaction.', 1;
        IF @ReorganizeAbovePct < 0 OR @RebuildAbovePct <= @ReorganizeAbovePct OR @MinPages < 0 THROW 50001, N'Invalid thresholds.', 1;
        DECLARE @w TABLE (Sch SYSNAME, Tbl SYSNAME, Idx SYSNAME, Frag FLOAT, Pages BIGINT);
        INSERT @w
        SELECT s.name, t.name, i.name, ps.avg_fragmentation_in_percent, ps.page_count
        FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ps
        JOIN sys.indexes i ON i.object_id = ps.object_id AND i.index_id = ps.index_id
        JOIN sys.tables t ON t.object_id = i.object_id JOIN sys.schemas s ON s.schema_id = t.schema_id
        WHERE ps.index_id > 0 AND ps.alloc_unit_type_desc = 'IN_ROW_DATA' AND i.is_disabled = 0 AND i.is_hypothetical = 0
          AND ps.page_count >= @MinPages AND ps.avg_fragmentation_in_percent > @ReorganizeAbovePct;
        BEGIN SET @logMsg = N'Indexes above the thresholds: ' + (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM @w) + N' (of '
             + (SELECT CAST(COUNT(*) AS NVARCHAR(10)) FROM sys.indexes i JOIN sys.tables t ON t.object_id = i.object_id WHERE i.index_id > 0) + N' indexes; minimum ' + CAST(@MinPages AS NVARCHAR(10)) + N' pages).'; EXEC sched.usp_JobLog @exec, @logMsg; END
        DECLARE @s SYSNAME, @tb SYSNAME, @ix SYSNAME, @frag FLOAT, @pages BIGINT, @sql NVARCHAR(1000), @act NVARCHAR(20);
        DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT Sch, Tbl, Idx, Frag, Pages FROM @w ORDER BY Pages DESC;
        OPEN c; FETCH NEXT FROM c INTO @s, @tb, @ix, @frag, @pages;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @act = CASE WHEN @frag > @RebuildAbovePct THEN N'REBUILD' ELSE N'REORGANIZE' END;
            SET @sql = N'ALTER INDEX ' + QUOTENAME(@ix) + N' ON ' + QUOTENAME(@s) + N'.' + QUOTENAME(@tb) + N' '
                     + CASE @act WHEN N'REBUILD' THEN N'REBUILD WITH (ONLINE = ON, SORT_IN_TEMPDB = ON)' ELSE N'REORGANIZE' END + N';';
            BEGIN TRY
                EXEC sys.sp_executesql @sql; SET @done += 1;
                SET @logMsg = @act + N' ' + @s + N'.' + @tb + N'.' + @ix + N' (' + CAST(CAST(@frag AS DECIMAL(5,1)) AS NVARCHAR(10)) + N' % fragmented, ' + CAST(@pages AS NVARCHAR(20)) + N' pages)'; EXEC sched.usp_JobLog @exec, @logMsg;
            END TRY
            BEGIN CATCH
                SET @failed += 1;
                SET @logMsg = @act + N' failed for ' + @s + N'.' + @tb + N'.' + @ix + N': ' + ERROR_MESSAGE(); EXEC sched.usp_JobLog @exec, @logMsg, 'Error';
            END CATCH
            FETCH NEXT FROM c INTO @s, @tb, @ix, @frag, @pages;
        END
        CLOSE c; DEALLOCATE c;
        IF @failed > 0 THROW 50002, N'Some indexes could not be maintained; see the run details.', 1;
        EXEC sched.usp_JobEnd @exec, @job, 'Succeeded', @done;
    END TRY
    BEGIN CATCH
        DECLARE @err NVARCHAR(2000) = ERROR_MESSAGE();
        EXEC sched.usp_JobEnd @exec, @job, 'Failed', @done, @err;
        THROW;
    END CATCH
END
GO

-- Statistics whose table changed since they were last updated: full scan up to @FullScanMaxRows rows, sampled above.
CREATE OR ALTER PROCEDURE sched.usp_Job_UpdateStatistics @FullScanMaxRows BIGINT = 1000000
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @job NVARCHAR(100) = N'TAMS - Update statistics', @exec BIGINT, @rc INT, @done INT = 0;
    DECLARE @logMsg NVARCHAR(1000);
    EXEC @rc = sched.usp_JobBegin @job, @exec OUTPUT;
    IF @rc <> 0 RETURN 0;
    BEGIN TRY
        IF @@TRANCOUNT > 0 THROW 50002, N'Statistics maintenance cannot run inside a transaction.', 1;
        DECLARE @w TABLE (Sch SYSNAME, Tbl SYSNAME, St SYSNAME, RowsN BIGINT, Mods BIGINT);
        INSERT @w
        SELECT s.name, t.name, st.name, sp.rows, sp.modification_counter
        FROM sys.stats st
        JOIN sys.tables t ON t.object_id = st.object_id JOIN sys.schemas s ON s.schema_id = t.schema_id
        CROSS APPLY sys.dm_db_stats_properties(st.object_id, st.stats_id) sp
        WHERE t.is_ms_shipped = 0 AND sp.modification_counter > 0;
        DECLARE @s SYSNAME, @tb SYSNAME, @stn SYSNAME, @rowsN BIGINT, @mods BIGINT, @sql NVARCHAR(1000);
        DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT Sch, Tbl, St, RowsN, Mods FROM @w ORDER BY Sch, Tbl, St;
        OPEN c; FETCH NEXT FROM c INTO @s, @tb, @stn, @rowsN, @mods;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @sql = N'UPDATE STATISTICS ' + QUOTENAME(@s) + N'.' + QUOTENAME(@tb) + N' ' + QUOTENAME(@stn) + CASE WHEN @rowsN <= @FullScanMaxRows THEN N' WITH FULLSCAN' ELSE N'' END + N';';
            EXEC sys.sp_executesql @sql; SET @done += 1;
            FETCH NEXT FROM c INTO @s, @tb, @stn, @rowsN, @mods;
        END
        CLOSE c; DEALLOCATE c;
        BEGIN SET @logMsg = N'Updated ' + CAST(@done AS NVARCHAR(10)) + N' statistics on ' + (SELECT CAST(COUNT(DISTINCT Sch + N'.' + Tbl) AS NVARCHAR(10)) FROM @w)
             + N' tables (' + ISNULL((SELECT CAST(SUM(Mods) AS NVARCHAR(20)) FROM @w), N'0') + N' row modifications since the previous update).'; EXEC sched.usp_JobLog @exec, @logMsg; END
        EXEC sched.usp_JobEnd @exec, @job, 'Succeeded', @done;
    END TRY
    BEGIN CATCH
        DECLARE @err NVARCHAR(2000) = ERROR_MESSAGE();
        EXEC sched.usp_JobEnd @exec, @job, 'Failed', @done, @err;
        THROW;
    END CATCH
END
GO

/* ---------------- administration (read) ---------------- */
CREATE OR ALTER PROCEDURE sched.usp_ListJobRunDetails @ActorUserId INT, @ExecutionId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Administrator';
    IF NOT EXISTS (SELECT 1 FROM sched.JobExecutionHistory WHERE ExecutionId = @ExecutionId) THROW 50004, N'Job run not found.', 1;
    SELECT DetailId, Level, Message, LoggedAt FROM sched.JobExecutionDetails WHERE ExecutionId = @ExecutionId ORDER BY DetailId;
END
GO

/* ---------------- least privilege: the application never runs scheduled work ---------------- */
DENY EXECUTE ON sched.usp_JobBegin TO tams_app_role;
DENY EXECUTE ON sched.usp_JobLog TO tams_app_role;
DENY EXECUTE ON sched.usp_JobEnd TO tams_app_role;
DENY EXECUTE ON sched.usp_NotifyJobFailure TO tams_app_role;   -- reached only through usp_JobEnd / usp_AppTaskEnd (ownership chaining)
DENY EXECUTE ON sched.usp_Job_ExpireRequisitions TO tams_app_role;
DENY EXECUTE ON sched.usp_Job_DetectContractExpiry TO tams_app_role;
DENY EXECUTE ON sched.usp_Job_PurgeNotifications TO tams_app_role;
DENY EXECUTE ON sched.usp_Job_DailyRecruitmentSummary TO tams_app_role;
DENY EXECUTE ON sched.usp_Job_BackupDatabase TO tams_app_role;
DENY EXECUTE ON sched.usp_Job_IndexMaintenance TO tams_app_role;
DENY EXECUTE ON sched.usp_Job_UpdateStatistics TO tams_app_role;
GO
