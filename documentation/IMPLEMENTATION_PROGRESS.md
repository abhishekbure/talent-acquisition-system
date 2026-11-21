# TAMS — Implementation Progress

Status vocabulary: NOT STARTED · IN PROGRESS · BLOCKED · COMPLETED · VERIFIED.
Last updated: 2026-11-20 (Phase 15 — all phases complete).

| Phase | Name | Status |
|---|---|---|
| 0 | Inspect environment | **VERIFIED** — SQL Server 2019 Developer 15.0.2000.5 + Agent running; `Verify-Environment.ps1` exits 0 |
| 1 | Architecture & requirements | **COMPLETED** (approved, D1–D8) |
| 2 | SQL Server database (schema, constraints, indexes, seed) | **VERIFIED** on the real instance (64/64 tests; repeatable; clean build from nothing) |
| 3 | SQL Server functionality (procedures, functions, triggers, views, DB tests, 3.5 admin/performance) | **VERIFIED for the implemented scope** — 247 SQL tests + 18 real-concurrency checks + backup/restore + performance demos all pass. Deferred items listed below. |
| 4 | Web API backend | **VERIFIED** — builds with 0 warnings; 26/26 API integration tests pass on 3 consecutive runs against a disposable DB copy; live smoke test passed |
| 5 | Angular frontend | **COMPLETED** — six role areas built; 23/23 unit tests; production build clean; every role signed in and exercised live in a browser against the real API (disposable DB copy). Full UI walkthroughs of both workflows are Phases 6–7 |
| 6 | Internal recruitment E2E (UI) | **VERIFIED** — full flow walked through the UI by 4 real accounts in 4 browser tabs; database trail 14/14 (`Verify-InternalWorkflow.ps1`); 4 defects fixed and re-verified |
| 7 | External staffing E2E (UI) | **VERIFIED** — full flow walked through the UI by 3 real accounts + a newly registered candidate; database trail 14/14 (`Verify-StaffingWorkflow.ps1`); 1 security-relevant defect (stale roles in tokens) and 3 UI defects fixed |
| 8 | Document management | **VERIFIED** — upload/download/delete for candidates, contractors (compliance proofs), employees and contracts; 30/30 SQL document tests, 35/35 API tests, 26/26 unit tests; walked through live by candidate, customer, contractor and recruiter accounts; 1 audit gap found and fixed |
| 9 | Notifications | **VERIFIED**: e-mail delivery by a console sender through a mock provider (.eml files), with retry/back-off, safe concurrent workers, an admin queue page and e-mail confirmation at registration (closes KI-014, KI-021, KI-028). 40/40 new SQL tests, 41/41 API, 33/33 unit; live UI check passed; 2 UI defects fixed |
| 10 | Reporting | **VERIFIED**: the 19 required reports (8 recruitment, 8 staffing, 3 HR) as parameterised procedures behind a role-checked catalog; API with CSV export; Reports page and a dashboard chart for Recruiter, HR, Customer and Admin. Gate *reports match SQL counts*: 28/28 SQL reconciliation and security checks; API 47/47; unit 38/38; live check by 4 roles; 1 UI defect fixed |
| 11 | SQL Server Agent jobs | **VERIFIED and INSTALLED** on TalentAcquisitionDB (2026-11-20, with your approval; first full backup taken through Agent): 9 Agent jobs, the 7 required plus differential and log backups; execution history, run details and failure reporting. Proved by **real SQL Server Agent runs** on a copy (18/18, including a restore of the full + diff + log chain) and 17/17 SQL tests; API 48/48; unit 39/39 |
| 12 | Task Scheduler + console app | **VERIFIED and REGISTERED** for TalentAcquisitionDB (2026-11-21, with your approval; a run started through Task Scheduler succeeded): 7 tasks in `TalentAcquisition.Scheduler`, the 6 required plus file housekeeping, with structured logging, retry, duplicate-run prevention, exit codes, configuration validation, execution history and failure reporting; register/remove scripts. Proved by manual runs **and Windows Task Scheduler runs** on a copy (27/27); SQL 15/15; API 51/51 |
| 13 | Security & performance | **VERIFIED**: the 13 required areas tested; manipulated identifiers swept across every API endpoint and record id (no leak); worker database identity, rate limits, body cap, report audit, one error shape; on a ~2-million-row copy every report < 2 s and every list < 0.5 s (16/16), 4 index proofs, stress test without a failed request. API 68/68, SQL 443/443, unit 41/41 |
| 14 | Automated testing (backend/frontend/E2E) | **VERIFIED**: one command (`Run-AllTests.ps1`) runs every layer, 1,078 / 1,078; new browser E2E suite (Playwright, no mocks) 14/14 covering both workflows and all 9 required edge cases; API edge cases +6; 2 UI defects found and fixed |
| 15 | Local deployment | **VERIFIED**: one command (`Start-Tams.ps1`) starts the whole system and checks its health; the API serves the production web app on http://localhost:5000; from nothing to running in 35 s (`Test-CleanDeployment.ps1` 12/12); all six roles checked in the browser against the real development records; full test run 1,079 / 1,079 with the browser tests on the production build; 3 defects found and fixed |

Phases 0–2 reports: see `ENVIRONMENT_REPORT.md`, `KNOWN_ISSUES.md` (KI-007 install history) and `TEST_RESULTS.md`. Highlights: SQL Server 2019 Developer installed from the Microsoft ISO after the bootstrapper's silent modes failed; 64 tables / 43 UQ / 117 FK / 84 CK / 83 indexes; seed data for all six roles.

---

## Phase 3 report — SQL Server functionality

1. **Phase:** 3 — Status **VERIFIED (implemented scope)**.
2. **Implemented**
   * **69 stored procedures** (13 sec, 18 cand, 5 hr, 4 rec, 14 staff, 6 time, 6 bill, 3 notify) covering the whole internal flow (hiring request → approval → job → approval → posting → application → screening → interview → feedback → offer → approval → acceptance → employee → onboarding) and the whole staffing flow (customer request → recruiter → submission → customer decision → external interview → contractor/placement/contract/rates/assignment → timesheet → approval/rejection/resubmission → invoice → payment), plus authentication support, registration, password reset, token revocation, candidate search.
   * **16 functions** (12 scalar, 4 inline table-valued): experience, contract duration, days to expiry, application age, time to hire, invoice balance, customer outstanding balance, candidate skills, candidate search, effective rate, CSV split (recursive CTE), number padding, role/customer/candidate/contractor lookups.
   * **13 DML triggers + 1 DDL trigger:** audit triggers (candidates, job requisitions, interviews, offers, contracts, timesheets, invoices), application status history, 5 append-only guards, schema-change audit. All multi-row safe (set-based `inserted`/`deleted` joins); actor captured through `CONTEXT_INFO`.
   * **11 views** in `report` (open requisitions, pipeline, candidate application status, upcoming interviews, pending offers, active employees, active contractors, expiring contracts, pending timesheets, customer invoices, recruiter performance). No view exposes a pay rate.
   * 8 sequences (business numbers), 3 table types (TVPs), 2 database roles (`tams_app_role`, `tams_report_role`) with least-privilege grants.
3. **Files created:** `database/03_Tables/05_Sequences.sql`, `06_StoredProcedures/00_Types.sql … 07_Security_Roles.sql` (8 files), `07_Functions/01_Functions.sql`, `08_Triggers/01_Triggers.sql`, `09_Views/01_Views.sql`, `10_SeedData/05_Sync_Sequences.sql`, `12_Tests/02_…Tests.sql`, `03_Permission_Tests.sql`; `scripts/database/TamsSql.ps1`, `Copy-Database.ps1`, `Test-Concurrency.ps1`, `Demo-Performance.ps1`, `Demo-BackupRestore.ps1`. **Modified:** `Run-DatabaseSetup.ps1` (functions before procedures), `Invoke-SqlScripts.ps1` (error line numbers).
4. **Commands executed:** `Run-DatabaseSetup.ps1 -IncludeTests` on `localhost` and on a brand-new database (clean build), `Test-Concurrency.ps1`, `Demo-Performance.ps1`, `Demo-BackupRestore.ps1`.
5. **Actual results** (details in `TEST_RESULTS.md`)
   * **Clean build from nothing:** every script folder in order, 0 failures, **247/247 tests** (64 + 167 + 16).
   * **Live database:** all suites pass; the Phase 3 suite passed **6 consecutive runs** after a flaky-test fix (167/167 each).
   * **Concurrency (real, two-connection, on a restored copy): 18/18** — blocking observed in `sys.dm_exec_requests`, lock timeout 1222, **deadlock detected (1205) with victim retry**, 4 isolation-level behaviours, no double payment, no double billing, no duplicate submission, optimistic concurrency 50006.
   * **Backup/restore: 8/8** — full backup + `RESTORE VERIFYONLY` + restore identical to source; **point-in-time restore** (full + log `STOPAT`) recovers the data from just before a simulated accident.
   * **Performance (measured):** index seek 165 reads vs forced scan 6,550 (40×); stale statistics → estimate 2,250 vs actual 151,500 → 464,568 reads/189 ms, refreshed → 9,327 reads/25 ms; table variable at compat level 130 → estimate 1 vs 100,000 actual, 302,269 reads, vs 4,351 reads at level 150.
6. **Defects found and fixed by the tests this phase** (all recorded, none hidden): notification de-duplication keys lacked the entity id (suppressed later events); notification `Body` NULL crash when a decision had no comment; security-role script ran before the table types existed (found by the clean build); a flaky test caused by `DATETIME2(0)` rounding up; test-design issues with `EXEC` arguments and with transactions doomed by trigger `THROW`.
7. **Build status:** SQL only (no .NET/Angular yet).
8. **Remaining / deferred (not claimed as done):**
   * Candidate education / experience / address maintenance procedures (skills are done) → with the candidate UI (Phase 5).
   * Document metadata procedures → Phase 8. Notification dequeue / mark-sent / retry procedures → Phase 9. Parameterised report procedures → Phase 10. Scheduled-maintenance procedures (expiry, purge, backups, index/statistics jobs) → Phase 11.
   * The application's SQL login: the instance is Windows-authentication only; mapping a login to `tams_app_role` is a Phase 4/15 deployment step (KI-015).
9. **Next phase:** Phase 4 — ASP.NET Web API 2 (.NET Framework 4.7.2, OWIN self-host, ADO.NET).

---

