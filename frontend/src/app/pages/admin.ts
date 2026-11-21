import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api } from '../core/api';
import { Auth } from '../core/auth';
import { isoDate, statusClass, StatusTextPipe } from '../core/format';
import { Dialogs, Toasts } from '../core/ui';
import { Lookups, opts } from '../shared/lookups';
import { Column, DataTable, RowAction } from '../shared/table';
import { DetailField, DetailList } from '../shared/widgets';
import { PASSWORD_RULE } from './auth-pages';

const STAFF_ROLES = ['Recruiter', 'HRManager', 'Administrator'];

@Component({
  selector: 'app-users',
  imports: [DataTable, FormsModule],
  template: `
    <div class="page-head">
      <h1>Users & roles</h1>
      <button class="btn primary" type="button" (click)="create()">New user</button>
    </div>
    <form class="filters" (ngSubmit)="load(1)">
      <input type="search" name="q" [(ngModel)]="q" placeholder="Name or e-mail" aria-label="Search" />
      <select name="role" [(ngModel)]="role" aria-label="Role"><option value="">Any role</option>@for (r of roles; track r) { <option [value]="r">{{ r }}</option> }</select>
      <select name="active" [(ngModel)]="active" aria-label="Active"><option [ngValue]="null">Active and inactive</option><option [ngValue]="true">Active</option><option [ngValue]="false">Inactive</option></select>
      <button class="btn" type="submit">Search</button>
    </form>
    <app-table [rows]="rows()" [columns]="cols" [actions]="actions" [total]="total()" [page]="page()" (pageChange)="load($event)" empty="No users." />
  `
})
export class UsersPage implements OnInit {
  private readonly api = inject(Api);
  private readonly auth = inject(Auth);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  private readonly lookups = inject(Lookups);
  readonly roles = ['Administrator', 'HRManager', 'Recruiter', 'Customer', 'Contractor', 'Candidate'];
  q = ''; role = ''; active: boolean | null = null;
  readonly rows = signal<any[]>([]);
  readonly total = signal(0);
  readonly page = signal(1);
  readonly cols: Column[] = [
    { key: 'displayName', label: 'Name' }, { key: 'email', label: 'E-mail' }, { key: 'roles', label: 'Roles' }, { key: 'customerName', label: 'Customer' },
    { key: 'isActive', label: 'Active', type: 'bool' }, { key: 'lastLoginAt', label: 'Last sign-in', type: 'datetime' },
    { key: 'failedLoginCount', label: 'Failed sign-ins', type: 'number' }, { key: 'lockoutUntil', label: 'Locked until', type: 'datetime' }
  ];
  private readonly notMe = (r: any) => r.userId !== this.auth.user()?.userId;
  readonly actions: RowAction[] = [
    { label: 'Deactivate', kind: 'danger', show: r => r.isActive && this.notMe(r), run: r => this.setActive(r, false) },
    { label: 'Activate', kind: 'primary', show: r => !r.isActive, run: r => this.setActive(r, true) },
    { label: 'Staff roles', run: r => this.manageRole(r) }
  ];

