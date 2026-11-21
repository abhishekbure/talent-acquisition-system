# TAMS — Database Design

Database `TalentAcquisitionDB`, **SQL Server 2019 Developer** (version change from 2014 approved 2026-11-19; classic-style design, default compatibility level), schemas: `sec org rec cand hr staff time bill doc notify audit report sched`.

## As built (Phase 2 scripts)
Scripts are in `database/01_Database … 12_Tests` and are repeatable (tables guarded by `OBJECT_ID`, constraints/indexes created from tables of definitions only when missing; nothing drops data). **Executed and verified on the real SQL Server 2019 Developer instance: 64/64 database tests pass and re-running the scripts is a no-op (see `TEST_RESULTS.md`).**

| Object | Count |
|---|---|
| Schemas / tables | 13 / 64 |
| Primary keys (clustered, identity) | 64 |
| Unique constraints | 43 |
| Foreign keys (incl. composite customer-isolation keys) | 117 |
| Check constraints | 84 |
| Default constraints | 120 |
| Nonclustered indexes (incl. 4 filtered-unique) | 83 |

Differences from the Phase 1 draft below:
* `JobApprovals`, `HiringApprovals`, `OfferApprovals` have **no** unique (item, approver) constraint, so a resubmitted item can be approved again by the same approver; "approver ≠ requester/creator" is enforced in the Phase 3 procedures (seed data already respects it and a test checks it).
* `audit.AuditLogs` and `audit.LoginHistory` deliberately have **no foreign keys**, so logging can never fail or block user maintenance.
* `Timesheets.WeekStartDate` must be a Monday (`DATEDIFF(DAY,'19000101',d) % 7 = 0`, independent of `DATEFIRST`).
* Customer isolation is enforced structurally by composite FKs `(Id, CustomerId)` on submissions, placements, contracts, assignments, timesheets, payments and external interviews.
* `ContractRates` requires `BillRate >= PayRate` (KI-010).
* Dev users are seeded with an unusable placeholder hash; `Set-DevPasswords.ps1` sets real PBKDF2-SHA256 hashes (210,000 iterations, 32-byte salt).

## Database logic as built (Phase 3 — verified)

Conventions used by every procedure: first parameter `@ActorUserId` (from the validated token, never from the client); `sec.usp_Authorize` re-checks the role and stamps `CONTEXT_INFO` so triggers audit the actor; errors are `THROW`n with API-mappable numbers — **50001** validation (400), **50002** business rule (422), **50003** duplicate/conflict (409), **50004** not found *or outside the caller's scope* (404), **50005** forbidden (403), **50006** concurrency conflict (409), **50010** append-only violation; a procedure owns its transaction only when none is open, otherwise it uses a SAVEPOINT (so procedures compose and tests roll back); `SET XACT_ABORT OFF` + `TRY/CATCH`; locks (`UPDLOCK, HOLDLOCK`) on the row that guards each business rule.

| Schema | Procedures (69 in total) |
|---|---|
| `sec` (13) | Authorize, GetUserForLogin, RecordLoginAttempt (5 failures → 15-minute lock), IssueToken, ValidateToken, RevokeToken, RevokeUserTokens, CreatePasswordReset, ConsumePasswordReset, ChangePassword, RegisterCandidate, CreateUser, SetUserActive |
| `hr` (5) | CreateEmployeeRequisition, SubmitEmployeeRequisition, DecideEmployeeRequisition, CreateEmployeeFromOffer (internal, runs inside the acceptance transaction), CompleteOnboardingTask |
| `rec` (4) | CreateJob (TVP of skills), DecideJob, PublishJob, CloseJob |
| `cand` (18) | CreateCandidate, UpdateCandidate (row-version check), GetCandidate, AddCandidateSkill, RemoveCandidateSkill, SearchCandidates, CreateApplication, WithdrawApplication, ChangeApplicationStatus (transition table), ShortlistApplication, ScheduleInterview (internal + external), RescheduleInterview, CancelInterview, SubmitInterviewFeedback, CreateOffer, DecideOffer, SendOffer, RespondToOffer |
| `staff` (14) | CreateCustomerRequisition, AcceptCustomerRequisition, CancelCustomerRequisition, SubmitCandidateToCustomer, DecideSubmission, WithdrawSubmission, ListCustomerRequisitions, GetSubmissionsForRequisition, CreateContractor (+ Internal), CreateContract (one transaction), CreateAssignment, RenewContract, TerminateContract |
| `time` (6) | SaveTimesheet (TVP of entries), SubmitTimesheet, ApproveTimesheet, RejectTimesheet, ListPendingTimesheets, GetMyTimesheets |
| `bill` (6) | GenerateInvoice, IssueInvoice, VoidInvoice, RecordPayment, ListInvoices, GetCustomerBalance |
| `notify` (3) | Enqueue (idempotent: key = caller key + entity + recipient), EnqueueForCustomer, MarkRead |

