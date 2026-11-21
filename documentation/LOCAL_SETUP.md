# TAMS — Local Setup

Status legend: ✔ verified on this machine · ✘ not done / failed · ◻ planned (not yet written/run).

## 1. Prerequisites (state on 2026-11-19)

| Tool | State |
|---|---|
| Node 22.13.1 / npm 10.9.2 | ✔ installed (Angular 20 requires Node ^20.19 or ≥22.12 → OK) |
| Git 2.46.0 | ✔ (project has its own repo; nothing committed yet) |
| .NET SDK 9.0.321 + .NET Framework 4.7.2 targeting pack | ✔ |
| **SQL Server 2019 Developer 15.0.2000.5 (default instance, Agent)** | ✔ installed and verified (§2) |
| sqlcmd, SSMS | ✘ optional (scripts use .NET SqlClient; SSMS: `winget install Microsoft.SQLServerManagementStudio.22`) |
| Visual Studio | not required (decision D2) |
| Angular CLI | not global; used per project via `npx @angular/cli@20` (decision D3) |

## 2. Install SQL Server 2019 Developer (DONE on this machine, 2026-11-19)

**What actually worked here:** the bootstrapper's silent modes failed (exit -1, no log). Reliable path: run the bootstrapper normally, choose **Download Media → ISO** (saved to Downloads), mount the ISO, confirm `setup.exe` is signed by Microsoft, and run `setup.exe` unattended from the ISO (it writes logs under `C:\Program Files\Microsoft SQL Server\150\Setup Bootstrap\Log`):

```powershell
Mount-DiskImage "$env:USERPROFILE\Downloads\SQLServer2019-x64-ENU-Dev.iso"   # note the drive letter, e.g. D:
(Get-AuthenticodeSignature D:\setup.exe).Status                               # must be Valid
Start-Process D:\setup.exe -Verb RunAs -Wait -ArgumentList '/ACTION=Install','/Q','/IACCEPTSQLSERVERLICENSETERMS','/FEATURES=SQLENGINE','/INSTANCENAME=MSSQLSERVER',"/SQLSYSADMINACCOUNTS=`"$env:USERDOMAIN\$env:USERNAME`"",'/AGTSVCACCOUNT="NT Service\SQLSERVERAGENT"','/AGTSVCSTARTUPTYPE=Automatic','/SQLSVCSTARTUPTYPE=Automatic','/TCPENABLED=1','/UPDATEENABLED=0'
```

The steps below describe the (non-working-here) bootstrapper route and are kept for reference. The winget package `Microsoft.SQLServer.2019.Developer` ships an **obsolete bootstrapper** ("This version of the installer is no longer supported"). Use the current Microsoft download instead.

1. **Close any open "SQL Server Installer" error window** (click OK).
2. Download the current bootstrapper and check its signature (PowerShell):

```powershell
$d = "$env:TEMP\sqlsetup"; New-Item -ItemType Directory -Force $d | Out-Null
Invoke-WebRequest 'https://go.microsoft.com/fwlink/?linkid=866662' -OutFile "$d\SQL2019-SSEI-Dev.exe"
(Get-AuthenticodeSignature "$d\SQL2019-SSEI-Dev.exe").Status   # must be Valid, signer Microsoft Corporation
```

3. Install unattended (Database Engine + Agent, default instance, Windows auth, your account as sysadmin; **this accepts Microsoft's license terms**; UAC prompt appears):

```powershell
Start-Process "$d\SQL2019-SSEI-Dev.exe" -Verb RunAs -Wait -ArgumentList '/ACTION=Install','/QUIET','/IACCEPTSQLSERVERLICENSETERMS','/FEATURES=SQLENGINE','/INSTANCENAME=MSSQLSERVER',"/SQLSYSADMINACCOUNTS=`"$env:USERDOMAIN\$env:USERNAME`"",'/AGTSVCACCOUNT="NT Service\SQLSERVERAGENT"','/AGTSVCSTARTUPTYPE=Automatic','/SQLSVCSTARTUPTYPE=Automatic','/TCPENABLED=1','/UPDATEENABLED=0'
```

4. **Do not trust the exit code.** Verify:

```powershell
.\scripts\database\Verify-Environment.ps1
```

Expected: services `MSSQLSERVER` and `SQLSERVERAGENT` Running/Auto, Windows-auth connection works, `IS_SRVROLEMEMBER('sysadmin') = 1`, edition Developer, version 15.x. If setup logs are needed: `C:\Program Files\Microsoft SQL Server\150\Setup Bootstrap\Log\<latest>\Summary.txt`.

