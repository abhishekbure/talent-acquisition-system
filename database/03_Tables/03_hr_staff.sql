/* ============================================================================
   TAMS - 03_Tables / 03_hr_staff.sql   (Internal HR, External staffing)
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;
GO

/* ---------- hr : internal employees ---------- */
IF OBJECT_ID(N'hr.EmployeeRequisitions', N'U') IS NULL
CREATE TABLE hr.EmployeeRequisitions (
    EmployeeRequisitionId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_EmployeeRequisitions PRIMARY KEY,
    RequisitionNo     NVARCHAR(30)  NOT NULL,
    DepartmentId      INT NOT NULL,
    LocationId        INT NULL,
    Title             NVARCHAR(200) NOT NULL,
    Headcount         INT NOT NULL CONSTRAINT DF_EmpReq_Headcount DEFAULT (1),
    EmploymentType    VARCHAR(15) NOT NULL CONSTRAINT DF_EmpReq_Type DEFAULT ('FullTime'),
    Justification     NVARCHAR(1000) NULL,
    BudgetMax         DECIMAL(12,2) NULL,
    RequiredByDate    DATE NULL,
    Status            VARCHAR(12) NOT NULL CONSTRAINT DF_EmpReq_Status DEFAULT ('Draft'),
    RequestedByUserId INT NOT NULL,
    SubmittedAt       DATETIME2(0) NULL,
    CreatedAt         DATETIME2(0) NOT NULL CONSTRAINT DF_EmpReq_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt         DATETIME2(0) NULL,
    RowVer            ROWVERSION NOT NULL
);
GO
IF OBJECT_ID(N'hr.HiringApprovals', N'U') IS NULL
CREATE TABLE hr.HiringApprovals (
    HiringApprovalId      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_HiringApprovals PRIMARY KEY,
    EmployeeRequisitionId INT NOT NULL,
    ApproverUserId        INT NOT NULL,
    Decision              VARCHAR(10) NOT NULL,
    Comments              NVARCHAR(500) NULL,
    DecidedAt             DATETIME2(0) NOT NULL CONSTRAINT DF_HiringApprovals_DecidedAt DEFAULT (SYSUTCDATETIME())
);
GO
IF OBJECT_ID(N'hr.Employees', N'U') IS NULL
CREATE TABLE hr.Employees (
    EmployeeId     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Employees PRIMARY KEY,
    EmployeeNo     NVARCHAR(20) NOT NULL,
    CandidateId    INT NOT NULL,
    JobOfferId     INT NOT NULL,
    DepartmentId   INT NOT NULL,
    LocationId     INT NULL,
    JobTitle       NVARCHAR(150) NOT NULL,
    StartDate      DATE NOT NULL,
    Salary         DECIMAL(12,2) NOT NULL,
    Status         VARCHAR(12) NOT NULL CONSTRAINT DF_Employees_Status DEFAULT ('Onboarding'),
    ManagerUserId  INT NULL,
    CreatedAt      DATETIME2(0) NOT NULL CONSTRAINT DF_Employees_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt      DATETIME2(0) NULL,
    RowVer         ROWVERSION NOT NULL
);
GO
IF OBJECT_ID(N'hr.EmployeeOnboarding', N'U') IS NULL
CREATE TABLE hr.EmployeeOnboarding (
    OnboardingId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_EmployeeOnboarding PRIMARY KEY,
    EmployeeId          INT NOT NULL,
    TaskName            NVARCHAR(150) NOT NULL,
    Category            VARCHAR(15) NOT NULL CONSTRAINT DF_Onb_Category DEFAULT ('Admin'),
    DueDate             DATE NULL,
    Status              VARCHAR(12) NOT NULL CONSTRAINT DF_Onb_Status DEFAULT ('Pending'),
    CompletedByUserId   INT NULL,
    CompletedAt         DATETIME2(0) NULL,
    Notes               NVARCHAR(500) NULL
);
GO
IF OBJECT_ID(N'hr.EmployeeDocuments', N'U') IS NULL
CREATE TABLE hr.EmployeeDocuments (
    EmployeeDocumentId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_EmployeeDocuments PRIMARY KEY,
    EmployeeId         INT NOT NULL,
    DocumentId         INT NOT NULL,
    DocType            VARCHAR(20) NOT NULL CONSTRAINT DF_EmpDocs_Type DEFAULT ('Other')
);
GO
IF OBJECT_ID(N'hr.EmploymentHistory', N'U') IS NULL
CREATE TABLE hr.EmploymentHistory (
    HistoryId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_EmploymentHistory PRIMARY KEY,
    EmployeeId       INT NOT NULL,
    EventType        VARCHAR(20) NOT NULL,
    EffectiveDate    DATE NOT NULL,
    Details          NVARCHAR(500) NULL,
    RecordedByUserId INT NULL,
    RecordedAt       DATETIME2(0) NOT NULL CONSTRAINT DF_EmpHist_RecordedAt DEFAULT (SYSUTCDATETIME())
);
GO

