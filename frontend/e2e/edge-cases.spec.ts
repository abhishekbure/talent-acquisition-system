import { expect, test } from '@playwright/test';
import { USERS, day, deliverMail, dialog, fill, latestMail, num, open, row, rowAction, runTask, scalar, signIn, sql, submit, submitRefused, toast } from './support';

/** Phase 14 edge cases, each through the browser against the real API and database. */

test('offer rejection: HR rejects an offer (reason required); a candidate declines a sent offer', async ({ browser }) => {
  // HR rejects the pending offer (a reason is required); the recruiter can no longer send it
  const anita = await signIn(browser, USERS.anita);
  await open(anita, 'hr', 'Offer approvals');
  await rowAction(anita, 'OFR-2026-003', 'Reject');
  const d = dialog(anita, 'Reject offer OFR-2026-003');
  await submitRefused(d, 'Reject', 'Please correct the highlighted fields.');
  await fill(d, 'comments', 'Salary above the approved band');
  await submit(d, 'Reject');
  await toast(anita, 'Offer rejected.');
  await expect(row(anita, 'OFR-2026-003')).toContainText('Rejected');
  expect(scalar(`SELECT Status FROM cand.JobOffers WHERE OfferNo = 'OFR-2026-003'`)).toBe('Rejected');
  expect(scalar(`SELECT TOP 1 Decision FROM cand.OfferApprovals oa JOIN cand.JobOffers o ON o.OfferId = oa.OfferId WHERE o.OfferNo = 'OFR-2026-003' ORDER BY oa.OfferApprovalId DESC`)).toBe('Rejected');

  // the candidate declines the sent offer: the offer is Declined, the application Rejected, no employee is created
  sql(`UPDATE cand.JobOffers SET ExpiresAt = DATEADD(DAY, 5, SYSUTCDATETIME()) WHERE OfferNo = 'OFR-2026-002' AND Status = 'Sent'`);   // keep the seeded offer open whatever today is
  const karan = await signIn(browser, USERS.karan);
  await open(karan, 'candidate', 'Offers');
  await rowAction(karan, 'OFR-2026-002', 'Decline');
  await fill(dialog(karan, 'Decline offer OFR-2026-002'), 'note', 'Accepted another offer');
  await submit(dialog(karan, 'Decline offer OFR-2026-002'), 'Decline offer');
  await toast(karan, 'Offer declined.');
  await expect(row(karan, 'OFR-2026-002')).toContainText('Declined');
  await expect(row(karan, 'OFR-2026-002').getByRole('button')).toHaveCount(0);       // an offer is answered once
  expect(scalar(`SELECT a.Status FROM cand.JobApplications a JOIN cand.JobOffers o ON o.ApplicationId = a.ApplicationId WHERE o.OfferNo = 'OFR-2026-002'`)).toBe('Rejected');
  expect(num(`SELECT COUNT(*) FROM hr.Employees e JOIN cand.JobOffers o ON o.OfferId = e.JobOfferId WHERE o.OfferNo = 'OFR-2026-002'`)).toBe(0);
});