## Phase 4 report — ASP.NET Web API 2 backend

1. **Phase:** 4 — Status **VERIFIED**.
2. **Implemented**
   * **Solution** `backend/TalentAcquisition.sln` (SDK-style projects targeting .NET Framework 4.7.2, built with the dotnet SDK — decision D2): `Models` (DTOs whose property names equal procedure parameters, TVP attributes), `Common` (configuration, file logging, PBKDF2 hashing, password policy, HS256 JWT, SQL-error → HTTP mapping), `Data` (ADO.NET only: connection lease with `EXECUTE AS USER = 'tams_app_demo'` + `REVERT`, stored-procedure executor with deadlock retry, TVP building, row mapping, 14 repositories), `Business` (15 services: validation, shaping of multi-result reads), `API` (OWIN self-host, controllers, filters, middleware). The `Scheduler` project is deliberately absent until Phase 12 (no placeholder project).
   * **118 endpoints** across 18 controllers covering authentication, users/roles, audit/login history, scheduler job history, customers/departments/locations/sources/rate cards, candidates and skills, hiring requests, jobs and public postings, applications, interviews and feedback, offers, employees/onboarding, staffing requests and submissions, contractors and compliance, contracts/renewal/termination, assignments, timesheets, invoices and payments, notifications, and role dashboards. The as-built list is in `API_SPECIFICATION.md`.
   * **Security:** JWT HS256 with a 64-byte random secret from a git-ignored local file (`scripts/setup/New-LocalConfig.ps1`); every token's `jti` checked against `sec.AuthTokens` on each request (logout and deactivation revoke immediately); `alg` other than HS256 rejected; PBKDF2-SHA256 210,000 iterations; lockout after 5 failures for 15 minutes (429); one generic message for wrong password and unknown e-mail; constant-time dummy verification for unknown e-mails; deny-by-default global authorization filter (401/403 as JSON) **plus** the role and data-scope checks inside every procedure; caller identity always taken from the token; database access through the least-privilege `tams_app_demo` user (EXECUTE on procedures only).
   * **Pipeline:** correlation id on every response and error, model validation (400 with field details), SQL error mapping (50001→400, 50005→403, 50004→404, 50003/50006/2601/2627→409, 50002/547→422, 1205/1222→503, timeout→504, other→500 without SQL text), request-body limit (413), security headers (`nosniff`, `DENY`, `no-referrer`, `no-store`), CORS restricted to the configured Angular origin, daily access/error log file.
   * **Startup checks:** `TalentAcquisition.API.exe --check` validates configuration and database reachability; exit codes 2 (configuration), 3 (database unreachable), 4 (port bind).
3. **Files created:** `backend/**` (5 projects), `scripts/setup/New-LocalConfig.ps1`, `scripts/deployment/Run-BackendTests.ps1`, `tests/backend/TalentAcquisition.Tests/` (`Infrastructure.cs`, `AuthAndSecurityTests.cs`, `IsolationAndConcurrencyTests.cs`, `WorkflowTests.cs`). **Modified:** `database/06_StoredProcedures/08_Queries_Admin_Reference.sql`, `09_…`, `10_Dashboards.sql` (read procedures added for the API; `sec.usp_GetMe` and `report.usp_Dashboard` return a single result set), `database/12_Tests/04_Query_Scope_Tests.sql` (53 scope tests for the new read procedures).
4. **Commands executed:** `dotnet build` (0 warnings, 0 errors); `New-LocalConfig.ps1`; live run of the API on `http://localhost:5000/` with a smoke script against `TalentAcquisitionDB`; `Run-BackendTests.ps1` three times (each: backup → verify → restore `TalentAcquisitionDB_ApiTest` → `dotnet test` → drop the copy).
5. **Actual results** (details in `TEST_RESULTS.md`)
   * **API integration suite: 26/26 on three consecutive runs** (~45 s each). The suite hosts the real API in-process and talks to it over HTTP; nothing is mocked.
   * Both business models pass end to end **through the API** with the real role accounts: hiring request → … → active employee (7 onboarding tasks), and customer request → … → contract → two weeks of timesheets (with a rejection and resubmission) → invoice **116,000 + 18 % = 136,880** → partial and final payment → Paid.
   * Live database unchanged by the test runs (15 candidates / 3 invoices / 445 audit rows before and after each run).
6. **Defects found and fixed this phase:** `INSERT … EXEC` cannot capture procedures with several result sets → `sec.usp_GetMe` and `report.usp_Dashboard` reshaped to one result set and `sec.usp_GetMyPermissions` added; **error 596 "session is in the kill state"** when a pooled connection was returned while still impersonating → the connection lease now `REVERT`s before release and clears the pool if that fails; two wrong expectations in the new scope tests corrected. One API test read rates from the wrong part of the contract response (test bug, API correct) → fixed.
7. **Build status:** `dotnet build backend/TalentAcquisition.sln` — succeeded, 0 warnings, 0 errors (6 projects incl. tests).
8. **Remaining / not claimed:**
   * E-mail ownership verification before a self-registration links to an existing candidate (KI-014) → Phase 9, when the mock mailer exists.
   * The API process still connects as the developer's Windows account and narrows itself with `EXECUTE AS USER`; a dedicated low-privilege identity is a deployment step (KI-015) → Phase 15.
   * Document upload/download endpoints → Phase 8; report endpoints → Phase 10; notification sending → Phase 9; per-IP rate limiting → Phase 13 (KI-022).
9. **Next phase:** Phase 5 — Angular 20 frontend with the six role dashboards.

---

## Phase 5 report — Angular frontend

