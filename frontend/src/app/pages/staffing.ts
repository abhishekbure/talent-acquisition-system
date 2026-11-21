import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api } from '../core/api';
import { Auth } from '../core/auth';
import { statusClass, StatusTextPipe } from '../core/format';
import { Dialogs, FieldDef, Toasts } from '../core/ui';
import { Actions } from '../shared/actions';
import { Lookups } from '../shared/lookups';
import { Column, DataTable, RowAction } from '../shared/table';
import { DetailField, DetailList } from '../shared/widgets';

const OPEN_FOR_SUBMISSIONS = ['Open', 'InReview', 'Sourcing'];

/**
 * Customer staffing requests. Customers see and decide only their own company's requests (the API takes the
 * customer from the login); recruiters accept requests, submit candidates and create contracts.
 */
@Component({
  selector: 'app-staffing-requests',
  imports: [DataTable, DetailList, FormsModule, StatusTextPipe],
  template: `
    <div class="page-head">
      <h1>Staffing requests</h1>
      <div class="tools wrap">
        @if (staff()) {
          <select [(ngModel)]="customerId" name="cust" (change)="load()" aria-label="Customer">
            <option [ngValue]="null">All customers</option>
            @for (c of customers(); track c.value) { <option [ngValue]="c.value">{{ c.label }}</option> }
          </select>
        }
        <select [(ngModel)]="status" name="st" (change)="load()" aria-label="Status">
          <option value="">All statuses</option>
          @for (s of statuses; track s) { <option [value]="s">{{ s | statusText }}</option> }
        </select>
        <button class="btn primary" type="button" (click)="create()">New staffing request</button>
      </div>
    </div>
    <app-table [rows]="rows()" [columns]="cols()" [actions]="rowActions" [selectable]="true" keyField="customerRequisitionId" [selectedKey]="sel()?.customerRequisitionId" (select)="openRequest($event)" empty="No staffing requests." />
    @if (sel(); as r) {
      <section class="card">
        <div class="card-head">
          <h2>{{ r.requestNo }} — {{ r.title }} <small class="muted">{{ r.customerName }}</small></h2>
          <span [class]="badge(r.status)">{{ r.status | statusText }}</span>
        </div>
        <app-details [data]="r" [fields]="detail" />
        <div class="card-head">
          <h3>Submitted candidates</h3>
          @if (staff() && acceptsSubmissions(r)) { <button class="btn primary" type="button" (click)="submitCandidate(r)">Submit a candidate</button> }
        </div>
        @if (customer()) { <p class="muted">Contact details become visible once you shortlist a candidate.</p> }
        <app-table [rows]="subs()" [columns]="subCols" [actions]="subActions" [filter]="false" empty="No candidates submitted yet." />
      </section>
    }
  `
})
export class StaffingRequestsPage implements OnInit {
  private readonly api = inject(Api);
  private readonly auth = inject(Auth);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  private readonly lookups = inject(Lookups);
  private readonly actions = inject(Actions);
  readonly statuses = ['Open', 'InReview', 'Sourcing', 'Filled', 'Cancelled'];
  status = '';
  customerId: number | null = null;
  readonly rows = signal<any[]>([]);
  readonly sel = signal<any>(null);
  readonly subs = signal<any[]>([]);
  readonly customers = signal<{ value: any; label: string }[]>([]);
  readonly staff = computed(() => this.auth.has('Recruiter', 'Administrator'));
  readonly customer = computed(() => this.auth.has('Customer'));