Functions (16): `dbo.fn_PadNumber`, `dbo.fn_SplitCsv` (recursive CTE, ≤ 99 items), `sec.fn_UserHasRole`, `sec.fn_UserCustomerId`, `cand.fn_CandidateIdForUser`, `staff.fn_ContractorIdForUser`, `cand.fn_ExperienceYears`, `staff.fn_ContractDurationDays`, `staff.fn_DaysToContractExpiry`, `cand.fn_ApplicationAgeDays`, `cand.fn_TimeToHireDays`, `bill.fn_InvoiceBalance`, `bill.fn_CustomerOutstandingBalance`, `cand.fn_CandidateSkills` (TVF), `cand.fn_SearchCandidates` (TVF), `staff.fn_EffectiveRate` (TVF).
Triggers: audit on Candidates, JobRequisitions, Interviews, JobOffers, Contracts, Timesheets, Invoices; status history on JobApplications; append-only on ApplicationStatusHistory (only an empty Reason may be filled), AuditLogs, TimesheetApprovals, TimesheetRejections, EmploymentHistory; DDL trigger `trg_DDL_SchemaAudit`.
Views (`report`): vw_OpenRequisitions, vw_RecruitmentPipeline, vw_CandidateApplicationStatus, vw_UpcomingInterviews, vw_PendingOffers, vw_ActiveEmployees, vw_ActiveContractors (no pay rate), vw_ExpiringContracts, vw_PendingTimesheets, vw_CustomerInvoices, vw_RecruitmentPerformance.
Sequences: `rec.seq_JobCode`, `hr.seq_RequisitionNo`, `hr.seq_EmployeeNo`, `cand.seq_OfferNo`, `staff.seq_ContractorNo`, `staff.seq_ContractNo`, `staff.seq_RequestNo`, `bill.seq_InvoiceNo` (re-aligned by `10_SeedData/05_Sync_Sequences.sql`). Table types: `dbo.IdList`, `rec.JobSkillList`, `time.TimesheetEntryList`.
Permissions: `tams_app_role` = EXECUTE on the procedure schemas and the three types + SELECT on `report`; `tams_report_role` = SELECT on `report`; neither has any table permission (ownership chaining lets procedures reach the tables).

## Phase 1 design reference (original draft)

Conventions: surrogate `INT IDENTITY` primary keys named `<Table>Id`; `CreatedAt DATETIME2(0) DEFAULT SYSUTCDATETIME()`, `CreatedBy`, `UpdatedAt`, `UpdatedBy`; `RowVer ROWVERSION` on mutable aggregates; status columns are `VARCHAR` with `CHECK (Status IN (...))`; money `DECIMAL(12,2)`, rates `DECIMAL(10,2)`, hours `DECIMAL(5,2)`; text in `NVARCHAR`. Dates in UTC.

## sec
| Table | Key columns / rules |
|---|---|
| Users | UserId, Email (UQ, normalized), PasswordHash, PasswordSalt, Iterations, IsActive, FailedLoginCount, LockoutUntil, LastLoginAt |
| Roles | RoleId, RoleName UQ — seeded: Candidate, Contractor, Customer, Recruiter, HRManager, Administrator |
| UserRoles | (UserId, RoleId) PK |
| Permissions | PermissionId, Code UQ (e.g. `requisition.approve`) |
| RolePermissions | (RoleId, PermissionId) PK |
| AuthTokens | Jti UQ, UserId, IssuedAt, ExpiresAt, RevokedAt |
| PasswordResetTokens | TokenHash UQ, UserId, ExpiresAt, UsedAt |

## org
| Table | Key columns / rules |
|---|---|
| Organizations | OrganizationId, Name — single internal organization |
| OrganizationUsers | UserId UQ→sec.Users, OrganizationId, DepartmentId, JobTitle, IsHiringManager |
| Departments | DepartmentId, OrganizationId, Name, UQ(OrganizationId, Name) |
| Locations | LocationId, OrganizationId, City, Country |
| Customers | CustomerId, Name UQ, Code UQ, Status, BillingEmail, PaymentTermsDays |
| CustomerUsers *(added)* | UserId UQ→sec.Users, CustomerId→Customers |

## rec
| Table | Key columns / rules |
|---|---|
| RecruitmentSources | SourceId, Name UQ (Portal, Referral, LinkedIn, Agency, …) |
| JobRequisitions | JobRequisitionId, EmployeeRequisitionId→hr, JobCode UQ, Title, Openings, Status (Draft/PendingApproval/Approved/Open/OnHold/Filled/Closed/Expired), OwnerRecruiterId |
| JobDescriptions | JobDescriptionId, JobRequisitionId, VersionNo, Responsibilities, Qualifications, MinExperienceYears, SalaryMin/Max, UQ(JobRequisitionId, VersionNo) |
| JobSkills | (JobRequisitionId, SkillName), IsRequired, MinYears |
| JobApprovals | JobApprovalId, JobRequisitionId, ApproverUserId, Decision, DecidedAt, Comments |
| JobPostings | JobPostingId, JobRequisitionId, SourceId, PostedAt, ClosesAt, Status (Draft/Published/Closed) |

