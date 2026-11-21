/* ============================================================================
   TAMS - 09_Views / 01_Views.sql
   Reporting / dashboard views (schema report). Customer-facing views carry CustomerId so
   the stored procedures can filter; PAY RATES are never exposed by any view.
   ========================================================================== */
USE TalentAcquisitionDB;
GO

CREATE OR ALTER VIEW report.vw_OpenRequisitions AS
SELECT jr.JobRequisitionId, jr.JobCode, jr.Title, d.Name AS Department, l.Name AS Location, jr.Openings, jr.Status,
       u.DisplayName AS OwnerRecruiter, jr.OwnerRecruiterUserId, jr.OpenedAt, jr.ClosesBy,
       DATEDIFF(DAY, jr.OpenedAt, SYSUTCDATETIME()) AS DaysOpen,
       (SELECT COUNT(*) FROM cand.JobApplications a JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId
         WHERE p.JobRequisitionId = jr.JobRequisitionId) AS ApplicationCount,
       (SELECT COUNT(*) FROM cand.JobApplications a JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId
         WHERE p.JobRequisitionId = jr.JobRequisitionId AND a.Status = 'Hired') AS HiredCount
FROM rec.JobRequisitions jr
JOIN org.Departments d ON d.DepartmentId = jr.DepartmentId
LEFT JOIN org.Locations l ON l.LocationId = jr.LocationId
JOIN sec.Users u ON u.UserId = jr.OwnerRecruiterUserId
WHERE jr.Status = 'Open';
GO

CREATE OR ALTER VIEW report.vw_RecruitmentPipeline AS
SELECT jr.JobRequisitionId, jr.JobCode, jr.Title, jr.Status AS JobStatus, jr.OwnerRecruiterUserId,
       COUNT(a.ApplicationId) AS Total,
       SUM(CASE WHEN a.Status = 'Applied'     THEN 1 ELSE 0 END) AS Applied,
       SUM(CASE WHEN a.Status = 'Screening'   THEN 1 ELSE 0 END) AS Screening,
       SUM(CASE WHEN a.Status = 'Shortlisted' THEN 1 ELSE 0 END) AS Shortlisted,
       SUM(CASE WHEN a.Status = 'Interview'   THEN 1 ELSE 0 END) AS Interview,
       SUM(CASE WHEN a.Status = 'Selected'    THEN 1 ELSE 0 END) AS Selected,
       SUM(CASE WHEN a.Status = 'OfferStage'  THEN 1 ELSE 0 END) AS OfferStage,
       SUM(CASE WHEN a.Status = 'Hired'       THEN 1 ELSE 0 END) AS Hired,
       SUM(CASE WHEN a.Status = 'Rejected'    THEN 1 ELSE 0 END) AS Rejected,
       SUM(CASE WHEN a.Status = 'Withdrawn'   THEN 1 ELSE 0 END) AS Withdrawn
FROM rec.JobRequisitions jr
LEFT JOIN rec.JobPostings p ON p.JobRequisitionId = jr.JobRequisitionId
LEFT JOIN cand.JobApplications a ON a.JobPostingId = p.JobPostingId
GROUP BY jr.JobRequisitionId, jr.JobCode, jr.Title, jr.Status, jr.OwnerRecruiterUserId;
GO

CREATE OR ALTER VIEW report.vw_CandidateApplicationStatus AS
SELECT a.ApplicationId, a.CandidateId, c.FirstName + N' ' + c.LastName AS CandidateName, c.Email,
       jr.JobCode, jr.Title AS JobTitle, d.Name AS Department, a.Status, a.AppliedAt,
       lh.ChangedAt AS LastStatusChangeAt,
       DATEDIFF(DAY, a.AppliedAt, CASE WHEN a.Status IN ('Hired','Rejected','Withdrawn') THEN ISNULL(lh.ChangedAt, SYSUTCDATETIME()) ELSE SYSUTCDATETIME() END) AS AgeDays,
       (SELECT MIN(i.StartsAt) FROM cand.Interviews i
         WHERE i.JobApplicationId = a.ApplicationId AND i.Status IN ('Scheduled','Rescheduled') AND i.StartsAt >= SYSUTCDATETIME()) AS NextInterviewAt
FROM cand.JobApplications a
JOIN cand.Candidates c ON c.CandidateId = a.CandidateId
JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId
JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
JOIN org.Departments d ON d.DepartmentId = jr.DepartmentId
OUTER APPLY (SELECT TOP (1) h.ChangedAt FROM cand.ApplicationStatusHistory h
             WHERE h.ApplicationId = a.ApplicationId ORDER BY h.ChangedAt DESC, h.HistoryId DESC) lh;
GO

