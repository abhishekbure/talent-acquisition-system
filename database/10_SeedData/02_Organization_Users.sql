/* ============================================================================
   TAMS - 10_SeedData / 02_Organization_Users.sql
   One internal organization, departments, locations, three customers and
   development users for ALL SIX ROLES.

   SECURITY: no password or password hash is stored in this repository. Users are
   created with an unusable placeholder hash (cannot log in). Run
   scripts/database/Set-DevPasswords.ps1 to generate random passwords, store a
   PBKDF2-SHA256 hash + salt, and write the credentials to an UNTRACKED local file.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF EXISTS (SELECT 1 FROM org.Organizations) BEGIN PRINT 'Organization data already present - skipped.'; RETURN; END

BEGIN TRAN;

INSERT org.Organizations (Name, LegalName, Website)
VALUES (N'Meridian Technologies', N'Meridian Technologies Private Limited', N'https://meridian.example');
DECLARE @org INT = SCOPE_IDENTITY();

INSERT org.Locations (OrganizationId, Name, AddressLine, City, Country) VALUES
 (@org, N'Bengaluru HQ',  N'14 Residency Road',        N'Bengaluru', N'India'),
 (@org, N'Pune Office',   N'Plot 7, Hinjewadi Phase 2', N'Pune',      N'India'),
 (@org, N'Remote - India',NULL,                         N'Remote',    N'India');

INSERT org.Departments (OrganizationId, Name, CostCenter) VALUES
 (@org, N'Engineering',        N'CC-100'),
 (@org, N'Human Resources',    N'CC-200'),
 (@org, N'Finance',            N'CC-300'),
 (@org, N'Sales & Marketing',  N'CC-400'),
 (@org, N'Operations',         N'CC-500');

-- Users: placeholder hash 0x00 = cannot authenticate until Set-DevPasswords.ps1 runs
-- Seeded accounts are trusted (their addresses are fictitious test domains) and count as verified.
INSERT sec.Users (Email, EmailNormalized, DisplayName, PasswordHash, PasswordSalt, EmailVerifiedAt)
SELECT v.Email, UPPER(v.Email), v.DisplayName, 0x00, 0x00, SYSUTCDATETIME() FROM (VALUES
 (N'admin@tams.local',                      N'System Administrator'),
 (N'priya.menon@tams.local',                N'Priya Menon'),
 (N'rahul.desai@tams.local',                N'Rahul Desai'),
 (N'anita.kapoor@tams.local',               N'Anita Kapoor'),
 (N'vikram.nair@tams.local',                N'Vikram Nair'),
 (N'arjun.shah@apexlogistics.example',      N'Arjun Shah'),
 (N'neha.verma@apexlogistics.example',      N'Neha Verma'),
 (N'meera.iyer@brightwave.example',         N'Meera Iyer'),
 (N'kabir.malhotra@crestline.example',      N'Kabir Malhotra'),
 (N'ravi.kumar@contractor.example',         N'Ravi Kumar'),
 (N'sneha.pillai@contractor.example',       N'Sneha Pillai'),
 (N'ananya.sharma@candidate.example',       N'Ananya Sharma'),
 (N'rohan.gupta@candidate.example',         N'Rohan Gupta'),
 (N'divya.reddy@candidate.example',         N'Divya Reddy'),
 (N'karan.joshi@candidate.example',         N'Karan Joshi')
) v(Email, DisplayName);

INSERT sec.UserRoles (UserId, RoleId)
SELECT u.UserId, r.RoleId FROM (VALUES
 (N'admin@tams.local',                 N'Administrator'),
 (N'priya.menon@tams.local',           N'Recruiter'),
 (N'rahul.desai@tams.local',           N'Recruiter'),
 (N'anita.kapoor@tams.local',          N'HRManager'),
 (N'vikram.nair@tams.local',           N'HRManager'),
 (N'arjun.shah@apexlogistics.example', N'Customer'),
 (N'neha.verma@apexlogistics.example', N'Customer'),
 (N'meera.iyer@brightwave.example',    N'Customer'),
 (N'kabir.malhotra@crestline.example', N'Customer'),
 (N'ravi.kumar@contractor.example',    N'Contractor'),
 (N'sneha.pillai@contractor.example',  N'Contractor'),
 (N'ananya.sharma@candidate.example',  N'Candidate'),
 (N'rohan.gupta@candidate.example',    N'Candidate'),
 (N'divya.reddy@candidate.example',    N'Candidate'),
 (N'karan.joshi@candidate.example',    N'Candidate')
) m(Email, RoleName)
JOIN sec.Users u ON u.EmailNormalized = UPPER(m.Email)
JOIN sec.Roles r ON r.RoleName = m.RoleName;

-- Internal staff -> organization/department (hiring managers are HRManager-role users flagged IsHiringManager)
INSERT org.OrganizationUsers (UserId, OrganizationId, DepartmentId, JobTitle, IsHiringManager)
SELECT u.UserId, @org, d.DepartmentId, m.JobTitle, m.IsHM FROM (VALUES
 (N'admin@tams.local',        NULL,                 N'System Administrator',       0),
 (N'priya.menon@tams.local',  N'Human Resources',   N'Senior Recruiter',           0),
 (N'rahul.desai@tams.local',  N'Human Resources',   N'Recruiter',                  0),
 (N'anita.kapoor@tams.local', N'Human Resources',   N'Head of Human Resources',    1),
 (N'vikram.nair@tams.local',  N'Engineering',       N'Engineering Manager',        1)
) m(Email, DeptName, JobTitle, IsHM)
JOIN sec.Users u ON u.EmailNormalized = UPPER(m.Email)
LEFT JOIN org.Departments d ON d.OrganizationId = @org AND d.Name = m.DeptName;

UPDATE org.Departments SET HeadUserId = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'VIKRAM.NAIR@TAMS.LOCAL')
 WHERE OrganizationId = @org AND Name = N'Engineering';
UPDATE org.Departments SET HeadUserId = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ANITA.KAPOOR@TAMS.LOCAL')
 WHERE OrganizationId = @org AND Name = N'Human Resources';

-- Customers (three, with different payment terms) + their login contacts
INSERT org.Customers (CustomerCode, Name, Industry, BillingEmail, BillingAddress, PaymentTermsDays, AccountManagerUserId)
SELECT v.Code, v.Name, v.Industry, v.BillingEmail, v.Addr, v.Terms, u.UserId FROM (VALUES
 (N'APEX',   N'Apex Logistics Pvt Ltd',   N'Logistics',        N'accounts@apexlogistics.example', N'Andheri East, Mumbai 400069',   30, N'PRIYA.MENON@TAMS.LOCAL'),
 (N'BRIGHT', N'Brightwave Telecom',       N'Telecommunications',N'ap@brightwave.example',         N'Baner Road, Pune 411045',      45, N'RAHUL.DESAI@TAMS.LOCAL'),
 (N'CREST',  N'Crestline Financial',      N'Financial Services',N'payables@crestline.example',    N'Nariman Point, Mumbai 400021', 30, N'PRIYA.MENON@TAMS.LOCAL')
) v(Code, Name, Industry, BillingEmail, Addr, Terms, MgrEmail)
JOIN sec.Users u ON u.EmailNormalized = v.MgrEmail;

INSERT org.CustomerUsers (UserId, CustomerId, JobTitle, IsPrimaryContact)
SELECT u.UserId, c.CustomerId, m.JobTitle, m.IsPrimary FROM (VALUES
 (N'arjun.shah@apexlogistics.example', N'APEX',   N'IT Delivery Head',   1),
 (N'neha.verma@apexlogistics.example', N'APEX',   N'Project Manager',    0),
 (N'meera.iyer@brightwave.example',    N'BRIGHT', N'Engineering Director',1),
 (N'kabir.malhotra@crestline.example', N'CREST',  N'Head of QA',         1)
) m(Email, Code, JobTitle, IsPrimary)
JOIN sec.Users u ON u.EmailNormalized = UPPER(m.Email)
JOIN org.Customers c ON c.CustomerCode = m.Code;

COMMIT;
PRINT 'Organization, departments, customers and users seeded (accounts cannot log in until Set-DevPasswords.ps1 is run).';
GO