## cand
| Table | Key columns / rules |
|---|---|
| Candidates | CandidateId, UserId (nullable UQ), FirstName, LastName, Email, **EmailNormalized UQ**, Phone, TotalExperienceYears, CurrentTitle, SourceId, Status |
| CandidateAddresses / Education / Experience / Skills | child tables by CandidateId; Skills UQ(CandidateId, SkillName) |
| CandidateDocuments | CandidateId, DocumentId→doc.Documents, DocType (Resume/ID/Certificate/Other) |
| JobApplications | ApplicationId, CandidateId, JobPostingId, SourceId, Status (Applied/Screening/Shortlisted/Interview/Selected/OfferStage/Hired/Rejected/Withdrawn), AppliedAt. **Filtered UQ(CandidateId, JobPostingId) WHERE Status<>'Withdrawn'** |
| ApplicationStatusHistory | append-only: ApplicationId, OldStatus, NewStatus, ChangedBy, ChangedAt, Reason |
| Interviews | InterviewId, JobApplicationId NULL, SubmittedCandidateId NULL, **CHECK exactly one not null**, RoundNo, StartsAt, EndsAt, Mode, LocationOrLink, Status (Scheduled/Rescheduled/Completed/Cancelled/NoShow), CustomerId NULL (set for external) |
| InterviewPanels | (InterviewId, UserId→sec.Users) |
| InterviewFeedback | InterviewId, InterviewerUserId, Rating 1–5, Recommendation (StrongYes/Yes/No/StrongNo), Comments, UQ(InterviewId, InterviewerUserId) |
| JobOffers | OfferId, ApplicationId, OfferedSalary, Currency, StartDate, ExpiresAt, Status (Draft/PendingApproval/Approved/Rejected/Sent/Accepted/Declined/Expired), CreatedBy |
| OfferApprovals | OfferId, ApproverUserId, Decision, DecidedAt; **CHECK handled in proc: approver ≠ creator** |

## hr
| Table | Key columns / rules |
|---|---|
| EmployeeRequisitions | EmployeeRequisitionId, DepartmentId, LocationId, Title, Headcount, Justification, BudgetMax, Status (Draft/Submitted/Approved/Rejected/Cancelled), RequestedBy |
| HiringApprovals | EmployeeRequisitionId, ApproverUserId, Decision, DecidedAt, Comments |
| Employees | EmployeeId, EmployeeNo UQ, CandidateId, **JobOfferId UQ**, DepartmentId, JobTitle, StartDate, Salary, Status (Onboarding/Active/Terminated) |
| EmployeeOnboarding | EmployeeId, TaskName, DueDate, Status (Pending/Done), CompletedBy, CompletedAt |
| EmployeeDocuments | EmployeeId, DocumentId, DocType |
| EmploymentHistory | EmployeeId, EventType, EffectiveDate, Details — append-only |

## staff
| Table | Key columns / rules |
|---|---|
| Contractors | ContractorId, **CandidateId UQ**, UserId (nullable UQ), Status (Active/Inactive/Blocked) |
| CustomerRequisitions | CustomerRequisitionId, CustomerId, Title, Positions, SkillsRequired, StartDate, DurationMonths, MaxBillRate, Status (Open/InReview/Sourcing/Filled/Cancelled), AssignedRecruiterId |
| SubmittedCandidates | SubmissionId, CustomerRequisitionId, CustomerId, CandidateId, ProposedBillRate, Status (Submitted/Shortlisted/Rejected/Interview/Selected/Withdrawn), **Filtered UQ(CustomerRequisitionId, CandidateId)** |
| CustomerCandidateDecisions | SubmissionId, CustomerId, DecidedByUserId, Decision (Shortlist/Reject/Select), Comments, DecidedAt |
| Placements | PlacementId, SubmissionId UQ, CustomerId, ContractorId, Status |
| Contracts | ContractId, PlacementId, CustomerId, ContractNo UQ, StartDate, EndDate (CHECK End>Start), Status (Draft/Active/Expiring/Expired/Terminated/Renewed) |
| Assignments | AssignmentId, ContractId, CustomerId, RoleTitle, HoursPerWeek, StartDate, EndDate, Status |
| ContractRates | ContractId, **PayRate**, **BillRate**, OvertimeMultiplier, EffectiveFrom, EffectiveTo; no overlap per contract |
| ContractExtensions | ContractId, OldEndDate, NewEndDate, Reason, ApprovedBy |
| ComplianceRecords | ContractorId, RecordType (BackgroundCheck/WorkAuth/NDA/…), Status, ExpiresOn, DocumentId |

