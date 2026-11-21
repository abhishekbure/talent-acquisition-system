/* ============================================================================
   TAMS - 10_SeedData / 03_Internal_Recruitment.sql
   Demo data for the INTERNAL recruitment flow and the shared Candidate Master:
   hiring requests -> approvals -> jobs -> postings -> candidates -> applications
   (+status history) -> interviews/panels/feedback -> offers/approvals ->
   employee + onboarding.  Dates are relative to "now" so the data stays current.
   Single transaction; skipped if hiring requests already exist.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF EXISTS (SELECT 1 FROM hr.EmployeeRequisitions) BEGIN PRINT 'Internal recruitment data already present - skipped.'; RETURN; END
IF NOT EXISTS (SELECT 1 FROM org.Organizations) BEGIN RAISERROR('Run 02_Organization_Users.sql first.', 16, 1); RETURN; END

BEGIN TRAN;

-- Audit/history triggers (added in Phase 3) must not double-write rows that this script inserts explicitly.
DISABLE TRIGGER ALL ON cand.Candidates;
DISABLE TRIGGER ALL ON rec.JobRequisitions;
DISABLE TRIGGER ALL ON cand.JobApplications;
DISABLE TRIGGER ALL ON cand.Interviews;
DISABLE TRIGGER ALL ON cand.JobOffers;

DECLARE @now   DATETIME2(0) = SYSUTCDATETIME();
DECLARE @today DATE = CAST(SYSUTCDATETIME() AS DATE);
DECLARE @yr    CHAR(4) = CAST(YEAR(SYSUTCDATETIME()) AS CHAR(4));
DECLARE @priya INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'PRIYA.MENON@TAMS.LOCAL');
DECLARE @rahul INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'RAHUL.DESAI@TAMS.LOCAL');
DECLARE @anita INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'ANITA.KAPOOR@TAMS.LOCAL');
DECLARE @vikram INT = (SELECT UserId FROM sec.Users WHERE EmailNormalized = N'VIKRAM.NAIR@TAMS.LOCAL');

/* ---- Department hiring requests (hr.EmployeeRequisitions) ---- */
INSERT hr.EmployeeRequisitions (RequisitionNo, DepartmentId, LocationId, Title, Headcount, EmploymentType, Justification,
                                BudgetMax, RequiredByDate, Status, RequestedByUserId, SubmittedAt, CreatedAt)
SELECT N'ER-' + @yr + N'-' + v.Seq, d.DepartmentId, l.LocationId, v.Title, v.Headcount, 'FullTime', v.Justification,
       v.Budget, DATEADD(DAY, v.ReqByDays, @today), v.Status, u.UserId,
       CASE WHEN v.SubmittedDays IS NULL THEN NULL ELSE DATEADD(DAY, v.SubmittedDays, @now) END,
       DATEADD(DAY, ISNULL(v.SubmittedDays, -1) - 1, @now)
FROM (VALUES
 (N'001', N'Engineering',       N'Bengaluru HQ', N'Senior Backend Engineer', 2, N'Scale the payments platform team',       3200000, 60,  'Approved',  N'VIKRAM.NAIR@TAMS.LOCAL', -50),
 (N'002', N'Engineering',       N'Pune Office',  N'QA Automation Engineer',  1, N'Increase regression automation coverage',2000000, 45,  'Approved',  N'VIKRAM.NAIR@TAMS.LOCAL', -40),
 (N'003', N'Human Resources',   N'Bengaluru HQ', N'HR Business Partner',     1, N'Backfill for attrition',                 2200000, 75,  'Approved',  N'ANITA.KAPOOR@TAMS.LOCAL',-35),
 (N'004', N'Finance',           N'Bengaluru HQ', N'Financial Analyst',       1, N'Month-end close capacity',               1500000, 90,  'Submitted', N'ANITA.KAPOOR@TAMS.LOCAL', -2),
 (N'005', N'Sales & Marketing', N'Pune Office',  N'Sales Executive',         2, N'Regional expansion',                     1200000, 120, 'Rejected',  N'VIKRAM.NAIR@TAMS.LOCAL', -30),
 (N'006', N'Operations',        N'Bengaluru HQ', N'Operations Coordinator',  1, N'Warehouse planning support',              900000, 100, 'Draft',     N'VIKRAM.NAIR@TAMS.LOCAL', NULL)
) v(Seq, Dept, Loc, Title, Headcount, Justification, Budget, ReqByDays, Status, ReqEmail, SubmittedDays)
JOIN org.Departments d ON d.Name = v.Dept
JOIN org.Locations   l ON l.Name = v.Loc
JOIN sec.Users       u ON u.EmailNormalized = v.ReqEmail;

INSERT hr.HiringApprovals (EmployeeRequisitionId, ApproverUserId, Decision, Comments, DecidedAt)
SELECT r.EmployeeRequisitionId, u.UserId, v.Decision, v.Comments, DATEADD(DAY, v.Days, @now)
FROM (VALUES
 (N'001', N'ANITA.KAPOOR@TAMS.LOCAL',  'Approved', N'Approved - aligns with the FY hiring plan.', -48),
 (N'002', N'ANITA.KAPOOR@TAMS.LOCAL',  'Approved', N'Approved.',                                  -38),
 (N'003', N'VIKRAM.NAIR@TAMS.LOCAL',   'Approved', N'Approved - backfill, within budget.',        -33),
 (N'005', N'ANITA.KAPOOR@TAMS.LOCAL',  'Rejected', N'Budget not allocated this half-year.',       -28)
) v(Seq, ApproverEmail, Decision, Comments, Days)
JOIN hr.EmployeeRequisitions r ON r.RequisitionNo = N'ER-' + @yr + N'-' + v.Seq
JOIN sec.Users u ON u.EmailNormalized = v.ApproverEmail;

/* ---- Jobs (rec.JobRequisitions) for approved hiring requests ---- */
INSERT rec.JobRequisitions (EmployeeRequisitionId, JobCode, Title, DepartmentId, LocationId, EmploymentType, Openings,
                            Status, OwnerRecruiterUserId, OpenedAt, ClosesBy, CreatedAt, CreatedByUserId)
