# TAMS — Entity Relationship Diagram (Phase 1 draft for approval)

No tables exist yet. Notation: `||--o{` = one-to-many. Only keys and the main business columns are shown here; the full column list is in `DATABASE_DESIGN.md`.

## 1. Security, organization and the "who is this person" model

```mermaid
erDiagram
  USERS ||--o{ USER_ROLES : has
  ROLES ||--o{ USER_ROLES : grants
  ROLES ||--o{ ROLE_PERMISSIONS : has
  PERMISSIONS ||--o{ ROLE_PERMISSIONS : in
  USERS ||--o{ AUTH_TOKENS : issues
  USERS ||--o{ PASSWORD_RESET_TOKENS : requests
  ORGANIZATIONS ||--o{ DEPARTMENTS : has
  ORGANIZATIONS ||--o{ LOCATIONS : has
  ORGANIZATIONS ||--o{ ORGANIZATION_USERS : employs_staff
  USERS ||--o| ORGANIZATION_USERS : is_staff
  DEPARTMENTS ||--o{ ORGANIZATION_USERS : members
  CUSTOMERS ||--o{ CUSTOMER_USERS : contacts
  USERS ||--o| CUSTOMER_USERS : is_customer_contact
  USERS ||--o| CANDIDATES : self_service_login
  USERS ||--o| CONTRACTORS : self_service_login
```

## 2. Internal recruitment

```mermaid
erDiagram
  DEPARTMENTS ||--o{ EMPLOYEE_REQUISITIONS : requests
  LOCATIONS ||--o{ EMPLOYEE_REQUISITIONS : at
  EMPLOYEE_REQUISITIONS ||--o{ HIRING_APPROVALS : approved_by
  EMPLOYEE_REQUISITIONS ||--o{ JOB_REQUISITIONS : becomes
  JOB_REQUISITIONS ||--o{ JOB_DESCRIPTIONS : versions
  JOB_REQUISITIONS ||--o{ JOB_SKILLS : needs
  JOB_REQUISITIONS ||--o{ JOB_APPROVALS : signed_off
  JOB_REQUISITIONS ||--o{ JOB_POSTINGS : published_as
  RECRUITMENT_SOURCES ||--o{ JOB_POSTINGS : channel
  CANDIDATES ||--o{ JOB_APPLICATIONS : applies
  JOB_POSTINGS ||--o{ JOB_APPLICATIONS : receives
  RECRUITMENT_SOURCES ||--o{ JOB_APPLICATIONS : source
  JOB_APPLICATIONS ||--o{ APPLICATION_STATUS_HISTORY : tracked
  JOB_APPLICATIONS ||--o{ INTERVIEWS : has
  INTERVIEWS ||--o{ INTERVIEW_PANELS : panel
  INTERVIEWS ||--o{ INTERVIEW_FEEDBACK : feedback
  JOB_APPLICATIONS ||--o{ JOB_OFFERS : results_in
  JOB_OFFERS ||--o{ OFFER_APPROVALS : approved_by
  JOB_OFFERS ||--o| EMPLOYEES : accepted_creates
  CANDIDATES ||--o{ EMPLOYEES : becomes
  DEPARTMENTS ||--o{ EMPLOYEES : in
  EMPLOYEES ||--o{ EMPLOYEE_ONBOARDING : tasks
  EMPLOYEES ||--o{ EMPLOYEE_DOCUMENTS : holds
  EMPLOYEES ||--o{ EMPLOYMENT_HISTORY : history
```

## 3. Candidate master (shared by both models)

```mermaid
erDiagram
  CANDIDATES ||--o{ CANDIDATE_ADDRESSES : lives_at
  CANDIDATES ||--o{ CANDIDATE_EDUCATION : studied
  CANDIDATES ||--o{ CANDIDATE_EXPERIENCE : worked
  CANDIDATES ||--o{ CANDIDATE_SKILLS : knows
  CANDIDATES ||--o{ CANDIDATE_DOCUMENTS : uploads
  DOCUMENTS ||--o| CANDIDATE_DOCUMENTS : file
  RECRUITMENT_SOURCES ||--o{ CANDIDATES : sourced_via
  CANDIDATES ||--o{ JOB_APPLICATIONS : "internal opportunity"
  CANDIDATES ||--o{ SUBMITTED_CANDIDATES : "external opportunity"
  CANDIDATES ||--o{ EMPLOYEES : "may become"
  CANDIDATES ||--o{ CONTRACTORS : "may become"
```

## 4. External staffing, timesheets and billing

