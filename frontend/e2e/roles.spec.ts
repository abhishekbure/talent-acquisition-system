import { expect, test } from '@playwright/test';
import { USERS, apiFromBrowser, dialog, fill, num, open, row, rowAction, signIn, submit, submitRefused, testPassword, toast, unique } from './support';

/** Role-based navigation for all six roles, and the role workflows not covered by the two business-model tests. */

const MENUS: Record<string, { email: string; slug: string; items: string[]; forbiddenUrl: string; forbiddenApi: string }> = {
  Candidate: { email: USERS.rohan, slug: 'candidate', items: ['Dashboard', 'Find jobs', 'My applications', 'Interviews', 'Offers', 'My profile'], forbiddenUrl: '/recruiter/candidates', forbiddenApi: '/candidates' },
  Contractor: { email: USERS.sneha, slug: 'contractor', items: ['Dashboard', 'Timesheets', 'Contracts', 'Profile & compliance'], forbiddenUrl: '/customer/invoices', forbiddenApi: '/invoices' },
  Customer: { email: USERS.arjun, slug: 'customer', items: ['Dashboard', 'Staffing requests', 'Interviews', 'Timesheet approvals', 'Contracts', 'Contractors', 'Invoices & balance', 'Reports'], forbiddenUrl: '/hr/employees', forbiddenApi: '/employees' },
  Recruiter: { email: USERS.priya, slug: 'recruiter', items: ['Dashboard', 'Jobs', 'Applications', 'Candidates', 'Interviews', 'Offers', 'Staffing requests', 'Contractors & compliance', 'Contracts', 'Timesheets', 'Invoices', 'Reports'], forbiddenUrl: '/admin/users', forbiddenApi: '/users' },
  HRManager: { email: USERS.vikram, slug: 'hr', items: ['Dashboard', 'Hiring requests', 'Jobs & approvals', 'Offer approvals', 'Employees & onboarding', 'Applications', 'Candidates', 'Interviews', 'Departments', 'Reports'], forbiddenUrl: '/recruiter/invoices', forbiddenApi: '/invoices' },
  Administrator: { email: USERS.admin, slug: 'admin', items: ['Dashboard', 'Users & roles', 'Customers & rate cards', 'Departments', 'Audit & login history', 'Scheduled jobs', 'Reports', 'E-mail queue', 'Hiring requests', 'Jobs', 'Staffing requests', 'Contracts', 'Invoices'], forbiddenUrl: '/contractor/timesheets', forbiddenApi: '/timesheets/mine' }
};

for (const [role, m] of Object.entries(MENUS)) {
  test(`role-based navigation: ${role} sees exactly its menu, and another role's pages and API calls are refused`, async ({ browser }) => {
    const page = await signIn(browser, m.email);
    await expect(page).toHaveURL(new RegExp(`/${m.slug}$`));
    const links = page.locator('aside.sidenav a').filter({ hasNotText: /^(Candidate|Contractor|Customer|Recruiter|HR Manager|Administrator)$/ });
    await expect(links).toHaveText(m.items);
    await page.goto(m.forbiddenUrl);                                      // typing another area's address ...
    await expect(page).toHaveURL(new RegExp(`/${m.slug}$`));              // ... leads back home (the route guard is UX only:)
    const r = await apiFromBrowser(page, 'GET', m.forbiddenApi);
    expect(r.status, 'the API refuses it whatever the browser does').toBe(403);
  });
}

test('candidate workflow: edit the profile and skills', async ({ browser }) => {
  const rohan = await signIn(browser, USERS.rohan);
  await open(rohan, 'candidate', 'My profile');
  await rohan.getByRole('button', { name: 'Edit profile' }).click();
  let d = dialog(rohan, 'Edit profile');
  await fill(d, 'totalExperienceYears', 75);
  await submitRefused(d, 'Save', 'Please correct the highlighted fields.');
  await expect(d.locator('.field-error')).toHaveText('Must be at most 60.');
  await fill(d, 'totalExperienceYears', 6.5);
  await fill(d, 'currentTitle', 'Senior QA Engineer');
  await submit(d, 'Save');
  await toast(rohan, 'Profile saved.');
  await expect(rohan.locator('main')).toContainText('Senior QA Engineer');
  await rohan.getByRole('button', { name: 'Add or update a skill' }).click();
  d = dialog(rohan, 'Add or update a skill');
  await fill(d, 'skillName', 'Playwright');
  await fill(d, 'yearsExperience', 2);
  await submit(d, 'Save');
  await toast(rohan, 'Skill saved.');
  await rowAction(rohan, 'Playwright', 'Remove');
  await submit(dialog(rohan, 'Remove skill'), 'Remove');
  await toast(rohan, 'Skill removed.');
  expect(num(`SELECT COUNT(*) FROM cand.CandidateSkills s JOIN cand.Candidates c ON c.CandidateId = s.CandidateId WHERE c.EmailNormalized = UPPER('${USERS.rohan}') AND s.SkillName = 'Playwright'`)).toBe(0);
  expect(num(`SELECT TotalExperienceYears FROM cand.Candidates WHERE EmailNormalized = UPPER('${USERS.rohan}')`)).toBe(6.5);
});

