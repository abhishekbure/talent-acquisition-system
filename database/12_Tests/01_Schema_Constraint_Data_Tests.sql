/* ============================================================================
   TAMS - 12_Tests / 01_Schema_Constraint_Data_Tests.sql
   Phase 2 acceptance tests. Read-only: every write is inside a transaction that is
   rolled back. Prints PASS/FAIL per test and raises an error (severity 16) if any
   test fails, so the runner returns a non-zero exit code.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;

CREATE TABLE #r (Id INT IDENTITY(1,1), TestName NVARCHAR(200), Passed BIT, Detail NVARCHAR(400));

/* ===================== A. STRUCTURE ===================== */
INSERT #r (TestName, Passed, Detail)
SELECT N'A01 all 13 schemas exist', CASE WHEN COUNT(*) = 13 THEN 1 ELSE 0 END, CONCAT(COUNT(*), N' of 13 found')
FROM sys.schemas WHERE name IN (N'sec',N'org',N'rec',N'cand',N'hr',N'staff',N'time',N'bill',N'doc',N'notify',N'audit',N'report',N'sched');

DECLARE @expected TABLE (SchemaName SYSNAME, TableName SYSNAME);
INSERT @expected VALUES
 (N'sec',N'Users'),(N'sec',N'Roles'),(N'sec',N'UserRoles'),(N'sec',N'Permissions'),(N'sec',N'RolePermissions'),(N'sec',N'AuthTokens'),(N'sec',N'PasswordResetTokens'),
 (N'org',N'Organizations'),(N'org',N'OrganizationUsers'),(N'org',N'Departments'),(N'org',N'Locations'),(N'org',N'Customers'),(N'org',N'CustomerUsers'),
 (N'rec',N'JobRequisitions'),(N'rec',N'JobDescriptions'),(N'rec',N'JobSkills'),(N'rec',N'JobApprovals'),(N'rec',N'JobPostings'),(N'rec',N'RecruitmentSources'),
 (N'cand',N'Candidates'),(N'cand',N'CandidateAddresses'),(N'cand',N'CandidateEducation'),(N'cand',N'CandidateExperience'),(N'cand',N'CandidateSkills'),
 (N'cand',N'CandidateDocuments'),(N'cand',N'JobApplications'),(N'cand',N'ApplicationStatusHistory'),(N'cand',N'Interviews'),(N'cand',N'InterviewPanels'),
 (N'cand',N'InterviewFeedback'),(N'cand',N'JobOffers'),(N'cand',N'OfferApprovals'),
 (N'hr',N'EmployeeRequisitions'),(N'hr',N'HiringApprovals'),(N'hr',N'Employees'),(N'hr',N'EmployeeOnboarding'),(N'hr',N'EmployeeDocuments'),(N'hr',N'EmploymentHistory'),
 (N'staff',N'Contractors'),(N'staff',N'CustomerRequisitions'),(N'staff',N'SubmittedCandidates'),(N'staff',N'CustomerCandidateDecisions'),(N'staff',N'Placements'),
 (N'staff',N'Contracts'),(N'staff',N'Assignments'),(N'staff',N'ContractRates'),(N'staff',N'ContractExtensions'),(N'staff',N'ComplianceRecords'),
 (N'time',N'Timesheets'),(N'time',N'TimesheetEntries'),(N'time',N'TimesheetApprovals'),(N'time',N'TimesheetRejections'),
 (N'bill',N'Invoices'),(N'bill',N'InvoiceLines'),(N'bill',N'Payments'),(N'bill',N'RateCards'),
 (N'doc',N'Documents'),(N'notify',N'NotificationQueue'),(N'notify',N'NotificationHistory'),(N'audit',N'AuditLogs'),(N'audit',N'LoginHistory'),
 (N'sched',N'JobDefinitions'),(N'sched',N'JobExecutionHistory'),(N'report',N'DailyRecruitmentSummary');

INSERT #r (TestName, Passed, Detail)
SELECT N'A02 all ' + CAST(COUNT(*) AS NVARCHAR(10)) + N' required tables exist',
       CASE WHEN SUM(CASE WHEN t.object_id IS NULL THEN 1 ELSE 0 END) = 0 THEN 1 ELSE 0 END,
       ISNULL(STUFF((SELECT N', ' + e2.SchemaName + N'.' + e2.TableName FROM @expected e2
                     LEFT JOIN sys.tables t2 ON t2.name = e2.TableName AND SCHEMA_NAME(t2.schema_id) = e2.SchemaName
                     WHERE t2.object_id IS NULL FOR XML PATH('')), 1, 2, N''), N'none missing')
FROM @expected e LEFT JOIN sys.tables t ON t.name = e.TableName AND SCHEMA_NAME(t.schema_id) = e.SchemaName;

