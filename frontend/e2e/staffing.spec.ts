import { expect, test } from '@playwright/test';
import {
  USERS, addDaysIso, apiFromBrowser, shownDate, dialog, enterWeek, fill, monday, num, open, registerCandidate, row, rowAction, scalar,
  signIn, sqlText, submit, submitRefused, tick, toast, unique
} from './support';

/**
 * Business model 2 — external staffing, end to end through the browser:
 * customer request -> recruiter accepts and submits a newly registered candidate (client-side bill-rate check) ->
 * customer shortlists (contact details appear), interviews, selects -> contract refused (bill below pay) and ROLLED BACK,
 * then created -> the candidate works as contractor -> week 1 approved, week 2 REJECTED, corrected and RESUBMITTED ->
 * INVOICE GENERATION FAILS while hours are unapproved and SUCCEEDS on retry -> issued -> paid in two parts.
 * Another customer can neither see nor touch any of it (UNAUTHORIZED CUSTOMER ACCESS).
 */
test('external staffing: customer request to paid invoice, with rollback, rejection, invoice retry and isolation', async ({ browser }) => {
  const title = unique('E2E Data Engineer');
  const crest = num(`SELECT CustomerId FROM org.Customers WHERE CustomerCode = 'CREST'`);
  const week1 = monday(2), week2 = monday(1);

  // 1. the customer raises a request (its customer is taken from the login)
  const kabir = await signIn(browser, USERS.kabir);
  await open(kabir, 'customer', 'Staffing requests');
  await kabir.getByRole('button', { name: 'New staffing request' }).click();
  let d = dialog(kabir, 'New staffing request');
  await expect(d.locator('#f_customerId')).toHaveCount(0);                         // a customer cannot pick a company
  await fill(d, 'title', title);
  await fill(d, 'skillsRequired', 'Python, SQL');
  await fill(d, 'startDate', week1);
  await fill(d, 'durationMonths', 6);
  await fill(d, 'maxBillRate', 1500);
  await fill(d, 'workLocation', 'Remote');
  await submit(d, 'Raise request');
  await toast(kabir, /Request .* raised\./);
  expect(num(`SELECT CustomerId FROM staff.CustomerRequisitions WHERE Title = N'${sqlText(title)}'`)).toBe(crest);

  // 2. a person registers as a candidate (shared candidate master); the recruiter accepts the request and submits them
  const first = 'Sam', last = 'Staffing' + Date.now().toString(36).slice(-4);
  const cand = await registerCandidate(browser, first, last);
  const rahul = await signIn(browser, USERS.rahul);
  await open(rahul, 'recruiter', 'Staffing requests');
  await rowAction(rahul, title, 'Accept');
  await submit(dialog(rahul, /^Accept /), 'Accept');
  await toast(rahul, 'Request accepted.');
  await row(rahul, title).click();
  await rahul.getByRole('button', { name: 'Submit a candidate' }).click();
  d = dialog(rahul, /^Submit a candidate to /);
  await fill(d, 'candidateId', cand.email);
  await fill(d, 'proposedBillRate', 1600);
  await submitRefused(d, 'Submit candidate', 'Please correct the highlighted fields.');      // above the customer's maximum
  await expect(d.locator('.field-error')).toHaveText('Must be at most 1500.');
  await fill(d, 'proposedBillRate', 1450);
  await fill(d, 'notes', '5 years of Python');
  await submit(d, 'Submit candidate');
  await toast(rahul, 'Candidate submitted; the customer has been notified.');

  // 3. the customer sees the candidate without contact details, shortlists (details appear), interviews and selects
  await kabir.reload();
  await row(kabir, title).click();
  const sub = () => row(kabir.locator('section.card'), `${first} ${last}`);
  await expect(sub()).not.toContainText(cand.email);
  await sub().getByRole('button', { name: 'Shortlist', exact: true }).click();
  await submit(dialog(kabir, `Shortlist: ${first} ${last}`), 'Shortlist');
  await toast(kabir, 'Candidate shortlisted.');
  await expect(sub()).toContainText(cand.email);
  await sub().getByRole('button', { name: 'Schedule interview', exact: true }).click();
  d = dialog(kabir, 'Schedule interview');
  await tick(d, 'Kabir');
  await submit(d, 'Schedule');
  await toast(kabir, 'Interview scheduled; the candidate has been invited.');
  await sub().getByRole('button', { name: 'Select', exact: true }).click();
  await submit(dialog(kabir, `Select: ${first} ${last}`), 'Select');
  await toast(kabir, 'Candidate selected.');

  // 4. DATABASE ROLLBACK: a contract with the bill rate below the pay rate is refused and leaves nothing behind
  await rahul.reload();
  await row(rahul, title).click();
  await row(rahul.locator('section.card'), `${first} ${last}`).getByRole('button', { name: 'Create contract' }).click();
  d = dialog(rahul, `Create contract for ${first} ${last}`);
  await fill(d, 'startDate', week1);
  await fill(d, 'payRate', 1600);
  await fill(d, 'billRate', 1450);
  await submitRefused(d, 'Create contract', /bill rate/i);
  const candId = num(`SELECT CandidateId FROM cand.Candidates WHERE EmailNormalized = UPPER('${cand.email}')`);
  expect(num(`SELECT COUNT(*) FROM staff.Contractors WHERE CandidateId = ${candId}`), 'no contractor left behind').toBe(0);
  expect(num(`SELECT COUNT(*) FROM staff.Placements p JOIN staff.SubmittedCandidates s ON s.SubmissionId = p.SubmissionId WHERE s.CandidateId = ${candId}`), 'no placement left behind').toBe(0);
  await fill(d, 'payRate', 1100);
  await submit(d, 'Create contract');
  await toast(rahul, /Contract CON-.* created\./);
  const contractNo = scalar(`SELECT ct.ContractNo FROM staff.Contracts ct JOIN staff.Placements p ON p.PlacementId = ct.PlacementId JOIN staff.Contractors k ON k.ContractorId = p.ContractorId WHERE k.CandidateId = ${candId}`);

  // 5. the candidate signs in again and now works as a contractor: week 1 of 40 h, week 2 with a 12-hour Friday
  const ctr = await signIn(browser, cand.email);
  await expect(ctr).toHaveURL(/\/contractor/);
  await open(ctr, 'contractor', 'Timesheets');
  await enterWeek(ctr, week1, [8, 8, 8, 8, 8]);
  await ctr.getByRole('button', { name: 'Save and submit for approval' }).click();
  await toast(ctr, 'Submitted to the customer for approval.');
  await enterWeek(ctr, week2, [8, 8, 8, 8, 12]);
  await ctr.getByRole('button', { name: 'Save and submit for approval' }).click();
  await toast(ctr, 'Submitted to the customer for approval.');

  // 6. INVOICE GENERATION FAILURE: nothing is approved yet, so the recruiter's run is refused and creates nothing
  const invoicesBefore = num(`SELECT COUNT(*) FROM bill.Invoices WHERE CustomerId = ${crest}`);
  await open(rahul, 'recruiter', 'Invoices');
  const generate = async () => {
    await rahul.getByRole('button', { name: 'Generate invoice' }).click();
    const g = dialog(rahul, 'Generate invoice');
    await fill(g, 'customerId', 'Crestline');
    await fill(g, 'periodStart', week1);
    await fill(g, 'periodEnd', addDaysIso(week2, 6));
    return g;
  };
  await submitRefused(await generate(), 'Generate draft', 'There are no approved, uninvoiced timesheets for this customer in the period.');
  await dialog(rahul, 'Generate invoice').getByRole('button', { name: 'Cancel' }).click();
  expect(num(`SELECT COUNT(*) FROM bill.Invoices WHERE CustomerId = ${crest}`)).toBe(invoicesBefore);

  // 7. the customer approves week 1 and REJECTS week 2 (a reason is required)
  const contractorName = `${first} ${last}`;
  await open(kabir, 'customer', 'Timesheet approvals');
  const pick = async (weekLabelDay: string) => { await kabir.locator('table.grid tbody tr').filter({ hasText: contractorName }).filter({ hasText: weekLabelDay }).first().click(); };
  const fmt = shownDate;
  await pick(fmt(week1));
  await kabir.locator('section.card').getByRole('button', { name: 'Approve', exact: true }).click();
  await submit(dialog(kabir, `Approve ${contractorName}'s week`), 'Approve');
  await toast(kabir, 'Timesheet approved.');
  await pick(fmt(week2));
  await kabir.locator('section.card').getByRole('button', { name: 'Reject', exact: true }).click();
  d = dialog(kabir, `Reject ${contractorName}'s week`);
  await submitRefused(d, 'Reject', 'Please correct the highlighted fields.');
  await fill(d, 'reason', 'Friday should be 8 hours');
  await submit(d, 'Reject');
  await toast(kabir, 'Timesheet rejected; the contractor has been notified.');

  // 8. TIMESHEET RESUBMISSION: the contractor sees the reason, corrects Friday and submits again; the customer approves
  await ctr.reload();
  await ctr.locator('input[name="wk"]').fill(week2);
  await expect(ctr.locator('.alert.error')).toContainText('Friday should be 8 hours');
  await enterWeek(ctr, week2, [8, 8, 8, 8, 8]);
  await ctr.getByRole('button', { name: 'Save and submit for approval' }).click();
  await toast(ctr, 'Submitted to the customer for approval.');
  await kabir.reload();
  await pick(fmt(week2));
  await kabir.locator('section.card').getByRole('button', { name: 'Approve', exact: true }).click();
  await submit(dialog(kabir, `Approve ${contractorName}'s week`), 'Approve');
  await toast(kabir, 'Timesheet approved.');

  // 9. RETRY: the same invoice run now succeeds — 80 h at the BILL rate 1,450 = 116,000 + 18 % = 136,880
  await submit(await generate(), 'Generate draft');
  await toast(rahul, /Draft INV-.* generated/);
  const invoiceNo = scalar(`SELECT TOP 1 InvoiceNo FROM bill.Invoices WHERE CustomerId = ${crest} ORDER BY InvoiceId DESC`);
  expect(scalar(`SELECT CAST(Total AS DECIMAL(12,2)) FROM bill.Invoices WHERE InvoiceNo = N'${invoiceNo}'`)).toBe('136880.00');
  await rowAction(rahul, invoiceNo, 'Issue');
  await submit(dialog(rahul, `Issue ${invoiceNo}`), 'Issue');
  await toast(rahul, 'Invoice issued.');
  await rowAction(rahul, invoiceNo, 'Record payment');
  d = dialog(rahul, `Record payment for ${invoiceNo}`);
  await fill(d, 'amount', 36880);
  await fill(d, 'reference', 'CREST-E2E-1');
  await submit(d, 'Record payment');
  await toast(rahul, 'Payment recorded.');
  await expect(row(rahul, invoiceNo)).toContainText('Partially paid');
  await rowAction(rahul, invoiceNo, 'Record payment');
  await submit(dialog(rahul, `Record payment for ${invoiceNo}`), 'Record payment');            // the rest of the balance
  await expect(row(rahul, invoiceNo)).toContainText('Paid');

  // 10. the customer sees its invoice; the contractor never sees the bill rate, the customer never the pay rate
  await open(kabir, 'customer', 'Invoices & balance');
  await expect(row(kabir, invoiceNo)).toContainText('Paid');
  await open(ctr, 'contractor', 'Contracts');
  await row(ctr, contractNo).click();
  await expect(ctr.locator('section.card')).toContainText('1,100');
  await expect(ctr.locator('section.card')).not.toContainText('1,450');
  await open(kabir, 'customer', 'Contracts');
  await row(kabir, contractNo).click();
  await expect(kabir.locator('section.card')).toContainText('1,450');
  await expect(kabir.locator('section.card')).not.toContainText('1,100');

  // 11. UNAUTHORIZED CUSTOMER ACCESS: Apex sees none of it, and manipulated requests from its browser are refused
  const arjun = await signIn(browser, USERS.arjun);
  await open(arjun, 'customer', 'Invoices & balance');
  await expect(arjun.locator('table.grid').first()).not.toContainText(invoiceNo);
  await open(arjun, 'customer', 'Contracts');
  await expect(arjun.locator('table.grid').first()).not.toContainText(contractNo);
  await open(arjun, 'customer', 'Staffing requests');
  await expect(arjun.locator('table.grid').first()).not.toContainText(title);
  const invId = num(`SELECT InvoiceId FROM bill.Invoices WHERE InvoiceNo = N'${invoiceNo}'`);
  const ctId = num(`SELECT ContractId FROM staff.Contracts WHERE ContractNo = N'${contractNo}'`);
  const tsId = num(`SELECT TOP 1 t.TimesheetId FROM [time].Timesheets t JOIN staff.Assignments a ON a.AssignmentId = t.AssignmentId WHERE a.ContractId = ${ctId}`);
  for (const [m, p, b] of [['GET', `/invoices/${invId}`, undefined], ['GET', `/contracts/${ctId}`, undefined], ['GET', `/timesheets/${tsId}`, undefined],
                           ['GET', `/invoices?customerId=${crest}`, undefined], ['POST', `/timesheets/${tsId}/reject`, { reason: 'hostile' }]] as const) {
    const r = await apiFromBrowser(arjun, m, p, b);
    expect(r.status, `${m} ${p}`).toBe(404);
  }

  // 12. the database trail
  expect(scalar(`SELECT CONCAT(CAST(r.PayRate AS INT), '/', CAST(r.BillRate AS INT)) FROM staff.ContractRates r JOIN staff.Contracts c ON c.ContractId = r.ContractId WHERE c.ContractNo = N'${contractNo}'`)).toBe('1100/1450');
  expect(num(`SELECT COUNT(*) FROM bill.InvoiceLines l JOIN bill.Invoices i ON i.InvoiceId = l.InvoiceId WHERE i.InvoiceNo = N'${invoiceNo}' AND l.BillRate <> 1450`)).toBe(0);
  expect(num(`SELECT COUNT(*) FROM [time].TimesheetRejections tr JOIN [time].Timesheets t ON t.TimesheetId = tr.TimesheetId JOIN staff.Assignments a ON a.AssignmentId = t.AssignmentId WHERE a.ContractId = ${ctId}`)).toBe(1);
  expect(scalar(`SELECT Status FROM bill.Invoices WHERE InvoiceNo = N'${invoiceNo}'`)).toBe('Paid');
  expect(scalar(`SELECT Status FROM staff.CustomerRequisitions WHERE Title = N'${sqlText(title)}'`)).toBe('Filled');
});
