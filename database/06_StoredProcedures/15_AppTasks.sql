/* ============================================================================
   TAMS - 06_StoredProcedures / 15_AppTasks.sql   (Phase 12)
   Database side of the application tasks run by Windows Task Scheduler through TalentAcquisition.Scheduler.exe.
   Responsibilities do not overlap with SQL Server Agent (Phase 11):
     * Agent CHANGES data (expires jobs, flags contracts Expiring, prepares the daily summary row, purges old rows);
     * these tasks TELL people (reminders, contract-expiry notices, the daily report e-mail), send the e-mail queue,
       and look after FILES in the application's folders (deleted documents, mail outbox, a copy of the document store).
   Run bookkeeping for the console app: sched.usp_AppTask* (only for Owner = 'TaskScheduler' jobs). The console app
   connects with pooled connections, so a run is protected by a database LEASE (a Running row younger than the lease
   blocks a second run on any machine) plus a machine-wide mutex in the app.
   ========================================================================== */
USE TalentAcquisitionDB;
GO

MERGE sched.JobDefinitions AS t
USING (VALUES
 (N'Interview reminders',           N'Remind the candidate and the panel of interviews starting within 24 hours (once per interview time)', N'Hourly'),
 (N'Offer expiry reminders',        N'Remind candidates of sent offers that expire within 2 days', N'Daily 08:00'),
 (N'Timesheet reminders',           N'Remind contractors with active assignments whose timesheet for this week is not submitted', N'Weekly Fri 15:00'),
 (N'Contract expiry notifications', N'Tell the contractor, the customer and the recruiter about contracts SQL Agent flagged Expiring (at 30, 7 and 1 days)', N'Daily 08:30'),
 (N'Email queue processing',        N'Send queued notifications as e-mail through the mock provider (.eml files)', N'Every 5 minutes'),
 (N'Daily report delivery',         N'E-mail yesterday''s recruitment summary (prepared by SQL Agent) to recruiters, HR and administrators', N'Daily 07:30'),
 (N'File housekeeping',             N'Delete files of documents deleted over 30 days ago and outbox e-mails over 30 days old; copy the document store to its backup folder', N'Daily 04:15')
) AS s (JobName, Description, ScheduleDescription)
ON t.JobName = s.JobName
WHEN MATCHED THEN UPDATE SET Description = s.Description, ScheduleDescription = s.ScheduleDescription, Owner = 'TaskScheduler'
WHEN NOT MATCHED BY TARGET THEN INSERT (JobName, Owner, Description, ScheduleDescription) VALUES (s.JobName, 'TaskScheduler', s.Description, s.ScheduleDescription);
GO

