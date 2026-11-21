# TAMS — Phase 0 Environment Inspection Report

Inspected: 2026-11-19 on the user's local machine. Every value below was read from the machine during this session, not assumed.

## 1. Findings

| Item | Result | Status |
|---|---|---|
| Windows | Windows 11 Home Single Language, build 10.0.26300, 64-bit | OK |
| Current user is administrator? | **No** (non-elevated shell) | Constraint |
| Visual Studio | **Not installed** (`vswhere` found nothing) | MISSING |
| MSBuild / NuGet CLI | Not on PATH | MISSING (replaced by `dotnet` SDK, see D2) |
| .NET SDK | 9.0.321 only (`dotnet --list-sdks`) | OK (builds net472 projects) |
| .NET Framework 4.7.2 targeting pack | **Present** (`Reference Assemblies\...\v4.7.2`; also v4.8) | OK |
| .NET Framework runtime | 4.8 (release 534296) — runs 4.7.2 assemblies | OK |
| SQL Server engine | **No instance installed** (no `MSSQL*` / `SQLAgent*` services; only the VSS writer) | **MISSING — BLOCKER** |
| SQL Server edition / version | n/a. Only LocalDB `MSSQLLocalDB` = SQL Server **2019** (15.0.4153.1), state Stopped | — |
| SQL Server Agent | **Not available.** LocalDB and Express editions do not include it | **MISSING — BLOCKER for Phase 11** |
| SSMS | Not installed (`winget` offers `Microsoft.SQLServerManagementStudio.22`) | MISSING (optional) |
| `sqlcmd` | Not installed | MISSING (can use .NET SqlClient from PowerShell meanwhile) |
| Node.js | v22.13.1 | OK |
| npm | 10.9.2 | OK |
| Angular CLI | **Not installed globally**; latest on npm is 22.x, so we pin the version via `npx @angular/cli@20` | MISSING (installed per-project) |
| Git | 2.46.0.windows.1 | OK |
| Git repo state | Project folder sits inside a repo rooted at `C:/Users/ABHISHEK` (branch `task/SR-000007`) | **Needs decision (D6)** |
| IIS Express | Present | OK (optional host) |
| Ports 1433, 1434, 4200, 4201, 5000, 5001, 8080, 44300–44302, 50000–52000 | All free | OK |
| Free disk | C: 42.2 GB free of ~453 GB | OK (SQL Server + node_modules need ~10 GB) |
| Network | nuget.org and registry.npmjs.org reachable | OK |
| winget | Present | OK |
| Project folder | `C:\Users\ABHISHEK\Desktop\Talent Acquistion` exists and is empty | OK |

### Angular / Node compatibility
Angular's published matrix: Angular 19 needs Node `^18.19.1 || ^20.11.1 || ^22.0.0`; Angular 20 needs `^20.19.0 || ^22.12.0 || ^24.0.0`. Installed Node 22.13.1 satisfies **both**. The scaffold step will re-verify this with `ng` itself.

### ASP.NET Web API 2 tooling
Web API 2 is a NuGet library (`Microsoft.AspNet.WebApi.*`) and works on net472. The classic *System.Web* project type needs Visual Studio's web targets, which are not installed. OWIN self-hosting works with the `dotnet` SDK alone (see D2).

## 2. Missing prerequisites

| # | Missing | Needed by | Proposed resolution |
|---|---|---|---|
| M1 | SQL Server engine with Agent | Phases 2–15 | Install SQL Server Developer edition (D1) |
| M2 | SQL Server 2014 specifically | Spec | Not on winget; see D1 for options |
| M3 | Visual Studio / MSBuild | Phase 4 | Not required if D2 approved |
| M4 | Angular CLI | Phase 5 | Per-project via `npx @angular/cli@20` |
| M5 | sqlcmd / SSMS | Phases 2–3 | `winget install Microsoft.Sqlcmd` and optionally SSMS |
| M6 | Admin rights | SQL install, service start, `HKLM` changes | One-time UAC elevation for the install |

## 3. Recommended local configuration

* SQL Server **2019 Developer** (default instance `MSSQLSERVER` on port 1433, Windows auth for admin, SQL login `tams_app` for the application), database `TalentAcquisitionDB` at **compatibility level 120** (the SQL Server 2014 level), plus a lint script that rejects post-2014 syntax.
* SQL Server Agent service set to Automatic.
* API: .NET Framework 4.7.2 OWIN self-host on `http://localhost:5000` (port reserved for it).
* Angular dev server on `http://localhost:4200` with CORS allowed for that origin only.
* Local mail capture folder `storage\mail-outbox`.
* Document storage `storage\documents` (outside any served path).

## 4. Phase 0 acceptance status

**BLOCKED pending approval of D1 (SQL Server) and D2 (API hosting).** See `PROJECT_PLAN.md` §3. Application code, database objects and installs have **not** been created or changed. Only documentation was written.
