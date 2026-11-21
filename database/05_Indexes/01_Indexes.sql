/* ============================================================================
   TAMS - 05_Indexes / 01_Indexes.sql
   Clustered indexes = the identity primary keys (created in 03_Tables).
   This file adds: FK-supporting nonclustered indexes, composite indexes for the
   dominant (Status, date) / (CustomerId, Status) access paths, FILTERED indexes
   and FILTERED UNIQUE indexes that implement business rules:
     * one live application per candidate per posting (withdrawn may re-apply)
     * one live submission per candidate per customer requisition
     * one login per candidate / contractor
   Repeatable. Execution plans are reviewed in Phase 3.5.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON;

DECLARE @x TABLE (Name SYSNAME, TableName NVARCHAR(256), KeyCols NVARCHAR(300),
                  IsUnique BIT, IncludeCols NVARCHAR(300) NULL, Filter NVARCHAR(300) NULL);
INSERT @x (Name, TableName, KeyCols, IsUnique, IncludeCols, Filter) VALUES
 -- sec
 (N'IX_UserRoles_Role',           N'sec.UserRoles',        N'RoleId', 0, NULL, NULL),
 (N'IX_AuthTokens_User_Revoked',  N'sec.AuthTokens',       N'UserId, RevokedAt', 0, N'ExpiresAt', NULL),
 (N'IX_AuthTokens_Expires',       N'sec.AuthTokens',       N'ExpiresAt', 0, NULL, NULL),
 (N'IX_PwdReset_User',            N'sec.PasswordResetTokens', N'UserId', 0, N'ExpiresAt, UsedAt', NULL),
 (N'IX_EmailVerify_User',         N'sec.EmailVerificationTokens', N'UserId', 0, N'ExpiresAt, UsedAt', NULL),
 -- org
 (N'IX_Departments_Org',          N'org.Departments',      N'OrganizationId', 0, NULL, NULL),
 (N'IX_OrgUsers_Dept',            N'org.OrganizationUsers',N'DepartmentId', 0, NULL, NULL),
 (N'IX_CustomerUsers_Customer',   N'org.CustomerUsers',    N'CustomerId', 0, NULL, NULL),
 (N'IX_Customers_Status',         N'org.Customers',        N'Status', 0, N'Name', NULL),
 -- rec
 (N'IX_JobReq_Status_Created',    N'rec.JobRequisitions',  N'Status, CreatedAt', 0, NULL, NULL),
 (N'IX_JobReq_Dept',              N'rec.JobRequisitions',  N'DepartmentId', 0, NULL, NULL),
 (N'IX_JobReq_EmpReq',            N'rec.JobRequisitions',  N'EmployeeRequisitionId', 0, NULL, NULL),
 (N'IX_JobReq_Owner_Status',      N'rec.JobRequisitions',  N'OwnerRecruiterUserId, Status', 0, NULL, NULL),
 (N'IX_JobAppr_Req',              N'rec.JobApprovals',     N'JobRequisitionId', 0, NULL, NULL),
 (N'IX_JobPostings_Req_Status',   N'rec.JobPostings',      N'JobRequisitionId, Status', 0, NULL, NULL),
 (N'IX_JobPostings_Published',    N'rec.JobPostings',      N'ClosesAt', 0, N'JobRequisitionId', N'Status = ''Published'''),
 -- cand
 (N'IX_Cand_Name',                N'cand.Candidates',      N'LastName, FirstName', 0, N'Email, CurrentTitle', NULL),
 (N'IX_Cand_Status_Exp',          N'cand.Candidates',      N'Status, TotalExperienceYears', 0, NULL, NULL),
 (N'UX_Cand_User',                N'cand.Candidates',      N'UserId', 1, NULL, N'UserId IS NOT NULL'),
 (N'IX_CandSkills_Skill',         N'cand.CandidateSkills', N'SkillName, CandidateId', 0, N'YearsExperience, ProficiencyLevel', NULL),
 (N'IX_CandAddr_Cand',            N'cand.CandidateAddresses', N'CandidateId', 0, NULL, NULL),
 (N'IX_CandEdu_Cand',             N'cand.CandidateEducation', N'CandidateId', 0, NULL, NULL),
 (N'IX_CandExp_Cand',             N'cand.CandidateExperience',N'CandidateId', 0, NULL, NULL),
 (N'IX_CandDocs_Cand',            N'cand.CandidateDocuments', N'CandidateId', 0, NULL, NULL),
 (N'IX_JobApps_Posting_Status',   N'cand.JobApplications', N'JobPostingId, Status', 0, NULL, NULL),
 (N'IX_JobApps_Cand_Status',      N'cand.JobApplications', N'CandidateId, Status', 0, NULL, NULL),
 (N'IX_JobApps_Status_Applied',   N'cand.JobApplications', N'Status, AppliedAt', 0, NULL, NULL),
 (N'UX_JobApps_Cand_Posting_Live',N'cand.JobApplications', N'CandidateId, JobPostingId', 1, NULL, N'Status <> ''Withdrawn'''),
 (N'IX_AppHist_App_At',           N'cand.ApplicationStatusHistory', N'ApplicationId, ChangedAt', 0, NULL, NULL),
 (N'IX_Interviews_App',           N'cand.Interviews',      N'JobApplicationId', 0, NULL, NULL),
 (N'IX_Interviews_Submission',    N'cand.Interviews',      N'SubmittedCandidateId', 0, NULL, NULL),
 (N'IX_Interviews_Start_Status',  N'cand.Interviews',      N'StartsAt, Status', 0, NULL, NULL),
 (N'IX_Interviews_Customer_Start',N'cand.Interviews',      N'CustomerId, StartsAt', 0, NULL, N'CustomerId IS NOT NULL'),
 (N'IX_Panels_User',              N'cand.InterviewPanels', N'UserId', 0, NULL, NULL),
 (N'IX_Offers_App',               N'cand.JobOffers',       N'ApplicationId', 0, NULL, NULL),
 (N'IX_Offers_Status_Expires',    N'cand.JobOffers',       N'Status, ExpiresAt', 0, NULL, NULL),
 (N'IX_OfferAppr_Offer',          N'cand.OfferApprovals',  N'OfferId', 0, NULL, NULL),
 -- hr
 (N'IX_EmpReq_Status_Dept',       N'hr.EmployeeRequisitions', N'Status, DepartmentId', 0, NULL, NULL),
 (N'IX_HiringAppr_Req',           N'hr.HiringApprovals',   N'EmployeeRequisitionId', 0, NULL, NULL),
 (N'IX_Employees_Dept_Status',    N'hr.Employees',         N'DepartmentId, Status', 0, NULL, NULL),
 (N'IX_Onboarding_Emp_Status',    N'hr.EmployeeOnboarding',N'EmployeeId, Status', 0, NULL, NULL),
 (N'IX_EmpDocs_Emp',              N'hr.EmployeeDocuments', N'EmployeeId', 0, NULL, NULL),
 (N'IX_EmpHist_Emp_Date',         N'hr.EmploymentHistory', N'EmployeeId, EffectiveDate', 0, NULL, NULL),
 -- staff
 (N'UX_Contractors_User',         N'staff.Contractors',    N'UserId', 1, NULL, N'UserId IS NOT NULL'),
 (N'IX_Contractors_Status',       N'staff.Contractors',    N'Status', 0, NULL, NULL),
 (N'IX_CustReq_Customer_Status',  N'staff.CustomerRequisitions', N'CustomerId, Status', 0, NULL, NULL),
 (N'IX_CustReq_Recruiter_Status', N'staff.CustomerRequisitions', N'AssignedRecruiterUserId, Status', 0, NULL, NULL),
 (N'IX_Submitted_Req_Status',     N'staff.SubmittedCandidates',  N'CustomerRequisitionId, Status', 0, NULL, NULL),
 (N'IX_Submitted_Cand',           N'staff.SubmittedCandidates',  N'CandidateId', 0, NULL, NULL),
 (N'IX_Submitted_Customer_Status',N'staff.SubmittedCandidates',  N'CustomerId, Status', 0, NULL, NULL),
 (N'UX_Submitted_Req_Cand_Live',  N'staff.SubmittedCandidates',  N'CustomerRequisitionId, CandidateId', 1, NULL, N'Status <> ''Withdrawn'''),
 (N'IX_CustDec_Submission',       N'staff.CustomerCandidateDecisions', N'SubmissionId', 0, NULL, NULL),
 (N'IX_Placements_Customer_Status',N'staff.Placements',    N'CustomerId, Status', 0, NULL, NULL),
 (N'IX_Placements_Contractor',    N'staff.Placements',     N'ContractorId', 0, NULL, NULL),
 (N'IX_Contracts_Customer_Status',N'staff.Contracts',      N'CustomerId, Status', 0, NULL, NULL),
 (N'IX_Contracts_Expiry',         N'staff.Contracts',      N'EndDate', 0, N'CustomerId, ContractNo', N'Status IN (''Active'',''Expiring'')'),
 (N'IX_Assign_Contract',          N'staff.Assignments',    N'ContractId', 0, NULL, NULL),
 (N'IX_Assign_Contractor_Status', N'staff.Assignments',    N'ContractorId, Status', 0, NULL, NULL),
 (N'IX_Assign_Customer_Status',   N'staff.Assignments',    N'CustomerId, Status', 0, NULL, NULL),
 (N'IX_Rates_Contract_From',      N'staff.ContractRates',  N'ContractId, EffectiveFrom', 0, N'PayRate, BillRate', NULL),
 (N'IX_Ext_Contract',             N'staff.ContractExtensions', N'ContractId', 0, NULL, NULL),
 (N'IX_Compliance_Contractor_Status', N'staff.ComplianceRecords', N'ContractorId, Status', 0, NULL, NULL),
 (N'IX_Compliance_Expiry',        N'staff.ComplianceRecords', N'ExpiresOn', 0, N'ContractorId, RecordType', N'ExpiresOn IS NOT NULL'),
 -- time
 (N'IX_Timesheets_Customer_Status',N'[time].Timesheets',   N'CustomerId, Status', 0, N'WeekStartDate, TotalHours', NULL),
 (N'IX_Timesheets_Contractor_Week',N'[time].Timesheets',   N'ContractorId, WeekStartDate', 0, NULL, NULL),
 (N'IX_Timesheets_Status_Week',   N'[time].Timesheets',    N'Status, WeekStartDate', 0, NULL, NULL),
 (N'IX_TsAppr_Timesheet',         N'[time].TimesheetApprovals', N'TimesheetId', 0, NULL, NULL),
 (N'IX_TsRej_Timesheet',          N'[time].TimesheetRejections',N'TimesheetId', 0, NULL, NULL),
 -- bill
 (N'IX_RateCards_Customer_Active',N'bill.RateCards',       N'CustomerId, IsActive', 0, NULL, NULL),
 (N'IX_Invoices_Customer_Status', N'bill.Invoices',        N'CustomerId, Status', 0, N'Total, DueDate', NULL),
 (N'IX_Invoices_Status_Due',      N'bill.Invoices',        N'Status, DueDate', 0, NULL, NULL),
 (N'IX_InvLines_Invoice',         N'bill.InvoiceLines',    N'InvoiceId', 0, N'LineTotal', NULL),
 (N'IX_Payments_Invoice',         N'bill.Payments',        N'InvoiceId', 0, N'Amount', NULL),
 (N'IX_Payments_Customer_Paid',   N'bill.Payments',        N'CustomerId, PaidOn', 0, NULL, NULL),
 -- doc / notify / audit / sched
 (N'IX_Documents_Owner',          N'doc.Documents',        N'OwnerType, OwnerId', 0, N'IsDeleted, CustomerId', NULL),
 (N'IX_Documents_Customer',       N'doc.Documents',        N'CustomerId', 0, NULL, N'CustomerId IS NOT NULL'),
 (N'IX_NotifQ_Status_Next',       N'notify.NotificationQueue', N'Status, NextAttemptAt', 0, NULL, NULL),
 (N'IX_NotifQ_Recipient_Read',    N'notify.NotificationQueue', N'RecipientUserId, IsRead, CreatedAt', 0, NULL, N'RecipientUserId IS NOT NULL'),
 (N'IX_NotifHist_Notif',          N'notify.NotificationHistory', N'NotificationId', 0, NULL, NULL),
 (N'IX_Audit_Table_Record',       N'audit.AuditLogs',      N'TableName, RecordId, ChangedAt', 0, NULL, NULL),
 (N'IX_Audit_ChangedAt',          N'audit.AuditLogs',      N'ChangedAt', 0, NULL, NULL),
 (N'IX_LoginHist_Email_At',       N'audit.LoginHistory',   N'Email, AttemptedAt', 0, N'Success', NULL),
 (N'IX_LoginHist_User_At',        N'audit.LoginHistory',   N'UserId, AttemptedAt', 0, NULL, N'UserId IS NOT NULL'),
 (N'IX_JobExec_Def_Start',        N'sched.JobExecutionHistory', N'JobDefinitionId, StartedAt', 0, N'Outcome', NULL),
 (N'IX_JobDetails_Execution',     N'sched.JobExecutionDetails', N'ExecutionId', 0, NULL, NULL),
 (N'IX_ReportRuns_Actor_At',      N'audit.ReportRuns',     N'ActorUserId, RanAt', 0, N'ReportCode', NULL),
 (N'IX_ReportRuns_RanAt',         N'audit.ReportRuns',     N'RanAt', 0, NULL, NULL);

DECLARE @n SYSNAME, @t NVARCHAR(256), @k NVARCHAR(300), @u BIT, @i NVARCHAR(300), @f NVARCHAR(300), @sql NVARCHAR(2000), @made INT = 0;
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT Name, TableName, KeyCols, IsUnique, IncludeCols, Filter FROM @x;
OPEN cur; FETCH NEXT FROM cur INTO @n, @t, @k, @u, @i, @f;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = @n AND object_id = OBJECT_ID(@t))
    BEGIN
        SET @sql = N'CREATE ' + CASE WHEN @u = 1 THEN N'UNIQUE ' ELSE N'' END + N'NONCLUSTERED INDEX ' + QUOTENAME(@n)
                 + N' ON ' + @t + N' (' + @k + N')'
                 + CASE WHEN @i IS NOT NULL THEN N' INCLUDE (' + @i + N')' ELSE N'' END
                 + CASE WHEN @f IS NOT NULL THEN N' WHERE ' + @f ELSE N'' END + N';';
        EXEC sys.sp_executesql @sql;
        SET @made += 1;
    END
    FETCH NEXT FROM cur INTO @n, @t, @k, @u, @i, @f;
END
CLOSE cur; DEALLOCATE cur;
PRINT 'Nonclustered indexes created this run: ' + CAST(@made AS VARCHAR(10));
GO
