/* ============================================================================
   TAMS - 03_Tables / 01_sec_org.sql   (Security, Organizations, Customers)
   Tables carry primary keys and DEFAULT constraints only.
   FKs / UNIQUE / CHECK -> 04_Constraints, indexes -> 05_Indexes.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;
GO

/* ---------- sec ---------- */
IF OBJECT_ID(N'sec.Roles', N'U') IS NULL
CREATE TABLE sec.Roles (
    RoleId       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Roles PRIMARY KEY,
    RoleName     NVARCHAR(50)  NOT NULL,
    Description  NVARCHAR(200) NULL
);
GO
IF OBJECT_ID(N'sec.Users', N'U') IS NULL
CREATE TABLE sec.Users (
    UserId           INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Users PRIMARY KEY,
    Email            NVARCHAR(256) NOT NULL,
    EmailNormalized  NVARCHAR(256) NOT NULL,           -- UPPER(LTRIM(RTRIM(Email)))
    DisplayName      NVARCHAR(150) NOT NULL,
    PasswordHash     VARBINARY(64) NOT NULL,           -- PBKDF2-SHA256 output
    PasswordSalt     VARBINARY(32) NOT NULL,
    HashIterations   INT           NOT NULL CONSTRAINT DF_Users_Iter DEFAULT (210000),
    IsActive         BIT           NOT NULL CONSTRAINT DF_Users_IsActive DEFAULT (1),
    FailedLoginCount INT           NOT NULL CONSTRAINT DF_Users_Failed DEFAULT (0),
    LockoutUntil     DATETIME2(0)  NULL,
    LastLoginAt      DATETIME2(0)  NULL,
    CreatedAt        DATETIME2(0)  NOT NULL CONSTRAINT DF_Users_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt        DATETIME2(0)  NULL,
    RowVer           ROWVERSION    NOT NULL
);
GO
IF OBJECT_ID(N'sec.UserRoles', N'U') IS NULL
CREATE TABLE sec.UserRoles (
    UserId     INT NOT NULL,
    RoleId     INT NOT NULL,
    AssignedAt DATETIME2(0) NOT NULL CONSTRAINT DF_UserRoles_AssignedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_UserRoles PRIMARY KEY (UserId, RoleId)
);
GO
IF OBJECT_ID(N'sec.Permissions', N'U') IS NULL
CREATE TABLE sec.Permissions (
    PermissionId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Permissions PRIMARY KEY,
    Code         NVARCHAR(100) NOT NULL,
    Description  NVARCHAR(200) NULL
);
GO
IF OBJECT_ID(N'sec.RolePermissions', N'U') IS NULL
CREATE TABLE sec.RolePermissions (
    RoleId       INT NOT NULL,
    PermissionId INT NOT NULL,
    CONSTRAINT PK_RolePermissions PRIMARY KEY (RoleId, PermissionId)
);
GO
IF OBJECT_ID(N'sec.AuthTokens', N'U') IS NULL
CREATE TABLE sec.AuthTokens (
    TokenId      BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AuthTokens PRIMARY KEY,
    Jti          UNIQUEIDENTIFIER NOT NULL,
    UserId       INT NOT NULL,
    IssuedAt     DATETIME2(0) NOT NULL CONSTRAINT DF_AuthTokens_IssuedAt DEFAULT (SYSUTCDATETIME()),
    ExpiresAt    DATETIME2(0) NOT NULL,
    RevokedAt    DATETIME2(0) NULL,
    RevokeReason NVARCHAR(100) NULL
);
GO
IF OBJECT_ID(N'sec.PasswordResetTokens', N'U') IS NULL
CREATE TABLE sec.PasswordResetTokens (
    ResetId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PasswordResetTokens PRIMARY KEY,
    UserId    INT NOT NULL,
    TokenHash VARBINARY(32) NOT NULL,                 -- SHA-256 of the emailed token; token itself never stored
    ExpiresAt DATETIME2(0) NOT NULL,
    UsedAt    DATETIME2(0) NULL,
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_PwdReset_CreatedAt DEFAULT (SYSUTCDATETIME())
);
GO

/* Phase 9: e-mail ownership. A self-registered login cannot sign in (and is not linked to a recruiter-created candidate record)
   until the address is proven, by the e-mailed verification link or by completing an e-mailed password reset. */