/* ============================== run bookkeeping (console app) ============================== */
-- Returns one row: ExecutionId, Outcome ('Running' = go ahead | 'Skipped'), Message.
CREATE OR ALTER PROCEDURE sched.usp_AppTaskBegin @JobName NVARCHAR(100), @LeaseMinutes INT = 60, @HostName NVARCHAR(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;     -- XACT_ABORT only after validation: a THROW under XACT_ABORT would doom a caller's transaction
    IF @LeaseMinutes IS NULL OR @LeaseMinutes NOT BETWEEN 1 AND 1440 THROW 50001, N'LeaseMinutes must be between 1 and 1440.', 1;
    DECLARE @def INT, @enabled BIT, @id BIGINT, @msg NVARCHAR(400) = NULL, @now DATETIME2(0) = SYSUTCDATETIME();
    IF NOT EXISTS (SELECT 1 FROM sched.JobDefinitions WHERE JobName = @JobName AND Owner = 'TaskScheduler') THROW 50004, N'Unknown Task Scheduler job.', 1;
    SET XACT_ABORT ON;
    BEGIN TRANSACTION;
    -- serialise starts of the same job: the definition row is the lock
    SELECT @def = JobDefinitionId, @enabled = IsEnabled FROM sched.JobDefinitions WITH (UPDLOCK, HOLDLOCK) WHERE JobName = @JobName AND Owner = 'TaskScheduler';
    -- a run that never reported back within the lease is abandoned (process killed, machine restarted)
    UPDATE sched.JobExecutionHistory SET Outcome = 'Failed', FinishedAt = @now, ErrorMessage = N'Abandoned: the run did not finish within its ' + CAST(@LeaseMinutes AS NVARCHAR(10)) + N'-minute lease.'
    WHERE JobDefinitionId = @def AND Outcome = 'Running' AND StartedAt < DATEADD(MINUTE, -@LeaseMinutes, @now);
    IF @enabled = 0 SET @msg = N'The job is switched off in sched.JobDefinitions.';
    ELSE IF EXISTS (SELECT 1 FROM sched.JobExecutionHistory WHERE JobDefinitionId = @def AND Outcome = 'Running')
        SELECT TOP (1) @msg = N'Another run of this job is still in progress (run #' + CAST(ExecutionId AS NVARCHAR(20)) + N' on ' + ISNULL(HostName, N'?') + N', started '
                              + CONVERT(NVARCHAR(19), StartedAt, 120) + N' UTC).'
        FROM sched.JobExecutionHistory WHERE JobDefinitionId = @def AND Outcome = 'Running' ORDER BY ExecutionId DESC;
    IF @msg IS NOT NULL
        INSERT sched.JobExecutionHistory (JobDefinitionId, FinishedAt, Outcome, RowsAffected, ErrorMessage, HostName) VALUES (@def, @now, 'Skipped', 0, @msg, LEFT(ISNULL(@HostName, HOST_NAME()), 128));
    ELSE
        INSERT sched.JobExecutionHistory (JobDefinitionId, HostName) VALUES (@def, LEFT(ISNULL(@HostName, HOST_NAME()), 128));
    SET @id = SCOPE_IDENTITY();
    COMMIT;
    SELECT ExecutionId, Outcome, ErrorMessage AS Message FROM sched.JobExecutionHistory WHERE ExecutionId = @id;
END
GO

-- Only a Task Scheduler run can be written to through these procedures (never an Agent job's history).
CREATE OR ALTER PROCEDURE sched.usp_AppTaskLog @ExecutionId BIGINT, @Message NVARCHAR(1000), @Level VARCHAR(7) = 'Info'
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM sched.JobExecutionHistory h JOIN sched.JobDefinitions d ON d.JobDefinitionId = h.JobDefinitionId
                   WHERE h.ExecutionId = @ExecutionId AND d.Owner = 'TaskScheduler' AND h.Outcome = 'Running')
        THROW 50004, N'No running Task Scheduler run with this id.', 1;
    IF @Level NOT IN ('Info', 'Warning', 'Error') THROW 50001, N'Level must be Info, Warning or Error.', 1;
    INSERT sched.JobExecutionDetails (ExecutionId, Level, Message) VALUES (@ExecutionId, @Level, LEFT(@Message, 1000));
END
GO

CREATE OR ALTER PROCEDURE sched.usp_AppTaskEnd @ExecutionId BIGINT, @Outcome VARCHAR(10), @RowsAffected INT = 0, @Error NVARCHAR(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @Outcome NOT IN ('Succeeded', 'Failed') THROW 50001, N'Outcome must be Succeeded or Failed.', 1;
    DECLARE @job NVARCHAR(100);
    SELECT @job = d.JobName FROM sched.JobExecutionHistory h JOIN sched.JobDefinitions d ON d.JobDefinitionId = h.JobDefinitionId
    WHERE h.ExecutionId = @ExecutionId AND d.Owner = 'TaskScheduler' AND h.Outcome = 'Running';
    IF @job IS NULL THROW 50004, N'No running Task Scheduler run with this id (finished, abandoned or not a Task Scheduler job).', 1;
    UPDATE sched.JobExecutionHistory SET FinishedAt = SYSUTCDATETIME(), Outcome = @Outcome, RowsAffected = @RowsAffected, ErrorMessage = LEFT(@Error, 2000)
    WHERE ExecutionId = @ExecutionId;
    IF @Outcome = 'Failed' EXEC sched.usp_NotifyJobFailure @ExecutionId, @job, @Error;
END
GO

/* ============================== what the tasks queue ============================== */
-- Each returns one row: Queued (new notifications), Considered (items looked at). Re-running never duplicates a
-- reminder: the de-duplication key names the item and the moment it is about (interview time, expiry, week ...).

CREATE OR ALTER PROCEDURE notify.usp_QueueInterviewReminders @WithinHours INT = 24
AS
BEGIN
    SET NOCOUNT ON;
    IF @WithinHours IS NULL OR @WithinHours NOT BETWEEN 1 AND 168 THROW 50001, N'WithinHours must be between 1 and 168.', 1;
    DECLARE @before BIGINT = ISNULL((SELECT MAX(NotificationId) FROM notify.NotificationQueue), 0), @now DATETIME2(0) = SYSUTCDATETIME(), @n INT = 0;
    DECLARE @iv TABLE (InterviewId INT PRIMARY KEY, StartsAt DATETIME2(0), EndsAt DATETIME2(0), Mode VARCHAR(10), Place NVARCHAR(300), RoleTitle NVARCHAR(200), CandUser INT, Panel NVARCHAR(1000));
    INSERT @iv
    SELECT i.InterviewId, i.StartsAt, i.EndsAt, i.Mode, i.LocationOrLink, COALESCE(jr.Title, cr.Title),
           (SELECT c.UserId FROM cand.Candidates c WHERE c.CandidateId = COALESCE(a.CandidateId, s.CandidateId)),
           STUFF((SELECT N', ' + u.DisplayName FROM cand.InterviewPanels ip JOIN sec.Users u ON u.UserId = ip.UserId WHERE ip.InterviewId = i.InterviewId ORDER BY ip.IsLead DESC, u.DisplayName FOR XML PATH(N'')), 1, 2, N'')
    FROM cand.Interviews i
    LEFT JOIN cand.JobApplications a ON a.ApplicationId = i.JobApplicationId
    LEFT JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId
    LEFT JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
    LEFT JOIN staff.SubmittedCandidates s ON s.SubmissionId = i.SubmittedCandidateId
    LEFT JOIN staff.CustomerRequisitions cr ON cr.CustomerRequisitionId = s.CustomerRequisitionId
    WHERE i.Status IN ('Scheduled', 'Rescheduled') AND i.StartsAt > @now AND i.StartsAt <= DATEADD(HOUR, @WithinHours, @now);
    SET @n = @@ROWCOUNT;

    DECLARE @id INT, @starts DATETIME2(0), @ends DATETIME2(0), @mode VARCHAR(10), @place NVARCHAR(300), @role NVARCHAR(200), @cand INT, @panel NVARCHAR(1000),
            @subj NVARCHAR(300), @body NVARCHAR(2000), @key NVARCHAR(180), @u INT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT InterviewId, StartsAt, EndsAt, Mode, Place, RoleTitle, CandUser, Panel FROM @iv;
    OPEN c; FETCH NEXT FROM c INTO @id, @starts, @ends, @mode, @place, @role, @cand, @panel;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @subj = N'Reminder: interview for ' + ISNULL(@role, N'your application') + N' on ' + dbo.fn_BusinessTime(@starts);
        SET @body = N'This is a reminder of the interview for ' + ISNULL(@role, N'the role') + N'.' + NCHAR(10) + N'Starts: ' + dbo.fn_BusinessTime(@starts)
                  + NCHAR(10) + N'Ends: ' + dbo.fn_BusinessTime(@ends) + NCHAR(10) + N'Mode: ' + @mode
                  + CASE WHEN NULLIF(LTRIM(@place), N'') IS NULL THEN N'' ELSE NCHAR(10) + N'Where: ' + @place END
                  + CASE WHEN @panel IS NULL THEN N'' ELSE NCHAR(10) + N'Panel: ' + @panel END;
        SET @key = N'IVREM:' + CONVERT(NVARCHAR(16), @starts, 120);              -- a rescheduled interview is reminded again
        IF @cand IS NOT NULL EXEC notify.usp_Enqueue 'INTERVIEW_REMINDER', @cand, @subj, @body, @key, 'Interview', @id;
        DECLARE p CURSOR LOCAL FAST_FORWARD FOR SELECT UserId FROM cand.InterviewPanels WHERE InterviewId = @id;
        OPEN p; FETCH NEXT FROM p INTO @u;
        WHILE @@FETCH_STATUS = 0 BEGIN EXEC notify.usp_Enqueue 'INTERVIEW_REMINDER', @u, @subj, @body, @key, 'Interview', @id; FETCH NEXT FROM p INTO @u; END
        CLOSE p; DEALLOCATE p;
        FETCH NEXT FROM c INTO @id, @starts, @ends, @mode, @place, @role, @cand, @panel;
    END
    CLOSE c; DEALLOCATE c;
    SELECT (SELECT COUNT(*) FROM notify.NotificationQueue WHERE NotificationId > @before AND TemplateCode = 'INTERVIEW_REMINDER') AS Queued, @n AS Considered;
END
GO

CREATE OR ALTER PROCEDURE notify.usp_QueueOfferExpiryReminders @WithinDays INT = 2
AS
BEGIN
    SET NOCOUNT ON;
    IF @WithinDays IS NULL OR @WithinDays NOT BETWEEN 1 AND 30 THROW 50001, N'WithinDays must be between 1 and 30.', 1;
    DECLARE @before BIGINT = ISNULL((SELECT MAX(NotificationId) FROM notify.NotificationQueue), 0), @now DATETIME2(0) = SYSUTCDATETIME(), @n INT = 0;
    DECLARE @id INT, @no NVARCHAR(30), @des NVARCHAR(150), @exp DATETIME2(0), @u INT, @subj NVARCHAR(300), @body NVARCHAR(1000), @key NVARCHAR(180);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT o.OfferId, o.OfferNo, o.Designation, o.ExpiresAt, cd.UserId
        FROM cand.JobOffers o JOIN cand.JobApplications a ON a.ApplicationId = o.ApplicationId JOIN cand.Candidates cd ON cd.CandidateId = a.CandidateId
        WHERE o.Status = 'Sent' AND o.ExpiresAt > @now AND o.ExpiresAt <= DATEADD(DAY, @WithinDays, @now) AND cd.UserId IS NOT NULL;
    OPEN c; FETCH NEXT FROM c INTO @id, @no, @des, @exp, @u;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @n += 1;
        SET @subj = N'Your offer ' + @no + N' expires on ' + dbo.fn_BusinessTime(@exp);
        SET @body = N'The offer for "' + @des + N'" (' + @no + N') is waiting for your answer and expires on ' + dbo.fn_BusinessTime(@exp)
                  + N'. Accept or decline it under Offers in TAMS before then.';
        SET @key = N'OFFEXP:' + CONVERT(NVARCHAR(16), @exp, 120);                -- an extended offer is reminded again
        EXEC notify.usp_Enqueue 'OFFER_EXPIRING', @u, @subj, @body, @key, 'JobOffer', @id;
        FETCH NEXT FROM c INTO @id, @no, @des, @exp, @u;
    END
    CLOSE c; DEALLOCATE c;
    SELECT (SELECT COUNT(*) FROM notify.NotificationQueue WHERE NotificationId > @before AND TemplateCode = 'OFFER_EXPIRING') AS Queued, @n AS Considered;
END
GO

-- Contractors with an active assignment in the week (Monday-based, IST) and no submitted/approved timesheet for it.
CREATE OR ALTER PROCEDURE notify.usp_QueueTimesheetReminders @WeekStart DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = dbo.fn_BusinessToday();
    SET @WeekStart = ISNULL(@WeekStart, DATEADD(DAY, -((DATEPART(WEEKDAY, @today) + @@DATEFIRST - 2) % 7), @today));
    IF (DATEPART(WEEKDAY, @WeekStart) + @@DATEFIRST - 2) % 7 <> 0 THROW 50001, N'WeekStart must be a Monday.', 1;
    DECLARE @weekEnd DATE = DATEADD(DAY, 6, @WeekStart);
    DECLARE @before BIGINT = ISNULL((SELECT MAX(NotificationId) FROM notify.NotificationQueue), 0), @n INT = 0;
    DECLARE @asg INT, @u INT, @role NVARCHAR(150), @cust NVARCHAR(200), @status VARCHAR(12), @subj NVARCHAR(300), @body NVARCHAR(1000), @key NVARCHAR(180);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT a.AssignmentId, k.UserId, a.RoleTitle, cu.Name, t.Status
        FROM staff.Assignments a
        JOIN staff.Contractors k ON k.ContractorId = a.ContractorId
        JOIN org.Customers cu ON cu.CustomerId = a.CustomerId
        LEFT JOIN [time].Timesheets t ON t.AssignmentId = a.AssignmentId AND t.WeekStartDate = @WeekStart
        WHERE a.Status = 'Active' AND k.Status = 'Active' AND k.UserId IS NOT NULL
          AND a.StartDate <= @weekEnd AND (a.EndDate IS NULL OR a.EndDate >= @WeekStart)
          AND ISNULL(t.Status, 'Draft') IN ('Draft', 'Rejected');
    OPEN c; FETCH NEXT FROM c INTO @asg, @u, @role, @cust, @status;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @n += 1;
        SET @subj = N'Timesheet reminder: week of ' + CONVERT(NVARCHAR(10), @WeekStart, 120);
        SET @body = CASE WHEN @status = 'Rejected'
                         THEN N'Your timesheet for the week of ' + CONVERT(NVARCHAR(10), @WeekStart, 120) + N' (' + @role + N' at ' + @cust + N') was rejected and still needs correcting and resubmitting.'
                         ELSE N'Your timesheet for the week of ' + CONVERT(NVARCHAR(10), @WeekStart, 120) + N' (' + @role + N' at ' + @cust + N') has not been submitted yet. Please enter your hours and submit it.' END;
        SET @key = N'TSREM:' + CONVERT(NVARCHAR(10), @WeekStart, 120);
        EXEC notify.usp_Enqueue 'TIMESHEET_REMINDER', @u, @subj, @body, @key, 'Assignment', @asg;
        FETCH NEXT FROM c INTO @asg, @u, @role, @cust, @status;
    END
    CLOSE c; DEALLOCATE c;
    SELECT (SELECT COUNT(*) FROM notify.NotificationQueue WHERE NotificationId > @before AND TemplateCode = 'TIMESHEET_REMINDER') AS Queued, @n AS Considered;
END
GO

-- Contracts that SQL Agent's "Detect contract expiry" job flagged Expiring (this task only tells people; it changes nothing).
-- Each contract is announced at three moments: 30 days or less, 7 days or less, last day.
CREATE OR ALTER PROCEDURE notify.usp_QueueContractExpiryNotices
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @today DATE = dbo.fn_BusinessToday(), @before BIGINT = ISNULL((SELECT MAX(NotificationId) FROM notify.NotificationQueue), 0), @n INT = 0;
    DECLARE @id INT, @no NVARCHAR(30), @end DATE, @cust INT, @custName NVARCHAR(200), @ctrUser INT, @ctrName NVARCHAR(201), @rec INT, @days INT,
            @stage NVARCHAR(10), @subj NVARCHAR(300), @body NVARCHAR(1000), @key NVARCHAR(180);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT ct.ContractId, ct.ContractNo, ct.EndDate, ct.CustomerId, cu.Name, k.UserId, cd.FirstName + N' ' + cd.LastName, ct.CreatedByUserId
        FROM staff.Contracts ct
        JOIN org.Customers cu ON cu.CustomerId = ct.CustomerId
        JOIN staff.Placements pl ON pl.PlacementId = ct.PlacementId
        JOIN staff.Contractors k ON k.ContractorId = pl.ContractorId
        JOIN cand.Candidates cd ON cd.CandidateId = k.CandidateId
        WHERE ct.Status = 'Expiring' AND ct.EndDate >= @today;
    OPEN c; FETCH NEXT FROM c INTO @id, @no, @end, @cust, @custName, @ctrUser, @ctrName, @rec;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @n += 1;
        SET @days = DATEDIFF(DAY, @today, @end);
        SET @stage = CASE WHEN @days <= 1 THEN N'1d' WHEN @days <= 7 THEN N'7d' ELSE N'30d' END;
        SET @subj = N'Contract ' + @no + N' ends on ' + CONVERT(NVARCHAR(10), @end, 120) + N' (' + CAST(@days AS NVARCHAR(10)) + CASE WHEN @days = 1 THEN N' day)' ELSE N' days)' END;
        SET @body = N'The contract ' + @no + N' for ' + @ctrName + N' at ' + @custName + N' ends on ' + CONVERT(NVARCHAR(10), @end, 120)
                  + N'. If the work should continue, the recruiter can renew it under Contracts; otherwise it ends on that date.';
        SET @key = N'CEXP:' + CONVERT(NVARCHAR(10), @end, 120) + N':' + @stage;
        IF @ctrUser IS NOT NULL EXEC notify.usp_Enqueue 'CONTRACT_EXPIRING', @ctrUser, @subj, @body, @key, 'Contract', @id;
        EXEC notify.usp_Enqueue 'CONTRACT_EXPIRING', @rec, @subj, @body, @key, 'Contract', @id;
        EXEC notify.usp_EnqueueForCustomer @cust, 'CONTRACT_EXPIRING', @subj, @body, @key, 'Contract', @id;
        FETCH NEXT FROM c INTO @id, @no, @end, @cust, @custName, @ctrUser, @ctrName, @rec;
    END
    CLOSE c; DEALLOCATE c;
    SELECT (SELECT COUNT(*) FROM notify.NotificationQueue WHERE NotificationId > @before AND TemplateCode = 'CONTRACT_EXPIRING') AS Queued, @n AS Considered;
END
GO

-- The summary row is prepared by SQL Agent (23:30); this task only delivers it. A missing row is an error, so the
-- run fails visibly instead of preparing the summary itself (no duplicated responsibility).
CREATE OR ALTER PROCEDURE notify.usp_QueueDailyReport @SummaryDate DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @SummaryDate = ISNULL(@SummaryDate, DATEADD(DAY, -1, dbo.fn_BusinessToday()));
    DECLARE @open INT, @apps INT, @ivs INT, @sent INT, @acc INT, @ctr INT, @ts INT;
    SELECT @open = OpenRequisitions, @apps = NewApplications, @ivs = InterviewsScheduled, @sent = OffersExtended, @acc = OffersAccepted,
           @ctr = ActiveContractors, @ts = PendingTimesheets
    FROM report.DailyRecruitmentSummary WHERE SummaryDate = @SummaryDate;
    IF @open IS NULL
    BEGIN
        DECLARE @err NVARCHAR(300) = N'No daily summary exists for ' + CONVERT(NVARCHAR(10), @SummaryDate, 120)
                                   + N'. It is prepared by the SQL Agent job "TAMS - Prepare daily recruitment summary"; check that job.';
        THROW 50002, @err, 1;
    END
    DECLARE @before BIGINT = ISNULL((SELECT MAX(NotificationId) FROM notify.NotificationQueue), 0), @n INT = 0, @u INT;
    DECLARE @subj NVARCHAR(300) = N'TAMS daily summary for ' + CONVERT(NVARCHAR(10), @SummaryDate, 120);
    DECLARE @body NVARCHAR(1000) = N'Recruitment and staffing on ' + CONVERT(NVARCHAR(10), @SummaryDate, 120) + N' (IST):' + NCHAR(10)
        + N'Open job requisitions: ' + CAST(@open AS NVARCHAR(10)) + NCHAR(10) + N'New applications: ' + CAST(@apps AS NVARCHAR(10)) + NCHAR(10)
        + N'Interviews scheduled: ' + CAST(@ivs AS NVARCHAR(10)) + NCHAR(10) + N'Offers sent: ' + CAST(@sent AS NVARCHAR(10)) + NCHAR(10)
        + N'Offers accepted: ' + CAST(@acc AS NVARCHAR(10)) + NCHAR(10) + N'Active contractors: ' + CAST(@ctr AS NVARCHAR(10)) + NCHAR(10)
        + N'Timesheets waiting for approval: ' + CAST(@ts AS NVARCHAR(10)) + NCHAR(10) + N'Details: Reports in TAMS.';
    DECLARE @key NVARCHAR(180) = N'DAILYSUM:' + CONVERT(NVARCHAR(10), @SummaryDate, 120);
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT ur.UserId FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId JOIN sec.Users u ON u.UserId = ur.UserId
        WHERE u.IsActive = 1 AND r.RoleName IN (N'Recruiter', N'HRManager', N'Administrator');
    OPEN c; FETCH NEXT FROM c INTO @u;
    WHILE @@FETCH_STATUS = 0 BEGIN SET @n += 1; EXEC notify.usp_Enqueue 'DAILY_SUMMARY', @u, @subj, @body, @key, 'Summary', NULL; FETCH NEXT FROM c INTO @u; END
    CLOSE c; DEALLOCATE c;
    SELECT (SELECT COUNT(*) FROM notify.NotificationQueue WHERE NotificationId > @before AND TemplateCode = 'DAILY_SUMMARY') AS Queued, @n AS Considered;
END
GO

/* ============================== document files (housekeeping) ============================== */
-- Files of documents deleted more than @OlderThanDays ago whose file is still in the store.
CREATE OR ALTER PROCEDURE doc.usp_ListPurgeableFiles @OlderThanDays INT = 30
AS
BEGIN
    SET NOCOUNT ON;
    IF @OlderThanDays IS NULL OR @OlderThanDays < 7 THROW 50001, N'OlderThanDays must be at least 7.', 1;
    SELECT DocumentId, StoredFileName, DeletedAt FROM doc.Documents
    WHERE IsDeleted = 1 AND FilePurgedAt IS NULL AND DeletedAt < DATEADD(DAY, -@OlderThanDays, SYSUTCDATETIME())
    ORDER BY DocumentId;
END
GO

CREATE OR ALTER PROCEDURE doc.usp_MarkFilePurged @DocumentId INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE doc.Documents SET FilePurgedAt = SYSUTCDATETIME() WHERE DocumentId = @DocumentId AND IsDeleted = 1 AND FilePurgedAt IS NULL;
    IF @@ROWCOUNT = 0 THROW 50004, N'No deleted document with a file still to purge has this id.', 1;
END
GO
