/* ============================================================================
   TAMS - 10_SeedData / 01_Reference_Data.sql
   Roles, permissions, role->permission grants, recruitment sources, job definitions.
   Reference data is required for the app to work (not just demo data). Repeatable
   (inserts only rows that do not yet exist).
   ========================================================================== */
USE TalentAcquisitionDB;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRAN;

-- Roles (exactly the six required roles)
INSERT sec.Roles (RoleName, Description)
SELECT v.RoleName, v.Description FROM (VALUES
 (N'Candidate',     N'Job seeker: profile, applications, interviews, offers'),
 (N'Contractor',    N'Placed contractor: assignments, timesheets, compliance'),
 (N'Customer',      N'Staffing customer: requests, submissions, timesheet approval, invoices'),
 (N'Recruiter',     N'Internal recruiter: jobs, pipeline, sourcing, submissions, contracts, billing'),
 (N'HRManager',     N'HR / hiring manager: hiring requests, approvals, employees, onboarding'),
 (N'Administrator', N'System administrator: users, customers, audit, scheduler, rate cards')
) v(RoleName, Description)
WHERE NOT EXISTS (SELECT 1 FROM sec.Roles r WHERE r.RoleName = v.RoleName);

-- Permissions
INSERT sec.Permissions (Code, Description)
SELECT v.Code, v.Description FROM (VALUES
 (N'candidate.profile.manage', N'Maintain own candidate profile'),
 (N'candidate.search',         N'Search the shared candidate master'),
 (N'job.browse',               N'Browse published jobs'),
 (N'application.create',       N'Apply to a job'),
 (N'application.review',       N'Review applications and change status'),
 (N'requisition.create',       N'Create department hiring requests'),
 (N'requisition.approve',      N'Approve or reject hiring requests and job content'),
 (N'job.manage',               N'Create and publish jobs'),
 (N'interview.schedule',       N'Schedule and reschedule interviews'),
 (N'interview.feedback',       N'Submit interview feedback'),
 (N'offer.create',             N'Create and send job offers'),
 (N'offer.approve',            N'Approve job offers'),
 (N'offer.respond',            N'Accept or decline own offer'),
 (N'employee.manage',          N'Manage employees and onboarding'),
 (N'staffing.request.create',  N'Create customer staffing requests'),
 (N'staffing.request.manage',  N'Review and assign staffing requests'),
 (N'staffing.submit',          N'Submit candidates to customers'),
 (N'staffing.decide',          N'Shortlist, reject or select submitted candidates'),
 (N'contractor.manage',        N'Create contractors, contracts, placements, assignments'),
 (N'timesheet.submit',         N'Enter and submit own timesheets'),
 (N'timesheet.approve',        N'Approve or reject customer timesheets'),
 (N'invoice.generate',         N'Generate invoices'),
 (N'invoice.view',             N'View invoices for own customer'),
 (N'payment.record',           N'Record payments'),
 (N'report.view',              N'View reports'),
 (N'document.upload',          N'Upload documents'),
 (N'document.download',        N'Download authorised documents'),
 (N'user.manage',              N'Manage users and roles'),
 (N'customer.manage',          N'Manage customers and rate cards'),
 (N'audit.view',               N'View audit and login history'),
 (N'scheduler.view',           N'View scheduled job status')
) v(Code, Description)
WHERE NOT EXISTS (SELECT 1 FROM sec.Permissions p WHERE p.Code = v.Code);