SELECT r.EmployeeRequisitionId, N'JOB-' + v.Code + N'-' + @yr + N'-001', r.Title, r.DepartmentId, r.LocationId, 'FullTime', r.Headcount,
       v.Status, u.UserId,
       CASE WHEN v.OpenedDays IS NULL THEN NULL ELSE DATEADD(DAY, v.OpenedDays, @now) END,
       DATEADD(DAY, v.ClosesDays, @today), DATEADD(DAY, v.OpenedDays - 1, @now), u.UserId
FROM (VALUES
 (N'001', N'BE', 'Open',            N'PRIYA.MENON@TAMS.LOCAL', -45, 30),
 (N'002', N'QA', 'Open',            N'RAHUL.DESAI@TAMS.LOCAL', -35, 25),
 (N'003', N'HR', 'PendingApproval', N'PRIYA.MENON@TAMS.LOCAL',  -5, 60)
) v(Seq, Code, Status, OwnerEmail, OpenedDays, ClosesDays)
JOIN hr.EmployeeRequisitions r ON r.RequisitionNo = N'ER-' + @yr + N'-' + v.Seq
JOIN sec.Users u ON u.EmailNormalized = v.OwnerEmail;

UPDATE rec.JobRequisitions SET OpenedAt = NULL WHERE JobCode = N'JOB-HR-' + @yr + N'-001';

INSERT rec.JobDescriptions (JobRequisitionId, VersionNo, Summary, Responsibilities, Qualifications, MinExperienceYears, SalaryMin, SalaryMax, CreatedByUserId)
SELECT jr.JobRequisitionId, 1, v.Summary, v.Resp, v.Qual, v.MinExp, v.SalMin, v.SalMax, jr.OwnerRecruiterUserId
FROM (VALUES
 (N'BE', N'Build and run the services behind our payments platform.',
         N'Design REST APIs, write stored procedures, mentor junior engineers, take part in code reviews and on-call.',
         N'B.E./B.Tech in Computer Science or equivalent; strong C#, .NET Framework and SQL Server experience.', 5.0, 2400000, 3200000),
 (N'QA', N'Own test automation for our web and API products.',
         N'Build automation frameworks, maintain regression suites, integrate tests into CI/CD, triage defects.',
         N'Degree in Computer Science or equivalent; hands-on Selenium and API testing.', 3.0, 1500000, 2000000),
 (N'HR', N'Partner with business leaders on people strategy.',
         N'Employee relations, performance cycles, workforce planning, HR analytics.',
         N'MBA (HR) or equivalent; 4+ years in an HRBP role.', 4.0, 1800000, 2200000)
) v(Code, Summary, Resp, Qual, MinExp, SalMin, SalMax)
JOIN rec.JobRequisitions jr ON jr.JobCode = N'JOB-' + v.Code + N'-' + @yr + N'-001';

INSERT rec.JobSkills (JobRequisitionId, SkillName, IsRequired, MinYears)
SELECT jr.JobRequisitionId, v.Skill, v.IsReq, v.Years
FROM (VALUES
 (N'BE', N'C#', 1, 5.0), (N'BE', N'.NET Framework', 1, 4.0), (N'BE', N'SQL Server', 1, 4.0),
 (N'BE', N'REST APIs', 1, 3.0), (N'BE', N'Angular', 0, 2.0),
 (N'QA', N'Selenium', 1, 3.0), (N'QA', N'C#', 1, 2.0), (N'QA', N'API Testing', 1, 2.0), (N'QA', N'CI/CD', 0, 1.0),
 (N'HR', N'Employee Relations', 1, 4.0), (N'HR', N'HR Analytics', 0, 2.0)
) v(Code, Skill, IsReq, Years)
JOIN rec.JobRequisitions jr ON jr.JobCode = N'JOB-' + v.Code + N'-' + @yr + N'-001';

INSERT rec.JobApprovals (JobRequisitionId, ApproverUserId, Decision, Comments, DecidedAt)
SELECT jr.JobRequisitionId, @anita, 'Approved', N'Job content reviewed and approved for posting.', DATEADD(DAY, v.Days, @now)
FROM (VALUES (N'BE', -44), (N'QA', -34)) v(Code, Days)
JOIN rec.JobRequisitions jr ON jr.JobCode = N'JOB-' + v.Code + N'-' + @yr + N'-001';

INSERT rec.JobPostings (JobRequisitionId, SourceId, PostedAt, ClosesAt, Status, PostedByUserId, CreatedAt)
SELECT jr.JobRequisitionId, s.SourceId, DATEADD(DAY, v.PostedDays, @now), DATEADD(DAY, v.ClosesDays, @now), 'Published', jr.OwnerRecruiterUserId,
       DATEADD(DAY, v.PostedDays, @now)
FROM (VALUES (N'BE', -45, 30), (N'QA', -35, 25)) v(Code, PostedDays, ClosesDays)
JOIN rec.JobRequisitions jr ON jr.JobCode = N'JOB-' + v.Code + N'-' + @yr + N'-001'
JOIN rec.RecruitmentSources s ON s.Name = N'Careers Portal';

/* ---- Candidate Master: one row per person (shared by internal and external flows) ---- */
INSERT cand.Candidates (UserId, FirstName, LastName, Email, EmailNormalized, Phone, CurrentTitle, CurrentEmployer,
                        TotalExperienceYears, ExpectedSalary, NoticePeriodDays, Summary, SourceId, CreatedAt)
SELECT u.UserId, v.First, v.Last, v.Email, UPPER(v.Email), v.Phone, v.Title, v.Employer, v.Exp, v.Sal, v.Notice, v.Summary, s.SourceId,
       DATEADD(DAY, v.CreatedDays, @now)