CREATE OR ALTER VIEW report.vw_UpcomingInterviews AS
SELECT i.InterviewId, i.StartsAt, i.EndsAt, i.RoundNo, i.InterviewType, i.Mode, i.LocationOrLink, i.Status, i.CustomerId,
       CASE WHEN i.JobApplicationId IS NOT NULL THEN 'Internal' ELSE 'External' END AS Opportunity,
       c.CandidateId, c.FirstName + N' ' + c.LastName AS CandidateName,
       COALESCE(jr.Title, cr.Title) AS RoleTitle, cu.Name AS CustomerName,
       STUFF((SELECT N', ' + u.DisplayName FROM cand.InterviewPanels ip JOIN sec.Users u ON u.UserId = ip.UserId
              WHERE ip.InterviewId = i.InterviewId ORDER BY ip.IsLead DESC, u.DisplayName FOR XML PATH(N'')), 1, 2, N'') AS Panel
FROM cand.Interviews i
LEFT JOIN cand.JobApplications a ON a.ApplicationId = i.JobApplicationId
LEFT JOIN rec.JobPostings p ON p.JobPostingId = a.JobPostingId
LEFT JOIN rec.JobRequisitions jr ON jr.JobRequisitionId = p.JobRequisitionId
LEFT JOIN staff.SubmittedCandidates s ON s.SubmissionId = i.SubmittedCandidateId
LEFT JOIN staff.CustomerRequisitions cr ON cr.CustomerRequisitionId = s.CustomerRequisitionId
LEFT JOIN org.Customers cu ON cu.CustomerId = i.CustomerId
JOIN cand.Candidates c ON c.CandidateId = COALESCE(a.CandidateId, s.CandidateId)
WHERE i.Status IN ('Scheduled', 'Rescheduled') AND i.StartsAt >= SYSUTCDATETIME();
GO

CREATE OR ALTER VIEW report.vw_PendingOffers AS
SELECT o.OfferId, o.OfferNo, o.ApplicationId, a.CandidateId, c.FirstName + N' ' + c.LastName AS CandidateName,
       o.Designation, o.OfferedSalary, o.Currency, o.StartDate, o.Status, o.ExpiresAt,
       DATEDIFF(DAY, SYSUTCDATETIME(), o.ExpiresAt) AS DaysToExpiry, u.DisplayName AS CreatedBy, o.CreatedByUserId
FROM cand.JobOffers o
JOIN cand.JobApplications a ON a.ApplicationId = o.ApplicationId
JOIN cand.Candidates c ON c.CandidateId = a.CandidateId
JOIN sec.Users u ON u.UserId = o.CreatedByUserId
WHERE o.Status IN ('PendingApproval', 'Approved', 'Sent');
GO

CREATE OR ALTER VIEW report.vw_ActiveEmployees AS
SELECT e.EmployeeId, e.EmployeeNo, e.CandidateId, c.FirstName + N' ' + c.LastName AS EmployeeName, c.Email,
       d.Name AS Department, l.Name AS Location, e.JobTitle, e.StartDate, e.Status, m.DisplayName AS Manager,
       (SELECT COUNT(*) FROM hr.EmployeeOnboarding o WHERE o.EmployeeId = e.EmployeeId AND o.Status IN ('Completed','Waived')) AS OnboardingDone,
       (SELECT COUNT(*) FROM hr.EmployeeOnboarding o WHERE o.EmployeeId = e.EmployeeId) AS OnboardingTotal
FROM hr.Employees e
JOIN cand.Candidates c ON c.CandidateId = e.CandidateId
JOIN org.Departments d ON d.DepartmentId = e.DepartmentId
LEFT JOIN org.Locations l ON l.LocationId = e.LocationId
LEFT JOIN sec.Users m ON m.UserId = e.ManagerUserId
WHERE e.Status IN ('Onboarding', 'Active', 'OnLeave');
GO

-- BillRate is shown (customer price); PayRate is deliberately NOT exposed.
CREATE OR ALTER VIEW report.vw_ActiveContractors AS
SELECT k.ContractorId, k.ContractorNo, c.FirstName + N' ' + c.LastName AS ContractorName, c.Email, k.Status,
       a.AssignmentId, a.RoleTitle, a.CustomerId, cu.Name AS CustomerName,
       ct.ContractId, ct.ContractNo, ct.StartDate, ct.EndDate, ct.Status AS ContractStatus, r.BillRate, r.Currency
FROM staff.Contractors k
JOIN cand.Candidates c ON c.CandidateId = k.CandidateId
LEFT JOIN staff.Assignments a ON a.ContractorId = k.ContractorId AND a.Status = 'Active'
LEFT JOIN staff.Contracts ct ON ct.ContractId = a.ContractId
LEFT JOIN org.Customers cu ON cu.CustomerId = a.CustomerId
OUTER APPLY (SELECT TOP (1) cr.BillRate, cr.Currency FROM staff.ContractRates cr
             WHERE cr.ContractId = ct.ContractId AND cr.EffectiveFrom <= CAST(SYSUTCDATETIME() AS DATE)
               AND (cr.EffectiveTo IS NULL OR cr.EffectiveTo >= CAST(SYSUTCDATETIME() AS DATE))
             ORDER BY cr.EffectiveFrom DESC) r
WHERE k.Status = 'Active';
GO

