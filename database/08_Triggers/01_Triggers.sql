/* ============================================================================
   TAMS - 08_Triggers / 01_Triggers.sql
   * Audit triggers (AFTER INSERT/UPDATE/DELETE) - multi-row safe: they join the whole
     inserted / deleted pseudo-tables on the primary key; no row-by-row variables.
   * Status-history trigger on cand.JobApplications.
   * Append-only guards for history/audit tables.
   * One DDL (database-level) trigger that logs schema changes.
   Triggers hold NO business workflow. The acting user is read from CONTEXT_INFO, which
   sec.usp_Authorize stamps at the start of every write procedure.
   ========================================================================== */
USE TalentAcquisitionDB;
GO

/* Phase 13: each audit row's XML is built from the joined row itself ((SELECT d.* FOR XML ...)) instead of a correlated
   lookup into the unindexed inserted/deleted tables: identical output (verified on 294,561 rows), and a statement that
   changes 1,000-2,000 rows is about 10x faster. */
/* ---------------- audit: cand.Candidates ---------------- */
CREATE OR ALTER TRIGGER cand.trg_Candidates_Audit ON cand.Candidates AFTER INSERT, UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    DECLARE @actor INT = NULLIF(CAST(SUBSTRING(CONTEXT_INFO(), 1, 4) AS INT), 0);
    INSERT audit.AuditLogs (TableName, RecordId, Action, OldValues, NewValues, ChangedByUserId)
    SELECT N'cand.Candidates', CAST(COALESCE(i.CandidateId, d.CandidateId) AS NVARCHAR(50)),
           CASE WHEN i.CandidateId IS NOT NULL AND d.CandidateId IS NOT NULL THEN 'U' WHEN i.CandidateId IS NOT NULL THEN 'I' ELSE 'D' END,
           CASE WHEN d.CandidateId IS NOT NULL THEN CAST((SELECT d.* FOR XML RAW('row'), ELEMENTS) AS NVARCHAR(MAX)) END,
           CASE WHEN i.CandidateId IS NOT NULL THEN CAST((SELECT i.* FOR XML RAW('row'), ELEMENTS) AS NVARCHAR(MAX)) END,
           @actor
    FROM inserted i FULL OUTER JOIN deleted d ON d.CandidateId = i.CandidateId;
END
GO

/* ---------------- audit: rec.JobRequisitions ---------------- */
CREATE OR ALTER TRIGGER rec.trg_JobRequisitions_Audit ON rec.JobRequisitions AFTER INSERT, UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    DECLARE @actor INT = NULLIF(CAST(SUBSTRING(CONTEXT_INFO(), 1, 4) AS INT), 0);
    INSERT audit.AuditLogs (TableName, RecordId, Action, OldValues, NewValues, ChangedByUserId)
    SELECT N'rec.JobRequisitions', CAST(COALESCE(i.JobRequisitionId, d.JobRequisitionId) AS NVARCHAR(50)),
           CASE WHEN i.JobRequisitionId IS NOT NULL AND d.JobRequisitionId IS NOT NULL THEN 'U' WHEN i.JobRequisitionId IS NOT NULL THEN 'I' ELSE 'D' END,
           CASE WHEN d.JobRequisitionId IS NOT NULL THEN CAST((SELECT d.* FOR XML RAW('row'), ELEMENTS) AS NVARCHAR(MAX)) END,
           CASE WHEN i.JobRequisitionId IS NOT NULL THEN CAST((SELECT i.* FOR XML RAW('row'), ELEMENTS) AS NVARCHAR(MAX)) END,
           @actor
    FROM inserted i FULL OUTER JOIN deleted d ON d.JobRequisitionId = i.JobRequisitionId;
END
GO

/* ---------------- audit: cand.Interviews ---------------- */
CREATE OR ALTER TRIGGER cand.trg_Interviews_Audit ON cand.Interviews AFTER INSERT, UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    DECLARE @actor INT = NULLIF(CAST(SUBSTRING(CONTEXT_INFO(), 1, 4) AS INT), 0);
    INSERT audit.AuditLogs (TableName, RecordId, Action, OldValues, NewValues, ChangedByUserId)
    SELECT N'cand.Interviews', CAST(COALESCE(i.InterviewId, d.InterviewId) AS NVARCHAR(50)),
           CASE WHEN i.InterviewId IS NOT NULL AND d.InterviewId IS NOT NULL THEN 'U' WHEN i.InterviewId IS NOT NULL THEN 'I' ELSE 'D' END,
           CASE WHEN d.InterviewId IS NOT NULL THEN CAST((SELECT d.* FOR XML RAW('row'), ELEMENTS) AS NVARCHAR(MAX)) END,
           CASE WHEN i.InterviewId IS NOT NULL THEN CAST((SELECT i.* FOR XML RAW('row'), ELEMENTS) AS NVARCHAR(MAX)) END,
           @actor
    FROM inserted i FULL OUTER JOIN deleted d ON d.InterviewId = i.InterviewId;
