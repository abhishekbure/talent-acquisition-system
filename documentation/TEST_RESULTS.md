# TAMS — Test Results

Only results from tests that were actually executed are recorded here. Target = SQL Server 2019 Developer 15.0.2000.5 (RTM), default instance, unless stated.

## One command for everything (Phase 14)

`.\scripts\testing\Run-AllTests.ps1 -IncludeTasks -IncludeAgent -IncludePerformance -IncludeCleanBuild` — last run 2026-11-20, **1,078 / 1,078 passed in about 6.5 minutes**:

| Suite | Result |
|---|---|
| Database (9 SQL suites, disposable copy) | 443 / 443 |
| Backend API integration | 74 / 74 |
| Frontend unit | 43 / 43 |
| **Browser end-to-end (Playwright, real app → API → SQL Server)** | **14 / 14** |
| Task Scheduler harness | 27 / 27 |
| SQL Server Agent harness | 18 / 18 |
| Performance (≈2 million rows) | 16 / 16 |
| Clean build into a new database | 443 / 443 |

## Phase 14 requirement → test traceability

| Requirement | Where it is proved |
|---|---|
| **Database:** tables and relationships | `01` A01–A08 (schemas, 64 tables, keys, FKs/checks trusted), C01–C18 (relationship rules) |
| Stored procedures | `02` I01–I51, X01–X68, S01–S15, plus `04`–`09` |
| Functions | `02` F01–F11 |
| Triggers | `02` T01–T13 (audit with acting user, status history, append-only, DDL) |
| Constraints | `01` D01–D30 |
| Transactions | `01` E02, `02` I41, I51 (rollback of a failing last step), X27, X47; savepoints `08` J06 |
| Multi-row operations | `02` T02, T03, T05, T06; performance A01 (2,000-row audited update) |
| Customer isolation | `01` D13–D17, `02` X02–X06, X14, X18, X21, X39, X46, X60–X62, `04` (57), `07` S03 |
| **Backend:** authentication | AuthenticationTests (10), TokenSecurityTests (2), PasswordStorageTests, AbuseLimitTests |
| Authorization | AuthorizationTests, ManipulatedIdentifierTests (5), role-change tests |
| Candidate management | CandidateManagementTests, registration tests |
| Recruitment / interviews / offers | InternalRecruitmentWorkflowTests; OfferAndInterviewEdgeCaseTests (rejection, decline, reschedule, cancel) |
| Staffing / contracts / timesheets / billing | StaffingWorkflowTests; ContractAndBillingEdgeCaseTests (expiry, renewal, invoice failure/retry, void); concurrency tests |
| Reports | ReportTests (6), report isolation |
| **Frontend:** role-based navigation | unit: guards and menu/route consistency; E2E: exact menu per role for all 6 roles, foreign addresses redirected, API 403 |
| Forms / validation | unit: DialogHost validation and conversion; E2E: required fields, number bounds, e-mail format, server refusals shown in the dialog |
| API integration | unit: Api client (errors, capped lists, downloads); E2E: everything through the real API |
| Candidate workflow | E2E: register → confirm e-mail → search → apply → interview → accept; profile and skills; decline an offer |
| Recruiter workflow | E2E: jobs, applications, interviews, offers, staffing submissions, contracts, invoices; candidate management |
| Customer workflow | E2E: request, shortlist, interview, select, timesheet approve/reject, invoices, contract expiry view |
| Contractor workflow | E2E: timesheet entry, submission, correction after rejection; own contract without the bill rate |
| HR workflow | E2E: hiring request, approvals (four-eyes), job approval, offer approval/rejection, onboarding to Active |
| Administrator workflow | E2E: create a user, deactivate (signed out at once), scheduled-job runs and failure notice |
| **E2E:** both complete workflows | `internal-recruitment.spec.ts`, `staffing.spec.ts` |
| Duplicate application prevention | internal-recruitment (second tab refused, one row in the database) |
| Offer rejection | edge-cases (HR rejects with a reason; candidate declines) |
| Interview rescheduling | internal-recruitment (new time in IST, new invitation, candidate sees it) |
| Timesheet rejection and resubmission | staffing |
| Contract expiry | edge-cases (Agent job → console-app notices → e-mail → customer view → renewal) |
| Invoice generation failure and retry | staffing (no approved hours → refused, nothing written → approved → succeeds); API: no rate in force → retry → void → re-invoice |
| Unauthorized customer access | staffing (another customer sees nothing; manipulated requests from its browser get 404) |
| Database rollback | staffing (refused contract leaves no contractor or placement) |
| Scheduler failure recovery | edge-cases (failed daily report reported to the administrator → catch-up → succeeds; abandoned run cleared); API SchedulerRecoveryTests |

## Current state (2026-11-20, after Phase 14)