FROM (VALUES
 (N'Ananya', N'Sharma',    N'ananya.sharma@candidate.example',   N'+91 98450 10001', N'Software Engineer',        N'Zenith Soft',      6.5, 2400000, 60, N'Backend engineer focused on payments APIs.',          N'Careers Portal',    -60),
 (N'Rohan',  N'Gupta',     N'rohan.gupta@candidate.example',     N'+91 98450 10002', N'Backend Developer',        N'Orbit Systems',    8.0, 3000000, 90, N'Senior developer, strong in SQL and distributed systems.', N'LinkedIn',     -55),
 (N'Divya',  N'Reddy',     N'divya.reddy@candidate.example',     N'+91 98450 10003', N'QA Engineer',              N'Kiran Tech',       4.0, 1500000, 30, N'Automation tester with Selenium and API experience.',  N'Careers Portal',    -45),
 (N'Karan',  N'Joshi',     N'karan.joshi@candidate.example',     N'+91 98450 10004', N'SDET',                     N'Nimbus Labs',      5.0, 1800000, 45, N'SDET building CI-integrated test frameworks.',        N'Employee Referral', -50),
 (N'Ravi',   N'Kumar',     N'ravi.kumar@contractor.example',     N'+91 98450 10005', N'Java Consultant',          N'Self-employed',    9.0, NULL,    15, N'Independent senior Java consultant.',                  N'Staffing Agency',  -150),
 (N'Sneha',  N'Pillai',    N'sneha.pillai@contractor.example',   N'+91 98450 10006', N'.NET Developer',           N'Self-employed',    7.0, NULL,    15, N'Independent .NET contractor, telecom domain.',         N'Staffing Agency',  -120),
 (N'Aditya', N'Rao',       N'aditya.rao@candidate.example',      N'+91 98450 10007', N'Full Stack Developer',     N'Bytewave',         5.0, 2200000, 60, N'Full stack developer, Angular and .NET.',             N'LinkedIn',          -40),
 (N'Pooja',  N'Nambiar',   N'pooja.nambiar@candidate.example',   N'+91 98450 10008', N'Data Analyst',             N'Insightly',        3.0, 1200000, 30, N'Data analyst, SQL and Power BI.',                     N'Careers Portal',    -20),
 (N'Imran',  N'Qureshi',   N'imran.qureshi@candidate.example',   N'+91 98450 10009', N'DevOps Engineer',          N'CloudNest',        6.0, 2500000, 60, N'DevOps engineer, Azure and pipelines.',               N'Naukri',            -48),
 (N'Lakshmi',N'Iyer',      N'lakshmi.iyer@candidate.example',    N'+91 98450 10010', N'Business Analyst',         N'FinServe',         7.0, 2000000, 60, N'Business analyst in banking domain.',                  N'Staffing Agency',   -35),
 (N'Siddharth',N'Menon',   N'siddharth.menon@candidate.example', N'+91 98450 10011', N'Project Manager',          N'DeliverIT',       11.0, 3600000, 90, N'Delivery manager, agile and large programmes.',        N'Direct Outreach',   -30),
 (N'Farah',  N'Khan',      N'farah.khan@candidate.example',      N'+91 98450 10012', N'QA Lead',                  N'TestForge',        9.0, 2400000, 60, N'QA lead managing a team of eight.',                   N'LinkedIn',          -42),
 (N'Manish', N'Patel',     N'manish.patel@candidate.example',    N'+91 98450 10013', N'Network Engineer',         N'NetCore',          6.0, 1700000, 30, N'Network engineer, routing and security.',              N'Staffing Agency',   -33),
 (N'Tanvi',  N'Deshmukh',  N'tanvi.deshmukh@candidate.example',  N'+91 98450 10014', N'HR Generalist',            N'PeopleFirst',      5.0, 1600000, 45, N'HR generalist, employee relations.',                   N'Careers Portal',    -10),
 (N'Gaurav', N'Singh',     N'gaurav.singh@candidate.example',    N'+91 98450 10015', N'Python Developer',         N'DataBridge',       4.0, 1700000, 30, N'Python developer, APIs and data pipelines.',           N'Campus Drive',      -25)
) v(First, Last, Email, Phone, Title, Employer, Exp, Sal, Notice, Summary, Source, CreatedDays)
LEFT JOIN sec.Users u ON u.EmailNormalized = UPPER(v.Email)
LEFT JOIN rec.RecruitmentSources s ON s.Name = v.Source;

INSERT cand.CandidateAddresses (CandidateId, AddressType, Line1, City, State, PostalCode, Country, IsPrimary)
SELECT c.CandidateId, 'Home', v.Line1, v.City, v.State, v.Postal, N'India', 1
FROM (VALUES
 (N'ananya.sharma@candidate.example',  N'22 Lake View Apartments',   N'Bengaluru', N'Karnataka',   N'560034'),
 (N'rohan.gupta@candidate.example',    N'8 Jubilee Hills Road',      N'Hyderabad', N'Telangana',   N'500033'),
 (N'divya.reddy@candidate.example',    N'51 Kondapur Main Road',     N'Hyderabad', N'Telangana',   N'500084'),
 (N'karan.joshi@candidate.example',    N'3 Koregaon Park',           N'Pune',      N'Maharashtra', N'411001'),
 (N'ravi.kumar@contractor.example',    N'17 Powai Lake Road',        N'Mumbai',    N'Maharashtra', N'400076'),
 (N'sneha.pillai@contractor.example',  N'9 Aundh Road',              N'Pune',      N'Maharashtra', N'411007'),
 (N'aditya.rao@candidate.example',     N'40 Indiranagar 2nd Stage',  N'Bengaluru', N'Karnataka',   N'560038'),
 (N'pooja.nambiar@candidate.example',  N'12 Marine Drive',           N'Kochi',     N'Kerala',      N'682031'),
 (N'imran.qureshi@candidate.example',  N'5 Banjara Hills',           N'Hyderabad', N'Telangana',   N'500034'),
 (N'lakshmi.iyer@candidate.example',   N'26 Adyar Main Road',        N'Chennai',   N'Tamil Nadu',  N'600020'),
 (N'siddharth.menon@candidate.example',N'31 Salt Lake Sector 5',     N'Kolkata',   N'West Bengal', N'700091'),
 (N'farah.khan@candidate.example',     N'14 Camp Area',              N'Pune',      N'Maharashtra', N'411001'),
 (N'manish.patel@candidate.example',   N'62 Satellite Road',         N'Ahmedabad', N'Gujarat',     N'380015'),
 (N'tanvi.deshmukh@candidate.example', N'7 Shivaji Nagar',           N'Pune',      N'Maharashtra', N'411005'),
 (N'gaurav.singh@candidate.example',   N'88 Sector 62',              N'Noida',     N'Uttar Pradesh',N'201301')
) v(Email, Line1, City, State, Postal)
JOIN cand.Candidates c ON c.EmailNormalized = UPPER(v.Email);