  ngOnInit(): void { void this.load(1); }
  async load(page: number): Promise<void> {
    try { const r = await this.api.get<any>('/users', { q: this.q.trim(), role: this.role, active: this.active, page }); this.rows.set(r.items); this.total.set(r.total); this.page.set(page); }
    catch (e) { this.toasts.error(e); }
  }
  async create(): Promise<void> {
    const r = await this.dlg.open({
      title: 'New user', wide: true, submitLabel: 'Create user',
      message: 'Give the temporary password to the person through a separate channel and ask them to change it after signing in. Candidates register themselves; contractor logins are linked when a contract is created.',
      fields: [
        { key: 'email', label: 'E-mail', type: 'email', required: true, maxLength: 256 },
        { key: 'displayName', label: 'Display name', required: true, maxLength: 150 },
        { key: 'roleName', label: 'Role', type: 'select', required: true, options: opts(['Recruiter', 'HRManager', 'Administrator', 'Customer']) },
        { key: 'customerId', label: 'Customer company', type: 'select', required: true, options: () => this.lookups.customers(), showIf: v => v.roleName === 'Customer' },
        { key: 'jobTitle', label: 'Job title', maxLength: 100 },
        { key: 'departmentId', label: 'Department', type: 'select', options: () => this.lookups.departments(), showIf: v => STAFF_ROLES.includes(v.roleName) },
        { key: 'isHiringManager', label: 'Hiring manager', type: 'checkbox', showIf: v => STAFF_ROLES.includes(v.roleName) },
        { key: 'temporaryPassword', label: 'Temporary password', type: 'password', required: true, hint: PASSWORD_RULE }
      ],
      submit: v => this.api.post('/users', v)
    });
    if (r) { this.toasts.ok('User created.'); await this.load(1); }
  }
  async setActive(r: any, active: boolean): Promise<void> {
    const ok = await this.dlg.confirm(`${active ? 'Activate' : 'Deactivate'} ${r.displayName}`,
      active ? 'The user can sign in again.' : 'The user is signed out everywhere immediately and can no longer sign in. Their records are kept.',
      () => this.api.post(`/users/${r.userId}/${active ? 'activate' : 'deactivate'}`), active ? 'Activate' : 'Deactivate', !active);
    if (ok) { this.toasts.ok(active ? 'User activated.' : 'User deactivated.'); await this.load(this.page()); }
  }
  async manageRole(r: any): Promise<void> {
    const ok = await this.dlg.open({
      title: `Staff roles for ${r.displayName}`, submitLabel: 'Apply',
      message: `Current roles: ${r.roles || 'none'}. Candidate, Customer and Contractor roles come from the person's profile and cannot be granted by hand. You cannot remove your own Administrator role.`,
      fields: [
        { key: 'roleName', label: 'Role', type: 'select', required: true, options: opts(STAFF_ROLES) },
        { key: 'add', label: 'Change', type: 'select', required: true, value: true, options: [{ value: true, label: 'Grant the role' }, { value: false, label: 'Remove the role' }] }
      ],
      submit: v => this.api.post(`/users/${r.userId}/roles`, v)
    });
    if (ok) { this.toasts.ok('Roles updated.'); await this.load(this.page()); }
  }
}

@Component({
  selector: 'app-customers',
  imports: [DataTable, DetailList],
  template: `
    <div class="page-head">
      <h1>Customers</h1>
      @if (admin()) { <button class="btn primary" type="button" (click)="edit(null)">New customer</button> }
    </div>
    <app-table [rows]="rows()" [columns]="cols" [selectable]="true" keyField="customerId" [selectedKey]="sel()?.customer?.customerId" (select)="open($event)" empty="No customers." />
    @if (sel(); as s) {
      <section class="card">
        <div class="card-head">
          <h2>{{ s.customer.name }} <small class="muted">{{ s.customer.customerCode }}</small></h2>
          @if (admin()) { <button class="btn" type="button" (click)="edit(s.customer)">Edit</button> }
        </div>
        <app-details [data]="s.customer" [fields]="detail" />
        <h3>Contacts (customer users)</h3>
        <app-table [rows]="s.contacts" [columns]="contactCols" [filter]="false" empty="No users for this customer yet (create one under Users)." />
        <div class="card-head"><h3>Rate cards (standard bill rates)</h3>@if (admin()) { <button class="btn sm" type="button" (click)="rateCard(s.customer, null)">Add rate card</button> }</div>
        <app-table [rows]="rates()" [columns]="rateCols" [actions]="rateActions" [filter]="false" empty="No rate cards." />
      </section>
    }
  `
})
export class CustomersPage implements OnInit {
  private readonly api = inject(Api);
  private readonly auth = inject(Auth);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  private readonly lookups = inject(Lookups);
  readonly rows = signal<any[]>([]);
  readonly sel = signal<any>(null);
  readonly rates = signal<any[]>([]);
  readonly admin = computed(() => this.auth.has('Administrator'));
  readonly cols: Column[] = [
    { key: 'customerCode', label: 'Code' }, { key: 'name', label: 'Name' }, { key: 'industry', label: 'Industry' }, { key: 'status', label: 'Status', type: 'status' },
    { key: 'accountManager', label: 'Account manager' }, { key: 'paymentTermsDays', label: 'Terms', type: 'days' }, { key: 'outstandingBalance', label: 'Outstanding', type: 'money' }
  ];
  readonly detail: DetailField[] = [
    { key: 'industry', label: 'Industry' }, { key: 'status', label: 'Status', type: 'status' }, { key: 'billingEmail', label: 'Billing e-mail' },
    { key: 'paymentTermsDays', label: 'Payment terms', type: 'days' }, { key: 'outstandingBalance', label: 'Outstanding balance', type: 'money' }, { key: 'billingAddress', label: 'Billing address', wide: true }
  ];
  readonly contactCols: Column[] = [{ key: 'displayName', label: 'Name' }, { key: 'email', label: 'E-mail' }, { key: 'jobTitle', label: 'Title' }, { key: 'isPrimaryContact', label: 'Primary', type: 'bool' }];
  readonly rateCols: Column[] = [
    { key: 'roleCategory', label: 'Role category' }, { key: 'standardBillRate', label: 'Bill rate / h', type: 'money' }, { key: 'effectiveFrom', label: 'From', type: 'date' },
    { key: 'effectiveTo', label: 'To', type: 'date' }, { key: 'isActive', label: 'Active', type: 'bool' }
  ];
  readonly rateActions: RowAction[] = [{ label: 'Edit', show: () => this.admin(), run: r => this.rateCard(this.sel().customer, r) }];