## time
| Table | Key columns / rules |
|---|---|
| Timesheets | TimesheetId, AssignmentId, ContractorId, CustomerId, WeekStartDate, Status (Draft/Submitted/Approved/Rejected/Invoiced), TotalHours, **UQ(AssignmentId, WeekStartDate)** |
| TimesheetEntries | TimesheetId, WorkDate, Hours CHECK 0–24, EntryType (Regular/Overtime), IsBillable, Notes; UQ(TimesheetId, WorkDate, EntryType) |
| TimesheetApprovals | TimesheetId, ApprovedByUserId, ApprovedAt — append-only |
| TimesheetRejections | TimesheetId, RejectedByUserId, Reason NOT NULL, RejectedAt — append-only |

## bill
| Table | Key columns / rules |
|---|---|
| RateCards | RateCardId, CustomerId, RoleCategory, StandardBillRate, EffectiveFrom/To |
| Invoices | InvoiceId, InvoiceNo UQ, CustomerId, PeriodStart/End, Subtotal, Tax, Total, Status (Draft/Issued/PartiallyPaid/Paid/Void), DueDate |
| InvoiceLines | InvoiceId, **TimesheetEntryId UQ**, Description, Hours, BillRate (snapshot), LineTotal |
| Payments | PaymentId, InvoiceId, CustomerId, Amount CHECK >0, PaidOn, Method, Reference, RecordedBy |

## doc, notify, audit, sched, report
| Table | Key columns / rules |
|---|---|
| doc.Documents | DocumentId, OwnerType, OwnerId, CustomerId NULL, StoredFileName (GUID), OriginalFileName, ContentType, SizeBytes, Sha256, UploadedBy |
| notify.NotificationQueue | NotificationId, TemplateCode, RecipientUserId, ToEmail, Subject, Body, **DedupeKey UQ**, Status (Pending/Processing/Sent/Failed/Cancelled), Attempts, NextAttemptAt |
| notify.NotificationHistory | NotificationId, AttemptNo, Outcome, ErrorMessage, AttemptedAt |
| audit.AuditLogs | AuditId, TableName, RecordId, Action (I/U/D), OldValues, NewValues (text), ChangedBy, ChangedAt |
| audit.LoginHistory | UserId NULL, Email, Success, FailureReason, IpAddress, AttemptedAt |
| sched.JobDefinitions | JobDefinitionId, JobName UQ, Owner (SqlAgent/TaskScheduler), IsEnabled |
| sched.JobExecutionHistory | JobDefinitionId, StartedAt, FinishedAt, Outcome, RowsAffected, ErrorMessage |
| report.DailyRecruitmentSummary *(added)* | SummaryDate PK, counts per stage |

## Indexing plan (to be validated with execution plans in Phase 3)
Nonclustered on every FK; composite `(Status, CreatedAt)` on requisitions, applications, timesheets, invoices; `(CustomerId, Status)` on staff/time/bill tables; `(CandidateId)` + `(EmailNormalized)` on candidates; `(ExpiresAt) WHERE Status='Active'` filtered index on contracts; `(Status, NextAttemptAt)` on notification queue.

## Stored procedures (Phase 3 catalogue, prefix `<schema>.usp_`)
Candidate Upsert/Search · Requisition Create/Submit/Approve · Job Create/Publish · Application Create/ChangeStatus/Shortlist · Interview Schedule/Reschedule/SubmitFeedback · Offer Create/Approve/Respond · Employee CreateFromOffer · Onboarding Complete · CustomerRequisition Create · Candidate SubmitToCustomer · Customer Decide · Contractor/Contract/Placement/Assignment Create · Contract Renew · Timesheet Submit/Approve/Reject · Invoice Generate · Payment Record · Report procedures · scheduled maintenance procedures.

Functions: `fn_ExperienceYears`, `fn_ContractDurationDays`, `fn_ApplicationAgeDays`, `fn_TimeToHireDays`, `fn_DaysToContractExpiry`, `fn_CustomerOutstandingBalance`, `fn_CandidateSkills` (TVF), `fn_SearchCandidates` (TVF).

Triggers (multi-row safe, audit/history only): Candidates, JobRequisitions, JobApplications (status history), Interviews, JobOffers, Contracts, Timesheets, Invoices.

Views: vw_OpenRequisitions, vw_RecruitmentPipeline, vw_CandidateApplicationStatus, vw_UpcomingInterviews, vw_PendingOffers, vw_ActiveEmployees, vw_ActiveContractors, vw_ExpiringContracts, vw_PendingTimesheets, vw_CustomerInvoices, vw_RecruitmentPerformance.

