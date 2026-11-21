/* ============================================================================
   TAMS - 12_Tests / 08_Job_Tests.sql        (Phase 11)
   The data-changing job procedures (expire requisitions, contract expiry, purge, daily summary), the run bookkeeping
   (history, details, Skipped when switched off, failure reporting) and least privilege. Runs in a transaction that is
   rolled back. Backups, index and statistics maintenance cannot run inside a transaction: they are proved through real
   SQL Server Agent runs by scripts/testing/Test-AgentJobs.ps1 (this suite only checks that they refuse a transaction).
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;
DECLARE @r TABLE (Id INT IDENTITY(1,1), Name NVARCHAR(240), Ok BIT, Detail NVARCHAR(400));
DECLARE @e INT, @e2 INT, @n INT, @m NVARCHAR(400), @ex BIGINT;
DECLARE @admin INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ADMIN@TAMS.LOCAL'),
        @priya INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'PRIYA.MENON@TAMS.LOCAL'),
        @divya INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'DIVYA.REDDY@CANDIDATE.EXAMPLE');
DECLARE @today DATE = dbo.fn_BusinessToday();
DECLARE @histBefore BIGINT = ISNULL((SELECT MAX(ExecutionId) FROM sched.JobExecutionHistory), 0);
DECLARE @tag NVARCHAR(20) = LEFT(REPLACE(CONVERT(NVARCHAR(36), NEWID()), N'-', N''), 10);

BEGIN TRANSACTION;

/* ============================== EXPIRE STALE REQUISITIONS ============================== */
DECLARE @job1 INT = (SELECT TOP (1) JobRequisitionId FROM rec.JobRequisitions WHERE Status = 'Open' ORDER BY JobRequisitionId),
        @job2 INT = (SELECT TOP (1) JobRequisitionId FROM rec.JobRequisitions WHERE Status = 'Open' ORDER BY JobRequisitionId DESC);
UPDATE rec.JobRequisitions SET ClosesBy = DATEADD(DAY, -1, @today) WHERE JobRequisitionId = @job1;
UPDATE rec.JobRequisitions SET ClosesBy = @today WHERE JobRequisitionId = @job2;
UPDATE rec.JobPostings SET Status = 'Published', ClosesAt = NULL WHERE JobRequisitionId = @job1;
EXEC sched.usp_Job_ExpireRequisitions;
SET @ex = (SELECT MAX(h.ExecutionId) FROM sched.JobExecutionHistory h JOIN sched.JobDefinitions d ON d.JobDefinitionId = h.JobDefinitionId WHERE d.JobName = N'TAMS - Expire stale requisitions');
INSERT @r VALUES (N'J01 a job past its closing date is Expired and its posting closed; a job closing today stays open (dates are IST business days)',
    IIF(@job1 <> @job2 AND (SELECT Status FROM rec.JobRequisitions WHERE JobRequisitionId = @job1) = 'Expired' AND (SELECT ClosedAt FROM rec.JobRequisitions WHERE JobRequisitionId = @job1) IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM rec.JobPostings WHERE JobRequisitionId = @job1 AND Status = 'Published')
        AND (SELECT Status FROM rec.JobRequisitions WHERE JobRequisitionId = @job2) = 'Open', 1, 0),
    CONCAT(N'job1=', (SELECT Status FROM rec.JobRequisitions WHERE JobRequisitionId = @job1), N' job2=', (SELECT Status FROM rec.JobRequisitions WHERE JobRequisitionId = @job2)));
INSERT @r VALUES (N'J02 the run is recorded (Succeeded, rows affected, details naming the job) and the owning recruiter is told',
    IIF(EXISTS (SELECT 1 FROM sched.JobExecutionHistory WHERE ExecutionId = @ex AND Outcome = 'Succeeded' AND RowsAffected >= 2 AND FinishedAt IS NOT NULL)
        AND EXISTS (SELECT 1 FROM sched.JobExecutionDetails WHERE ExecutionId = @ex AND Message LIKE N'Expired ' + (SELECT JobCode FROM rec.JobRequisitions WHERE JobRequisitionId = @job1) + N'%')
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE TemplateCode = 'JOB_EXPIRED' AND RelatedEntityId = @job1
                    AND RecipientUserId = (SELECT OwnerRecruiterUserId FROM rec.JobRequisitions WHERE JobRequisitionId = @job1)), 1, 0),
    CONCAT(N'rows=', (SELECT RowsAffected FROM sched.JobExecutionHistory WHERE ExecutionId = @ex)));