  ngOnInit(): void { void this.load(); }
  async load(): Promise<void> { try { this.rows.set(await this.api.get('/customers')); } catch (e) { this.toasts.error(e); } }
  async open(r: any): Promise<void> {
    try {
      const [d, rc] = await Promise.all([this.api.get<any>(`/customers/${r.customerId}`), this.api.get<any[]>(`/customers/${r.customerId}/rate-cards`)]);
      this.sel.set(d); this.rates.set(rc);
    } catch (e) { this.toasts.error(e); }
  }
  async edit(c: any | null): Promise<void> {
    const out: any = await this.dlg.open({
      title: c ? `Edit ${c.name}` : 'New customer', wide: true,
      fields: [
        { key: 'customerCode', label: 'Code', value: c?.customerCode ?? '', required: true, maxLength: 20 },
        { key: 'name', label: 'Name', value: c?.name ?? '', required: true, maxLength: 200 },
        { key: 'industry', label: 'Industry', value: c?.industry ?? '', maxLength: 100 },
        { key: 'status', label: 'Status', type: 'select', value: c?.status ?? 'Active', required: true, options: opts(['Active', 'Inactive', 'OnHold']) },
        { key: 'billingEmail', label: 'Billing e-mail', type: 'email', value: c?.billingEmail ?? '', maxLength: 256 },
        { key: 'billingAddress', label: 'Billing address', type: 'textarea', value: c?.billingAddress ?? '', maxLength: 300 },
        { key: 'paymentTermsDays', label: 'Payment terms (days)', type: 'number', min: 0, max: 365, value: c?.paymentTermsDays ?? 30, required: true },
        { key: 'accountManagerUserId', label: 'Account manager', type: 'select', value: c?.accountManagerUserId ?? null, options: () => this.lookups.recruiters() }
      ],
      submit: v => c ? this.api.put(`/customers/${c.customerId}`, { ...v, rowVer: c.rowVer }) : this.api.post('/customers', v)
    });
    if (out) { this.toasts.ok('Customer saved.'); await this.load(); if (c) await this.open(c); }
  }
  async rateCard(c: any, r: any | null): Promise<void> {
    const ok = await this.dlg.open({
      title: r ? `Edit rate card: ${r.roleCategory}` : `New rate card for ${c.name}`,
      fields: [
        { key: 'roleCategory', label: 'Role category', value: r?.roleCategory ?? '', required: true, maxLength: 100 },
        { key: 'standardBillRate', label: 'Standard bill rate per hour (INR)', type: 'number', min: 0.01, step: 0.01, value: r?.standardBillRate ?? null, required: true },
        { key: 'effectiveFrom', label: 'Effective from', type: 'date', value: r ? r.effectiveFrom.substring(0, 10) : isoDate(new Date()), required: true },
        { key: 'effectiveTo', label: 'Effective to (optional)', type: 'date', value: r?.effectiveTo ? r.effectiveTo.substring(0, 10) : null },
        { key: 'isActive', label: 'Active', type: 'checkbox', value: r ? r.isActive : true }
      ],
      submit: v => { const body = { ...v, customerId: c.customerId, currency: 'INR' }; return r ? this.api.put(`/admin/rate-cards/${r.rateCardId}`, body) : this.api.post('/admin/rate-cards', body); }
    });
    if (ok) { this.toasts.ok('Rate card saved.'); await this.open(c); }
  }
}

