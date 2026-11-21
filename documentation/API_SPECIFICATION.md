# TAMS — API Specification

Base: `http://localhost:5000/api/v1`. Since Phase 15 the same process also serves the web application on every non-`/api/` GET path (`WebRoot`; see ARCHITECTURE section 13): a file of the Angular build or `index.html`, with a Content-Security-Policy. JSON (camelCase). Auth: `Authorization: Bearer <jwt>` on everything except `/auth/register|login|forgot-password|reset-password` and `/health`.

## As built — Phases 4–13 (21 controllers; verified by 68 integration tests; Phases 12 and 13 added no endpoints)

**Phase 13 behaviour (all endpoints):**
* **Rate limits** per client address and minute (`X-Forwarded-For` is ignored): POST /auth/login 20; POST /auth/register, /auth/forgot-password, /auth/resend-verification 5; POST /auth/verify-email, /auth/reset-password 10. Beyond that: **429** `{ code: "rate_limited" }` with `Retry-After` (seconds). The per-account lockout is separate (429 `locked`).
* **Capped lists:** GET /interviews, /offers, /contracts, /contractors, /staffing/requests, /assignments, /timesheets, /timesheets/pending, /invoices return at most the **newest 500** rows. Headers `X-Result-Limit: 500` and `X-Result-Truncated: true|false` (exposed to the browser through CORS). Paged lists (candidates, applications, jobs, users, audit) are unchanged.
* **Errors:** every error has the shape `{ code, message, correlationId, details? }`, including addresses without a route (**404** `not_found`), wrong methods (**405** `method_not_allowed`) and bodies that are not JSON or multipart (**415** `unsupported_media_type`). A database that cannot be reached gives **503** `unavailable` (no server details). A request body without `Content-Length` is read up to the same size limit (**413** `too_large` beyond it).
* **Report runs** are recorded in `audit.ReportRuns` (view or CSV, filters, who, when).

Roles: C Candidate · K Contractor · U Customer · R Recruiter · H HRManager · A Administrator · *any* = any signed-in user. Every endpoint is also checked inside its stored procedure (role **and** data scope); `404` means "not found or not yours". Roles are read from the database on **every** request (not from the token), so role grants and removals apply immediately. Errors: `{ code, message, correlationId, details? }` with codes `validation` / `weak_password` / `invalid_password` 400, `unauthenticated` / `invalid_credentials` 401, `forbidden` 403, `email_unverified` 403 (right password, address not confirmed yet), `not_found` 404, `conflict` / `concurrency` 409, `length_required` 411 (upload without `Content-Length`), `too_large` 413, `unsupported_media_type` 415 (upload not multipart), `business_rule` / `constraint` 422, `locked` 429, `busy` 503 (deadlock after retries, lock timeout), `timeout` 504, `server_error` 500 (no SQL text). Paged lists return `{ items, total, page, pageSize }`.

