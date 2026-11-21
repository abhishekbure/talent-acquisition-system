# TAMS web app (Angular 20)

The web front end of TAMS. See the [project README](../README.md) for the whole system and the one-command start.

| Task | Command (run in `frontend/`) |
|---|---|
| Install packages (from `package-lock.json`) | `npm ci` |
| Production build: `dist/tams-web/browser`, served by the API on http://localhost:5000 | `npx ng build` |
| Development server with live reload on http://localhost:4200 (proxies `/api` to port 5000) | `npm start` |
| Unit tests (headless Chrome; HTTP mocked, unit level only) | `npx ng test --watch=false --browsers=ChromeHeadless` |
| Browser end-to-end tests: real API and database copy, no mocks. Run from the project root | `.\scripts\testing\Run-E2E.ps1` |

Code layout:
* `src/app/core/`: the API client, the session and auth guard, and formatting.
* `src/app/shared/`: the table, details, dialogs, documents and toasts.
* `src/app/pages/`: the pages for each role.
* `e2e/`: the Playwright tests.

The route guards only shape the menus. The API checks every request (role and data scope) on its own.
