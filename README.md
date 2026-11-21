# TAMS — Talent Acquisition Management System

A local, Windows-only system for two business models:
* **internal recruitment:** a hiring request becomes a job, then applications, interviews, an offer and an onboarded employee;
* **contract staffing:** a customer request becomes a submitted candidate, then a contract, weekly timesheets, an invoice and a payment.

There are six roles: Candidate, Recruiter, HR Manager, Customer, Contractor and Administrator.

| Layer | Technology |
|---|---|
| Database | SQL Server 2019 Developer, `TalentAcquisitionDB`: 12 schemas, about 175 stored procedures, functions, triggers and views |
| API | ASP.NET Web API 2 on .NET Framework 4.7.2 (OWIN self-host), ADO.NET only, JWT bearer tokens |
| Web app | Angular 20, served by the API from its production build |
| Background work | 9 SQL Server Agent jobs for data and maintenance, and 7 Windows Task Scheduler tasks that run `TalentAcquisition.Scheduler.exe` for e-mail and reminders |
| E-mail | A mock provider: messages are written as `.eml` files to `storage\mail-outbox`, and nothing leaves the machine |

Everything listens on **loopback only**: the app is at **http://localhost:5000**.

---

## Quick start: one command

Prerequisites (one-time install, see [LOCAL_SETUP §1–2](documentation/LOCAL_SETUP.md)):
* Windows 10 or 11;
* SQL Server 2019 Developer (default instance) with SQL Server Agent;
* .NET SDK 9 (builds the .NET Framework 4.7.2 projects; the 4.7.2 runtime is part of Windows);
* Node.js 22.12 or later, or 20.19 or later;
* Google Chrome, for the tests.

Open PowerShell in the project folder and run:

```powershell
.\scripts\deployment\Start-Tams.ps1
```

It runs eight steps and prints what it did at each one:

