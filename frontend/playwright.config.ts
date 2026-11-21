import { defineConfig } from '@playwright/test';

/**
 * Phase 14 browser end-to-end tests. Start them with scripts\testing\Run-E2E.ps1, which prepares a disposable database
 * copy, the real API and the web app, and sets the TAMS_E2E_* variables. Nothing is mocked.
 * The installed Chrome is used (channel "chrome"); Playwright's own browsers are not downloaded.
 */
export default defineConfig({
  testDir: './e2e',
  fullyParallel: false,
  workers: 1,                       // the workflows share one database copy and build on real state
  retries: 0,
  timeout: 240_000,
  expect: { timeout: 15_000 },
  outputDir: '../tests/e2e/artifacts',
  reporter: [['list'], ['json', { outputFile: '../tests/e2e/results.json' }], ['html', { outputFolder: '../tests/e2e/report', open: 'never' }]],
  use: {
    baseURL: process.env['TAMS_E2E_BASEURL'] ?? 'http://localhost:5080',
    channel: 'chrome',
    headless: true,
    viewport: { width: 1400, height: 900 },
    timezoneId: 'Asia/Kolkata',
    locale: 'en-IN',
    actionTimeout: 15_000,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure'
  }
});
