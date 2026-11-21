/* ============================================================================
   TAMS - 04_Constraints / 03_CheckConstraints.sql
   Table-driven, repeatable. Status domains, ranges, date ordering and the
   "exactly one opportunity" rule for interviews.
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;

DECLARE @k TABLE (Name SYSNAME, TableName NVARCHAR(256), Expr NVARCHAR(1000));
INSERT @k VALUES
 -- sec
 (N'CK_Users_Iterations',   N'sec.Users', N'HashIterations >= 10000'),
 (N'CK_Users_Failed',       N'sec.Users', N'FailedLoginCount >= 0'),
 (N'CK_AuthTokens_Expiry',  N'sec.AuthTokens', N'ExpiresAt > IssuedAt'),
 -- org
 (N'CK_Customers_Status',   N'org.Customers', N'Status IN (''Active'',''Inactive'',''OnHold'')'),
 (N'CK_Customers_Terms',    N'org.Customers', N'PaymentTermsDays BETWEEN 0 AND 365'),
 -- rec
 (N'CK_RecSources_Type',    N'rec.RecruitmentSources', N'SourceType IN (''Portal'',''Referral'',''Agency'',''SocialMedia'',''Event'',''Direct'')'),
 (N'CK_JobReq_Status',      N'rec.JobRequisitions', N'Status IN (''Draft'',''PendingApproval'',''Approved'',''Open'',''OnHold'',''Filled'',''Closed'',''Expired'')'),
 (N'CK_JobReq_EmpType',     N'rec.JobRequisitions', N'EmploymentType IN (''FullTime'',''PartTime'',''Intern'')'),
 (N'CK_JobReq_Openings',    N'rec.JobRequisitions', N'Openings > 0'),
 (N'CK_JobDesc_Salary',     N'rec.JobDescriptions', N'SalaryMax IS NULL OR SalaryMin IS NULL OR SalaryMax >= SalaryMin'),
 (N'CK_JobDesc_Exp',        N'rec.JobDescriptions', N'MinExperienceYears >= 0'),
 (N'CK_JobSkills_Years',    N'rec.JobSkills', N'MinYears >= 0'),
 (N'CK_JobAppr_Decision',   N'rec.JobApprovals', N'Decision IN (''Approved'',''Rejected'')'),
 (N'CK_JobPostings_Status', N'rec.JobPostings', N'Status IN (''Draft'',''Published'',''Closed'')'),
 (N'CK_JobPostings_Dates',  N'rec.JobPostings', N'ClosesAt IS NULL OR PostedAt IS NULL OR ClosesAt > PostedAt'),
 -- cand
 (N'CK_Cand_Status',        N'cand.Candidates', N'Status IN (''Active'',''Inactive'',''Blacklisted'')'),
 (N'CK_Cand_Exp',           N'cand.Candidates', N'TotalExperienceYears BETWEEN 0 AND 60'),
 (N'CK_Cand_Email',         N'cand.Candidates', N'Email LIKE ''%_@_%._%'''),
 (N'CK_CandAddr_Type',      N'cand.CandidateAddresses', N'AddressType IN (''Home'',''Mailing'',''Work'')'),
 (N'CK_CandEdu_Years',      N'cand.CandidateEducation', N'EndYear IS NULL OR StartYear IS NULL OR EndYear >= StartYear'),
 (N'CK_CandExp_Dates',      N'cand.CandidateExperience', N'EndDate IS NULL OR EndDate >= StartDate'),
 (N'CK_CandSkills_Level',   N'cand.CandidateSkills', N'ProficiencyLevel BETWEEN 1 AND 5 AND YearsExperience >= 0'),
 (N'CK_CandDocs_Type',      N'cand.CandidateDocuments', N'DocType IN (''Resume'',''CoverLetter'',''Certificate'',''Identity'',''Other'')'),
 (N'CK_JobApps_Status',     N'cand.JobApplications', N'Status IN (''Applied'',''Screening'',''Shortlisted'',''Interview'',''Selected'',''OfferStage'',''Hired'',''Rejected'',''Withdrawn'')'),
 (N'CK_AppHist_Status',     N'cand.ApplicationStatusHistory', N'NewStatus IN (''Applied'',''Screening'',''Shortlisted'',''Interview'',''Selected'',''OfferStage'',''Hired'',''Rejected'',''Withdrawn'')'),
 (N'CK_Interviews_Status',  N'cand.Interviews', N'Status IN (''Scheduled'',''Rescheduled'',''Completed'',''Cancelled'',''NoShow'')'),
 (N'CK_Interviews_Mode',    N'cand.Interviews', N'Mode IN (''Onsite'',''Video'',''Phone'')'),
 (N'CK_Interviews_Type',    N'cand.Interviews', N'InterviewType IN (''Screening'',''Technical'',''HR'',''Managerial'',''Customer'')'),
 (N'CK_Interviews_Time',    N'cand.Interviews', N'EndsAt > StartsAt'),
 (N'CK_Interviews_Round',   N'cand.Interviews', N'RoundNo BETWEEN 1 AND 10'),
 (N'CK_Interviews_OneOpportunity', N'cand.Interviews',
    N'(JobApplicationId IS NOT NULL AND SubmittedCandidateId IS NULL AND CustomerId IS NULL) OR (JobApplicationId IS NULL AND SubmittedCandidateId IS NOT NULL AND CustomerId IS NOT NULL)'),
 (N'CK_Feedback_Rating',    N'cand.InterviewFeedback', N'Rating BETWEEN 1 AND 5'),
 (N'CK_Feedback_Recommendation', N'cand.InterviewFeedback', N'Recommendation IN (''StrongYes'',''Yes'',''No'',''StrongNo'')'),
 (N'CK_Offers_Status',      N'cand.JobOffers', N'Status IN (''Draft'',''PendingApproval'',''Approved'',''Rejected'',''Sent'',''Accepted'',''Declined'',''Expired'')'),
 (N'CK_Offers_Salary',      N'cand.JobOffers', N'OfferedSalary > 0'),
 (N'CK_OfferAppr_Decision', N'cand.OfferApprovals', N'Decision IN (''Approved'',''Rejected'')'),
 -- hr
 (N'CK_EmpReq_Status',      N'hr.EmployeeRequisitions', N'Status IN (''Draft'',''Submitted'',''Approved'',''Rejected'',''Cancelled'')'),
 (N'CK_EmpReq_Headcount',   N'hr.EmployeeRequisitions', N'Headcount > 0'),
 (N'CK_EmpReq_Type',        N'hr.EmployeeRequisitions', N'EmploymentType IN (''FullTime'',''PartTime'',''Intern'')'),
 (N'CK_HiringAppr_Decision',N'hr.HiringApprovals', N'Decision IN (''Approved'',''Rejected'')'),
 (N'CK_Employees_Status',   N'hr.Employees', N'Status IN (''Onboarding'',''Active'',''OnLeave'',''Terminated'')'),
 (N'CK_Employees_Salary',   N'hr.Employees', N'Salary > 0'),
 (N'CK_Onboarding_Status',  N'hr.EmployeeOnboarding', N'Status IN (''Pending'',''InProgress'',''Completed'',''Waived'')'),
 (N'CK_Onboarding_Category',N'hr.EmployeeOnboarding', N'Category IN (''Admin'',''IT'',''Compliance'',''Orientation'',''Payroll'')'),
 (N'CK_EmpHist_Event',      N'hr.EmploymentHistory', N'EventType IN (''Hired'',''Promotion'',''Transfer'',''SalaryChange'',''Termination'')'),
 -- staff
 (N'CK_Contractors_Status', N'staff.Contractors', N'Status IN (''Active'',''Inactive'',''Blocked'')'),
 (N'CK_CustReq_Status',     N'staff.CustomerRequisitions', N'Status IN (''Open'',''InReview'',''Sourcing'',''Filled'',''Cancelled'')'),
 (N'CK_CustReq_Positions',  N'staff.CustomerRequisitions', N'Positions > 0'),
 (N'CK_Submitted_Status',   N'staff.SubmittedCandidates', N'Status IN (''Submitted'',''Shortlisted'',''Interview'',''Selected'',''Rejected'',''Withdrawn'')'),
 (N'CK_CustDec_Decision',   N'staff.CustomerCandidateDecisions', N'Decision IN (''Shortlist'',''Reject'',''Select'')'),
 (N'CK_Placements_Status',  N'staff.Placements', N'Status IN (''Active'',''Completed'',''Cancelled'')'),
 (N'CK_Contracts_Status',   N'staff.Contracts', N'Status IN (''Draft'',''Active'',''Expiring'',''Expired'',''Terminated'',''Renewed'')'),
 (N'CK_Contracts_Dates',    N'staff.Contracts', N'EndDate >= StartDate'),
 (N'CK_Assign_Status',      N'staff.Assignments', N'Status IN (''Active'',''Completed'',''Cancelled'')'),
 (N'CK_Assign_Hours',       N'staff.Assignments', N'HoursPerWeek BETWEEN 1 AND 80'),
 (N'CK_Assign_Dates',       N'staff.Assignments', N'EndDate IS NULL OR EndDate >= StartDate'),
 (N'CK_Rates_NonNegative',  N'staff.ContractRates', N'PayRate >= 0 AND BillRate >= 0'),
 (N'CK_Rates_Margin',       N'staff.ContractRates', N'BillRate >= PayRate'),
 (N'CK_Rates_Dates',        N'staff.ContractRates', N'EffectiveTo IS NULL OR EffectiveTo >= EffectiveFrom'),
 (N'CK_Rates_Multipliers',  N'staff.ContractRates', N'OvertimePayMultiplier >= 1 AND OvertimeBillMultiplier >= 1'),
 (N'CK_Ext_Dates',          N'staff.ContractExtensions', N'NewEndDate > PreviousEndDate'),
 (N'CK_Compliance_Type',    N'staff.ComplianceRecords', N'RecordType IN (''BackgroundCheck'',''WorkAuthorization'',''NDA'',''Insurance'',''Identity'')'),
 (N'CK_Compliance_Status',  N'staff.ComplianceRecords', N'Status IN (''Pending'',''Verified'',''Expired'',''Rejected'')'),
 -- time
 (N'CK_Timesheets_Status',  N'[time].Timesheets', N'Status IN (''Draft'',''Submitted'',''Approved'',''Rejected'',''Invoiced'')'),
 (N'CK_Timesheets_Monday',  N'[time].Timesheets', N'DATEDIFF(DAY, ''19000101'', WeekStartDate) % 7 = 0'),   -- 1900-01-01 was a Monday
 (N'CK_Timesheets_Total',   N'[time].Timesheets', N'TotalHours BETWEEN 0 AND 168'),
 (N'CK_TsEntries_Hours',    N'[time].TimesheetEntries', N'Hours > 0 AND Hours <= 24'),
 (N'CK_TsEntries_Type',     N'[time].TimesheetEntries', N'EntryType IN (''Regular'',''Overtime'')'),
 (N'CK_TsRej_Reason',       N'[time].TimesheetRejections', N'LEN(LTRIM(RTRIM(Reason))) > 0'),
 -- bill
 (N'CK_RateCards_Rate',     N'bill.RateCards', N'StandardBillRate > 0'),
 (N'CK_Invoices_Status',    N'bill.Invoices', N'Status IN (''Draft'',''Issued'',''PartiallyPaid'',''Paid'',''Void'')'),
 (N'CK_Invoices_Amounts',   N'bill.Invoices', N'Subtotal >= 0 AND TaxAmount >= 0 AND Total >= 0 AND TaxRate BETWEEN 0 AND 100'),
 (N'CK_Invoices_Period',    N'bill.Invoices', N'PeriodEnd >= PeriodStart'),
 (N'CK_InvLines_Amounts',   N'bill.InvoiceLines', N'Hours > 0 AND BillRate >= 0 AND ABS(LineTotal - Hours * BillRate) < 0.01'),
 (N'CK_Payments_Amount',    N'bill.Payments', N'Amount > 0'),
 (N'CK_Payments_Method',    N'bill.Payments', N'Method IN (''BankTransfer'',''Cheque'',''Card'',''Cash'')'),
 -- doc / notify / audit / sched
 (N'CK_Documents_Owner',    N'doc.Documents', N'OwnerType IN (''Candidate'',''Employee'',''Contractor'',''Contract'')'),
 (N'CK_Documents_Size',     N'doc.Documents', N'SizeBytes BETWEEN 1 AND 10485760'),
 (N'CK_NotifQ_Status',      N'notify.NotificationQueue', N'Status IN (''Pending'',''Processing'',''Sent'',''Failed'',''Cancelled'')'),
 (N'CK_NotifQ_Attempts',    N'notify.NotificationQueue', N'Attempts >= 0 AND MaxAttempts >= 1'),
 (N'CK_NotifHist_Outcome',  N'notify.NotificationHistory', N'Outcome IN (''Sent'',''Failed'')'),
 (N'CK_AuditLogs_Action',   N'audit.AuditLogs', N'Action IN (''I'',''U'',''D'')'),
 (N'CK_JobDefs_Owner',      N'sched.JobDefinitions', N'Owner IN (''SqlAgent'',''TaskScheduler'')'),
 (N'CK_JobExec_Outcome',    N'sched.JobExecutionHistory', N'Outcome IN (''Running'',''Succeeded'',''Failed'',''Skipped'')');

DECLARE @n SYSNAME, @t NVARCHAR(256), @e NVARCHAR(1000), @sql NVARCHAR(1500), @made INT = 0;
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT Name, TableName, Expr FROM @k;
OPEN cur; FETCH NEXT FROM cur INTO @n, @t, @e;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = @n AND parent_object_id = OBJECT_ID(@t))
    BEGIN
        SET @sql = N'ALTER TABLE ' + @t + N' WITH CHECK ADD CONSTRAINT ' + QUOTENAME(@n) + N' CHECK (' + @e + N');';
        EXEC sys.sp_executesql @sql;
        SET @made += 1;
    END
    FETCH NEXT FROM cur INTO @n, @t, @e;
END
CLOSE cur; DEALLOCATE cur;
PRINT 'Check constraints created this run: ' + CAST(@made AS VARCHAR(10));
GO