EXEC sched.usp_Job_ExpireRequisitions;
INSERT @r VALUES (N'J03 running it again changes nothing (idempotent)',
    IIF((SELECT RowsAffected FROM sched.JobExecutionHistory WHERE ExecutionId = (SELECT MAX(ExecutionId) FROM sched.JobExecutionHistory)) = 0, 1, 0), N'');

/* ============================== CONTRACT EXPIRY ============================== */
DECLARE @k1 INT = (SELECT ContractId FROM staff.Contracts WHERE ContractNo LIKE N'CON-%-001'),
        @k2 INT = (SELECT ContractId FROM staff.Contracts WHERE ContractNo LIKE N'CON-%-002');
UPDATE staff.Contracts SET Status = 'Active', EndDate = DATEADD(DAY, -1, @today) WHERE ContractId = @k1;
UPDATE staff.Contracts SET Status = 'Active', EndDate = DATEADD(DAY, 10, @today) WHERE ContractId = @k2;
UPDATE staff.Assignments SET Status = 'Active' WHERE ContractId = @k1;
EXEC sched.usp_Job_DetectContractExpiry;
SET @ex = (SELECT MAX(ExecutionId) FROM sched.JobExecutionHistory);
INSERT @r VALUES (N'J04 a contract that ended is Expired and its assignment and placement Completed; one ending within 30 days is Expiring',
    IIF((SELECT Status FROM staff.Contracts WHERE ContractId = @k1) = 'Expired' AND (SELECT Status FROM staff.Contracts WHERE ContractId = @k2) = 'Expiring'
        AND NOT EXISTS (SELECT 1 FROM staff.Assignments WHERE ContractId = @k1 AND Status = 'Active')
        AND (SELECT pl.Status FROM staff.Placements pl JOIN staff.Contracts ct ON ct.PlacementId = pl.PlacementId WHERE ct.ContractId = @k1) = 'Completed'
        AND (SELECT COUNT(*) FROM sched.JobExecutionDetails WHERE ExecutionId = @ex AND (Message LIKE N'%-> Expired%' OR Message LIKE N'%-> Expiring%')) >= 2, 1, 0),
    CONCAT(N'k1=', (SELECT Status FROM staff.Contracts WHERE ContractId = @k1), N' k2=', (SELECT Status FROM staff.Contracts WHERE ContractId = @k2)));
UPDATE staff.Contracts SET EndDate = DATEADD(DAY, 200, @today) WHERE ContractId = @k2;      -- renewed
EXEC sched.usp_Job_DetectContractExpiry;
INSERT @r VALUES (N'J05 an Expiring contract whose end date moved beyond the window (renewal) returns to Active; audit rows are written',
    IIF((SELECT Status FROM staff.Contracts WHERE ContractId = @k2) = 'Active'
        AND EXISTS (SELECT 1 FROM audit.AuditLogs WHERE TableName = N'staff.Contracts' AND RecordId = CAST(@k2 AS NVARCHAR(50)) AND NewValues LIKE N'%Expiring%'), 1, 0),
    (SELECT Status FROM staff.Contracts WHERE ContractId = @k2));
SET @e = 0; BEGIN TRY EXEC sched.usp_Job_DetectContractExpiry @WarningDays = 0; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'J06 a bad parameter fails the run (re-raised for Agent), records the error and notifies every administrator',
    IIF(@e = 50001 AND EXISTS (SELECT 1 FROM sched.JobExecutionHistory WHERE ExecutionId = (SELECT MAX(ExecutionId) FROM sched.JobExecutionHistory)
                                AND Outcome = 'Failed' AND ErrorMessage LIKE N'%WarningDays%')
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE TemplateCode = 'JOB_FAILED' AND RecipientUserId = @admin
                    AND RelatedEntityId = (SELECT MAX(ExecutionId) FROM sched.JobExecutionHistory) AND Body LIKE N'%WarningDays%'), 1, 0), CONCAT(N'err=', @e));