## Seed data (Phase 2)
1 organization, 5 departments, 3 locations, 3 customers, 1+ user per role (2 recruiters, 2 HR managers, 3 customer users, 2 contractors, ~15 candidates), requisitions in every status, applications across stages, interviews, offers, 2 contractors with contracts, timesheets, invoices, payments. Development passwords are **generated at setup time**, written to an untracked `dev-credentials.local.md`, and never committed.

## Phase 5 changes (for the UI)
* **New** `sec.usp_ListStaffDirectory @ActorUserId` (Recruiter, HRManager, Administrator): active users holding a staff role, returning `UserId, DisplayName, Roles` (staff roles only, no e-mail). Feeds interview-panel pickers. Scope tests Q53–Q54.
* `staff.usp_GetSubmissionsForRequisition` also returns `ContractNo` (the contract created from the submission, if any).
* `bill.usp_ListInvoices` and `bill.usp_GetInvoice`: customers no longer see **Draft** invoices (list excludes them; by id returns 50004). Staff still see drafts. Scope tests Q55–Q56.
* `report.usp_Dashboard` (HR Manager): metric `employees` relabelled "Headcount (incl. onboarding)"; the value is unchanged.
* Verified by a clean build into a new database: 304/304 SQL tests.

## Phase 6 changes
* `cand.usp_ScheduleInterview` gains `@LeadUserId INT = NULL`: the lead interviewer, validated to be on the panel (50001 otherwise); without it the lowest user id leads (previous behaviour). The API always passes it (first listed interviewer by default).
* Verified by a clean build into a new database: 304/304 SQL tests.