@Component({
  selector: 'app-audit',
  imports: [DataTable, DetailList, FormsModule],
  template: `
    <div class="page-head">
      <h1>Audit & login history</h1>
      <div class="tabs" role="tablist">
        <button type="button" role="tab" [class.active]="tab() === 'audit'" (click)="tab.set('audit')">Data changes</button>
        <button type="button" role="tab" [class.active]="tab() === 'logins'" (click)="tab.set('logins')">Sign-in attempts</button>
      </div>
    </div>
    @if (tab() === 'audit') {
      <form class="filters" (ngSubmit)="loadAudit(1)">
        <input type="text" name="t" [(ngModel)]="table" placeholder="Table, e.g. cand.JobOffers" aria-label="Table" />
        <input type="text" name="r" [(ngModel)]="recordId" placeholder="Record id" aria-label="Record id" />
        <label class="inline">From <input type="date" name="from" [(ngModel)]="from" /></label>
        <label class="inline">To <input type="date" name="to" [(ngModel)]="to" /></label>
        <button class="btn" type="submit">Show</button>
      </form>
      <app-table [rows]="audit()" [columns]="auditCols" [selectable]="true" keyField="auditId" [selectedKey]="auditSel()?.auditId" (select)="auditSel.set($event)"
                 [total]="auditTotal()" [page]="auditPage()" [pageSize]="50" (pageChange)="loadAudit($event)" empty="No audit entries." />
      @if (auditSel(); as a) {
        <section class="card">
          <h2>{{ a.tableName }} #{{ a.recordId }}</h2>
          <app-details [data]="a" [fields]="auditDetail" />
          <p class="muted">Values are shown up to 4,000 characters.</p>
          <h3>Before</h3><pre class="code">{{ a.oldValues ?? '—' }}</pre>
          <h3>After</h3><pre class="code">{{ a.newValues ?? '—' }}</pre>
        </section>
      }
    } @else {
      <form class="filters" (ngSubmit)="loadLogins(1)">
        <input type="search" name="e" [(ngModel)]="email" placeholder="E-mail contains" aria-label="E-mail" />
        <select name="s" [(ngModel)]="success" aria-label="Outcome"><option [ngValue]="null">All attempts</option><option [ngValue]="true">Successful</option><option [ngValue]="false">Failed</option></select>
        <button class="btn" type="submit">Show</button>
      </form>
      <app-table [rows]="logins()" [columns]="loginCols" [total]="loginTotal()" [page]="loginPage()" [pageSize]="50" (pageChange)="loadLogins($event)" empty="No sign-in attempts." />
    }
  `
})
export class AuditPage implements OnInit {
  private readonly api = inject(Api);
  private readonly toasts = inject(Toasts);
  readonly tab = signal<'audit' | 'logins'>('audit');
  table = ''; recordId = ''; from = ''; to = ''; email = ''; success: boolean | null = null;
  readonly audit = signal<any[]>([]);
  readonly auditTotal = signal(0);
  readonly auditPage = signal(1);
  readonly auditSel = signal<any>(null);
  readonly logins = signal<any[]>([]);
  readonly loginTotal = signal(0);
  readonly loginPage = signal(1);
  readonly auditCols: Column[] = [
    { key: 'changedAt', label: 'When', type: 'datetime' }, { key: 'tableName', label: 'Table' }, { key: 'recordId', label: 'Record' },
    { key: 'action', label: 'Action', value: r => ({ I: 'Insert', U: 'Update', D: 'Delete' } as any)[r.action] ?? r.action }, { key: 'changedBy', label: 'Changed by' }
  ];
  readonly auditDetail: DetailField[] = [{ key: 'changedAt', label: 'When', type: 'datetime' }, { key: 'action', label: 'Action' }, { key: 'changedBy', label: 'Changed by (application user)' }];
  readonly loginCols: Column[] = [
    { key: 'attemptedAt', label: 'When', type: 'datetime' }, { key: 'email', label: 'E-mail' }, { key: 'success', label: 'Succeeded', type: 'bool' },
    { key: 'failureReason', label: 'Reason' }, { key: 'ipAddress', label: 'IP address' }
  ];
  ngOnInit(): void { void this.loadAudit(1); void this.loadLogins(1); }
  async loadAudit(page: number): Promise<void> {
    try {
      const r = await this.api.get<any>('/admin/audit-logs', { table: this.table.trim(), recordId: this.recordId.trim(), from: this.from, to: this.to ? this.to + 'T23:59:59' : '', page, pageSize: 50 });
      this.audit.set(r.items); this.auditTotal.set(r.total); this.auditPage.set(page); this.auditSel.set(null);
    } catch (e) { this.toasts.error(e); }
  }
  async loadLogins(page: number): Promise<void> {
    try {
      const r = await this.api.get<any>('/admin/login-history', { email: this.email.trim(), success: this.success, page, pageSize: 50 });
      this.logins.set(r.items); this.loginTotal.set(r.total); this.loginPage.set(page);
    } catch (e) { this.toasts.error(e); }
  }
}