INSERT #r (TestName, Passed, Detail)
SELECT N'A03 every table has a clustered primary key', CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END,
       ISNULL(STUFF((SELECT N', ' + SCHEMA_NAME(t2.schema_id) + N'.' + t2.name FROM sys.tables t2
                     WHERE NOT EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t2.object_id AND i.is_primary_key = 1 AND i.type = 1)
                     FOR XML PATH('')), 1, 2, N''), N'all have one')
FROM sys.tables t
WHERE NOT EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_primary_key = 1 AND i.type = 1);

INSERT #r (TestName, Passed, Detail)
SELECT N'A04 all foreign keys are enabled and trusted', CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END, CONCAT(COUNT(*), N' untrusted/disabled')
FROM sys.foreign_keys WHERE is_disabled = 1 OR is_not_trusted = 1;

INSERT #r (TestName, Passed, Detail)
SELECT N'A05 all check constraints are enabled and trusted', CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END, CONCAT(COUNT(*), N' untrusted/disabled')
FROM sys.check_constraints WHERE is_disabled = 1 OR is_not_trusted = 1;

INSERT #r (TestName, Passed, Detail)
SELECT N'A06 constraint and index inventory', CASE WHEN fk >= 110 AND ck >= 80 AND uq >= 40 AND ix >= 80 AND df >= 110 THEN 1 ELSE 0 END,
       CONCAT(N'FK=', fk, N' CHECK=', ck, N' UNIQUE=', uq, N' NC-indexes=', ix, N' DEFAULT=', df)
FROM (SELECT (SELECT COUNT(*) FROM sys.foreign_keys) fk, (SELECT COUNT(*) FROM sys.check_constraints) ck,
             (SELECT COUNT(*) FROM sys.key_constraints WHERE type = 'UQ') uq,
             (SELECT COUNT(*) FROM sys.indexes WHERE type = 2 AND is_primary_key = 0 AND is_unique_constraint = 0
                AND OBJECTPROPERTY(object_id, 'IsUserTable') = 1) ix,
             (SELECT COUNT(*) FROM sys.default_constraints) df) x;

INSERT #r (TestName, Passed, Detail)
SELECT N'A07 filtered unique indexes implement business rules',
       CASE WHEN COUNT(*) = 4 THEN 1 ELSE 0 END, CONCAT(COUNT(*), N' of 4 found')
FROM sys.indexes WHERE has_filter = 1 AND is_unique = 1
  AND name IN (N'UX_JobApps_Cand_Posting_Live', N'UX_Submitted_Req_Cand_Live', N'UX_Cand_User', N'UX_Contractors_User');

INSERT #r (TestName, Passed, Detail)
SELECT N'A08 no table uses a post-2019 or non-classic data type (no JSON/XML columns)', CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END, CONCAT(COUNT(*), N' found')
FROM sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE OBJECTPROPERTY(c.object_id, 'IsUserTable') = 1 AND ty.name IN (N'xml', N'json', N'geography', N'geometry', N'hierarchyid');

/* ===================== B. SEED DATA ===================== */
INSERT #r SELECT N'B01 six roles seeded', CASE WHEN COUNT(*) = 6 THEN 1 ELSE 0 END, CONCAT(COUNT(*), N' roles') FROM sec.Roles;

INSERT #r (TestName, Passed, Detail)
SELECT N'B02 every role has at least one active user', CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END,
       ISNULL(STUFF((SELECT N', ' + r2.RoleName FROM sec.Roles r2 WHERE NOT EXISTS
          (SELECT 1 FROM sec.UserRoles ur JOIN sec.Users u ON u.UserId = ur.UserId AND u.IsActive = 1 WHERE ur.RoleId = r2.RoleId) FOR XML PATH('')), 1, 2, N''), N'all covered')
FROM sec.Roles r WHERE NOT EXISTS (SELECT 1 FROM sec.UserRoles ur JOIN sec.Users u ON u.UserId = ur.UserId AND u.IsActive = 1 WHERE ur.RoleId = r.RoleId);

INSERT #r SELECT N'B03 one internal organization, 5 departments, 3 customers',
   CASE WHEN (SELECT COUNT(*) FROM org.Organizations) = 1 AND (SELECT COUNT(*) FROM org.Departments) = 5 AND (SELECT COUNT(*) FROM org.Customers) = 3 THEN 1 ELSE 0 END,
   CONCAT((SELECT COUNT(*) FROM org.Organizations), N'/', (SELECT COUNT(*) FROM org.Departments), N'/', (SELECT COUNT(*) FROM org.Customers));