  readonly cols = computed<Column[]>(() => [
    { key: 'requestNo', label: 'Request' },
    ...(this.staff() ? [{ key: 'customerName', label: 'Customer' }] : []),
    { key: 'title', label: 'Role' }, { key: 'positions', label: 'Positions', type: 'number' }, { key: 'status', label: 'Status', type: 'status' },
    { key: 'startDate', label: 'Start', type: 'date' }, { key: 'maxBillRate', label: 'Max bill rate / h', type: 'money' },
    { key: 'submissions', label: 'Submissions', type: 'number' }, { key: 'createdAt', label: 'Raised', type: 'datetime' }
  ] as Column[]);
  readonly rowActions: RowAction[] = [
    { label: 'Accept', kind: 'primary', show: r => this.staff() && ['Open', 'InReview'].includes(r.status) && (!r.assignedRecruiterUserId || r.assignedRecruiterUserId === this.auth.user()?.userId || this.auth.has('Administrator')), run: r => this.accept(r) },
    { label: 'Cancel', kind: 'danger', show: r => (this.customer() || this.auth.has('Administrator')) && !['Filled', 'Cancelled'].includes(r.status), run: r => this.cancel(r) }
  ];
  readonly detail: DetailField[] = [
    { key: 'positions', label: 'Positions', type: 'number' }, { key: 'startDate', label: 'Start', type: 'date' }, { key: 'maxBillRate', label: 'Max bill rate / h', type: 'money' },
    { key: 'createdAt', label: 'Raised', type: 'datetime' }
  ];
  readonly subCols: Column[] = [
    { key: 'name', label: 'Candidate', value: s => `${s.firstName} ${s.lastName}` }, { key: 'currentTitle', label: 'Current title' },
    { key: 'totalExperienceYears', label: 'Experience (y)', type: 'number' }, { key: 'proposedBillRate', label: 'Proposed bill rate / h', type: 'money' },
    { key: 'status', label: 'Status', type: 'status' }, { key: 'submittedAt', label: 'Submitted', type: 'datetime' }, { key: 'notes', label: 'Recruiter notes' },
    { key: 'email', label: 'E-mail' }, { key: 'phone', label: 'Phone' }, { key: 'contractNo', label: 'Contract' }
  ];
  readonly subActions: RowAction[] = [
    { label: 'Shortlist', kind: 'primary', show: s => this.customer() && s.status === 'Submitted', run: s => this.decide(s, 'Shortlist') },
    { label: 'Select', kind: 'primary', show: s => this.customer() && ['Shortlisted', 'Interview'].includes(s.status), run: s => this.decide(s, 'Select') },
    { label: 'Reject', kind: 'danger', show: s => this.customer() && ['Submitted', 'Shortlisted', 'Interview'].includes(s.status), run: s => this.decide(s, 'Reject') },
    { label: 'Schedule interview', show: s => (this.customer() || this.staff()) && ['Shortlisted', 'Interview'].includes(s.status), run: s => this.interview(s) },
    { label: 'Résumé', show: s => this.staff() || ['Shortlisted', 'Interview', 'Selected'].includes(s.status), run: s => this.resume(s) },
    { label: 'Create contract', kind: 'primary', show: s => this.staff() && s.status === 'Selected' && !s.contractNo, run: s => this.contract(s) },
    { label: 'Withdraw', kind: 'danger', show: s => this.staff() && ['Submitted', 'Shortlisted', 'Interview'].includes(s.status), run: s => this.withdraw(s) }
  ];

