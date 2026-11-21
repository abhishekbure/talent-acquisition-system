# TAMS — Architecture (Phase 1 draft for approval)

## 1. System architecture

```
 Browser ── Angular 20 SPA (localhost:4200)
               │  HTTPS-style JSON + Bearer JWT
               ▼
 ASP.NET Web API 2 (.NET Fx 4.7.2, OWIN self-host, localhost:5000)
   API  →  Business  →  Data (ADO.NET)  →  SQL Server (stored procedures only)
               │                                   ▲
               └── local file storage (documents)  │
                                                   │
 SQL Server Agent (DB-only jobs)  ─────────────────┤
 TalentAcquisition.Scheduler.exe (Windows Task Scheduler, app jobs) ─┘
        └── writes .eml files to storage\mail-outbox (mock email provider)
```

## 2. Backend layers (6 projects; a 7th, `TalentAcquisition.Scheduler`, since Phase 9 — see section 10)

| Project | Responsibility | May reference |
|---|---|---|
| `Models` | DTOs, request/response contracts, enums | — |
| `Common` | Config, logging, errors, password hasher, JWT helper, validation, result types | Models |
| `Data` | `ConnectionManager`, `StoredProcExecutor` (SqlConnection/SqlCommand/SqlDataReader/SqlTransaction), repositories, row mappers, retry on deadlock (1205) | Models, Common |
| `Business` | Services (Auth, Users, Candidates, Recruitment, Applications, Interviews, Offers, HR, Staffing, Contracts, Assignments, Timesheets, Billing, Notifications, Reporting), authorization rules, validation | Data, Models, Common |
| `API` | OWIN startup, Web API 2 controllers (attribute routing, `/api/v1`), `[Authorize]` filters, exception filter, CORS, health endpoint | Business, Models, Common |
| `Scheduler` | Console app: tasks, retry, applock, exit codes, execution history | Business, Data, Common |

Rules: no SQL text in C# (stored procedures only, always parameterised); no Entity Framework; controllers never contain business logic; the `CustomerId` / `CandidateId` / `ContractorId` of the caller is **resolved server-side from the token**, never trusted from request bodies.