IF COL_LENGTH(N'sec.Users', N'EmailVerifiedAt') IS NULL
BEGIN
    ALTER TABLE sec.Users ADD EmailVerifiedAt DATETIME2(0) NULL;
    -- one-time upgrade of an existing database: accounts created before verification existed were created by an
    -- administrator, seeded, or registered under the old rules, and keep working
    EXEC (N'UPDATE sec.Users SET EmailVerifiedAt = CreatedAt WHERE EmailVerifiedAt IS NULL;');
END
GO
IF OBJECT_ID(N'sec.EmailVerificationTokens', N'U') IS NULL
CREATE TABLE sec.EmailVerificationTokens (
    VerificationId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_EmailVerificationTokens PRIMARY KEY,
    UserId    INT NOT NULL,
    TokenHash VARBINARY(32) NOT NULL,                 -- SHA-256 of the e-mailed token; the token itself is never stored
    ExpiresAt DATETIME2(0) NOT NULL,
    UsedAt    DATETIME2(0) NULL,
    CreatedAt DATETIME2(0) NOT NULL CONSTRAINT DF_EmailVerify_CreatedAt DEFAULT (SYSUTCDATETIME())
);
GO

/* ---------- org ---------- */
IF OBJECT_ID(N'org.Organizations', N'U') IS NULL
CREATE TABLE org.Organizations (
    OrganizationId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Organizations PRIMARY KEY,
    Name           NVARCHAR(200) NOT NULL,
    LegalName      NVARCHAR(250) NULL,
    Website        NVARCHAR(200) NULL,
    CreatedAt      DATETIME2(0)  NOT NULL CONSTRAINT DF_Org_CreatedAt DEFAULT (SYSUTCDATETIME())
);
GO
IF OBJECT_ID(N'org.Locations', N'U') IS NULL
CREATE TABLE org.Locations (
    LocationId     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Locations PRIMARY KEY,
    OrganizationId INT NOT NULL,
    Name           NVARCHAR(100) NOT NULL,
    AddressLine    NVARCHAR(200) NULL,
    City           NVARCHAR(100) NOT NULL,
    Country        NVARCHAR(100) NOT NULL,
    IsActive       BIT NOT NULL CONSTRAINT DF_Locations_IsActive DEFAULT (1)
);
GO
IF OBJECT_ID(N'org.Departments', N'U') IS NULL
CREATE TABLE org.Departments (
    DepartmentId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Departments PRIMARY KEY,
    OrganizationId INT NOT NULL,
    Name           NVARCHAR(100) NOT NULL,
    CostCenter     NVARCHAR(30)  NULL,
    HeadUserId     INT NULL,
    IsActive       BIT NOT NULL CONSTRAINT DF_Departments_IsActive DEFAULT (1)
);
GO
IF OBJECT_ID(N'org.OrganizationUsers', N'U') IS NULL
CREATE TABLE org.OrganizationUsers (
    OrgUserId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_OrganizationUsers PRIMARY KEY,
    UserId           INT NOT NULL,
    OrganizationId   INT NOT NULL,
    DepartmentId     INT NULL,
    JobTitle         NVARCHAR(100) NULL,
    IsHiringManager  BIT NOT NULL CONSTRAINT DF_OrgUsers_HM DEFAULT (0)
);
GO
IF OBJECT_ID(N'org.Customers', N'U') IS NULL
CREATE TABLE org.Customers (
    CustomerId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Customers PRIMARY KEY,
    CustomerCode      NVARCHAR(20)  NOT NULL,
    Name              NVARCHAR(200) NOT NULL,
    Industry          NVARCHAR(100) NULL,
    Status            VARCHAR(15)   NOT NULL CONSTRAINT DF_Customers_Status DEFAULT ('Active'),
    BillingEmail      NVARCHAR(256) NULL,
    BillingAddress    NVARCHAR(300) NULL,
    PaymentTermsDays  INT NOT NULL CONSTRAINT DF_Customers_Terms DEFAULT (30),
    AccountManagerUserId INT NULL,
    CreatedAt         DATETIME2(0) NOT NULL CONSTRAINT DF_Customers_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt         DATETIME2(0) NULL,
    RowVer            ROWVERSION NOT NULL
);
GO
IF OBJECT_ID(N'org.CustomerUsers', N'U') IS NULL
CREATE TABLE org.CustomerUsers (
    CustomerUserId   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_CustomerUsers PRIMARY KEY,
    UserId           INT NOT NULL,
    CustomerId       INT NOT NULL,
    JobTitle         NVARCHAR(100) NULL,
    IsPrimaryContact BIT NOT NULL CONSTRAINT DF_CustUsers_Primary DEFAULT (0)
);
GO