  async ngOnInit(): Promise<void> {
    await this.load();
    if (this.staff()) { try { this.customers.set(await this.lookups.customers()); } catch (e) { this.toasts.error(e); } }
  }
  acceptsSubmissions(r: any): boolean { return OPEN_FOR_SUBMISSIONS.includes(r.status); }
  async load(): Promise<void> {
    try {
      this.rows.set(await this.api.get('/staffing/requests', { status: this.status, customerId: this.customerId }));
      const s = this.sel();
      if (s) this.sel.set(this.rows().find(r => r.customerRequisitionId === s.customerRequisitionId) ?? null);
    } catch (e) { this.toasts.error(e); }
  }
  async openRequest(r: any): Promise<void> {
    this.sel.set(r);
    try { this.subs.set(await this.api.get(`/staffing/requests/${r.customerRequisitionId}/submissions`)); } catch (e) { this.toasts.error(e); }
  }
  async create(): Promise<void> {
    const fields: FieldDef[] = [
      ...(this.staff() ? [{ key: 'customerId', label: 'Customer', type: 'select', required: true, options: () => this.lookups.customers() } as FieldDef] : []),
      { key: 'title', label: 'Role title', required: true, maxLength: 200 },
      { key: 'description', label: 'Description', type: 'textarea', maxLength: 2000 },
      { key: 'positions', label: 'Positions', type: 'number', min: 1, max: 1000, value: 1, required: true },
      { key: 'skillsRequired', label: 'Skills required', maxLength: 500, placeholder: 'e.g. Java, Spring, SQL' },
      { key: 'startDate', label: 'Start date', type: 'date' },
      { key: 'durationMonths', label: 'Duration (months)', type: 'number', min: 1, max: 60 },
      { key: 'maxBillRate', label: 'Maximum bill rate per hour (INR)', type: 'number', min: 1, step: 0.01 },
      { key: 'workLocation', label: 'Work location', maxLength: 150 }
    ];
    const r: any = await this.dlg.open({ title: 'New staffing request', wide: true, fields, submitLabel: 'Raise request', submit: v => this.api.post('/staffing/requests', v) });
    if (r) { this.toasts.ok(`Request ${r.requestNo} raised.`); await this.load(); }
  }
  async accept(r: any): Promise<void> {
    const ok = await this.dlg.open({
      title: `Accept ${r.requestNo}`, submitLabel: 'Accept',
      fields: [{ key: 'assignedRecruiterUserId', label: 'Assign to recruiter (default: you)', type: 'select', options: () => this.lookups.recruiters() }],
      submit: v => this.api.post(`/staffing/requests/${r.customerRequisitionId}/accept`, v)
    });
    if (ok) { this.toasts.ok('Request accepted.'); await this.load(); }
  }
  async cancel(r: any): Promise<void> {
    const ok = await this.dlg.open({
      title: `Cancel ${r.requestNo}`, danger: true, submitLabel: 'Cancel request',
      fields: [{ key: 'reason', label: 'Reason', type: 'textarea', maxLength: 300 }],
      submit: v => this.api.post(`/staffing/requests/${r.customerRequisitionId}/cancel`, v)
    });
    if (ok) { this.toasts.ok('Request cancelled.'); await this.load(); }
  }
  async submitCandidate(r: any): Promise<void> {
    const ok = await this.dlg.open({
      title: `Submit a candidate to ${r.customerName}`, submitLabel: 'Submit candidate',
      message: r.maxBillRate ? `The customer's maximum bill rate is ${r.maxBillRate}/h.` : undefined,
      fields: [
        { key: 'candidateId', label: 'Candidate (shared candidate master)', type: 'select', required: true, options: () => this.lookups.activeCandidates() },
        { key: 'proposedBillRate', label: 'Proposed bill rate per hour', type: 'number', min: 0.01, step: 0.01, max: r.maxBillRate ?? undefined },
        { key: 'notes', label: 'Notes for the customer', type: 'textarea', maxLength: 1000 }
      ],
      submit: v => this.api.post(`/staffing/requests/${r.customerRequisitionId}/submissions`, v)
    });
    if (ok) { this.toasts.ok('Candidate submitted; the customer has been notified.'); await this.load(); await this.openRequest(this.sel()); }
  }
  async decide(s: any, decision: 'Shortlist' | 'Select' | 'Reject'): Promise<void> {
    const ok = await this.dlg.open({
      title: `${decision}: ${s.firstName} ${s.lastName}`, submitLabel: decision, danger: decision === 'Reject',
      message: decision === 'Select' ? 'Selecting tells the recruiter to prepare a contract for this candidate.' : undefined,
      fields: [{ key: 'comments', label: decision === 'Reject' ? 'Reason' : 'Comments (optional)', type: 'textarea', required: decision === 'Reject', maxLength: 500 }],
      submit: v => this.api.post(`/staffing/submissions/${s.submissionId}/decision`, { decision, comments: v.comments })
    });
    if (ok) { this.toasts.ok(`Candidate ${decision === 'Shortlist' ? 'shortlisted' : decision === 'Select' ? 'selected' : 'rejected'}.`); await this.refresh(); }
  }
  async interview(s: any): Promise<void> {
    const r = this.sel();
    const panel = this.customer() && !this.staff() ? () => this.lookups.customerContacts(this.auth.user()!.customerId!) : () => this.lookups.staffAndCustomer(r.customerId);
    if (await this.actions.scheduleInterview({ submittedCandidateId: s.submissionId }, panel, 'Customer')) { this.toasts.ok('Interview scheduled; the candidate has been invited.'); await this.refresh(); }
  }
  async contract(s: any): Promise<void> {
    const r = this.sel();
    const out: any = await this.actions.createContract(s, { title: r.title, maxBillRate: r.maxBillRate, startDate: r.startDate, workLocation: null });
    if (out) { this.toasts.ok(`Contract ${out.contractNo} created.`); await this.refresh(); }
  }
  async withdraw(s: any): Promise<void> {
    const ok = await this.dlg.confirm('Withdraw submission', `Withdraw ${s.firstName} ${s.lastName} from this request?`, () => this.api.post(`/staffing/submissions/${s.submissionId}/withdraw`), 'Withdraw', true);
    if (ok) { this.toasts.ok('Submission withdrawn.'); await this.refresh(); }
  }
  /** Downloads the candidate's main résumé (customers only see it after shortlisting - enforced by the database). */
  async resume(s: any): Promise<void> {
    try {
      const docs: any[] = await this.api.get('/documents', { ownerType: 'Candidate', ownerId: s.candidateId });
      const cv = docs.find(d => d.docType === 'Resume' && d.isPrimaryResume) ?? docs.find(d => d.docType === 'Resume');
      if (!cv) { this.toasts.info(`${s.firstName} ${s.lastName} has no résumé on file yet.`); return; }
      await this.api.download(`/documents/${cv.documentId}/download`, cv.originalFileName);
    } catch (e) { this.toasts.error(e); }
  }
  private async refresh(): Promise<void> { await this.load(); if (this.sel()) await this.openRequest(this.sel()); }
  badge(v: unknown): string { return statusClass(v); }
}

