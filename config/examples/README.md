# Configuration examples

The API (`TalentAcquisition.API.exe`) and the console app (`TalentAcquisition.Scheduler.exe`) read their settings in this order. Later sources win:

1. **`appsettings.json`** next to the executable. This is committed and holds no secrets. The committed files are the
   local-deployment defaults:
   * [backend/TalentAcquisition.API/appsettings.json](../../backend/TalentAcquisition.API/appsettings.json)
   * [backend/TalentAcquisition.Scheduler/appsettings.json](../../backend/TalentAcquisition.Scheduler/appsettings.json)
2. **`appsettings.local.json`** next to the executable. This file is **git-ignored** and holds secrets: the API's JWT signing secret.
   `scripts\setup\New-LocalConfig.ps1` generates it, and `Start-Tams.ps1` runs that script for you. It is copied next to the executable when the
   project is built.
3. **`--settings <file>`**: an extra JSON file given on the command line. It is used to point a second instance at a database copy. The
   end-to-end tests and the Task Scheduler test harness use it.
4. **Environment variables**: `TAMS_CONNECTION_STRING`, `TAMS_JWT_SECRET`, `TAMS_LISTEN_URL`, `TAMS_DB_IMPERSONATE`, `TAMS_WEB_ROOT`,
   `TAMS_DOCUMENT_STORE`, `TAMS_MAIL_OUTBOX`.

Relative paths resolve against the executable's folder (`bin\Debug\net472`), so `../../../../../storage` is the project's `storage` folder.
Both programs validate their settings at start-up and stop with exit code 2 and a message when a setting is invalid.

| File here | Shows |
|---|---|
| [api.appsettings.example.json](api.appsettings.example.json) | Every API setting with its local-deployment value |
| [appsettings-local.example.json](appsettings-local.example.json) | The shape of the git-ignored secret file (a placeholder, not a secret) |
| [scheduler.appsettings.example.json](scheduler.appsettings.example.json) | Every console-app setting |
| [copy-database.settings.example.json](copy-database.settings.example.json) | A `--settings` file that runs a second API on port 5090 against a restored copy |

## Settings that matter for a local deployment

| Setting | Default | Meaning |
|---|---|---|
| `ConnectionString` | localhost, TalentAcquisitionDB, Windows authentication | No SQL password is used anywhere |
| `DbImpersonateUser` | `tams_app_demo` (API), `tams_worker_demo` (console app) | After connecting, every call runs `EXECUTE AS USER` as this least-privilege database user |
| `ListenUrl` | `http://localhost:5000/` | Must be a loopback address; any other address is refused at start-up |
| `WebRoot` | `frontend/dist/tams-web/browser` | The production Angular build. The API serves it at the same address. Empty = API only |
| `CorsOrigins` | `http://localhost:4200` | Only needed for `ng serve` (development). The deployed app is same-origin |
| `AppBaseUrl`, `ResetLinkBase`, `VerifyEmailLinkBase` | `http://localhost:5000/...` | Links written into e-mails |
| `MailOutboxPath` | `storage/mail-outbox` | Mock e-mail: each message becomes an `.eml` file here. Nothing is sent over the network |
| `DocumentStorePath`, `DocumentBackupPath` | `storage/documents`, `storage/document-backup` | Uploaded files, outside the web root |
| `TokenMinutes` | 60 | Sign-in session length (5–1440) |
| `MaxRequestBodyKb` | 1024 | Largest JSON body. Uploads are capped at 10 MB separately |
| `RateLimit*PerMinute` | 20 / 5 / 10 | Per-client limits on sign-in, account e-mails and one-time links (0 = off) |