test('recruiter workflow: candidate management (add, duplicate refused, search)', async ({ browser }) => {
  const priya = await signIn(browser, USERS.priya);
  await open(priya, 'recruiter', 'Candidates');
  const email = `e2e.added.${Date.now().toString(36)}@candidate.example`;
  await priya.getByRole('button', { name: 'Add candidate' }).click();
  let d = dialog(priya, 'Add candidate');
  await fill(d, 'firstName', 'Asha');
  await fill(d, 'lastName', 'Added');
  await fill(d, 'email', 'not-an-email');
  await submitRefused(d, 'Add candidate', 'Please correct the highlighted fields.');
  await fill(d, 'email', email);
  await fill(d, 'currentTitle', 'Data Analyst');
  await fill(d, 'totalExperienceYears', 3);
  await submit(d, 'Add candidate');
  await priya.getByRole('button', { name: 'Add candidate' }).click();
  d = dialog(priya, 'Add candidate');
  await fill(d, 'firstName', 'Asha');
  await fill(d, 'lastName', 'Again');
  await fill(d, 'email', email.toUpperCase());
  await fill(d, 'totalExperienceYears', 3);
  await submitRefused(d, 'Add candidate', /already/i);                    // one candidate master per e-mail address
  await d.getByRole('button', { name: 'Cancel' }).click();
  await priya.getByRole('searchbox', { name: 'Search' }).fill('Asha Added');
  await priya.getByRole('button', { name: 'Search' }).click();
  await expect(row(priya, email)).toContainText('Data Analyst');
  expect(num(`SELECT COUNT(*) FROM cand.Candidates WHERE EmailNormalized = UPPER('${email}')`)).toBe(1);
});

test('administrator workflow: create a user who signs in, then deactivate them (signed out at once)', async ({ browser }) => {
  const admin = await signIn(browser, USERS.admin);
  await open(admin, 'admin', 'Users & roles');
  const email = `e2e.recruiter.${Date.now().toString(36)}@tams.local`, name = unique('E2E Recruiter');
  await admin.getByRole('button', { name: 'New user' }).click();
  const d = dialog(admin, 'New user');
  await fill(d, 'email', email);
  await fill(d, 'displayName', name);
  await fill(d, 'roleName', 'Recruiter');
  await expect(d.locator('#f_customerId')).toHaveCount(0);               // only shown for customer users
  await fill(d, 'temporaryPassword', 'short');
  await submitRefused(d, 'Create user', /password/i);
  await fill(d, 'temporaryPassword', testPassword());
  await submit(d, 'Create user');
  await toast(admin, 'User created.');

  const newbie = await signIn(browser, email);
  await expect(newbie).toHaveURL(/\/recruiter$/);

  await admin.getByRole('searchbox', { name: /Search/ }).first().fill(email);
  await admin.getByRole('button', { name: 'Search' }).click();
  await rowAction(admin, email, 'Deactivate');
  await submit(dialog(admin, `Deactivate ${name}`), 'Deactivate');
  await toast(admin, 'User deactivated.');
  await newbie.goto('/recruiter/jobs');                                   // the next request is refused and the session ends
  await expect(newbie).toHaveURL(/\/login/);
  expect(num(`SELECT COUNT(*) FROM sec.AuthTokens t JOIN sec.Users u ON u.UserId = t.UserId WHERE u.EmailNormalized = UPPER('${email}') AND t.RevokedAt IS NULL`)).toBe(0);
});