## Phase 7 changes
* `sec.usp_ValidateToken` (called on every API request) now also returns `Roles` (the user's current roles as a comma list). The API authorises from these, so role changes take effect on existing tokens immediately (KI-030).
* Verified by a clean build into a new database: 304/304 SQL tests.

## Phase 8 changes (document management, `06_StoredProcedures/11_Documents.sql`)
* **Access functions**
  * `doc.fn_CanManageOwner(@ActorUserId, @OwnerType, @OwnerId)` — who may upload or delete for an owner:
    * Administrator: always.
    * Candidate: Recruiter, HRManager, or the candidate themself.
    * Contractor: Recruiter or the contractor themself.
    * Employee: HRManager.
    * Contract: Recruiter.
  * `doc.fn_CanAccessDocument(@ActorUserId, @DocumentId)` — who may read a file. A deleted document is never readable. Otherwise:
    * Candidate files: staff, the candidate, and a customer for **Resume** files only, of candidates submitted to that customer at Shortlisted/Interview/Selected.
    * Contractor files: Recruiter or the contractor.
    * Employee files: HRManager or the employee's own login.
    * Contract files: Recruiter, the contract's customer, or its contractor.
* **Procedures**
  * `doc.usp_AddDocument(@ActorUserId, @OwnerType, @OwnerId, @DocType, @StoredFileName, @OriginalFileName, @ContentType, @SizeBytes, @Sha256, @ComplianceId, @IsPrimaryResume)`:
    * Validates the stored name (generated, no path characters), size (1 byte–10 MB), document type per owner, and that the owner exists and the caller may manage it (50004 otherwise).
    * Links the file to `cand.CandidateDocuments` (the first résumé becomes the main one, and asking for main moves the flag), `hr.EmployeeDocuments`, `staff.Contracts.DocumentId` or `staff.ComplianceRecords.DocumentId`. A contractor's own proof resets that record to Pending.
  * `doc.usp_ListDocuments(@ActorUserId, @OwnerType, @OwnerId)` returns only the files the caller may read, with `CanDelete`.
  * `doc.usp_GetDocumentForDownload(@ActorUserId, @DocumentId)` returns the stored name, size and SHA-256 only after the access check (50004 otherwise).
  * `doc.usp_DeleteDocument(@ActorUserId, @DocumentId)` is a soft delete (`IsDeleted = 1`). It clears the contract and compliance links and the main-résumé flag.
  * `staff.usp_DecideCompliance(@ActorUserId, @ComplianceId, @Status, @Notes)`:
    * Recruiter or Administrator only.
    * `Verified` requires an attached document (50002); `Rejected` requires notes (50001).
    * Records who decided and when, and queues `COMPLIANCE_DECISION` for the contractor.
  * `staff.usp_ListCompliance` and the compliance set of `staff.usp_GetMyContractor` also return `DocumentId` (and `Notes` in the list).
* **Triggers:** `doc.trg_Documents_Audit` and `staff.trg_ComplianceRecords_Audit`. Both write to `audit.AuditLogs` with the acting user from `CONTEXT_INFO`. The second was added after the live check showed that compliance decisions were not audited (KI-035).
* **Permissions:** `GRANT EXECUTE ON SCHEMA::doc TO tams_app_role` (in `07_Security_Roles.sql`). `doc.Documents` still cannot be SELECTed by the application role.
* **Tests:** `12_Tests/05_Document_Tests.sql`, 30 checks, run in a rolled-back transaction.
* **Verification:** a clean build into a new database passed 334/334 SQL tests.

## Phase 9 changes (notifications and e-mail ownership)
* **Schema:**
  * `sec.Users.EmailVerifiedAt DATETIME2(0) NULL` (NULL means a self-registered account that has not confirmed its address and cannot sign in). The table script adds the column to an existing database and sets it once to `CreatedAt` for existing rows; the seed sets it.
  * New table `sec.EmailVerificationTokens` (VerificationId, UserId, TokenHash `VARBINARY(32)` = SHA-256 of the e-mailed token, ExpiresAt, UsedAt, CreatedAt), with `UQ_EmailVerify_TokenHash`, `FK_EmailVerify_User` and `IX_EmailVerify_User`.
* **Functions:**
  * `dbo.fn_BusinessTime(@Utc)` → "20 Nov 2026, 10:00 IST" (time zone 'India Standard Time', in one place).
  * `notify.fn_IsSecurityTemplate(@TemplateCode)` → 1 for PASSWORD_RESET and EMAIL_VERIFY.
* **Security procedures** (`01_Security_Notify.sql`):
  * `sec.usp_RegisterCandidate` gains `@VerifyTokenHash, @VerifyExpiresAt`. The new login is unconfirmed, and an existing recruiter-created candidate with that address is **not** linked; otherwise the candidate record is created as before.
  * New `sec.usp_CompleteEmailVerification` (internal): sets `EmailVerifiedAt`, then links the unclaimed candidate record with the same address, or creates one.
  * New `sec.usp_VerifyEmail @TokenHash`: single use, unexpired (otherwise 50002).
  * New `sec.usp_CreateEmailVerification`: resend; replaces older links; at most one per minute; only for active, unconfirmed accounts.
  * `sec.usp_ConsumePasswordReset` now also completes verification.
  * `sec.usp_CreateUser` creates accounts as confirmed.
  * `sec.usp_GetUserForLogin` returns `EmailVerifiedAt`.
  * `sec.usp_RecordLoginAttempt` gains `@CountFailure BIT = 1` (0 means logged but not counted towards lockout).
* **Delivery procedures** (`12_Notifications.sql`):
  * `notify.usp_ClaimBatch @BatchSize, @LeaseSeconds` runs in one transaction:
    1. Leases that ran out become a recorded failed attempt; the message is retried or given up.
    2. Messages to recipients deactivated since queuing are Cancelled.
    3. The oldest due Pending messages are claimed with `UPDLOCK, READPAST, ROWLOCK` (Attempts+1, Status Processing, NextAttemptAt = lease expiry).

    It returns what the sender needs.
  * `notify.usp_MarkSent @NotificationId, @AttemptNo` and `notify.usp_MarkFailed @NotificationId, @AttemptNo, @Error` act only on the attempt that was handed out. The back-off is 2^(n-1) minutes, at most 60; the message is Failed at MaxAttempts (5). Both write `notify.NotificationHistory`.
  * Bodies of sign-in-link messages are replaced by a "[Removed …]" text when sent, given up or cancelled.
* **Administration procedures** (Administrator only):
  * `notify.usp_ListQueue` (paged, no bodies, last error) and `notify.usp_ListDeliveryHistory`.
  * `notify.usp_RetryNotification` (Failed/Cancelled → Pending, Attempts 0; never for sign-in links or inactive recipients) and `notify.usp_CancelNotification` (Pending only). Both write `audit.AuditLogs` with the administrator as actor.
* **Queries:**
  * `notify.usp_ListMyNotifications` and the unread count in `sec.usp_GetMe` leave out sign-in-link messages.
  * The list also returns `EmailStatus` and `EmailedAt`.
* **Interview texts:** `cand.usp_ScheduleInterview` and `cand.usp_RescheduleInterview` write times in IST. The invitation body adds the end time, the mode and the location.
* **Tests:**
  * `12_Tests/06_Notification_Tests.sql`: 40 checks, run in a rolled-back transaction with existing queued messages parked.
  * Phase 3 test S04 updated (linking after confirmation); F06 made independent of the build day.
* **Verification:** a clean build into a new database passed **374/374**.

## Phase 10 changes (reporting, `06_StoredProcedures/13_Reports.sql`)
* **Catalog:** new table `report.ReportDefinitions` (ReportCode PK, Category Recruitment/Staffing/HR, Title, Description, ProcedureName, Roles, DateFilter, UsesDays, CustomerScoped, ChartLabel, ChartValue, ChartAggregate value/count/sum, SortOrder). It is created in `03_Tables/04_time_bill_support.sql`; its rows are maintained by MERGE in `13_Reports.sql`, which also deletes rows no longer listed. It holds no personal data.
* **Shared check:** `report.usp_ReportScope @ActorUserId, @Roles, @FromDate, @ToDate, @CustomerScoped, @CustomerId OUTPUT`:
  * the role (50005);
  * dates: start not after end, years 2000–2100 (50001);
  * customer scope: staff may pass any existing customer (otherwise 50004); a Customer is forced to its own company, and a different id gives 50004.
* **19 report procedures** `report.usp_Rpt_*`, all with the parameters `(@ActorUserId, @FromDate = NULL, @ToDate = NULL, @CustomerId = NULL, @Days = NULL)` and inclusive date ranges:

  | Group | Procedures |
  |---|---|
  | Recruitment | OpenRequisitions, ApplicationsByStatus, Pipeline, Sourcing, InterviewConversion, OfferAcceptance, TimeToHire, RecruiterPerformance |
  | Staffing | StaffingRequests, Submissions, Placements, ActiveContractors, ExpiringContracts (`@Days` 1–365, default 30), PendingTimesheets, CustomerInvoices, OutstandingPayments |
  | HR | Onboarding, DepartmentHiring, RequisitionStatus |

  * `usp_Rpt_Placements` returns PayRate and MarginPct only to staff; a Customer gets a different column list.
  * `usp_Rpt_CustomerInvoices` hides Draft invoices from customers.
* **Entry points:**
  * `report.usp_ListReports @ActorUserId`: the catalog rows the caller's roles allow, plus `CanFilterCustomer`.
  * `report.usp_RunReport @ActorUserId, @ReportCode, …`:
    * an unknown code gives 50004 and a role not in the catalog's list gives 50005;
    * it runs `report.<ProcedureName>`; the name comes from the catalog, never from the caller, and must exist as a procedure;
    * the report procedure checks the role again.
* **Permissions:** unchanged. The application role already has EXECUTE and SELECT on schema `report`. It cannot read the base tables (test P01).
* **Tests:** `12_Tests/07_Report_Tests.sql`, 28 checks reconciling every report with independent queries (read-only, no transaction needed).
* **Verification:** a clean build into a new database passed **402/402**.

## Phase 11 changes (SQL Server Agent jobs, `06_StoredProcedures/14_Jobs.sql`)
* **Schema:** new table `sched.JobExecutionDetails` (DetailId, ExecutionId → `sched.JobExecutionHistory`, Level Info/Warning/Error, Message, LoggedAt) with `FK_JobDetails_Execution` and `IX_JobDetails_Execution`.
* **Functions:** new `dbo.fn_BusinessToday()`, the IST calendar day used by the nightly jobs.
* **Job catalogue:** `sched.JobDefinitions` for Owner = SqlAgent is maintained by MERGE, with descriptions and schedules. Two definitions were added: *Differential database backup* and *Transaction log backup*. There are now 9 SQL Agent jobs and 6 Task Scheduler jobs; the latter are untouched until Phase 12.
* **Bookkeeping procedures:**
  * `sched.usp_JobBegin @JobName, @ExecutionId OUTPUT` returns 1 for Skipped (switched off, or `sp_getapplock` on the job name already held).
  * `sched.usp_JobLog`.
  * `sched.usp_JobEnd`: on Failed it queues `JOB_FAILED` for every active administrator.
* **Job procedures:** `sched.usp_Job_ExpireRequisitions @AsOf`, `usp_Job_DetectContractExpiry @AsOf, @WarningDays = 30`, `usp_Job_PurgeNotifications @RetentionDays = 90, @BatchSize = 5000`, `usp_Job_DailyRecruitmentSummary @SummaryDate`, `usp_Job_BackupDatabase @BackupType FULL|DIFF|LOG, @RetentionDays = 14, @RootDirectory`, `usp_Job_IndexMaintenance @ReorganizeAbovePct = 10, @RebuildAbovePct = 30, @MinPages = 100`, `usp_Job_UpdateStatistics @FullScanMaxRows = 1000000`.
  * The data jobs use the savepoint convention, rolling back only to a savepoint the run created.
  * The maintenance jobs refuse to run inside a transaction (50002).
* **Admin read:** `sched.usp_ListJobRunDetails @ActorUserId, @ExecutionId` (Administrator).
* **Permissions:** `DENY EXECUTE` to `tams_app_role` on the bookkeeping and all job procedures. The schema-level grant on `sched` stays, for the admin read procedures.
* **Agent objects** (not part of `Run-DatabaseSetup.ps1`, because they are server-wide):
  * `database/11_AgentJobs/01_Create_Agent_Jobs.sql`, run through `scripts/database/Install-AgentJobs.ps1`.
  * Category TAMS, owner `sa`, one T-SQL step per job, schedules in server time, `notify_level_eventlog = 2`.
* **Tests:**
  * `12_Tests/08_Job_Tests.sql`, 17 checks in a rolled-back transaction.
  * Real Agent runs: `scripts/testing/Test-AgentJobs.ps1`, 18 checks on a copy.
* **Verification:** a clean build into a new database passed **419/419**.

## Phase 12 changes (console-app tasks, `06_StoredProcedures/15_AppTasks.sql`)
* **Schema:** `doc.Documents` gains `DeletedAt DATETIME2` (set by `doc.usp_DeleteDocument`; existing deleted rows backfilled once from the audit trail, else the upload time) and `FilePurgedAt DATETIME2` (when the file was removed from disk).
* **Job catalogue:** `sched.JobDefinitions` for Owner = TaskScheduler is maintained by MERGE: the 6 required tasks plus *File housekeeping* (7).
* **Bookkeeping** (Task Scheduler runs only; 50004 otherwise):
  * `sched.usp_AppTaskBegin @JobName, @LeaseMinutes = 60, @HostName` returns ExecutionId, Outcome (Running/Skipped) and Message. It locks the definition row (UPDLOCK, HOLDLOCK), closes runs older than the lease as *Failed* ("Abandoned"), and records *Skipped* when the job is switched off or another run is going (a database lease that works across machines). Validation happens before `XACT_ABORT` and the transaction.
  * `sched.usp_AppTaskLog`; `sched.usp_AppTaskEnd` (on *Failed* calls `sched.usp_NotifyJobFailure`, which since Phase 12 is shared with the Agent jobs' `usp_JobEnd`).
* **Queueing procedures** (each returns Queued and Considered; de-duplication keys name the moment):
  * `notify.usp_QueueInterviewReminders @WithinHours = 24` (candidate and panel; key per interview time, so a reschedule reminds again);
  * `notify.usp_QueueOfferExpiryReminders @WithinDays = 2`;
  * `notify.usp_QueueTimesheetReminders @WeekStart` (must be a Monday, 50001);
  * `notify.usp_QueueContractExpiryNotices` (contracts Agent flagged Expiring; contractor, recruiter, customer users; 30/7/1-day stages);
  * `notify.usp_QueueDailyReport @SummaryDate` (default yesterday; 50002 naming the Agent job when the summary row is missing).
* **Files:** `doc.usp_ListPurgeableFiles @OlderThanDays = 30`, `doc.usp_MarkFilePurged @DocumentId`.
* **Tests:** `12_Tests/09_AppTask_Tests.sql`, 15 checks in a rolled-back transaction; `08_Job_Tests.sql` J14 now expects 7 Task Scheduler jobs.
* **Verification:** a clean build into a new database passed **434/434**.

## Phase 13 changes (security and performance)
* **Worker identity:** `06_StoredProcedures/16_Worker_Role.sql` creates `tams_worker_role` and `tams_worker_demo` (no login), grants EXECUTE on the 13 worker procedures plus `sec.usp_Ping`, and DENIES the 13 to `tams_app_role`.
* **Report audit:** new append-only table `audit.ReportRuns` (ReportRunId, ReportCode, ActorUserId → `sec.Users`, OutputFormat view/csv, FromDate, ToDate, CustomerId, Days, DbUser, RanAt), indexes `IX_ReportRuns_Actor_At` and `IX_ReportRuns_RanAt`, trigger `audit.trg_ReportRuns_AppendOnly`. `report.usp_RunReport` gains `@Format` and writes one row per successful run.
* **Audit triggers:** each row's XML is built from the joined row (`(SELECT d.* FOR XML RAW('row'), ELEMENTS)`) instead of a correlated lookup into `inserted`/`deleted`. Identical output (compared on 294,561 rows); about 10× faster for statements that change 1,000–2,000 rows.
* **Lists:**
  * `cand.usp_SearchCandidates` and `cand.usp_ListApplications` count once and fetch only the page, with `OPTION (RECOMPILE)`. Free text is matched once into a temp table (`UPPER(...) COLLATE Latin1_General_BIN2`: same matches, about 5× less CPU).
  * `cand.fn_SearchCandidates` joins the skill matches once.
  * `cand.usp_ListInterviews` inlines the visibility rules of `cand.fn_CanSeeInterview`.
  * Nine unpaged list procedures gain `@Top INT = 500` (newest first).
* **Reports:** `usp_Rpt_InterviewConversion` is one grouped pass (892,000 → 1,800 reads); `usp_Rpt_Sourcing` aggregates per source in one pass (600 → 200 ms).
* **Database option:** `ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 4` (`01_Database/01_CreateDatabase.sql`).
* **Tests:**
  * the permission suite now has 22 checks (worker role P17–P22);
  * the report suite has 31 (audit A01/A02, now in a rolled-back transaction);
  * the notification and app-task least-privilege checks use the worker identity;
  * a clean build passed **443/443**.
