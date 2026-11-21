import { Browser, Locator, Page, expect } from '@playwright/test';
import { execFileSync, spawnSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Helpers for the Phase 14 end-to-end tests. Everything goes through the real stack:
 *  - people act in the browser (one browser context per person, so sessions never mix);
 *  - e-mail is delivered by the real console app (TalentAcquisition.Scheduler.exe process-notifications) into a real outbox;
 *  - sqlcmd is used only to arrange time-dependent state (an interview "takes place") and to check the database trail.
 * The settings come from scripts\testing\Run-E2E.ps1.
 */
function env(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set: run the tests with scripts\\testing\\Run-E2E.ps1`);
  return v;
}
const PASSWORD = () => env('TAMS_E2E_PASSWORD');
export const E2E = {
  db: () => env('TAMS_E2E_DB'),
  outbox: () => env('TAMS_E2E_OUTBOX')
};

export const USERS = {
  admin: 'admin@tams.local', priya: 'priya.menon@tams.local', rahul: 'rahul.desai@tams.local',
  anita: 'anita.kapoor@tams.local', vikram: 'vikram.nair@tams.local',
  arjun: 'arjun.shah@apexlogistics.example', meera: 'meera.iyer@brightwave.example', kabir: 'kabir.malhotra@crestline.example',
  ravi: 'ravi.kumar@contractor.example', sneha: 'sneha.pillai@contractor.example',
  karan: 'karan.joshi@candidate.example', rohan: 'rohan.gupta@candidate.example'
};

export function unique(prefix: string): string { return `${prefix} ${Date.now().toString(36).slice(-5)}`; }
export function sqlText(s: string): string { return s.replace(/'/g, "''"); }

/* ------------------------------------------------------------------ database (arrange + verify only) */
/** Runs T-SQL on the disposable copy and returns the rows ('|' separated). */
export function sql(query: string): string[][] {
  const out = execFileSync('sqlcmd', ['-S', process.env['TAMS_E2E_SERVER'] ?? 'localhost', '-E', '-I', '-b', '-d', E2E.db(), '-h', '-1', '-W', '-s', '|',
    '-Q', 'SET NOCOUNT ON; ' + query], { encoding: 'utf8' });
  return out.split(/\r?\n/).map(l => l.trim()).filter(l => l.length > 0).map(l => l.split('|'));
}
export function scalar(query: string): string { const r = sql(query); return r.length ? r[0][0] : ''; }
export function num(query: string): number { return Number(scalar(query)); }

/* ------------------------------------------------------------------ console app (real e-mail and tasks) */
/** Runs one task of TalentAcquisition.Scheduler.exe against the copy; returns its exit code. */
export function runTask(task: string): { code: number; out: string } {
  const r = spawnSync(env('TAMS_E2E_SCHEDULER'), ['run', task, '--settings', env('TAMS_E2E_SETTINGS')], { encoding: 'utf8' });
  return { code: r.status ?? -1, out: (r.stdout ?? '') + (r.stderr ?? '') };
}
/** Delivers the queued e-mail (the real sender writing .eml files into the outbox). */
export function deliverMail(): void {
  const r = runTask('process-notifications');
  if (r.code !== 0) throw new Error('process-notifications failed: ' + r.out);
}
export interface Mail { to: string; template: string; subject: string; text: string; id: number; token: string | null; }
export function mails(): Mail[] {
  const dir = E2E.outbox();
  return readdirSync(dir).filter(f => f.endsWith('.eml')).map(f => {
    const raw = readFileSync(join(dir, f), 'utf8');
    const head = raw.split(/\r?\n\r?\n/)[0];
    const h = (name: string) => (new RegExp('^' + name + ':\\s*(.*)$', 'mi').exec(head)?.[1] ?? '').trim();
    const to = /<([^>]+)>/.exec(h('To'))?.[1] ?? h('To');
    const text = /Content-Type: text\/plain; charset=utf-8\r?\nContent-Transfer-Encoding: 8bit\r?\n\r?\n([\s\S]*?)\r?\n----boundary/.exec(raw)?.[1] ?? '';
    const tok = /[?&]token=([A-Za-z0-9_\-%]+)/.exec(text)?.[1];
    return { to, template: h('X-TAMS-Template'), subject: h('Subject'), text, id: Number(h('X-TAMS-Notification-Id')), token: tok ? decodeURIComponent(tok) : null };
  }).sort((a, b) => a.id - b.id);
}
export function latestMail(to: string, template: string): Mail | undefined {
  return mails().filter(m => m.to.toLowerCase() === to.toLowerCase() && m.template === template).pop();
}

/* ------------------------------------------------------------------ people */
/** Opens a fresh browser context for one person and signs in through the login page. */
export async function signIn(browser: Browser, email: string, password = PASSWORD()): Promise<Page> {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await page.goto('/login');
  await page.locator('#email').fill(email);
  await page.locator('#password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);
  return page;
}
export async function signOut(page: Page): Promise<void> {
  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect(page).toHaveURL(/\/login/);
}
export const testPassword = (): string => PASSWORD();

/** Opens a page of an area (e.g. 'recruiter', 'applications') through the side navigation, as a person would. */
export async function open(page: Page, area: string, navLabel: string): Promise<void> {
  if (!page.url().includes('/' + area)) await page.goto('/' + area);
  await page.locator('aside.sidenav').getByRole('link', { name: navLabel, exact: true }).first().click();
  await expect(page.locator('main h1').first()).toBeVisible();
}

/* ------------------------------------------------------------------ dialogs, tables, messages */
export function dialog(page: Page, title?: string | RegExp): Locator {
  return title ? page.getByRole('dialog', { name: title }) : page.getByRole('dialog');
}
/** Sets a dialog field by its key (the inputs are rendered with id "f_<key>"). Selects take the visible option text (a part is enough). */
export async function fill(dlg: Locator, key: string, value: string | number | boolean): Promise<void> {
  const el = dlg.locator('#f_' + key);
  const tag = await el.evaluate(e => e.tagName.toLowerCase());
  if (tag === 'select') {
    const opt = el.locator('option', { hasText: String(value) }).first();
    await expect(opt).toBeAttached();
    await el.selectOption({ label: ((await opt.textContent()) ?? '').trim() });
  } else if (typeof value === 'boolean') {
    await el.setChecked(value);
  } else {
    await el.fill(String(value));
  }
}
export async function tick(dlg: Locator, label: string): Promise<void> {
  await dlg.locator('.checklist label', { hasText: label }).first().locator('input').check();
}
/** Submits the dialog and waits until it closes (it stays open, with the server's message, when the API refuses). */
export async function submit(dlg: Locator, label: string): Promise<void> {
  await dlg.getByRole('button', { name: label, exact: true }).click();
  await expect(dlg).toBeHidden();
}
/** Submits and expects the API to refuse: the dialog stays open and shows the message. */
export async function submitRefused(dlg: Locator, label: string, message: string | RegExp): Promise<void> {
  await dlg.getByRole('button', { name: label, exact: true }).click();
  await expect(dlg.locator('.alert.error')).toContainText(message);
  await expect(dlg).toBeVisible();
}
export function row(page: Page | Locator, text: string | RegExp): Locator {
  return page.locator('table.grid tbody tr').filter({ hasText: text }).first();
}
export async function rowAction(page: Page | Locator, text: string | RegExp, action: string): Promise<void> {
  const r = row(page, text);
  await expect(r).toBeVisible();
  await r.getByRole('button', { name: action, exact: true }).click();
}
export async function toast(page: Page, text: string | RegExp): Promise<void> {
  await expect(page.locator('.toasts .toast').filter({ hasText: text }).first()).toBeVisible();
}
/** Calls the API from the signed-in browser with that person's own token (as a manipulated request would). */
export async function apiFromBrowser(page: Page, method: string, path: string, body?: unknown): Promise<{ status: number; json: any }> {
  return page.evaluate(async ([m, p, b]) => {
    const raw = sessionStorage.getItem('tams.session') ?? Object.keys(sessionStorage).map(k => sessionStorage.getItem(k)).find(v => v && v.includes('"token"')) ?? '{}';
    const token = JSON.parse(raw).token;
    const res = await fetch('/api/v1' + p, { method: m as string, headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' }, body: b === undefined ? undefined : JSON.stringify(b) });
    let json: any = null; try { json = await res.json(); } catch { /* no body */ }
    return { status: res.status, json };
  }, [method, path, body] as const);
}

/** "YYYY-MM-DD" in local time, n days from today. */
export function day(n = 0): string {
  const d = new Date(); d.setDate(d.getDate() + n);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
/** Monday of the week n weeks ago, "YYYY-MM-DD". */
export function monday(weeksBack = 0): string {
  const d = new Date(); const diff = (d.getDay() + 6) % 7; d.setDate(d.getDate() - diff - 7 * weeksBack);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
export function localDateTime(daysAhead: number, hour: number, minute = 0): string {
  return `${day(daysAhead)}T${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}`;
}

/** A new candidate registers through the web app, confirms the e-mailed link (real sender, real outbox) and signs in. */
export async function registerCandidate(browser: Browser, first: string, last: string): Promise<{ page: Page; email: string }> {
  const email = `e2e.${last.toLowerCase()}.${Date.now().toString(36)}@candidate.example`;
  const page = await (await browser.newContext()).newPage();
  await page.goto('/register');
  await page.locator('#fn').fill(first);
  await page.locator('#ln').fill(last);
  await page.locator('#em').fill(email);
  await page.locator('#pw').fill(PASSWORD());
  await page.locator('#pw2').fill(PASSWORD());
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page.getByRole('heading', { name: 'Check your e-mail' })).toBeVisible();
  deliverMail();
  const link = latestMail(email, 'EMAIL_VERIFY');
  if (!link?.token) throw new Error('no confirmation e-mail for ' + email);
  await page.goto('/verify-email?token=' + encodeURIComponent(link.token));
  await page.getByRole('button', { name: 'Confirm my e-mail address' }).click();
  await expect(page).toHaveURL(/\/login/);
  await page.locator('#email').fill(email);
  await page.locator('#password').fill(PASSWORD());
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/candidate/);
  return { page, email };
}

/** Contractor time entry: picks the week and types the regular hours per day (Monday first). */
export async function enterWeek(page: Page, mondayIso: string, hours: number[]): Promise<void> {
  await page.locator('input[name="wk"]').fill(mondayIso);
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  for (let i = 0; i < hours.length; i++) {
    const label = `Regular hours ${names[i]} ${shownDate(addDaysIso(mondayIso, i))}`;      // the grid's accessible labels
    await page.getByRole('spinbutton', { name: label, exact: true }).fill(String(hours[i]));
  }
}
export function addDaysIso(iso: string, n: number): string {
  const d = new Date(iso + 'T00:00:00'); d.setDate(d.getDate() + n);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/** A DATE as the app shows it (e.g. "02 Nov 2026"). */
export function shownDate(iso: string): string {
  return new Date(iso + 'T00:00:00Z').toLocaleDateString('en-IN', { timeZone: 'UTC', day: '2-digit', month: 'short', year: 'numeric' });
}
