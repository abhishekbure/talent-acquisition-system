/* ============================================================================
   TAMS - 06_StoredProcedures / 10_Dashboards.sql
   One procedure per dashboard request: every number is computed from the tables at call time
   (nothing hard-coded) and is SCOPED to the caller (own customer, own contractor, own candidate, ...).
   Single result set: metrics (MetricKey, Label, Value, Unit). Notifications come from notify.usp_ListMyNotifications.
   ========================================================================== */
USE TalentAcquisitionDB;
GO

CREATE OR ALTER PROCEDURE report.usp_Dashboard @ActorUserId INT, @Role NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    EXEC sec.usp_Authorize @ActorUserId, N'Candidate,Contractor,Customer,Recruiter,HRManager,Administrator';
    IF @Role NOT IN (N'Candidate', N'Contractor', N'Customer', N'Recruiter', N'HRManager', N'Administrator') THROW 50001, N'Unknown dashboard role.', 1;
    IF sec.fn_UserHasRole(@ActorUserId, @Role) = 0 THROW 50005, N'You do not have this role.', 1;

    DECLARE @m TABLE (Ord INT IDENTITY(1,1), MetricKey VARCHAR(40), Label NVARCHAR(100), Value DECIMAL(18,2), Unit VARCHAR(10));
    DECLARE @now DATETIME2(0) = SYSUTCDATETIME(), @today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @cid INT = cand.fn_CandidateIdForUser(@ActorUserId), @ctr INT = staff.fn_ContractorIdForUser(@ActorUserId), @cust INT = sec.fn_UserCustomerId(@ActorUserId);

    IF @Role = N'Candidate'
    BEGIN
        INSERT @m (MetricKey, Label, Value, Unit) VALUES
         ('applications',   N'My applications',          (SELECT COUNT(*) FROM cand.JobApplications WHERE CandidateId = @cid), 'count'),
         ('activeApps',     N'Applications in progress', (SELECT COUNT(*) FROM cand.JobApplications WHERE CandidateId = @cid AND Status NOT IN ('Hired','Rejected','Withdrawn')), 'count'),
         ('interviews',     N'Upcoming interviews',      (SELECT COUNT(*) FROM cand.Interviews i LEFT JOIN cand.JobApplications a ON a.ApplicationId = i.JobApplicationId LEFT JOIN staff.SubmittedCandidates s ON s.SubmissionId = i.SubmittedCandidateId
                                                           WHERE COALESCE(a.CandidateId, s.CandidateId) = @cid AND i.Status IN ('Scheduled','Rescheduled') AND i.StartsAt >= @now), 'count'),
         ('offers',         N'Offers awaiting my reply', (SELECT COUNT(*) FROM cand.JobOffers o JOIN cand.JobApplications a ON a.ApplicationId = o.ApplicationId WHERE a.CandidateId = @cid AND o.Status = 'Sent' AND o.ExpiresAt > @now), 'count'),
         ('openJobs',       N'Open jobs you can apply to', (SELECT COUNT(*) FROM rec.JobPostings p JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId WHERE p.Status = 'Published' AND jr.Status = 'Open'), 'count');
    END
    ELSE IF @Role = N'Contractor'
    BEGIN
        INSERT @m (MetricKey, Label, Value, Unit) VALUES
         ('assignments',    N'Active assignments',       (SELECT COUNT(*) FROM staff.Assignments WHERE ContractorId = @ctr AND Status = 'Active'), 'count'),
         ('draft',          N'Draft timesheets',         (SELECT COUNT(*) FROM [time].Timesheets WHERE ContractorId = @ctr AND Status = 'Draft'), 'count'),
         ('rejected',       N'Timesheets to correct',    (SELECT COUNT(*) FROM [time].Timesheets WHERE ContractorId = @ctr AND Status = 'Rejected'), 'count'),
         ('awaiting',       N'Awaiting customer approval', (SELECT COUNT(*) FROM [time].Timesheets WHERE ContractorId = @ctr AND Status = 'Submitted'), 'count'),
         ('hoursMonth',     N'Hours worked this month',  (SELECT ISNULL(SUM(e.Hours), 0) FROM [time].TimesheetEntries e JOIN [time].Timesheets t ON t.TimesheetId = e.TimesheetId WHERE t.ContractorId = @ctr AND e.WorkDate >= DATEADD(DAY, 1 - DAY(@today), @today)), 'hours'),
         ('complianceDue',  N'Compliance items expiring within 60 days', (SELECT COUNT(*) FROM staff.ComplianceRecords WHERE ContractorId = @ctr AND ExpiresOn IS NOT NULL AND ExpiresOn <= DATEADD(DAY, 60, @today)), 'count');
    END
    ELSE IF @Role = N'Customer'
    BEGIN
        IF @cust IS NULL THROW 50005, N'This login is not linked to a customer.', 1;
        INSERT @m (MetricKey, Label, Value, Unit) VALUES
         ('openRequests',   N'Open staffing requests',   (SELECT COUNT(*) FROM staff.CustomerRequisitions WHERE CustomerId = @cust AND Status IN ('Open','InReview','Sourcing')), 'count'),
         ('toReview',       N'Candidates awaiting my review', (SELECT COUNT(*) FROM staff.SubmittedCandidates WHERE CustomerId = @cust AND Status = 'Submitted'), 'count'),
         ('interviews',     N'Upcoming interviews',      (SELECT COUNT(*) FROM cand.Interviews WHERE CustomerId = @cust AND Status IN ('Scheduled','Rescheduled') AND StartsAt >= @now), 'count'),
         ('contractors',    N'Contractors on assignment', (SELECT COUNT(DISTINCT ContractorId) FROM staff.Assignments WHERE CustomerId = @cust AND Status = 'Active'), 'count'),
         ('timesheets',     N'Timesheets to approve',    (SELECT COUNT(*) FROM [time].Timesheets WHERE CustomerId = @cust AND Status = 'Submitted'), 'count'),
         ('outstanding',    N'Outstanding balance',      bill.fn_CustomerOutstandingBalance(@cust), 'currency'),
         ('overdue',        N'Overdue invoices',         (SELECT COUNT(*) FROM report.vw_CustomerInvoices WHERE CustomerId = @cust AND DaysOverdue > 0), 'count');
    END
    ELSE IF @Role = N'Recruiter'
    BEGIN
        INSERT @m (MetricKey, Label, Value, Unit) VALUES
         ('openJobs',       N'My open jobs',             (SELECT COUNT(*) FROM rec.JobRequisitions WHERE OwnerRecruiterUserId = @ActorUserId AND Status = 'Open'), 'count'),
         ('approvedToJob',  N'Approved hiring requests without a job', (SELECT COUNT(*) FROM hr.EmployeeRequisitions r WHERE r.Status = 'Approved' AND NOT EXISTS (SELECT 1 FROM rec.JobRequisitions j WHERE j.EmployeeRequisitionId = r.EmployeeRequisitionId AND j.Status NOT IN ('Closed','Expired'))), 'count'),
         ('applicants',     N'Active applicants on my jobs', (SELECT COUNT(*) FROM cand.JobApplications a JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
                                                              WHERE jr.OwnerRecruiterUserId = @ActorUserId AND a.Status NOT IN ('Hired','Rejected','Withdrawn')), 'count'),
         ('interviews7',    N'Interviews in the next 7 days', (SELECT COUNT(*) FROM cand.Interviews i WHERE cand.fn_CanSeeInterview(@ActorUserId, i.InterviewId) = 1 AND i.Status IN ('Scheduled','Rescheduled') AND i.StartsAt BETWEEN @now AND DATEADD(DAY, 7, @now)), 'count'),
         ('offers',         N'My offers not yet answered', (SELECT COUNT(*) FROM cand.JobOffers WHERE CreatedByUserId = @ActorUserId AND Status IN ('PendingApproval','Approved','Sent')), 'count'),
         ('staffingReq',    N'Staffing requests assigned to me', (SELECT COUNT(*) FROM staff.CustomerRequisitions WHERE AssignedRecruiterUserId = @ActorUserId AND Status IN ('InReview','Sourcing')), 'count'),
         ('unassigned',     N'Staffing requests waiting for a recruiter', (SELECT COUNT(*) FROM staff.CustomerRequisitions WHERE AssignedRecruiterUserId IS NULL AND Status = 'Open'), 'count'),
         ('expiring',       N'Contracts expiring within 30 days', (SELECT COUNT(*) FROM report.vw_ExpiringContracts), 'count'),
         ('toInvoice',      N'Approved timesheets not yet invoiced', (SELECT COUNT(*) FROM [time].Timesheets t WHERE t.Status = 'Approved' AND NOT EXISTS (SELECT 1 FROM [time].TimesheetEntries e JOIN bill.InvoiceLines l ON l.TimesheetEntryId = e.EntryId WHERE e.TimesheetId = t.TimesheetId)), 'count');
    END
    ELSE IF @Role = N'HRManager'
    BEGIN
        INSERT @m (MetricKey, Label, Value, Unit) VALUES
         ('pendingRequests', N'Hiring requests awaiting approval', (SELECT COUNT(*) FROM hr.EmployeeRequisitions WHERE Status = 'Submitted' AND RequestedByUserId <> @ActorUserId), 'count'),
         ('jobApprovals',   N'Jobs awaiting content sign-off', (SELECT COUNT(*) FROM rec.JobRequisitions WHERE Status = 'PendingApproval' AND ISNULL(CreatedByUserId, 0) <> @ActorUserId), 'count'),
         ('offerApprovals', N'Offers awaiting approval',  (SELECT COUNT(*) FROM cand.JobOffers WHERE Status = 'PendingApproval' AND CreatedByUserId <> @ActorUserId), 'count'),
         ('onboardingOpen', N'Open onboarding tasks',     (SELECT COUNT(*) FROM hr.EmployeeOnboarding WHERE Status IN ('Pending','InProgress')), 'count'),
         ('onboarding',     N'Employees onboarding',      (SELECT COUNT(*) FROM hr.Employees WHERE Status = 'Onboarding'), 'count'),
         ('employees',      N'Headcount (incl. onboarding)', (SELECT COUNT(*) FROM hr.Employees WHERE Status IN ('Onboarding','Active','OnLeave')), 'count'),
         ('hiresQuarter',   N'Hires this quarter',        (SELECT COUNT(*) FROM hr.Employees WHERE StartDate >= DATEADD(QUARTER, DATEDIFF(QUARTER, 0, @today), 0)), 'count'),
         ('openJobs',       N'Open jobs',                 (SELECT COUNT(*) FROM rec.JobRequisitions WHERE Status = 'Open'), 'count');
    END
    ELSE  -- Administrator
    BEGIN
        INSERT @m (MetricKey, Label, Value, Unit) VALUES
         ('users',          N'Users',                    (SELECT COUNT(*) FROM sec.Users), 'count'),
         ('activeUsers',    N'Active users',             (SELECT COUNT(*) FROM sec.Users WHERE IsActive = 1), 'count'),
         ('lockedUsers',    N'Locked accounts',          (SELECT COUNT(*) FROM sec.Users WHERE LockoutUntil > @now), 'count'),
         ('customers',      N'Customers',                (SELECT COUNT(*) FROM org.Customers WHERE Status = 'Active'), 'count'),
         ('failedLogins24', N'Failed logins (24 h)',     (SELECT COUNT(*) FROM audit.LoginHistory WHERE Success = 0 AND AttemptedAt >= DATEADD(HOUR, -24, @now)), 'count'),
         ('audit24',        N'Audited changes (24 h)',   (SELECT COUNT(*) FROM audit.AuditLogs WHERE ChangedAt >= DATEADD(HOUR, -24, @now) AND TableName NOT LIKE N'(DDL)%'), 'count'),
         ('queuePending',   N'Notifications waiting to be sent', (SELECT COUNT(*) FROM notify.NotificationQueue WHERE Status IN ('Pending','Processing')), 'count'),
         ('queueFailed',    N'Notifications failed',     (SELECT COUNT(*) FROM notify.NotificationQueue WHERE Status = 'Failed'), 'count'),
         ('jobsFailed7',    N'Scheduled-job failures (7 days)', (SELECT COUNT(*) FROM sched.JobExecutionHistory WHERE Outcome = 'Failed' AND StartedAt >= DATEADD(DAY, -7, @now)), 'count'),
         ('outstanding',    N'Total outstanding receivables', (SELECT ISNULL(SUM(Balance), 0) FROM report.vw_CustomerInvoices WHERE Status IN ('Issued','PartiallyPaid')), 'currency');
    END
    SELECT MetricKey, Label, Value, Unit FROM @m ORDER BY Ord;
END
GO
