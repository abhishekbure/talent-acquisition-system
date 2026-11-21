# TAMS — How to run the tests

Every automated test runs against a **disposable copy** of `TalentAcquisitionDB` (or a new database built from the scripts). The copy is
dropped afterwards. The development database is only read, so the tests never change your data, and they can run while the app is
running. Test passwords are random, set only inside the copy, and never stored. Results of the latest runs are in
[TEST_RESULTS.md](TEST_RESULTS.md).

## Everything with one command

```powershell
.\scripts\testing\Run-AllTests.ps1
```

This builds the backend, then runs the four main layers (about 4 minutes; with every switch below about 6 minutes, measured 2026-11-20: 1,079 / 1,079). It prints one summary table, and its exit code is 0 only when every test passed.
Logs are in `tests\results\` (git-ignored). Add any of these switches for the slower harnesses:

| Switch | Adds | Time |
|---|---|---|
| `-IncludeTasks` | Windows Task Scheduler harness: registers temporary tasks against a copy, runs them through Task Scheduler, removes them | ~1 min |
| `-IncludeAgent` | Real SQL Server Agent runs of every job against a copy | < 1 min |
| `-IncludePerformance` | Loads ~1 million rows into a copy, checks time and index budgets, and runs a 20-second API stress test | ~1 min |
| `-IncludeCleanBuild` | Builds every script into a brand-new database and runs the SQL suites there | < 1 min |

## The suites one by one

| Layer | Command | What it covers | Count |
|---|---|---|---|
| Database | `.\scripts\database\Run-DatabaseSetup.ps1 -DatabaseName TAMS_Check -IncludeTests` (new database), or as `Run-AllTests.ps1` does it: on a copy | Tables and relationships, procedures, functions, triggers, constraints, transactions, multi-row operations, permissions, customer isolation, notifications, reports, scheduled jobs (`database\12_Tests`, 9 suites) | 443 |
| Backend API | `.\scripts\deployment\Run-BackendTests.ps1` | The real API over HTTP on port 5055: authentication, authorization, every business area, security (tampered identifiers, tokens, rate limits, input validation, error shape), concurrency, edge cases | 74 |
| Frontend unit | `cd frontend; npx ng test --watch=false --browsers=ChromeHeadless` | Angular services, guards, interceptor, forms, tables, formatting, the timesheet race regression. Uses HTTP mocks (unit tests only) | 44 |
| Browser end-to-end | `.\scripts\testing\Run-E2E.ps1` | Both business workflows end to end; every role's menu and refusals; the candidate, recruiter and administrator workflows; the nine edge cases. Real web app → real API → real SQL Server, **no mocks** | 14 |
| Task Scheduler | `.\scripts\testing\Test-ScheduledTasks.ps1` | Registration, real runs through Task Scheduler, exit codes, failure reporting, retry, abandoned runs | 27 |
| SQL Server Agent | `.\scripts\testing\Test-AgentJobs.ps1` | Every Agent job run by the Agent against a copy, with its outcome and history | 18 |
| Performance | `.\scripts\testing\Test-Performance.ps1` | Query time and reads on a large copy, index use, missing-index check, API throughput under load | 16 |

### Browser end-to-end tests
`Run-E2E.ps1` does the following:
1. Copies the database to `TalentAcquisitionDB_E2E`.
2. Builds the **production** web app into a temporary folder and starts the real API on http://localhost:5080. The API serves that build, exactly as the deployment does.
3. Runs Playwright in your installed Google Chrome. No browser is downloaded.
4. Stops the API and drops the copy.

Options:
* `-Grep "staffing"` runs only tests whose title matches.
* `-Headed` shows the browser.
* `-Keep` keeps the copy and the temporary folder for inspection.
* `-DevServer` uses `ng serve` on port 4300 instead of the production build.

The HTML report is in `tests\e2e\report\index.html`. A failed test keeps its screenshot and a trace in `tests\e2e\artifacts\`.

## The deployment itself (Phase 15)

```powershell
.\scripts\testing\Test-CleanDeployment.ps1
```

This proves the one-command start-up from nothing:
1. Copies the project to a temporary folder without build output, local configuration or credentials.
2. Runs `Start-Tams.ps1` there against a new database `TalentAcquisitionDB_CleanDeploy` on port 5091. The script must create and seed it, generate the secret and passwords, build, start and pass the health check.
3. Signs in with a generated password and checks role-scoped data.
4. Stops the instance and removes everything.

It takes about 1 minute and makes 12 checks. The running app on port 5000 is not touched. `frontend\node_modules` is linked rather than downloaded, so `npm ci` itself is not exercised.

## Before you run
* **Install once:** `npm --prefix frontend ci` installs Angular, Karma and Playwright. Chrome must be installed.
* **Free ports:** 5055 (API tests), 5080 (end-to-end), 5070 (performance stress). Port 5000 may stay in use by the running app.
* **Rights:** the SQL Server login used, your Windows account, must be allowed to create and drop databases (`sysadmin` on this development instance).
  The Agent harness needs SQL Server Agent to be running.

## Checking a running deployment
The tests above prove the code. To check that the running installation is healthy (services, database, jobs, tasks, API, web app,
configuration), use the read-only health check:

```powershell
.\scripts\deployment\Test-TamsHealth.ps1
```