INSERT #r SELECT N'B04 two recruiters and two HR managers',
   CASE WHEN (SELECT COUNT(*) FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId WHERE r.RoleName = N'Recruiter') = 2
         AND (SELECT COUNT(*) FROM sec.UserRoles ur JOIN sec.Roles r ON r.RoleId = ur.RoleId WHERE r.RoleName = N'HRManager') = 2 THEN 1 ELSE 0 END, N'';

INSERT #r SELECT N'B05 15 candidates, requisitions, applications, interviews, offers, contractors, contracts present',
   CASE WHEN (SELECT COUNT(*) FROM cand.Candidates) = 15 AND (SELECT COUNT(*) FROM hr.EmployeeRequisitions) = 6
         AND (SELECT COUNT(*) FROM cand.JobApplications) = 11 AND (SELECT COUNT(*) FROM cand.Interviews) >= 11
         AND (SELECT COUNT(*) FROM cand.JobOffers) = 3 AND (SELECT COUNT(*) FROM staff.Contractors) = 2
         AND (SELECT COUNT(*) FROM staff.Contracts) = 2 AND (SELECT COUNT(*) FROM staff.Assignments) = 2
         AND (SELECT COUNT(*) FROM [time].Timesheets) = 10 AND (SELECT COUNT(*) FROM bill.Invoices) = 3 THEN 1 ELSE 0 END,
   CONCAT(N'cand=', (SELECT COUNT(*) FROM cand.Candidates), N' apps=', (SELECT COUNT(*) FROM cand.JobApplications),
          N' int=', (SELECT COUNT(*) FROM cand.Interviews), N' ts=', (SELECT COUNT(*) FROM [time].Timesheets), N' inv=', (SELECT COUNT(*) FROM bill.Invoices));

-- No plaintext passwords: every user is either the unusable 1-byte seed placeholder or a 32-byte PBKDF2-SHA256
-- hash with a 32-byte salt and >= 100,000 iterations (no short/odd-length value that could be a plaintext password).
INSERT #r SELECT N'B06 passwords are never stored in plaintext (placeholder or salted PBKDF2 hash only)',
   CASE WHEN NOT EXISTS (SELECT 1 FROM sec.Users
          WHERE NOT (DATALENGTH(PasswordHash) = 1
                  OR (DATALENGTH(PasswordHash) = 32 AND DATALENGTH(PasswordSalt) = 32 AND HashIterations >= 100000))) THEN 1 ELSE 0 END,
   N'';

/* ===================== C. RELATIONSHIP & BUSINESS-RULE INTEGRITY ===================== */
INSERT #r SELECT N'C01 shared Candidate Master: no duplicate candidate e-mails',
   CASE WHEN NOT EXISTS (SELECT EmailNormalized FROM cand.Candidates GROUP BY EmailNormalized HAVING COUNT(*) > 1) THEN 1 ELSE 0 END, N'';

INSERT #r SELECT N'C02 one candidate has BOTH internal applications and external submissions (no duplicate master row)',
   CASE WHEN EXISTS (SELECT 1 FROM cand.Candidates c WHERE EXISTS (SELECT 1 FROM cand.JobApplications a WHERE a.CandidateId = c.CandidateId)
                     AND EXISTS (SELECT 1 FROM staff.SubmittedCandidates s WHERE s.CandidateId = c.CandidateId)) THEN 1 ELSE 0 END, N'';

INSERT #r SELECT N'C03 one candidate applied to multiple internal jobs',
   CASE WHEN EXISTS (SELECT CandidateId FROM cand.JobApplications GROUP BY CandidateId HAVING COUNT(*) > 1) THEN 1 ELSE 0 END, N'';

INSERT #r SELECT N'C04 Employee and Contractor are separate entities, both reference the Candidate Master',
   CASE WHEN (SELECT COUNT(*) FROM hr.Employees e JOIN cand.Candidates c ON c.CandidateId = e.CandidateId) >= 1
         AND (SELECT COUNT(*) FROM staff.Contractors k JOIN cand.Candidates c ON c.CandidateId = k.CandidateId) >= 2
         AND NOT EXISTS (SELECT 1 FROM hr.Employees e JOIN staff.Contractors k ON k.CandidateId = e.CandidateId) THEN 1 ELSE 0 END, N'';

INSERT #r SELECT N'C05 contractor PAY rate and customer BILL rate are separate and differ',
   CASE WHEN NOT EXISTS (SELECT 1 FROM staff.ContractRates WHERE PayRate = BillRate OR PayRate IS NULL OR BillRate IS NULL) THEN 1 ELSE 0 END, N'';