INSERT cand.CandidateEducation (CandidateId, Institution, Degree, FieldOfStudy, StartYear, EndYear, Grade)
SELECT c.CandidateId, v.Inst, v.Degree, v.Field, v.StartY, v.EndY, v.Grade
FROM (VALUES
 (N'ananya.sharma@candidate.example',  N'Deccan Institute of Technology', N'B.E.',   N'Computer Science',            2014, 2018, N'8.4 CGPA'),
 (N'rohan.gupta@candidate.example',    N'Western Ghats University',       N'B.Tech', N'Information Technology',      2011, 2015, N'8.1 CGPA'),
 (N'divya.reddy@candidate.example',    N'Coastal Engineering College',    N'B.Tech', N'Computer Science',            2016, 2020, N'8.6 CGPA'),
 (N'karan.joshi@candidate.example',    N'Northern Plains University',     N'B.E.',   N'Electronics',                 2015, 2019, N'7.9 CGPA'),
 (N'ravi.kumar@contractor.example',    N'Deccan Institute of Technology', N'B.E.',   N'Computer Science',            2008, 2012, N'First class'),
 (N'sneha.pillai@contractor.example',  N'Coastal Engineering College',    N'B.Tech', N'Computer Science',            2010, 2014, N'8.0 CGPA'),
 (N'aditya.rao@candidate.example',     N'Western Ghats University',       N'B.Tech', N'Computer Science',            2015, 2019, N'8.2 CGPA'),
 (N'pooja.nambiar@candidate.example',  N'Coastal Engineering College',    N'B.Sc.',  N'Statistics',                  2017, 2020, N'8.8 CGPA'),
 (N'imran.qureshi@candidate.example',  N'Northern Plains University',     N'B.E.',   N'Computer Science',            2012, 2016, N'7.8 CGPA'),
 (N'lakshmi.iyer@candidate.example',   N'Western Ghats University',       N'MBA',    N'Finance & Systems',           2012, 2014, N'First class'),
 (N'siddharth.menon@candidate.example',N'Deccan Institute of Technology', N'B.E.',   N'Mechanical',                  2004, 2008, N'First class'),
 (N'farah.khan@candidate.example',     N'Northern Plains University',     N'B.Tech', N'Computer Science',            2009, 2013, N'8.0 CGPA'),
 (N'manish.patel@candidate.example',   N'Coastal Engineering College',    N'Diploma',N'Network Engineering',         2012, 2015, N'Distinction'),
 (N'tanvi.deshmukh@candidate.example', N'Western Ghats University',       N'MBA',    N'Human Resources',             2015, 2017, N'8.5 CGPA'),
 (N'gaurav.singh@candidate.example',   N'Northern Plains University',     N'B.Tech', N'Computer Science',            2018, 2022, N'8.3 CGPA')
) v(Email, Inst, Degree, Field, StartY, EndY, Grade)
JOIN cand.Candidates c ON c.EmailNormalized = UPPER(v.Email);

INSERT cand.CandidateExperience (CandidateId, Employer, JobTitle, StartDate, EndDate, IsCurrent, Description)
SELECT c.CandidateId, v.Employer, v.Title, DATEADD(YEAR, -v.StartYearsAgo, @today),
       CASE WHEN v.IsCurrent = 1 THEN NULL ELSE DATEADD(YEAR, -v.EndYearsAgo, @today) END, v.IsCurrent, v.Descr
FROM (VALUES
 (N'ananya.sharma@candidate.example',  N'Zenith Soft',    N'Software Engineer',        6, 0, 1, N'Payments gateway APIs in C# and SQL Server.'),
 (N'rohan.gupta@candidate.example',    N'Orbit Systems',  N'Backend Developer',        8, 0, 1, N'Order management services and reporting stored procedures.'),
 (N'divya.reddy@candidate.example',    N'Kiran Tech',     N'QA Engineer',              4, 0, 1, N'Selenium and REST Assured automation.'),
 (N'karan.joshi@candidate.example',    N'Nimbus Labs',    N'SDET',                     5, 0, 1, N'Test frameworks integrated with Jenkins pipelines.'),
 (N'ravi.kumar@contractor.example',    N'Self-employed',  N'Java Consultant',          5, 0, 1, N'Contract Java engagements for logistics and retail.'),
 (N'ravi.kumar@contractor.example',    N'Pinnacle IT',    N'Senior Java Developer',    9, 5, 0, N'Spring microservices.'),
 (N'sneha.pillai@contractor.example',  N'Self-employed',  N'.NET Developer',           4, 0, 1, N'Telecom billing integrations.'),
 (N'sneha.pillai@contractor.example',  N'Vantage Soft',   N'.NET Developer',           7, 4, 0, N'ASP.NET Web API and SQL Server.'),
 (N'aditya.rao@candidate.example',     N'Bytewave',       N'Full Stack Developer',     5, 0, 1, N'Angular front ends with .NET back ends.'),
 (N'pooja.nambiar@candidate.example',  N'Insightly',      N'Data Analyst',             3, 0, 1, N'Dashboards in Power BI, SQL reporting.'),
 (N'imran.qureshi@candidate.example',  N'CloudNest',      N'DevOps Engineer',          6, 0, 1, N'Azure DevOps pipelines and IaC.'),
 (N'lakshmi.iyer@candidate.example',   N'FinServe',       N'Business Analyst',         7, 0, 1, N'Requirements for retail banking platforms.'),
 (N'farah.khan@candidate.example',     N'TestForge',      N'QA Lead',                  9, 0, 1, N'Led QA for three product lines.'),
 (N'gaurav.singh@candidate.example',   N'DataBridge',     N'Python Developer',         4, 0, 1, N'ETL pipelines and Flask APIs.')
) v(Email, Employer, Title, StartYearsAgo, EndYearsAgo, IsCurrent, Descr)
JOIN cand.Candidates c ON c.EmailNormalized = UPPER(v.Email);

