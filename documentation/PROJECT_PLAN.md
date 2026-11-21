# TAMS — Project Plan

## 1. Objective
A local Windows Talent Acquisition Management System supporting two business models in one application: **Internal Corporate Recruitment** and **External Staffing / Contract Recruitment**. Six role-based dashboards (Candidate, Contractor, Customer, Recruiter, HR Manager, Administrator), real SQL Server database, Web API 2 backend, Angular frontend, SQL Agent jobs and a Windows Task Scheduler console app.

## 2. Module breakdown

| Module | DB schema | Backend service / controller | Angular area | Roles |
|---|---|---|---|---|
| Security & identity | `sec` | Auth, Users | `auth`, `admin` | all |
| Organization & customers | `org` | Customers, Departments | `admin`, `customer` | Admin, HR, Customer |
| Recruitment (jobs) | `hr`, `rec` | Requisitions, Jobs | `hr`, `recruiter` | HR, Recruiter |
| Candidate master & applications | `cand` | Candidates, Applications | `candidate`, `recruiter` | Candidate, Recruiter |
| Interviews | `cand` | Interviews | `recruiter`, `customer` | Recruiter, HR, Customer |
| Offers | `cand` | Offers | `recruiter`, `hr`, `candidate` | Recruiter, HR, Candidate |
| HR / employees / onboarding | `hr` | Employees | `hr` | HR |
| Staffing (requests, submissions, placements) | `staff` | CustomerRequisitions, Submissions, Contractors, Contracts, Assignments | `customer`, `recruiter`, `contractor` | Customer, Recruiter, Contractor |
| Timesheets | `time` | Timesheets | `contractor`, `customer` | Contractor, Customer |
| Billing | `bill` | Invoices, Payments, RateCards | `customer`, `recruiter`, `admin` | Customer, Recruiter, Admin |
| Documents | `doc` | Documents | all | all (authorized) |
| Notifications | `notify` | Notifications | header bell | all |
| Audit | `audit` | Admin | `admin` | Admin |
| Reporting | `report` | Reports | `reports` | Recruiter, HR, Customer, Admin |
| Scheduling | `sched` | Admin, Scheduler console | `admin` | Admin |

## 3. Decisions requiring your approval