-- Role -> permission grants
INSERT sec.RolePermissions (RoleId, PermissionId)
SELECT r.RoleId, p.PermissionId
FROM (VALUES
 (N'Candidate',  N'candidate.profile.manage'),(N'Candidate',N'job.browse'),(N'Candidate',N'application.create'),
 (N'Candidate',  N'offer.respond'),(N'Candidate',N'document.upload'),(N'Candidate',N'document.download'),
 (N'Contractor', N'timesheet.submit'),(N'Contractor',N'document.upload'),(N'Contractor',N'document.download'),
 (N'Customer',   N'staffing.request.create'),(N'Customer',N'staffing.decide'),(N'Customer',N'interview.schedule'),
 (N'Customer',   N'interview.feedback'),(N'Customer',N'timesheet.approve'),(N'Customer',N'invoice.view'),
 (N'Customer',   N'report.view'),(N'Customer',N'document.download'),
 (N'Recruiter',  N'candidate.search'),(N'Recruiter',N'application.review'),(N'Recruiter',N'job.manage'),
 (N'Recruiter',  N'interview.schedule'),(N'Recruiter',N'interview.feedback'),(N'Recruiter',N'offer.create'),
 (N'Recruiter',  N'staffing.request.create'),(N'Recruiter',N'staffing.request.manage'),(N'Recruiter',N'staffing.submit'),
 (N'Recruiter',  N'contractor.manage'),(N'Recruiter',N'invoice.generate'),(N'Recruiter',N'payment.record'),
 (N'Recruiter',  N'report.view'),(N'Recruiter',N'document.upload'),(N'Recruiter',N'document.download'),
 (N'HRManager',  N'candidate.search'),(N'HRManager',N'requisition.create'),(N'HRManager',N'requisition.approve'),
 (N'HRManager',  N'job.manage'),(N'HRManager',N'interview.schedule'),(N'HRManager',N'interview.feedback'),
 (N'HRManager',  N'offer.create'),(N'HRManager',N'offer.approve'),(N'HRManager',N'employee.manage'),
 (N'HRManager',  N'report.view'),(N'HRManager',N'document.upload'),(N'HRManager',N'document.download'),
 (N'Administrator', N'candidate.search'),(N'Administrator',N'requisition.create'),(N'Administrator',N'requisition.approve'),
 (N'Administrator', N'job.manage'),(N'Administrator',N'application.review'),(N'Administrator',N'interview.schedule'),
 (N'Administrator', N'offer.create'),(N'Administrator',N'offer.approve'),(N'Administrator',N'employee.manage'),
 (N'Administrator', N'staffing.request.create'),(N'Administrator',N'staffing.request.manage'),(N'Administrator',N'staffing.submit'),
 (N'Administrator', N'contractor.manage'),(N'Administrator',N'invoice.generate'),(N'Administrator',N'invoice.view'),
 (N'Administrator', N'payment.record'),(N'Administrator',N'report.view'),(N'Administrator',N'document.upload'),
 (N'Administrator', N'document.download'),(N'Administrator',N'user.manage'),(N'Administrator',N'customer.manage'),
 (N'Administrator', N'audit.view'),(N'Administrator',N'scheduler.view')
) g(RoleName, Code)
JOIN sec.Roles r ON r.RoleName = g.RoleName
JOIN sec.Permissions p ON p.Code = g.Code
WHERE NOT EXISTS (SELECT 1 FROM sec.RolePermissions rp WHERE rp.RoleId = r.RoleId AND rp.PermissionId = p.PermissionId);

-- Recruitment sources
INSERT rec.RecruitmentSources (Name, SourceType)
SELECT v.Name, v.SourceType FROM (VALUES
 (N'Careers Portal',    'Portal'),
 (N'Naukri',            'Portal'),
 (N'LinkedIn',          'SocialMedia'),
 (N'Employee Referral', 'Referral'),
 (N'Staffing Agency',   'Agency'),
 (N'Campus Drive',      'Event'),
 (N'Direct Outreach',   'Direct')
) v(Name, SourceType)
WHERE NOT EXISTS (SELECT 1 FROM rec.RecruitmentSources s WHERE s.Name = v.Name);

-- Job definitions: who owns which scheduled task (no overlap between SQL Agent and Task Scheduler)
INSERT sched.JobDefinitions (JobName, Owner, Description, ScheduleDescription)
SELECT v.JobName, v.Owner, v.Description, v.Sched FROM (VALUES
 (N'TAMS - Expire stale requisitions',        'SqlAgent',      N'Close job requisitions past their ClosesBy date',          N'Daily 01:00'),
 (N'TAMS - Detect contract expiry',           'SqlAgent',      N'Flag contracts expiring within 30 days / expired',         N'Daily 01:15'),
 (N'TAMS - Purge notification queue',         'SqlAgent',      N'Remove sent notifications older than 90 days',             N'Weekly Sun 02:00'),
 (N'TAMS - Prepare daily recruitment summary','SqlAgent',      N'Populate report.DailyRecruitmentSummary',                  N'Daily 23:30'),
 (N'TAMS - Full database backup',             'SqlAgent',      N'Full backup of TalentAcquisitionDB',                       N'Weekly Sun 03:00'),
 (N'TAMS - Index maintenance',                'SqlAgent',      N'Reorganise/rebuild fragmented indexes',                    N'Weekly Sun 03:30'),
 (N'TAMS - Update statistics',                'SqlAgent',      N'sp_updatestats',                                           N'Daily 02:30'),
 (N'Interview reminders',                     'TaskScheduler', N'Queue reminders for interviews in next 24 hours',          N'Hourly'),
 (N'Offer expiry reminders',                  'TaskScheduler', N'Queue reminders for offers expiring within 2 days',        N'Daily 08:00'),
 (N'Timesheet reminders',                     'TaskScheduler', N'Remind contractors with missing/unsubmitted timesheets',   N'Weekly Fri 15:00'),
 (N'Contract expiry notifications',           'TaskScheduler', N'Queue notifications for contracts flagged as expiring',    N'Daily 08:30'),
 (N'Email queue processing',                  'TaskScheduler', N'Send pending notifications via the mock email provider',   N'Every 5 minutes'),
 (N'Daily report delivery',                   'TaskScheduler', N'Email the daily recruitment summary to recruiters/HR',     N'Daily 07:30')
) v(JobName, Owner, Description, Sched)
WHERE NOT EXISTS (SELECT 1 FROM sched.JobDefinitions j WHERE j.JobName = v.JobName);

COMMIT;
PRINT 'Reference data seeded.';
GO