## 3. Create the database ✔ (executed and verified on the real instance)

```powershell
.\scripts\database\Run-DatabaseSetup.ps1 -IncludeTests
```

Creates `TalentAcquisitionDB` (never drops an existing one), schemas, tables, constraints, indexes, seed data, then runs the database tests. Repeatable. To rehearse without the main instance: `-Server '(localdb)\MSSQLLocalDB' -DatabaseName TAMS_ScriptCheck`.

### Database scripts and tests (all verified on this machine)

| Command | Purpose |
|---|---|
| `.\scripts\database\Verify-Environment.ps1` | prints real evidence of SQL Server, Agent, tools; exit 0 = OK |
| `.\scripts\database\Run-DatabaseSetup.ps1 -IncludeTests` | builds/updates `TalentAcquisitionDB` (folders in dependency order; functions before procedures) and runs the 3 SQL suites (247 tests) |
| `.\scripts\database\Run-DatabaseSetup.ps1 -DatabaseName MyScratch -IncludeTests` | same into a throw-away database (clean-build proof) — drop it afterwards |
| `.\scripts\database\Test-Concurrency.ps1` | blocking, lock timeout, deadlock + retry, isolation levels, race guards (restored disposable copy) |
| `.\scripts\database\Demo-BackupRestore.ps1` | full + log backup, verify, point-in-time restore (disposable copies) |
| `.\scripts\database\Demo-Performance.ps1` | measured plans / statistics / table-variable / window-function demos (disposable 300k-row copy) |
| `.\scripts\database\Copy-Database.ps1 -Target X -Force` | backup + verify + restore a copy under another name |

## 4. Development logins

```powershell
.\scripts\database\Set-DevPasswords.ps1
```

Generates a random password per seeded user (all six roles), stores only a salted PBKDF2-SHA256 hash in `sec.Users`, and writes the plaintext once to `dev-credentials.local.md` in the project root (git-ignored; keep it out of version control and documentation). Re-running does not rotate passwords unless `-Rotate` is given.

Seeded users (emails only): `admin@tams.local` (Administrator), `priya.menon@` / `rahul.desai@tams.local` (Recruiter), `anita.kapoor@` / `vikram.nair@tams.local` (HRManager), `arjun.shah@` / `neha.verma@apexlogistics.example`, `meera.iyer@brightwave.example`, `kabir.malhotra@crestline.example` (Customer), `ravi.kumar@` / `sneha.pillai@contractor.example` (Contractor), `ananya.sharma@`, `rohan.gupta@`, `divya.reddy@`, `karan.joshi@candidate.example` (Candidate).

## 5. Web API ✔ (Phase 4, verified on this machine)

Prerequisite: .NET SDK 9 (builds the .NET Framework 4.7.2 projects; the 4.7.2+ runtime is part of Windows 11).

```powershell
.\scripts\setup\New-LocalConfig.ps1
```
Creates `backend\TalentAcquisition.API\appsettings.local.json` (git-ignored) with a random 64-byte JWT signing secret. Run once; it does not overwrite an existing file. Settings can also come from environment variables `TAMS_CONNECTION_STRING`, `TAMS_JWT_SECRET`, `TAMS_LISTEN_URL`, `TAMS_DB_IMPERSONATE`, `TAMS_DOCUMENT_STORE` (and, for the sender in section 7, `TAMS_MAIL_OUTBOX`).

**Document store (Phase 8):** uploaded files go to `DocumentStorePath` — by default `storage\documents` in the project folder (created on the first upload; its contents are git-ignored). Set `TAMS_DOCUMENT_STORE` to an absolute path to use another folder (the integration tests and UI checks use a temporary one). The folder is **not** in database backups (KI-033); keep it with the database when copying or restoring.

```powershell
dotnet build .\backend\TalentAcquisition.sln
```

```powershell
.\backend\TalentAcquisition.API\bin\Debug\net472\TalentAcquisition.API.exe --check
```
Validates configuration and database reachability, then exits (0 = OK, 2 = configuration, 3 = database unreachable).

