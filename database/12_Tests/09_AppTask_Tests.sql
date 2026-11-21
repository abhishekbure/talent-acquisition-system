/* ============================================================================
   TAMS - 12_Tests / 09_AppTask_Tests.sql        (Phase 12)
   Database side of the Task Scheduler tasks: run bookkeeping (lease, Skipped, abandoned runs, failure reporting,
   no access to Agent runs), the reminder / notice / daily-report queueing (who is told, never twice), the document-file
   purge list, and least privilege. Runs in a transaction that is rolled back.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
-- earlier suites run in the same session (Run-DatabaseSetup.ps1) and use some of these temp-table names with other columns
IF OBJECT_ID(N'tempdb..#b') IS NOT NULL DROP TABLE #b;
IF OBJECT_ID(N'tempdb..#q') IS NOT NULL DROP TABLE #q;
IF OBJECT_ID(N'tempdb..#f') IS NOT NULL DROP TABLE #f;
GO
SET NOCOUNT ON;
DECLARE @r TABLE (Id INT IDENTITY(1,1), Name NVARCHAR(240), Ok BIT, Detail NVARCHAR(400));
DECLARE @e INT, @e2 INT, @n INT, @m NVARCHAR(400);
DECLARE @admin INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ADMIN@TAMS.LOCAL');
DECLARE @today DATE = dbo.fn_BusinessToday(), @histBefore BIGINT = ISNULL((SELECT MAX(ExecutionId) FROM sched.JobExecutionHistory), 0);
DECLARE @notifBefore BIGINT = ISNULL((SELECT MAX(NotificationId) FROM notify.NotificationQueue), 0);
CREATE TABLE #b (ExecutionId BIGINT, Outcome VARCHAR(10), Message NVARCHAR(2000));
CREATE TABLE #q (Queued INT, Considered INT);
CREATE TABLE #f (DocumentId INT, StoredFileName NVARCHAR(100), DeletedAt DATETIME2(0));

BEGIN TRANSACTION;
UPDATE notify.NotificationQueue SET NextAttemptAt = '9999-12-31' WHERE Status = 'Pending';      -- not needed, but keeps the copy calm

/* ============================== RUN BOOKKEEPING ============================== */
INSERT #b EXEC sched.usp_AppTaskBegin N'Interview reminders', 60, N'TEST-HOST';
DECLARE @x1 BIGINT = (SELECT ExecutionId FROM #b);
DELETE #b; INSERT #b EXEC sched.usp_AppTaskBegin N'Interview reminders', 60, N'OTHER-HOST';
INSERT @r VALUES (N'T01 a run takes the job; a second start (any machine) while it runs is Skipped and says which run holds it',
    IIF((SELECT Outcome FROM sched.JobExecutionHistory WHERE ExecutionId = @x1) = 'Running'
        AND (SELECT Outcome FROM #b) = 'Skipped' AND (SELECT Message FROM #b) LIKE N'%run #' + CAST(@x1 AS NVARCHAR(20)) + N' on TEST-HOST%', 1, 0), (SELECT Message FROM #b));
EXEC sched.usp_AppTaskLog @x1, N'queued 3', 'Info';
EXEC sched.usp_AppTaskEnd @x1, 'Succeeded', 3;
DELETE #b; INSERT #b EXEC sched.usp_AppTaskBegin N'Interview reminders', 60, N'TEST-HOST';
DECLARE @x2 BIGINT = (SELECT ExecutionId FROM #b);
INSERT @r VALUES (N'T02 after it finished (Succeeded, rows, details), the next run starts normally',
    IIF((SELECT Outcome FROM sched.JobExecutionHistory WHERE ExecutionId = @x1) = 'Succeeded' AND (SELECT RowsAffected FROM sched.JobExecutionHistory WHERE ExecutionId = @x1) = 3
        AND EXISTS (SELECT 1 FROM sched.JobExecutionDetails WHERE ExecutionId = @x1 AND Message = N'queued 3') AND (SELECT Outcome FROM #b) = 'Running', 1, 0), N'');
UPDATE sched.JobExecutionHistory SET StartedAt = DATEADD(MINUTE, -90, SYSUTCDATETIME()) WHERE ExecutionId = @x2;   -- the process died
DELETE #b; INSERT #b EXEC sched.usp_AppTaskBegin N'Interview reminders', 60, N'TEST-HOST';
INSERT @r VALUES (N'T03 a run that never reported back within its lease is marked Failed (abandoned) and no longer blocks the job',
    IIF((SELECT Outcome FROM sched.JobExecutionHistory WHERE ExecutionId = @x2) = 'Failed' AND (SELECT ErrorMessage FROM sched.JobExecutionHistory WHERE ExecutionId = @x2) LIKE N'Abandoned%'
        AND (SELECT Outcome FROM #b) = 'Running', 1, 0), N'');
DECLARE @x3 BIGINT = (SELECT ExecutionId FROM #b);
EXEC sched.usp_AppTaskEnd @x3, 'Failed', 0, N'SMTP outbox not writable';
INSERT @r VALUES (N'T04 a failed run is recorded with its error and every administrator is notified',
    IIF((SELECT Outcome FROM sched.JobExecutionHistory WHERE ExecutionId = @x3) = 'Failed'
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE TemplateCode = 'JOB_FAILED' AND RecipientUserId = @admin AND RelatedEntityId = @x3 AND Body LIKE N'%SMTP outbox not writable%'), 1, 0), N'');
UPDATE sched.JobDefinitions SET IsEnabled = 0 WHERE JobName = N'Offer expiry reminders';
DELETE #b; INSERT #b EXEC sched.usp_AppTaskBegin N'Offer expiry reminders';
UPDATE sched.JobDefinitions SET IsEnabled = 1 WHERE JobName = N'Offer expiry reminders';
INSERT @r VALUES (N'T05 a task switched off in TAMS is Skipped', IIF((SELECT Outcome FROM #b) = 'Skipped' AND (SELECT Message FROM #b) LIKE N'%switched off%', 1, 0), N'');
-- the console app cannot touch SQL Agent runs or unknown jobs
DECLARE @agentDef INT = (SELECT JobDefinitionId FROM sched.JobDefinitions WHERE JobName = N'TAMS - Update statistics');
INSERT sched.JobExecutionHistory (JobDefinitionId) VALUES (@agentDef);
DECLARE @agentRun BIGINT = SCOPE_IDENTITY();
SET @e = 0;  BEGIN TRY EXEC sched.usp_AppTaskEnd @agentRun, 'Succeeded', 0; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
SET @e2 = 0; BEGIN TRY EXEC sched.usp_AppTaskLog @agentRun, N'x'; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
DECLARE @e3 INT = 0; BEGIN TRY EXEC sched.usp_AppTaskBegin N'TAMS - Update statistics'; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH
DECLARE @e4 INT = 0; BEGIN TRY EXEC sched.usp_AppTaskEnd @x1, 'Succeeded', 0; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'T06 the app procedures refuse SQL Agent runs and jobs, and a run that already finished (50004)',
    IIF(@e = 50004 AND @e2 = 50004 AND @e3 = 50004 AND @e4 = 50004 AND (SELECT Outcome FROM sched.JobExecutionHistory WHERE ExecutionId = @agentRun) = 'Running', 1, 0),
    CONCAT(N'err=', @e, N'/', @e2, N'/', @e3, N'/', @e4));

/* ============================== INTERVIEW REMINDERS ============================== */
DECLARE @iv INT = (SELECT TOP (1) i.InterviewId FROM cand.Interviews i WHERE i.JobApplicationId IS NOT NULL AND EXISTS (SELECT 1 FROM cand.InterviewPanels p WHERE p.InterviewId = i.InterviewId) ORDER BY i.InterviewId);
UPDATE cand.Interviews SET Status = 'Scheduled', StartsAt = DATEADD(HOUR, 5, SYSUTCDATETIME()), EndsAt = DATEADD(HOUR, 6, SYSUTCDATETIME()) WHERE InterviewId = @iv;
UPDATE cand.Interviews SET StartsAt = DATEADD(DAY, 3, SYSUTCDATETIME()), EndsAt = DATEADD(DAY, 3, DATEADD(HOUR, 1, SYSUTCDATETIME())) WHERE Status IN ('Scheduled', 'Rescheduled') AND InterviewId <> @iv;
DECLARE @candUser INT = (SELECT c.UserId FROM cand.Interviews i JOIN cand.JobApplications a ON a.ApplicationId = i.JobApplicationId JOIN cand.Candidates c ON c.CandidateId = a.CandidateId WHERE i.InterviewId = @iv);
DECLARE @panelN INT = (SELECT COUNT(*) FROM cand.InterviewPanels WHERE InterviewId = @iv);
INSERT #q EXEC notify.usp_QueueInterviewReminders 24;
SET @n = (SELECT Queued FROM #q);
INSERT @r VALUES (N'T07 an interview within 24 hours: the candidate and every panel member are reminded once, with the IST time; later interviews are not',
    IIF(@n = @panelN + IIF(@candUser IS NULL, 0, 1) AND (SELECT Considered FROM #q) = 1
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE TemplateCode = 'INTERVIEW_REMINDER' AND RelatedEntityId = @iv AND RecipientUserId = @candUser AND Subject LIKE N'% IST' AND Body LIKE N'%Panel: %'), 1, 0),
    CONCAT(N'queued=', @n, N' panel=', @panelN));
DELETE #q; INSERT #q EXEC notify.usp_QueueInterviewReminders 24;
SET @n = (SELECT Queued FROM #q);
UPDATE cand.Interviews SET Status = 'Rescheduled', StartsAt = DATEADD(HOUR, 7, SYSUTCDATETIME()), EndsAt = DATEADD(HOUR, 8, SYSUTCDATETIME()) WHERE InterviewId = @iv;
DELETE #q; INSERT #q EXEC notify.usp_QueueInterviewReminders 24;
INSERT @r VALUES (N'T08 the hourly re-run reminds nobody twice; a rescheduled interview is reminded again', IIF(@n = 0 AND (SELECT Queued FROM #q) = @panelN + IIF(@candUser IS NULL, 0, 1), 1, 0), CONCAT(N'rerun=', @n));

/* ============================== OFFER EXPIRY ============================== */
DECLARE @off INT = (SELECT TOP (1) OfferId FROM cand.JobOffers ORDER BY OfferId);
UPDATE cand.JobOffers SET Status = 'Sent', SentAt = DATEADD(DAY, -2, SYSUTCDATETIME()), ExpiresAt = DATEADD(HOUR, 30, SYSUTCDATETIME()) WHERE OfferId = @off;
UPDATE cand.JobOffers SET ExpiresAt = DATEADD(DAY, 20, SYSUTCDATETIME()) WHERE Status = 'Sent' AND OfferId <> @off;
DELETE #q; INSERT #q EXEC notify.usp_QueueOfferExpiryReminders 2;
SET @n = (SELECT Queued FROM #q);
DELETE #q; INSERT #q EXEC notify.usp_QueueOfferExpiryReminders 2;
INSERT @r VALUES (N'T09 a sent offer expiring within 2 days: its candidate is reminded once; offers further out are not',
    IIF(@n = 1 AND (SELECT Queued FROM #q) = 0 AND EXISTS (SELECT 1 FROM notify.NotificationQueue n JOIN cand.JobOffers o ON o.OfferId = n.RelatedEntityId
          JOIN cand.JobApplications a ON a.ApplicationId = o.ApplicationId JOIN cand.Candidates c ON c.CandidateId = a.CandidateId
          WHERE n.TemplateCode = 'OFFER_EXPIRING' AND o.OfferId = @off AND n.RecipientUserId = c.UserId), 1, 0), CONCAT(N'queued=', @n));

/* ============================== TIMESHEET REMINDERS ============================== */
DECLARE @thisMonday DATE = DATEADD(DAY, -((DATEPART(WEEKDAY, @today) + @@DATEFIRST - 2) % 7), @today);
DECLARE @nextMonday DATE = DATEADD(DAY, 7, @thisMonday);
UPDATE staff.Assignments SET EndDate = DATEADD(DAY, 60, @today) WHERE Status = 'Active' AND EndDate < DATEADD(DAY, 14, @today);
DECLARE @expected INT = (SELECT COUNT(*) FROM staff.Assignments a JOIN staff.Contractors k ON k.ContractorId = a.ContractorId
                         WHERE a.Status = 'Active' AND k.Status = 'Active' AND k.UserId IS NOT NULL AND a.StartDate <= DATEADD(DAY, 6, @nextMonday)
                           AND NOT EXISTS (SELECT 1 FROM [time].Timesheets t WHERE t.AssignmentId = a.AssignmentId AND t.WeekStartDate = @nextMonday AND t.Status NOT IN ('Draft', 'Rejected')));
DELETE #q; INSERT #q EXEC notify.usp_QueueTimesheetReminders @nextMonday;
SET @n = (SELECT Queued FROM #q);
DELETE #q; INSERT #q EXEC notify.usp_QueueTimesheetReminders @nextMonday;
DECLARE @tue DATE = DATEADD(DAY, 1, @nextMonday);
SET @e = 0; BEGIN TRY EXEC notify.usp_QueueTimesheetReminders @tue; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
INSERT @r VALUES (N'T10 every contractor with an active assignment and no submitted timesheet for the week is reminded once; a non-Monday week is refused',
    IIF(@expected > 0 AND @n = @expected AND (SELECT Queued FROM #q) = 0 AND @e = 50001, 1, 0), CONCAT(N'expected=', @expected, N' queued=', @n, N' err=', @e));

/* ============================== CONTRACT EXPIRY NOTICES ============================== */
DECLARE @k INT = (SELECT ContractId FROM staff.Contracts WHERE ContractNo LIKE N'CON-%-002');
UPDATE staff.Contracts SET Status = 'Active' WHERE Status = 'Expiring';
UPDATE staff.Contracts SET Status = 'Expiring', EndDate = DATEADD(DAY, 10, @today) WHERE ContractId = @k;
DECLARE @custUsers INT = (SELECT COUNT(*) FROM org.CustomerUsers cu JOIN sec.Users u ON u.UserId = cu.UserId WHERE u.IsActive = 1 AND cu.CustomerId = (SELECT CustomerId FROM staff.Contracts WHERE ContractId = @k));
DELETE #q; INSERT #q EXEC notify.usp_QueueContractExpiryNotices;
SET @n = (SELECT Queued FROM #q);
DELETE #q; INSERT #q EXEC notify.usp_QueueContractExpiryNotices;
SET @e = (SELECT Queued FROM #q);
UPDATE staff.Contracts SET EndDate = DATEADD(DAY, 5, @today) WHERE ContractId = @k;
DELETE #q; INSERT #q EXEC notify.usp_QueueContractExpiryNotices;
INSERT @r VALUES (N'T11 a contract SQL Agent flagged Expiring: contractor, recruiter and every customer user are told once at 30 days and again at 7 days',
    IIF(@n = 2 + @custUsers AND @e = 0 AND (SELECT Queued FROM #q) = 2 + @custUsers AND (SELECT Considered FROM #q) = 1
        AND (SELECT Status FROM staff.Contracts WHERE ContractId = @k) = 'Expiring', 1, 0), CONCAT(N'first=', @n, N' again=', @e, N' 7d=', (SELECT Queued FROM #q), N' customer users=', @custUsers));

/* ============================== DAILY REPORT ============================== */
DECLARE @yesterday DATE = DATEADD(DAY, -1, @today);
DELETE FROM report.DailyRecruitmentSummary WHERE SummaryDate = @yesterday;
SET @e = 0; SET @m = NULL; BEGIN TRY EXEC notify.usp_QueueDailyReport; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); SET @m = ERROR_MESSAGE(); END CATCH
INSERT report.DailyRecruitmentSummary (SummaryDate, OpenRequisitions, NewApplications, InterviewsScheduled, OffersExtended, OffersAccepted, ActiveContractors, PendingTimesheets)
VALUES (@yesterday, 2, 3, 1, 1, 0, 2, 4);
DELETE #q; INSERT #q EXEC notify.usp_QueueDailyReport;
SET @n = (SELECT Queued FROM #q);
DELETE #q; INSERT #q EXEC notify.usp_QueueDailyReport;
DECLARE @staff INT = (SELECT COUNT(DISTINCT ur.UserId) FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId JOIN sec.Users u ON u.UserId = ur.UserId
                      WHERE u.IsActive = 1 AND r.RoleName IN (N'Recruiter', N'HRManager', N'Administrator'));
INSERT @r VALUES (N'T12 the daily report: refused (50002, naming the SQL Agent job) when the summary was not prepared; otherwise sent once to every recruiter, HR manager and administrator with the figures',
    IIF(@e = 50002 AND @m LIKE N'%Prepare daily recruitment summary%' AND @n = @staff AND (SELECT Queued FROM #q) = 0
        AND EXISTS (SELECT 1 FROM notify.NotificationQueue WHERE TemplateCode = 'DAILY_SUMMARY' AND RecipientUserId = @admin AND Body LIKE N'%Timesheets waiting for approval: 4%'), 1, 0),
    CONCAT(N'err=', @e, N' queued=', @n, N' staff=', @staff));

/* ============================== DOCUMENT FILES ============================== */
DECLARE @sha BINARY(32) = HASHBYTES('SHA2_256', 'tams-purge-test'), @divya INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'DIVYA.REDDY@CANDIDATE.EXAMPLE');
INSERT doc.Documents (OwnerType, OwnerId, StoredFileName, OriginalFileName, ContentType, SizeBytes, Sha256, UploadedByUserId, IsDeleted, DeletedAt)
VALUES ('Candidate', 1, N'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pdf', N'old.pdf', N'application/pdf', 10, @sha, @divya, 1, DATEADD(DAY, -40, SYSUTCDATETIME())),
       ('Candidate', 1, N'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.pdf', N'recent.pdf', N'application/pdf', 10, @sha, @divya, 1, DATEADD(DAY, -2, SYSUTCDATETIME())),
       ('Candidate', 1, N'cccccccccccccccccccccccccccccccc.pdf', N'live.pdf', N'application/pdf', 10, @sha, @divya, 0, NULL);
INSERT #f EXEC doc.usp_ListPurgeableFiles 30;
DECLARE @listed BIT = IIF(EXISTS (SELECT 1 FROM #f WHERE StoredFileName LIKE N'aaaa%') AND NOT EXISTS (SELECT 1 FROM #f WHERE StoredFileName LIKE N'bbbb%' OR StoredFileName LIKE N'cccc%'), 1, 0);
DECLARE @old INT = (SELECT DocumentId FROM doc.Documents WHERE StoredFileName = N'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pdf');
EXEC doc.usp_MarkFilePurged @old;
SET @e = 0; BEGIN TRY EXEC doc.usp_MarkFilePurged @old; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
DELETE #f; INSERT #f EXEC doc.usp_ListPurgeableFiles 30;
INSERT @r VALUES (N'T13 only files of documents deleted over 30 days ago are listed for purging; marking one removes it from the list (once)',
    IIF(@listed = 1 AND NOT EXISTS (SELECT 1 FROM #f WHERE StoredFileName LIKE N'aaaa%' OR StoredFileName LIKE N'bbbb%' OR StoredFileName LIKE N'cccc%')
        AND (SELECT FilePurgedAt FROM doc.Documents WHERE DocumentId = @old) IS NOT NULL AND @e = 50004, 1, 0), CONCAT(N'listed=', @listed, N' err=', @e));

/* ============================== LEAST PRIVILEGE ============================== */
EXECUTE AS USER = 'tams_app_demo';
DECLARE @a1 INT = 0; BEGIN TRY DELETE #q; INSERT #q EXEC notify.usp_QueueOfferExpiryReminders 2; END TRY BEGIN CATCH SET @a1 = ERROR_NUMBER(); END CATCH
DECLARE @a2 INT = 0; BEGIN TRY EXEC sched.usp_AppTaskBegin N'Offer expiry reminders'; END TRY BEGIN CATCH SET @a2 = ERROR_NUMBER(); END CATCH
DECLARE @a3 INT = 0; BEGIN TRY EXEC doc.usp_MarkFilePurged 1; END TRY BEGIN CATCH SET @a3 = ERROR_NUMBER(); END CATCH
REVERT;
EXECUTE AS USER = 'tams_worker_demo';
SET @e = 0;  BEGIN TRY DELETE #q; INSERT #q EXEC notify.usp_QueueOfferExpiryReminders 2; END TRY BEGIN CATCH SET @e = ERROR_NUMBER(); END CATCH
SET @e2 = 0; BEGIN TRY EXEC sched.usp_NotifyJobFailure 1, N'x', N'spam'; END TRY BEGIN CATCH SET @e2 = ERROR_NUMBER(); END CATCH
SET @e3 = 0; BEGIN TRY EXEC sched.usp_JobEnd 1, N'x', 'Failed', 0, N'x'; END TRY BEGIN CATCH SET @e3 = ERROR_NUMBER(); END CATCH
SET @e4 = 0; BEGIN TRY SELECT @n = COUNT(*) FROM sched.JobExecutionHistory; END TRY BEGIN CATCH SET @e4 = ERROR_NUMBER(); END CATCH
REVERT;
INSERT @r VALUES (N'P01 the worker identity runs the task procedures, but cannot raise failure notices directly, touch Agent bookkeeping or read the tables (229); the API identity cannot run the task procedures at all (229, Phase 13)',
    IIF(@e = 0 AND @e2 = 229 AND @e3 = 229 AND @e4 = 229 AND @a1 = 229 AND @a2 = 229 AND @a3 = 229, 1, 0), CONCAT(N'worker=', @e, N'/', @e2, N'/', @e3, N'/', @e4, N' api=', @a1, N'/', @a2, N'/', @a3));

IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT @r VALUES (N'Z01 the suite left no trace',
    IIF(@@TRANCOUNT = 0 AND ISNULL((SELECT MAX(ExecutionId) FROM sched.JobExecutionHistory), 0) = @histBefore
        AND ISNULL((SELECT MAX(NotificationId) FROM notify.NotificationQueue), 0) = @notifBefore
        AND NOT EXISTS (SELECT 1 FROM doc.Documents WHERE Sha256 = HASHBYTES('SHA2_256', 'tams-purge-test')), 1, 0), N'');

DECLARE @line NVARCHAR(700);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT CASE WHEN Ok = 1 THEN N'PASS  ' ELSE N'FAIL  ' END + Name + CASE WHEN Ok = 0 THEN N'  -> ' + ISNULL(Detail, N'') ELSE N'' END FROM @r ORDER BY Id;
OPEN c; FETCH NEXT FROM c INTO @line; WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c INTO @line; END CLOSE c; DEALLOCATE c;
DECLARE @total INT = (SELECT COUNT(*) FROM @r), @passed INT = (SELECT COUNT(*) FROM @r WHERE Ok = 1);
PRINT CONCAT(N'--- App task tests: ', @passed, N' passed, ', @total - @passed, N' failed, ', @total, N' total ---');
IF @passed <> @total RAISERROR(N'App task tests FAILED', 16, 1);
GO