@Component({
  selector: 'app-scheduler',
  imports: [DataTable],
  template: `
    <h1>Scheduled jobs</h1>
    <p class="muted">Database jobs run in SQL Server Agent (installed with <code>scripts\\database\\Install-AgentJobs.ps1</code>); application jobs run from
      Windows Task Scheduler (registered with <code>scripts\\scheduler\\Register-ScheduledTasks.ps1</code>). Every run is recorded here: <em>Skipped</em> means the job was switched off or another run was still going.
      A failed run also notifies the administrators. Select a job for its runs, and a run for what it did.</p>
    <app-table [rows]="rows()" [columns]="cols" [selectable]="true" keyField="jobDefinitionId" [selectedKey]="sel()?.jobDefinitionId" (select)="open($event)" empty="No job definitions." />
    @if (sel(); as j) {
      <section class="card">
        <h2>{{ j.jobName }}</h2>
        <p class="muted">{{ j.description }} · {{ j.scheduleDescription }}</p>
        <app-table [rows]="history()" [columns]="histCols" [selectable]="true" keyField="executionId" [selectedKey]="run()?.executionId" (select)="openRun($event)" [filter]="false" empty="This job has not run yet." />
        @if (run(); as r) {
          <h3>Run #{{ r.executionId }} — what it did</h3>
          <app-table [rows]="details()" [columns]="detailCols" [filter]="false" empty="No details were logged for this run." />
        }
      </section>
    }
  `
})
export class SchedulerPage implements OnInit {
  private readonly api = inject(Api);
  private readonly toasts = inject(Toasts);
  readonly rows = signal<any[]>([]);
  readonly sel = signal<any>(null);
  readonly history = signal<any[]>([]);
  readonly run = signal<any>(null);
  readonly details = signal<any[]>([]);
  readonly detailCols: Column[] = [{ key: 'loggedAt', label: 'When', type: 'datetime' }, { key: 'level', label: 'Level', type: 'status' }, { key: 'message', label: 'Message' }];
  readonly cols: Column[] = [
    { key: 'jobName', label: 'Job' }, { key: 'owner', label: 'Runs in' }, { key: 'scheduleDescription', label: 'Schedule' }, { key: 'isEnabled', label: 'Enabled', type: 'bool' },
    { key: 'lastStartedAt', label: 'Last run', type: 'datetime' }, { key: 'lastOutcome', label: 'Outcome', type: 'status' }, { key: 'lastRowsAffected', label: 'Rows', type: 'number' }, { key: 'lastError', label: 'Last error' }
  ];
  readonly histCols: Column[] = [
    { key: 'startedAt', label: 'Started', type: 'datetime' }, { key: 'finishedAt', label: 'Finished', type: 'datetime' }, { key: 'outcome', label: 'Outcome', type: 'status' },
    { key: 'rowsAffected', label: 'Rows', type: 'number' }, { key: 'errorMessage', label: 'Error' }, { key: 'hostName', label: 'Host' }
  ];
  ngOnInit(): void { void this.load(); }
  async load(): Promise<void> { try { this.rows.set(await this.api.get('/admin/jobs')); } catch (e) { this.toasts.error(e); } }
  async open(j: any): Promise<void> {
    this.sel.set(j); this.run.set(null); this.details.set([]);
    try { this.history.set(await this.api.get(`/admin/jobs/${j.jobDefinitionId}/history`, { top: 50 })); } catch (e) { this.toasts.error(e); }
  }
  async openRun(r: any): Promise<void> {
    this.run.set(r);
    try { this.details.set(await this.api.get(`/admin/jobs/runs/${r.executionId}/details`)); } catch (e) { this.toasts.error(e); }
  }
  badge(v: unknown): string { return statusClass(v); }
}