| Area | Endpoints (method path — roles) |
|---|---|
| Health | GET /health — anonymous |
| Auth | POST /auth/login, /auth/forgot-password (always 202), /auth/reset-password (also confirms the address) — anonymous · POST /auth/register — anonymous, returns 201 `{ email, verificationRequired: true, message }` and does **not** sign in; a confirmation link is e-mailed · POST /auth/verify-email `{ token }` → 200 `{ verified, email }` (single use, 24 h; 422 if used/expired/unknown) · POST /auth/resend-verification `{ email }` → always 202 with the same text (at most one new link per minute; older links stop working) · POST /auth/logout, /auth/change-password, GET /auth/me — *any* |
| Users | GET /users, GET /users/{id}, POST /users, POST /users/{id}/activate, /deactivate, /roles — A |
| Admin | GET /admin/audit-logs, /admin/login-history, /admin/jobs, /admin/jobs/{id}/history, /admin/jobs/runs/{executionId}/details (Phase 11: what a run did — level, message, time); POST /admin/rate-cards, PUT /admin/rate-cards/{id} — A · **E-mail queue (Phase 9):** GET /admin/notifications (`status` Pending/Processing/Sent/Failed/Cancelled, `q`, paging; recipient, subject, status, attempts, next attempt, last error, `isSecurity`; never the message body), GET /admin/notifications/{id}/history (every attempt), POST /admin/notifications/{id}/retry (Failed/Cancelled → Pending with fresh attempts; 422 for Sent/Pending and for sign-in links), POST /admin/notifications/{id}/cancel (Pending only, else 422) — A; retry and cancel are audited |
| Organisation | GET /staff-directory — R, H, A (active staff: id, name, staff roles; no e-mail; for interview-panel pickers) · GET /customers, /customers/{id} — U (own), R, H, A · GET /customers/{id}/balance, /customers/{id}/rate-cards — U (own), R, A · POST /customers, PUT /customers/{id} — A · GET /departments, /locations — R, H, A · POST /departments, PUT /departments/{id} — H, A · GET /sources — C, R, H, A |
| Candidates | GET/PUT /candidates/me, POST /candidates/me/skills, DELETE /candidates/me/skills/{skill} — C · GET /candidates (search: q, skills, minExp, maxExp, status, paging), GET /candidates/{id}, POST /candidates, PUT /candidates/{id}, POST /candidates/{id}/skills, DELETE /candidates/{id}/skills/{skill} — R, H, A |
| Hiring requests | GET /requisitions, /requisitions/{id} — R, H, A · POST /requisitions (`submit: true` submits at once), /requisitions/{id}/submit, /approve, /reject — H, A (not one's own request) |
| Jobs | GET /jobs, /jobs/{id}, POST /jobs (with skills), /jobs/{id}/publish, /jobs/{id}/close — R, H, A · POST /jobs/{id}/approve, /reject — H, A (not the creator) · GET /public/jobs, /public/jobs/{postingId} — C, R, H, A |
| Applications | POST /applications, GET /applications/mine, POST /applications/{id}/withdraw — C · GET /applications/mine/submissions — C, K · GET /applications/{id} — C (own), R, H, A · GET /applications — R, H, A · POST /applications/{id}/status, /shortlist — R, A |
| Interviews | GET /interviews, /interviews/{id} — *any*, scoped (candidates never see feedback) · POST /interviews (`panel` user ids in order; optional `leadUserId`, must be on the panel — default: first listed), PUT /interviews/{id}/reschedule, POST /interviews/{id}/cancel, /feedback — R, H, A, U (own customer's submissions; feedback = panel members only) |
| Offers | GET /offers, POST /offers, POST /offers/{id}/send — R, H, A · POST /offers/{id}/approve, /reject — H, A (not the creator) · GET /offers/mine, POST /offers/{id}/accept, /decline — C (own) |
| Employees | GET /employees, /employees/{id}, POST /employees/{id}/onboarding/{taskId}/complete — H, A |
| Staffing | POST/GET /staffing/requests, GET /staffing/requests/{id}/submissions — U (own), R, A · POST /staffing/requests/{id}/accept, POST /staffing/requests/{id}/submissions, POST /staffing/submissions/{id}/withdraw — R, A · POST /staffing/requests/{id}/cancel — U (own), A · POST /staffing/submissions/{id}/decision (Shortlist/Reject/Select) — U (own). Submissions include `contractNo` once a contract exists |
| Contractors | GET /contractors — U, R, A · GET /contractors/me — K · POST /contractors — R, A · GET /contractors/compliance — K (own), R, A |
| Contracts | GET /contracts, /contracts/{id} — K (own, pay rate only), U (own, bill rate only), R, A · POST /contracts, /contracts/{id}/renew, /terminate — R, A · GET /assignments — K, U, R, A · POST /assignments — R, A |
| Timesheets | GET /timesheets, /timesheets/{id} — K (own), U (own), R, A · GET /timesheets/mine, PUT /timesheets/entries (week + entries TVP), POST /timesheets/{id}/submit — K · GET /timesheets/pending — U, R, A · POST /timesheets/{id}/approve, /reject (reason required) — U (own) |
| Invoices | GET /invoices, /invoices/{id} — U (own, **issued only**: Drafts are hidden from customers), R, A · POST /invoices/generate, /invoices/{id}/issue, /void, /payments — R, A |
| Documents | POST /documents — C, K, R, H, A: `multipart/form-data` with `ownerType` (Candidate · Contractor · Employee · Contract), `ownerId`, optional `docType` (Candidate: Resume, CoverLetter, Certificate, Identity, Other · Employee: Contract, Identity, Offer, Payroll, Certificate, Other), optional `complianceId` (contractor proof; resets the record to Pending), optional `primaryResume`, and exactly one file (pdf/doc/docx/png/jpg/jpeg, content must match, ≤ 10 MB) → 201 `{ documentId, ownerType, ownerId, docType, isPrimaryResume }`; refused files 400 `invalid_file` with nothing stored · GET /documents?ownerType&ownerId — *any*, only the files the caller may read (each with `canDelete`) · GET /documents/{id}/download — *any* with access: the bytes as an attachment (original name, `nosniff`, sandbox CSP) after a size and SHA-256 check (500 `document_integrity` / `document_missing`) · DELETE /documents/{id} — C, K, R, H, A who may manage the owner (soft delete) · Who may manage: Candidate → the candidate, R, H; Contractor → the contractor, R; Employee → H; Contract → R; A always · Who may read: as above, plus a customer for **résumés only** of candidates submitted to it at Shortlisted/Interview/Selected, the employee for own files, the contract's customer and contractor. Anything else is 404 |
| Compliance | POST /compliance/{id}/decision `{ status: Verified \| Rejected, notes }` — R, A. Verified needs an attached proof (422); Rejected needs `notes` (400); the contractor is notified; `GET /contractors/compliance` and `/contractors/me` include `documentId` and `notes` |
| Notifications | GET /notifications (each item also has `emailStatus` and `emailedAt`; sign-in-link messages are e-mail only and never listed), POST /notifications/read-all, /notifications/{id}/read — *any* (own) |
| Reports (Phase 10) | GET /reports: the caller's catalog (`reportCode, category, title, description, dateFilter, usesDays, customerScoped, canFilterCustomer, chartLabel, chartValue, chartAggregate`) — U, R, H, A (candidates and contractors 403) · GET /reports/{code}?from=yyyy-MM-dd&to=yyyy-MM-dd&customerId&days → `{ report, columns: [{ key, label, type }], rows, rowCount, truncated, generatedAt, from, to, customerId, days }` (types: text, number, money, percent, hours, date, datetime, bool; at most 10,000 rows) · GET /reports/{code}/csv: the same as a CSV attachment (UTF-8 BOM, formula-safe). Codes: recruitment `open-requisitions, applications-by-status, pipeline, sourcing, interview-conversion, offer-acceptance, time-to-hire, recruiter-performance` (R, H, A); staffing `staffing-requests, submissions, placements, active-contractors, expiring-contracts, pending-timesheets, customer-invoices, outstanding-payments` (R, A; U own company: another `customerId` → 404; never pay rate or margin); HR `onboarding, department-hiring, requisition-status` (H, A). Errors: unknown code 404, role 403, from > to or days outside 1–365 → 400 |
| Dashboards | GET /dashboards/{role} (`Candidate`, `Contractor`, `Customer`, `Recruiter`, `HRManager`, `Administrator`) — the matching role; every metric computed by `report.usp_Dashboard` |

**Differences from the Phase 1 plan below:** offers are created directly in `PendingApproval` (no separate `/submit`); withdrawal is `POST /applications/{id}/withdraw` (not `DELETE`); timesheets are saved with `PUT /timesheets/entries` (the week identifies the sheet); documents use `GET /documents?ownerType&ownerId` for lists (added) and multipart upload as planned; candidate education/experience/addresses and reports endpoints come with later phases (KI-019, Phase 10); `/admin/health` is covered by `/health` + `--check`.

---

## Phase 1 plan (kept for reference)

Conventions
* Lists: `?page=1&pageSize=25&sort=field:asc&q=...&status=...` → `{ items:[…], total, page, pageSize }`.
* Errors: `{ code, message, details? }` with status `400` validation · `401` unauthenticated · `403` role/permission · `404` not found *or outside caller's customer scope* · `409` duplicate / concurrency · `422` business-rule violation · `500` generic (no SQL text leaked).
* Identity of the caller (candidate id, contractor id, customer id) always comes from the token, never from the body or URL.
* Roles: **C**andidate, **K**=Contractor, **U**=Customer, **R**ecruiter, **H**R Manager, **A**dmin.

## Auth — `AuthController`
| Method & path | Roles | Purpose |
|---|---|---|
| POST /auth/register | anon | Candidate self-registration (creates user + candidate master, or links an existing one by email) |
| POST /auth/login | anon | Returns token, role, profile |
| POST /auth/logout | any | Revoke token |
| POST /auth/forgot-password | anon | Queue reset email (always 202) |
| POST /auth/reset-password | anon | Consume single-use token |
| POST /auth/change-password | any | |
| GET /auth/me | any | Current user + permissions |

## Admin — `UsersController`, `AdminController`
| GET/POST /users, GET/PUT /users/{id}, POST /users/{id}/deactivate, /activate, /roles | A | User management |
| GET /admin/audit-logs, /admin/login-history | A | Filterable, paged |
| GET /admin/jobs, GET /admin/jobs/{id}/history | A | Scheduler definitions + execution history |
| GET/POST/PUT /admin/rate-cards | A | Customer rate cards |
| GET /admin/health | A | DB connectivity, queue depth |
| GET/POST/PUT /customers, GET /customers/{id} | A (all), R (read), U (own only) | Customers and their contacts |
| GET/POST/PUT /departments | A, H | |

## Candidates — `CandidatesController`
| GET /candidates/me, PUT /candidates/me | C | Own profile (+ addresses, education, experience, skills sub-resources) |
| GET/POST/DELETE /candidates/me/skills, /education, /experience, /addresses | C | |
| GET /candidates?q=&skills=&minExp=&status= | R, H, A | Search shared candidate master |
| GET /candidates/{id} | R, H, A | Full profile |
| POST /candidates | R, A | Recruiter-created candidate (duplicate email → 409 with existing id) |
| PUT /candidates/{id} | R, A | |

## Internal recruitment
| `RequisitionsController` | | |
|---|---|---|
| POST /requisitions | H, A | Department hiring request (`hr.EmployeeRequisitions`) |
| GET /requisitions, GET /requisitions/{id} | H, R (approved only), A | |
| POST /requisitions/{id}/submit | H, A | |
| POST /requisitions/{id}/approve, /reject | H, A (not own request) | |
| POST /jobs | R, H, A | Create job from an approved requisition |
| PUT /jobs/{id}, GET /jobs, GET /jobs/{id} | R, H, A | |
| POST /jobs/{id}/approve | H, A | Job-content sign-off |
| POST /jobs/{id}/publish, /close | R, H, A | Creates/closes posting |
| GET /public/jobs, GET /public/jobs/{postingId} | C (and anon browse optional) | Published postings only |
| `ApplicationsController` | | |
| POST /applications `{postingId}` | C | Apply (duplicate → 409) |
| GET /applications/mine, DELETE /applications/{id} (withdraw) | C | Own only |
| GET /applications?jobId=&status= | R, H, A | Pipeline |
| POST /applications/{id}/status `{status, reason}` | R, A | Screening/shortlist/reject/select; history written |
| `InterviewsController` | | |
| POST /interviews | R, H, A (external: U for own customer) | Schedule |
| PUT /interviews/{id}/reschedule, POST /{id}/cancel | same | |
| GET /interviews, GET /interviews/{id} | R, H, A, U (own), C/K (own) | |
| POST /interviews/{id}/feedback | panel members (R, H, U) | One per interviewer |
| `OffersController` | | |
| POST /offers | R, H, A | Create from selected application |
| POST /offers/{id}/submit | R, H, A | → PendingApproval |
| POST /offers/{id}/approve, /reject | H, A (not creator) | |
| POST /offers/{id}/send | R, H, A | Notifies candidate |
| GET /offers/mine | C | |
| POST /offers/{id}/accept, /decline | C (own) | Accept runs the employee-creation transaction |
| `EmployeesController` | | |
| GET /employees, GET /employees/{id} | H, A | |
| GET /employees/{id}/onboarding, POST /employees/{id}/onboarding/{taskId}/complete | H, A | |
| POST/GET /employees/{id}/documents | H, A | |

## External staffing
| `CustomerRequisitionsController` (route `/staffing/requests`) | | |
|---|---|---|
| POST /staffing/requests | U (own), R, A | Create staffing request |
| GET /staffing/requests, GET /{id} | U (own only), R, A | |
| POST /staffing/requests/{id}/accept, /assign `{recruiterId}` | R, A | Recruiter review |
| POST /staffing/requests/{id}/cancel | U (own), A | |
| POST /staffing/requests/{id}/submissions `{candidateId, proposedBillRate}` | R, A | Submit candidate (duplicate → 409) |
| GET /staffing/requests/{id}/submissions | U (own), R, A | Customer sees candidate summary, not private contact data until shortlisted |
| POST /staffing/submissions/{id}/decision `{decision, comments}` | U (own) | Shortlist / reject / select |
| POST /staffing/submissions/{id}/withdraw | R, A | |
| `ContractorsController` | | |
| POST /contractors `{candidateId}` | R, A | Creates contractor from candidate master |
| GET /contractors, GET /contractors/{id} | R, A; U (own placed only) | |
| GET /contractors/me | K | |
| GET/POST /contractors/{id}/compliance | R, A; K (own, upload) | |
| `ContractsController` | | |
| POST /contracts `{submissionId, startDate, endDate, payRate, billRate}` | R, A | Transaction: contractor + placement + contract + rates + assignment |
| GET /contracts, GET /contracts/{id} | R, A; U (own); K (own) | |
| POST /contracts/{id}/renew `{newEndDate, payRate?, billRate?}` | R, A | |
| POST /contracts/{id}/terminate | R, A | |
| `AssignmentsController` | | |
| GET /assignments, GET /assignments/mine | R, A, U (own); K (own) | |
| PUT /assignments/{id} | R, A | |
| `TimesheetsController` | | |
| GET /timesheets/mine, GET /timesheets/{id} | K (own) | |
| PUT /timesheets/{id}/entries | K (own, Draft/Rejected only) | |
| POST /timesheets/{id}/submit | K (own) | |
| GET /timesheets/pending | U (own) | |
| POST /timesheets/{id}/approve, /reject `{reason}` | U (own) | |
| `InvoicesController` | | |
| POST /invoices/generate `{customerId, periodStart, periodEnd}` | R, A | Approved, uninvoiced billable entries only; transactional |
| GET /invoices, GET /invoices/{id} | R, A; U (own) | |
| POST /invoices/{id}/issue, /void | R, A | |
| POST /invoices/{id}/payments `{amount, paidOn, method, reference}` | R, A | Updates balance/status |
| GET /customers/{id}/balance | R, A; U (own) | `fn_CustomerOutstandingBalance` |

## Documents, notifications, reports
| POST /documents (multipart) | owner-dependent | Upload with validation |
| GET /documents/{id}/download, DELETE /documents/{id} | authorized owner scope | Streams file after access check |
| GET /notifications, POST /notifications/{id}/read, POST /notifications/read-all | any | In-app list for the caller (Phase 9: every notification is also e-mailed by the scheduler console app, not by the API) |
| ~~GET /reports/recruitment/…, /reports/staffing/…, /reports/hr/…~~ | | **Superseded in Phase 10** by `GET /reports/{code}` with one catalog (see *As built*) |
| GET /dashboards/{candidate\|contractor\|customer\|recruiter\|hr\|admin} | matching role | Dashboard card data, all computed in SQL |
| GET /health | anon | API + DB reachability only |

## Database contract for the API (Phase 3, verified)
Every endpoint calls ONE stored procedure (ADO.NET `CommandType.StoredProcedure`, parameters always bound) with the caller's `UserId` as `@ActorUserId`. Procedure errors map to HTTP: `50001→400`, `50005→403`, `50004→404`, `50003→409`, `50006→409`, `50002→422`; `1205` (deadlock victim) is retried by the data layer up to 3 times; `1222` → 503; anything else → 500 without SQL text. Examples: `POST /auth/login` → `sec.usp_GetUserForLogin` + `sec.usp_RecordLoginAttempt` + `sec.usp_IssueToken`; `POST /applications` → `cand.usp_CreateApplication`; `POST /offers/{id}/accept` → `cand.usp_RespondToOffer`; `POST /contracts` → `staff.usp_CreateContract`; `PUT /timesheets/{id}/entries` → `time.usp_SaveTimesheet` (TVP); `POST /invoices/generate` → `bill.usp_GenerateInvoice`; list/read endpoints use `report.vw_*` through procedures that apply the caller's scope (`staff.usp_ListCustomerRequisitions`, `bill.usp_ListInvoices`, `time.usp_ListPendingTimesheets`, …). The full procedure catalogue is in `DATABASE_DESIGN.md`.

## Dashboard features (every item backed by an endpoint above)
* **Candidate:** profile, resume upload, browse/apply to jobs, my applications + status timeline, interviews, offers (accept/decline), notifications.
* **Contractor:** profile, compliance docs, active assignments/contract, timesheet entry & submission, rejection feedback and resubmission, approved/invoiced status.
* **Customer:** staffing requests, submitted candidates (shortlist/reject/select), interviews, contractors, timesheet approvals, invoices, payments/balance, reports.
* **Recruiter:** job management, application pipeline, candidate search, interviews, offers, staffing requests, submissions, contractor/contract creation, invoicing, payments, reports.
* **HR Manager:** hiring requests, requisition/job/offer approvals, employees, onboarding, department hiring reports.
* **Administrator:** users/roles, customers, departments, rate cards, audit and login history, scheduler job status, system health.