INSERT cand.CandidateSkills (CandidateId, SkillName, YearsExperience, ProficiencyLevel)
SELECT c.CandidateId, v.Skill, v.Years, v.Lvl
FROM (VALUES
 (N'ananya.sharma@candidate.example', N'C#', 6.0, 5), (N'ananya.sharma@candidate.example', N'.NET Framework', 6.0, 4),
 (N'ananya.sharma@candidate.example', N'SQL Server', 5.0, 4), (N'ananya.sharma@candidate.example', N'REST APIs', 5.0, 4),
 (N'rohan.gupta@candidate.example', N'C#', 8.0, 5), (N'rohan.gupta@candidate.example', N'SQL Server', 8.0, 5),
 (N'rohan.gupta@candidate.example', N'REST APIs', 7.0, 4), (N'rohan.gupta@candidate.example', N'.NET Framework', 7.0, 4),
 (N'divya.reddy@candidate.example', N'Selenium', 4.0, 4), (N'divya.reddy@candidate.example', N'C#', 3.0, 3),
 (N'divya.reddy@candidate.example', N'API Testing', 3.0, 4), (N'divya.reddy@candidate.example', N'CI/CD', 2.0, 3),
 (N'karan.joshi@candidate.example', N'Selenium', 5.0, 5), (N'karan.joshi@candidate.example', N'C#', 4.0, 4),
 (N'karan.joshi@candidate.example', N'API Testing', 4.0, 4), (N'karan.joshi@candidate.example', N'CI/CD', 3.0, 4),
 (N'ravi.kumar@contractor.example', N'Java', 9.0, 5), (N'ravi.kumar@contractor.example', N'Spring Boot', 7.0, 5),
 (N'ravi.kumar@contractor.example', N'SQL', 8.0, 4), (N'ravi.kumar@contractor.example', N'REST APIs', 8.0, 5),
 (N'sneha.pillai@contractor.example', N'C#', 7.0, 5), (N'sneha.pillai@contractor.example', N'.NET Framework', 7.0, 5),
 (N'sneha.pillai@contractor.example', N'SQL Server', 6.0, 4), (N'sneha.pillai@contractor.example', N'REST APIs', 6.0, 4),
 (N'aditya.rao@candidate.example', N'Angular', 4.0, 4), (N'aditya.rao@candidate.example', N'C#', 5.0, 4),
 (N'aditya.rao@candidate.example', N'REST APIs', 4.0, 4), (N'aditya.rao@candidate.example', N'SQL Server', 4.0, 3),
 (N'pooja.nambiar@candidate.example', N'SQL', 3.0, 4), (N'pooja.nambiar@candidate.example', N'Power BI', 3.0, 4),
 (N'pooja.nambiar@candidate.example', N'Excel', 3.0, 5),
 (N'imran.qureshi@candidate.example', N'Azure', 5.0, 4), (N'imran.qureshi@candidate.example', N'CI/CD', 6.0, 5),
 (N'imran.qureshi@candidate.example', N'Docker', 4.0, 4),
 (N'lakshmi.iyer@candidate.example', N'Requirements Analysis', 7.0, 5), (N'lakshmi.iyer@candidate.example', N'SQL', 5.0, 3),
 (N'lakshmi.iyer@candidate.example', N'Banking Domain', 7.0, 5),
 (N'siddharth.menon@candidate.example', N'Agile', 10.0, 5), (N'siddharth.menon@candidate.example', N'Program Management', 8.0, 5),
 (N'farah.khan@candidate.example', N'Selenium', 8.0, 4), (N'farah.khan@candidate.example', N'Test Strategy', 9.0, 5),
 (N'farah.khan@candidate.example', N'Java', 6.0, 3),
 (N'manish.patel@candidate.example', N'Cisco Routing', 6.0, 4), (N'manish.patel@candidate.example', N'Network Security', 5.0, 4),
 (N'tanvi.deshmukh@candidate.example', N'Employee Relations', 4.0, 4), (N'tanvi.deshmukh@candidate.example', N'HR Analytics', 2.0, 3),
 (N'gaurav.singh@candidate.example', N'Python', 4.0, 4), (N'gaurav.singh@candidate.example', N'SQL', 3.0, 3),
 (N'gaurav.singh@candidate.example', N'REST APIs', 3.0, 3)
) v(Email, Skill, Years, Lvl)
JOIN cand.Candidates c ON c.EmailNormalized = UPPER(v.Email);

/* ---- Internal applications (a candidate may apply to several jobs) ---- */
DECLARE @app TABLE (Email NVARCHAR(256), PostKey CHAR(2), ApplicationId INT, PRIMARY KEY (Email, PostKey));

INSERT cand.JobApplications (CandidateId, JobPostingId, SourceId, Status, CoverNote, AppliedAt, UpdatedAt)
SELECT c.CandidateId, p.JobPostingId, c.SourceId, v.Status, v.Note, DATEADD(DAY, v.AppliedDays, @now), DATEADD(DAY, v.UpdatedDays, @now)
FROM (VALUES
 (N'ananya.sharma@candidate.example',  'BE', 'Hired',       N'Excited to build payments services at Meridian.', -40, -12),
 (N'rohan.gupta@candidate.example',    'BE', 'Interview',   N'Eight years of backend experience.',               -25,  -3),
 (N'aditya.rao@candidate.example',     'BE', 'Shortlisted', NULL,                                               -20, -14),
 (N'gaurav.singh@candidate.example',   'BE', 'Screening',   NULL,                                               -12,  -9),
 (N'imran.qureshi@candidate.example',  'BE', 'Rejected',    NULL,                                               -30, -26),
 (N'pooja.nambiar@candidate.example',  'BE', 'Applied',     NULL,                                                -3,  -3),
 (N'divya.reddy@candidate.example',    'QA', 'Selected',    N'Looking to grow into automation architecture.',   -28,  -9),
 (N'karan.joshi@candidate.example',    'QA', 'OfferStage',  N'Referred by an existing employee.',               -30,  -6),
 (N'farah.khan@candidate.example',     'QA', 'Rejected',    NULL,                                               -26, -10),
 (N'manish.patel@candidate.example',   'QA', 'Withdrawn',   NULL,                                               -18, -14),
 (N'rohan.gupta@candidate.example',    'QA', 'Applied',     N'Interested in test engineering leadership.',       -5,  -5)
) v(Email, PostKey, Status, Note, AppliedDays, UpdatedDays)
JOIN cand.Candidates c ON c.EmailNormalized = UPPER(v.Email)
JOIN rec.JobRequisitions jr ON jr.JobCode = N'JOB-' + v.PostKey + N'-' + @yr + N'-001'
JOIN rec.JobPostings p ON p.JobRequisitionId = jr.JobRequisitionId;

INSERT @app (Email, PostKey, ApplicationId)
SELECT c.EmailNormalized, CAST(SUBSTRING(jr.JobCode, 5, 2) AS CHAR(2)), a.ApplicationId
FROM cand.JobApplications a
JOIN cand.Candidates c ON c.CandidateId = a.CandidateId
JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId
JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId;