/* ============================== PURGE ============================== */
EXEC notify.usp_Enqueue 'TEST_NOTE', @divya, N'old sent', N'x', N'PJ1', 'Test', 1;
EXEC notify.usp_Enqueue 'TEST_NOTE', @divya, N'recent sent', N'x', N'PJ2', 'Test', 2;
EXEC notify.usp_Enqueue 'TEST_NOTE', @divya, N'old waiting', N'x', N'PJ3', 'Test', 3;
DECLARE @p1 BIGINT = (SELECT NotificationId FROM notify.NotificationQueue WHERE DedupeKey LIKE N'PJ1|%'),
        @p2 BIGINT = (SELECT NotificationId FROM notify.NotificationQueue WHERE DedupeKey LIKE N'PJ2|%'),
        @p3 BIGINT = (SELECT NotificationId FROM notify.NotificationQueue WHERE DedupeKey LIKE N'PJ3|%');
UPDATE notify.NotificationQueue SET Status = 'Sent', Attempts = 1, ProcessedAt = DATEADD(DAY, -120, SYSUTCDATETIME()) WHERE NotificationId = @p1;
UPDATE notify.NotificationQueue SET Status = 'Sent', Attempts = 1, ProcessedAt = DATEADD(DAY, -5, SYSUTCDATETIME()) WHERE NotificationId = @p2;
UPDATE notify.NotificationQueue SET CreatedAt = DATEADD(DAY, -120, SYSUTCDATETIME()), NextAttemptAt = '9999-12-31' WHERE NotificationId = @p3;
INSERT notify.NotificationHistory (NotificationId, AttemptNo, Outcome, AttemptedAt) VALUES (@p1, 1, 'Sent', DATEADD(DAY, -120, SYSUTCDATETIME())), (@p2, 1, 'Sent', SYSUTCDATETIME());
INSERT sec.PasswordResetTokens (UserId, TokenHash, ExpiresAt, UsedAt, CreatedAt)
VALUES (@divya, HASHBYTES('SHA2_256', N'old-used-' + @tag), DATEADD(DAY, -119, SYSUTCDATETIME()), DATEADD(DAY, -119, SYSUTCDATETIME()), DATEADD(DAY, -120, SYSUTCDATETIME())),
       (@divya, HASHBYTES('SHA2_256', N'fresh-' + @tag), DATEADD(MINUTE, 30, SYSUTCDATETIME()), NULL, SYSUTCDATETIME());
EXEC sched.usp_Job_PurgeNotifications @RetentionDays = 90, @BatchSize = 100;
INSERT @r VALUES (N'J07 purge deletes handled notifications older than 90 days with their history and used/expired tokens; recent ones, waiting ones and live tokens stay',
    IIF(NOT EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE NotificationId = @p1) AND NOT EXISTS (SELECT 1 FROM notify.NotificationHistory WHERE NotificationId = @p1)
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE NotificationId = @p2) AND EXISTS (SELECT 1 FROM notify.NotificationHistory WHERE NotificationId = @p2)
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE NotificationId = @p3)
        AND NOT EXISTS (SELECT 1 FROM sec.PasswordResetTokens WHERE TokenHash = HASHBYTES('SHA2_256', N'old-used-' + @tag))
        AND EXISTS (SELECT 1 FROM sec.PasswordResetTokens WHERE TokenHash = HASHBYTES('SHA2_256', N'fresh-' + @tag))
        AND (SELECT RowsAffected FROM sched.JobExecutionHistory WHERE ExecutionId = (SELECT MAX(ExecutionId) FROM sched.JobExecutionHistory)) >= 3, 1, 0), N'');
SET @e = 0; BEGIN TRY EXEC sched.usp_Job_PurgeNotifications @RetentionDays = 1; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'J08 a retention under 7 days is refused (50001)', IIF(@e = 50001, 1, 0), CONCAT(N'err=', @e));

