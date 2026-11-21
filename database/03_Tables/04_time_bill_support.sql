/* ============================================================================
   TAMS - 03_Tables / 04_time_bill_support.sql
   Timesheets, Billing, Documents, Notifications, Audit, Scheduling, Reporting
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;
GO

/* ---------- time ---------- */
IF OBJECT_ID(N'time.Timesheets', N'U') IS NULL
CREATE TABLE [time].Timesheets (
    TimesheetId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Timesheets PRIMARY KEY,
    AssignmentId  INT NOT NULL,
    ContractorId  INT NOT NULL,
    CustomerId    INT NOT NULL,
    WeekStartDate DATE NOT NULL,                               -- always a Monday (see CK)
    Status        VARCHAR(10) NOT NULL CONSTRAINT DF_Timesheets_Status DEFAULT ('Draft'),
    TotalHours    DECIMAL(6,2) NOT NULL CONSTRAINT DF_Timesheets_Total DEFAULT (0),
    SubmittedAt   DATETIME2(0) NULL,
    CreatedAt     DATETIME2(0) NOT NULL CONSTRAINT DF_Timesheets_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt     DATETIME2(0) NULL,
    RowVer        ROWVERSION NOT NULL
);
GO
IF OBJECT_ID(N'time.TimesheetEntries', N'U') IS NULL
CREATE TABLE [time].TimesheetEntries (
    EntryId      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_TimesheetEntries PRIMARY KEY,
    TimesheetId  INT NOT NULL,
    WorkDate     DATE NOT NULL,
    Hours        DECIMAL(5,2) NOT NULL,
    EntryType    VARCHAR(10) NOT NULL CONSTRAINT DF_TsEntries_Type DEFAULT ('Regular'),
    IsBillable   BIT NOT NULL CONSTRAINT DF_TsEntries_Billable DEFAULT (1),
    Notes        NVARCHAR(500) NULL
);
GO
IF OBJECT_ID(N'time.TimesheetApprovals', N'U') IS NULL
CREATE TABLE [time].TimesheetApprovals (
    ApprovalId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_TimesheetApprovals PRIMARY KEY,
    TimesheetId      INT NOT NULL,
    ApprovedByUserId INT NOT NULL,
    ApprovedAt       DATETIME2(0) NOT NULL CONSTRAINT DF_TsApprovals_At DEFAULT (SYSUTCDATETIME()),
    Comments         NVARCHAR(500) NULL
);
GO
IF OBJECT_ID(N'time.TimesheetRejections', N'U') IS NULL
CREATE TABLE [time].TimesheetRejections (
    RejectionId      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_TimesheetRejections PRIMARY KEY,
    TimesheetId      INT NOT NULL,
    RejectedByUserId INT NOT NULL,
    Reason           NVARCHAR(500) NOT NULL,
    RejectedAt       DATETIME2(0) NOT NULL CONSTRAINT DF_TsRejections_At DEFAULT (SYSUTCDATETIME())
);
GO

