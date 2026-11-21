/* ============================================================================
   TAMS - 11_AgentJobs / 01_Create_Agent_Jobs.sql   (Phase 11)
   Creates (or re-creates, or with Remove=1 deletes) the SQL Server Agent jobs that run the sched.usp_Job_* procedures
   of one database. Run through scripts/database/Install-AgentJobs.ps1, which supplies the sqlcmd variables:
     DatabaseName  target database               JobPrefix  'TAMS' (names 'TAMS - <job>' then equal sched.JobDefinitions) or 'TAMS[<copy>]'
     Enabled       1 = scheduled, 0 = created but only run by hand (test copies)      Remove  1 = delete the jobs only
   Times are the server's local time (IST on this machine). Not part of Run-DatabaseSetup.ps1: jobs are server-wide
   objects in msdb and must not be created for every test database.
   ========================================================================== */
USE msdb;
GO
SET NOCOUNT ON;
DECLARE @db SYSNAME = N'$(DatabaseName)', @prefix NVARCHAR(80) = N'$(JobPrefix)', @enabled TINYINT = $(Enabled), @remove BIT = $(Remove);
IF DB_ID(@db) IS NULL THROW 50001, N'The target database does not exist.', 1;
IF @remove = 0 AND NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories WHERE name = N'TAMS' AND category_class = 1)
    EXEC msdb.dbo.sp_add_category @class = N'JOB', @type = N'LOCAL', @name = N'TAMS';

-- freq_type 4 = daily, 8 = weekly (freq_interval: Sunday 1, Monday 2 ... Saturday 64); subday type 1 = once, 4 = every N minutes
DECLARE @jobs TABLE (Seq INT, Suffix NVARCHAR(100), Command NVARCHAR(400), FreqType INT, FreqInterval INT, SubdayType INT, SubdayInterval INT, StartTime INT, Retries INT);
INSERT @jobs VALUES
 (1, N'Expire stale requisitions',         N'EXEC sched.usp_Job_ExpireRequisitions;',                     4,   1, 1,  0,  10000, 0),
 (2, N'Detect contract expiry',            N'EXEC sched.usp_Job_DetectContractExpiry;',                   4,   1, 1,  0,  11500, 0),
 (3, N'Purge notification queue',          N'EXEC sched.usp_Job_PurgeNotifications;',                     8,   1, 1,  0,  20000, 0),
 (4, N'Prepare daily recruitment summary', N'EXEC sched.usp_Job_DailyRecruitmentSummary;',                4,   1, 1,  0, 233000, 0),
 (5, N'Full database backup',              N'EXEC sched.usp_Job_BackupDatabase @BackupType = ''FULL'';',  8,   1, 1,  0,  30000, 1),
 (6, N'Differential database backup',      N'EXEC sched.usp_Job_BackupDatabase @BackupType = ''DIFF'';',  8, 126, 1,  0,  30000, 1),
 (7, N'Transaction log backup',            N'EXEC sched.usp_Job_BackupDatabase @BackupType = ''LOG'';',   4,   1, 4, 30,   1000, 1),
 (8, N'Index maintenance',                 N'EXEC sched.usp_Job_IndexMaintenance;',                       8,   1, 1,  0,  33000, 0),
 (9, N'Update statistics',                 N'EXEC sched.usp_Job_UpdateStatistics;',                       4,   1, 1,  0,  23000, 0);

DECLARE @seq INT, @suffix NVARCHAR(100), @cmd NVARCHAR(400), @ft INT, @fi INT, @st INT, @si INT, @start INT, @retries INT, @name NVARCHAR(128), @desc NVARCHAR(512), @sched NVARCHAR(128), @rf INT, @owner SYSNAME = SUSER_SNAME(0x01);
DECLARE j CURSOR LOCAL FAST_FORWARD FOR SELECT Seq, Suffix, Command, FreqType, FreqInterval, SubdayType, SubdayInterval, StartTime, Retries FROM @jobs ORDER BY Seq;
OPEN j; FETCH NEXT FROM j INTO @seq, @suffix, @cmd, @ft, @fi, @st, @si, @start, @retries;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @name = @prefix + N' - ' + @suffix;
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @name)
    BEGIN
        EXEC msdb.dbo.sp_delete_job @job_name = @name, @delete_unused_schedule = 1;
        PRINT N'removed  ' + @name;
    END
    IF @remove = 0
    BEGIN
        SET @desc = N'TAMS scheduled job for database ' + @db + N'. Runs ' + @cmd + N' Execution history: sched.JobExecutionHistory / Administrator > Scheduled jobs.';
        EXEC msdb.dbo.sp_add_job @job_name = @name, @enabled = @enabled, @description = @desc, @category_name = N'TAMS',
             @owner_login_name = @owner, @notify_level_eventlog = 2;          -- failures are also written to the Windows Application log
        EXEC msdb.dbo.sp_add_jobstep @job_name = @name, @step_name = N'Run', @subsystem = N'TSQL', @database_name = @db, @command = @cmd,
             @retry_attempts = @retries, @retry_interval = 5, @on_success_action = 1, @on_fail_action = 2;
        SET @sched = @name + N' (schedule)'; SET @rf = CASE WHEN @ft = 8 THEN 1 ELSE 0 END;     -- weekly: every 1 week
        EXEC msdb.dbo.sp_add_jobschedule @job_name = @name, @name = @sched, @enabled = 1, @freq_type = @ft, @freq_interval = @fi,
             @freq_subday_type = @st, @freq_subday_interval = @si, @freq_recurrence_factor = @rf, @active_start_time = @start;
        EXEC msdb.dbo.sp_add_jobserver @job_name = @name, @server_name = N'(local)';
        PRINT N'created  ' + @name + CASE WHEN @enabled = 1 THEN N'' ELSE N'  (disabled: runs only when started by hand)' END;
    END
    FETCH NEXT FROM j INTO @seq, @suffix, @cmd, @ft, @fi, @st, @si, @start, @retries;
END
CLOSE j; DEALLOCATE j;
GO