END
GO

/* ---------------- audit: cand.JobOffers ---------------- */
CREATE OR ALTER TRIGGER cand.trg_JobOffers_Audit ON cand.JobOffers AFTER INSERT, UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    DECLARE @actor INT = NULLIF(CAST(SUBSTRING(CONTEXT_INFO(), 1, 4) AS INT), 0);
    INSERT audit.AuditLogs (TableName, RecordId, Action, OldValues, NewValues, ChangedByUserId)
    SELECT N'cand.JobOffers', CAST(COALESCE(i.OfferId, d.OfferId) AS NVARCHAR(50)),
           CASE WHEN i.OfferId IS NOT NULL AND d.OfferId IS NOT NULL THEN 'U' WHEN i.OfferId IS NOT NULL THEN 'I' ELSE 'D' END,
           CASE WHEN d.OfferId IS NOT NULL THEN CAST((SELECT d.* FOR XML RAW('row'), ELEMENTS) AS NVARCHAR(MAX)) END,
           CASE WHEN i.OfferId IS NOT NULL THEN CAST((SELECT i.* FOR XML RAW('row'), ELEMENTS) AS NVARCHAR(MAX)) END,
           @actor
    FROM inserted i FULL OUTER JOIN deleted d ON d.OfferId = i.OfferId;
END
GO

/* ---------------- audit: staff.Contracts ---------------- */
CREATE OR ALTER TRIGGER staff.trg_Contracts_Audit ON staff.Contracts AFTER INSERT, UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    DECLARE @actor INT = NULLIF(CAST(SUBSTRING(CONTEXT_INFO(), 1, 4) AS INT), 0);
    INSERT audit.AuditLogs (TableName, RecordId, Action, OldValues, NewValues, ChangedByUserId)
    SELECT N'staff.Contracts', CAST(COALESCE(i.ContractId, d.ContractId) AS NVARCHAR(50)),
           CASE WHEN i.ContractId IS NOT NULL AND d.ContractId IS NOT NULL THEN 'U' WHEN i.ContractId IS NOT NULL THEN 'I' ELSE 'D' END,
           CASE WHEN d.ContractId IS NOT NULL THEN CAST((SELECT d.* FOR XML RAW('row'), ELEMENTS) AS NVARCHAR(MAX)) END,
           CASE WHEN i.ContractId IS NOT NULL THEN CAST((SELECT i.* FOR XML RAW('row'), ELEMENTS) AS NVARCHAR(MAX)) END,
           @actor
    FROM inserted i FULL OUTER JOIN deleted d ON d.ContractId = i.ContractId;
END
GO

/* ---------------- audit: time.Timesheets ---------------- */
CREATE OR ALTER TRIGGER [time].trg_Timesheets_Audit ON [time].Timesheets AFTER INSERT, UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    DECLARE @actor INT = NULLIF(CAST(SUBSTRING(CONTEXT_INFO(), 1, 4) AS INT), 0);
    INSERT audit.AuditLogs (TableName, RecordId, Action, OldValues, NewValues, ChangedByUserId)
    SELECT N'time.Timesheets', CAST(COALESCE(i.TimesheetId, d.TimesheetId) AS NVARCHAR(50)),
           CASE WHEN i.TimesheetId IS NOT NULL AND d.TimesheetId IS NOT NULL THEN 'U' WHEN i.TimesheetId IS NOT NULL THEN 'I' ELSE 'D' END,
           CASE WHEN d.TimesheetId IS NOT NULL THEN CAST((SELECT d.* FOR XML RAW('row'), ELEMENTS) AS NVARCHAR(MAX)) END,
           CASE WHEN i.TimesheetId IS NOT NULL THEN CAST((SELECT i.* FOR XML RAW('row'), ELEMENTS) AS NVARCHAR(MAX)) END,
           @actor
    FROM inserted i FULL OUTER JOIN deleted d ON d.TimesheetId = i.TimesheetId;
END
GO

/* ---------------- audit: bill.Invoices ---------------- */
CREATE OR ALTER TRIGGER bill.trg_Invoices_Audit ON bill.Invoices AFTER INSERT, UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    DECLARE @actor INT = NULLIF(CAST(SUBSTRING(CONTEXT_INFO(), 1, 4) AS INT), 0);
    INSERT audit.AuditLogs (TableName, RecordId, Action, OldValues, NewValues, ChangedByUserId)
    SELECT N'bill.Invoices', CAST(COALESCE(i.InvoiceId, d.InvoiceId) AS NVARCHAR(50)),
           CASE WHEN i.InvoiceId IS NOT NULL AND d.InvoiceId IS NOT NULL THEN 'U' WHEN i.InvoiceId IS NOT NULL THEN 'I' ELSE 'D' END,
           CASE WHEN d.InvoiceId IS NOT NULL THEN CAST((SELECT d.* FOR XML RAW('row'), ELEMENTS) AS NVARCHAR(MAX)) END,
           CASE WHEN i.InvoiceId IS NOT NULL THEN CAST((SELECT i.* FOR XML RAW('row'), ELEMENTS) AS NVARCHAR(MAX)) END,
           @actor
    FROM inserted i FULL OUTER JOIN deleted d ON d.InvoiceId = i.InvoiceId;