INSERT #r SELECT N'C06 customer chain is consistent: submission/placement/contract/assignment/timesheet/invoice share one customer',
   CASE WHEN NOT EXISTS (
        SELECT 1 FROM [time].Timesheets t
        JOIN staff.Assignments a ON a.AssignmentId = t.AssignmentId
        JOIN staff.Contracts ct ON ct.ContractId = a.ContractId
        JOIN staff.Placements p ON p.PlacementId = ct.PlacementId
        JOIN staff.SubmittedCandidates s ON s.SubmissionId = p.SubmissionId
        JOIN staff.CustomerRequisitions r ON r.CustomerRequisitionId = s.CustomerRequisitionId
        WHERE NOT (t.CustomerId = a.CustomerId AND a.CustomerId = ct.CustomerId AND ct.CustomerId = p.CustomerId
                   AND p.CustomerId = s.CustomerId AND s.CustomerId = r.CustomerId)) THEN 1 ELSE 0 END, N'0 mismatches';

INSERT #r SELECT N'C07 invoice lines belong to timesheets of the invoice''s own customer',
   CASE WHEN NOT EXISTS (SELECT 1 FROM bill.InvoiceLines l JOIN bill.Invoices i ON i.InvoiceId = l.InvoiceId
        JOIN [time].TimesheetEntries e ON e.EntryId = l.TimesheetEntryId JOIN [time].Timesheets t ON t.TimesheetId = e.TimesheetId
        WHERE t.CustomerId <> i.CustomerId) THEN 1 ELSE 0 END, N'';

INSERT #r SELECT N'C08 invoice totals = sum of lines + tax',
   CASE WHEN NOT EXISTS (SELECT 1 FROM bill.Invoices i LEFT JOIN (SELECT InvoiceId, SUM(LineTotal) s FROM bill.InvoiceLines GROUP BY InvoiceId) l ON l.InvoiceId = i.InvoiceId
        WHERE i.Subtotal <> ISNULL(l.s, 0) OR i.Total <> i.Subtotal + i.TaxAmount) THEN 1 ELSE 0 END, N'';

INSERT #r SELECT N'C09 invoice status agrees with payments (Paid / PartiallyPaid / Issued)',
   CASE WHEN NOT EXISTS (SELECT 1 FROM bill.Invoices i LEFT JOIN (SELECT InvoiceId, SUM(Amount) p FROM bill.Payments GROUP BY InvoiceId) p ON p.InvoiceId = i.InvoiceId
        WHERE (i.Status = 'Paid' AND ISNULL(p.p, 0) <> i.Total)
           OR (i.Status = 'PartiallyPaid' AND NOT (ISNULL(p.p, 0) > 0 AND ISNULL(p.p, 0) < i.Total))
           OR (i.Status = 'Issued' AND ISNULL(p.p, 0) <> 0)) THEN 1 ELSE 0 END, N'';

INSERT #r SELECT N'C10 timesheet totals = sum of entries',
   CASE WHEN NOT EXISTS (SELECT 1 FROM [time].Timesheets t LEFT JOIN (SELECT TimesheetId, SUM(Hours) h FROM [time].TimesheetEntries GROUP BY TimesheetId) e ON e.TimesheetId = t.TimesheetId
        WHERE t.TotalHours <> ISNULL(e.h, 0)) THEN 1 ELSE 0 END, N'';

INSERT #r SELECT N'C11 only Invoiced timesheets have invoiced entries; Approved ones are available for billing',
   CASE WHEN NOT EXISTS (SELECT 1 FROM [time].Timesheets t JOIN [time].TimesheetEntries e ON e.TimesheetId = t.TimesheetId
          WHERE (t.Status = 'Invoiced' AND NOT EXISTS (SELECT 1 FROM bill.InvoiceLines l WHERE l.TimesheetEntryId = e.EntryId))
             OR (t.Status <> 'Invoiced' AND EXISTS (SELECT 1 FROM bill.InvoiceLines l WHERE l.TimesheetEntryId = e.EntryId)))
         AND EXISTS (SELECT 1 FROM [time].Timesheets WHERE Status = 'Approved') THEN 1 ELSE 0 END, N'';

INSERT #r SELECT N'C12 timesheet workflow states and rejection history all represented',
   CASE WHEN (SELECT COUNT(DISTINCT Status) FROM [time].Timesheets) = 5 AND EXISTS (SELECT 1 FROM [time].TimesheetRejections)
         AND EXISTS (SELECT 1 FROM [time].TimesheetApprovals) THEN 1 ELSE 0 END, N'';

INSERT #r SELECT N'C13 application status history ends at the application''s current status',
   CASE WHEN NOT EXISTS (SELECT 1 FROM cand.JobApplications a CROSS APPLY
        (SELECT TOP 1 NewStatus FROM cand.ApplicationStatusHistory h WHERE h.ApplicationId = a.ApplicationId ORDER BY h.ChangedAt DESC, h.HistoryId DESC) x
        WHERE x.NewStatus <> a.Status) THEN 1 ELSE 0 END, N'';