/* ---------- bill ---------- */
IF OBJECT_ID(N'bill.RateCards', N'U') IS NULL
CREATE TABLE bill.RateCards (
    RateCardId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_RateCards PRIMARY KEY,
    CustomerId       INT NOT NULL,
    RoleCategory     NVARCHAR(100) NOT NULL,
    StandardBillRate DECIMAL(10,2) NOT NULL,
    Currency         CHAR(3) NOT NULL CONSTRAINT DF_RateCards_Currency DEFAULT ('INR'),
    EffectiveFrom    DATE NOT NULL,
    EffectiveTo      DATE NULL,
    IsActive         BIT NOT NULL CONSTRAINT DF_RateCards_Active DEFAULT (1)
);
GO
IF OBJECT_ID(N'bill.Invoices', N'U') IS NULL
CREATE TABLE bill.Invoices (
    InvoiceId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Invoices PRIMARY KEY,
    InvoiceNo        NVARCHAR(30) NOT NULL,
    CustomerId       INT NOT NULL,
    PeriodStart      DATE NOT NULL,
    PeriodEnd        DATE NOT NULL,
    IssueDate        DATE NULL,
    DueDate          DATE NULL,
    Currency         CHAR(3) NOT NULL CONSTRAINT DF_Invoices_Currency DEFAULT ('INR'),
    Subtotal         DECIMAL(12,2) NOT NULL CONSTRAINT DF_Invoices_Subtotal DEFAULT (0),
    TaxRate          DECIMAL(5,2)  NOT NULL CONSTRAINT DF_Invoices_TaxRate DEFAULT (0),
    TaxAmount        DECIMAL(12,2) NOT NULL CONSTRAINT DF_Invoices_Tax DEFAULT (0),
    Total            DECIMAL(12,2) NOT NULL CONSTRAINT DF_Invoices_Total DEFAULT (0),
    Status           VARCHAR(15) NOT NULL CONSTRAINT DF_Invoices_Status DEFAULT ('Draft'),
    GeneratedByUserId INT NOT NULL,
    CreatedAt        DATETIME2(0) NOT NULL CONSTRAINT DF_Invoices_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt        DATETIME2(0) NULL,
    RowVer           ROWVERSION NOT NULL
);
GO
IF OBJECT_ID(N'bill.InvoiceLines', N'U') IS NULL
CREATE TABLE bill.InvoiceLines (
    InvoiceLineId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_InvoiceLines PRIMARY KEY,
    InvoiceId        INT NOT NULL,
    TimesheetEntryId INT NOT NULL,
    Description      NVARCHAR(300) NOT NULL,
    Hours            DECIMAL(5,2) NOT NULL,
    BillRate         DECIMAL(10,2) NOT NULL,         -- snapshot of the rate used
    LineTotal        DECIMAL(12,2) NOT NULL
);
GO
IF OBJECT_ID(N'bill.Payments', N'U') IS NULL
CREATE TABLE bill.Payments (
    PaymentId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Payments PRIMARY KEY,
    InvoiceId        INT NOT NULL,
    CustomerId       INT NOT NULL,
    Amount           DECIMAL(12,2) NOT NULL,
    PaidOn           DATE NOT NULL,
    Method           VARCHAR(15) NOT NULL CONSTRAINT DF_Payments_Method DEFAULT ('BankTransfer'),
    Reference        NVARCHAR(100) NULL,
    RecordedByUserId INT NOT NULL,
    RecordedAt       DATETIME2(0) NOT NULL CONSTRAINT DF_Payments_RecordedAt DEFAULT (SYSUTCDATETIME())
);
GO

/* ---------- doc ---------- */
IF OBJECT_ID(N'doc.Documents', N'U') IS NULL
CREATE TABLE doc.Documents (
    DocumentId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Documents PRIMARY KEY,
    OwnerType        VARCHAR(12) NOT NULL,
    OwnerId          INT NOT NULL,
    CustomerId       INT NULL,                        -- set when a customer-scoped document (e.g. contract)
    StoredFileName   NVARCHAR(100) NOT NULL,          -- GUID-based name on disk, never user supplied
    OriginalFileName NVARCHAR(260) NOT NULL,
    ContentType      NVARCHAR(100) NOT NULL,
    SizeBytes        BIGINT NOT NULL,
    Sha256           BINARY(32) NOT NULL,
    UploadedByUserId INT NOT NULL,
    UploadedAt       DATETIME2(0) NOT NULL CONSTRAINT DF_Documents_UploadedAt DEFAULT (SYSUTCDATETIME()),
    IsDeleted        BIT NOT NULL CONSTRAINT DF_Documents_Deleted DEFAULT (0)
);
GO
/* Phase 12: when a document was deleted, and when its file was removed from the store after the retention period. */
IF COL_LENGTH(N'doc.Documents', N'DeletedAt') IS NULL
BEGIN
    ALTER TABLE doc.Documents ADD DeletedAt DATETIME2(0) NULL, FilePurgedAt DATETIME2(0) NULL;
    -- one-time upgrade of an existing database: earlier deletions take their time from the audit trail (or the upload
    -- time if none). A new database has no rows yet and its audit table is created further down this script.
    IF OBJECT_ID(N'audit.AuditLogs', N'U') IS NOT NULL
    EXEC (N'UPDATE d SET DeletedAt = COALESCE((SELECT MAX(a.ChangedAt) FROM audit.AuditLogs a WHERE a.TableName = N''doc.Documents''
                     AND a.RecordId = CAST(d.DocumentId AS NVARCHAR(50)) AND a.NewValues LIKE N''%<IsDeleted>1</IsDeleted>%''), d.UploadedAt)
           FROM doc.Documents d WHERE d.IsDeleted = 1 AND d.DeletedAt IS NULL;');
END
GO

