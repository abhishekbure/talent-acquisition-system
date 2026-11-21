/* ============================================================================
   TAMS - 03_Tables / 02_rec_cand.sql   (Recruitment, Candidate master, Applications,
                                         Interviews, Offers)
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;
GO

/* ---------- rec ---------- */
IF OBJECT_ID(N'rec.RecruitmentSources', N'U') IS NULL
CREATE TABLE rec.RecruitmentSources (
    SourceId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_RecruitmentSources PRIMARY KEY,
    Name        NVARCHAR(100) NOT NULL,
    SourceType  VARCHAR(20)   NOT NULL,
    IsActive    BIT NOT NULL CONSTRAINT DF_RecSources_IsActive DEFAULT (1)
);
GO
IF OBJECT_ID(N'rec.JobRequisitions', N'U') IS NULL
CREATE TABLE rec.JobRequisitions (
    JobRequisitionId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_JobRequisitions PRIMARY KEY,
    EmployeeRequisitionId   INT NOT NULL,
    JobCode                 NVARCHAR(30)  NOT NULL,
    Title                   NVARCHAR(200) NOT NULL,
    DepartmentId            INT NOT NULL,
    LocationId              INT NULL,
    EmploymentType          VARCHAR(15) NOT NULL CONSTRAINT DF_JobReq_EmpType DEFAULT ('FullTime'),
    Openings                INT NOT NULL CONSTRAINT DF_JobReq_Openings DEFAULT (1),
    Status                  VARCHAR(20) NOT NULL CONSTRAINT DF_JobReq_Status DEFAULT ('Draft'),
    OwnerRecruiterUserId    INT NOT NULL,
    OpenedAt                DATETIME2(0) NULL,
    ClosesBy                DATE NULL,
    ClosedAt                DATETIME2(0) NULL,
    CreatedAt               DATETIME2(0) NOT NULL CONSTRAINT DF_JobReq_CreatedAt DEFAULT (SYSUTCDATETIME()),
    CreatedByUserId         INT NULL,
    UpdatedAt               DATETIME2(0) NULL,
    UpdatedByUserId         INT NULL,
    RowVer                  ROWVERSION NOT NULL
);
GO
IF OBJECT_ID(N'rec.JobDescriptions', N'U') IS NULL
CREATE TABLE rec.JobDescriptions (
    JobDescriptionId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_JobDescriptions PRIMARY KEY,
    JobRequisitionId   INT NOT NULL,
    VersionNo          INT NOT NULL CONSTRAINT DF_JobDesc_Ver DEFAULT (1),
    Summary            NVARCHAR(500) NULL,
    Responsibilities   NVARCHAR(MAX) NULL,
    Qualifications     NVARCHAR(MAX) NULL,
    MinExperienceYears DECIMAL(4,1) NOT NULL CONSTRAINT DF_JobDesc_Exp DEFAULT (0),
    SalaryMin          DECIMAL(12,2) NULL,
    SalaryMax          DECIMAL(12,2) NULL,
    IsCurrent          BIT NOT NULL CONSTRAINT DF_JobDesc_Current DEFAULT (1),
    CreatedAt          DATETIME2(0) NOT NULL CONSTRAINT DF_JobDesc_CreatedAt DEFAULT (SYSUTCDATETIME()),
    CreatedByUserId    INT NULL
);
GO
IF OBJECT_ID(N'rec.JobSkills', N'U') IS NULL
CREATE TABLE rec.JobSkills (
    JobSkillId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_JobSkills PRIMARY KEY,
    JobRequisitionId INT NOT NULL,
    SkillName        NVARCHAR(100) NOT NULL,
    IsRequired       BIT NOT NULL CONSTRAINT DF_JobSkills_Req DEFAULT (1),
    MinYears         DECIMAL(4,1) NOT NULL CONSTRAINT DF_JobSkills_Years DEFAULT (0)
);
GO
IF OBJECT_ID(N'rec.JobApprovals', N'U') IS NULL
CREATE TABLE rec.JobApprovals (
    JobApprovalId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_JobApprovals PRIMARY KEY,
    JobRequisitionId INT NOT NULL,
    ApproverUserId   INT NOT NULL,
    Decision         VARCHAR(10) NOT NULL,
    Comments         NVARCHAR(500) NULL,
    DecidedAt        DATETIME2(0) NOT NULL CONSTRAINT DF_JobApprovals_DecidedAt DEFAULT (SYSUTCDATETIME())
);
GO
IF OBJECT_ID(N'rec.JobPostings', N'U') IS NULL
CREATE TABLE rec.JobPostings (
    JobPostingId     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_JobPostings PRIMARY KEY,
    JobRequisitionId INT NOT NULL,
    SourceId         INT NULL,
    PostedAt         DATETIME2(0) NULL,
    ClosesAt         DATETIME2(0) NULL,
    Status           VARCHAR(10) NOT NULL CONSTRAINT DF_JobPostings_Status DEFAULT ('Draft'),
    PostedByUserId   INT NULL,
    CreatedAt        DATETIME2(0) NOT NULL CONSTRAINT DF_JobPostings_CreatedAt DEFAULT (SYSUTCDATETIME())
);
GO