/* ============================== DAILY SUMMARY ============================== */
EXEC sched.usp_Job_DailyRecruitmentSummary;
EXEC sched.usp_Job_DailyRecruitmentSummary;
DECLARE @f DATETIME2(0) = CAST((CAST(@today AS DATETIME2(0)) AT TIME ZONE 'India Standard Time') AT TIME ZONE 'UTC' AS DATETIME2(0));
INSERT @r VALUES (N'J09 the daily summary holds today''s IST-day figures, equal to direct counts, and re-running replaces the row (one row per day)',
    IIF((SELECT COUNT(*) FROM report.DailyRecruitmentSummary WHERE SummaryDate = @today) = 1
        AND EXISTS (SELECT 1 FROM report.DailyRecruitmentSummary s WHERE s.SummaryDate = @today
                    AND s.OpenRequisitions = (SELECT COUNT(*) FROM rec.JobRequisitions WHERE Status = 'Open')
                    AND s.NewApplications = (SELECT COUNT(*) FROM cand.JobApplications WHERE AppliedAt >= @f AND AppliedAt < DATEADD(DAY, 1, @f))
                    AND s.PendingTimesheets = (SELECT COUNT(*) FROM [time].Timesheets WHERE Status = 'Submitted')
                    AND s.OffersExtended = (SELECT COUNT(*) FROM cand.JobOffers WHERE SentAt >= @f AND SentAt < DATEADD(DAY, 1, @f))), 1, 0),
    CONCAT(N'f=', CONVERT(NVARCHAR(20), @f, 120)));
SET @e = 0; BEGIN TRY DECLARE @tomorrow DATE = DATEADD(DAY, 1, @today); EXEC sched.usp_Job_DailyRecruitmentSummary @tomorrow; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'J10 a summary for a future day is refused and recorded as Failed', IIF(@e = 50001 AND (SELECT Outcome FROM sched.JobExecutionHistory WHERE ExecutionId = (SELECT MAX(ExecutionId) FROM sched.JobExecutionHistory)) = 'Failed', 1, 0), CONCAT(N'err=', @e));

/* ============================== BOOKKEEPING ============================== */
UPDATE sched.JobDefinitions SET IsEnabled = 0 WHERE JobName = N'TAMS - Expire stale requisitions';
UPDATE rec.JobRequisitions SET ClosesBy = DATEADD(DAY, -1, @today) WHERE JobRequisitionId = @job2;
EXEC sched.usp_Job_ExpireRequisitions;
INSERT @r VALUES (N'J11 a job switched off in TAMS is recorded as Skipped and does nothing',
    IIF((SELECT Outcome FROM sched.JobExecutionHistory WHERE ExecutionId = (SELECT MAX(ExecutionId) FROM sched.JobExecutionHistory)) = 'Skipped'
        AND (SELECT Status FROM rec.JobRequisitions WHERE JobRequisitionId = @job2) = 'Open', 1, 0), N'');
UPDATE sched.JobDefinitions SET IsEnabled = 1 WHERE JobName = N'TAMS - Expire stale requisitions';
SET @e = 0;  BEGIN TRY EXEC sched.usp_Job_IndexMaintenance; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
SET @e2 = 0; BEGIN TRY EXEC sched.usp_Job_BackupDatabase 'FULL'; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'J12 backups and index maintenance refuse to run inside a transaction (50002) and record the failure',
    IIF(@e = 50002 AND @e2 = 50002 AND (SELECT COUNT(*) FROM sched.JobExecutionHistory WHERE ExecutionId > @histBefore AND Outcome = 'Failed' AND ErrorMessage LIKE N'%inside a transaction%') = 2, 1, 0),
    CONCAT(N'err=', @e, N'/', @e2));
INSERT @r VALUES (N'J13 every run left no lock behind and has a finish time',
    IIF(APPLOCK_MODE('public', N'TAMS - Expire stale requisitions', 'Session') = 'NoLock' AND APPLOCK_MODE('public', N'TAMS - Index maintenance', 'Session') = 'NoLock'
        AND NOT EXISTS (SELECT 1 FROM sched.JobExecutionHistory WHERE ExecutionId > @histBefore AND (Outcome = 'Running' OR FinishedAt IS NULL)), 1, 0), N'');