INSERT #r SELECT N'C14 accepted offer has exactly one employee, onboarding tasks and history',
   CASE WHEN (SELECT COUNT(*) FROM cand.JobOffers o JOIN hr.Employees e ON e.JobOfferId = o.OfferId WHERE o.Status = 'Accepted') = 1
         AND (SELECT COUNT(*) FROM hr.EmployeeOnboarding) >= 5 AND (SELECT COUNT(*) FROM hr.EmploymentHistory) >= 1 THEN 1 ELSE 0 END, N'';

INSERT #r SELECT N'C15 offer approver is never the offer creator (four-eyes)',
   CASE WHEN NOT EXISTS (SELECT 1 FROM cand.OfferApprovals a JOIN cand.JobOffers o ON o.OfferId = a.OfferId WHERE a.ApproverUserId = o.CreatedByUserId) THEN 1 ELSE 0 END, N'';

INSERT #r SELECT N'C16 hiring-request approver is never the requester',
   CASE WHEN NOT EXISTS (SELECT 1 FROM hr.HiringApprovals a JOIN hr.EmployeeRequisitions r ON r.EmployeeRequisitionId = a.EmployeeRequisitionId WHERE a.ApproverUserId = r.RequestedByUserId) THEN 1 ELSE 0 END, N'';

INSERT #r SELECT N'C17 external interviews carry the customer of their submission; internal ones carry none',
   CASE WHEN NOT EXISTS (SELECT 1 FROM cand.Interviews i LEFT JOIN staff.SubmittedCandidates s ON s.SubmissionId = i.SubmittedCandidateId
        WHERE (i.SubmittedCandidateId IS NOT NULL AND i.CustomerId <> s.CustomerId) OR (i.JobApplicationId IS NOT NULL AND i.CustomerId IS NOT NULL)) THEN 1 ELSE 0 END, N'';

INSERT #r SELECT N'C18 no customer user can belong to more than one customer; each customer has a login contact',
   CASE WHEN NOT EXISTS (SELECT UserId FROM org.CustomerUsers GROUP BY UserId HAVING COUNT(*) > 1)
         AND NOT EXISTS (SELECT 1 FROM org.Customers c WHERE NOT EXISTS (SELECT 1 FROM org.CustomerUsers cu WHERE cu.CustomerId = c.CustomerId)) THEN 1 ELSE 0 END, N'';