| ID | Decision | Recommendation | Why |
|---|---|---|---|
| **D1 (APPROVED 2026-11-19; compat-120 restriction later lifted by the user)** | SQL Server version. No instance is installed. SQL Server 2014 is out of support, is not distributed through `winget`, and is not on the support matrix for Windows 11. | **Install SQL Server 2019 Developer** via `winget` (needs one UAC prompt, ~6 GB). Create the DB at **compatibility level 120** and write T-SQL to 2014 rules, enforced by a lint script. *Alternative:* you supply SQL Server 2014 Developer media (needs a Microsoft/Visual Studio subscription download) and I install that. | Developer edition includes SQL Agent, which Phase 11 requires. Honest limit: level 120 emulates 2014 query-processor behaviour but is not a true 2014 engine, so "verified on real 2014" cannot be claimed under this option. This will be recorded in `KNOWN_ISSUES.md`. |
| **D2** | API hosting. Visual Studio / System.Web web targets are not installed. | **ASP.NET Web API 2 on .NET Framework 4.7.2, OWIN self-hosted** as a console `.exe`, built with `dotnet build`. Same Web API 2 controllers, attribute routing, filters, ADO.NET. *Alternative:* install VS 2022 Build Tools with the web workload (admin, ~5–8 GB) and host in IIS Express. | Keeps the specified stack, avoids a multi-GB IDE install. The only difference is the host process. |
| **D3** | Angular version | **Angular 20** with Angular Material, standalone components, lazy-loaded feature routes. Node 22.13.1 qualifies. | Newest release in the allowed 19/20 range. |
| **D4** | Token design | JWT (HS256) signed with a secret kept in untracked local config; 60-minute lifetime; every token's `jti` stored in `sec.AuthTokens` so logout and admin deactivation revoke it server-side. Passwords: PBKDF2-SHA256 (210,000 iterations, per-user salt). | Web API 2 compatible, real revocation, no plaintext passwords. |
| **D5** | Role gaps. The spec has no "Employee", "Interviewer" or "Department Manager" role. | Interviewers are Recruiters/HR Managers (and Customer users for external interviews). Department managers are HR Manager-role users flagged `IsHiringManager` with a department. Employees have **no login** in v1; they are managed by HR. | Keeps the specified six roles. |
| **D6** | Git. This folder is inside a repository rooted at your home directory (`C:/Users/ABHISHEK`, branch `task/SR-000007`) whose status is mostly untracked home-folder files. | `git init` inside `Talent Acquistion` so TAMS has its own repo, with a `.gitignore` for secrets, `node_modules`, `bin/obj`, storage. | A project-level repo avoids tracking home-directory files. I will not commit or init anything until you say so. |
| **D7** | `rec.JobApprovals` vs `hr.HiringApprovals` | Keep both as specified: `HiringApprovals` approves the department's *hiring request*; `JobApprovals` is HR Manager sign-off of the *job content* before posting. | Both listed in the spec; each must be functional, not placeholder. |
| **D8** | Test tooling | SQL tests: plain T-SQL test scripts with a PowerShell runner (avoids tSQLt's CLR/sysadmin install). Backend: MSTest integration tests on a real test database. Frontend: Karma/Jasmine unit tests. E2E: Playwright against the real stack. | Meets "no mocks in final E2E". |

## 4. Development sequence

Phases follow the master prompt exactly. Each has a gate; none starts until the previous gate passes.

| Phase | Name | Gate (acceptance) | Depends on |
|---|---|---|---|
| 0 | Environment | D1–D2 approved, SQL Server + Agent running | — |
| 1 | Architecture / ERD / API plan | **Your approval of these documents** | 0 |
| 2 | Database schema + seed | All tables, FKs, constraints reject bad data, 2014-lint passes | 1 |
| 3 | DB logic (procs, functions, triggers, views, DB tests) | T-SQL test suite green | 2 |
| 4 | Web API | Solution builds; API tests green; real DB data | 3 |
| 5 | Angular | Six dashboards render DB data via API | 4 |
| 6 | Internal recruitment E2E | Full record trail via UI | 5 |
| 7 | Staffing E2E | Full record trail via UI | 5 |
| 8 | Documents | Upload/download/auth tests | 6, 7 |
| 9 | Notifications | Queue, retry, dedupe tests | 6, 7 |
| 10 | Reporting | Reports match SQL counts | 6, 7 |
| 11 | SQL Agent jobs | Real Agent job history | 3 |
| 12 | Scheduler console + Task Scheduler | Real task runs | 9 |
| 13 | Security / performance | Isolation, injection tests pass | 4–12 |
| 14 | Full automated suite | All suites + both E2E workflows | all |
| 15 | Local deployment | Clean-machine setup procedure verified | all |

Status tracking is in `IMPLEMENTATION_PROGRESS.md`.

## 5. Proposed folder structure
Project root = `C:\Users\ABHISHEK\Desktop\Talent Acquistion` (acts as `TAMS/`). Structure follows the master prompt unchanged:

```
backend/{TalentAcquisition.API,.Business,.Data,.Models,.Common,.Scheduler}
frontend/talent-acquisition-ui
database/{01_Database … 12_Tests}
scripts/{setup,scheduler,database,deployment}
storage/{documents,mail-outbox}      (mail-outbox added for the local email capture provider)
tests/{backend,frontend,e2e}
documentation/*.md
```

Only change: `storage/mail-outbox` added for Phase 9. Folders are created when their phase begins.

## 6. Risks

1. SQL Server 2014 fidelity (D1).
2. Phase 11 depends on a full SQL Server edition with Agent; Express/LocalDB cannot run it.
3. Registering Windows scheduled tasks and installing SQL need elevation at least once.
4. Scope is very large; each phase will be reported with evidence, and a failing gate stops progress.