test('contract expiry: SQL Agent flags it, the console app tells everyone, the customer sees it, the recruiter renews it', async ({ browser }) => {
  // Brightwave's contract now ends in 10 days (arranged), then the nightly Agent job runs (the procedure its step runs)
  sql(`UPDATE staff.Contracts SET EndDate = DATEADD(DAY, 10, CAST(SYSUTCDATETIME() AS DATE)), Status = 'Active' WHERE ContractNo = 'CON-2026-002'`);
  sql(`EXEC sched.usp_Job_DetectContractExpiry`);
  expect(scalar(`SELECT Status FROM staff.Contracts WHERE ContractNo = 'CON-2026-002'`)).toBe('Expiring');

  // the Task Scheduler task announces it to the contractor, the recruiter and the customer; the sender delivers the e-mail
  const r = runTask('contract-expiry-notices');
  expect(r.code, r.out).toBe(0);
  deliverMail();
  for (const who of [USERS.sneha, USERS.meera]) expect(latestMail(who, 'CONTRACT_EXPIRING')?.subject, who).toContain('CON-2026-002');

  // the customer sees the contract as expiring, with the days left
  const meera = await signIn(browser, USERS.meera);
  await open(meera, 'customer', 'Contracts');
  await expect(row(meera, 'CON-2026-002')).toContainText('Expiring');
  await expect(row(meera, 'CON-2026-002')).toContainText('10');

  // the recruiter renews it for six months: Active again, the extension is recorded
  const rahul = await signIn(browser, USERS.rahul);
  await open(rahul, 'recruiter', 'Contracts');
  await row(rahul, 'CON-2026-002').click();
  await rahul.getByRole('button', { name: 'Renew / extend' }).click();
  const d = dialog(rahul, 'Renew CON-2026-002');
  await fill(d, 'newEndDate', day(190));
  await fill(d, 'reason', 'Project extended');
  await submit(d, 'Renew');
  await toast(rahul, 'Contract renewed.');
  await expect(row(rahul, 'CON-2026-002')).toContainText('Active');
  expect(num(`SELECT COUNT(*) FROM staff.ContractExtensions x JOIN staff.Contracts c ON c.ContractId = x.ContractId WHERE c.ContractNo = 'CON-2026-002' AND x.Reason = N'Project extended'`)).toBe(1);
});

test('scheduler failure recovery: a failed run is reported and recovers; an abandoned run is cleared', async ({ browser }) => {
  // the daily report cannot be sent while SQL Agent's summary for yesterday is missing: the task fails (exit 1)
  sql(`DELETE FROM report.DailyRecruitmentSummary WHERE SummaryDate = DATEADD(DAY, -1, dbo.fn_BusinessToday())`);
  const failed = runTask('daily-report');
  expect(failed.code, failed.out).toBe(1);

  // the administrator sees the failed run with its reason, and has been notified
  const admin = await signIn(browser, USERS.admin);
  await open(admin, 'admin', 'Scheduled jobs');
  await row(admin, 'Daily report delivery').click();
  const runs = admin.locator('section.card');
  await expect(row(runs, 'Failed')).toContainText('Prepare daily recruitment summary');
  await admin.getByRole('link', { name: /Notifications/ }).click();
  await expect(admin.locator('main')).toContainText('Daily report delivery');

  // recovery: the Agent job's procedure is run for the missing day (its nightly 23:30 run covers that day; this is the catch-up)
  sql(`DECLARE @d DATE = DATEADD(DAY, -1, dbo.fn_BusinessToday()); EXEC sched.usp_Job_DailyRecruitmentSummary @SummaryDate = @d`);
  const ok = runTask('daily-report');
  expect(ok.code, ok.out).toBe(0);
  await open(admin, 'admin', 'Scheduled jobs');
  await row(admin, 'Daily report delivery').click();
  await expect(admin.locator('section.card table.grid tbody tr').first()).toContainText('Succeeded');

  // a run that crashed on another machine (no report back for over an hour) does not block the job forever
  sql(`INSERT sched.JobExecutionHistory (JobDefinitionId, HostName, StartedAt)
       SELECT JobDefinitionId, 'CRASHED-PC', DATEADD(HOUR, -2, SYSUTCDATETIME()) FROM sched.JobDefinitions WHERE JobName = N'Offer expiry reminders'`);
  const after = runTask('offer-reminders');
  expect(after.code, after.out).toBe(0);
  expect(scalar(`SELECT Outcome FROM sched.JobExecutionHistory WHERE HostName = 'CRASHED-PC'`)).toBe('Failed');
  expect(scalar(`SELECT ErrorMessage FROM sched.JobExecutionHistory WHERE HostName = 'CRASHED-PC'`)).toContain('Abandoned');
  await open(admin, 'admin', 'Scheduled jobs');
  await row(admin, 'Offer expiry reminders').click();
  await expect(admin.locator('section.card table.grid tbody tr').first()).toContainText('Succeeded');
  await expect(row(admin.locator('section.card'), 'CRASHED-PC')).toContainText('Failed');
});