| Suite | How to run | Result |
|---|---|---|
| Phase 2 schema / constraint / data | `database/12_Tests/01_Schema_Constraint_Data_Tests.sql` | **64 / 64** |
| Phase 3 functions, views, triggers, procedures (end-to-end workflows) | `database/12_Tests/02_Functions_Views_Triggers_Procedures_Tests.sql` | **167 / 167** (6 consecutive runs) |
| Permissions / least privilege (app, report and — since Phase 13 — worker identities) | `database/12_Tests/03_Permission_Tests.sql` | **22 / 22** |
| Real concurrency, blocking, deadlock, isolation | `scripts/database/Test-Concurrency.ps1` | **18 / 18** |
| Backup / restore / point-in-time | `scripts/database/Demo-BackupRestore.ps1` | **8 / 8** |
| Clean build of everything into a NEW database | `Run-DatabaseSetup.ps1 -DatabaseName <new> -IncludeTests` | all folders OK; **247 / 247** SQL tests |
| Query-scope tests for the API read procedures | `database/12_Tests/04_Query_Scope_Tests.sql` | **57 / 57** (53 + staff directory 2 + draft-invoice visibility 2) |
| **Document management** (access rules, validation, compliance decisions, audit) | `database/12_Tests/05_Document_Tests.sql` | **30 / 30** (runs in a rolled-back transaction) |
| **Notifications and e-mail confirmation** (queue, back-off, leases, erased links, administration, confirmation, IST, least privilege) | `database/12_Tests/06_Notification_Tests.sql` | **40 / 40** (rolled-back transaction) |
| **Reports reconcile with the database** (gate of Phase 10: all 19 reports, roles, customer isolation, pay secrecy, validation; Phase 13: report-run audit) | `database/12_Tests/07_Report_Tests.sql` | **31 / 31** (rolled-back transaction) |
| **Scheduled-job procedures** (data jobs, history, Skipped, failure reporting, least privilege) | `database/12_Tests/08_Job_Tests.sql` | **17 / 17** (rolled-back transaction) |
| **Console-app task procedures** (catalogue, leases, Skipped, abandoned runs, every reminder and its de-duplication, daily report without a summary, purgeable files, least privilege of the bookkeeping) | `database/12_Tests/09_AppTask_Tests.sql` | **15 / 15** (rolled-back transaction) |
| **Console app run by hand and by Windows Task Scheduler** on a copy (exit codes, retry, every task, housekeeping, duplicate-run prevention, failure reporting, JSON log, 7 registered tasks started through Task Scheduler) | `scripts/testing/Test-ScheduledTasks.ps1` | **27 / 27** |
| **Performance and index effectiveness on ~2 million rows** (64 timed calls, 4 index proofs, missing-index check, audited bulk change, real-API stress test) | `scripts/testing/Test-Performance.ps1` | **16 / 16** |
| **Real SQL Server Agent runs** of all 9 jobs on a copy (Agent job history, backups restored as a chain, lock, failure, event log) | `scripts/testing/Test-AgentJobs.ps1` | **18 / 18** |
| **API integration (real API over HTTP, disposable DB copy)** | `scripts/deployment/Run-BackendTests.ps1` | **74 / 74** (26 since Phase 4; +1 in Phase 7; +8 in Phase 8; +6 in Phase 9; +6 in Phase 10; +1 job test in Phase 11; +3 scheduler tests in Phase 12; +17 security tests in Phase 13; +6 edge-case tests in Phase 14). One earlier run had 1 intermittent failure (KI-046) |
| Clean build of everything into a NEW database (after Phase 5 changes) | `Run-DatabaseSetup.ps1 -DatabaseName TAMS_CleanBuild5 -IncludeTests` | **304 / 304** (64 + 167 + 16 + 57), database dropped afterwards |
| Clean build of everything into a NEW database (after Phase 8) | `Run-DatabaseSetup.ps1 -DatabaseName TAMS_CleanBuild8 -IncludeTests` | **334 / 334** (64 + 167 + 16 + 57 + 30), database dropped afterwards |
| Clean build of everything into a NEW database (after Phase 9) | `Run-DatabaseSetup.ps1 -DatabaseName TAMS_CleanBuild9 -IncludeTests` | **374 / 374** (64 + 167 + 16 + 57 + 30 + 40), database dropped afterwards |
| Clean build of everything into a NEW database (after Phase 10) | `Run-DatabaseSetup.ps1 -DatabaseName TAMS_CleanBuild10 -IncludeTests` | **402 / 402** (64 + 167 + 16 + 57 + 30 + 40 + 28), database dropped afterwards |
| Clean build of everything into a NEW database (after Phase 11) | `Run-DatabaseSetup.ps1 -DatabaseName TAMS_CleanBuild11 -IncludeTests` | **419 / 419** (64 + 167 + 16 + 57 + 30 + 40 + 28 + 17), database dropped afterwards |
| Clean build of everything into a NEW database (after Phase 12) | `Run-DatabaseSetup.ps1 -DatabaseName TAMS_CleanBuild12 -IncludeTests` | **434 / 434** (64 + 167 + 16 + 57 + 30 + 40 + 28 + 17 + 15), database dropped afterwards |
| Clean build of everything into a NEW database (after Phase 13) | `Run-DatabaseSetup.ps1 -DatabaseName TAMS_CleanBuild13 -IncludeTests` | **443 / 443** (64 + 167 + 22 + 57 + 30 + 40 + 31 + 17 + 15); MAXDOP 4 set; database dropped afterwards |
| **Frontend unit tests** (isolated; HTTP replaced by Angular's test controller) | `cd frontend; npx ng test --watch=false --browsers=ChromeHeadless` | **43 / 43** |
| **Browser end-to-end** (Playwright, installed Chrome; real web app, API and database copy; no mocks) | `scripts/testing/Run-E2E.ps1` | **14 / 14** (2 runs in a row) |
| **Live browser verification, all six roles** (real API, disposable DB copy) | `New-TestCopy.ps1` + API + `npm start`, driven in the browser pane | see Phase 5 section |
| **Internal recruitment E2E through the UI** (4 accounts, 16 steps) | see `IMPLEMENTATION_PROGRESS.md` Phase 6 | all steps OK |
| Database trail of that run | `scripts/testing/Verify-InternalWorkflow.ps1 -Database <copy> -CandidateEmail <e-mail>` | **14 / 14** |
| **External staffing E2E through the UI** (customer, recruiter, new candidate → contractor; 18 steps) | see `IMPLEMENTATION_PROGRESS.md` Phase 7 | all steps OK |
| Database trail of that run | `scripts/testing/Verify-StaffingWorkflow.ps1 -Database <copy> -RequestTitle <title> -ContractorEmail <e-mail>` | **14 / 14** |
| **Documents through the UI** (candidate, customer, contractor, recruiter; 9 steps) | see `IMPLEMENTATION_PROGRESS.md` Phase 8 | all steps OK |
| **E-mail through the UI and the sender** (register → confirm → sign in; in-app list; failed delivery → admin don't-send / send again → delivered; 10 steps) | see `IMPLEMENTATION_PROGRESS.md` Phase 9 | all steps OK |
| **Reports through the UI** (Recruiter, Customer, HR Manager, Administrator; dashboards, filters, CSV, phone width; 11 steps) | see `IMPLEMENTATION_PROGRESS.md` Phase 10 | all steps OK after 1 fix |
| Environment | `scripts/database/Verify-Environment.ps1` | 0 required checks failed |

## What the Phase 3 suite proves (167 checks)
* **Functions F01–F11:** padding, CSV split, candidate search (all skills required), experience, contract duration/expiry, application age, time to hire, customer balance, effective rate (pay ≠ bill), role/scope lookups.
* **Views V01–V04:** pipeline totals equal real counts, no pay rate in any view, balances agree with the function, all 11 views return data.
* **Security S01–S15:** role gate, registration (and linking to an existing candidate = no duplicate master row), duplicate e-mail, lockout after 5 failures, token validity/revocation/deactivation, single-use and expiring password reset, admin-only user creation.
* **Internal flow I01–I51:** hiring request → approval (requester cannot approve own) → job → sign-off → publish → apply (duplicate refused, withdraw + re-apply) → status rules and history → interviews (panel rules, reschedule, one-feedback-each, auto-complete) → offer (four-eyes, one live offer) → acceptance as ONE transaction (employee, 7 onboarding tasks, history, job Filled) → onboarding → decline path → **rollback of a failure in the last step**.
* **Staffing flow + customer isolation X01–X68:** customer request (customer taken from the login, forged CustomerId = 404), recruiter assignment rules, rate limits, submissions (duplicate refused; contact details hidden until shortlisted), customer decisions, external interviews, contract in ONE transaction (pay ≤ bill ≤ customer max), timesheets (own assignment only, Monday weeks, rejection + resubmission), invoice generation (failure when no rate, retry, bill-rate arithmetic 82 h → 166,498 incl. 18% tax, double-billing refused, void releases lines), issue, partial/final payment, outstanding balance, **15+ cross-customer access attempts all refused as "not found"**, renewal (rates versioned), termination.
* **Triggers T01–T13:** audit with acting user, **multi-row** update/insert/delete and status-history behaviour, append-only guards (50010), DDL audit.

## What the API suite proves (26 tests, `tests/backend/TalentAcquisition.Tests`)
The suite starts the real OWIN pipeline in-process on `localhost:5055`, against `TalentAcquisitionDB_ApiTest` (restored from the live database, dropped afterwards). Every request goes over HTTP; nothing is mocked. Test passwords are set only inside that copy.
* **Authentication (9):** login returns token, roles, customer link and database permissions; wrong password and unknown e-mail give the same 401 and both are audited; 5 failures lock the account (429) even for the right password; logout revokes the token at once; forged payload, `alg=none` and garbage tokens rejected; registration (201) → login, duplicate e-mail in other case (409), weak password and bad e-mail (400), only a 32-byte hash stored; forgot-password always 202 and queues mail only for real accounts; reset link works once, new password logs in, change-password; deactivating a user kills the live token and further logins.
* **Authorization (2):** anonymous → 401 everywhere except `/health`; ten cross-role attempts (candidate creating jobs, contractor reading invoices, customer reading employees or generating invoices, recruiter approving offers or listing users, HR approving timesheets or reading the admin dashboard) → 403.
* **Errors and hardening (6):** 404 with correlation id and no SQL/stack text; malformed JSON and invalid fields → 400 with details; business rule → 422; duplicate → 409; 100 KB body → 413; security headers; CORS allows `http://localhost:4200` only; SQL-injection strings in search and login treated as data.
* **Customer isolation (5):** a Brightwave user tries 15 Apex invoice/timesheet/contract/request/submission/interview/customer/balance URLs, forged `customerId` filters and a forged create → all 404, nothing changed; every list contains only the caller's customer; contractors see pay rate only, customers bill rate only; a contractor cannot read or submit another contractor's timesheet; a candidate cannot read, accept or withdraw another candidate's application or offer.
* **Concurrency (2):** two simultaneous 50,000 payments on an 80,240 invoice → exactly one 201 and one 422, never overpaid; two simultaneous identical applications → exactly one 201 and one 409.
* **Internal workflow (1):** HR request (self-approval 422, other HR approves) → job with skills (publish before approval 422, recruiter approval 403, HR approves) → publish → new candidate finds and applies (duplicate 409) → shortlist → interview (non-panel feedback 404, early feedback 422, duplicate feedback 409) → auto-Completed → candidate cannot see feedback → Selected → offer (duplicate live offer 409, recruiter approval 403, accept before sending 422, other candidate 404) → accept → employee with 7 onboarding tasks → all completed → Active; database trail checked (job Filled, posting Closed, ≥5 status-history rows, Hired event, invitation queued, ≥3 offer audit rows, approver recorded).
* **Staffing workflow (1):** customer request (customer from the login; other customer 404) → recruiter accepts → submission above the customer's max 422, duplicate 409 → contact details hidden until shortlisted → customer interview (other customer 404, foreign panel member 400) → Select → contract with bill < pay 422 and bill > max 422 leave **no contractor behind** → contract created, request Filled → the candidate's login gains the Contractor role → rate visibility per party → future week 422 → week 1 submitted, other customer 404, approved, then locked (422) → week 2 rejected without reason 400, with reason → corrected → approved → invoice **80 h × 1,450 = 116,000 + 20,880 tax = 136,880** (bill rate on every line, 10 lines) → second generation 422 with no invoice created → other customer 404 → payment on Draft 422 → issue → 36,880 → PartiallyPaid → overpay 422 → future-dated 400 → 100,000 → Paid, balance 0 → void after payment 422 → customer balance equals `bill.fn_CustomerOutstandingBalance`.

## What the document suite proves (30 checks, `05_Document_Tests.sql`)
* **Validation:** owner must exist and be manageable by the caller (else 50004, so other people's records are not revealed); only the allowed document types per owner; stored name must be a bare generated name (no path characters); size 1 byte–10 MB.
* **Résumés:** the first résumé becomes the main one; asking for "main" moves the flag; deleting the main résumé clears it.
* **Who can read:** a candidate's own files; staff; a customer only for résumés of candidates it has submitted at Shortlisted/Interview/Selected (not before, not after rejection, not other document types, not other customers); contractor files only by recruiters and that contractor (not HR, not another contractor); employee files by HR and the employee; contract files by recruiters, that customer and that contractor; deleted files by nobody.
* **Compliance:** a contractor can attach proof only to their own record, which resets it to Pending; only a recruiter or admin decides; Verified needs a proof; Rejected needs a reason; the contractor is notified; **the decision is audited with the recruiter as the actor (D19a)**.
* **Audit and privilege:** uploads and deletions audited with the acting user; the application role can execute the procedures but cannot read `doc.Documents` directly.

## What the Agent harness proves (18 checks, `scripts/testing/Test-AgentJobs.ps1`, real SQL Server Agent)
* **C01:** the 9 jobs in msdb are category TAMS, owned by `sa`, have one T-SQL step in the target database and one schedule, and are disabled on copies.
* **A01–A04:** started with `sp_start_job`, the expire, contract-expiry, purge and summary jobs succeeded in Agent's job history and in TAMS's history, and made the expected changes.
* **A05–A10, backups:**
  * the first DIFF became a FULL (no TAMS base yet);
  * a FULL, a real DIFF and a LOG followed, all verified and in msdb history under `Backup\TAMS\<db>\`;
  * **the three files restored into a new database containing the change made just before the log backup**.
* **A11–A12, indexes:** index maintenance succeeded, and with every index eligible it really rebuilt (online) and reorganised indexes.
* **A13, statistics:** statistics were updated.
* **A14:** with the job's lock held by another session, the run was Skipped.
* **A15–A16, failure handling:**
  * Agent reported the failing step with its error text;
  * TAMS recorded Failed and notified the administrators;
  * Windows Application event 208 "Status: Failed" was written.
* **A17:** Agent and TAMS history both hold runs of all 9 jobs.

## What the console-app suite proves (15 checks, `09_AppTask_Tests.sql`)
* **Catalogue:** 7 Task Scheduler jobs; `usp_AppTaskBegin` refuses an unknown or SQL Agent job (50004) and records the run with its host.
* **Duplicate runs:** a second Begin while a run is going is *Skipped* and names the run, host and start time; a disabled job is *Skipped*; a run older than the lease is closed as *Failed* ("Abandoned") and a new one starts.
* **Bookkeeping:** Log and End only act on running Task Scheduler runs; End with *Failed* notifies every administrator (`JOB_FAILED`).
* **Reminders** (each run twice to prove nothing is sent twice): interviews within 24 h to the candidate and the panel, and again after a reschedule; offers expiring within 2 days; timesheet reminders only on a Monday week start and only for contractors without a submitted timesheet; contract notices to contractor, recruiter and customer users at each stage; the daily report to recruiters, HR and administrators.
* **Agent boundary:** the daily report without Agent's summary row fails with 50002 naming the Agent job.
* **Files:** a document deleted over 30 days ago is listed once, then not again after it is marked purged; recent deletions and live documents are never listed.
* **Least privilege:** `sched.usp_NotifyJobFailure` is denied to `tams_app_role`.

## What the scheduled-task harness proves (27 checks, `scripts/testing/Test-ScheduledTasks.ps1`)
* **Copy and folders:** runs on `TalentAcquisitionDB_TaskTest` with a temporary outbox, document store, backup folder and log folder; all removed afterwards.
* **By hand (M01–M12):** `--check`, `list`; exit 64 for usage errors, 2 for invalid or missing settings, 3 after retries when the database is unreachable; every task exits 0 and queues the expected rows; the queue is sent as `.eml` files; housekeeping purges the old file, marks the document, deletes the old e-mail, keeps the recent one and mirrors the store; a concurrent second copy exits at once; a lease held by another host makes the run *Skipped*; the daily report without a summary exits 1, is recorded *Failed* and notifies administrators; the JSON log has the expected fields.
* **Through Windows Task Scheduler (S01–S04):** 7 tasks registered in `\TAMS-Test\` by `Register-ScheduledTasks.ps1` (hidden launcher, interactive logon, IgnoreNew, 30-minute limit); each started by `Start-ScheduledTask` ends with Last Run Result 0 and a new TAMS run from this PC; the failing daily report gives Last Run Result 1; the 5-minute task has a next run time.
* **Z01:** the tasks and folder are unregistered.

## What the Phase 13 API security tests prove (17, `SecurityTests.cs`)
* **Manipulated identifiers:**
  * every JSON GET endpoint (found by reflection) is called with every record id in use, as a customer, a candidate and a contractor; no foreign customer, candidate or contractor data appears and nothing answers 500;
  * each leak detector first proves it fires on a staff view;
  * report filters naming another customer are refused (404) and not audited;
  * writes on another customer's contracts and invoices change nothing.
* **Tokens:** re-signed with the real key, a token that is expired, has the wrong audience or issuer, is not yet valid, has an unknown id or names another user is rejected; claimed roles grant nothing.
* **Passwords:** unique salts and hashes, PBKDF2 parameters, no text column for passwords, no password material in any response.
* **Abuse limits:** the limiter's counting and reset (unit); 429 with `Retry-After` on a second real host, unaffected by `X-Forwarded-For`; chunked bodies capped.
* **Input and errors:**
  * wrong-shape bodies on every POST/PUT as six roles give 400/403;
  * over-long values, bad ids and dates give 400/404;
  * injection strings in every list's filters are treated as data;
  * 404/405/415 use the standard shape;
  * an unreachable database gives 503 without details.
* **Concurrency:** one decision from two simultaneous approvals; one consistent invoice from two simultaneous invoice runs.

## What the performance harness proves (16 checks, `scripts/testing/Test-Performance.ps1`)
* V01 the copy holds ~2 million rows.
* P01–P03:
  * 64 calls run without error under the API's identity;
  * reports < 2 s, dashboards < 1 s, lists < 0.5 s, records < 0.2 s;
  * no list returns more than 1,000 rows.
* I01 four indexes each cut the reads on their table at least 3×; I02 no high-impact missing-index suggestion.
* A01 a 2,000-row audited update takes < 1 s.
* L01–L03 the real API under 16 pauseless clients: no failed request; stress p95 within 1.5 s for lists and 4 s for reports; every endpoint exercised.

## What the job suite proves (17 checks, `08_Job_Tests.sql`)
* **J01–J03:** expiry by IST business day; postings closed; recruiter notified; history and details; a second run changes nothing.
* **J04–J06:**
  * Expired / Expiring contracts, with assignment and placement completed, and back to Active after a renewal; audited;
  * an invalid parameter fails the run, the error is recorded and every administrator is notified.
* **J07–J08:** purge of old handled notifications, their history and used tokens, while recent and waiting ones stay; a retention under 7 days is refused.
* **J09–J10:** the daily summary equals direct counts and is one row per day; a future day is refused and recorded Failed.
* **J11–J15:**
  * Skipped when switched off;
  * backup and index work refused inside a transaction;
  * no lock left behind;
  * the catalogue has 9 Agent and 6 Task Scheduler jobs;
  * run details are for administrators only.
* **P01:** the application role is denied every job procedure.

## What the report suite proves (28 checks, `07_Report_Tests.sql`), the gate *reports match SQL counts*
* **Catalog and roles C01–C05:**
  * 19 reports (8 / 8 / 3), each backed by an existing procedure;
  * the exact report list per role (admin 19, recruiter 16, HR 11, customer 8, contractor and candidate 0), and only staff can pick a customer;
  * a role outside a report's list gives 50005, even when calling the report procedure directly;
  * an unknown report gives 50004;
  * an inverted date range, days outside 1–365 or absurd dates give 50001.
* **Recruitment R01–R09**, each compared with an independent query:
  * open jobs and their application, in-progress and hired counts;
  * every application status, with shares adding up to 100 %; a future range gives 0, and a one-day range gives exactly that day (the end day is included);
  * the pipeline per stage against `vw_RecruitmentPipeline`;
  * sourcing totals, with LinkedIn checked directly;
  * interviews, completed ones, feedback and distinct candidates interviewed, with conversion % recomputed;
  * offers by outcome adding up to the table;
  * time to hire against `cand.fn_TimeToHireDays`;
  * recruiter performance against `vw_RecruitmentPerformance`.
* **Staffing S01–S10:**
  * requests and submissions for staff, a staff filter by customer, and a customer's own rows only;
  * a forged or unknown customer id gives 50004;
  * placements with their current rates and recomputed margin, while a customer's result **has no pay rate or margin columns**;
  * active and expiring contracts against their views and a 365-day window;
  * pending timesheets and their hours;
  * invoices with balance = total − payments, and no drafts for customers;
  * outstanding amounts equal `bill.fn_CustomerOutstandingBalance` per customer, with ageing buckets adding up; a customer sees only its own.
* **HR H01–H03:**
  * onboarding done / total / overdue per employee;
  * department hires equal the time-to-hire rows, requests and applications add up, and headcount equals current employees;
  * approved and pending hiring requests, where pending ones have days waiting and no decision.
* **P01:** the application role runs reports but cannot SELECT the base tables.

## What the API report tests prove (6)
* The catalog per role, and 403 for candidates and contractors.
* All 19 reports run for an administrator with labelled, typed columns: for example "Share %" is a percent and "Overdue 1 to 30 days" a label.
* Applications, hires, outstanding balances and pending timesheets equal the database, and date ranges include and exclude correctly.
* For a customer, every one of the 8 staffing reports holds only its own company, has no pay rate or margin in the JSON or CSV, and a forged `customerId` gives 404 while its own id works. Staff get pay rate and margin, and their customer filter matches the database.
* A customer running a recruitment report gets 403, HR running a staffing report gets 403, an unknown or malformed code 404, an inverted range or `days=0` 400, an unparsable date 400 and an unknown customer 404.
* CSV export:
  * `text/csv` attachment named `tams-staffing-requests-…`;
  * UTF-8 BOM, labelled header with "(UTC)" on date-times, one line per row;
  * a customer-typed title `=HYPERLINK(...)` comes out as `'=HYPERLINK(...)`, quoted.

## What the notification suite proves (40 checks, `06_Notification_Tests.sql`)
* **Queue N01–N14:**
  * one message per event and recipient;
  * a claim takes only due messages, oldest first, under a 300-second lease, and never gives a leased message to a second worker;
  * mark-sent and mark-failed apply once, for the attempt that was handed out;
  * back-off is measured: 60 / 120 / 240 / 480 seconds, then Failed at attempt 5, and a Failed message is never claimed again;
  * an expired lease is recorded as a failed attempt and claimed again, and the vanished worker cannot record an outcome;
  * an expired lease on the last attempt gives up;
  * a recipient deactivated after queuing is not contacted.
* **Sign-in links N15–N16:** not in the in-app list or unread count; the in-app list shows the e-mail status; the link text is erased when delivered or given up, while ordinary bodies are kept.
* **Administration N17–N23:**
  * only an administrator sees the queue, with the last error and no bodies;
  * the attempt history is in order, and an unknown id gives 50004;
  * retry of Failed/Cancelled is audited, while sign-in links and Sent messages are refused;
  * cancel works on Pending only;
  * claim parameters are validated.
* **Confirmation V01–V11:**
  * a new login is unconfirmed, with a hashed link and its own candidate record;
  * the address of a recruiter-created candidate is **not** linked before confirmation, and is linked after it;
  * used or expired links are refused;
  * resend replaces older links and is throttled to one a minute;
  * no link for unknown or confirmed addresses;
  * a completed password reset confirms the address and links the record;
  * a sign-in refused only for an unconfirmed address does not count towards lockout;
  * administrator-created accounts are confirmed.
* **T01–T02:** IST formatting, including the change of year, and no `UTC` text left in any procedure. **P01:** the application role runs the procedures but cannot SELECT the queue or the tokens.

## What the API notification tests prove (6, plus changed tests)
* An impostor who registers a recruiter-created candidate's address cannot sign in, and the record stays unlinked with no duplicate. The confirmation goes to the real mailbox. The real owner takes over through "Forgot password" and is linked to the recruiter's record; the impostor's password stops working.
* Resend gives identical answers for unconfirmed, unknown and confirmed addresses. The old link stops working and the new one works.
* A provider failure (outbox below a file) is recorded with the `IOException`, Pending, and retried about 60 seconds later. It is not retried early, and is then delivered. Non-ASCII text survives, `<script>` is encoded in the HTML part, `Message-ID` carries attempt 2, and the history shows Failed then Sent.
* **Four workers in parallel deliver 40 messages: 40 files, 40 distinct ids, all Sent, and the work is shared.**
* Admin queue: a Recruiter gets 403; the list has no bodies and shows the last error; an invalid status gives 400; history, retry (the message is then delivered), retry of a Sent message gives 422, cancel works, an unknown id gives 404; a cancelled reset link cannot be retried and its text is erased.
* A password-reset e-mail is not in the in-app list.
* Changed tests:
  * Registration: 403 `email_unverified` six times without lockout; a wrong password is still a generic 401; the link is erased after delivery and works once.
  * Password reset: the token is read from the delivered `.eml`.
  * Internal workflow: the invitation subject ends in "IST" and the e-mail includes the mode.

## What the API document tests prove (8)
* Upload → list → download round trip: same bytes, original name in `Content-Disposition` (incl. UTF-8 `filename*`), `nosniff` and sandbox CSP.
* An `.exe` renamed `.pdf`, a fake `.docx` and a disallowed extension → 400, **and no file left in the store**.
* Over 10 MB → 413; not multipart → 415.
* Another user's owner → 404 with no file left behind.
* A customer can read a shortlisted candidate's résumé and nothing else.
* A file changed on disk after upload → 500 `document_integrity` (never serves altered bytes).
* Soft delete: gone from the list, download 404, row kept.
* Compliance: contractor proof → Pending → recruiter verifies; contractor cannot decide.

## What the frontend unit tests prove (38)
* **Reports (5):** column names camel-cased exactly as the API serialiser does; bars per row, or counted / summed per label, largest first and capped at 25; no bar for zero or negative values (the number stays); the page lists only the API's reports, runs the chosen report with its filters, draws chart and table and refuses an inverted range without a request; "not available for your role" for a report the role lacks.
* **E-mail confirmation and queue (7):**
  * registration does not sign in and shows the check-your-e-mail page;
  * an unconfirmed sign-in offers resend, with the neutral answer;
  * a wrong password offers no resend;
  * the confirm page sends nothing until clicked, then lands on sign-in;
  * an expired link offers a new one;
  * queue actions appear only for the right states;
  * e-mail status labels.
* **Documents (2):** the browser pre-check mirrors the server's extension list and the 10 MB limit (exactly 10 MB allowed); download names are read from `Content-Disposition`, preferring the UTF-8 form.
* Formatting: DATE values keep their calendar day; Monday-of-week (ISO) incl. Sunday and year end; INR, hours, yes/no, empty values; badge classes.
* API client: empty query parameters dropped; relative base path; API error body -> message with the correlation reference; unreachable server explained.
* Session: login stores token/roles; highest-ranked role decides the home area; bearer token only on `/api/*`; a 401 clears the session and returns to sign-in; an expired stored session is ignored; role guard redirects (UI convenience only).
* DataTable: rows, status badges, only applicable row actions, numeric sort both ways, text filter, pager.
* Dialog: required / range rules block the API call; numbers, local date-time -> UTC ISO, repeatable rows and hidden fields converted correctly; a server refusal keeps the dialog open with the message and field-level details.
* Navigation: every menu entry has a route behind a role guard, no duplicate paths, all six areas present; application status steps equal `cand.usp_ChangeApplicationStatus`; password rule equals the server policy.
* **Regression:** dashboard metrics do not re-request when the token is cleared at sign-out. Verified to FAIL with the fix removed ("found 1" stray request) and pass with it.

## Phase 5 live browser verification (2026-11-19, API on `TalentAcquisitionDB_UiCheck`, dropped afterwards)
| Role | Signed in as | Exercised (all against the real API) | Result |
|---|---|---|---|
| Recruiter | priya.menon@ | dashboard (9 metrics + open requests), jobs, applications pipeline (per-status actions), candidate search, staffing requests; **submitted Karan Joshi to CR-2026-004**: 1,400/h blocked client-side against the 1,300 maximum, 1,250/h accepted, toast shown, request moved to Sourcing | OK |
| Customer | arjun.shah@ (Apex) | dashboard scoped to Apex (3 candidates awaiting review incl. the new one); only Apex requests; contact details hidden until **shortlisting Karan** (then shown); **scheduled a customer interview** with Apex's own panel (shown 10:00 local; seeded 11:00 UTC shows 4:30 pm IST); **approved Ravi's week** (decision trail shows Arjun); invoices only Apex with balance 80,240; contracts bill rate only; typing `/recruiter` returns to own dashboard | OK |
| Contractor | ravi.kumar@ | dashboard; timesheet editor loaded the draft week (24 h), **added Thu 8 h + 1.5 h overtime, saved and submitted**: 33.5 h Submitted and locked; contracts pay rate only; profile with compliance | OK |
| Candidate | **new self-registration** (meghna.bose@) | weak password refused with the policy text; registration signs in; dashboard; job details with skills; **applied** ("You have applied"); profile skill **C#** added and removed (URL-encoded `C%23`) | OK |
| HR Manager | anita.kapoor@ | dashboard + offers awaiting approval; **approved OFR-2026-003** (created by Rahul), "Send to candidate" then offered; **completed an onboarding task** (3/7) | OK |
| Administrator | admin@ | dashboard (10 metrics, recent sign-ins), users & roles, scheduled-job definitions (no runs yet), audit log showing each action above with the acting user, customers | OK |
| Layout | - | 1009 px and 375 px (phone) widths: no sideways scrolling after fixes; side menu on phones | OK after fixes |

## Chronological log

| Date | Phase | Suite | Result |
|---|---|---|---|
| 2026-11-19 | 0 | `Verify-Environment.ps1` (before install) | FAIL — SQL Server missing |
| 2026-11-19 | 0 | `Verify-Environment.ps1` (after install) | PASS, 0 required failures |
| 2026-11-19 | 2 | schema suite on the live DB | 64/64 |
| 2026-11-19 | 2 | schema suite after passwords were set | 63/64 — test B06 was wrong (assumed no hash existed) → rewritten → 64/64 |
| 2026-11-19 | 3 | Phase 3 suite, first executions | failed with SQL syntax errors in the *test file* (expressions as `EXEC` arguments), then a real defect: `notify.usp_Enqueue` crashed on a NULL body → fixed |
| 2026-11-19 | 3 | Phase 3 suite | an unguarded interview call hit a duplicate-round error; later reproduced as intermittent on the live DB; root cause: `DATETIME2(0)` rounding made my "past time" negative case succeed ~50% of the time → test fixed; **167/167 on 6 consecutive runs afterwards** |
| 2026-11-19 | 3 | trigger tests | a `THROW` inside an append-only trigger dooms the open transaction (SQL Server behaviour) → those cases now run in throw-away transactions |
| 2026-11-19 | 3.5 | permission suite | 13/15 first (a denied `CREATE TABLE` doomed the test transaction) → DDL cases moved outside the transaction → 16/16 |
| 2026-11-19 | 3.5 | `Test-Concurrency.ps1` | first run: C3 failed because connection B kept `LOCK_TIMEOUT 1500` from C2 (script bug) → fixed → **18/18** |
| 2026-11-19 | 3.5 | `Demo-BackupRestore.ps1` | 8/8 |
| 2026-11-19 | 3.5 | clean build into a new database | failed once: security-role script referenced table types created later → moved after the types → **all 247 tests pass** |
| 2026-11-19 | 4 | query-scope suite (new read procedures) | two expected values wrong and one test granted a role that leaked into a later test → corrected → **53/53** |
| 2026-11-19 | 4 | live API smoke test (`localhost:5000`, live DB) | first run: HTTP 500 / SQL error 596 after the first request — a pooled connection was released while still under `EXECUTE AS` → lease now `REVERT`s first → health, login, me, dashboard, paged jobs, customer-scoped invoices, cross-customer 404, forged filter 404, 401/403, tampered token, wrong password, unknown e-mail, missing body 400, logout revocation all as expected |
| 2026-11-19 | 4 | `Run-BackendTests.ps1` run 1 | 25/26 — staffing test read pay/bill rate from `contract` instead of `rates` (test bug; API returned the right data) → fixed |
| 2026-11-19 | 4 | `Run-BackendTests.ps1` runs 2 and 3 | **26/26** each; live DB counts identical before and after |
| 2026-11-19 | 5 | `ng build` (first) | succeeded; 2 template warnings (`??` on index access) removed, then clean |
| 2026-11-19 | 5 | frontend unit tests | 22/22, then 23/23 with the sign-out regression test |
| 2026-11-19 | 5 | live browser check | defects found and fixed: page scrolled sideways (absolutely positioned hidden header escaping the table scroller); stretched dialog checkboxes; customers could see **Draft** invoices (procedures fixed); two 401s fired at sign-out (effects tracked the token); phone-width top bar overflow; misleading HR metric label |
| 2026-11-19 | 5 | scope suite after new procedures | 55/55 then 57/57; Phase 3 suite 167/167 after the submissions change |
| 2026-11-19 | 5 | clean build into `TAMS_CleanBuild5` | 304/304 SQL tests, 0 failed batches |
| 2026-11-19 | 5 | `Run-BackendTests.ps1` | 26/26 |
| 2026-11-19 | 6 | UI walk-through of the internal flow | completed; defects: interview lead ignored selection order; picker listed fully planned requests; "HRManager" label; `OfferStage` missing from filter/badges — all fixed |
| 2026-11-19 | 6 | `Verify-InternalWorkflow.ps1` | 12/14 first (W06: my history string was XML-escaped and omitted the real `OfferStage` step; W13: flagged the test-clock edit as unattributed, which is correct) → checks corrected → **14/14** |
| 2026-11-19 | 6 | after fixes | Phase 3 167/167, scope 57/57, clean build 304/304, API 26/26 (incl. new lead checks), unit 24/24, lead re-verified in the UI |
| 2026-11-19 | 7 | UI walk-through of the staffing flow | completed; **defect: API authorised from roles frozen in the token** (new contractor refused with 403; removed roles kept working) — fixed; plus 3 UI text defects |
| 2026-11-19 | 7 | `Verify-StaffingWorkflow.ps1` | **14/14** first run |
| 2026-11-19 | 7 | after fixes | Phase 3 167/167, clean build 304/304, API **27/27** (new `Role_changes_apply_to_existing_tokens_at_once`), unit 24/24, Tara's unchanged session re-verified |
| 2026-11-19 | 8 | document suite (new) | **29/29** |
| 2026-11-19 | 8 | `Run-BackendTests.ps1` | first run: a test file name containing quotes threw inside `MultipartFormDataContent` (test bug) → name changed → **35/35** |
| 2026-11-19 | 8 | frontend unit tests | **26/26**; production build clean |
| 2026-11-19/20 | 8 | live UI check (9 steps, 4 accounts) | all OK; **defect: compliance Verify/Reject left no audit row** (no trigger on `staff.ComplianceRecords`) → trigger added + test D19a → re-verified live; "Main résumé" column shown for non-candidate files → removed |
| 2026-11-20 | 8 | after fixes | document suite **30/30**; clean build `TAMS_CleanBuild8` **334/334**; API **35/35**; unit **26/26**; no console errors |
| 2026-11-20 | 9 | SQL suites after the schema/procedure changes | 165/167 Phase 3 (S04 by design: linking now waits for confirmation; **F06 failed because it hard-coded the build day**, KI-020) and the scope suite's temp table lacked the 2 new columns → tests updated → all suites pass |
| 2026-11-20 | 9 | notification suite (new) | **40/40** first full run, after fixing my own test script (an uncaught invalid call; `INSERT … EXEC` around calls that roll back to a savepoint) |
| 2026-11-20 | 9 | `Run-BackendTests.ps1` | **41/41** |
| 2026-11-20 | 9 | sender smoke test on a disposable copy | 2 sent; UTF-8 subject, HTML-encoded `<script>`, clickable links, reset link erased in the database |
| 2026-11-20 | 9 | live UI check (10 steps) | all OK; defects: outbox folder shown as "storagemail-outbox" (template escape), "Cancel" vs "Cancel e-mail" dialog wording — both fixed |
| 2026-11-20 | 9 | after fixes | unit **33/33**; build clean; clean build `TAMS_CleanBuild9` **374/374**; API **41/41**; only console error = the deliberate 403 for an unconfirmed sign-in |
| 2026-11-20 | 10 | all 19 reports run once on the dev database as administrator | all return rows; values spot-checked |
| 2026-11-20 | 10 | report suite (new) | **28/28** first run |
| 2026-11-20 | 10 | `Run-BackendTests.ps1 -Filter ReportTests` | **6/6** (after making column keys match the API's camel-cased row keys, found while writing the tests) |
| 2026-11-20 | 10 | frontend unit tests | **38/38** |
| 2026-11-20 | 10 | live UI check (4 roles, 11 steps) | all OK; **defect: the SVG chart shrank to unreadable ~6 px text at phone width** → HTML/CSS bars → re-verified (12 px, no overflow) |
| 2026-11-20 | 10 | after the fix | unit **38/38**; build clean; clean build `TAMS_CleanBuild10` **402/402**; API **47/47** |
| 2026-11-20 | 11 | Agent support check | Developer Edition, Agent Running (automatic); TalentAcquisitionDB in FULL recovery with `log_reuse_wait = LOG_BACKUP` (no log backup ever) → log-backup job added |
| 2026-11-20 | 11 | job procedures applied | first attempt failed to compile (expressions as `EXEC` arguments) → fixed |
| 2026-11-20 | 11 | job suite (new) | 15/17: J06 found a real defect (rolling back to a previous run's savepoint) → fixed → **17/17** |
| 2026-11-20 | 11 | `Test-AgentJobs.ps1` | failed to start twice (COPY_ONLY edit put a comment inside SQL; sqlcmd `-v` with spaces) → fixed; then 17/18 (harness `-like` with `[ ]`) → **18/18** |
| 2026-11-20 | 11 | live admin page | runs, details and the administrator's failure notification OK; defect: the install path lost its backslashes (template escape) → fixed + unit check |
| 2026-11-20 | 11 | regression | unit **39/39**; build clean; clean build `TAMS_CleanBuild11` **419/419**; API 47/48 once (KI-046, an unchanged document test: HTTP 500 for one list call, not reproducible), then the document tests alone **8/8** and two further full runs **48/48** |
| 2026-11-20 | 12 | console-app suite (new) | first run stopped with error 3930: `usp_AppTaskBegin` switched `XACT_ABORT` on before its validation THROW, dooming the caller's transaction (real defect) → fixed; T13 strengthened → **15/15** |
| 2026-11-20 | 12 | `Run-BackendTests.ps1 -Filter SchedulerTests` | failed first: test host lacked `DocumentBackupPath` (test setup); runner threw *Object synchronization method was called from an unsynchronized block* (**real defect**: a named Mutex is thread-affine and was released after `await`) → named Semaphore; JSON test re-formatted the timestamp in the local culture (test bug) → **3/3** |
| 2026-11-20 | 12 | `Test-ScheduledTasks.ps1` | Task Scheduler step read the interim result 267009 (0x41301, *running*) as a failure (harness) → waits for the final result → **27/27** |
| 2026-11-20 | 12 | clean build into `TAMS_CleanBuild12` | failed twice: the `DeletedAt` backfill referenced `audit.AuditLogs` before a new database creates it (guarded); temp-table names of an earlier suite clashed in the shared session (dropped first); J14 updated to 7 Task Scheduler jobs → **434/434** |
| 2026-11-20 | 12 | regression | API **51/51**; unit **39/39**; build clean; only `TalentAcquisitionDB` left on the instance |
| 2026-11-20 | 13 | permission suite with worker identity | **22/22** first run; notification 40/40 and app-task 15/15 with the worker identity |
| 2026-11-20 | 13 | new API security tests | 13/17 first run: **real defect: an XML body gave 500** (framework exception treated as server error) → passed on; addresses without a route returned an empty body (OWIN "soft 404") → terminal JSON 404; my test assumptions (wrong column names; reports refuse foreign customer ids with 404, not an empty result) → **17/17** |
| 2026-11-20 | 13 | performance harness, first runs | **real defects:** 10 unbounded lists (up to 73,980 rows), slow catch-all searches (up to 585,000 reads), interview list 1.5 s, interview-conversion report 892,000 reads; audit triggers quadratic-ish for mid-size statements; parallelism waits under load. Harness bugs: an expression as an EXEC argument, a lookup under the API identity, index proofs on queries that did not use the index. A RECOMPILE made text search worse (450,000 reads, skills probed per candidate) → match in one pass. A `HASH JOIN` hint was refused (8622) → temp-table paging. |
| 2026-11-20 | 13 | fresh full run | failed once because the improved procedures had been applied to the performance copy only, not to the development database (500s under load) → applied, all SQL suites re-run 443/443 → **16/16** |
| 2026-11-20 | 13 | regression | API **68/68**; unit **41/41**; build clean; clean build `TAMS_CleanBuild13` **443/443**; Task Scheduler harness **27/27** (worker identity); only `TalentAcquisitionDB` left |
| 2026-11-20 | 14 | Playwright installed (approved; 1.65.1, no browser download) | — |
| 2026-11-20 | 14 | browser E2E, first runs | test-side fixes: navigation is an `aside`, sessions are per tab, a refreshing list clicked too early. **Real defects:** (1) table statuses showed raw codes (`PendingApproval`) while filters said "Pending approval" → tables show words; (2) **contractor timesheet race**: switching week while the previous week was still loading showed the old week's grid and status under the new date → stale loads dropped, unit regression test proved to fail without the fix |
| 2026-11-20 | 14 | browser E2E, complete | **14/14** twice in a row (1.4 min) |
| 2026-11-20 | 14 | API edge-case tests | 3/6 first run (test assumptions: reschedule and renew answer 200 with the record; a global temp table vanished with its connection) → **6/6** |
| 2026-11-20 | 14 | `Run-AllTests.ps1` with every option | **1,078 / 1,078** (443 + 74 + 43 + 14 + 27 + 18 + 16 + 443) in ~6.5 min; only `TalentAcquisitionDB` left |
| 2026-11-20 | 15 | Web app served by the API (probes against the running API) | `/`, deep link, bundle, CSS and icon 200 with CSP and cache headers; unknown file, `.config`, `.bak`, `/api/v1/nope` and POST answer the JSON 404; encoded `..` refused (403 by Windows' HTTP listener) |
| 2026-11-20 | 15 | `Run-E2E.ps1` on the **production build** | **14/14** in 1.5 min (KI-064 resolved) |
| 2026-11-20 | 15 | `Start-Tams.ps1` on this PC | exit 0 in 8 s; health 28 PASS, 2 WARN (KI-011, KI-055), 0 FAIL |
| 2026-11-20 | 15 | Browser verification, six roles, `TalentAcquisitionDB` | every list matched SQL; the customer's tampered requests for another customer refused (404); found raw status codes in filters and badges → fixed (KI-069), unit tests **44/44** |
| 2026-11-20 | 15 | Backup and restore scripts | backup verified; restore to a new name 6/6 database principals with identical row counts; restore over an existing database without `-Replace` refused; `-Replace` took a safety backup; damaged backup refused at VERIFYONLY; test databases and files removed |
| 2026-11-20 | 15 | `Run-AllTests.ps1` with every option | **1,079 / 1,079** (443 + 74 + 44 + 14 + 27 + 18 + 16 + 443) in 6 min; only `TalentAcquisitionDB` left, no `\TAMS*` tasks |
| 2026-11-21 | 12/15 | Task Scheduler tasks registered for `TalentAcquisitionDB` (approved) | 7 tasks in `\TAMS\`, Ready, run as the signed-in user (interactive, no stored password); *Email queue processing* started through Task Scheduler → result 0, TAMS run 132 Succeeded (0 messages waiting); after a PC restart the API was down as expected (KI-065) → `Start-Tams.ps1` → health **30 PASS, 1 WARN (KI-011), 0 FAIL** |
| 2026-11-20 | 15 | `Test-CleanDeployment.ps1` (from nothing) | first run: start-up healthy in ~30 s but the captured call never returned → defect KI-070 fixed → **12/12** (35 s from nothing), twice; failure path checked: an invalid `ListenUrl` is reported with the `--check` reason |
| 2026-11-20 | 11 | jobs installed on TalentAcquisitionDB (approved) | 9 jobs created and enabled; *Full database backup* started through Agent: Agent `The job succeeded`, TAMS Succeeded, 1.8 MB file written and verified; Agent's next runs computed (log 16:40, then every 30 min) |

## Measured performance demonstration (`Demo-Performance.ps1`, 300,000-row copy)

| Experiment | Result |
|---|---|
| Worker query with `IX_NotifQ_Status_Next` vs forced clustered scan | **165 vs 6,550 logical reads (40×)** |
| Stale statistics (150,000 new Pending rows, auto-update off) | estimated **2,250**, actual **151,500** → 151,500 key lookups, **464,568 reads, 189 ms** |
| After `UPDATE STATISTICS … FULLSCAN` | estimate 151,500 → clustered scan, **9,327 reads, 25 ms** |
| Table variable, compatibility level 130 | estimate **1** vs 100,000 actual, **302,269 reads** |
| Table variable, level 150 (deferred compilation) / temp table | estimate 100,000, **4,351 reads** |
| Window functions (SUM OVER, LAG, ROW_NUMBER, RANK), recursive CTE (8-week zero-filled series), numbers-generator CTE | correct output on the seed data |

## Not yet tested
Tasks running while signed out (KI-052), load from separate client machines (KI-060), browsers other than Chrome (KI-062), `npm ci` from the registry in the from-scratch test (node_modules is linked to avoid a download), the API as a Windows service (not built, KI-065).
