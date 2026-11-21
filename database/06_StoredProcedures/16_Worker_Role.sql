/* ============================================================================
   TAMS - 06_StoredProcedures / 16_Worker_Role.sql        (Phase 13: least privilege for the background worker)
   The console app (TalentAcquisition.Scheduler) gets its OWN database identity:
     tams_worker_role   EXECUTE on exactly the procedures the worker calls (below) and the health ping. Nothing else:
                        no table access, no user-facing procedures.
     tams_app_role      (the API) is DENIED those worker procedures, so a compromised API cannot claim queued e-mails
                        (and read their bodies), mark them sent, queue reminders or record task runs (KI-039, KI-053).
   Nested procedures (usp_Enqueue, usp_EnqueueForCustomer, usp_NotifyJobFailure) are reached through ownership
   chaining (all objects owned by dbo), so neither role needs them.
   tams_worker_demo has no login; the worker connects with Windows authentication and runs EXECUTE AS USER on it,
   exactly like the API does with tams_app_demo. A real login is mapped to tams_worker_role at deployment (Phase 15).
   Repeatable; must run after every script that creates the procedures listed below.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;

IF DATABASE_PRINCIPAL_ID(N'tams_worker_role') IS NULL CREATE ROLE tams_worker_role AUTHORIZATION dbo;
GO
IF DATABASE_PRINCIPAL_ID(N'tams_worker_demo') IS NULL CREATE USER tams_worker_demo WITHOUT LOGIN;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_role_members rm WHERE rm.role_principal_id = DATABASE_PRINCIPAL_ID(N'tams_worker_role') AND rm.member_principal_id = DATABASE_PRINCIPAL_ID(N'tams_worker_demo'))
    ALTER ROLE tams_worker_role ADD MEMBER tams_worker_demo;
GO

DECLARE @p TABLE (Name NVARCHAR(256) NOT NULL, WorkerOnly BIT NOT NULL);
INSERT @p VALUES
 (N'notify.usp_ClaimBatch', 1), (N'notify.usp_MarkSent', 1), (N'notify.usp_MarkFailed', 1),                 -- e-mail sender
 (N'notify.usp_QueueInterviewReminders', 1), (N'notify.usp_QueueOfferExpiryReminders', 1),
 (N'notify.usp_QueueTimesheetReminders', 1), (N'notify.usp_QueueContractExpiryNotices', 1),
 (N'notify.usp_QueueDailyReport', 1),                                                                        -- reminder tasks
 (N'sched.usp_AppTaskBegin', 1), (N'sched.usp_AppTaskLog', 1), (N'sched.usp_AppTaskEnd', 1),                 -- run bookkeeping
 (N'doc.usp_ListPurgeableFiles', 1), (N'doc.usp_MarkFilePurged', 1),                                         -- file housekeeping
 (N'sec.usp_Ping', 0);                                                                                       -- --check (the API uses it too)

DECLARE @name NVARCHAR(256), @only BIT, @sql NVARCHAR(600);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT Name, WorkerOnly FROM @p;
OPEN c; FETCH NEXT FROM c INTO @name, @only;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID(@name, N'P') IS NULL BEGIN CLOSE c; DEALLOCATE c; THROW 50004, N'A worker procedure is missing; run the procedure scripts first.', 1; END
    SET @sql = N'GRANT EXECUTE ON ' + QUOTENAME(OBJECT_SCHEMA_NAME(OBJECT_ID(@name))) + N'.' + QUOTENAME(OBJECT_NAME(OBJECT_ID(@name))) + N' TO tams_worker_role;';
    IF @only = 1
        SET @sql += N' DENY EXECUTE ON ' + QUOTENAME(OBJECT_SCHEMA_NAME(OBJECT_ID(@name))) + N'.' + QUOTENAME(OBJECT_NAME(OBJECT_ID(@name))) + N' TO tams_app_role;';
    EXEC sys.sp_executesql @sql;
    FETCH NEXT FROM c INTO @name, @only;
END
CLOSE c; DEALLOCATE c;
GO