/* ---------- notify ---------- */
IF OBJECT_ID(N'notify.NotificationQueue', N'U') IS NULL
CREATE TABLE notify.NotificationQueue (
    NotificationId     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_NotificationQueue PRIMARY KEY,
    TemplateCode       VARCHAR(40)  NOT NULL,
    RecipientUserId    INT NULL,
    ToEmail            NVARCHAR(256) NOT NULL,
    Subject            NVARCHAR(300) NOT NULL,
    Body               NVARCHAR(MAX) NOT NULL,
    DedupeKey          NVARCHAR(200) NOT NULL,
    Status             VARCHAR(12) NOT NULL CONSTRAINT DF_NotifQ_Status DEFAULT ('Pending'),
    Attempts           INT NOT NULL CONSTRAINT DF_NotifQ_Attempts DEFAULT (0),
    MaxAttempts        INT NOT NULL CONSTRAINT DF_NotifQ_Max DEFAULT (5),
    NextAttemptAt      DATETIME2(0) NOT NULL CONSTRAINT DF_NotifQ_Next DEFAULT (SYSUTCDATETIME()),
    RelatedEntityType  VARCHAR(30) NULL,
    RelatedEntityId    INT NULL,
    IsRead             BIT NOT NULL CONSTRAINT DF_NotifQ_IsRead DEFAULT (0),
    ReadAt             DATETIME2(0) NULL,
    CreatedAt          DATETIME2(0) NOT NULL CONSTRAINT DF_NotifQ_CreatedAt DEFAULT (SYSUTCDATETIME()),
    ProcessedAt        DATETIME2(0) NULL
);
GO
IF OBJECT_ID(N'notify.NotificationHistory', N'U') IS NULL
CREATE TABLE notify.NotificationHistory (
    HistoryId      BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_NotificationHistory PRIMARY KEY,
    NotificationId BIGINT NOT NULL,
    AttemptNo      INT NOT NULL,
    Outcome        VARCHAR(10) NOT NULL,
    ErrorMessage   NVARCHAR(1000) NULL,
    AttemptedAt    DATETIME2(0) NOT NULL CONSTRAINT DF_NotifHist_At DEFAULT (SYSUTCDATETIME())
);
GO

/* ---------- audit ---------- */
IF OBJECT_ID(N'audit.AuditLogs', N'U') IS NULL
CREATE TABLE audit.AuditLogs (
    AuditId         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AuditLogs PRIMARY KEY,
    TableName       NVARCHAR(128) NOT NULL,
    RecordId        NVARCHAR(50)  NOT NULL,
    Action          CHAR(1) NOT NULL,
    OldValues       NVARCHAR(MAX) NULL,
    NewValues       NVARCHAR(MAX) NULL,
    ChangedByUserId INT NULL,
    DbUser          SYSNAME NOT NULL CONSTRAINT DF_AuditLogs_DbUser DEFAULT (SUSER_SNAME()),
    ChangedAt       DATETIME2(0) NOT NULL CONSTRAINT DF_AuditLogs_At DEFAULT (SYSUTCDATETIME())
);
GO
IF OBJECT_ID(N'audit.LoginHistory', N'U') IS NULL
CREATE TABLE audit.LoginHistory (
    LoginHistoryId BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LoginHistory PRIMARY KEY,
    UserId         INT NULL,
    Email          NVARCHAR(256) NOT NULL,
    Success        BIT NOT NULL,
    FailureReason  NVARCHAR(100) NULL,
    IpAddress      VARCHAR(45) NULL,
    UserAgent      NVARCHAR(300) NULL,
    AttemptedAt    DATETIME2(0) NOT NULL CONSTRAINT DF_LoginHist_At DEFAULT (SYSUTCDATETIME())
);
GO
-- Phase 13 (KI-043): one row per successful report run, written by report.usp_RunReport itself (the API cannot skip it). Append-only.
IF OBJECT_ID(N'audit.ReportRuns', N'U') IS NULL
CREATE TABLE audit.ReportRuns (
    ReportRunId  BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ReportRuns PRIMARY KEY,
    ReportCode   VARCHAR(40)  NOT NULL,
    ActorUserId  INT          NOT NULL,
    OutputFormat VARCHAR(10)  NOT NULL,
    FromDate     DATE NULL,
    ToDate       DATE NULL,
    CustomerId   INT  NULL,             -- the filter as requested (a customer is always scoped to its own anyway)
    [Days]       INT  NULL,
    DbUser       SYSNAME NOT NULL CONSTRAINT DF_ReportRuns_DbUser DEFAULT (USER_NAME()),
    RanAt        DATETIME2(0) NOT NULL CONSTRAINT DF_ReportRuns_At DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_ReportRuns_Format CHECK (OutputFormat IN ('view', 'csv'))
);
GO