/* ---------- cand : Candidate master (shared by both business models) ---------- */
IF OBJECT_ID(N'cand.Candidates', N'U') IS NULL
CREATE TABLE cand.Candidates (
    CandidateId           INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Candidates PRIMARY KEY,
    UserId                INT NULL,
    FirstName             NVARCHAR(100) NOT NULL,
    LastName              NVARCHAR(100) NOT NULL,
    Email                 NVARCHAR(256) NOT NULL,
    EmailNormalized       NVARCHAR(256) NOT NULL,
    Phone                 NVARCHAR(30)  NULL,
    CurrentTitle          NVARCHAR(150) NULL,
    CurrentEmployer       NVARCHAR(150) NULL,
    TotalExperienceYears  DECIMAL(4,1) NOT NULL CONSTRAINT DF_Cand_Exp DEFAULT (0),
    ExpectedSalary        DECIMAL(12,2) NULL,
    NoticePeriodDays      INT NULL,
    Summary               NVARCHAR(1000) NULL,
    SourceId              INT NULL,
    Status                VARCHAR(12) NOT NULL CONSTRAINT DF_Cand_Status DEFAULT ('Active'),
    CreatedAt             DATETIME2(0) NOT NULL CONSTRAINT DF_Cand_CreatedAt DEFAULT (SYSUTCDATETIME()),
    CreatedByUserId       INT NULL,
    UpdatedAt             DATETIME2(0) NULL,
    UpdatedByUserId       INT NULL,
    RowVer                ROWVERSION NOT NULL
);
GO
IF OBJECT_ID(N'cand.CandidateAddresses', N'U') IS NULL
CREATE TABLE cand.CandidateAddresses (
    AddressId    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_CandidateAddresses PRIMARY KEY,
    CandidateId  INT NOT NULL,
    AddressType  VARCHAR(10) NOT NULL CONSTRAINT DF_CandAddr_Type DEFAULT ('Home'),
    Line1        NVARCHAR(200) NOT NULL,
    Line2        NVARCHAR(200) NULL,
    City         NVARCHAR(100) NOT NULL,
    State        NVARCHAR(100) NULL,
    PostalCode   NVARCHAR(20)  NULL,
    Country      NVARCHAR(100) NOT NULL,
    IsPrimary    BIT NOT NULL CONSTRAINT DF_CandAddr_Primary DEFAULT (0)
);
GO
IF OBJECT_ID(N'cand.CandidateEducation', N'U') IS NULL
CREATE TABLE cand.CandidateEducation (
    EducationId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_CandidateEducation PRIMARY KEY,
    CandidateId   INT NOT NULL,
    Institution   NVARCHAR(200) NOT NULL,
    Degree        NVARCHAR(100) NOT NULL,
    FieldOfStudy  NVARCHAR(100) NULL,
    StartYear     SMALLINT NULL,
    EndYear       SMALLINT NULL,
    Grade         NVARCHAR(30) NULL
);
GO
IF OBJECT_ID(N'cand.CandidateExperience', N'U') IS NULL
CREATE TABLE cand.CandidateExperience (
    ExperienceId  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_CandidateExperience PRIMARY KEY,
    CandidateId   INT NOT NULL,
    Employer      NVARCHAR(150) NOT NULL,
    JobTitle      NVARCHAR(150) NOT NULL,
    StartDate     DATE NOT NULL,
    EndDate       DATE NULL,
    IsCurrent     BIT NOT NULL CONSTRAINT DF_CandExp_Current DEFAULT (0),
    Description   NVARCHAR(1000) NULL
);
GO
IF OBJECT_ID(N'cand.CandidateSkills', N'U') IS NULL
CREATE TABLE cand.CandidateSkills (
    CandidateSkillId  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_CandidateSkills PRIMARY KEY,
    CandidateId       INT NOT NULL,
    SkillName         NVARCHAR(100) NOT NULL,
    YearsExperience   DECIMAL(4,1) NOT NULL CONSTRAINT DF_CandSkills_Years DEFAULT (0),
    ProficiencyLevel  TINYINT NOT NULL CONSTRAINT DF_CandSkills_Level DEFAULT (3)
);
GO
IF OBJECT_ID(N'cand.CandidateDocuments', N'U') IS NULL
CREATE TABLE cand.CandidateDocuments (
    CandidateDocumentId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_CandidateDocuments PRIMARY KEY,
    CandidateId         INT NOT NULL,
    DocumentId          INT NOT NULL,
    DocType             VARCHAR(15) NOT NULL CONSTRAINT DF_CandDocs_Type DEFAULT ('Resume'),
    IsPrimaryResume     BIT NOT NULL CONSTRAINT DF_CandDocs_Primary DEFAULT (0)
);
GO
IF OBJECT_ID(N'cand.JobApplications', N'U') IS NULL
CREATE TABLE cand.JobApplications (
    ApplicationId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_JobApplications PRIMARY KEY,
    CandidateId     INT NOT NULL,
    JobPostingId    INT NOT NULL,
    SourceId        INT NULL,
    Status          VARCHAR(12) NOT NULL CONSTRAINT DF_JobApps_Status DEFAULT ('Applied'),
    CoverNote       NVARCHAR(1000) NULL,
    AppliedAt       DATETIME2(0) NOT NULL CONSTRAINT DF_JobApps_AppliedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt       DATETIME2(0) NULL,
    UpdatedByUserId INT NULL,
    RowVer          ROWVERSION NOT NULL
);
GO
IF OBJECT_ID(N'cand.ApplicationStatusHistory', N'U') IS NULL
CREATE TABLE cand.ApplicationStatusHistory (
    HistoryId       BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ApplicationStatusHistory PRIMARY KEY,
    ApplicationId   INT NOT NULL,
    OldStatus       VARCHAR(12) NULL,
    NewStatus       VARCHAR(12) NOT NULL,
    ChangedByUserId INT NULL,
    ChangedAt       DATETIME2(0) NOT NULL CONSTRAINT DF_AppHist_ChangedAt DEFAULT (SYSUTCDATETIME()),
    Reason          NVARCHAR(500) NULL
);
GO
IF OBJECT_ID(N'cand.Interviews', N'U') IS NULL
CREATE TABLE cand.Interviews (
    InterviewId          INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Interviews PRIMARY KEY,
    JobApplicationId     INT NULL,                -- internal opportunity ...
    SubmittedCandidateId INT NULL,                -- ... or external opportunity (exactly one, see CK)
    CustomerId           INT NULL,                -- set only for external interviews (isolation)
    RoundNo              TINYINT NOT NULL CONSTRAINT DF_Interviews_Round DEFAULT (1),
    InterviewType        VARCHAR(15) NOT NULL CONSTRAINT DF_Interviews_Type DEFAULT ('Technical'),
    StartsAt             DATETIME2(0) NOT NULL,
    EndsAt               DATETIME2(0) NOT NULL,
    Mode                 VARCHAR(10) NOT NULL CONSTRAINT DF_Interviews_Mode DEFAULT ('Video'),
    LocationOrLink       NVARCHAR(300) NULL,
    Status               VARCHAR(12) NOT NULL CONSTRAINT DF_Interviews_Status DEFAULT ('Scheduled'),
    Notes                NVARCHAR(1000) NULL,
    ScheduledByUserId    INT NOT NULL,
    CreatedAt            DATETIME2(0) NOT NULL CONSTRAINT DF_Interviews_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt            DATETIME2(0) NULL,
    RowVer               ROWVERSION NOT NULL
);
GO
IF OBJECT_ID(N'cand.InterviewPanels', N'U') IS NULL
CREATE TABLE cand.InterviewPanels (
    InterviewPanelId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_InterviewPanels PRIMARY KEY,
    InterviewId      INT NOT NULL,
    UserId           INT NOT NULL,
    IsLead           BIT NOT NULL CONSTRAINT DF_Panels_Lead DEFAULT (0)
);
GO
IF OBJECT_ID(N'cand.InterviewFeedback', N'U') IS NULL
CREATE TABLE cand.InterviewFeedback (
    FeedbackId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_InterviewFeedback PRIMARY KEY,
    InterviewId       INT NOT NULL,
    InterviewerUserId INT NOT NULL,
    Rating            TINYINT NOT NULL,
    Recommendation    VARCHAR(10) NOT NULL,
    Strengths         NVARCHAR(1000) NULL,
    Concerns          NVARCHAR(1000) NULL,
    SubmittedAt       DATETIME2(0) NOT NULL CONSTRAINT DF_Feedback_SubmittedAt DEFAULT (SYSUTCDATETIME())
);
GO
IF OBJECT_ID(N'cand.JobOffers', N'U') IS NULL
CREATE TABLE cand.JobOffers (
    OfferId          INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_JobOffers PRIMARY KEY,
    ApplicationId    INT NOT NULL,
    OfferNo          NVARCHAR(30) NOT NULL,
    Designation      NVARCHAR(150) NOT NULL,
    OfferedSalary    DECIMAL(12,2) NOT NULL,
    Currency         CHAR(3) NOT NULL CONSTRAINT DF_Offers_Currency DEFAULT ('INR'),
    StartDate        DATE NOT NULL,
    ExpiresAt        DATETIME2(0) NOT NULL,
    Status           VARCHAR(16) NOT NULL CONSTRAINT DF_Offers_Status DEFAULT ('Draft'),
    CreatedByUserId  INT NOT NULL,
    SentAt           DATETIME2(0) NULL,
    RespondedAt      DATETIME2(0) NULL,
    ResponseNote     NVARCHAR(500) NULL,
    CreatedAt        DATETIME2(0) NOT NULL CONSTRAINT DF_Offers_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt        DATETIME2(0) NULL,
    RowVer           ROWVERSION NOT NULL
);
GO
IF OBJECT_ID(N'cand.OfferApprovals', N'U') IS NULL
CREATE TABLE cand.OfferApprovals (
    OfferApprovalId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_OfferApprovals PRIMARY KEY,
    OfferId         INT NOT NULL,
    ApproverUserId  INT NOT NULL,
    Decision        VARCHAR(10) NOT NULL,
    Comments        NVARCHAR(500) NULL,
    DecidedAt       DATETIME2(0) NOT NULL CONSTRAINT DF_OfferApprovals_DecidedAt DEFAULT (SYSUTCDATETIME())
);
GO