INSERT @r VALUES (N'J14 the Agent job catalogue: 9 SQL Agent jobs (incl. differential and log backups), the 7 Task Scheduler jobs (6 required + file housekeeping, Phase 12) untouched',
    IIF((SELECT COUNT(*) FROM sched.JobDefinitions WHERE Owner = 'SqlAgent') = 9 AND (SELECT COUNT(*) FROM sched.JobDefinitions WHERE Owner = 'TaskScheduler') = 7
        AND EXISTS (SELECT 1 FROM sched.JobDefinitions WHERE JobName = N'TAMS - Transaction log backup'), 1, 0), N'');
CREATE TABLE #d (DetailId BIGINT, Level VARCHAR(7), Message NVARCHAR(1000), LoggedAt DATETIME2(0));
SET @ex = (SELECT MIN(ExecutionId) FROM sched.JobExecutionHistory WHERE ExecutionId > @histBefore);
INSERT #d EXEC sched.usp_ListJobRunDetails @admin, @ex;
SET @e = 0; BEGIN TRY EXEC sched.usp_ListJobRunDetails @priya, @ex; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'J15 an administrator reads a run''s details; others cannot (50005)', IIF((SELECT COUNT(*) FROM #d) >= 1 AND @e = 50005, 1, 0), CONCAT(N'details=', (SELECT COUNT(*) FROM #d), N' err=', @e));

/* ============================== LEAST PRIVILEGE ============================== */
EXECUTE AS USER = 'tams_app_demo';
SET @e = 0;  BEGIN TRY EXEC sched.usp_Job_PurgeNotifications; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
SET @e2 = 0; BEGIN TRY EXEC sched.usp_Job_BackupDatabase 'FULL'; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
DECLARE @e3 INT = 0; BEGIN TRY DECLARE @x BIGINT; EXEC sched.usp_JobBegin N'TAMS - Update statistics', @x OUTPUT; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH
DECLARE @e4 INT = 0; BEGIN TRY DELETE #d; INSERT #d EXEC sched.usp_ListJobRunDetails @admin, @ex; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH
REVERT;
INSERT @r VALUES (N'P01 the application role cannot run any scheduled job or its bookkeeping (229) but can read run details for administrators',
    IIF(@e = 229 AND @e2 = 229 AND @e3 = 229 AND @e4 = 0, 1, 0), CONCAT(N'err=', @e, N'/', @e2, N'/', @e3, N'/', @e4));

IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT @r VALUES (N'Z01 the suite left no trace',
    IIF(@@TRANCOUNT = 0 AND ISNULL((SELECT MAX(ExecutionId) FROM sched.JobExecutionHistory), 0) = @histBefore
        AND NOT EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE TemplateCode IN ('TEST_NOTE', 'JOB_FAILED', 'JOB_EXPIRED'))
        AND (SELECT COUNT(*) FROM rec.JobRequisitions WHERE Status = 'Expired' AND JobRequisitionId IN (@job1, @job2)) = 0, 1, 0), N'');

DECLARE @line NVARCHAR(700);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT CASE WHEN Ok = 1 THEN N'PASS  ' ELSE N'FAIL  ' END + Name + CASE WHEN Ok = 0 THEN N'  -> ' + ISNULL(Detail, N'') ELSE N'' END FROM @r ORDER BY Id;
OPEN c; FETCH NEXT FROM c INTO @line; WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c INTO @line; END CLOSE c; DEALLOCATE c;
DECLARE @total INT = (SELECT COUNT(*) FROM @r), @passed INT = (SELECT COUNT(*) FROM @r WHERE Ok = 1);
PRINT CONCAT(N'--- Job tests: ', @passed, N' passed, ', @total - @passed, N' failed, ', @total, N' total ---');
IF @passed <> @total RAISERROR(N'Job tests FAILED', 16, 1);
GO