1. **Phase:** 5 — Status **COMPLETED** (built, unit-tested, and exercised live for all six roles). Not claimed: a click-through of *every* action — the complete workflows through the UI are Phases 6 (internal) and 7 (staffing).
2. **Implemented** (`frontend/`, Angular 20.3)
   * Sign-in, candidate self-registration (auto sign-in), forgot / reset password (reset page reads the token from the link), account page with change password, notifications page (mark read / all read; unread count in the top bar).
   * **Six role areas: 48 menu entries served by 24 page components** (`areas.ts`; plus 4 sign-in pages and 2 shared pages), each with a dashboard of SQL-computed metrics plus the role's main worklist:
     * **Candidate** — find jobs (search, details with skills, apply with cover note and source), my applications (status timeline, interviews, offers, withdraw; contract opportunities submitted to customers), interviews, offers (accept/decline before expiry), profile (edit with optimistic concurrency, skills add/update/remove).
     * **Contractor** — weekly timesheet editor (assignment + Monday-week picker, regular/overtime/billable/notes per day, loads an existing week, save draft, save-and-submit, rejection reason shown, locked once submitted), contracts (pay rate only), profile with assignments and compliance records.
     * **Customer** — staffing requests (raise, cancel, submissions with shortlist / select / reject-with-reason; contact details revealed only after shortlisting), interviews (schedule with own panel, reschedule, cancel, feedback), timesheet approvals (approve, reject with reason, entries and decision trail), contracts (bill rate only), contractors, invoices with outstanding balance.
     * **Recruiter** — jobs (create with skills from an approved hiring request, publish, close), application pipeline (filters, shortlist, valid next statuses only, schedule interviews with a staff panel, create offers), candidate master (search by text/skills/experience/status, add, edit, skills), interviews, offers (send), staffing requests (accept/assign, submit candidates within the customer's maximum, withdraw, schedule, create contract), contractors & compliance (register contractor, expiring filter), contracts (renew, terminate, add assignment), timesheets, invoices (generate, issue, record payment, void).
     * **HR Manager** — hiring requests (create/submit, approve/reject others' requests), job approvals, offer approvals (not own), employees & onboarding (complete / waive tasks; last task activates the employee), applications, candidates, interviews, departments.
     * **Administrator** — users & roles (create staff/customer users, activate/deactivate, grant/remove staff roles), customers & rate cards, departments, audit log (filters, before/after values) and sign-in history, scheduled-job definitions and run history, plus hiring requests, jobs, staffing requests, contracts and invoices.
   * **Backend additions for the UI:** `GET /api/v1/staff-directory` (`sec.usp_ListStaffDirectory`: active staff, names and staff roles only, no e-mail) for interview panels; submissions list returns `ContractNo` so "Create contract" is offered only once; **customers no longer see Draft invoices** (list and by id) until the recruiter issues them; HR dashboard label corrected to "Headcount (incl. onboarding)".
   * Scripts: `scripts/database/New-TestCopy.ps1` (disposable DB copy with one random test password, written to git-ignored `test-credentials.local.md`; `-Drop` removes it), `.claude/launch.json` (dev server).
3. **Commands executed:** `ng new` (Angular CLI 20.3.43), `ng build` (production), `ng test --browsers=ChromeHeadless`, `New-TestCopy.ps1`, API on the copy + `ng serve` with the browser pane, `Run-DatabaseSetup.ps1 -DatabaseName TAMS_CleanBuild5 -IncludeTests` (dropped afterwards), `Run-BackendTests.ps1`.
4. **Actual results** (details in `TEST_RESULTS.md`): production build clean (0 warnings); unit tests **23/23**; API suite **26/26**; clean database build with all SQL suites **64 + 167 + 16 + 57 = 304/304**; live browser verification of all six roles with real actions (below), no console errors after fixes.
5. **Defects found and fixed during live verification:** customers could see Draft invoices (procedures fixed + 2 scope tests); a visually hidden table header made the page scroll sideways (CSS); checkbox styling in dialogs; dates wrapping in narrow tables; phone-width top bar 7 px too wide and no role switching on phones; **Angular effects tracked the auth token read during requests, so signing out fired two requests that got 401** (fixed with `untracked`; regression test proven to fail without the fix); misleading HR metric label.
6. **Build status:** `ng build` OK; `dotnet build` OK (0 warnings).
7. **Remaining / not claimed:** UI walkthrough of job creation → publish → interview → offer → onboarding (Phase 6) and of contract → invoice → payment (Phase 7); document upload (Phase 8); charts and report pages (Phase 10); automated browser E2E (Phase 14); serving the built UI from the API host (Phase 15). Candidate education/experience self-service still deferred (KI-019).
8. **Next phase:** Phase 6 — internal recruitment end to end through the UI.

---

## Phase 6 report — Internal recruitment end to end through the UI

1. **Phase:** 6 — Status **VERIFIED**.
2. **How it was run:** API + Angular dev server against a disposable copy (`New-TestCopy.ps1 -Target TalentAcquisitionDB_E2E`, dropped afterwards). Four browser tabs, each signed in as a different real account (session storage is per tab): **Vikram** (HR Manager, Engineering head), **Anita** (HR Manager), **Priya** (Recruiter) and a **new candidate who registered through the UI** (Nikhil Rao). Every step below was done by clicking in the UI; nothing was called directly except one documented SQL edit that moved the interview's start time into the past (an interview cannot be waited for).
3. **The walk-through (all OK):**
   | # | Who | Action in the UI | Observed |
   |---|---|---|---|
   | 1 | Vikram | New hiring request "Platform Engineer (E2E)", Engineering, Bengaluru, headcount 1, budget 25 L, submit now | ER-2026-016 *Submitted*; **no Approve button for his own request** (shown on Anita's) |
   | 2 | Anita | Approve with comment | *Approved*; approval row with her name; "Create job" offered |
   | 3 | Priya | New job from ER-2026-016 with 3 skill rows (Kubernetes req 2 y, Go req 2 y, CI/CD optional), salary 18–24 L, closes 28 Feb 2027 | JOB-EN-2026-011 *Pending approval*; **no Approve for the recruiter** |
   | 4 | Anita | Approve job | *Approved*; "Publish" appears for Priya |
   | 5 | Priya | Publish via LinkedIn | *Open*, posting #16 Published |
   | 6 | Nikhil | Register (weak passwords refused earlier in Phase 5), find the job, apply with cover note + source | *Applied*; job shows "You have applied" |
   | 7 | Priya | Shortlist with note; schedule round 1 Technical (computed round 1), panel Vikram + Priya, meeting link | *Shortlisted* → *Interview*; invitation queued |
   | 8 | Priya | Open the interview before it starts | Reschedule/Cancel offered, **no "Give feedback"** |
   | — | (test clock) | `UPDATE cand.Interviews SET StartsAt/EndsAt` 3 h / 2 h in the past, on the copy only | — |
   | 9 | Priya, then Vikram | Feedback 4 "Yes" and 5 "Strong yes" | After the 2nd: interview **Completed automatically**; Reschedule/Cancel gone |
   | 10 | Nikhil | Open his interview | Sees time/link only; the raw API response has `"feedback": []` (server-side, not just hidden) |
   | 11 | Priya | Change status (only Selected / Shortlisted / Rejected offered from Interview) → Selected | history updated; "Create offer" appears |
   | 12 | Priya | Create offer (designation, start +30 d, expiry +7 d prefilled; salary 22 L) | OFR-2026-020 *Pending approval* |
   | 13 | Anita | Approve offer | *Approved*; "Send to candidate" for Priya |
   | 14 | Priya | Send | *Sent* |
   | 15 | Nikhil | Notifications: Screening, Shortlisted, Interview invitation, Selected, Offer (5) — then Accept | *Accepted*; employee EMP-0010 created in the same transaction |
   | 16 | Anita | Onboarding: waive "IT equipment" (reason **required** — refused without one), complete the other 6 | 7/7; toast "the employee is now Active"; history "Hired through offer OFR-2026-020" |
4. **Database trail check** — new `scripts/testing/Verify-InternalWorkflow.ps1` (read-only, 14 checks): **14/14 PASS** — request approved by a different HR manager, job approved by someone other than its creator and now *Filled*, 3 skills (2 required), posting closed automatically, application history `Applied|Screening|Shortlisted|Interview|Selected|OfferStage|Hired`, 2 panel members with exactly one feedback each, offer approval by a non-creator, employee *Active* with the department head as manager, 6 completed + 1 waived task with notes and who/when, 5 candidate notifications incl. the invitation, onboarding notice to HR, audit rows naming every acting user (the only unattributed row is the test-clock edit, as expected).
5. **Defects found and fixed (each re-verified):**
   * **Interview lead ignored the order of selection** — the dialog said "the first selected is the lead" but the procedure chose the lowest user id (Priya instead of Vikram). Fixed: `cand.usp_ScheduleInterview` takes `@LeadUserId` (must be on the panel, else 50001); the API defaults it to the first listed interviewer. Re-verified in the UI (round 3: Vikram ticked first → lead) and by the API suite (lead assertion + lead-not-on-panel → 400).
   * New-job picker listed hiring requests whose headcount was already fully planned → filtered, with an explanatory hint.
   * "HRManager" shown un-spaced in panel pickers → `humanize` handles acronyms (unit test added).
   * Application status `OfferStage` missing from the pipeline filter and without a badge colour → added.
   * (Check-script fixes, not product defects: `>` was XML-escaped in my history string; the audit check now states the expected test-clock exception explicitly.)
6. **Regression after the fixes:** clean database build **304/304**; Phase 3 suite 167/167; scope 57/57; API **26/26**; frontend unit **24/24**; production build clean; no console errors in the four tabs except five 401s caused by a stale Phase 5 session from a dropped database (the app correctly sent that tab to sign-in).
7. **Not covered here:** e-mail delivery of the queued notifications (Phase 9); interview reminders (Phase 12). Interview invitation subjects state the time in UTC (KI-028).
8. **Next phase:** Phase 7 — external staffing end to end through the UI.

---

## Phase 7 report — External staffing end to end through the UI

1. **Phase:** 7 — Status **VERIFIED**.
2. **How it was run:** API + Angular dev server against a disposable copy (`TalentAcquisitionDB_E2E`, dropped afterwards); one browser tab per person: **Kabir** (Crestline customer), **Rahul** (Recruiter) and **Tara Menon**, a candidate who **registered through the UI** during the run and became the contractor. Every action was a click in the UI, except one documented SQL edit moving the customer interview's start time into the past.
3. **The walk-through (all OK):**
   | # | Who | Action in the UI | Observed |
   |---|---|---|---|
   | 1 | Kabir | Sees only Crestline's request; raises "Data Engineer (E2E)", start 2 Nov, 6 months, **max bill rate 1,500/h** | CR-2026-014 *Open*, customer taken from his login |
   | 2 | Rahul | Accept (assign to self); no Accept offered on Priya's CR-2026-004 | *InReview*, assigned to Rahul |
   | 3 | Tara | Register; edit profile (title, employer, 5 years) | saved with optimistic concurrency |
   | 4 | Rahul | Submit Tara at 1,450/h (type-ahead picker), **re-submit Tara → refused "already been submitted" (409) inside the dialog**, submit Karan Joshi at 1,400/h | 2 submissions, request *Sourcing* |
   | 5 | Kabir | Contact details hidden; reject Karan (**empty reason refused**, then with reason); shortlist Tara → her e-mail appears | Karan *Rejected* (no further actions), Tara *Shortlisted* |
   | 6 | Kabir | Schedule a customer interview with his own panel (only Crestline users offered) | submission *Interview* |
   | — | (test clock) | interview start/end moved 3 h / 2 h into the past, copy only | — |
   | 7 | Kabir | Feedback 5 "Strong yes" → interview *Completed*; Select Tara with a comment | *Selected* |
   | 8 | Rahul | Create contract (role, start 2 Nov, end +6 months, bill 1,450 prefilled, customer max shown): **bill 1,550 → refused "exceeds the customer's maximum"**; **pay 1,600 > bill → refused**; pay 1,100 / bill 1,450 → **CON-2026-012** | request *Filled*, submission shows the contract no.; "Create contract" no longer offered |
   | 9 | (rates) | Contracts page per party | Kabir: **bill 1,450 only**; Rahul: pay 1,100 + bill 1,450; Tara: **pay 1,100 only** |
   | 10 | Tara | Without signing out, gains the Contractor role (role switcher Candidate / Contractor) | see defect D1 |
   | 11 | Tara | Week of 2 Nov: 5 × 8 h, save & submit; week of 9 Nov with Friday 12 h (44 h), submit | both *Submitted*, locked |
   | 12 | Kabir | Approve 2 Nov; reject 9 Nov with reason | decision trail shows both |
   | 13 | Tara | Sees the reason, corrects Friday to 8 h (40 h), resubmits | *Submitted* |
   | 14 | Kabir | Approve | trail: Rejected (with reason) → Approved |
   | 15 | Rahul | Generate invoice for Crestline (default period 19 Oct–15 Nov, 18 %) | Draft **INV-2026-0022: 116,000 + 20,880 = 136,880**, 10 lines all at 1,450 |
   | 16 | Kabir | Invoices page | **draft not visible**, balance 0 |
   | 17 | Rahul | Issue | *Issued*, due 19 Dec (30-day terms); Kabir now sees it, balance 136,880 |
   | 18 | Rahul | Pay 36,880 (bank transfer) → *PartiallyPaid*, Void no longer offered; **100,000.01 refused (max = balance)**; 100,000 by cheque | *Paid*; Kabir's balance 0 |
4. **Database trail check** — new `scripts/testing/Verify-StaffingWorkflow.ps1` (read-only, 14 checks): **14/14 PASS** — request by a customer user and Filled; one Selected + one Rejected-with-reason submission; customer decisions Shortlist|Select by the customer's own user; external interview owned by the customer with only its users on the panel and full feedback; contractor linked to the candidate's own login with both roles; contract pay 1,100 / bill 1,450 within the maximum, one rate row, one assignment; **the two refused contract attempts left no placement/contract behind**; two 40 h weeks *Invoiced*, approvals by the customer; rejection kept in the append-only trail before the approval; invoice arithmetic and every line at the bill rate tied to this assignment; two payments equal to the total, balance 0; notifications (request, decision, contract, timesheet rejected/approved); audit rows attributed (only the test-clock edit unattributed); nothing linked to another customer.
5. **Defects found and fixed (each re-verified):**
   * **D1 — roles were frozen in the sign-in token (security-relevant).** After the contract made Tara a contractor, the UI (which reads `/auth/me` from the database) showed the Contractor area, but the API refused her with 403 because it authorised from the roles captured in her token. The same staleness meant a role **removed** by an administrator kept working until the token expired. Fixed: `sec.usp_ValidateToken` (already run on every request) now returns the user's **current** roles and the API authorises from those. Re-verified: Tara's unchanged session then listed her contract; new API test `Role_changes_apply_to_existing_tokens_at_once` (grant works and removal stops access with the same token) and an extra assertion in the staffing API test. (Earlier in this phase I had told you in chat that the server re-reads roles on each request; that was not true until this fix.)
   * D2 — contractor rejection banner printed a doubled full stop after the customer's reason → quoted instead.
   * D3 — payments showed the raw code "BankTransfer" → "Bank Transfer".
   * D4 — "Rejection reason" column kept showing the last reason after resubmission without saying so → "Last rejection reason".
   * Not defects: an early read of the type-ahead list and of the timesheet total happened before Angular re-rendered; re-reading showed correct values.
6. **Regression after the fixes:** clean database build **304/304**; API **27/27** (new role-change test); frontend unit **24/24**; production build clean; console errors in the tabs were only the deliberate refusals (409 duplicate submission, two 422 contract refusals) and the pre-fix 403.
7. **Not covered here:** e-mail delivery of the queued notifications (Phase 9); timesheet reminders and contract-expiry jobs (Phases 11–12); compliance document upload (Phase 8).
8. **Next phase:** Phase 8 — document management (done, see below).

---

## Phase 8 report — Document management

1. **Phase:** 8 — Status **VERIFIED**.
2. **What was built:**
   * **Database** (`06_StoredProcedures/11_Documents.sql`): `doc.fn_CanManageOwner` (who may upload or delete for an owner) and `doc.fn_CanAccessDocument` (who may read a file). `doc.usp_AddDocument`, `usp_ListDocuments`, `usp_GetDocumentForDownload` and `usp_DeleteDocument` (soft delete). `staff.usp_DecideCompliance` (Verify/Reject). Audit triggers on `doc.Documents` and, new this phase, on `staff.ComplianceRecords`. EXECUTE on schema `doc` for `tams_app_role`; the application still cannot SELECT the table directly.
   * **Who can read what** (enforced in the database; the UI only hides buttons):
     * Candidate files: staff, the candidate, and a customer, but only **résumés** of candidates submitted to it at Shortlisted, Interview or Selected.
     * Contractor files: recruiters and the contractor.
     * Employee files: HR and the employee.
     * Contract files: recruiters, the contract's customer and its contractor.
     * Deleted files: nobody.
   * **File handling** (`TalentAcquisition.Common/Documents.cs`):
     * Only .pdf/.doc/.docx/.png/.jpg/.jpeg, and the content must match the extension (magic bytes; a .docx must be a real Word package).
     * At most 10 MB. Uploads without `Content-Length` get 411, oversized ones 413, before the body is read.
     * The original name is cleaned of paths and reserved characters. The file is stored under a random name `{store}\{2 hex}\{32 hex}{ext}`, outside any served folder.
     * SHA-256 and size are recorded and **re-checked on every download**: a changed or missing file gives 500, never wrong bytes.
     * Downloads are sent as attachments with `nosniff` and a `sandbox` CSP.
     * A failed database insert deletes the file it just wrote.
   * **API:** `POST /documents` (multipart), `GET /documents?ownerType&ownerId`, `GET /documents/{id}/download`, `DELETE /documents/{id}`, `POST /compliance/{id}/decision`.
   * **UI:** one reusable documents panel, placed on:
     * the candidate's own profile and the staff candidate view;
     * the contractor's profile, with "Proof for" a compliance record;
     * the HR employee view;
     * contracts ("Signed contract": staff upload, the customer and contractor read).

     Two more places use it:
     * A **Résumé** action on staffing submissions, which customers only get once they have shortlisted the candidate.
     * **Proof / Verify / Reject** on the recruiter's compliance tab. A rejection needs a reason, and a verification needs an attached proof.

     The browser pre-checks type and size; the server checks again.
3. **Live verification** (API and Angular on the disposable copy `TalentAcquisitionDB_E2E`, temp document store, both deleted afterwards). Files were attached in the page (the OS picker can't be driven), and download clicks were captured in the page, so nothing was written to disk.
   | # | Who | Action | Observed |
   |---|---|---|---|
   | 1 | Rohan (candidate) | Upload an `.exe` renamed to `.pdf` | refused: "The file content does not match its .pdf extension" |
   | 2 | Rohan | Upload a real PDF as main résumé; download it | name "Rohan Gupta CV 2026.pdf", 111 bytes, `%PDF-1.4` |
   | 3 | Arjun (customer) | Résumé action on Rohan's shortlisted submission | same 111-byte file |
   | 4 | Arjun | Résumé on Ravi (no file) / rejected Aditya | toast "has no résumé on file yet" / action not offered |
   | 5 | Ravi (contractor) | Attach "Ravi NDA signed.pdf" as proof for his NDA record | record Verified → **Pending**, Proof "Attached" |
   | 6 | Rahul (recruiter) | Compliance tab: Proof → Verify with a note | 125-byte PDF downloaded; record **Verified**; COMPLIANCE_DECISION queued |
   | 7 | Rahul | Reject Sneha's NDA with an empty reason, then with a reason; reject her expired Insurance | empty refused in the dialog; both **Rejected** with the reason shown |
   | 8 | Rahul | Upload the signed copy to Ravi's contract CON-2026-001 | listed under "Signed contract" |
   | 9 | Ravi | Open his contract | can download it (156 bytes, valid PDF); no Upload or Delete offered |
   * No console errors in any tab.
4. **Defects found and fixed:**
   * **D1 — compliance decisions were not audited.** `staff.ComplianceRecords` had no audit trigger, so after steps 6–7 the audit log had no record of who verified or rejected a record. (The row's `VerifiedByUserId` only holds the latest decision.) Added `staff.trg_ComplianceRecords_Audit`, and test **D19a** checks for the audit row and its actor. Re-verified live: the Insurance rejection in step 7 is in `audit.AuditLogs` with Rahul as the actor.
   * D2 — the documents table showed a "Main résumé" column for contractor, employee and contract files. It now appears only for candidates.
5. **Tests:**
   * Clean database build from nothing: **334/334** (64 + 167 + 16 + 57 + **30 document tests**).
   * API **35/35**, including 8 new document tests: round trip and headers; disguised or disallowed files leave nothing behind; 413 and 415; another user gets 404 and no file is left behind; a customer reads only shortlisted résumés; tampering is detected; soft delete; compliance proof and decision.
   * Frontend unit **26/26**. Production build clean (initial bundle 369 kB).
6. **Not covered:**
   * There is no antivirus or malware scan of uploaded files.
   * Soft-deleted files stay on disk until a purge job exists (Phase 11).
   * The document store is not in the database backups (Phase 11).
   * HR employee-document upload was checked by the SQL and API suites, not clicked through live.
   * See KI-031–KI-034.
7. **Next phase:** Phase 9 — notifications (done, see below).

---

## Phase 9 report — Notifications

1. **Phase:** 9. Status **VERIFIED**.
2. **What was built:**
   * **Delivery** (`06_StoredProcedures/12_Notifications.sql`):
     * `notify.usp_ClaimBatch` gives due messages to a worker under a lease. It uses `UPDLOCK, READPAST`, so two workers never get the same message.
     * `usp_MarkSent` / `usp_MarkFailed` record the outcome of exactly the attempt that was handed out. They refuse to overwrite a newer attempt.
     * Failed attempts are retried after 1, 2, 4 and 8 minutes; after the 5th failure the message is *Failed*.
     * A worker that disappears loses its lease after 5 minutes. The lost attempt is recorded and the message is retried.
     * Messages to accounts deactivated after queuing are *Cancelled*, not sent.
     * Every attempt is in `notify.NotificationHistory`.
   * **Sender:** new console project `backend/TalentAcquisition.Scheduler` (`process-notifications [--max N]`, `--check`). It uses `NotificationProcessor` and the **mock provider** `PickupDirectoryMailSender`: `System.Net.Mail.SmtpClient` in pickup-directory mode writes each e-mail as an `.eml` file to `storage\mail-outbox`, and nothing leaves the machine.
     * Each e-mail has a plain-text part and an HTML part. In the HTML part everything is HTML-encoded and links are clickable.
     * Subjects and names are reduced to one line, the encoding is UTF-8, and headers `X-TAMS-Notification-Id`, `Message-ID` and `Auto-Submitted` are set.
     * The log holds ids and templates only, never addresses or text.
     * Task Scheduler registration is Phase 12. Until then the sender is run by hand.
   * **Sign-in links (KI-021):** password-reset and confirmation e-mails are e-mail only (not in the in-app list or unread count). Their text, which holds the one-time link, is **erased from the database** once sent, given up or cancelled, and an administrator cannot re-send them.
   * **E-mail ownership (KI-014):**
     * A self-registered account starts unconfirmed and cannot sign in until the link e-mailed to it is used (`POST /auth/verify-email`; single use, 24 hours, stored only as a SHA-256 hash).
     * A recruiter-created candidate record with the same address is linked **only after** confirmation. Knowing someone's address no longer gives access to their record.
     * Completing an e-mailed password reset also confirms the address, so the real owner can take over an account someone else registered with their address.
     * `POST /auth/resend-verification` always gives the same answer and creates at most one link per minute.
     * A sign-in refused for an unconfirmed address is logged but does not count towards lockout. It is reported (403 `email_unverified`) only when the password was right.
     * Accounts created by an administrator, seeded accounts, and accounts that existed before this phase count as confirmed. The upgrade sets `EmailVerifiedAt = CreatedAt` once.
   * **Times in IST (KI-028):** `dbo.fn_BusinessTime` writes notification times as "20 Nov 2026, 10:00 IST"; the data stays UTC. Interview invitations now also give the end time, the mode and the location or link.
   * **API:**
     * `POST /auth/verify-email` and `POST /auth/resend-verification`.
     * `POST /auth/register` now returns `{ email, verificationRequired, message }` and no longer signs in.
     * `GET /admin/notifications`, `GET /admin/notifications/{id}/history`, `POST /admin/notifications/{id}/retry` and `POST /admin/notifications/{id}/cancel`. These never return message bodies.
   * **UI:**
     * Registration ends on a "Check your e-mail" page.
     * Sign-in explains an unconfirmed address and offers "Send a new confirmation link".
     * `/verify-email` needs a click to confirm, so mail scanners that open links cannot use up the token.
     * The in-app list shows each message's e-mail status ("Sent", "Queued", …) and its text when selected (marking it read).
     * Administrator → **E-mail queue**: status filter, search, attempts, next try, last error, attempt history, "Send again" (Failed/Cancelled, not sign-in links) and "Don't send" (Pending).
3. **Live verification:** API, Angular and the console sender ran against a throwaway copy (`TalentAcquisitionDB_E2E`), with the outbox in a temporary folder. Everything was deleted afterwards.
   | # | Who | Action | Observed |
   |---|---|---|---|
   | 1 | New candidate Kavya | Register in the UI | "Check your e-mail" page; no sign-in |
   | 2 | Kavya | Sign in before confirming | refused with an explanation and a "Send a new confirmation link" button (the only 403 in the console) |
   | 3 | Sender | `process-notifications` | `sent=1`; the `.eml` holds the confirmation link |
   | 4 | Kavya | Open the link | confirm page; **token still unused in the database** until the click |
   | 5 | Kavya | Click "Confirm", sign in | "Your e-mail address is confirmed"; candidate dashboard; the confirmation is not counted as unread |
   | 6 | Divya | Notifications page | only her ordinary message (her reset-link e-mail is not listed); E-mail "Sent"; selecting it shows the text, including a `<script>` typed by a "recruiter", as plain text, and marks it read |
   | 7 | Sender (outbox below a file) | `process-notifications` | `failed=1`; message Pending, attempt 1/5, next try +1 min |
   | 8 | Admin | E-mail queue | the message with the provider's IOException, its attempt history, only "Don't send" offered |
   | 9 | Admin | "Don't send", then "Send again" | Cancelled, then Pending 0/5; both actions in the audit log under the administrator |
   | 10 | Sender (working outbox) | `process-notifications` | `sent=1`; history: Failed, then Sent |
   * An earlier smoke run of the sender produced a UTF-8 subject; the recruiter's `<script>` encoded in the HTML part; clickable links; and the reset link's text erased from the database after delivery.
4. **Defects found and fixed:**
   * D1: the registration page showed the outbox folder as "storagemail-outbox" (a backslash in an Angular template was taken as an escape). Fixed, and a unit test now checks the text.
   * D2: the admin "Cancel" action opened a dialog with both "Cancel" and "Cancel e-mail". Renamed to "Don't send".
   * Found while testing, not caused by Phase 9: Phase 3 test **F06** expected exactly "20 days to expiry" for a contract seeded relative to the day the database was built, so it failed on any later day (KI-020). It now compares with the calendar.
5. **Tests:**
   * The new suite `12_Tests/06_Notification_Tests.sql` passes **40/40**: queue, back-off, lost leases, deactivated recipients, erased links, administration, confirmation, IST, least privilege.
   * Phase 3 test S04 was rewritten: linking now waits for confirmation.
   * A clean build into a new database passes **374/374** (64 + 167 + 16 + 57 + 30 + 40).
   * API **41/41**. Six new tests:
     * an impostor cannot take over a recruiter-created candidate, and the real owner takes over through "Forgot password";
     * resend gives the same answer for every address and the new link works;
     * a failed delivery is retried with back-off and then delivered safely encoded;
     * **four workers at once deliver 40 messages exactly once each**;
     * the admin queue: no bodies, retry and cancel;
     * sign-in links are absent from the in-app list.

     Existing tests changed:
     * Registration and password-reset tests now read the delivered `.eml`, as a person would.
     * The workflow test checks the interview invitation is in IST and delivered.
   * Frontend unit **33/33**, 7 new: registration does not sign in; the resend control; no confirmation without a click; expired links; queue actions; status labels. The production build is clean.
6. **Not covered:**
   * The sender is not on a schedule yet (Phase 12): messages wait until `process-notifications` runs.
   * There is no real SMTP server (by design: mock provider).
   * Outbox files and old queue rows are not purged (Phase 11).
   * The queue procedures can be run by the application role (KI-039).
   * See KI-037–KI-041.
7. **Next phase:** Phase 10, reporting (done, see below).

---

## Phase 10 report — Reporting

1. **Phase:** 10. Status **VERIFIED**.
2. **What was built:**
   * **19 reports**, exactly the list in the requirements:

     | Category | Reports | Who can run them |
     |---|---|---|
     | Recruitment | open requisitions, applications by status, recruitment pipeline, candidate sourcing, interview conversion, offer acceptance, time to hire, recruiter performance | Recruiter, HR Manager, Administrator |
     | Staffing | customer staffing requests, candidate submissions, placements, active contractors, expiring contracts, pending timesheets, customer invoices, outstanding payments | Recruiter, Administrator; a Customer for **its own company only** |
     | HR | employee onboarding, department hiring, approved and pending requisitions | HR Manager, Administrator |

     Candidates and contractors have no reports.
   * **Database** (`06_StoredProcedures/13_Reports.sql`):
     * Each report is one procedure, and all share the parameters (`@ActorUserId, @FromDate, @ToDate, @CustomerId, @Days`).
     * Each procedure checks the caller's role itself through `report.usp_ReportScope`. That helper also validates the dates (the start not after the end, years 2000–2100) and resolves the customer scope: a customer always gets its own company, and another company's id is "not found".
     * The catalog table `report.ReportDefinitions` (maintained by MERGE in the same script) holds each report's roles, the date it filters, its options and its chart.
     * `report.usp_ListReports` returns the caller's reports. `report.usp_RunReport` is the single entry point: unknown code → 404, wrong role → 403, then it runs the catalog's procedure.
     * Pay rates and margins are returned to staff only. A customer's placements report has a different column set, with the bill rate only.
     * Customers never see Draft invoices.
     * Definitions are shared, so reports agree with each other and with existing functions: time to hire uses the same rule as `cand.fn_TimeToHireDays`, and outstanding payments the same population as `bill.fn_CustomerOutstandingBalance`.
   * **API** (`ReportsController`): `GET /reports` (catalog), `GET /reports/{code}?from&to&customerId&days`, and `GET /reports/{code}/csv`.
     * The JSON gives each column a key, a label ("Overdue 1 to 30 days", "Hire rate %") and a display type (money, percent, hours, date, datetime, number).
     * At most 10,000 rows are returned; a flag says when more exist.
     * The CSV is UTF-8 with BOM, quoted per RFC 4180, and **formula-safe**: a text cell starting with `= + - @` is prefixed with `'`, so a value a customer typed cannot run as a spreadsheet formula. It is an attachment, with `no-store` caching and a sandbox CSP.
   * **UI:**
     * A **Reports** menu item for Recruiter, HR Manager, Customer and Administrator. The list shows only the reports the API offers that role.
     * Each report has its own address (`?report=code`), date filters labelled with what they filter, a customer picker (staff only), a days field (expiring contracts) and **Export CSV**.
     * A bar chart: plain HTML/CSS bars, no library and no external requests. Sum and count aggregation come from the catalog.
     * The table shows status badges and formatted money and percentages.
     * **Each of those four dashboards shows one report chart:** Recruiter, applications by status; HR, department hiring; Customer, its staffing requests; Administrator, recruiter performance.
3. **Gate, "reports match SQL counts"** (`12_Tests/07_Report_Tests.sql`, 28 checks, all passing): every one of the 19 reports, run through `report.usp_RunReport`, matches an independent query on the base tables, or an existing view or function computed another way:
   * applications by status, overall and for a one-day range;
   * the pipeline per stage against `vw_RecruitmentPipeline`;
   * sourcing totals;
   * interviews and feedback;
   * offers by outcome;
   * time to hire against `cand.fn_TimeToHireDays`;
   * recruiter performance against `vw_RecruitmentPerformance`;
   * requests, submissions, placements with their margin;
   * active and expiring contracts against their views;
   * pending timesheets and their hours;
   * invoice balances;
   * outstanding amounts against `bill.fn_CustomerOutstandingBalance`, with the ageing buckets adding up;
   * onboarding tasks;
   * department hires against the time-to-hire report;
   * hiring requests by status.
4. **Live verification:** API and Angular ran against a throwaway copy, deleted afterwards.
   | # | Who | Action | Observed |
   |---|---|---|---|
   | 1 | Rahul (Recruiter) | Dashboard | "Applications by status" chart under the worklist |
   | 2 | Rahul | Reports | 16 reports (recruitment + staffing), no HR |
   | 3 | Rahul | Placements | bill rate, pay rate, margin (e.g. 1,700 / 1,250 → 26.5 %); chart of placements by customer |
   | 4 | Rahul | Filter Apex, Export CSV (captured in the page, not written to disk) | table and file contain only the Apex row; labelled header, ISO dates |
   | 5 | Rahul | Applications by status, 10–20 Nov | 2 of 11, the same as a direct count on the copy; an inverted range is refused before any request |
   | 6 | Arjun (Customer) | Dashboard | chart of Apex's own staffing requests |
   | 7 | Arjun | Placements; Outstanding payments | only Apex, **no pay rate or margin**, no customer picker; outstanding ₹80,240 |
   | 8 | Arjun | Typed `?report=pipeline` | "That report is not available for your role." |
   | 9 | Anita (HR) | Dashboard; Reports; Onboarding | department-hiring chart; 8 + 3 reports, no staffing; EMP-0001 2/7 tasks (28.6 %), next task and due date |
   | 10 | Admin | Dashboard; Reports | recruiter-performance chart; all 19 in three groups |
   | 11 | Admin | Interview conversion at phone width (375 px) | see D1; after the fix the labels are 12 px and nothing overflows (the table scrolls inside its box) |
   * The console showed four 401s from the stale session of the previous run (correctly sent to "session ended") and no other errors. The API log of this run has no 403.
5. **Defect found and fixed:** D1, the first chart was a scaled SVG. At phone width its text shrank to about 6 px. It was replaced by HTML/CSS bars, whose text keeps its size; the unit tests were updated.
6. **Tests:**
   * A clean build into a new database passes **402/402** (64 + 167 + 16 + 57 + 30 + 40 + **28**).
   * API **47/47**, with 6 new report tests:
     * the catalog per role, and 403 for candidates and contractors;
     * all 19 reports run, with labelled, typed columns;
     * figures match the database, including date ranges;
     * a customer sees only its own company in all 8 staffing reports, a forged `customerId` gives 404 for each, and pay appears in neither the JSON nor the CSV;
     * roles, codes and parameters are validated;
     * the CSV export is safe, including a `=HYPERLINK(...)` title.
   * Frontend unit **38/38**, 5 new: column-name casing identical to the API; bars per row, count and sum, capped at 25; no bar for zero or negative values; the page runs the chosen report with its filters and refuses an inverted range; "not available for your role".
   * The production build is clean.
7. **Not covered:**
   * Reports query live data on every run; there is no snapshot. Their performance on large volumes belongs to Phase 13.
   * The daily summary table is filled by a Phase 11 Agent job, and the e-mailed daily report comes in Phase 12.
   * There is no PDF or Excel export: CSV opens in Excel.
   * Running a report is logged by the API but not written to the audit table.
   * See KI-042–KI-045.
8. **Next phase:** Phase 11, SQL Server Agent jobs (done, see below).

---

## Phase 11 report — SQL Server Agent jobs

1. **Phase:** 11. Status **VERIFIED**.

   **Installed on 2026-11-20 after your approval:** `Install-AgentJobs.ps1` created the 9 jobs for `TalentAcquisitionDB`, all enabled. The *Full database backup* job was then started once through Agent: it succeeded and wrote and verified `Backup\TAMS\TalentAcquisitionDB\TAMS_TalentAcquisitionDB_FULL_20261120_104835Z.bak` (1.8 MB), the base of the backup chain. Agent's next runs: log backup 16:40 the same day, then every 30 minutes; summary 23:30; the nightly jobs from 01:00; differential 03:00 Saturday; full and index maintenance Sunday. The text below is the state before installation. Once installed and enabled, they change existing rows on schedule (expire jobs, flag contracts, purge old notifications) and write backup files. Your rule was "do not overwrite existing data without explicit approval", so installing them is your decision:

   ```powershell
   .\scripts\database\Install-AgentJobs.ps1
   ```
2. **Prerequisite verified first:**
   * The instance is SQL Server 2019 **Developer Edition** (15.0.2000.5), which includes SQL Server Agent.
   * The service "SQL Server Agent (MSSQLSERVER)" is **Running**, with automatic start, as `NT Service\SQLSERVERAGENT`.
   * The `sa` login is disabled. Agent jobs can still be owned by `sa` (the usual practice), and Agent runs T-SQL steps of sysadmin-owned jobs under its own service account.
   * Found while checking: `TalentAcquisitionDB` uses the **FULL recovery model and had never had a log backup**: `log_reuse_wait = LOG_BACKUP`, so the log could only grow. This is why a log-backup job was added.
3. **What was built:**
   * **Procedures** (`06_StoredProcedures/14_Jobs.sql`, schema `sched`), one per job:

     | Procedure | What it does |
     |---|---|
     | `usp_Job_ExpireRequisitions` | Open or on-hold jobs past their closing date (an IST business day) become Expired; their postings, and postings past their own closing time, become Closed; the owning recruiter is notified. |
     | `usp_Job_DetectContractExpiry` | Ended contracts become Expired, and their active assignment and placement Completed. Contracts ending within 30 days become Expiring. An Expiring contract whose end date a renewal moved beyond the window goes back to Active. |
     | `usp_Job_PurgeNotifications` | Deletes sent, failed or cancelled notifications older than 90 days, with their delivery history, plus used or expired sign-in tokens. Batched; messages still waiting are never deleted. |
     | `usp_Job_DailyRecruitmentSummary` | One row per IST day in `report.DailyRecruitmentSummary`; re-running a day replaces its row. |
     | `usp_Job_BackupDatabase` | FULL, DIFF or LOG into `{instance backup folder}\TAMS\{database}\`, with CHECKSUM and COMPRESSION, then RESTORE VERIFYONLY, then deletion of TAMS backup files older than 14 days. A DIFF or LOG whose base would not be a full backup taken by this job becomes a FULL. |
     | `usp_Job_IndexMaintenance` | Reorganises indexes over 10 % fragmented and rebuilds (online) those over 30 %, for indexes of 100+ pages; logs each index. |
     | `usp_Job_UpdateStatistics` | Updates every statistic whose table changed since its last update: full scan up to 1 M rows, sampled above. |
   * **Bookkeeping**, shared by all jobs:
     * `sched.usp_JobBegin` adds a history row and takes an exclusive **application lock per job**. A run started while another is going is recorded **Skipped**; so is a job switched off in `sched.JobDefinitions`.
     * `usp_JobLog` writes to the new table `sched.JobExecutionDetails`.
     * `usp_JobEnd` records the outcome (Succeeded / Failed / Skipped), rows affected and the error. On failure it gives **every administrator an in-app notification**, which is also e-mailed.
     * Errors are re-raised, so the Agent step fails visibly.
     * The application role is **denied** EXECUTE on all of these.
   * **Agent jobs** (`database/11_AgentJobs/01_Create_Agent_Jobs.sql`, installed with `scripts/database/Install-AgentJobs.ps1`), category "TAMS", owner `sa`. Failures are also written to the Windows Application log. Backup steps retry once after 5 minutes. Times are the server's local time (IST).

     | Job | Schedule |
     |---|---|
     | Expire stale requisitions | daily 01:00 |
     | Detect contract expiry | daily 01:15 |
     | Purge notification queue | Sunday 02:00 |
     | Update statistics | daily 02:30 |
     | Full database backup | Sunday 03:00 |
     | Differential database backup | Monday–Saturday 03:00 |
     | Transaction log backup | every 30 minutes |
     | Index maintenance | Sunday 03:30 |
     | Prepare daily recruitment summary | daily 23:30 |

     Jobs for any other database (test copies) are named `TAMS[<db>] - …` and created disabled.
   * **Admin UI:** the Scheduled-jobs page lists each job's runs, now real, and **what a run did** (new endpoint `GET /admin/jobs/runs/{id}/details`), with badges for Skipped, Running, Warning and Error.
   * **Fix in an existing script:** `scripts/database/Copy-Database.ps1` took *non-copy-only* full backups (overwritten each time) for test copies. Once differential and log backups exist, such a backup would silently become their base and leave the chain unrestorable. It now uses `COPY_ONLY`.
4. **Evidence of real Agent execution** (`scripts/testing/Test-AgentJobs.ps1` on a copy, **18/18**):
   * The 9 jobs were created in msdb as specified.
   * Each was started with `msdb.dbo.sp_start_job`. **SQL Server Agent job history** (`sysjobhistory`) shows every run succeeded, and TAMS's own history agrees.
   * Data jobs changed what they should.
   * The first differential correctly became a FULL. FULL, DIFF and LOG files were written, verified and listed in msdb, and **restored together into a new database that contained the change made just before the log backup**.
   * Index maintenance really rebuilt and reorganised indexes; statistics were updated.
   * A held job lock made the next run **Skipped**.
   * A failing job: Agent reported the step failure with the error text, TAMS recorded Failed and notified the administrators, and **event 208 "Status: Failed"** appeared in the Windows Application log.
   * Cleanup removed the jobs, databases, backup files and msdb history.
5. **Defects found and fixed:**
   * Job procedures running inside a caller's transaction could roll back to *a previous run's* savepoint after an early error (SQL test J06).
   * Several `EXEC` calls passed expressions as arguments (compile errors).
   * Windows PowerShell mangled a sqlcmd `-v` value containing spaces.
   * In the harness, a `-like` pattern treated `[ ]` in job names as wildcards.
   * In the UI, the install path lost its backslashes in an Angular template; a unit test now checks it.
6. **Tests:**
   * The new suite `12_Tests/08_Job_Tests.sql` passes **17/17**: all data jobs, idempotency, failure + notification, Skipped when switched off, refusal inside a transaction for backup and index work, catalogue, least privilege.
   * A clean build into a new database passes **419/419** (+17).
   * API **48/48**, including the new `JobTests`. One run had a single intermittent 500 in an unchanged document test that could not be reproduced in two further full runs and a run of the document tests alone (KI-046). The API log is now captured during tests.
   * Unit **39/39**.
   * Live: the Scheduled-jobs page with real runs, details and a failed run, plus the administrator's failure notification.
7. **Not covered:**
   * File-level clean-up stays out of SQL Agent: deleted document files (KI-032), outbox `.eml` files (KI-040) and the copy of the document store with backups (KI-033). The database engine should not reach into the application's folders. They move to the Phase 12 console app.
   * Agent has no e-mail operator (Database Mail is not configured). Failures go to the Windows log and to TAMS administrators instead.
   * See KI-047–KI-051.
8. **Next phase:** Phase 12, Windows Task Scheduler and the console application (done, see below).

---

## Phase 12 report — Windows Task Scheduler and the console application

1. **Phase:** 12. Status **VERIFIED**.

   **Not done yet, and waiting for you:** the tasks are not registered in this PC's Task Scheduler for `TalentAcquisitionDB`. Once registered, they send e-mail every 5 minutes, queue reminders from your data and delete old files, so registering them is your decision:

   ```powershell
   .\scripts\scheduler\Register-ScheduledTasks.ps1
   ```
2. **Division of work with SQL Server Agent:**
   * **SQL Server Agent (Phase 11) changes data:** it expires jobs, flags contracts Expiring, prepares the daily summary row and purges old rows.
   * **The console app tells people and handles files:**
     * *Contract expiry notifications* announces contracts Agent flagged; it never sets the status.
     * *Daily report delivery* e-mails the row Agent prepared. If the row is missing, the run **fails** and names the Agent job, rather than preparing the row itself.
3. **Tasks** (`TalentAcquisition.Scheduler.exe run <task>`):

   | Task | Command | Schedule | What it does |
   |---|---|---|---|
   | Interview reminders | `interview-reminders` | hourly | Interviews within 24 h: the candidate and every panel member. Times in IST, with mode, place and panel; reminded again if rescheduled. |
   | Offer expiry reminders | `offer-reminders` | daily 08:00 | Sent offers expiring within 2 days. |
   | Timesheet reminders | `timesheet-reminders` | Friday 15:00 | Contractors with an active assignment and no submitted timesheet for the week, or a rejected one. |
   | Contract expiry notifications | `contract-expiry-notices` | daily 08:30 | The contractor, the recruiter and every customer user, at 30, 7 and 1 days. |
   | Daily report delivery | `daily-report` | daily 07:30 | Yesterday's summary to recruiters, HR and administrators. |
   | Email queue processing | `process-notifications` | every 5 minutes | Sends the queued notifications (Phase 9). |
   | File housekeeping | `file-housekeeping` | daily 04:15 | Removes files of documents deleted over 30 days ago (KI-032) and outbox e-mails over 30 days old (KI-040); copies the document store to `storage\document-backup` (KI-033). |

   A reminder is never sent twice: each one's de-duplication key names the moment it is about (interview time, expiry, week, contract milestone, day).
4. **Required qualities:**
   * **Structured logging:** `logs\scheduler-yyyyMMdd.jsonl` (next to the program) holds one JSON object per entry (UTC time, level, task, run id, message, outcome, rows, duration, error), plus a readable console line. No addresses or secrets are logged.
   * **Retry handling:** temporary failures (database busy or unreachable, timeouts) are retried 3 times by default, waiting 2 s then 4 s. Rule violations fail at once. E-mails have their own per-message retry (Phase 9).
   * **Duplicate-execution prevention:**
     1. Task Scheduler never starts a second instance (MultipleInstances IgnoreNew).
     2. A machine-wide named semaphore makes a second copy exit at once. A mutex was tried first, but a mutex must be released by the thread that took it, and a run continues on other threads after `await` (found by a test).
     3. A **database lease** (`sched.usp_AppTaskBegin`) blocks a run on any machine while another is going. Abandoned runs are cleared after 60 minutes. A blocked run is recorded as *Skipped*.
   * **Exit codes:** 0 succeeded or skipped, 1 failed, 2 configuration, 3 database unreachable, 64 usage. They appear as Task Scheduler's "Last Run Result".
   * **Configuration validation:**
     * every run validates paths, retention and limits, and rejects a document backup folder equal to the store;
     * `--check` also proves the folders are writable and the database answers;
     * the register script refuses to register if `--check` fails;
     * `--settings <file>` points a run at another configuration (used for the tests).
   * **Execution history:**
     * every run is in `sched.JobExecutionHistory`, with host, outcome, rows and error, and details in `sched.JobExecutionDetails`;
     * shown on Administrator > Scheduled jobs;
     * Task Scheduler keeps its own history too.
   * **Failure reporting:**
     * a failed run is recorded with its error;
     * **every administrator gets a notification** (in-app and e-mail), through `sched.usp_NotifyJobFailure`, which the Agent jobs now use as well;
     * the exit code marks the run failed in Task Scheduler.
5. **Scripts** (`scripts\scheduler`):
   * `Register-ScheduledTasks.ps1`:
     * one task per job in the folder `\TAMS\`, run as the current user while signed in (no password stored);
     * runs missed while signed out start at the next sign-in;
     * at most 30 minutes per run.
   * `run-hidden.vbs`: starts the program without a console window and passes its exit code back.
   * `Unregister-ScheduledTasks.ps1`: removes the tasks and the folder.
6. **Database** (`06_StoredProcedures/15_AppTasks.sql`):
   * the task catalogue, now 7 Task Scheduler jobs;
   * `sched.usp_AppTaskBegin/Log/End`, which only work for Task Scheduler runs;
   * `notify.usp_QueueInterviewReminders`, `usp_QueueOfferExpiryReminders`, `usp_QueueTimesheetReminders`, `usp_QueueContractExpiryNotices` and `usp_QueueDailyReport`;
   * `doc.usp_ListPurgeableFiles` and `doc.usp_MarkFilePurged`;
   * `doc.Documents` gains `DeletedAt` and `FilePurgedAt`, and `doc.usp_DeleteDocument` sets `DeletedAt`.
7. **Evidence:** `scripts/testing/Test-ScheduledTasks.ps1` ran on a copy with temporary folders, everything removed afterwards: **27/27**.
   * **By hand:**
     * `--check` and `list` work; usage errors give 64; invalid or missing settings give 2;
     * an unreachable database is retried with back-off and gives 3;
     * every task succeeded and queued what it should, and the e-mails appeared as `.eml` files;
     * housekeeping removed the old deleted document's file (and marked it), deleted the old e-mail but kept the recent one, and copied the store;
     * a second copy exited at once; a lease held by "OTHER-PC" made the run *Skipped*;
     * the daily report without a summary failed with exit 1, was recorded and notified the administrators;
     * the JSON log has all the fields.
   * **Through Windows Task Scheduler** (folder `\TAMS-Test\`):
     * 7 tasks registered with the hidden launcher, interactive logon, no overlap and the 30-minute limit;
     * **each task started with `Start-ScheduledTask` showed Last Run Result 0**, with a new run in TAMS from this PC;
     * the failing daily report showed **Last Run Result 1** and *Failed* in TAMS;
     * the 5-minute task had its next run scheduled.
8. **Defects found and fixed:**
   * The thread-affine mutex (above).
   * `XACT_ABORT` was switched on before validation in `usp_AppTaskBegin`, which would doom a caller's transaction (SQL tests).
   * The harness read Task Scheduler's interim result 0x41301 "running" too early.
   * The clean build failed: the upgrade backfill referenced the audit table before a new database creates it.
   * Temp tables of an earlier test suite clashed in the shared setup session.
   * Phase 11's test J14 expected 6 Task Scheduler jobs; there are now 7.
9. **Tests:**
   * The new suite `12_Tests/09_AppTask_Tests.sql` passes **15/15**.
   * A clean build into a new database passes **434/434** (+15).
   * API **51/51**, with 3 new scheduler tests: retry policy, structured log, runner with success / Skipped / failure.
   * Unit **39/39**; build clean.
10. **Not covered:**
    * The tasks run only while the user is signed in. Running them while signed out needs a stored password or a service account (Phase 15).
    * The document backup copy is on the same disk.
    * See KI-052–KI-055.
11. **Next phase:** Phase 13, security and performance testing (done, see below).

---

## Phase 13 report — Security and performance testing

1. **Phase:** 13. Status **VERIFIED**.

   Nothing waits for you to unblock this phase. Two optional server-level changes are your decision:
   * binding SQL Server to the loopback address (KI-011);
   * the server parallelism settings (KI-058).

   The Task Scheduler registration from Phase 12 is still pending (KI-055).
2. **What was verified:**

   | Required area | How | Result |
   |---|---|---|
   | Authentication | Forged tokens re-signed with the real key, each with exactly one defect (expired, wrong audience, wrong issuer, not yet valid, unknown token id, other user's id); plus the Phase 4–9 tests (lockout, logout, revocation, e-mail confirmation) | rejected (401) |
   | Role permissions | A validly signed token claiming Administrator for a candidate; every role against the other roles' endpoints | 403; roles always come from the database |
   | Customer data isolation (**manipulated identifiers**) | Reflection finds every JSON GET endpoint. As a customer, a candidate and a contractor, each is called with **every record id in use** and with foreign customer/candidate/contractor query ids; any 200 is checked for other parties' names, e-mail domains and ids. Each detector is first proved to fire on a staff view. Plus write attempts on another customer's contracts and invoices, and report filters | **no leak**; writes refused (404) and nothing changed |
   | SQL injection | Injection strings in the `q` and `status` of every list endpoint, in path ids, in sign-in | treated as data; tables intact |
   | Input validation | Wrong-shape bodies (array, string, broken JSON) to **every** POST/PUT endpoint as six roles; over-long names and e-mails; bad dates; ids 0, negative, beyond INT; absurd page sizes | always 400/403/404, never 500 |
   | Secure password storage | Two accounts with the same password; schema scan; API responses | 32-byte PBKDF2-SHA256 hashes, unique 32-byte salts, 210,000 iterations; no text column can hold a password; no hash, salt or password in any response |
   | Document access control | Phase 8 suite (30 SQL + 8 API) re-run | unchanged, passing |
   | Database least privilege | New **worker identity**; permission suite 16 → 22 checks | API identity cannot claim e-mails or run worker procedures; worker identity has exactly 14 procedure grants |
   | Concurrent operations | Simultaneous approvals of one timesheet; simultaneous invoice runs for the same hours; Phase 4 races | exactly one winner each; no hour billed twice |
   | Transaction integrity | Invoice totals = lines + tax after the race; Phase 3 rollback tests; clean build | consistent |
   | API error handling | Unknown address, wrong method, XML body, unreachable database | one JSON error shape (404/405/415/503), no internals |
   | Query performance | ~2 million rows (100,000 candidates, 300,000 applications, 414,000 timesheet entries, 397,000 invoice lines) | every report < 2 s, list < 0.5 s, dashboard < 1 s, record < 0.2 s |
   | Index effectiveness | Index disabled vs enabled on the same call; missing-index and plan inspection | 4 proofs (3.2x–49x fewer reads); no high-impact missing index |
3. **Defects found and fixed:**
   * **Unbounded lists:** 9 list endpoints returned whole tables (interviews 73,980 rows in 2.6 s; customer timesheets 27,632). Now capped at the newest 500, the API says so (`X-Result-Truncated`) and the table shows *"Showing the newest 500 records. Narrow the filters to see older ones."*
   * **Slow searches:** candidate search 584 ms / 434,000 reads → 81 ms / 3,400; applications by status 527 ms / 585,000 → ~50 ms / 4,400; deep paging 692 → ~100 ms. How:
     * count once instead of `COUNT(*) OVER ()`;
     * fetch the page first, then its details;
     * `OPTION (RECOMPILE)` for the catch-all filters;
     * match the free text once into a temp table;
     * binary-collation `UPPER` comparison, which gives the same matches at about 5× less CPU.
   * **Interview list for administrators:** 1.5 s → 70 ms. The per-row visibility function was replaced by the same rules inlined.
   * **Reports:** interview conversion 892,000 → 1,800 reads (one grouped pass); sourcing 600 → ~250 ms. Both were cross-checked: on the large copy all 1,122 interview-conversion rows equal an independent calculation.
   * **Audit triggers:** a correlated lookup into `inserted`/`deleted` made statements that change 1,000–2,000 rows about 10× slower than necessary. They now build the XML from the joined row. The output is identical, compared on 294,561 rows.
   * **Parallelism:** with the server defaults, concurrent users spent their time in CXPACKET waits. `MAXDOP 4` for the TAMS database only raised stress throughput by about 40 %.
   * **API:**
     * an XML body gave **500** instead of 415, because the framework's exception was treated as a server error;
     * addresses without a route returned an empty body;
     * an unreachable database gave a generic 500 (now 503 `unavailable`).
   * **Script runner:** `Invoke-SqlScripts.ps1` failed on scripts outside the `database` folder.
4. **Security additions:**
   * **Worker database identity** (KI-039, KI-053):
     * `tams_worker_role` / `tams_worker_demo` with 14 procedure grants;
     * those procedures are denied to the API's role;
     * the console app uses it (Task Scheduler harness re-run: 27/27 as `tams_worker_demo`).
   * **Rate limits** (KI-022): per client address and minute on the anonymous account endpoints, giving 429 with `Retry-After`. `X-Forwarded-For` is ignored.
   * **Body cap without a length** (KI-034).
   * **Report-run audit** (KI-043): append-only `audit.ReportRuns`, written by the database.
5. **Performance harness** (`scripts/testing/Test-Performance.ps1`, **16/16**):
   * **Setup:** a disposable copy with ~2 million rows, loaded in ~40 s.
   * **Timing:** 64 calls timed under the API's database identity.
   * **Index proofs:**
     * `IX_JobApps_Posting_Status` 3.2×;
     * `IX_AppHist_App_At` 49×;
     * `IX_Timesheets_Contractor_Week` 22×;
     * `IX_InvLines_Invoice` 48×.
   * **Audited 2,000-row update:** about 0.2 s.
   * **Stress test** of the real API (16 clients without pauses, all on this PC):
     * 894 requests in 20.8 s, **no failed request**;
     * p95 1.3 s for the slowest list and 1.7 s for the slowest report.
   * Slowest single-user calls on the large copy: department hiring report 462 ms, sourcing 299 ms, pipeline 281 ms; the slowest list is deep paging at 131 ms.
6. **Tests:**
   * SQL suites **443/443**, on the development database and a clean build;
   * API **68/68** (+17);
   * frontend unit **41/41** (+2);
   * production build clean;
   * Task Scheduler harness **27/27**;
   * performance **16/16**.
7. **Not covered or limited:**
   * SQL Server listens on all interfaces; the firewall blocks it (KI-011).
   * Rate limits are per API process (KI-056).
   * Lists are capped, not paged (KI-057).
   * Stress figures are from one shared PC (KI-060).
   * No malware scanning of uploads (KI-031, unchanged).
8. **Next phase:** Phase 14, complete automated testing (done, see below).

---

## Phase 14 report — Complete automated testing

1. **Phase:** 14. Status **VERIFIED**.
2. **One command:**

   ```powershell
   .\scripts\testing\Run-AllTests.ps1
   ```

   * By default it runs the database, backend, frontend unit and browser end-to-end tests (about 6 minutes).
   * Add `-IncludeTasks -IncludeAgent -IncludePerformance -IncludeCleanBuild` for the Phase 11–13 harnesses.
   * Last full run: **1,078 / 1,078 passed in about 6.5 minutes**. The development database is only read (copied).
3. **New: browser end-to-end tests** (`frontend/e2e`, run by `scripts/testing/Run-E2E.ps1`, **14/14**, twice in a row).
   * **How they run:**
     * Playwright 1.65.1 (installed with your approval, no browser download) drives the installed Chrome.
     * The real web app talks to the real API on a disposable database copy. Nothing is mocked.
     * Each person has their own browser.
     * E-mail is delivered by the real console app; the candidate opens the confirmation link from the delivered e-mail.
   * **Both complete business workflows through the UI:**
     * internal recruitment: hiring request → … → onboarding → Active employee, by 4 people;
     * external staffing: customer request → … → paid invoice, by 4 people.
   * **The 9 required edge cases:**
     * duplicate application (from a second tab);
     * offer rejection (HR) and decline (candidate);
     * interview rescheduling;
     * timesheet rejection and resubmission;
     * contract expiry (Agent → console app → e-mail → customer → renewal);
     * invoice failure and retry;
     * unauthorized customer access (manipulated requests from the other customer's browser);
     * database rollback (refused contract leaves nothing);
     * scheduler failure recovery (failed run reported → catch-up → success; abandoned run cleared).
   * **Every role:** exact menu for all six roles, other areas redirected, and the API refuses them. Plus the candidate, recruiter and administrator workflows not covered above.
4. **Gaps filled elsewhere:**
   * **API (+6):** candidate management with optimistic concurrency; HR offer rejection and candidate decline; reschedule (past time, stale version) and cancel; contract expiry, report and renewal; invoice failure with no rate in force, then retry, void and re-invoice; scheduler recovery.
   * **Frontend unit (+2):** status words; the timesheet race.
   * **Database:** already complete (443 checks); the traceability matrix in `TEST_RESULTS.md` maps every required area to its tests.
5. **Defects found by the new tests and fixed:**
   * **Timesheet grid could show the wrong week.** If a contractor switched week while the previous week was still loading (for example right after submitting), the late answer replaced the grid. The date said 09 Nov while the grid and status were 02 Nov's. Stale loads are now dropped. A unit test reproduces it: it fails without the fix and passes with it.
   * **Status codes in tables.** Tables showed raw codes ("PendingApproval", "PartiallyPaid") where filters and details said "Pending approval"; they now show the words.
6. **Supporting changes:**
   * The API accepts `--settings <file>`, like the console app, so a throwaway API can point at a copy.
   * `Run-AllTests.ps1` and `Run-E2E.ps1`.
   * `tests/e2e` and `tests/results` are git-ignored.
7. **Not covered:**
   * Time is arranged in SQL (KI-061).
   * The tests run in Chrome only (KI-062).
   * The tests use the dev server, not the production build (KI-064, Phase 15).
   * npm reports dev-only advisories (KI-063).
8. **Next phase:** Phase 15, local deployment and final execution.

---

## Phase 15 report — Local deployment and final execution

1. **Phase:** 15. Status **VERIFIED**. This completes the project plan (phases 0–15).
2. **One documented start-up procedure:**

   ```powershell
   .\scripts\deployment\Start-Tams.ps1
   ```

   * **What it does:** checks SQL Server and Agent, creates the database only if missing (never drops, overwrites or re-seeds), creates the local secret if missing, builds what changed, starts the API, runs the health check and opens the browser.
   * **Measured:** 7–8 s on this machine with everything in place, and **35 s from nothing**.
   * **Stop:** `Stop-Tams.ps1` stops only what `Start-Tams.ps1` started.
   * **Options:** `-Dev` for live reload on port 4200; `-InstallAgentJobs` and `-RegisterTasks`; `-DatabaseName`/`-Port` for a second instance, such as a restored copy.
3. **The nine required commands** are each in the [README](../README.md) as their own command block:
   1. start SQL Server;
   2. create or restore the database (new `Backup-TamsDatabase.ps1` and `Restore-TamsDatabase.ps1`);
   3. run the database setup scripts;
   4. start the API;
   5. start Angular;
   6. register the scheduled tasks;
   7. start the SQL Server Agent jobs;
   8. run the tests;
   9. verify health (new `Test-TamsHealth.ps1`).
4. **Production web app served by the API:**
   * **Serving:** the new `WebAppMiddleware` serves the Angular production build on the API's own address. Angular routes get `index.html`; only listed file types inside `WebRoot` are ever sent.
   * **Content-Security-Policy** on every page: scripts only from this origin (KI-067). Critical-CSS inlining was switched off because it needs an inline event handler.
   * **E-mail links** now point to port 5000.
   * **Checked against the running API:** encoded traversal is refused, as are unknown files, other extensions and non-GET requests.
5. **Deliverables:**
   * **README:** the root `README.md`.
   * **Configuration examples:** `config/examples/` (every key checked against the settings class; no secrets).
   * **Test instructions:** `documentation/TESTING.md`.
   * **Setup instructions:** LOCAL_SETUP §13.
   * **Frontend README:** project-specific, replacing the CLI boilerplate.
   * **Visual Studio solution:** `backend/TalentAcquisition.sln` (7 projects); the scheduler project, SQL scripts and seed data already existed.
   * **Folder layout:** matches the requested structure, except that the Angular project is at `frontend/`, not `frontend/talent-acquisition-ui/` (see the README).
6. **Verification with evidence:**
   * **Browser, real records:** the production build on `TalentAcquisitionDB` (port 5000), signed in as each of the six roles. Every list was compared with the database:
     * the customer saw only Apex's 2 invoices (₹80,240 each, Issued/Paid);
     * the contractor saw 5 timesheets with matching weeks, statuses, hours and rejection reason;
     * the candidate saw 2 applications;
     * the recruiter saw 3 invoices, including the partly paid ₹70,800/₹40,000/₹30,800, and their own requisitions' 6 applications (by design: recruiters see requisitions they own);
     * HR saw 3 offers;
     * the administrator saw 15 users and 3 jobs.
   * **Tampered requests:** the customer's own browser asked for Brightwave's invoice, balance and invoice list, and every request was refused (404). Every application request returned 200, deep links survived a reload, and there were no CSP violations.
   * **From nothing:** `Test-CleanDeployment.ps1` 12/12. A copy of the project with no build output, configuration, credentials or database is started by `Start-Tams.ps1`, signs in with a generated password, is stopped, and is removed. The running app was not touched.
   * **Health:** 28 passed, 2 warnings, 0 failed. The two warnings are your decisions: KI-011, and the task registration in KI-055. After the tasks were registered (2026-11-21): **30 passed, 1 warning (KI-011), 0 failed**.
   * **Backup and restore:**
     * backup, then restore under a new name: 6/6 database users, identical row counts;
     * a second restore without `-Replace` is refused;
     * `-Replace` takes a safety backup first;
     * a deliberately damaged backup is refused at verification.
     * All test databases and backup files were removed.
   * **Full test run** `Run-AllTests.ps1 -IncludeTasks -IncludeAgent -IncludePerformance -IncludeCleanBuild`: **1,079 / 1,079 in 6 minutes** (443 + 74 + 44 + 14 + 27 + 18 + 16 + 443). The browser tests now run on the production build (KI-064 resolved).
7. **Defects found and fixed in this phase:**
   * **Raw status codes in filters and detail badges** ("OfferStage", "PartiallyPaid"). Found in the browser check; fixed with a `statusText` pipe and a unit test (KI-069).
   * **`Start-Tams.ps1` never returned when its output was captured.** Found by the from-scratch test; fixed (KI-070).
   * **Starting a second instance stopped the first.** Fixed with one state file per port (KI-070).
8. **Open items, all needing your decision:**
   * KI-011: SQL Server listening on all interfaces.
   * ~~KI-055~~: the Task Scheduler tasks were registered for TalentAcquisitionDB on 2026-11-21, with your approval.
   * KI-058: server-wide parallelism.
   * KI-063: dev-only npm advisories, which need newer tooling downloads.
   * Accepted by design: KI-065 (the API runs as a user process, not a service), KI-066 (Debug .NET build) and KI-067 (inline styles allowed by CSP).
9. **Nothing is committed to git** (as agreed: only on request).