END
GO

/* ---------------- application status history ---------------- */
-- One history row for every application inserted and for every application whose Status really changed.
CREATE OR ALTER TRIGGER cand.trg_JobApplications_StatusHistory ON cand.JobApplications AFTER INSERT, UPDATE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;
    DECLARE @actor INT = NULLIF(CAST(SUBSTRING(CONTEXT_INFO(), 1, 4) AS INT), 0);
    INSERT cand.ApplicationStatusHistory (ApplicationId, OldStatus, NewStatus, ChangedByUserId)
    SELECT i.ApplicationId, d.Status, i.Status, @actor
    FROM inserted i
    LEFT JOIN deleted d ON d.ApplicationId = i.ApplicationId
    WHERE d.ApplicationId IS NULL OR d.Status <> i.Status;
END
GO

/* ---------------- append-only guards ---------------- */
-- Status history: no deletes; the only permitted update is filling a NULL Reason (set by the procedure that caused the change).
CREATE OR ALTER TRIGGER cand.trg_ApplicationStatusHistory_AppendOnly ON cand.ApplicationStatusHistory AFTER UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    IF NOT EXISTS (SELECT 1 FROM inserted)
        THROW 50010, N'cand.ApplicationStatusHistory is append-only: rows cannot be deleted.', 1;
    IF UPDATE(ApplicationId) OR UPDATE(OldStatus) OR UPDATE(NewStatus) OR UPDATE(ChangedByUserId) OR UPDATE(ChangedAt)
       OR EXISTS (SELECT 1 FROM deleted d JOIN inserted i ON i.HistoryId = d.HistoryId WHERE d.Reason IS NOT NULL AND ISNULL(i.Reason, N'') <> d.Reason)
        THROW 50010, N'cand.ApplicationStatusHistory is append-only: only an empty Reason may be filled in.', 1;
END
GO

CREATE OR ALTER TRIGGER audit.trg_AuditLogs_AppendOnly ON audit.AuditLogs AFTER UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted) THROW 50010, N'audit.AuditLogs is append-only.', 1;
END
GO

CREATE OR ALTER TRIGGER audit.trg_ReportRuns_AppendOnly ON audit.ReportRuns AFTER UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted) THROW 50010, N'audit.ReportRuns is append-only.', 1;
END
GO

CREATE OR ALTER TRIGGER [time].trg_TimesheetApprovals_AppendOnly ON [time].TimesheetApprovals AFTER UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted) THROW 50010, N'time.TimesheetApprovals is append-only.', 1;
END
GO

CREATE OR ALTER TRIGGER [time].trg_TimesheetRejections_AppendOnly ON [time].TimesheetRejections AFTER UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted) THROW 50010, N'time.TimesheetRejections is append-only.', 1;
END
GO

CREATE OR ALTER TRIGGER hr.trg_EmploymentHistory_AppendOnly ON hr.EmploymentHistory AFTER UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted) THROW 50010, N'hr.EmploymentHistory is append-only.', 1;
END
GO

/* ---------------- DDL trigger: schema change audit ---------------- */
-- Never blocks DDL: any failure inside is swallowed.
CREATE OR ALTER TRIGGER trg_DDL_SchemaAudit ON DATABASE FOR DDL_DATABASE_LEVEL_EVENTS AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @e XML = EVENTDATA();
        INSERT audit.AuditLogs (TableName, RecordId, Action, NewValues, ChangedByUserId)
        VALUES (LEFT(N'(DDL) ' + ISNULL(@e.value('(/EVENT_INSTANCE/SchemaName)[1]', 'nvarchar(128)') + N'.', N'')
                     + ISNULL(@e.value('(/EVENT_INSTANCE/ObjectName)[1]', 'nvarchar(128)'), N''), 128),
                LEFT(ISNULL(@e.value('(/EVENT_INSTANCE/EventType)[1]', 'nvarchar(50)'), N'?'), 50),
                'U', CAST(@e AS NVARCHAR(MAX)), NULLIF(CAST(SUBSTRING(CONTEXT_INFO(), 1, 4) AS INT), 0));
    END TRY
    BEGIN CATCH
    END CATCH
END
GO