1. **SQL Server and SQL Server Agent:** checks that they are running, and starts them if this window is allowed to.
2. **Database:** creates `TalentAcquisitionDB` with its schema and seed data, **only if it does not exist yet**. An existing database is never dropped, overwritten or re-seeded. A new database gets random passwords for the development users, stored only as hashes. The plaintext is written once to the git-ignored `dev-credentials.local.md`.
3. **Configuration:** creates the git-ignored `appsettings.local.json`, holding a random signing secret, if it is missing.
4. **Build:** builds the backend, and rebuilds the production Angular bundle when its source changed.
5. **API and web app:** starts the API hidden. It serves the API and the web app on http://localhost:5000. An instance this script started earlier is restarted.
6. **Angular dev server:** with `-Dev` only, runs `ng serve` with live reload on http://localhost:4200.
7. **Background jobs:** reports the SQL Server Agent jobs and the Task Scheduler tasks, and installs them if you ask (see the switches below).
8. **Health check and browser:** runs the health check (see [Verify health](#9-verify-application-health)), then opens http://localhost:5000.

Sign in with any account from `dev-credentials.local.md`, which has one or more per role. Stop the app with:

```powershell
.\scripts\deployment\Stop-Tams.ps1
```

Useful switches:
* `-Dev` adds `ng serve` with live reload on http://localhost:4200.
* `-NoBrowser` skips opening the browser.
* `-SkipBuild` skips the build step.
* `-InstallAgentJobs` installs or re-creates the SQL Server Agent jobs.
* `-RegisterTasks` registers the Task Scheduler tasks.
* `-DatabaseName <name> -Port <n>` runs a second instance beside the normal one, for example a restored copy. Stop it with `Stop-Tams.ps1 -Port <n>`.

Logs are in `.run\` and `backend\TalentAcquisition.API\bin\Debug\net472\logs\`.

---

## Step by step

Each step below is one command, run from the project folder in PowerShell. `Start-Tams.ps1` performs steps 1–5 and 9 for you.

### 1. Start SQL Server
Both services start automatically with Windows. To start them by hand, use an administrator PowerShell:

```powershell
Start-Service MSSQLSERVER, SQLSERVERAGENT
```

### 2. Create or restore the database
Create it, with schema, seed data and development passwords. This never drops an existing database:

```powershell
.\scripts\database\Run-DatabaseSetup.ps1
```

```powershell
.\scripts\database\Set-DevPasswords.ps1
```

Back up the database: a COPY_ONLY backup, verified, written to SQL Server's backup folder. The path is printed:

```powershell
.\scripts\database\Backup-TamsDatabase.ps1
```

Restore a backup. By default it restores under a **new** name. If the target exists, the script refuses unless you add `-Replace`; it then takes a safety backup first and asks you to type the database name before overwriting TalentAcquisitionDB:

```powershell
.\scripts\database\Restore-TamsDatabase.ps1 -BackupFile "<path to .bak>" -DatabaseName TalentAcquisitionDB_Restored
```

### 3. Run the database setup scripts
`Run-DatabaseSetup.ps1` runs every folder under `database\` in dependency order: `01_Database` → `02_Schemas` → `03_Tables` → `04_Constraints` → `05_Indexes` → `07_Functions` → `06_StoredProcedures` → `08_Triggers` → `09_Views` → `10_SeedData`. The scripts are repeatable. To run one folder against a database:

```powershell
.\scripts\database\Invoke-SqlScripts.ps1 -DatabaseName TalentAcquisitionDB -Path .\database\06_StoredProcedures
```

### 4. Start the ASP.NET API
Create the local secret once, then build:

```powershell
.\scripts\setup\New-LocalConfig.ps1
```

```powershell
dotnet build .\backend\TalentAcquisition.sln
```

Start the API in this window; stop it with Ctrl+C. It serves http://localhost:5000/api/v1 and the web app:

```powershell
.\backend\TalentAcquisition.API\bin\Debug\net472\TalentAcquisition.API.exe
```

`TalentAcquisition.API.exe --check` validates the configuration and the database connection, then exits. Exit codes: 0 OK, 2 configuration, 3 database, 4 port in use.

### 5. Start Angular
Build the production bundle; the API serves it:

```powershell
npm --prefix frontend ci
```

```powershell
npm --prefix frontend run build
```

Or, for UI development with live reload, run the dev server on http://localhost:4200. It proxies `/api` to port 5000:

```powershell
npm --prefix frontend start
```

### 6. Register the scheduled tasks (Windows Task Scheduler)
This registers 7 tasks under `\TAMS\`, running as you and only while you are signed in. They deliver e-mail and queue reminders and the daily report. Re-running replaces them:

```powershell
.\scripts\scheduler\Register-ScheduledTasks.ps1
```

Remove them:

```powershell
.\scripts\scheduler\Unregister-ScheduledTasks.ps1
```

Run a single task once, without registering anything:

```powershell
.\backend\TalentAcquisition.Scheduler\bin\Debug\net472\TalentAcquisition.Scheduler.exe run email-queue
```

### 7. Start the SQL Server Agent jobs
Install the 9 jobs; they then run on their own schedules (nightly contract-expiry detection, stale-requisition expiry, the daily summary, backups, index and statistics maintenance, queue purge):

```powershell
.\scripts\database\Install-AgentJobs.ps1
```

Start one job now:

```powershell
sqlcmd -S localhost -E -Q "EXEC msdb.dbo.sp_start_job N'TAMS - Detect contract expiry'"
```

### 8. Run the tests
Run the database, API, Angular unit and browser end-to-end tests, about 6 minutes. Every suite runs on throwaway database copies; the development database is only read:

```powershell
.\scripts\testing\Run-AllTests.ps1
```

To prove the deployment itself from nothing (a fresh copy of the project with a new database on port 5091, removed afterwards; about 1 minute):

```powershell
.\scripts\testing\Test-CleanDeployment.ps1
```

See [documentation/TESTING.md](documentation/TESTING.md) for every suite, the options and the reports.

### 9. Verify application health
This read-only check covers SQL Server, the database, least-privilege roles, Agent jobs, scheduled tasks, the e-mail queue, the API, the web app and its security headers, the storage folders and the configuration. Each line is PASS, WARN or FAIL. Exit code 0 means no FAIL:

```powershell
.\scripts\deployment\Test-TamsHealth.ps1
```

---

## Repository layout

```
backend/                          Visual Studio solution TalentAcquisition.sln (opens in VS 2019/2022; builds with dotnet build)
  TalentAcquisition.API/          OWIN self-host, controllers, security pipeline, serves the web app
  TalentAcquisition.Business/     services (one per area), validation, workflow rules
  TalentAcquisition.Data/         ADO.NET repositories (stored procedures only)
  TalentAcquisition.Models/       request/response models
  TalentAcquisition.Common/       settings, logging, password hashing, documents, errors
  TalentAcquisition.Scheduler/    console app run by Windows Task Scheduler (e-mail, reminders, housekeeping)
frontend/                         Angular 20 app (src/app/pages per role), Playwright tests in e2e/
database/01_Database … 12_Tests   SQL scripts in run order; 10_SeedData = seed data; 11_AgentJobs = SQL Server Agent jobs
scripts/database|deployment|scheduler|setup|testing   PowerShell for every step above
config/examples/                  configuration examples (no secrets)
tests/backend/                    API integration tests (MSTest, real API over HTTP)
storage/                          documents and mock e-mail outbox (contents git-ignored)
documentation/                    architecture, database design, API, setup, tests, known issues, progress
```

The Angular project is at `frontend/` instead of `frontend/talent-acquisition-ui/`. It is the only frontend, and the scripts and tests refer to this path.

## Security notes
* No passwords or secrets are committed. The signing secret is in `appsettings.local.json`, and the development passwords are in `dev-credentials.local.md`. Both are git-ignored and generated locally at random.
* SQL Server uses Windows authentication. The API and the console app run every database call as least-privilege database users (`tams_app_demo`, `tams_worker_demo`) that may only execute their own stored procedures.
* The API refuses to listen on anything but loopback. The web app is served with a strict Content-Security-Policy.
* SQL Server itself currently listens on all network interfaces (KI-011). Restricting it to loopback is a server setting left for you to change; see [KNOWN_ISSUES](documentation/KNOWN_ISSUES.md).

## Documentation
[Local setup](documentation/LOCAL_SETUP.md) · [Testing](documentation/TESTING.md) · [Architecture](documentation/ARCHITECTURE.md) · [Database design](documentation/DATABASE_DESIGN.md) · [ERD](documentation/ERD.md) · [API](documentation/API_SPECIFICATION.md) · [Test results](documentation/TEST_RESULTS.md) · [Known issues](documentation/KNOWN_ISSUES.md) · [Progress](documentation/IMPLEMENTATION_PROGRESS.md) · [Configuration](config/examples/README.md)