INSERT cand.ApplicationStatusHistory (ApplicationId, OldStatus, NewStatus, ChangedByUserId, ChangedAt, Reason)
SELECT a.ApplicationId, v.OldS, v.NewS, u.UserId, DATEADD(DAY, v.Days, @now), v.Reason
FROM (VALUES
 (N'ananya.sharma@candidate.example','BE',NULL,'Applied',NULL,-40,N'Application received'),
 (N'ananya.sharma@candidate.example','BE','Applied','Screening',N'PRIYA.MENON@TAMS.LOCAL',-38,NULL),
 (N'ananya.sharma@candidate.example','BE','Screening','Shortlisted',N'PRIYA.MENON@TAMS.LOCAL',-35,N'Strong profile'),
 (N'ananya.sharma@candidate.example','BE','Shortlisted','Interview',N'PRIYA.MENON@TAMS.LOCAL',-33,NULL),
 (N'ananya.sharma@candidate.example','BE','Interview','Selected',N'PRIYA.MENON@TAMS.LOCAL',-22,N'Panel recommends hire'),
 (N'ananya.sharma@candidate.example','BE','Selected','OfferStage',N'PRIYA.MENON@TAMS.LOCAL',-20,NULL),
 (N'ananya.sharma@candidate.example','BE','OfferStage','Hired',N'PRIYA.MENON@TAMS.LOCAL',-12,N'Offer accepted'),
 (N'rohan.gupta@candidate.example','BE',NULL,'Applied',NULL,-25,N'Application received'),
 (N'rohan.gupta@candidate.example','BE','Applied','Screening',N'PRIYA.MENON@TAMS.LOCAL',-23,NULL),
 (N'rohan.gupta@candidate.example','BE','Screening','Shortlisted',N'PRIYA.MENON@TAMS.LOCAL',-20,NULL),
 (N'rohan.gupta@candidate.example','BE','Shortlisted','Interview',N'PRIYA.MENON@TAMS.LOCAL',-12,NULL),
 (N'aditya.rao@candidate.example','BE',NULL,'Applied',NULL,-20,N'Application received'),
 (N'aditya.rao@candidate.example','BE','Applied','Screening',N'PRIYA.MENON@TAMS.LOCAL',-18,NULL),
 (N'aditya.rao@candidate.example','BE','Screening','Shortlisted',N'PRIYA.MENON@TAMS.LOCAL',-14,NULL),
 (N'gaurav.singh@candidate.example','BE',NULL,'Applied',NULL,-12,N'Application received'),
 (N'gaurav.singh@candidate.example','BE','Applied','Screening',N'PRIYA.MENON@TAMS.LOCAL',-9,NULL),
 (N'imran.qureshi@candidate.example','BE',NULL,'Applied',NULL,-30,N'Application received'),
 (N'imran.qureshi@candidate.example','BE','Applied','Screening',N'PRIYA.MENON@TAMS.LOCAL',-28,NULL),
 (N'imran.qureshi@candidate.example','BE','Screening','Rejected',N'PRIYA.MENON@TAMS.LOCAL',-26,N'Insufficient .NET Framework depth'),
 (N'pooja.nambiar@candidate.example','BE',NULL,'Applied',NULL,-3,N'Application received'),
 (N'divya.reddy@candidate.example','QA',NULL,'Applied',NULL,-28,N'Application received'),
 (N'divya.reddy@candidate.example','QA','Applied','Screening',N'RAHUL.DESAI@TAMS.LOCAL',-26,NULL),
 (N'divya.reddy@candidate.example','QA','Screening','Shortlisted',N'RAHUL.DESAI@TAMS.LOCAL',-22,NULL),
 (N'divya.reddy@candidate.example','QA','Shortlisted','Interview',N'RAHUL.DESAI@TAMS.LOCAL',-19,NULL),
 (N'divya.reddy@candidate.example','QA','Interview','Selected',N'RAHUL.DESAI@TAMS.LOCAL',-9,N'Panel recommends hire'),
 (N'karan.joshi@candidate.example','QA',NULL,'Applied',NULL,-30,N'Application received'),
 (N'karan.joshi@candidate.example','QA','Applied','Screening',N'RAHUL.DESAI@TAMS.LOCAL',-28,NULL),
 (N'karan.joshi@candidate.example','QA','Screening','Shortlisted',N'RAHUL.DESAI@TAMS.LOCAL',-24,NULL),
 (N'karan.joshi@candidate.example','QA','Shortlisted','Interview',N'RAHUL.DESAI@TAMS.LOCAL',-23,NULL),
 (N'karan.joshi@candidate.example','QA','Interview','Selected',N'RAHUL.DESAI@TAMS.LOCAL',-12,N'Panel recommends hire'),
 (N'karan.joshi@candidate.example','QA','Selected','OfferStage',N'RAHUL.DESAI@TAMS.LOCAL',-6,NULL),
 (N'farah.khan@candidate.example','QA',NULL,'Applied',NULL,-26,N'Application received'),
 (N'farah.khan@candidate.example','QA','Applied','Screening',N'RAHUL.DESAI@TAMS.LOCAL',-24,NULL),
 (N'farah.khan@candidate.example','QA','Screening','Shortlisted',N'RAHUL.DESAI@TAMS.LOCAL',-20,NULL),
 (N'farah.khan@candidate.example','QA','Shortlisted','Interview',N'RAHUL.DESAI@TAMS.LOCAL',-17,NULL),
 (N'farah.khan@candidate.example','QA','Interview','Rejected',N'RAHUL.DESAI@TAMS.LOCAL',-10,N'Automation depth below requirement'),
 (N'manish.patel@candidate.example','QA',NULL,'Applied',NULL,-18,N'Application received'),
 (N'manish.patel@candidate.example','QA','Applied','Withdrawn',NULL,-14,N'Accepted another opportunity'),
 (N'rohan.gupta@candidate.example','QA',NULL,'Applied',NULL,-5,N'Application received')
) v(Email, PostKey, OldS, NewS, ByEmail, Days, Reason)
JOIN @app a ON a.Email = UPPER(v.Email) AND a.PostKey = v.PostKey
LEFT JOIN sec.Users u ON u.EmailNormalized = v.ByEmail;

/* ---- Internal interviews, panels, feedback ---- */
DECLARE @iv TABLE (Email NVARCHAR(256), PostKey CHAR(2), Round TINYINT, InterviewId INT, PRIMARY KEY (Email, PostKey, Round));

