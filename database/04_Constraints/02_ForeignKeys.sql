/* ============================================================================
   TAMS - 04_Constraints / 02_ForeignKeys.sql
   Table-driven, repeatable. Composite (Id, CustomerId) FKs enforce CUSTOMER ISOLATION:
   a child row can only reference a parent that belongs to the SAME customer.
   Audit / login-history tables intentionally have no FK to sec.Users so that
   logging can never fail or block user maintenance.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;

DECLARE @f TABLE (Name SYSNAME, ChildTable NVARCHAR(256), ChildCols NVARCHAR(200),
                  ParentTable NVARCHAR(256), ParentCols NVARCHAR(200));
INSERT @f VALUES
 -- sec
 (N'FK_UserRoles_User',        N'sec.UserRoles',  N'UserId', N'sec.Users', N'UserId'),
 (N'FK_UserRoles_Role',        N'sec.UserRoles',  N'RoleId', N'sec.Roles', N'RoleId'),
 (N'FK_RolePerms_Role',        N'sec.RolePermissions', N'RoleId', N'sec.Roles', N'RoleId'),
 (N'FK_RolePerms_Perm',        N'sec.RolePermissions', N'PermissionId', N'sec.Permissions', N'PermissionId'),
 (N'FK_AuthTokens_User',       N'sec.AuthTokens', N'UserId', N'sec.Users', N'UserId'),
 (N'FK_PwdReset_User',         N'sec.PasswordResetTokens', N'UserId', N'sec.Users', N'UserId'),
 (N'FK_EmailVerify_User',      N'sec.EmailVerificationTokens', N'UserId', N'sec.Users', N'UserId'),
 -- org
 (N'FK_Locations_Org',         N'org.Locations',   N'OrganizationId', N'org.Organizations', N'OrganizationId'),
 (N'FK_Departments_Org',       N'org.Departments', N'OrganizationId', N'org.Organizations', N'OrganizationId'),
 (N'FK_Departments_Head',      N'org.Departments', N'HeadUserId', N'sec.Users', N'UserId'),
 (N'FK_OrgUsers_User',         N'org.OrganizationUsers', N'UserId', N'sec.Users', N'UserId'),
 (N'FK_OrgUsers_Org',          N'org.OrganizationUsers', N'OrganizationId', N'org.Organizations', N'OrganizationId'),
 (N'FK_OrgUsers_Dept',         N'org.OrganizationUsers', N'DepartmentId', N'org.Departments', N'DepartmentId'),
 (N'FK_Customers_AcctMgr',     N'org.Customers', N'AccountManagerUserId', N'sec.Users', N'UserId'),
 (N'FK_CustUsers_User',        N'org.CustomerUsers', N'UserId', N'sec.Users', N'UserId'),
 (N'FK_CustUsers_Customer',    N'org.CustomerUsers', N'CustomerId', N'org.Customers', N'CustomerId'),
 -- hr (requisition side)
 (N'FK_EmpReq_Dept',           N'hr.EmployeeRequisitions', N'DepartmentId', N'org.Departments', N'DepartmentId'),
 (N'FK_EmpReq_Location',       N'hr.EmployeeRequisitions', N'LocationId', N'org.Locations', N'LocationId'),
 (N'FK_EmpReq_RequestedBy',    N'hr.EmployeeRequisitions', N'RequestedByUserId', N'sec.Users', N'UserId'),
 (N'FK_HiringAppr_Req',        N'hr.HiringApprovals', N'EmployeeRequisitionId', N'hr.EmployeeRequisitions', N'EmployeeRequisitionId'),
 (N'FK_HiringAppr_Approver',   N'hr.HiringApprovals', N'ApproverUserId', N'sec.Users', N'UserId'),
 -- rec
 (N'FK_JobReq_EmpReq',         N'rec.JobRequisitions', N'EmployeeRequisitionId', N'hr.EmployeeRequisitions', N'EmployeeRequisitionId'),
 (N'FK_JobReq_Dept',           N'rec.JobRequisitions', N'DepartmentId', N'org.Departments', N'DepartmentId'),
 (N'FK_JobReq_Location',       N'rec.JobRequisitions', N'LocationId', N'org.Locations', N'LocationId'),
 (N'FK_JobReq_Owner',          N'rec.JobRequisitions', N'OwnerRecruiterUserId', N'sec.Users', N'UserId'),
 (N'FK_JobReq_CreatedBy',      N'rec.JobRequisitions', N'CreatedByUserId', N'sec.Users', N'UserId'),
 (N'FK_JobReq_UpdatedBy',      N'rec.JobRequisitions', N'UpdatedByUserId', N'sec.Users', N'UserId'),
 (N'FK_JobDesc_Req',           N'rec.JobDescriptions', N'JobRequisitionId', N'rec.JobRequisitions', N'JobRequisitionId'),
 (N'FK_JobDesc_CreatedBy',     N'rec.JobDescriptions', N'CreatedByUserId', N'sec.Users', N'UserId'),
 (N'FK_JobSkills_Req',         N'rec.JobSkills', N'JobRequisitionId', N'rec.JobRequisitions', N'JobRequisitionId'),
 (N'FK_JobAppr_Req',           N'rec.JobApprovals', N'JobRequisitionId', N'rec.JobRequisitions', N'JobRequisitionId'),
 (N'FK_JobAppr_Approver',      N'rec.JobApprovals', N'ApproverUserId', N'sec.Users', N'UserId'),
 (N'FK_JobPostings_Req',       N'rec.JobPostings', N'JobRequisitionId', N'rec.JobRequisitions', N'JobRequisitionId'),
 (N'FK_JobPostings_Source',    N'rec.JobPostings', N'SourceId', N'rec.RecruitmentSources', N'SourceId'),
 (N'FK_JobPostings_PostedBy',  N'rec.JobPostings', N'PostedByUserId', N'sec.Users', N'UserId'),
 -- cand
 (N'FK_Candidates_User',       N'cand.Candidates', N'UserId', N'sec.Users', N'UserId'),
 (N'FK_Candidates_Source',     N'cand.Candidates', N'SourceId', N'rec.RecruitmentSources', N'SourceId'),
 (N'FK_Candidates_CreatedBy',  N'cand.Candidates', N'CreatedByUserId', N'sec.Users', N'UserId'),
 (N'FK_Candidates_UpdatedBy',  N'cand.Candidates', N'UpdatedByUserId', N'sec.Users', N'UserId'),
 (N'FK_CandAddr_Cand',         N'cand.CandidateAddresses', N'CandidateId', N'cand.Candidates', N'CandidateId'),
 (N'FK_CandEdu_Cand',          N'cand.CandidateEducation', N'CandidateId', N'cand.Candidates', N'CandidateId'),
 (N'FK_CandExp_Cand',          N'cand.CandidateExperience', N'CandidateId', N'cand.Candidates', N'CandidateId'),
 (N'FK_CandSkills_Cand',       N'cand.CandidateSkills', N'CandidateId', N'cand.Candidates', N'CandidateId'),
 (N'FK_CandDocs_Cand',         N'cand.CandidateDocuments', N'CandidateId', N'cand.Candidates', N'CandidateId'),
 (N'FK_CandDocs_Doc',          N'cand.CandidateDocuments', N'DocumentId', N'doc.Documents', N'DocumentId'),
 (N'FK_JobApps_Cand',          N'cand.JobApplications', N'CandidateId', N'cand.Candidates', N'CandidateId'),
 (N'FK_JobApps_Posting',       N'cand.JobApplications', N'JobPostingId', N'rec.JobPostings', N'JobPostingId'),
 (N'FK_JobApps_Source',        N'cand.JobApplications', N'SourceId', N'rec.RecruitmentSources', N'SourceId'),
 (N'FK_JobApps_UpdatedBy',     N'cand.JobApplications', N'UpdatedByUserId', N'sec.Users', N'UserId'),
 (N'FK_AppHist_App',           N'cand.ApplicationStatusHistory', N'ApplicationId', N'cand.JobApplications', N'ApplicationId'),
 (N'FK_AppHist_ChangedBy',     N'cand.ApplicationStatusHistory', N'ChangedByUserId', N'sec.Users', N'UserId'),
 (N'FK_Interviews_App',        N'cand.Interviews', N'JobApplicationId', N'cand.JobApplications', N'ApplicationId'),
 (N'FK_Interviews_Submission_Customer', N'cand.Interviews', N'SubmittedCandidateId, CustomerId', N'staff.SubmittedCandidates', N'SubmissionId, CustomerId'),
 (N'FK_Interviews_ScheduledBy',N'cand.Interviews', N'ScheduledByUserId', N'sec.Users', N'UserId'),
 (N'FK_Panels_Interview',      N'cand.InterviewPanels', N'InterviewId', N'cand.Interviews', N'InterviewId'),
 (N'FK_Panels_User',           N'cand.InterviewPanels', N'UserId', N'sec.Users', N'UserId'),
 (N'FK_Feedback_Interview',    N'cand.InterviewFeedback', N'InterviewId', N'cand.Interviews', N'InterviewId'),
 (N'FK_Feedback_Interviewer',  N'cand.InterviewFeedback', N'InterviewerUserId', N'sec.Users', N'UserId'),
 (N'FK_Offers_App',            N'cand.JobOffers', N'ApplicationId', N'cand.JobApplications', N'ApplicationId'),
 (N'FK_Offers_CreatedBy',      N'cand.JobOffers', N'CreatedByUserId', N'sec.Users', N'UserId'),
 (N'FK_OfferAppr_Offer',       N'cand.OfferApprovals', N'OfferId', N'cand.JobOffers', N'OfferId'),
 (N'FK_OfferAppr_Approver',    N'cand.OfferApprovals', N'ApproverUserId', N'sec.Users', N'UserId'),
 -- hr (employee side)
 (N'FK_Employees_Cand',        N'hr.Employees', N'CandidateId', N'cand.Candidates', N'CandidateId'),
 (N'FK_Employees_Offer',       N'hr.Employees', N'JobOfferId', N'cand.JobOffers', N'OfferId'),
 (N'FK_Employees_Dept',        N'hr.Employees', N'DepartmentId', N'org.Departments', N'DepartmentId'),
 (N'FK_Employees_Location',    N'hr.Employees', N'LocationId', N'org.Locations', N'LocationId'),
 (N'FK_Employees_Manager',     N'hr.Employees', N'ManagerUserId', N'sec.Users', N'UserId'),
 (N'FK_Onboarding_Employee',   N'hr.EmployeeOnboarding', N'EmployeeId', N'hr.Employees', N'EmployeeId'),
 (N'FK_Onboarding_CompletedBy',N'hr.EmployeeOnboarding', N'CompletedByUserId', N'sec.Users', N'UserId'),
 (N'FK_EmpDocs_Employee',      N'hr.EmployeeDocuments', N'EmployeeId', N'hr.Employees', N'EmployeeId'),
 (N'FK_EmpDocs_Doc',           N'hr.EmployeeDocuments', N'DocumentId', N'doc.Documents', N'DocumentId'),
 (N'FK_EmpHist_Employee',      N'hr.EmploymentHistory', N'EmployeeId', N'hr.Employees', N'EmployeeId'),
 (N'FK_EmpHist_RecordedBy',    N'hr.EmploymentHistory', N'RecordedByUserId', N'sec.Users', N'UserId'),
 -- staff
 (N'FK_Contractors_Cand',      N'staff.Contractors', N'CandidateId', N'cand.Candidates', N'CandidateId'),
 (N'FK_Contractors_User',      N'staff.Contractors', N'UserId', N'sec.Users', N'UserId'),
 (N'FK_Contractors_CreatedBy', N'staff.Contractors', N'CreatedByUserId', N'sec.Users', N'UserId'),
 (N'FK_CustReq_Customer',      N'staff.CustomerRequisitions', N'CustomerId', N'org.Customers', N'CustomerId'),
 (N'FK_CustReq_Recruiter',     N'staff.CustomerRequisitions', N'AssignedRecruiterUserId', N'sec.Users', N'UserId'),
 (N'FK_CustReq_CreatedBy',     N'staff.CustomerRequisitions', N'CreatedByUserId', N'sec.Users', N'UserId'),
 (N'FK_Submitted_Req_Customer',N'staff.SubmittedCandidates', N'CustomerRequisitionId, CustomerId', N'staff.CustomerRequisitions', N'CustomerRequisitionId, CustomerId'),
 (N'FK_Submitted_Cand',        N'staff.SubmittedCandidates', N'CandidateId', N'cand.Candidates', N'CandidateId'),
 (N'FK_Submitted_SubmittedBy', N'staff.SubmittedCandidates', N'SubmittedByUserId', N'sec.Users', N'UserId'),
 (N'FK_CustDec_Sub_Customer',  N'staff.CustomerCandidateDecisions', N'SubmissionId, CustomerId', N'staff.SubmittedCandidates', N'SubmissionId, CustomerId'),
 (N'FK_CustDec_DecidedBy',     N'staff.CustomerCandidateDecisions', N'DecidedByUserId', N'sec.Users', N'UserId'),
 (N'FK_Placements_Sub_Customer',N'staff.Placements', N'SubmissionId, CustomerId', N'staff.SubmittedCandidates', N'SubmissionId, CustomerId'),
 (N'FK_Placements_Contractor', N'staff.Placements', N'ContractorId', N'staff.Contractors', N'ContractorId'),
 (N'FK_Placements_CreatedBy',  N'staff.Placements', N'CreatedByUserId', N'sec.Users', N'UserId'),
 (N'FK_Contracts_Plc_Customer',N'staff.Contracts', N'PlacementId, CustomerId', N'staff.Placements', N'PlacementId, CustomerId'),
 (N'FK_Contracts_Doc',         N'staff.Contracts', N'DocumentId', N'doc.Documents', N'DocumentId'),
 (N'FK_Contracts_CreatedBy',   N'staff.Contracts', N'CreatedByUserId', N'sec.Users', N'UserId'),
 (N'FK_Assign_Ctr_Customer',   N'staff.Assignments', N'ContractId, CustomerId', N'staff.Contracts', N'ContractId, CustomerId'),
 (N'FK_Assign_Contractor',     N'staff.Assignments', N'ContractorId', N'staff.Contractors', N'ContractorId'),
 (N'FK_Rates_Contract',        N'staff.ContractRates', N'ContractId', N'staff.Contracts', N'ContractId'),
 (N'FK_Rates_CreatedBy',       N'staff.ContractRates', N'CreatedByUserId', N'sec.Users', N'UserId'),
 (N'FK_Ext_Contract',          N'staff.ContractExtensions', N'ContractId', N'staff.Contracts', N'ContractId'),
 (N'FK_Ext_ApprovedBy',        N'staff.ContractExtensions', N'ApprovedByUserId', N'sec.Users', N'UserId'),
 (N'FK_Compliance_Contractor', N'staff.ComplianceRecords', N'ContractorId', N'staff.Contractors', N'ContractorId'),
 (N'FK_Compliance_Doc',        N'staff.ComplianceRecords', N'DocumentId', N'doc.Documents', N'DocumentId'),
 (N'FK_Compliance_VerifiedBy', N'staff.ComplianceRecords', N'VerifiedByUserId', N'sec.Users', N'UserId'),
 -- time
 (N'FK_Timesheets_Assign_Customer', N'[time].Timesheets', N'AssignmentId, CustomerId', N'staff.Assignments', N'AssignmentId, CustomerId'),
 (N'FK_Timesheets_Contractor', N'[time].Timesheets', N'ContractorId', N'staff.Contractors', N'ContractorId'),
 (N'FK_TsEntries_Timesheet',   N'[time].TimesheetEntries', N'TimesheetId', N'[time].Timesheets', N'TimesheetId'),
 (N'FK_TsAppr_Timesheet',      N'[time].TimesheetApprovals', N'TimesheetId', N'[time].Timesheets', N'TimesheetId'),
 (N'FK_TsAppr_User',           N'[time].TimesheetApprovals', N'ApprovedByUserId', N'sec.Users', N'UserId'),
 (N'FK_TsRej_Timesheet',       N'[time].TimesheetRejections', N'TimesheetId', N'[time].Timesheets', N'TimesheetId'),
 (N'FK_TsRej_User',            N'[time].TimesheetRejections', N'RejectedByUserId', N'sec.Users', N'UserId'),
 -- bill
 (N'FK_RateCards_Customer',    N'bill.RateCards', N'CustomerId', N'org.Customers', N'CustomerId'),
 (N'FK_Invoices_Customer',     N'bill.Invoices', N'CustomerId', N'org.Customers', N'CustomerId'),
 (N'FK_Invoices_GeneratedBy',  N'bill.Invoices', N'GeneratedByUserId', N'sec.Users', N'UserId'),
 (N'FK_InvLines_Invoice',      N'bill.InvoiceLines', N'InvoiceId', N'bill.Invoices', N'InvoiceId'),
 (N'FK_InvLines_Entry',        N'bill.InvoiceLines', N'TimesheetEntryId', N'[time].TimesheetEntries', N'EntryId'),
 (N'FK_Payments_Inv_Customer', N'bill.Payments', N'InvoiceId, CustomerId', N'bill.Invoices', N'InvoiceId, CustomerId'),
 (N'FK_Payments_RecordedBy',   N'bill.Payments', N'RecordedByUserId', N'sec.Users', N'UserId'),
 -- doc / notify / sched
 (N'FK_Documents_UploadedBy',  N'doc.Documents', N'UploadedByUserId', N'sec.Users', N'UserId'),
 (N'FK_Documents_Customer',    N'doc.Documents', N'CustomerId', N'org.Customers', N'CustomerId'),
 (N'FK_NotifQ_Recipient',      N'notify.NotificationQueue', N'RecipientUserId', N'sec.Users', N'UserId'),
 (N'FK_NotifHist_Notif',       N'notify.NotificationHistory', N'NotificationId', N'notify.NotificationQueue', N'NotificationId'),
 (N'FK_JobExec_Definition',    N'sched.JobExecutionHistory', N'JobDefinitionId', N'sched.JobDefinitions', N'JobDefinitionId'),
 (N'FK_JobDetails_Execution',  N'sched.JobExecutionDetails', N'ExecutionId', N'sched.JobExecutionHistory', N'ExecutionId'),
 (N'FK_ReportRuns_Actor',      N'audit.ReportRuns', N'ActorUserId', N'sec.Users', N'UserId');

DECLARE @n SYSNAME, @ct NVARCHAR(256), @cc NVARCHAR(200), @pt NVARCHAR(256), @pc NVARCHAR(200), @sql NVARCHAR(1200), @made INT = 0;
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT Name, ChildTable, ChildCols, ParentTable, ParentCols FROM @f;
OPEN cur; FETCH NEXT FROM cur INTO @n, @ct, @cc, @pt, @pc;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = @n AND parent_object_id = OBJECT_ID(@ct))
    BEGIN
        SET @sql = N'ALTER TABLE ' + @ct + N' WITH CHECK ADD CONSTRAINT ' + QUOTENAME(@n)
                 + N' FOREIGN KEY (' + @cc + N') REFERENCES ' + @pt + N' (' + @pc + N');';
        EXEC sys.sp_executesql @sql;
        SET @made += 1;
    END
    FETCH NEXT FROM cur INTO @n, @ct, @cc, @pt, @pc;
END
CLOSE cur; DEALLOCATE cur;
PRINT 'Foreign keys created this run: ' + CAST(@made AS VARCHAR(10));
GO