```powershell
.\backend\TalentAcquisition.API\bin\Debug\net472\TalentAcquisition.API.exe
```
Serves `http://localhost:5000/api/v1` (loopback only; CORS allows `http://localhost:4200`). Health check: `http://localhost:5000/api/v1/health`. Logs go to `backend\TalentAcquisition.API\bin\Debug\net472\logs\`. Stop it with Ctrl+C (or `Get-Process TalentAcquisition.API | Stop-Process` before rebuilding). Log in with the development accounts from section 4.

### API integration tests

```powershell
.\scripts\deployment\Run-BackendTests.ps1
```
Backs up `TalentAcquisitionDB`, restores it as `TalentAcquisitionDB_ApiTest`, runs the 48 integration tests (real API hosted in-process on port 5055), then drops the copy. The live database is only read. Options: `-Filter "FullyQualifiedName~Workflow"`, `-KeepDatabase`. Results: `tests\backend\TestResults\api-tests.trx`.

## 6. Angular frontend ✔ (Phase 5, verified on this machine)

Prerequisites: Node.js 22.13 (or 20.19+), npm 10. Install once:

```powershell
npm --prefix frontend install
```

Start the API (section 5) and then the dev server; open http://localhost:4200 and sign in with a development account (section 4):

```powershell
npm --prefix frontend start
```

The dev server proxies `/api` to `http://localhost:5000` (`frontend/proxy.conf.json`), so the browser talks to one origin.

Unit tests (headless Chrome) and production build:

```powershell
cd frontend; npx ng test --watch=false --browsers=ChromeHeadless
```

```powershell
cd frontend; npx ng build
```

### Click through the UI without touching development data
Create a disposable copy whose users all share one random test password (written to the git-ignored `test-credentials.local.md`), run the API on it, use the UI, then drop it:

```powershell
.\scripts\database\New-TestCopy.ps1 -Target TalentAcquisitionDB_UiCheck
```

```powershell
$env:TAMS_CONNECTION_STRING = 'Server=localhost;Database=TalentAcquisitionDB_UiCheck;Integrated Security=SSPI;TrustServerCertificate=True'; .\backend\TalentAcquisition.API\bin\Debug\net472\TalentAcquisition.API.exe
```

```powershell
.\scripts\database\New-TestCopy.ps1 -Target TalentAcquisitionDB_UiCheck -Drop
```

### Check the database trail of a UI walk-through (Phase 6)
After walking the internal recruitment flow through the UI on a disposable copy:

```powershell
.\scripts\testing\Verify-InternalWorkflow.ps1 -Database TalentAcquisitionDB_E2E -CandidateEmail <the candidate's e-mail>
```

### Check the database trail of a staffing walk-through (Phase 7)

```powershell
.\scripts\testing\Verify-StaffingWorkflow.ps1 -Database TalentAcquisitionDB_E2E -RequestTitle '<request title>' -ContractorEmail <the contractor's e-mail>
```

## 7. Notifications sender ✔ (Phase 9, verified on this machine)

Notifications are queued in the database by the procedures and e-mailed by the console app `TalentAcquisition.Scheduler`. It is built with the solution (section 5) and has its own `appsettings.json`, which holds no secrets: Windows authentication plus the least-privileged database user, as the API uses.

```powershell
.\backend\TalentAcquisition.Scheduler\bin\Debug\net472\TalentAcquisition.Scheduler.exe --check
```

```powershell
.\backend\TalentAcquisition.Scheduler\bin\Debug\net472\TalentAcquisition.Scheduler.exe process-notifications
```

* **Mock e-mail:** each message is written as an `.eml` file to `storage\mail-outbox` in the project folder. The folder is created on first use and its contents are git-ignored. Open a file with any mail program, or read it as text. No SMTP server is contacted. Set `TAMS_MAIL_OUTBOX` to an absolute path to write elsewhere; `TAMS_CONNECTION_STRING` selects another database, for example a test copy.
* **Output and exit codes:** the run prints `RESULT claimed=… sent=… failed=… gave-up=… lost-lease=…`. Exit codes: 0 done (failed messages are retried later), 2 configuration, 3 database error, 64 wrong usage. Logs: `backend\TalentAcquisition.Scheduler\bin\Debug\net472\logs\scheduler-YYYYMMDD.log`, holding ids and templates only.
* **Retries:** failed messages are retried after 1, 2, 4 and 8 minutes and marked Failed after 5 attempts. Several copies may run at once safely.
* **Not scheduled yet:** Windows Task Scheduler runs it every 5 minutes from Phase 12 (KI-038). Until then run it by hand, for example after registering a candidate.
* **New candidate accounts must confirm their e-mail address** before they can sign in:
  1. Register.
  2. Run the sender.
  3. Open the `.eml` addressed to the new account and follow its `http://localhost:4200/verify-email?token=…` link.
  4. Click **Confirm my e-mail address**.
  5. Sign in.

  Seeded and administrator-created accounts are already confirmed.
* **Administrator → E-mail queue** shows every message: status, attempts, next try, last error, attempt history, "Send again" and "Don't send".