/** Phase 9: the e-mail delivery queue. Message bodies are never shown here (they can hold personal details and sign-in links). */
@Component({
  selector: 'app-email-queue',
  imports: [DataTable, FormsModule, StatusTextPipe],
  template: `
    <div class="page-head">
      <h1>E-mail queue</h1>
      <form class="tools wrap" (ngSubmit)="load(1)">
        <select name="st" [(ngModel)]="status" aria-label="Status"><option value="">All statuses</option>@for (s of statuses; track s) { <option [value]="s">{{ s | statusText }}</option> }</select>
        <input type="search" name="q" [(ngModel)]="q" placeholder="Address, subject or template" aria-label="Search" />
        <button class="btn" type="submit">Show</button>
      </form>
    </div>
    <p class="muted">Every notification is also e-mailed. The sender (<code>TalentAcquisition.Scheduler process-notifications</code>) writes each message as an .eml file
      to the mock outbox; a failed attempt is retried after 1, 2, 4 and 8 minutes and the message is marked Failed after 5 attempts.
      Sign-in links (password reset, e-mail confirmation) are never re-sent and their text is erased once handled.</p>
    <app-table [rows]="rows()" [columns]="cols" [actions]="actions" [selectable]="true" keyField="notificationId" [selectedKey]="sel()?.notificationId"
               [total]="total()" [page]="page()" (pageChange)="load($event)" (select)="open($event)" empty="No e-mails in the queue." />
    @if (sel(); as n) {
      <section class="card">
        <h2>Delivery attempts — #{{ n.notificationId }}</h2>
        <p class="muted">{{ n.subject }} → {{ n.toEmail }}</p>
        <app-table [rows]="history()" [columns]="histCols" [filter]="false" empty="Not attempted yet." />
      </section>
    }
  `
})
export class EmailQueuePage implements OnInit {
  private readonly api = inject(Api);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  readonly statuses = ['Pending', 'Processing', 'Sent', 'Failed', 'Cancelled'];
  status = ''; q = '';
  readonly rows = signal<any[]>([]);
  readonly total = signal(0);
  readonly page = signal(1);
  readonly sel = signal<any>(null);
  readonly history = signal<any[]>([]);
  readonly cols: Column[] = [
    { key: 'createdAt', label: 'Queued', type: 'datetime' }, { key: 'templateCode', label: 'Type' }, { key: 'toEmail', label: 'To' }, { key: 'subject', label: 'Subject' },
    { key: 'status', label: 'Status', type: 'status' }, { key: 'attempts', label: 'Attempts', value: r => `${r.attempts} / ${r.maxAttempts}` },
    { key: 'when', label: 'Sent / next try', value: r => r.status === 'Pending' || r.status === 'Processing' ? r.nextAttemptAt : r.processedAt, type: 'datetime' },
    { key: 'lastError', label: 'Last error' }
  ];
  readonly actions: RowAction[] = [
    { label: 'Send again', kind: 'primary', show: r => (r.status === 'Failed' || r.status === 'Cancelled') && !r.isSecurity, run: r => this.act(r, 'retry') },
    { label: "Don't send", kind: 'danger', show: r => r.status === 'Pending', run: r => this.act(r, 'cancel') }
  ];
  readonly histCols: Column[] = [
    { key: 'attemptNo', label: 'Attempt', type: 'number' }, { key: 'attemptedAt', label: 'When', type: 'datetime' }, { key: 'outcome', label: 'Outcome', type: 'status' }, { key: 'errorMessage', label: 'Error' }
  ];

  ngOnInit(): void { void this.load(1); }
  async load(page: number): Promise<void> {
    try { const r = await this.api.get<any>('/admin/notifications', { status: this.status, q: this.q.trim(), page }); this.rows.set(r.items); this.total.set(r.total); this.page.set(page); }
    catch (e) { this.toasts.error(e); }
  }
  async open(n: any): Promise<void> {
    this.sel.set(n);
    try { this.history.set(await this.api.get(`/admin/notifications/${n.notificationId}/history`)); } catch (e) { this.toasts.error(e); }
  }
  async act(n: any, what: 'retry' | 'cancel'): Promise<void> {
    const ok = await this.dlg.confirm(what === 'retry' ? 'Send again' : "Don't send this e-mail",
      what === 'retry' ? `Queue "${n.subject}" to ${n.toEmail} again with fresh attempts? It goes out the next time the sender runs.`
                       : `"${n.subject}" to ${n.toEmail} will not be sent. The in-app notification stays.`,
      () => this.api.post(`/admin/notifications/${n.notificationId}/${what}`), what === 'retry' ? 'Send again' : "Don't send", what === 'cancel');
    if (ok) { this.toasts.ok(what === 'retry' ? 'Queued again.' : 'The e-mail will not be sent.'); await this.load(this.page()); if (this.sel()?.notificationId === n.notificationId) await this.open(n); }
  }
}