/* ---------- staff : external staffing ---------- */
IF OBJECT_ID(N'staff.Contractors', N'U') IS NULL
CREATE TABLE staff.Contractors (
    ContractorId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Contractors PRIMARY KEY,
    ContractorNo   NVARCHAR(20) NOT NULL,
    CandidateId    INT NOT NULL,
    UserId         INT NULL,
    Status         VARCHAR(10) NOT NULL CONSTRAINT DF_Contractors_Status DEFAULT ('Active'),
    CreatedAt      DATETIME2(0) NOT NULL CONSTRAINT DF_Contractors_CreatedAt DEFAULT (SYSUTCDATETIME()),
    CreatedByUserId INT NULL,
    UpdatedAt      DATETIME2(0) NULL,
    RowVer         ROWVERSION NOT NULL
);
GO
IF OBJECT_ID(N'staff.CustomerRequisitions', N'U') IS NULL
CREATE TABLE staff.CustomerRequisitions (
    CustomerRequisitionId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_CustomerRequisitions PRIMARY KEY,
    RequestNo       NVARCHAR(30) NOT NULL,
    CustomerId      INT NOT NULL,
    Title           NVARCHAR(200) NOT NULL,
    Description     NVARCHAR(2000) NULL,
    Positions       INT NOT NULL CONSTRAINT DF_CustReq_Positions DEFAULT (1),
    SkillsRequired  NVARCHAR(500) NULL,
    StartDate       DATE NULL,
    DurationMonths  INT NULL,
    MaxBillRate     DECIMAL(10,2) NULL,
    WorkLocation    NVARCHAR(150) NULL,
    Status          VARCHAR(12) NOT NULL CONSTRAINT DF_CustReq_Status DEFAULT ('Open'),
    AssignedRecruiterUserId INT NULL,
    CreatedByUserId INT NOT NULL,
    CreatedAt       DATETIME2(0) NOT NULL CONSTRAINT DF_CustReq_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt       DATETIME2(0) NULL,
    RowVer          ROWVERSION NOT NULL
);
GO
IF OBJECT_ID(N'staff.SubmittedCandidates', N'U') IS NULL
CREATE TABLE staff.SubmittedCandidates (
    SubmissionId          INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_SubmittedCandidates PRIMARY KEY,
    CustomerRequisitionId INT NOT NULL,
    CustomerId            INT NOT NULL,
    CandidateId           INT NOT NULL,
    ProposedBillRate      DECIMAL(10,2) NULL,
    Status                VARCHAR(12) NOT NULL CONSTRAINT DF_Submitted_Status DEFAULT ('Submitted'),
    SubmittedByUserId     INT NOT NULL,
    SubmittedAt           DATETIME2(0) NOT NULL CONSTRAINT DF_Submitted_SubmittedAt DEFAULT (SYSUTCDATETIME()),
    Notes                 NVARCHAR(1000) NULL,
    UpdatedAt             DATETIME2(0) NULL,
    RowVer                ROWVERSION NOT NULL
);
GO
IF OBJECT_ID(N'staff.CustomerCandidateDecisions', N'U') IS NULL
CREATE TABLE staff.CustomerCandidateDecisions (
    DecisionId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_CustCandDecisions PRIMARY KEY,
    SubmissionId      INT NOT NULL,
    CustomerId        INT NOT NULL,
    DecidedByUserId   INT NOT NULL,
    Decision          VARCHAR(10) NOT NULL,
    Comments          NVARCHAR(500) NULL,
    DecidedAt         DATETIME2(0) NOT NULL CONSTRAINT DF_CustDec_DecidedAt DEFAULT (SYSUTCDATETIME())
);
GO
IF OBJECT_ID(N'staff.Placements', N'U') IS NULL
CREATE TABLE staff.Placements (
    PlacementId      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Placements PRIMARY KEY,
    SubmissionId     INT NOT NULL,
    CustomerId       INT NOT NULL,
    ContractorId     INT NOT NULL,
    PlacementDate    DATE NOT NULL,
    Status           VARCHAR(10) NOT NULL CONSTRAINT DF_Placements_Status DEFAULT ('Active'),
    CreatedByUserId  INT NOT NULL,
    CreatedAt        DATETIME2(0) NOT NULL CONSTRAINT DF_Placements_CreatedAt DEFAULT (SYSUTCDATETIME())
);
GO
IF OBJECT_ID(N'staff.Contracts', N'U') IS NULL
CREATE TABLE staff.Contracts (
    ContractId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Contracts PRIMARY KEY,
    ContractNo       NVARCHAR(30) NOT NULL,
    PlacementId      INT NOT NULL,
    CustomerId       INT NOT NULL,
    StartDate        DATE NOT NULL,
    EndDate          DATE NOT NULL,
    Status           VARCHAR(12) NOT NULL CONSTRAINT DF_Contracts_Status DEFAULT ('Active'),
    Terms            NVARCHAR(2000) NULL,
    DocumentId       INT NULL,
    CreatedByUserId  INT NOT NULL,
    CreatedAt        DATETIME2(0) NOT NULL CONSTRAINT DF_Contracts_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt        DATETIME2(0) NULL,
    RowVer           ROWVERSION NOT NULL
);
GO
IF OBJECT_ID(N'staff.Assignments', N'U') IS NULL
CREATE TABLE staff.Assignments (
    AssignmentId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Assignments PRIMARY KEY,
    ContractId     INT NOT NULL,
    CustomerId     INT NOT NULL,
    ContractorId   INT NOT NULL,
    RoleTitle      NVARCHAR(150) NOT NULL,
    SiteLocation   NVARCHAR(150) NULL,
    HoursPerWeek   DECIMAL(5,2) NOT NULL CONSTRAINT DF_Assign_Hours DEFAULT (40),
    StartDate      DATE NOT NULL,
    EndDate        DATE NULL,
    Status         VARCHAR(10) NOT NULL CONSTRAINT DF_Assign_Status DEFAULT ('Active'),
    CreatedAt      DATETIME2(0) NOT NULL CONSTRAINT DF_Assign_CreatedAt DEFAULT (SYSUTCDATETIME())
);
GO
IF OBJECT_ID(N'staff.ContractRates', N'U') IS NULL
CREATE TABLE staff.ContractRates (
    ContractRateId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ContractRates PRIMARY KEY,
    ContractId           INT NOT NULL,
    PayRate              DECIMAL(10,2) NOT NULL,        -- what the contractor is PAID (never shown to customer)
    BillRate             DECIMAL(10,2) NOT NULL,        -- what the customer is BILLED
    OvertimePayMultiplier  DECIMAL(4,2) NOT NULL CONSTRAINT DF_Rates_OTPay DEFAULT (1.5),
    OvertimeBillMultiplier DECIMAL(4,2) NOT NULL CONSTRAINT DF_Rates_OTBill DEFAULT (1.5),
    Currency             CHAR(3) NOT NULL CONSTRAINT DF_Rates_Currency DEFAULT ('INR'),
    EffectiveFrom        DATE NOT NULL,
    EffectiveTo          DATE NULL,
    CreatedByUserId      INT NULL,
    CreatedAt            DATETIME2(0) NOT NULL CONSTRAINT DF_Rates_CreatedAt DEFAULT (SYSUTCDATETIME())
);
GO
IF OBJECT_ID(N'staff.ContractExtensions', N'U') IS NULL
CREATE TABLE staff.ContractExtensions (
    ExtensionId      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ContractExtensions PRIMARY KEY,
    ContractId       INT NOT NULL,
    PreviousEndDate  DATE NOT NULL,
    NewEndDate       DATE NOT NULL,
    Reason           NVARCHAR(500) NULL,
    ApprovedByUserId INT NOT NULL,
    CreatedAt        DATETIME2(0) NOT NULL CONSTRAINT DF_Ext_CreatedAt DEFAULT (SYSUTCDATETIME())
);
GO
IF OBJECT_ID(N'staff.ComplianceRecords', N'U') IS NULL
CREATE TABLE staff.ComplianceRecords (
    ComplianceId     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ComplianceRecords PRIMARY KEY,
    ContractorId     INT NOT NULL,
    RecordType       VARCHAR(20) NOT NULL,
    Status           VARCHAR(10) NOT NULL CONSTRAINT DF_Compliance_Status DEFAULT ('Pending'),
    IssuedOn         DATE NULL,
    ExpiresOn        DATE NULL,
    DocumentId       INT NULL,
    VerifiedByUserId INT NULL,
    VerifiedAt       DATETIME2(0) NULL,
    Notes            NVARCHAR(500) NULL
);
GO