## 8. Reports ✔ (Phase 10, verified on this machine)

Sign in as a Recruiter, HR Manager, Customer or Administrator and open **Reports** in the side menu. Each role sees only its reports:
* Recruiter: recruitment and staffing.
* HR Manager: recruitment and HR.
* Customer: staffing, for its own company.
* Administrator: all 19.

Each report has date filters (the hint says which date they filter), and staff can pick a customer for staffing reports. **Export CSV** downloads what is on screen. Each of these dashboards also shows one report chart.

The SQL reconciliation suite can be run on its own (read-only):

```powershell
sqlcmd -S localhost -E -I -d TalentAcquisitionDB -i .\database\12_Tests\07_Report_Tests.sql
```

## 9. SQL Server Agent jobs ✔ (Phase 11; installed for TalentAcquisitionDB on 2026-11-20)

SQL Server Agent must be running (`Verify-Environment.ps1` checks it). The 9 jobs are installed. To (re)install them for the development database, for example after changing the job script:

```powershell
.\scripts\database\Install-AgentJobs.ps1
```

The jobs are:
* expire stale requisitions;
* contract expiry;
* notification purge;
* daily summary;
* full, differential and log backups;
* index maintenance;
* statistics.

From then on they change data on schedule and write backups to `...\MSSQL\Backup\TAMS\TalentAcquisitionDB\` (kept 14 days). Run history is under **Administrator > Scheduled jobs**, and in SQL Server Agent's job history in SSMS.

Other commands:
* `Install-AgentJobs.ps1 -Disable`: keep the jobs but stop their schedules.
* `Install-AgentJobs.ps1 -Remove`: delete them.
* Start one by hand: `EXEC msdb.dbo.sp_start_job N'TAMS - Full database backup'`.

To prove the jobs through real Agent runs without touching the development data:

```powershell
.\scripts\testing\Test-AgentJobs.ps1
```

It works on a disposable copy (`TalentAcquisitionDB_AgentTest`) and removes it, its jobs and its backup files afterwards.

## 10. Windows Task Scheduler tasks ✔ (Phase 12; registered for TalentAcquisitionDB on 2026-11-21)

Build the backend first (`dotnet build .\backend\TalentAcquisition.sln`, section 5), then check the console app's configuration and database connection:

```powershell
.\backend\TalentAcquisition.Scheduler\bin\Debug\net472\TalentAcquisition.Scheduler.exe --check
```

Register the 7 tasks in Task Scheduler (folder `\TAMS\`, run as you while you are signed in, no password stored). The script runs `--check` first and refuses to register if it fails:

```powershell
.\scripts\scheduler\Register-ScheduledTasks.ps1
```

From then on, on the development data: e-mail is sent to `storage\mail-outbox` every 5 minutes; reminders are queued (interviews hourly; offers, contracts and the daily report each morning; timesheets on Friday 15:00); at 04:15 old deleted document files and old outbox files are removed and the document store is copied to `storage\document-backup`.

Other commands:
* `Register-ScheduledTasks.ps1 -Disabled`: register them switched off.
* Remove them:

  ```powershell
  .\scripts\scheduler\Unregister-ScheduledTasks.ps1
  ```
* Run one task by hand: `TalentAcquisition.Scheduler.exe run interview-reminders` (`list` shows all task names).

Results: Task Scheduler's "Last Run Result" (0 ok or skipped, 1 failed, 2 configuration, 3 database, 64 usage), **Administrator > Scheduled jobs**, and `logs\scheduler-yyyyMMdd.jsonl` next to the program (`backend\TalentAcquisition.Scheduler\bin\Debug\net472\logs`).

To prove the tasks by hand and through Task Scheduler without touching the development data:

```powershell
.\scripts\testing\Test-ScheduledTasks.ps1
```

It works on a disposable copy (`TalentAcquisitionDB_TaskTest`) with temporary folders and a `\TAMS-Test\` task folder, and removes all of them afterwards.

## 11. Security and performance tests ✔ (Phase 13)

The API integration suite (section 5) includes the security tests:
* manipulated identifiers across every endpoint;
* forged tokens;
* password storage;
* rate limits;
* input validation and error handling;
* concurrency.

Performance on a large copy:

```powershell
.\scripts\testing\Test-Performance.ps1
```

It copies `TalentAcquisitionDB` to `TalentAcquisitionDB_PerfTest` and loads about 2 million rows of synthetic history (about 45 s). Then it:
* times every report and the main lists under the API's database identity;
* proves the key indexes by disabling them;
* stress-tests the real API on port 5070 with 16 clients for 20 s.

It drops the copy at the end; `-Keep` keeps it. Measurements go to `tests\performance\perf-<date>.csv` (git-ignored). Build the backend first. The test sets a random password on the copy only and never shows it.

The console app now connects as its own database user `tams_worker_demo` (`DbImpersonateUser` in `backend\TalentAcquisition.Scheduler\appsettings.json`). Apply `database\06_StoredProcedures\16_Worker_Role.sql` to any database it should run against; `Run-DatabaseSetup.ps1` already does.

## 12. Complete automated test suite ✔ (Phase 14)

One command runs every suite and prints one summary (about 6 minutes):

```powershell
.\scripts\testing\Run-AllTests.ps1
```

It builds the backend, then runs:
1. **Database tests:** the 9 SQL suites on a disposable copy.
2. **Backend tests:** the API integration suite on its own copy.
3. **Frontend tests:** the Angular unit tests.
4. **Browser end-to-end tests.**

Add `-IncludeTasks -IncludeAgent -IncludePerformance -IncludeCleanBuild` for the Task Scheduler, SQL Server Agent, performance and clean-build harnesses (about 2 minutes more; 1,079 tests in about 6 minutes in total). Logs go to `tests\results` (git-ignored); the development database is only read.

### Browser end-to-end tests only

```powershell
.\scripts\testing\Run-E2E.ps1
```

* **Setup:** it copies the database to `TalentAcquisitionDB_E2E` and sets a random password on the copy only. Then it builds the production web app and starts the real API on port 5080, serving that build (Phase 15; `-DevServer` uses `ng serve` on port 4300 instead).
* **Run:** Playwright drives your installed Chrome. `-Grep "staffing"` runs only matching tests; `-Headed` shows the browser.
* **Clean-up:** it stops both servers and drops the copy afterwards.
* **Reports:** `tests\e2e\report\index.html`; a failed step keeps a screenshot and a trace.
* **Ports:** 5080 must be free (and 4300 with `-DevServer`).
* **One-time setup:** Playwright is a dev dependency of `frontend`, installed by `npm install`. Its own browsers are not needed.

## 13. Local deployment ✔ (Phase 15)

The [README](../README.md) is the entry point: one command, plus each of the nine steps as its own command. In short:

```powershell
.\scripts\deployment\Start-Tams.ps1
```

* **What it does:** it checks SQL Server and SQL Server Agent, then creates the database only if it is missing; an existing one is never touched. It creates the local secret if missing, builds the backend, and rebuilds the Angular production bundle if its source changed. Then it starts the API hidden and runs the health check.
* **One address:** the API serves the web app and the API on **http://localhost:5000** (`WebRoot` in `appsettings.json`). Angular routes such as `/recruiter/jobs` get `index.html`; `/api/*` is the API. Links in e-mails point to port 5000 too.
* **Content-Security-Policy:** every page carries one (scripts only from this origin).
* **Development:** `-Dev` additionally runs `ng serve` with live reload on port 4200.
* **Stop:** `Stop-Tams.ps1` stops only what `Start-Tams.ps1` started (recorded in `.run\tams.json`, git-ignored).
* **Health:** `Test-TamsHealth.ps1` is read-only and prints PASS, WARN or FAIL for about 30 checks. FAIL means the app is not usable; WARN means it works but needs attention, for example KI-011, or the scheduled tasks if they are not registered.
* **Backup and restore:**
  * `Backup-TamsDatabase.ps1` takes a verified COPY_ONLY backup that does not disturb the scheduled backup chain.
  * `Restore-TamsDatabase.ps1` restores under a new name by default. It refuses an existing target unless `-Replace` is given, then takes a safety backup first, and asks you to type the name before overwriting TalentAcquisitionDB.
* **Configuration examples:** [config/examples](../config/examples/README.md).

Time measured on this machine: about 7–8 seconds when the database and builds exist, and **35 seconds from nothing**: a fresh copy with no builds, no configuration and no database, proved by `scripts\testing\Test-CleanDeployment.ps1`, 12/12.

* **A second instance**, for example a restored copy, runs beside the normal one: `Start-Tams.ps1 -DatabaseName TalentAcquisitionDB_Restored -Port 5090`, stopped with `Stop-Tams.ps1 -Port 5090`. A missing database of that name is created and seeded, and its logins go to `dev-credentials.<name>.local.md`.
* **Start-up errors:** if the API does not start, the script prints the reason from `TalentAcquisition.API.exe --check`.