CREATE OR ALTER VIEW report.vw_ExpiringContracts AS
SELECT ct.ContractId, ct.ContractNo, ct.CustomerId, cu.Name AS CustomerName, k.ContractorId, k.ContractorNo,
       c.FirstName + N' ' + c.LastName AS ContractorName, ct.StartDate, ct.EndDate, ct.Status,
       DATEDIFF(DAY, CAST(SYSUTCDATETIME() AS DATE), ct.EndDate) AS DaysToExpiry
FROM staff.Contracts ct
JOIN staff.Placements pl ON pl.PlacementId = ct.PlacementId
JOIN staff.Contractors k ON k.ContractorId = pl.ContractorId
JOIN cand.Candidates c ON c.CandidateId = k.CandidateId
JOIN org.Customers cu ON cu.CustomerId = ct.CustomerId
WHERE ct.Status IN ('Active', 'Expiring') AND ct.EndDate <= DATEADD(DAY, 30, CAST(SYSUTCDATETIME() AS DATE));
GO

CREATE OR ALTER VIEW report.vw_PendingTimesheets AS
SELECT t.TimesheetId, t.CustomerId, cu.Name AS CustomerName, t.ContractorId, k.ContractorNo,
       c.FirstName + N' ' + c.LastName AS ContractorName, a.RoleTitle, t.WeekStartDate, t.TotalHours, t.SubmittedAt,
       DATEDIFF(DAY, t.SubmittedAt, SYSUTCDATETIME()) AS DaysWaiting
FROM [time].Timesheets t
JOIN staff.Assignments a ON a.AssignmentId = t.AssignmentId
JOIN staff.Contractors k ON k.ContractorId = t.ContractorId
JOIN cand.Candidates c ON c.CandidateId = k.CandidateId
JOIN org.Customers cu ON cu.CustomerId = t.CustomerId
WHERE t.Status = 'Submitted';
GO

CREATE OR ALTER VIEW report.vw_CustomerInvoices AS
SELECT i.InvoiceId, i.InvoiceNo, i.CustomerId, cu.Name AS CustomerName, i.PeriodStart, i.PeriodEnd, i.IssueDate, i.DueDate,
       i.Status, i.Currency, i.Subtotal, i.TaxAmount, i.Total, ISNULL(p.Paid, 0) AS AmountPaid,
       CASE WHEN i.Status = 'Void' THEN 0 ELSE i.Total - ISNULL(p.Paid, 0) END AS Balance,
       CASE WHEN i.Status IN ('Issued', 'PartiallyPaid') AND i.DueDate < CAST(SYSUTCDATETIME() AS DATE)
            THEN DATEDIFF(DAY, i.DueDate, CAST(SYSUTCDATETIME() AS DATE)) ELSE 0 END AS DaysOverdue
FROM bill.Invoices i
JOIN org.Customers cu ON cu.CustomerId = i.CustomerId
LEFT JOIN (SELECT InvoiceId, SUM(Amount) AS Paid FROM bill.Payments GROUP BY InvoiceId) p ON p.InvoiceId = i.InvoiceId;
GO

CREATE OR ALTER VIEW report.vw_RecruitmentPerformance AS
SELECT u.UserId AS RecruiterUserId, u.DisplayName AS Recruiter,
       (SELECT COUNT(*) FROM rec.JobRequisitions jr WHERE jr.OwnerRecruiterUserId = u.UserId) AS JobsOwned,
       x.Applications, x.Hires,
       (SELECT COUNT(*) FROM cand.JobOffers o WHERE o.CreatedByUserId = u.UserId) AS OffersCreated,
       (SELECT COUNT(*) FROM cand.JobOffers o WHERE o.CreatedByUserId = u.UserId AND o.Status = 'Accepted') AS OffersAccepted,
       x.AvgDaysToHire,
       (SELECT COUNT(*) FROM staff.SubmittedCandidates s WHERE s.SubmittedByUserId = u.UserId) AS StaffingSubmissions,
       (SELECT COUNT(*) FROM staff.Placements p WHERE p.CreatedByUserId = u.UserId) AS Placements
FROM sec.Users u
JOIN sec.UserRoles ur ON ur.UserId = u.UserId
JOIN sec.Roles r ON r.RoleId = ur.RoleId AND r.RoleName = N'Recruiter'
OUTER APPLY (SELECT COUNT(a.ApplicationId) AS Applications,
                    SUM(CASE WHEN a.Status = 'Hired' THEN 1 ELSE 0 END) AS Hires,
                    AVG(CASE WHEN a.Status = 'Hired' THEN CAST(cand.fn_TimeToHireDays(a.ApplicationId) AS FLOAT) END) AS AvgDaysToHire
             FROM rec.JobRequisitions jr
             JOIN rec.JobPostings p ON p.JobRequisitionId = jr.JobRequisitionId
             JOIN cand.JobApplications a ON a.JobPostingId = p.JobPostingId
             WHERE jr.OwnerRecruiterUserId = u.UserId) x;
GO
