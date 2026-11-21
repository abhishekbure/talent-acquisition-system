import { expect, test } from '@playwright/test';
import {
  USERS, deliverMail, dialog, fill, latestMail, localDateTime, num, open, row, rowAction, scalar, signIn, sql, sqlText, submit,
  submitRefused, testPassword, tick, toast, unique, day
} from './support';

/**
 * Business model 1 — internal recruitment, end to end through the browser:
 * hiring request -> approval -> job -> approval -> publish -> a NEW candidate registers, confirms the e-mailed link and applies
 * (a second application from another tab is refused) -> shortlist -> interview -> RESCHEDULE -> panel feedback -> selected
 * -> offer -> HR approval -> sent -> accepted -> onboarding completed -> active employee; then the database trail.
 */
test('internal recruitment: hiring request to active employee, with duplicate application and rescheduling', async ({ browser }) => {
  const title = unique('E2E Platform Engineer');
  const cand = { first: 'Esha', last: 'Endtoend', email: `e2e.${Date.now().toString(36)}@candidate.example` };

  // 1. HR (Vikram, head of Engineering) raises a hiring request and submits it
  const vikram = await signIn(browser, USERS.vikram);
  await open(vikram, 'hr', 'Hiring requests');
  await vikram.getByRole('button', { name: 'New hiring request' }).click();
  let d = dialog(vikram, 'New hiring request');
  await submitRefused(d, 'Save', 'Please correct the highlighted fields.');        // client validation: nothing sent yet
  await expect(d.locator('.field-error').first()).toHaveText('Required.');
  await fill(d, 'departmentId', 'Engineering');
  await fill(d, 'title', title);
  await fill(d, 'headcount', 1);
  await fill(d, 'justification', 'E2E: new platform team');
  await submit(d, 'Save');
  await toast(vikram, /Hiring request ER-.* saved/);
  await expect(row(vikram, title)).toContainText('Submitted');

  // the requester cannot approve their own request: no Approve button for him
  await expect(row(vikram, title).getByRole('button', { name: 'Approve' })).toHaveCount(0);

  // 2. another HR manager approves
  const anita = await signIn(browser, USERS.anita);
  await open(anita, 'hr', 'Hiring requests');
  await rowAction(anita, title, 'Approve');
  d = dialog(anita, /^Approve ER-/);
  await fill(d, 'comments', 'Budget confirmed');
  await submit(d, 'Approve');
  await toast(anita, 'Hiring request approved.');

  // 3. the recruiter creates the job with a skill; HR approves the content; the recruiter publishes
  const priya = await signIn(browser, USERS.priya);
  await open(priya, 'recruiter', 'Jobs');
  await priya.getByRole('button', { name: 'New job' }).click();
  d = dialog(priya, 'New job');
  await fill(d, 'employeeRequisitionId', title);
  await fill(d, 'summary', 'Builds the platform');
  await fill(d, 'minExperienceYears', 2);
  await d.getByRole('textbox', { name: 'Skill' }).first().fill('Kubernetes');
  await submit(d, 'Create job');
  await toast(priya, /Job .* created and sent for approval/);
  await expect(row(priya, title)).toContainText('Pending approval');
  await expect(row(priya, title).getByRole('button', { name: 'Approve' })).toHaveCount(0);   // recruiters do not approve jobs

  await open(anita, 'hr', 'Jobs & approvals');
  await rowAction(anita, title, 'Approve');
  await submit(dialog(anita, /^Approve /), 'Approve');
  await toast(anita, 'Job approved; it can now be published.');

  await priya.reload();
  await rowAction(priya, title, 'Publish');
  await submit(dialog(priya, /^Publish /), 'Publish');
  await toast(priya, 'Job published.');
  await expect(row(priya, title)).toContainText('Open');

  // 4. a new candidate registers; sign-in waits for the e-mailed confirmation link
  const cctx = await browser.newContext();
  const candPage = await cctx.newPage();
  await candPage.goto('/register');
  await candPage.locator('#fn').fill(cand.first);
  await candPage.locator('#ln').fill(cand.last);
  await candPage.locator('#em').fill(cand.email);
  await candPage.locator('#pw').fill(testPassword());
  await candPage.locator('#pw2').fill(testPassword());
  await candPage.getByRole('button', { name: 'Create account' }).click();
  await expect(candPage.getByRole('heading', { name: 'Check your e-mail' })).toBeVisible();
  deliverMail();
  const link = latestMail(cand.email, 'EMAIL_VERIFY');
  expect(link?.token, 'confirmation e-mail delivered').toBeTruthy();
  await candPage.goto('/verify-email?token=' + encodeURIComponent(link!.token!));
  await candPage.getByRole('button', { name: 'Confirm my e-mail address' }).click();
  await expect(candPage).toHaveURL(/\/login/);
  await candPage.locator('#email').fill(cand.email);
  await candPage.locator('#password').fill(testPassword());
  await candPage.getByRole('button', { name: 'Sign in' }).click();
  await expect(candPage).toHaveURL(/\/candidate/);

  // 5. the candidate finds the job; a second tab has it open too
  await open(candPage, 'candidate', 'Find jobs');
  await candPage.getByRole('searchbox', { name: 'Search jobs' }).fill(title);
  await candPage.getByRole('button', { name: 'Search' }).click();
  await row(candPage, title).click();
  const tab2 = await cctx.newPage();                                   // the session is per tab (sessionStorage): sign in there too
  await tab2.goto('/login');
  await tab2.locator('#email').fill(cand.email);
  await tab2.locator('#password').fill(testPassword());
  await tab2.getByRole('button', { name: 'Sign in' }).click();
  await expect(tab2).toHaveURL(/\/candidate/);
  await open(tab2, 'candidate', 'Find jobs');
  await tab2.getByRole('searchbox', { name: 'Search jobs' }).fill(title);
  await tab2.getByRole('button', { name: 'Search' }).click();
  await row(tab2, title).click();
  await expect(tab2.getByRole('button', { name: 'Apply' })).toBeVisible();

  await candPage.getByRole('button', { name: 'Apply' }).click();
  d = dialog(candPage, `Apply: ${title}`);
  await fill(d, 'coverNote', 'I run Kubernetes in production.');
  await submit(d, 'Submit application');
  await toast(candPage, 'Application submitted.');
  await expect(candPage.getByText('You have applied')).toBeVisible();

  // DUPLICATE APPLICATION: the stale tab still offers "Apply"; the server refuses and the dialog says why
  await tab2.getByRole('button', { name: 'Apply' }).click();
  await submitRefused(dialog(tab2, `Apply: ${title}`), 'Submit application', 'You have already applied for this job.');
  await tab2.close();
  expect(num(`SELECT COUNT(*) FROM cand.JobApplications a JOIN cand.Candidates c ON c.CandidateId = a.CandidateId WHERE c.EmailNormalized = UPPER('${cand.email}')`)).toBe(1);

  // 6. the recruiter shortlists and schedules an interview with an internal panel (Vikram leads)
  await open(priya, 'recruiter', 'Applications');
  await priya.getByRole('searchbox', { name: 'Search' }).fill(cand.email);
  await priya.getByRole('button', { name: 'Show' }).click();
  await rowAction(priya, cand.email, 'Shortlist');
  await submit(dialog(priya, /^Shortlist /), 'Shortlist');
  await toast(priya, 'Candidate shortlisted.');
  await rowAction(priya, cand.email, 'Schedule interview');
  d = dialog(priya, 'Schedule interview');
  await fill(d, 'startsAt', localDateTime(2, 10));
  await fill(d, 'locationOrLink', 'https://meet.example/e2e');
  await tick(d, 'Vikram Nair');
  await tick(d, 'Priya Menon');
  await submit(d, 'Schedule');
  await toast(priya, 'Interview scheduled; the candidate has been invited.');
  const ivId = num(`SELECT TOP 1 i.InterviewId FROM cand.Interviews i JOIN cand.JobApplications a ON a.ApplicationId = i.JobApplicationId JOIN cand.Candidates c ON c.CandidateId = a.CandidateId WHERE c.EmailNormalized = UPPER('${cand.email}')`);

  // 7. INTERVIEW RESCHEDULING: the recruiter moves it a day later; the candidate sees the new time and gets a new invitation
  const invitesBefore = num(`SELECT COUNT(*) FROM notify.NotificationQueue WHERE RelatedEntityType = 'Interview' AND RelatedEntityId = ${ivId}`);
  await open(priya, 'recruiter', 'Interviews');
  await row(priya, `${cand.first} ${cand.last}`).click();
  await priya.getByRole('button', { name: 'Reschedule' }).click();
  d = dialog(priya, 'Reschedule interview');
  await fill(d, 'startsAt', localDateTime(3, 11, 30));
  await submit(d, 'Reschedule');
  await toast(priya, 'Interview rescheduled; the candidate is notified.');
  await expect(row(priya, `${cand.first} ${cand.last}`)).toContainText('Rescheduled');
  expect(scalar(`SELECT FORMAT(DATEADD(MINUTE, 330, StartsAt), 'yyyy-MM-dd HH:mm') FROM cand.Interviews WHERE InterviewId = ${ivId}`)).toBe(`${day(3)} 11:30`);
  expect(num(`SELECT COUNT(*) FROM notify.NotificationQueue WHERE RelatedEntityType = 'Interview' AND RelatedEntityId = ${ivId}`)).toBeGreaterThan(invitesBefore);
  await open(candPage, 'candidate', 'Interviews');
  await expect(row(candPage, title)).toContainText('Rescheduled');

  // the interview "takes place" (time cannot be waited for: only the clock of this interview is moved)
  sql(`UPDATE cand.Interviews SET StartsAt = DATEADD(HOUR, -3, SYSUTCDATETIME()), EndsAt = DATEADD(HOUR, -2, SYSUTCDATETIME()) WHERE InterviewId = ${ivId}`);

  // 8. both panel members give feedback; the interview completes
  for (const [p, area, rec] of [[vikram, 'hr', 'Strong yes'], [priya, 'recruiter', 'Yes']] as const) {
    await open(p, area, 'Interviews');
    await row(p, `${cand.first} ${cand.last}`).click();
    await p.getByRole('button', { name: 'Give feedback' }).click();
    d = dialog(p, 'Interview feedback');
    await fill(d, 'rating', rec === 'Strong yes' ? 5 : 4);
    await fill(d, 'recommendation', rec);
    await fill(d, 'strengths', 'Clear design thinking');
    await submit(d, 'Submit feedback');
    await toast(p, 'Feedback recorded.');
  }
  await expect(row(priya, `${cand.first} ${cand.last}`)).toContainText('Completed');

  // 9. selection, offer, HR approval (not the creator), sending
  await open(priya, 'recruiter', 'Applications');
  await priya.getByRole('searchbox', { name: 'Search' }).fill(cand.email);
  await priya.getByRole('button', { name: 'Show' }).click();
  await rowAction(priya, cand.email, 'Change status');
  d = dialog(priya, /^Change status of /);
  await fill(d, 'newStatus', 'Selected');
  await fill(d, 'reason', 'Panel recommends');
  await submit(d, 'Change status');
  await rowAction(priya, cand.email, 'Create offer');
  d = dialog(priya, /^Create offer/);
  await fill(d, 'designation', 'Platform Engineer');
  await fill(d, 'offeredSalary', 2100000);
  await fill(d, 'startDate', day(30));
  await submit(d, 'Create offer');
  await toast(priya, /Offer OFR-.* created and waiting for HR approval/);
  const offerNo = scalar(`SELECT o.OfferNo FROM cand.JobOffers o JOIN cand.JobApplications a ON a.ApplicationId = o.ApplicationId JOIN cand.Candidates c ON c.CandidateId = a.CandidateId WHERE c.EmailNormalized = UPPER('${cand.email}')`);

  await open(priya, 'recruiter', 'Offers');
  await expect(row(priya, offerNo).getByRole('button', { name: 'Approve' })).toHaveCount(0);
  await open(anita, 'hr', 'Offer approvals');
  await rowAction(anita, offerNo, 'Approve');
  await submit(dialog(anita, `Approve offer ${offerNo}`), 'Approve');
  await toast(anita, 'Offer approved.');
  await priya.reload();
  await rowAction(priya, offerNo, 'Send to candidate');
  await submit(dialog(priya, `Send offer ${offerNo}`), 'Send');
  await toast(priya, 'Offer sent to the candidate.');

  // 10. the candidate accepts: employee + onboarding are created in one transaction
  await open(candPage, 'candidate', 'Offers');
  await rowAction(candPage, offerNo, 'Accept');
  await submit(dialog(candPage, `Accept offer ${offerNo}`), 'Accept offer');
  await toast(candPage, 'Offer accepted.');
  await expect(row(candPage, offerNo)).toContainText('Accepted');

  // 11. HR completes onboarding; the employee becomes Active
  await open(anita, 'hr', 'Employees & onboarding');
  await row(anita, `${cand.first} ${cand.last}`).click();
  const openTasks = anita.locator('section.card').getByRole('button', { name: 'Complete', exact: true });
  await expect(openTasks).toHaveCount(7);
  for (let left = 7; left > 0; left--) {
    await openTasks.first().click();
    await submit(dialog(anita, /^Complete: /), 'Mark complete');
    await expect(openTasks).toHaveCount(left - 1);                    // the checklist has refreshed before the next task
  }
  await expect(row(anita, `${cand.first} ${cand.last}`)).toContainText('Active');

  // 12. the database trail
  const em = sqlText(cand.email.toUpperCase());
  expect(scalar(`SELECT jr.Status FROM rec.JobRequisitions jr WHERE jr.Title = N'${sqlText(title)}'`)).toBe('Filled');
  expect(scalar(`SELECT a.Status FROM cand.JobApplications a JOIN cand.Candidates c ON c.CandidateId = a.CandidateId WHERE c.EmailNormalized = N'${em}'`)).toBe('Hired');
  expect(scalar(`SELECT e.Status FROM hr.Employees e JOIN cand.Candidates c ON c.CandidateId = e.CandidateId WHERE c.EmailNormalized = N'${em}'`)).toBe('Active');
  expect(num(`SELECT COUNT(*) FROM cand.ApplicationStatusHistory h JOIN cand.JobApplications a ON a.ApplicationId = h.ApplicationId JOIN cand.Candidates c ON c.CandidateId = a.CandidateId WHERE c.EmailNormalized = N'${em}'`)).toBeGreaterThanOrEqual(6);
  expect(scalar(`SELECT u.Email FROM cand.OfferApprovals oa JOIN cand.JobOffers o ON o.OfferId = oa.OfferId JOIN sec.Users u ON u.UserId = oa.ApproverUserId WHERE o.OfferNo = N'${offerNo}'`)).toBe(USERS.anita);
  expect(num(`SELECT COUNT(*) FROM audit.AuditLogs WHERE TableName = 'cand.JobOffers' AND RecordId = (SELECT CAST(OfferId AS NVARCHAR(50)) FROM cand.JobOffers WHERE OfferNo = N'${offerNo}') AND ChangedByUserId IS NOT NULL`)).toBeGreaterThanOrEqual(3);
});