/* ===================== D. CONSTRAINTS REJECT INVALID DATA ===================== */
DECLARE @neg TABLE (Id INT IDENTITY(1,1), TestName NVARCHAR(200), Expected NVARCHAR(128), Stmt NVARCHAR(MAX));
INSERT @neg (TestName, Expected, Stmt) VALUES
 (N'D01 invalid candidate status rejected', N'CK_Cand_Status',
  N'INSERT cand.Candidates (FirstName,LastName,Email,EmailNormalized,Status) VALUES (N''T'',N''T'',N''t1@x.example'',N''T1@X.EXAMPLE'',''Bogus'')'),
 (N'D02 duplicate candidate e-mail rejected', N'UQ_Candidates_Email',
  N'INSERT cand.Candidates (FirstName,LastName,Email,EmailNormalized) SELECT N''Dup'',N''Dup'',Email,EmailNormalized FROM cand.Candidates WHERE EmailNormalized = N''ANANYA.SHARMA@CANDIDATE.EXAMPLE'''),
 (N'D03 malformed e-mail rejected', N'CK_Cand_Email',
  N'INSERT cand.Candidates (FirstName,LastName,Email,EmailNormalized) VALUES (N''T'',N''T'',N''not-an-email'',N''NOT-AN-EMAIL'')'),
 (N'D04 interview with BOTH internal and external opportunity rejected', N'CK_Interviews_OneOpportunity',
  N'INSERT cand.Interviews (JobApplicationId,SubmittedCandidateId,CustomerId,StartsAt,EndsAt,ScheduledByUserId)
    SELECT TOP 1 (SELECT TOP 1 ApplicationId FROM cand.JobApplications), s.SubmissionId, s.CustomerId, SYSUTCDATETIME(), DATEADD(HOUR,1,SYSUTCDATETIME()), (SELECT TOP 1 UserId FROM sec.Users) FROM staff.SubmittedCandidates s'),
 (N'D05 interview with NO opportunity rejected', N'CK_Interviews_OneOpportunity',
  N'INSERT cand.Interviews (StartsAt,EndsAt,ScheduledByUserId) SELECT SYSUTCDATETIME(), DATEADD(HOUR,1,SYSUTCDATETIME()), (SELECT TOP 1 UserId FROM sec.Users)'),
 (N'D06 interview ending before it starts rejected', N'CK_Interviews_Time',
  N'INSERT cand.Interviews (JobApplicationId,StartsAt,EndsAt,ScheduledByUserId) SELECT TOP 1 ApplicationId, SYSUTCDATETIME(), DATEADD(HOUR,-1,SYSUTCDATETIME()), (SELECT TOP 1 UserId FROM sec.Users) FROM cand.JobApplications'),
 (N'D07 timesheet week not starting on Monday rejected', N'CK_Timesheets_Monday',
  N'INSERT [time].Timesheets (AssignmentId,ContractorId,CustomerId,WeekStartDate) SELECT TOP 1 AssignmentId,ContractorId,CustomerId,''2030-01-01'' FROM staff.Assignments'),
 (N'D08 duplicate timesheet for same assignment and week rejected', N'UQ_Timesheets_Assign_Week',
  N'INSERT [time].Timesheets (AssignmentId,ContractorId,CustomerId,WeekStartDate) SELECT TOP 1 AssignmentId,ContractorId,CustomerId,WeekStartDate FROM [time].Timesheets'),
 (N'D09 timesheet entry of 25 hours rejected', N'CK_TsEntries_Hours',
  N'INSERT [time].TimesheetEntries (TimesheetId,WorkDate,Hours) SELECT TOP 1 TimesheetId,''2031-01-01'',25 FROM [time].Timesheets'),
 (N'D10 bill rate below pay rate rejected', N'CK_Rates_Margin',
  N'INSERT staff.ContractRates (ContractId,PayRate,BillRate,EffectiveFrom) SELECT TOP 1 ContractId,2000,1000,''2031-01-01'' FROM staff.Contracts'),
 (N'D11 duplicate live application (same candidate, same posting) rejected', N'UX_JobApps_Cand_Posting_Live',
  N'INSERT cand.JobApplications (CandidateId,JobPostingId) SELECT TOP 1 CandidateId,JobPostingId FROM cand.JobApplications WHERE Status <> ''Withdrawn'''),
 (N'D12 invoicing the same time entry twice rejected', N'UQ_InvoiceLines_Entry',
  N'INSERT bill.InvoiceLines (InvoiceId,TimesheetEntryId,Description,Hours,BillRate,LineTotal) SELECT TOP 1 InvoiceId,TimesheetEntryId,N''dup'',Hours,BillRate,LineTotal FROM bill.InvoiceLines'),
 (N'D13 CUSTOMER ISOLATION: submission whose customer differs from its requisition''s customer rejected', N'FK_Submitted_Req_Customer',
  N'INSERT staff.SubmittedCandidates (CustomerRequisitionId,CustomerId,CandidateId,SubmittedByUserId)
    SELECT TOP 1 r.CustomerRequisitionId, (SELECT TOP 1 CustomerId FROM org.Customers WHERE CustomerId <> r.CustomerId), (SELECT TOP 1 CandidateId FROM cand.Candidates WHERE EmailNormalized = N''GAURAV.SINGH@CANDIDATE.EXAMPLE''), (SELECT TOP 1 UserId FROM sec.Users) FROM staff.CustomerRequisitions r'),
 (N'D14 CUSTOMER ISOLATION: timesheet whose customer differs from its assignment''s customer rejected', N'FK_Timesheets_Assign_Customer',
  N'INSERT [time].Timesheets (AssignmentId,ContractorId,CustomerId,WeekStartDate) SELECT TOP 1 AssignmentId,ContractorId,(SELECT TOP 1 CustomerId FROM org.Customers WHERE CustomerId <> a.CustomerId),''2031-01-06'' FROM staff.Assignments a'),
 (N'D15 CUSTOMER ISOLATION: payment recorded against another customer''s invoice rejected', N'FK_Payments_Inv_Customer',
  N'INSERT bill.Payments (InvoiceId,CustomerId,Amount,PaidOn,RecordedByUserId) SELECT TOP 1 InvoiceId,(SELECT TOP 1 CustomerId FROM org.Customers WHERE CustomerId <> i.CustomerId),10,SYSUTCDATETIME(),(SELECT TOP 1 UserId FROM sec.Users) FROM bill.Invoices i'),
 (N'D16 CUSTOMER ISOLATION: external interview with another customer''s id rejected', N'FK_Interviews_Submission_Customer',
  N'INSERT cand.Interviews (SubmittedCandidateId,CustomerId,StartsAt,EndsAt,ScheduledByUserId) SELECT TOP 1 SubmissionId,(SELECT TOP 1 CustomerId FROM org.Customers WHERE CustomerId <> s.CustomerId),SYSUTCDATETIME(),DATEADD(HOUR,1,SYSUTCDATETIME()),(SELECT TOP 1 UserId FROM sec.Users) FROM staff.SubmittedCandidates s'),
 (N'D17 CUSTOMER ISOLATION: contract linked to a placement of another customer rejected', N'FK_Contracts_Plc_Customer',
  N'INSERT staff.Contracts (ContractNo,PlacementId,CustomerId,StartDate,EndDate,CreatedByUserId) SELECT TOP 1 N''CON-X'',PlacementId,(SELECT TOP 1 CustomerId FROM org.Customers WHERE CustomerId <> p.CustomerId),''2031-01-01'',''2031-06-01'',(SELECT TOP 1 UserId FROM sec.Users) FROM staff.Placements p'),
 (N'D18 second employee for the same offer rejected', N'UQ_Employees_Offer',
  N'INSERT hr.Employees (EmployeeNo,CandidateId,JobOfferId,DepartmentId,JobTitle,StartDate,Salary) SELECT TOP 1 N''EMP-X'',(SELECT TOP 1 CandidateId FROM cand.Candidates WHERE EmailNormalized = N''GAURAV.SINGH@CANDIDATE.EXAMPLE''),JobOfferId,DepartmentId,JobTitle,StartDate,Salary FROM hr.Employees'),
 (N'D19 second contractor entity for the same candidate rejected', N'UQ_Contractors_Candidate',
  N'INSERT staff.Contractors (ContractorNo,CandidateId) SELECT TOP 1 N''CTR-X'',CandidateId FROM staff.Contractors'),
 (N'D20 timesheet rejection without a reason rejected', N'CK_TsRej_Reason',
  N'INSERT [time].TimesheetRejections (TimesheetId,RejectedByUserId,Reason) SELECT TOP 1 TimesheetId,(SELECT TOP 1 UserId FROM sec.Users),N''   '' FROM [time].Timesheets'),
 (N'D21 zero-value payment rejected', N'CK_Payments_Amount',
  N'INSERT bill.Payments (InvoiceId,CustomerId,Amount,PaidOn,RecordedByUserId) SELECT TOP 1 InvoiceId,CustomerId,0,SYSUTCDATETIME(),(SELECT TOP 1 UserId FROM sec.Users) FROM bill.Invoices'),
 (N'D22 contract ending before it starts rejected', N'CK_Contracts_Dates',
  N'INSERT staff.Contracts (ContractNo,PlacementId,CustomerId,StartDate,EndDate,CreatedByUserId) SELECT TOP 1 N''CON-Y'',PlacementId,CustomerId,''2031-06-01'',''2031-01-01'',(SELECT TOP 1 UserId FROM sec.Users) FROM staff.Placements'),
 (N'D23 invoice line with wrong total rejected', N'CK_InvLines_Amounts',
  N'INSERT bill.InvoiceLines (InvoiceId,TimesheetEntryId,Description,Hours,BillRate,LineTotal) SELECT TOP 1 InvoiceId,(SELECT TOP 1 EntryId FROM [time].TimesheetEntries e WHERE NOT EXISTS (SELECT 1 FROM bill.InvoiceLines l WHERE l.TimesheetEntryId = e.EntryId)),N''bad'',8,100,1 FROM bill.Invoices'),
 (N'D24 duplicate notification (same dedupe key) rejected', N'UQ_NotifQ_DedupeKey',
  N'INSERT notify.NotificationQueue (TemplateCode,ToEmail,Subject,Body,DedupeKey) VALUES (''T'',N''a@x.example'',N''s'',N''b'',N''same-key''),(''T'',N''a@x.example'',N''s'',N''b'',N''same-key'')'),
 (N'D25 invalid customer status rejected', N'CK_Customers_Status',
  N'UPDATE org.Customers SET Status = ''Bogus'' WHERE CustomerCode = N''APEX'''),
 (N'D26 deleting a customer that owns data rejected (referential integrity)', N'REFERENCE constraint',
  N'DELETE org.Customers WHERE CustomerCode = N''APEX'''),
 (N'D27 deleting a role that is in use rejected', N'FK_UserRoles_Role',
  N'DELETE sec.Roles WHERE RoleName = N''Recruiter'''),
 (N'D28 oversize document (>10 MB) rejected', N'CK_Documents_Size',
  N'INSERT doc.Documents (OwnerType,OwnerId,StoredFileName,OriginalFileName,ContentType,SizeBytes,Sha256,UploadedByUserId) SELECT ''Candidate'',1,N''x.pdf'',N''x.pdf'',N''application/pdf'',20000000,0x00,(SELECT TOP 1 UserId FROM sec.Users)'),
 (N'D29 unknown document owner type rejected', N'CK_Documents_Owner',
  N'INSERT doc.Documents (OwnerType,OwnerId,StoredFileName,OriginalFileName,ContentType,SizeBytes,Sha256,UploadedByUserId) SELECT ''Alien'',1,N''y.pdf'',N''y.pdf'',N''application/pdf'',10,0x00,(SELECT TOP 1 UserId FROM sec.Users)'),
 (N'D30 feedback rating out of range rejected', N'CK_Feedback_Rating',
  N'INSERT cand.InterviewFeedback (InterviewId,InterviewerUserId,Rating,Recommendation) SELECT TOP 1 InterviewId,(SELECT TOP 1 UserId FROM sec.Users),9,''Yes'' FROM cand.Interviews');

DECLARE @n INT = 1, @max INT = (SELECT MAX(Id) FROM @neg), @name NVARCHAR(200), @exp NVARCHAR(128), @sql NVARCHAR(MAX);
WHILE @n <= @max
BEGIN
    SELECT @name = TestName, @exp = Expected, @sql = Stmt FROM @neg WHERE Id = @n;
    BEGIN TRY
        BEGIN TRAN;
        EXEC sys.sp_executesql @sql;
        ROLLBACK;
        INSERT #r VALUES (@name, 0, N'statement unexpectedly SUCCEEDED');
    END TRY
    BEGIN CATCH
        DECLARE @msg NVARCHAR(4000) = ERROR_MESSAGE();
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT #r VALUES (@name, CASE WHEN @msg LIKE N'%' + @exp + N'%' THEN 1 ELSE 0 END,
                          CASE WHEN @msg LIKE N'%' + @exp + N'%' THEN N'rejected by ' + @exp ELSE LEFT(@msg, 350) END);
    END CATCH
    SET @n += 1;
END

/* ===================== E. VALID DATA IS ACCEPTED; TRANSACTIONS ROLL BACK ===================== */
BEGIN TRY  -- a withdrawn application may be re-submitted (filtered unique index excludes Withdrawn)
    BEGIN TRAN;
    INSERT cand.JobApplications (CandidateId, JobPostingId)
    SELECT CandidateId, JobPostingId FROM cand.JobApplications WHERE Status = 'Withdrawn';
    DECLARE @ok INT = @@ROWCOUNT;
    ROLLBACK;
    INSERT #r VALUES (N'E01 re-application after withdrawal accepted', CASE WHEN @ok = 1 THEN 1 ELSE 0 END, CONCAT(@ok, N' row inserted (rolled back)'));
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    INSERT #r VALUES (N'E01 re-application after withdrawal accepted', 0, LEFT(ERROR_MESSAGE(), 300));
END CATCH

DECLARE @before INT = (SELECT COUNT(*) FROM org.Departments), @after INT;
BEGIN TRY  -- multi-step operation: first insert succeeds, second violates a constraint -> everything rolls back
    BEGIN TRAN;
    SET XACT_ABORT ON;
    INSERT org.Departments (OrganizationId, Name) SELECT TOP 1 OrganizationId, N'Temp Dept' FROM org.Organizations;
    INSERT org.Departments (OrganizationId, Name) SELECT TOP 1 OrganizationId, N'Temp Dept' FROM org.Organizations;  -- duplicate -> UQ violation
    COMMIT;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
END CATCH
SET XACT_ABORT OFF;
SET @after = (SELECT COUNT(*) FROM org.Departments);
INSERT #r VALUES (N'E02 failed multi-statement transaction leaves no partial data', CASE WHEN @before = @after THEN 1 ELSE 0 END, CONCAT(N'departments before=', @before, N' after=', @after));

/* ===================== REPORT ===================== */
DECLARE @line NVARCHAR(600);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT CASE WHEN Passed = 1 THEN N'PASS  ' ELSE N'FAIL  ' END + TestName + CASE WHEN Detail <> N'' AND Passed = 0 THEN N'  -> ' + Detail ELSE N'' END FROM #r ORDER BY Id;
OPEN c; FETCH NEXT FROM c INTO @line;
WHILE @@FETCH_STATUS = 0 BEGIN PRINT @line; FETCH NEXT FROM c INTO @line; END
CLOSE c; DEALLOCATE c;

DECLARE @total INT = (SELECT COUNT(*) FROM #r), @passed INT = (SELECT COUNT(*) FROM #r WHERE Passed = 1);
PRINT CONCAT(N'--- Schema/constraint/data tests: ', @passed, N' passed, ', @total - @passed, N' failed, ', @total, N' total ---');
IF @passed <> @total RAISERROR(N'Database tests FAILED', 16, 1);
DROP TABLE #r;
GO