INSERT cand.Interviews (JobApplicationId, RoundNo, InterviewType, StartsAt, EndsAt, Mode, LocationOrLink, Status, ScheduledByUserId, CreatedAt)
SELECT a.ApplicationId, v.Round, v.Type,
       DATEADD(HOUR, 10, CAST(DATEADD(DAY, v.Days, @today) AS DATETIME2(0))),
       DATEADD(MINUTE, v.Minutes, DATEADD(HOUR, 10, CAST(DATEADD(DAY, v.Days, @today) AS DATETIME2(0)))),
       v.Mode, v.Link, v.Status, u.UserId, DATEADD(DAY, v.Days - 3, @now)
FROM (VALUES
 (N'ananya.sharma@candidate.example','BE',1,'Technical',-30,60,'Video',N'https://meet.meridian.example/room/be-1','Completed',N'PRIYA.MENON@TAMS.LOCAL'),
 (N'ananya.sharma@candidate.example','BE',2,'HR',-26,45,'Video',N'https://meet.meridian.example/room/be-2','Completed',N'PRIYA.MENON@TAMS.LOCAL'),
 (N'rohan.gupta@candidate.example','BE',1,'Technical',-10,60,'Video',N'https://meet.meridian.example/room/be-3','Completed',N'PRIYA.MENON@TAMS.LOCAL'),
 (N'rohan.gupta@candidate.example','BE',2,'Managerial',2,45,'Onsite',N'Bengaluru HQ - Room Orion','Scheduled',N'PRIYA.MENON@TAMS.LOCAL'),
 (N'karan.joshi@candidate.example','QA',1,'Technical',-22,60,'Video',N'https://meet.meridian.example/room/qa-1','Completed',N'RAHUL.DESAI@TAMS.LOCAL'),
 (N'karan.joshi@candidate.example','QA',2,'Managerial',-16,45,'Video',N'https://meet.meridian.example/room/qa-2','Completed',N'RAHUL.DESAI@TAMS.LOCAL'),
 (N'divya.reddy@candidate.example','QA',1,'Technical',-18,60,'Video',N'https://meet.meridian.example/room/qa-3','Completed',N'RAHUL.DESAI@TAMS.LOCAL'),
 (N'farah.khan@candidate.example','QA',1,'Technical',-15,60,'Video',N'https://meet.meridian.example/room/qa-4','Completed',N'RAHUL.DESAI@TAMS.LOCAL')
) v(Email, PostKey, Round, Type, Days, Minutes, Mode, Link, Status, SchedEmail)
JOIN @app a ON a.Email = UPPER(v.Email) AND a.PostKey = v.PostKey
JOIN sec.Users u ON u.EmailNormalized = v.SchedEmail;

INSERT @iv (Email, PostKey, Round, InterviewId)
SELECT a.Email, a.PostKey, i.RoundNo, i.InterviewId
FROM cand.Interviews i JOIN @app a ON a.ApplicationId = i.JobApplicationId;

INSERT cand.InterviewPanels (InterviewId, UserId, IsLead)
SELECT iv.InterviewId, u.UserId, v.IsLead
FROM (VALUES
 (N'ananya.sharma@candidate.example','BE',1,N'VIKRAM.NAIR@TAMS.LOCAL',1),(N'ananya.sharma@candidate.example','BE',1,N'PRIYA.MENON@TAMS.LOCAL',0),
 (N'ananya.sharma@candidate.example','BE',2,N'ANITA.KAPOOR@TAMS.LOCAL',1),
 (N'rohan.gupta@candidate.example','BE',1,N'VIKRAM.NAIR@TAMS.LOCAL',1),
 (N'rohan.gupta@candidate.example','BE',2,N'VIKRAM.NAIR@TAMS.LOCAL',1),(N'rohan.gupta@candidate.example','BE',2,N'ANITA.KAPOOR@TAMS.LOCAL',0),
 (N'karan.joshi@candidate.example','QA',1,N'RAHUL.DESAI@TAMS.LOCAL',1),(N'karan.joshi@candidate.example','QA',1,N'VIKRAM.NAIR@TAMS.LOCAL',0),
 (N'karan.joshi@candidate.example','QA',2,N'ANITA.KAPOOR@TAMS.LOCAL',1),
 (N'divya.reddy@candidate.example','QA',1,N'RAHUL.DESAI@TAMS.LOCAL',1),(N'divya.reddy@candidate.example','QA',1,N'VIKRAM.NAIR@TAMS.LOCAL',0),
 (N'farah.khan@candidate.example','QA',1,N'RAHUL.DESAI@TAMS.LOCAL',1)
) v(Email, PostKey, Round, UserEmail, IsLead)
JOIN @iv iv ON iv.Email = UPPER(v.Email) AND iv.PostKey = v.PostKey AND iv.Round = v.Round
JOIN sec.Users u ON u.EmailNormalized = v.UserEmail;

INSERT cand.InterviewFeedback (InterviewId, InterviewerUserId, Rating, Recommendation, Strengths, Concerns, SubmittedAt)
SELECT iv.InterviewId, u.UserId, v.Rating, v.Rec, v.Strengths, v.Concerns,
       DATEADD(HOUR, 12, CAST(DATEADD(DAY, v.Days, @today) AS DATETIME2(0)))
FROM (VALUES
 (N'ananya.sharma@candidate.example','BE',1,N'VIKRAM.NAIR@TAMS.LOCAL',5,'StrongYes',N'Strong system design and C# depth.',N'None.',-30),
 (N'ananya.sharma@candidate.example','BE',1,N'PRIYA.MENON@TAMS.LOCAL',4,'Yes',N'Clear communicator.',NULL,-30),
 (N'ananya.sharma@candidate.example','BE',2,N'ANITA.KAPOOR@TAMS.LOCAL',4,'Yes',N'Good culture fit.',NULL,-26),
 (N'rohan.gupta@candidate.example','BE',1,N'VIKRAM.NAIR@TAMS.LOCAL',4,'Yes',N'Solid SQL and API design.',N'Limited Angular exposure.',-10),
 (N'karan.joshi@candidate.example','QA',1,N'RAHUL.DESAI@TAMS.LOCAL',4,'Yes',N'Good framework design.',NULL,-22),
 (N'karan.joshi@candidate.example','QA',1,N'VIKRAM.NAIR@TAMS.LOCAL',5,'StrongYes',N'Excellent CI integration experience.',NULL,-22),
 (N'karan.joshi@candidate.example','QA',2,N'ANITA.KAPOOR@TAMS.LOCAL',4,'Yes',N'Collaborative.',NULL,-16),
 (N'divya.reddy@candidate.example','QA',1,N'RAHUL.DESAI@TAMS.LOCAL',4,'Yes',N'Good API testing skills.',NULL,-18),
 (N'divya.reddy@candidate.example','QA',1,N'VIKRAM.NAIR@TAMS.LOCAL',4,'Yes',N'Quick learner.',N'Limited CI/CD ownership.',-18),
 (N'farah.khan@candidate.example','QA',1,N'RAHUL.DESAI@TAMS.LOCAL',2,'No',N'Strong test strategy.',N'Limited hands-on framework design.',-15)
) v(Email, PostKey, Round, InterviewerEmail, Rating, Rec, Strengths, Concerns, Days)
JOIN @iv iv ON iv.Email = UPPER(v.Email) AND iv.PostKey = v.PostKey AND iv.Round = v.Round
JOIN sec.Users u ON u.EmailNormalized = v.InterviewerEmail;