## 3. Database architecture
* One database `TalentAcquisitionDB`, 13 schemas: `sec org rec cand hr staff time bill doc notify audit report sched`.
* All writes go through stored procedures that take `@ActorUserId` and re-check authorization and ownership (second line of defence behind the API).
* The application login `tams_app` has `EXECUTE` on procedure schemas and `SELECT` only on `report` views. It has no direct table access.
* Multi-step operations (offer acceptance → employee + onboarding, placement → contract + rate + assignment, invoice generation) run inside explicit transactions with `SET XACT_ABORT ON` and TRY/CATCH.
* Triggers only write audit rows and status history, are multi-row safe, and never hold workflow logic.
* `rowversion` columns on mutable aggregates for optimistic concurrency (conflicts → HTTP 409).
* **Platform (revised 2026-11-19):** SQL Server **2019 Developer**, default instance `MSSQLSERVER`, Windows authentication for administration, SQL Server Agent available. The original SQL Server 2014 target was replaced with the user's approval and the 2014-syntax restriction was lifted. Default compatibility level (150). The design deliberately stays "classic" (≈2015 practice: procedures, functions, DML/DDL triggers, views, indexes, constraints, transactions, Agent, auditing, execution plans, locking, backup/restore) and avoids newer features (JSON, `STRING_AGG`, graph, ledger, etc.) that add nothing to those goals. Convenience syntax such as `CREATE OR ALTER` is allowed for repeatable scripts.
* **Actual installation (verified 2026-11-19):** Microsoft SQL Server 2019 (RTM) 15.0.2000.5, **Developer Edition (64-bit)**, default instance `MSSQLSERVER` on host `INSNABHI`; services `MSSQLSERVER` and `SQLSERVERAGENT` Running/Automatic; Windows authentication only, `INSNABHI\ABHISHEK` is sysadmin; TCP 1433 enabled (see KI-011).
* **Version deviations from the original architecture:** SQL Server 2014 → 2019; Visual Studio/IIS → OWIN self-host built with `dotnet build` (D2). Backend stack (ASP.NET Web API 2, C#, .NET Framework 4.7.2, ADO.NET) is unchanged.

## 4. Authentication and authorization
* Registration: only **Candidate** can self-register. Other roles are created by Administrator (Customer/Contractor users are linked to their customer/contractor record at creation).
* Login → JWT (HS256, 60 min) containing `sub`, `jti`, role, and the linked profile id. `jti` recorded in `sec.AuthTokens`; a message handler validates the token **and** that the `jti` is not revoked and the user is active on each request.
* Logout revokes the `jti`. Deactivating a user revokes all of that user's tokens.
* Lockout: 5 failed logins → 15-minute lock; every attempt written to `audit.LoginHistory`.
* Password reset: single-use, hashed, 30-minute token in `sec.PasswordResetTokens`; the reset link is delivered through the mock email provider.
* Authorization: `[Authorize(Roles=...)]` plus permission checks (`sec.Permissions` ↔ `sec.RolePermissions`) in the business layer, plus ownership checks in the stored procedures. Angular route guards are UX only.
* Customer isolation: every `staff.*`, `time.*`, `bill.*` row carries `CustomerId`; procedures filter on the actor's customer; a manipulated id returns 404 (not 403) so existence is not revealed.

**Security as built and tested (Phase 13):**
* **Database identities (least privilege):**

  | Identity | Used by | Rights |
  |---|---|---|
  | `tams_app_role` (`tams_app_demo`) | Web API | EXECUTE on the procedure schemas, SELECT on report views; **denied** the 13 worker procedures and the job procedures; no table access |
  | `tams_worker_role` (`tams_worker_demo`) | `TalentAcquisition.Scheduler` | EXECUTE on exactly 14 procedures (sender, reminder queueing, task bookkeeping, file housekeeping, ping); nothing else |
  | `tams_report_role` (`tams_report_demo`) | read-only reporting | SELECT on report views |

* **Abuse limits:** per-client rate limits on the anonymous account endpoints (`RateLimiter` in `Hosting.cs`); request bodies are capped whether or not they state their length.
* **Errors:** one JSON shape for every error, including the framework's 404/405/415 and an unreachable database (503); no stack traces, SQL text or framework names.
* **Audit:** data changes (triggers, linear since Phase 13), sign-ins (`audit.LoginHistory`) and report runs (`audit.ReportRuns`).
* **Tests:**
  * a reflection-driven sweep of every JSON GET endpoint with every record id in use, as a customer, a candidate and a contractor, proves no foreign data is returned;
  * wrong-shape bodies are sent to every POST/PUT endpoint as six roles.

**Performance as built and tested (Phase 13):**
* **Lists:** paged lists count once and fetch only the page; catch-all searches use `OPTION (RECOMPILE)`; free-text candidate search matches in one pass with a binary-collation comparison. Unpaged lists are capped at the newest 500.
* **Reports:** whole-period reports aggregate in one pass (no per-row subqueries or table variables).
* **Parallelism:** `MAXDOP 4` for the TAMS database only (database-scoped).
* **Evidence:** `scripts/testing/Test-Performance.ps1` measures every report and the main lists on a copy with about 2 million rows, proves key indexes by disabling them, and stress-tests the real API.
## 5. Role permission summary

| Capability | Candidate | Contractor | Customer | Recruiter | HR Manager | Admin |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| Own profile / resume / documents | ✔ | ✔ (own) | – | – | – | – |
| Browse & apply to internal jobs | ✔ | – | – | – | – | – |
| Create department hiring request | – | – | – | – | ✔ | ✔ |
| Approve hiring request / job content | – | – | – | – | ✔ | ✔ |
| Create & publish job | – | – | – | ✔ | ✔ | ✔ |
| Screen applications, set status | – | – | – | ✔ | ✔ (view) | ✔ |
| Search candidate master | – | – | – | ✔ | ✔ | ✔ |
| Schedule interviews | – | – | ✔ (own cust.) | ✔ | ✔ | ✔ |
| Submit interview feedback | – | – | ✔ (own cust.) | ✔ | ✔ | – |
| Create offer | – | – | – | ✔ | ✔ | ✔ |
| Approve offer (not own) | – | – | – | – | ✔ | ✔ |
| Accept/reject own offer | ✔ | – | – | – | – | – |
| Employee onboarding | – | – | – | – | ✔ | ✔ |
| Create staffing request | – | – | ✔ | ✔ (on behalf) | – | ✔ |
| Submit candidates to customer | – | – | – | ✔ | – | ✔ |
| Shortlist / reject / select candidates | – | – | ✔ (own) | – | – | – |
| Create contractor / contract / placement | – | – | – | ✔ | – | ✔ |
| Submit own timesheet | – | ✔ | – | – | – | – |
| Approve/reject timesheet | – | – | ✔ (own) | – | – | – |
| Generate invoice | – | – | – | ✔ | – | ✔ |
| Record payment | – | – | – | ✔ | – | ✔ |
| View own customer's invoices | – | – | ✔ | – | – | – |
| Reports | – | – | ✔ (own) | ✔ | ✔ | ✔ |
| Users, roles, audit, jobs, rate cards | – | – | – | – | – | ✔ |

## 6. Workflows

### A. Internal recruitment
`hr.EmployeeRequisitions` (Draft→Submitted) → `hr.HiringApprovals` (Approved/Rejected) → `rec.JobRequisitions` + `JobDescriptions` + `JobSkills` (Draft) → `rec.JobApprovals` (HR sign-off) → `rec.JobPostings` (Published) → `cand.JobApplications` (Applied → Screening → Shortlisted → Interview → Selected / Rejected / Withdrawn; each change in `cand.ApplicationStatusHistory`) → `cand.Interviews` + `InterviewPanels` + `InterviewFeedback` → `cand.JobOffers` (Draft → PendingApproval → Approved → Sent → Accepted / Rejected / Expired) + `OfferApprovals` → **transaction**: `hr.Employees` + `hr.EmployeeOnboarding` tasks + `hr.EmploymentHistory` → HR completes onboarding.

### B. External staffing
`staff.CustomerRequisitions` → recruiter reviews/accepts → searches `cand.Candidates` → `staff.SubmittedCandidates` → `staff.CustomerCandidateDecisions` (Shortlist/Reject/Select) → `cand.Interviews` (linked to submission) → **transaction**: `staff.Contractors` (reuses the Candidate Master row), `staff.Placements`, `staff.Contracts`, `staff.ContractRates` (pay rate ≠ bill rate), `staff.Assignments` → `time.Timesheets` + `TimesheetEntries` (Draft → Submitted → Approved/Rejected → resubmit) with `TimesheetApprovals`/`TimesheetRejections` → **transaction**: `bill.Invoices` + `InvoiceLines` (one line per approved billable entry, unique per entry so nothing is billed twice, bill rate snapshotted) → `bill.Payments` → outstanding balance via function.

### Shared rules
* `cand.Candidates` is the only person-master. Applications and submissions reference it; `hr.Employees` and `staff.Contractors` reference it and add role-specific data. No candidate duplication (unique normalized email).
* Duplicate prevention: unique (CandidateId, JobRequisitionId) on applications; unique (CandidateId, CustomerRequisitionId) on submissions; both exclude withdrawn rows through a filtered unique index.

## 7. Frontend architecture
Angular 20, standalone components, lazy-loaded feature routes: `core` (HTTP interceptor adds JWT, error interceptor, auth service, role guard), `shared` (layout, sidebar, header, notification bell, data-table with server paging/sort/filter, confirm/modal dialogs, form controls, loading/empty/error states), feature areas `auth candidate contractor customer recruiter hr admin reports`. Angular Material + Reactive Forms. No business data in the client: all tables and cards come from API calls. Charts via Chart.js.

**As built (Phase 5) — and where it differs from the plan above**
* Angular **20.3**, standalone components, signals, built-in control flow, zone.js change detection; project `frontend/` (`tams-web`). Every role area and every page is lazy-loaded (initial bundle 367 kB raw / 101 kB transferred).
* **No Angular Material and no Reactive Forms (deviation).** The UI uses one hand-written stylesheet (system fonts, no external requests) and a *declarative dialog*: each action declares its fields (text, number, date, local date-time → UTC, select with type-ahead filter, multi-select, checkbox, repeatable rows) and the one API call it makes; the dialog validates required/range/e-mail rules, stays open on a server error and maps the API's field details to the fields. This keeps every action consistent without per-form component code and avoids a large UI dependency. **Chart.js is not used yet**; charts come with reporting (Phase 10).
* `core/`: `Api` (promise client, relative base `/api/v1`, maps the API error body), `Auth` (session in `sessionStorage`, roles, home area), `authInterceptor` (bearer token on `/api/*`; a 401 ends the session), guards (`signedInGuard`, `roleGuard`, `homeRedirect` — convenience only, the API decides), `Toasts`, `Dialogs`, format helpers (DATE columns shown on their calendar day, DATETIME2 values converted from UTC to local time, INR formatting).
* `shared/`: `DataTable` (server paging where the API pages; client sort/filter of the current page; per-row actions shown by status/role), `DialogHost`, `DetailList`, `Metrics` (dashboard cards from `report.usp_Dashboard`), `Lookups` (live option lists), `Actions` (schedule/reschedule/cancel interview, feedback, create offer, create contract — shared by several roles).
* `areas.ts`: one definition per role → both the side navigation and the routes, so a menu entry cannot point to a missing page (asserted by a unit test). Multi-role users switch areas from the top bar (side menu on phones).
* Dev: `ng serve` proxies `/api` to `localhost:5000` (`proxy.conf.json`); deployment (Phase 15) serves the built files from the same origin as the API.

## 8. Document storage
**As built (Phase 8):**
* **Where files live.** Files are kept on local disk at `{store}\{first 2 hex}\{32-hex random name}{ext}`, outside any served path.
  * The store is `DocumentStorePath` (default `storage\documents` under the project folder) or `TAMS_DOCUMENT_STORE`, and must be an absolute path.
  * This differs from the Phase 1 draft's `{yyyy}\{MM}` folders (see KI-036).
  * Metadata (owner type and id, customer id, original name, content type, size, SHA-256, uploader, soft-delete flag) is in `doc.Documents`. The application role cannot SELECT that table directly.
* **Upload.** The API pipeline checks `Content-Length` first (411 if missing, 413 above 10 MB + 64 KB). Then `FileRules` checks:
  * extension allow-list: pdf, doc, docx, png, jpg, jpeg;
  * size: 1 byte to 10 MB;
  * magic bytes, and a .docx must contain `[Content_Types].xml` and `word/document.xml`;
  * the original name is cleaned.

  `DocumentStore` then writes a new random name (create-new, never overwrite), and `doc.usp_AddDocument` checks that the caller may manage the owner. If the database refuses, the file is deleted again.
* **Download.** `doc.usp_GetDocumentForDownload` runs `doc.fn_CanAccessDocument` on every request and returns a stored name only if access is allowed. Otherwise the caller gets 404, so other people's files are not revealed.
  * The stored name must match `^[0-9a-f]{32}\.(pdf|png|jpg|doc|docx)$` and resolve inside the store.
  * Size and SHA-256 are re-checked before any byte is sent (500 `document_integrity` or `document_missing` otherwise).
  * The response carries `Content-Disposition: attachment` (with UTF-8 `filename*`), `X-Content-Type-Options: nosniff` and `Content-Security-Policy: default-src 'none'; sandbox`.
* **Delete.** Deletion is soft: the row is kept for audit, the file stays on disk until the Phase 11 purge (KI-032), and the document is unreadable from then on.
* **Compliance.** A contractor's proof is linked to a compliance record and resets it to Pending. A recruiter verifies it (a proof is required) or rejects it (a reason is required), and the contractor is notified. Both the documents and the compliance records have audit triggers.

## 9. Scheduler architecture (no overlap between the two)

| SQL Server Agent (DB-only) | Windows Task Scheduler → `TalentAcquisition.Scheduler.exe` (app-level) |
|---|---|
| Expire stale requisitions | Interview reminders |
| Detect expiring/expired contracts (status flag) | Offer-expiry reminders |
| Purge old queue/history rows | Timesheet reminders |
| Prepare daily recruitment summary (`report` table) | Contract-expiry notifications |
| Full/differential backups | Process email queue (send via mock provider) |
| Index maintenance, statistics updates | Deliver daily report |

Duplicate-run protection: `sp_getapplock` per job name. History in `sched.JobExecutionHistory`. Notification de-duplication via a unique `DedupeKey`.

**As built for SQL Server Agent (Phase 11):**
* **Jobs:** 9 Agent jobs, the 7 above plus differential and transaction-log backups, because the database uses the FULL recovery model. Each runs one `sched.usp_Job_*` procedure in the database.
* **Run bookkeeping:**
  * a per-job `sp_getapplock`; a held lock or a job switched off in `sched.JobDefinitions` makes the run "Skipped";
  * history in `sched.JobExecutionHistory`, with what the run did in `sched.JobExecutionDetails`;
  * failures re-raised (Agent history + Windows event 208) and notified to administrators.
* **Backups:**
  * written to `{instance backup folder}\TAMS\{database}\` with CHECKSUM and COMPRESSION, verified, and kept for 14 days;
  * a DIFF or LOG whose base is not a TAMS full backup becomes a FULL, so the files always form a restorable chain (proved by restoring full + diff + log on a copy);
  * test-copy backups are `COPY_ONLY`.
* **What stays out of SQL Agent:** file-level work in the application's folders (documents, mail outbox, a copy of the document store) runs in the Phase 12 console app, keeping the database engine out of application folders.

**As built for Windows Task Scheduler (Phase 12):**
* **Rule:** Agent changes data; the console app tells people, sends e-mail and handles files. It never repeats an Agent job: contract notices read the status Agent set, and the daily report fails (naming the Agent job) if Agent's summary row is missing.
* **Program:** `TalentAcquisition.Scheduler.exe run <task>` (7 tasks: the 6 above plus *File housekeeping*), `list`, `--check`, `--settings <file>`, `--max N`. Tasks live in `TalentAcquisition.Business/AppTasks.cs` (`AppTaskCatalog`, `TaskRunner`, `RetryPolicy`, `FileHousekeeping`); data access in `AppTaskRepository`.
* **A run:**
  1. configuration validated (exit 2 on error);
  2. a machine-wide named semaphore per database and task (a second copy exits 0 at once);
  3. `sched.usp_AppTaskBegin` takes the database lease (Skipped → exit 0; database unreachable after retries → exit 3);
  4. the work, with retry of transient errors (3 attempts, 2 s then 4 s);
  5. `sched.usp_AppTaskEnd` Succeeded (exit 0) or Failed (exit 1, administrators notified).
* **Logging:** `StructuredLog` writes JSON lines to `logs\scheduler-yyyyMMdd.jsonl` (`LogDirectory`, relative to the program folder) and a readable console line.
* **Registration:** `scripts\scheduler\Register-ScheduledTasks.ps1` (folder `\TAMS\`, current user, interactive logon, IgnoreNew, 30-minute limit, StartWhenAvailable) runs each task through `run-hidden.vbs`, which hides the console and passes the exit code to Task Scheduler. `Unregister-ScheduledTasks.ps1` removes them.

## 10. Notifications
Procedures enqueue to `notify.NotificationQueue` (status, attempts, next-attempt time, dedupe key). The console app processes the queue, retries with back-off, and writes `notify.NotificationHistory`. The mock provider writes `.eml` files through `SmtpClient` pickup-directory delivery, so nothing external is contacted.

**As built (Phase 9):**
* **Path of a message:** procedure → `notify.usp_Enqueue` (de-duplicated per event and recipient) → `TalentAcquisition.Scheduler process-notifications` → `notify.usp_ClaimBatch` → `MailRenderer` → `PickupDirectoryMailSender` (`.eml` in `storage\mail-outbox`) → `notify.usp_MarkSent` or `usp_MarkFailed`. The API never sends mail.
* **Leases:** a claim leases each message for 5 minutes (`NextAttemptAt` = lease expiry). Several workers can run at once, because `UPDLOCK, READPAST` hands each message to one worker. A lost lease counts as a failed attempt. Outcomes apply only to the attempt that was handed out.
* **Delivery guarantee:** delivery is at least once (KI-037).
* **Retries:** 1, 2, 4 and 8 minutes, then Failed after 5 attempts; an administrator can re-queue.
* **Rendering:** plain text plus an HTML alternative. The HTML is fully encoded, and links are made clickable only for plain `http(s)` URLs. Subjects and names are reduced to one line (no header injection). `Message-ID` is `<notification-{id}.{attempt}@tams.local>`.
* **Sign-in links (password reset, e-mail confirmation):**
  * e-mail only;
  * the body is erased in the database once handled;
  * never re-sent by an administrator;
  * the token is stored only as SHA-256.
* **Registration:** self-registration is confirmed by e-mail before sign-in and before any link to an existing candidate record (KI-014). The confirm page needs a click, so link-scanning mail filters cannot use up the token.
* **Times:** times in texts are in IST (`dbo.fn_BusinessTime`); data stays UTC.
* **Backend projects:** the backend now has **7 projects**. `TalentAcquisition.Scheduler` (net472 console) references Business, Data, Common and Models.

## 11. Reporting
`report` schema holds views and parameterised procedures; customer-scoped reports require the actor's customer id; one API `ReportsController`; Angular `reports` area renders tables and charts. A small `report.DailyRecruitmentSummary` snapshot table is filled by an Agent job.

**As built (Phase 10):**
* **Data path:** `report.ReportDefinitions` (catalog) → `report.usp_ListReports` / `report.usp_RunReport` → one procedure per report → `ReportService` (labels, display types, 10,000-row limit, CSV) → `ReportsController` (`/reports`, `/reports/{code}`, `/reports/{code}/csv`) → Angular `pages/reports.ts`.
* **No per-report code in the API or UI:** adding a report means a procedure plus one catalog row; the UI builds its filters, table and chart from the catalog and the returned column list.
* **Security:**
  * Roles are checked at the API edge, again by the entry point against the catalog, and a third time inside each report procedure.
  * The customer scope is resolved in SQL from the login, never from the request.
  * Pay rates are removed at the source: the procedure returns a different column set to a customer.
* **Charts:** `shared/reports.ts`, `BarChart` in HTML/CSS (readable at phone width; no library), with value, count or sum per label as the catalog says. `ReportCard` puts one report on the Recruiter, HR, Customer and Administrator dashboards.
* **Daily summary:** the `report.DailyRecruitmentSummary` snapshot is still filled by the Phase 11 Agent job. The interactive reports read live data.

## 12. Test architecture (Phase 14)

| Layer | Tool | Runs against | Mocks |
|---|---|---|---|
| Database | T-SQL suites (`database/12_Tests`) | a disposable copy (or a clean build) | none; rolled-back transactions |
| Backend | MSTest; the real API hosted in-process (`tests/backend`) | its own disposable copy | none |
| Frontend unit | Jasmine + Karma, ChromeHeadless | — | HTTP replaced by Angular's test controller (isolated unit tests only) |
| Browser end-to-end | Playwright (`frontend/e2e`), installed Chrome | production build served by the API process (`--settings`, Phase 15; `-DevServer`: `ng serve`) → `TalentAcquisitionDB_E2E` | **none** |
| Harnesses | PowerShell | copies, real SQL Server Agent, real Windows Task Scheduler, large copy | none |

* **Browser tests:** each person has their own browser context.
  * E-mail is delivered by the real console app into a temporary outbox; tests open the links from those e-mails.
  * `sqlcmd` only arranges time (KI-061) and checks the database trail.
* **One command:** `scripts/testing/Run-AllTests.ps1` runs every layer and prints one summary.
* **Secrets:** no secret is stored. Each run sets a random password on its copy and passes it to the tests in memory.

## 13. Local deployment (Phase 15)

```
 Browser ──► http://localhost:5000 ─┬─ /api/v1/*  → CORS → token check → Web API 2 pipeline → services → ADO.NET → SQL Server
            (one process:           ├─ /<file>    → WebAppMiddleware: a file of the production Angular build (hashed names cached 1 year)
             TalentAcquisition.API) └─ /<route>   → WebAppMiddleware: index.html (Angular routing); anything else → JSON 404
 SQL Server Agent (9 jobs)    ──► TalentAcquisitionDB      (data and maintenance work, nightly and periodic)
 Task Scheduler (7 tasks)     ──► TalentAcquisition.Scheduler.exe ──► TalentAcquisitionDB, storage\mail-outbox, storage\documents
```

* **One origin:** the API serves the production web app from `WebRoot`, so the browser needs no CORS and no proxy, and the tokens never cross origins. `ng serve` on port 4200 remains for UI development only.
* **What the web-app middleware sends:** only GET and HEAD outside `/api/`, and only files inside `WebRoot` with a listed extension. Paths with `..`, `\`, `:` or NUL are refused; Windows' own HTTP listener also rejects encoded traversal with a 403. There is no directory listing.
* **Headers on every page:** `Content-Security-Policy` (`script-src 'self'`, `connect-src 'self'`, `frame-ancestors 'none'`, inline styles allowed for Angular: KI-067), `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff` and `Referrer-Policy: no-referrer`.
* **Caching:** `index.html` is `no-cache`, so a rebuild is picked up at the next navigation without restarting the API.
* **Start, stop, health:** `Start-Tams.ps1` (checks, creates if missing, builds, starts, health), `Stop-Tams.ps1` (only what it started) and `Test-TamsHealth.ps1` (read-only, PASS/WARN/FAIL).
* **Data safety:** no deployment script drops, overwrites or re-seeds an existing database. `Restore-TamsDatabase.ps1` restores under a new name unless `-Replace` is given, and then takes a safety backup first.
