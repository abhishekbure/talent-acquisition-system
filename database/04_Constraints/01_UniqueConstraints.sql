/* ============================================================================
   TAMS - 04_Constraints / 01_UniqueConstraints.sql
   Table-driven, repeatable. Must run BEFORE 02_ForeignKeys.sql because the
   composite (Id, CustomerId) keys are targets of customer-isolation FKs.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;

DECLARE @u TABLE (Name SYSNAME, TableName NVARCHAR(256), Cols NVARCHAR(400));
INSERT @u (Name, TableName, Cols) VALUES
 -- sec
 (N'UQ_Users_Email',              N'sec.Users',            N'EmailNormalized'),
 (N'UQ_Roles_Name',               N'sec.Roles',            N'RoleName'),
 (N'UQ_Permissions_Code',         N'sec.Permissions',      N'Code'),
 (N'UQ_AuthTokens_Jti',           N'sec.AuthTokens',       N'Jti'),
 (N'UQ_PwdReset_TokenHash',       N'sec.PasswordResetTokens', N'TokenHash'),
 (N'UQ_EmailVerify_TokenHash',    N'sec.EmailVerificationTokens', N'TokenHash'),
 -- org
 (N'UQ_Organizations_Name',       N'org.Organizations',    N'Name'),
 (N'UQ_Locations_Org_Name',       N'org.Locations',        N'OrganizationId, Name'),
 (N'UQ_Departments_Org_Name',     N'org.Departments',      N'OrganizationId, Name'),
 (N'UQ_OrgUsers_User',            N'org.OrganizationUsers',N'UserId'),
 (N'UQ_Customers_Code',           N'org.Customers',        N'CustomerCode'),
 (N'UQ_Customers_Name',           N'org.Customers',        N'Name'),
 (N'UQ_CustomerUsers_User',       N'org.CustomerUsers',    N'UserId'),
 -- rec
 (N'UQ_RecSources_Name',          N'rec.RecruitmentSources', N'Name'),
 (N'UQ_JobReq_JobCode',           N'rec.JobRequisitions',  N'JobCode'),
 (N'UQ_JobDesc_Req_Version',      N'rec.JobDescriptions',  N'JobRequisitionId, VersionNo'),
 (N'UQ_JobSkills_Req_Skill',      N'rec.JobSkills',        N'JobRequisitionId, SkillName'),
 -- cand
 (N'UQ_Candidates_Email',         N'cand.Candidates',      N'EmailNormalized'),
 (N'UQ_CandSkills_Cand_Skill',    N'cand.CandidateSkills', N'CandidateId, SkillName'),
 (N'UQ_Panels_Interview_User',    N'cand.InterviewPanels', N'InterviewId, UserId'),
 (N'UQ_Feedback_Interview_User',  N'cand.InterviewFeedback', N'InterviewId, InterviewerUserId'),
 (N'UQ_JobOffers_OfferNo',        N'cand.JobOffers',       N'OfferNo'),
 -- hr
 (N'UQ_EmpReq_No',                N'hr.EmployeeRequisitions', N'RequisitionNo'),
 (N'UQ_Employees_No',             N'hr.Employees',         N'EmployeeNo'),
 (N'UQ_Employees_Offer',          N'hr.Employees',         N'JobOfferId'),     -- offer -> employee is 1:1
 (N'UQ_Employees_Candidate',      N'hr.Employees',         N'CandidateId'),
 -- staff
 (N'UQ_Contractors_No',           N'staff.Contractors',    N'ContractorNo'),
 (N'UQ_Contractors_Candidate',    N'staff.Contractors',    N'CandidateId'),    -- one contractor entity per person
 (N'UQ_CustReq_No',               N'staff.CustomerRequisitions', N'RequestNo'),
 (N'UQ_CustReq_Id_Customer',      N'staff.CustomerRequisitions', N'CustomerRequisitionId, CustomerId'),
 (N'UQ_Submitted_Id_Customer',    N'staff.SubmittedCandidates',  N'SubmissionId, CustomerId'),
 (N'UQ_Placements_Submission',    N'staff.Placements',     N'SubmissionId'),
 (N'UQ_Placements_Id_Customer',   N'staff.Placements',     N'PlacementId, CustomerId'),
 (N'UQ_Contracts_No',             N'staff.Contracts',      N'ContractNo'),
 (N'UQ_Contracts_Id_Customer',    N'staff.Contracts',      N'ContractId, CustomerId'),
 (N'UQ_Assignments_Id_Customer',  N'staff.Assignments',    N'AssignmentId, CustomerId'),
 -- time
 (N'UQ_Timesheets_Assign_Week',   N'[time].Timesheets',    N'AssignmentId, WeekStartDate'),
 (N'UQ_TsEntries_Day_Type',       N'[time].TimesheetEntries', N'TimesheetId, WorkDate, EntryType'),
 -- bill
 (N'UQ_Invoices_No',              N'bill.Invoices',        N'InvoiceNo'),
 (N'UQ_Invoices_Id_Customer',     N'bill.Invoices',        N'InvoiceId, CustomerId'),
 (N'UQ_InvoiceLines_Entry',       N'bill.InvoiceLines',    N'TimesheetEntryId'), -- a time entry is billed at most once
 -- doc / notify / sched
 (N'UQ_Documents_StoredName',     N'doc.Documents',        N'StoredFileName'),
 (N'UQ_NotifQ_DedupeKey',         N'notify.NotificationQueue', N'DedupeKey'),
 (N'UQ_JobDefs_Name',             N'sched.JobDefinitions', N'JobName');

DECLARE @n SYSNAME, @t NVARCHAR(256), @c NVARCHAR(400), @sql NVARCHAR(1000), @made INT = 0;
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT Name, TableName, Cols FROM @u;
OPEN cur; FETCH NEXT FROM cur INTO @n, @t, @c;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = @n AND parent_object_id = OBJECT_ID(@t))
    BEGIN
        SET @sql = N'ALTER TABLE ' + @t + N' ADD CONSTRAINT ' + QUOTENAME(@n) + N' UNIQUE (' + @c + N');';
        EXEC sys.sp_executesql @sql;
        SET @made += 1;
    END
    FETCH NEXT FROM cur INTO @n, @t, @c;
END
CLOSE cur; DEALLOCATE cur;
PRINT 'Unique constraints created this run: ' + CAST(@made AS VARCHAR(10));
GO