/* ---- Offers and approvals (approver is never the offer's creator) ---- */
INSERT cand.JobOffers (ApplicationId, OfferNo, Designation, OfferedSalary, Currency, StartDate, ExpiresAt, Status, CreatedByUserId, SentAt, RespondedAt, ResponseNote, CreatedAt)
SELECT a.ApplicationId, N'OFR-' + @yr + N'-' + v.Seq, v.Designation, v.Salary, 'INR', DATEADD(DAY, v.StartDays, @today),
       DATEADD(DAY, v.ExpiresDays, @now), v.Status, u.UserId,
       CASE WHEN v.SentDays IS NULL THEN NULL ELSE DATEADD(DAY, v.SentDays, @now) END,
       CASE WHEN v.RespDays IS NULL THEN NULL ELSE DATEADD(DAY, v.RespDays, @now) END,
       v.RespNote, DATEADD(DAY, v.CreatedDays, @now)
FROM (VALUES
 (N'001', N'ananya.sharma@candidate.example','BE', N'Senior Backend Engineer', 2600000, 14, -5,  'Accepted',        N'PRIYA.MENON@TAMS.LOCAL', -19, -12, N'Happy to accept - thank you.', -21),
 (N'002', N'karan.joshi@candidate.example',  'QA', N'QA Automation Engineer', 1950000, 30,  4,  'Sent',            N'RAHUL.DESAI@TAMS.LOCAL', -6,  NULL, NULL, -8),
 (N'003', N'divya.reddy@candidate.example',  'QA', N'QA Automation Engineer', 1650000, 35, 14,  'PendingApproval', N'RAHUL.DESAI@TAMS.LOCAL', NULL, NULL, NULL, -2)
) v(Seq, Email, PostKey, Designation, Salary, StartDays, ExpiresDays, Status, CreatorEmail, SentDays, RespDays, RespNote, CreatedDays)
JOIN @app a ON a.Email = UPPER(v.Email) AND a.PostKey = v.PostKey
JOIN sec.Users u ON u.EmailNormalized = v.CreatorEmail;

INSERT cand.OfferApprovals (OfferId, ApproverUserId, Decision, Comments, DecidedAt)
SELECT o.OfferId, @anita, 'Approved', v.Comments, DATEADD(DAY, v.Days, @now)
FROM (VALUES (N'001', N'Within approved salary band.', -20), (N'002', N'Approved.', -7)) v(Seq, Comments, Days)
JOIN cand.JobOffers o ON o.OfferNo = N'OFR-' + @yr + N'-' + v.Seq;

/* ---- Accepted offer -> Employee (separate entity from Contractor) + onboarding ---- */
INSERT hr.Employees (EmployeeNo, CandidateId, JobOfferId, DepartmentId, LocationId, JobTitle, StartDate, Salary, Status, ManagerUserId, CreatedAt)
SELECT N'EMP-0001', c.CandidateId, o.OfferId, jr.DepartmentId, jr.LocationId, o.Designation, o.StartDate, o.OfferedSalary, 'Onboarding', @vikram, DATEADD(DAY, -12, @now)
FROM cand.JobOffers o
JOIN cand.JobApplications a ON a.ApplicationId = o.ApplicationId
JOIN cand.Candidates c ON c.CandidateId = a.CandidateId
JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId
JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
WHERE o.OfferNo = N'OFR-' + @yr + N'-001';

INSERT hr.EmployeeOnboarding (EmployeeId, TaskName, Category, DueDate, Status, CompletedByUserId, CompletedAt)
SELECT e.EmployeeId, v.Task, v.Cat, DATEADD(DAY, v.DueDays, @today), v.Status,
       CASE WHEN v.Status = 'Completed' THEN @anita END,
       CASE WHEN v.Status = 'Completed' THEN DATEADD(DAY, v.DueDays - 1, @now) END
FROM (VALUES
 (N'Sign employment agreement',         'Admin',       -10, 'Completed'),
 (N'Submit identity and address proof', 'Compliance',   -8, 'Completed'),
 (N'Bank and payroll setup',            'Payroll',       5, 'Pending'),
 (N'IT equipment provisioning',         'IT',           10, 'Pending'),
 (N'Email and system accounts',         'IT',           12, 'Pending'),
 (N'Orientation session',               'Orientation',  14, 'Pending'),
 (N'Complete compliance training',      'Compliance',   21, 'Pending')
) v(Task, Cat, DueDays, Status)
CROSS JOIN (SELECT EmployeeId FROM hr.Employees WHERE EmployeeNo = N'EMP-0001') e;

INSERT hr.EmploymentHistory (EmployeeId, EventType, EffectiveDate, Details, RecordedByUserId, RecordedAt)
SELECT e.EmployeeId, 'Hired', e.StartDate, N'Hired through offer ' + N'OFR-' + @yr + N'-001', @anita, DATEADD(DAY, -12, @now)
FROM hr.Employees e WHERE e.EmployeeNo = N'EMP-0001';

ENABLE TRIGGER ALL ON cand.Candidates;
ENABLE TRIGGER ALL ON rec.JobRequisitions;
ENABLE TRIGGER ALL ON cand.JobApplications;
ENABLE TRIGGER ALL ON cand.Interviews;
ENABLE TRIGGER ALL ON cand.JobOffers;

COMMIT;
PRINT 'Internal recruitment demo data seeded.';
GO