@Component({
  selector: 'app-contractors',
  imports: [DataTable, FormsModule],
  template: `
    <div class="page-head">
      <h1>Contractors</h1>
      <div class="tools">
        @if (staff()) {
          <div class="tabs" role="tablist">
            <button type="button" role="tab" [class.active]="tab() === 'list'" (click)="tab.set('list')">Contractors</button>
            <button type="button" role="tab" [class.active]="tab() === 'compliance'" (click)="tab.set('compliance')">Compliance</button>
          </div>
          <button class="btn" type="button" (click)="register()">Register contractor</button>
        }
      </div>
    </div>
    @if (tab() === 'list') {
      <app-table [rows]="rows()" [columns]="cols" empty="No contractors." />
    } @else {
      <div class="tools">
        <label class="inline">Expiring within
          <select [(ngModel)]="within" name="w" (change)="loadCompliance()">
            <option [ngValue]="null">any time</option><option [ngValue]="30">30 days</option><option [ngValue]="60">60 days</option><option [ngValue]="90">90 days</option>
          </select>
        </label>
      </div>
      <app-table [rows]="compliance()" [columns]="compCols" [actions]="compActions" empty="No compliance records." />
    }
  `
})
export class ContractorsPage implements OnInit {
  private readonly api = inject(Api);
  private readonly auth = inject(Auth);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  private readonly lookups = inject(Lookups);
  readonly tab = signal<'list' | 'compliance'>('list');
  readonly rows = signal<any[]>([]);
  readonly compliance = signal<any[]>([]);
  readonly staff = computed(() => this.auth.has('Recruiter', 'Administrator'));
  within: number | null = null;
  readonly cols: Column[] = [
    { key: 'contractorNo', label: 'No.' }, { key: 'contractorName', label: 'Name' }, { key: 'email', label: 'E-mail' }, { key: 'status', label: 'Status', type: 'status' },
    { key: 'activeAssignments', label: 'Active assignments', type: 'number' }, { key: 'currentCustomer', label: 'Current customer' }
  ];
  readonly compCols: Column[] = [
    { key: 'contractorNo', label: 'No.' }, { key: 'contractorName', label: 'Contractor' }, { key: 'recordType', label: 'Record' }, { key: 'status', label: 'Status', type: 'status' },
    { key: 'issuedOn', label: 'Issued', type: 'date' }, { key: 'expiresOn', label: 'Expires', type: 'date' }, { key: 'daysToExpiry', label: 'Days left', type: 'number' },
    { key: 'proof', label: 'Proof', value: r => r.documentId ? 'Attached' : 'Missing' }, { key: 'notes', label: 'Notes' }
  ];
  readonly compActions: RowAction[] = [
    { label: 'Proof', show: r => !!r.documentId, run: r => this.proof(r) },
    { label: 'Verify', kind: 'primary', show: r => !!r.documentId && r.status !== 'Verified', run: r => this.decideCompliance(r, 'Verified') },
    { label: 'Reject', kind: 'danger', show: r => r.status !== 'Rejected', run: r => this.decideCompliance(r, 'Rejected') }
  ];
  ngOnInit(): void { void this.load(); if (this.staff()) void this.loadCompliance(); }
  async load(): Promise<void> { try { this.rows.set(await this.api.get('/contractors')); } catch (e) { this.toasts.error(e); } }
  async loadCompliance(): Promise<void> { try { this.compliance.set(await this.api.get('/contractors/compliance', { expiringWithinDays: this.within })); } catch (e) { this.toasts.error(e); } }
  async proof(r: any): Promise<void> {
    try { await this.api.download(`/documents/${r.documentId}/download`, `${r.contractorNo}-${r.recordType}`); } catch (e) { this.toasts.error(e); }
  }
  async decideCompliance(r: any, status: 'Verified' | 'Rejected'): Promise<void> {
    const ok = await this.dlg.open({
      title: `${status === 'Verified' ? 'Verify' : 'Reject'} ${r.recordType} for ${r.contractorName}`, submitLabel: status === 'Verified' ? 'Verify' : 'Reject', danger: status === 'Rejected',
      message: status === 'Verified' ? 'Confirm you have checked the attached proof.' : 'The contractor is told why and can upload a new proof.',
      fields: [{ key: 'notes', label: status === 'Verified' ? 'Notes (optional)' : 'Reason', type: 'textarea', required: status === 'Rejected', maxLength: 500 }],
      submit: v => this.api.post(`/compliance/${r.complianceId}/decision`, { status, notes: v.notes })
    });
    if (ok) { this.toasts.ok(`Compliance record ${status.toLowerCase()}.`); await this.loadCompliance(); }
  }
  async register(): Promise<void> {
    const r: any = await this.dlg.open({
      title: 'Register a contractor', submitLabel: 'Register',
      message: 'Creates a contractor record from the shared candidate master. If the candidate has a login, it gains the Contractor role. Contracts created for a selected submission do this automatically.',
      fields: [{ key: 'candidateId', label: 'Candidate', type: 'select', required: true, options: () => this.lookups.activeCandidates() }],
      submit: v => this.api.post('/contractors', v)
    });
    if (r) { this.toasts.ok('Contractor registered.'); await this.load(); }
  }
}