```mermaid
erDiagram
  CUSTOMERS ||--o{ CUSTOMER_REQUISITIONS : requests
  CUSTOMER_REQUISITIONS ||--o{ SUBMITTED_CANDIDATES : receives
  CANDIDATES ||--o{ SUBMITTED_CANDIDATES : submitted
  SUBMITTED_CANDIDATES ||--o{ CUSTOMER_CANDIDATE_DECISIONS : decided
  SUBMITTED_CANDIDATES ||--o{ INTERVIEWS : interviewed
  SUBMITTED_CANDIDATES ||--o| PLACEMENTS : selected_as
  CUSTOMERS ||--o{ PLACEMENTS : owns
  CONTRACTORS ||--o{ PLACEMENTS : placed
  PLACEMENTS ||--o{ CONTRACTS : under
  CONTRACTS ||--o{ CONTRACT_RATES : priced
  CONTRACTS ||--o{ CONTRACT_EXTENSIONS : extended
  CONTRACTS ||--o{ ASSIGNMENTS : staffed_by
  CONTRACTORS ||--o{ COMPLIANCE_RECORDS : compliance
  CUSTOMERS ||--o{ RATE_CARDS : default_rates
  ASSIGNMENTS ||--o{ TIMESHEETS : weekly
  TIMESHEETS ||--o{ TIMESHEET_ENTRIES : days
  TIMESHEETS ||--o{ TIMESHEET_APPROVALS : approved
  TIMESHEETS ||--o{ TIMESHEET_REJECTIONS : rejected
  CUSTOMERS ||--o{ INVOICES : billed
  INVOICES ||--o{ INVOICE_LINES : lines
  TIMESHEET_ENTRIES ||--o| INVOICE_LINES : billed_once
  INVOICES ||--o{ PAYMENTS : paid_by
```

## 5. Supporting tables

```mermaid
erDiagram
  DOCUMENTS }o--|| USERS : uploaded_by
  DOCUMENTS {
    datetime2 DeletedAt "Phase 12"
    datetime2 FilePurgedAt "Phase 12"
  }
  NOTIFICATION_QUEUE ||--o{ NOTIFICATION_HISTORY : attempts
  USERS ||--o{ NOTIFICATION_QUEUE : recipient
  USERS ||--o{ AUDIT_LOGS : actor
  USERS ||--o{ LOGIN_HISTORY : logins
  JOB_DEFINITIONS ||--o{ JOB_EXECUTION_HISTORY : runs
  USERS ||--o{ REPORT_RUNS : ran_report
```

## 6. Key relationship decisions

| # | Decision | Where enforced |
|---|---|---|
| R1 | One **Candidate Master** row per person (unique normalized email). Applications (internal) and submissions (external) both point at it, so one candidate can pursue many opportunities with no duplication. | UQ on `Candidates.EmailNormalized` |
| R2 | **Employee** and **Contractor** are separate tables, each referencing `CandidateId`. No shared columns beyond the FK. | FKs, no common supertype |
| R3 | **Pay rate and bill rate** live in separate columns of `ContractRates` with an effective date range; invoices use the *bill* rate snapshotted onto `InvoiceLines`. | CHECK `BillRate >= 0`, `PayRate >= 0`; no-overlap enforced in the proc |
| R4 | **Customer isolation:** `CustomerId` is denormalized onto `CustomerRequisitions`, `SubmittedCandidates`, `Placements`, `Contracts`, `Assignments`, `Timesheets`, `Invoices`, `Payments`. Composite FKs keep parent and child on the same customer. | composite FK `(Id, CustomerId)`, plus proc filters |
| R5 | **Interviews** belong to exactly one opportunity type: either `JobApplicationId` (internal) or `SubmittedCandidateId` (external). | CHECK exactly-one-not-null |
| R6 | **No double billing:** an approved `TimesheetEntry` can appear on at most one `InvoiceLine`. | UQ on `InvoiceLines.TimesheetEntryId` |
| R7 | **Duplicate applications / submissions** are blocked, but a withdrawn one may be re-opened. | filtered unique indexes |
| R8 | **Offer → Employee** is 1:1 and created transactionally on acceptance. | UQ on `Employees.JobOfferId` |
| R9 | **Timesheet** is unique per assignment per week; rejection returns it to Draft for resubmission, with history kept in `TimesheetRejections`. | UQ `(AssignmentId, WeekStartDate)` |
| R10 | `ApplicationStatusHistory`, `AuditLogs`, `TimesheetApprovals/Rejections`, `NotificationHistory` are append-only. | triggers block UPDATE/DELETE |

## 7. Tables beyond the spec's list (justified)

| Table | Reason |
|---|---|
| `sec.AuthTokens` | server-side token revocation (logout) |
| `sec.PasswordResetTokens` | password reset workflow |
| `sec.EmailVerificationTokens` | e-mail confirmation of self-registered accounts (Phase 9; FK UserId → sec.Users; token stored as SHA-256 only) |
| `report.ReportDefinitions` | catalog of the 19 parameterised reports (Phase 10; no foreign keys; roles, filters and chart per report) |
| `sched.JobExecutionDetails` | what one scheduled-job run did (Phase 11; FK ExecutionId → sched.JobExecutionHistory) |
| `org.CustomerUsers` | link a Customer-role login to exactly one customer (isolation) |
| `report.DailyRecruitmentSummary` | output of the daily summary Agent job |

No other additions are planned.