/* ---------- sched ---------- */
IF OBJECT_ID(N'sched.JobDefinitions', N'U') IS NULL
CREATE TABLE sched.JobDefinitions (
    JobDefinitionId     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_JobDefinitions PRIMARY KEY,
    JobName             NVARCHAR(100) NOT NULL,
    Owner               VARCHAR(15) NOT NULL,
    Description         NVARCHAR(300) NULL,
    ScheduleDescription NVARCHAR(100) NULL,
    IsEnabled           BIT NOT NULL CONSTRAINT DF_JobDefs_Enabled DEFAULT (1)
);
GO
IF OBJECT_ID(N'sched.JobExecutionHistory', N'U') IS NULL
CREATE TABLE sched.JobExecutionHistory (
    ExecutionId     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_JobExecutionHistory PRIMARY KEY,
    JobDefinitionId INT NOT NULL,
    StartedAt       DATETIME2(0) NOT NULL CONSTRAINT DF_JobExec_Start DEFAULT (SYSUTCDATETIME()),
    FinishedAt      DATETIME2(0) NULL,
    Outcome         VARCHAR(10) NOT NULL CONSTRAINT DF_JobExec_Outcome DEFAULT ('Running'),
    RowsAffected    INT NULL,
    ErrorMessage    NVARCHAR(2000) NULL,
    HostName        NVARCHAR(128) NULL CONSTRAINT DF_JobExec_Host DEFAULT (HOST_NAME())
);
GO
/* Phase 11: what one run did (each index rebuilt, each contract flagged, each backup file ...), and warnings. */
IF OBJECT_ID(N'sched.JobExecutionDetails', N'U') IS NULL
CREATE TABLE sched.JobExecutionDetails (
    DetailId    BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_JobExecutionDetails PRIMARY KEY,
    ExecutionId BIGINT NOT NULL,
    Level       VARCHAR(7) NOT NULL CONSTRAINT DF_JobDetails_Level DEFAULT ('Info'),
    Message     NVARCHAR(1000) NOT NULL,
    LoggedAt    DATETIME2(0) NOT NULL CONSTRAINT DF_JobDetails_At DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_JobDetails_Level CHECK (Level IN ('Info', 'Warning', 'Error'))
);
GO

/* ---------- report ---------- */
IF OBJECT_ID(N'report.DailyRecruitmentSummary', N'U') IS NULL
CREATE TABLE report.DailyRecruitmentSummary (
    SummaryDate         DATE NOT NULL CONSTRAINT PK_DailyRecruitmentSummary PRIMARY KEY,
    OpenRequisitions    INT NOT NULL,
    NewApplications     INT NOT NULL,
    InterviewsScheduled INT NOT NULL,
    OffersExtended      INT NOT NULL,
    OffersAccepted      INT NOT NULL,
    ActiveContractors   INT NOT NULL,
    PendingTimesheets   INT NOT NULL,
    GeneratedAt         DATETIME2(0) NOT NULL CONSTRAINT DF_DailySummary_At DEFAULT (SYSUTCDATETIME())
);
GO
/* Phase 10: catalog of the parameterised reports. The API and the UI are driven by it (which reports a role may run,
   which filters apply, how the chart is drawn); report.usp_RunReport authorises against Roles. Rows are maintained by
   06_StoredProcedures/13_Reports.sql (MERGE), so they are code, not user data. Contains no personal data. */
IF OBJECT_ID(N'report.ReportDefinitions', N'U') IS NULL
CREATE TABLE report.ReportDefinitions (
    ReportCode     VARCHAR(40)   NOT NULL CONSTRAINT PK_ReportDefinitions PRIMARY KEY,
    Category       VARCHAR(20)   NOT NULL,
    Title          NVARCHAR(100) NOT NULL,
    Description    NVARCHAR(400) NOT NULL,
    ProcedureName  SYSNAME       NOT NULL,
    Roles          NVARCHAR(200) NOT NULL,              -- comma list of role names allowed to run it
    DateFilter     NVARCHAR(100) NULL,                  -- what the From/To dates filter (NULL = report has no date range)
    UsesDays       BIT           NOT NULL CONSTRAINT DF_ReportDefs_Days DEFAULT (0),
    CustomerScoped BIT           NOT NULL CONSTRAINT DF_ReportDefs_Cust DEFAULT (0),
    ChartLabel     SYSNAME       NULL,                  -- column on the chart axis (NULL = no chart)
    ChartValue     SYSNAME       NULL,                  -- column plotted; NULL with ChartAggregate 'count' = rows per label
    ChartAggregate VARCHAR(5)    NOT NULL CONSTRAINT DF_ReportDefs_Agg DEFAULT ('value'),
    SortOrder      INT           NOT NULL,
    CONSTRAINT CK_ReportDefs_Category CHECK (Category IN ('Recruitment', 'Staffing', 'HR')),
    CONSTRAINT CK_ReportDefs_Agg CHECK (ChartAggregate IN ('value', 'count', 'sum'))
);
GO
