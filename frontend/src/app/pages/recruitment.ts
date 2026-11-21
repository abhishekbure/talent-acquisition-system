import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api } from '../core/api';
import { Auth } from '../core/auth';
import { formatValue, statusClass, StatusTextPipe } from '../core/format';
import { Dialogs, Option, Toasts } from '../core/ui';
import { Actions } from '../shared/actions';
import { EMPLOYMENT_TYPES, Lookups, opts } from '../shared/lookups';
import { Column, DataTable, RowAction } from '../shared/table';
import { DetailField, DetailList } from '../shared/widgets';

/** Same transitions as cand.usp_ChangeApplicationStatus; the procedure remains the authority. */
export const NEXT_STATUS: Record<string, string[]> = {
  Applied: ['Screening', 'Rejected'], Screening: ['Shortlisted', 'Rejected'], Shortlisted: ['Interview', 'Rejected'],
  Interview: ['Selected', 'Shortlisted', 'Rejected'], Selected: ['Rejected']
};

/** Opens the "new job" dialog; used from Jobs and from an approved hiring request. */
function openJobDialog(api: Api, dlg: Dialogs, lookups: Lookups, auth: Auth, requisitionId: number | null = null, title = ''): Promise<unknown> {
  return dlg.open({
    title: title ? `New job for "${title}"` : 'New job', wide: true, submitLabel: 'Create job',
    message: 'The job is created as "Pending approval"; an HR Manager who did not create it approves the content before it can be published.',
    fields: [
      { key: 'employeeRequisitionId', label: 'Approved hiring request', type: 'select', required: true, value: requisitionId, options: () => lookups.approvedRequisitions(), hint: 'Only approved hiring requests with headcount not yet planned into jobs are listed.' },
      { key: 'ownerRecruiterUserId', label: 'Owning recruiter', type: 'select', value: auth.has('Recruiter') ? auth.user()!.userId : null, options: () => lookups.recruiters(), required: true },
      { key: 'openings', label: 'Openings', type: 'number', min: 1, value: 1, required: true },
      { key: 'summary', label: 'Summary', type: 'textarea', maxLength: 500 },
      { key: 'responsibilities', label: 'Responsibilities', type: 'textarea' },
      { key: 'qualifications', label: 'Qualifications', type: 'textarea' },
      { key: 'minExperienceYears', label: 'Minimum experience (years)', type: 'number', min: 0, max: 60, step: 0.5, value: 0, required: true },
      { key: 'salaryMin', label: 'Salary from (INR / year)', type: 'number', min: 0 },
      { key: 'salaryMax', label: 'Salary to (INR / year)', type: 'number', min: 0 },
      { key: 'closesBy', label: 'Closes by', type: 'date' },
      {
        key: 'skills', label: 'Skills', type: 'rows', value: [{ skillName: '', isRequired: true, minYears: 0 }],
        rows: [{ key: 'skillName', label: 'Skill' }, { key: 'isRequired', label: 'Required', type: 'checkbox', value: true }, { key: 'minYears', label: 'Min. years', type: 'number', min: 0, step: 0.5, value: 0 }]
      }
    ],
    submit: v => api.post('/jobs', { ...v, skills: (v.skills as any[]).filter(s => s.skillName).map(s => ({ skillName: s.skillName, isRequired: s.isRequired, minYears: s.minYears ?? 0 })) })
  });
}

@Component({
  selector: 'app-requisitions',
  imports: [DataTable, DetailList, FormsModule, StatusTextPipe],
  template: `
    <div class="page-head">
      <h1>Hiring requests</h1>
      <div class="tools">
        <select [(ngModel)]="status" name="st" (change)="load(1)" aria-label="Status">
          <option value="">All statuses</option>
          @for (s of statuses; track s) { <option [value]="s">{{ s | statusText }}</option> }
        </select>
        @if (hr()) { <button class="btn primary" type="button" (click)="create()">New hiring request</button> }
      </div>
    </div>
    <app-table [rows]="rows()" [columns]="cols" [actions]="actions" [selectable]="true" keyField="employeeRequisitionId" [selectedKey]="sel()?.request?.employeeRequisitionId"
               [total]="total()" [page]="page()" (pageChange)="load($event)" (select)="open($event)" empty="No hiring requests." />
    @if (sel(); as s) {
      <section class="card">
        <div class="card-head"><h2>{{ s.request.requisitionNo }} — {{ s.request.title }}</h2><span [class]="badge(s.request.status)">{{ s.request.status | statusText }}</span></div>
        <app-details [data]="s.request" [fields]="detail" />
        <h3>Approvals</h3>
        <app-table [rows]="s.approvals" [columns]="apprCols" [filter]="false" empty="No decision yet." />
        <h3>Jobs created from this request</h3>
        <app-table [rows]="s.jobs" [columns]="jobCols" [filter]="false" empty="No jobs yet." />
      </section>
    }
  `
})
export class RequisitionsPage implements OnInit {
  private readonly api = inject(Api);
  private readonly auth = inject(Auth);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  private readonly lookups = inject(Lookups);
  readonly statuses = ['Draft', 'Submitted', 'Approved', 'Rejected', 'Cancelled'];
  status = '';
  readonly rows = signal<any[]>([]);
  readonly total = signal(0);
  readonly page = signal(1);
  readonly sel = signal<any>(null);
  readonly hr = computed(() => this.auth.has('HRManager', 'Administrator'));
  private readonly me = () => this.auth.user()?.userId;

  readonly cols: Column[] = [
    { key: 'requisitionNo', label: 'Request' }, { key: 'title', label: 'Title' }, { key: 'department', label: 'Department' }, { key: 'location', label: 'Location' },
    { key: 'headcount', label: 'Headcount', type: 'number' }, { key: 'openingsPlanned', label: 'Openings planned', type: 'number' }, { key: 'budgetMax', label: 'Budget max', type: 'money' },
    { key: 'requiredByDate', label: 'Needed by', type: 'date' }, { key: 'status', label: 'Status', type: 'status' }, { key: 'requestedBy', label: 'Requested by' }
  ];
  readonly actions: RowAction[] = [
    { label: 'Submit', kind: 'primary', show: r => this.hr() && r.status === 'Draft' && (r.requestedByUserId === this.me() || this.auth.has('Administrator')), run: r => this.submit(r) },
    { label: 'Approve', kind: 'primary', show: r => this.hr() && r.status === 'Submitted' && r.requestedByUserId !== this.me(), run: r => this.decide(r, true) },
    { label: 'Reject', kind: 'danger', show: r => this.hr() && r.status === 'Submitted' && r.requestedByUserId !== this.me(), run: r => this.decide(r, false) },
    { label: 'Create job', show: r => r.status === 'Approved' && Number(r.openingsPlanned) < Number(r.headcount), run: r => this.createJob(r) }
  ];
  readonly detail: DetailField[] = [
    { key: 'department', label: 'Department' }, { key: 'location', label: 'Location' }, { key: 'headcount', label: 'Headcount', type: 'number' },
    { key: 'employmentType', label: 'Employment type' }, { key: 'budgetMax', label: 'Budget max', type: 'money' }, { key: 'requiredByDate', label: 'Needed by', type: 'date' },
    { key: 'requestedBy', label: 'Requested by' }, { key: 'submittedAt', label: 'Submitted', type: 'datetime' }, { key: 'justification', label: 'Justification', wide: true }
  ];
  readonly apprCols: Column[] = [{ key: 'decision', label: 'Decision', type: 'status' }, { key: 'approver', label: 'By' }, { key: 'decidedAt', label: 'When', type: 'datetime' }, { key: 'comments', label: 'Comments' }];
  readonly jobCols: Column[] = [{ key: 'jobCode', label: 'Job' }, { key: 'title', label: 'Title' }, { key: 'openings', label: 'Openings', type: 'number' }, { key: 'status', label: 'Status', type: 'status' }];

  ngOnInit(): void { void this.load(1); }
  async load(page: number): Promise<void> {
    try { const r = await this.api.get<any>('/requisitions', { status: this.status, page }); this.rows.set(r.items); this.total.set(r.total); this.page.set(page); }
    catch (e) { this.toasts.error(e); }
  }
  async open(r: any): Promise<void> { try { this.sel.set(await this.api.get(`/requisitions/${r.employeeRequisitionId}`)); } catch (e) { this.toasts.error(e); } }

  async create(): Promise<void> {
    const r: any = await this.dlg.open({
      title: 'New hiring request', wide: true, submitLabel: 'Save',
      fields: [
        { key: 'departmentId', label: 'Department', type: 'select', required: true, options: () => this.lookups.departments() },
        { key: 'locationId', label: 'Location', type: 'select', options: () => this.lookups.locations() },
        { key: 'title', label: 'Position title', required: true, maxLength: 200 },
        { key: 'headcount', label: 'Headcount', type: 'number', min: 1, max: 1000, value: 1, required: true },
        { key: 'employmentType', label: 'Employment type', type: 'select', options: EMPLOYMENT_TYPES, value: 'FullTime', required: true },
        { key: 'justification', label: 'Business justification', type: 'textarea', maxLength: 1000 },
        { key: 'budgetMax', label: 'Maximum annual budget per hire (INR)', type: 'number', min: 0 },
        { key: 'requiredByDate', label: 'Needed by', type: 'date' },
        { key: 'submit', label: 'Submit for approval now (otherwise saved as Draft)', type: 'checkbox', value: true }
      ],
      submit: v => this.api.post('/requisitions', v)
    });
    if (r) { this.toasts.ok(`Hiring request ${r.requisitionNo} saved.`); await this.load(1); }
  }
  async submit(r: any): Promise<void> {
    if (await this.dlg.confirm(`Submit ${r.requisitionNo}`, 'Send this hiring request for approval by another HR Manager?', () => this.api.post(`/requisitions/${r.employeeRequisitionId}/submit`), 'Submit')) await this.after(r, 'Submitted for approval.');
  }
  async decide(r: any, approve: boolean): Promise<void> {
    const ok = await this.dlg.open({
      title: `${approve ? 'Approve' : 'Reject'} ${r.requisitionNo}`, submitLabel: approve ? 'Approve' : 'Reject', danger: !approve,
      fields: [{ key: 'comments', label: approve ? 'Comments (optional)' : 'Reason', type: 'textarea', required: !approve, maxLength: 500 }],
      submit: v => this.api.post(`/requisitions/${r.employeeRequisitionId}/${approve ? 'approve' : 'reject'}`, v)
    });
    if (ok) await this.after(r, approve ? 'Hiring request approved.' : 'Hiring request rejected.');
  }
  async createJob(r: any): Promise<void> {
    const out: any = await openJobDialog(this.api, this.dlg, this.lookups, this.auth, r.employeeRequisitionId, r.title);
    if (out) await this.after(r, `Job ${out.jobCode} created and sent for approval.`);
  }
  private async after(r: any, msg: string): Promise<void> { this.toasts.ok(msg); await this.load(this.page()); await this.open(r); }
  badge(v: unknown): string { return statusClass(v); }
}

@Component({
  selector: 'app-jobs',
  imports: [DataTable, DetailList, FormsModule],
  template: `
    <div class="page-head">
      <h1>Jobs</h1>
      <form class="tools wrap" (ngSubmit)="load(1)">
        <input type="search" name="q" [(ngModel)]="q" placeholder="Title or code" aria-label="Search jobs" />
        <select [(ngModel)]="status" name="st" aria-label="Status">
          <option value="">All statuses</option>
          @for (s of statuses; track s) { <option [value]="s">{{ label(s) }}</option> }
        </select>
        <button class="btn" type="submit">Show</button>
        <button class="btn primary" type="button" (click)="create()">New job</button>
      </form>
    </div>
    <app-table [rows]="rows()" [columns]="cols" [actions]="actions" [selectable]="true" keyField="jobRequisitionId" [selectedKey]="sel()?.job?.jobRequisitionId"
               [total]="total()" [page]="page()" (pageChange)="load($event)" (select)="open($event)" empty="No jobs." />
    @if (sel(); as s) {
      <section class="card">
        <div class="card-head"><h2>{{ s.job.jobCode }} — {{ s.job.title }}</h2><span [class]="badge(s.job.status)">{{ label(s.job.status) }}</span></div>
        <app-details [data]="s.job" [fields]="detail" />
        <h3>Skills</h3>
        <app-table [rows]="s.skills" [columns]="skillCols" [filter]="false" empty="No skills." />
        <h3>Postings</h3>
        <app-table [rows]="s.postings" [columns]="postCols" [filter]="false" empty="Not published." />
        <h3>Approvals</h3>
        <app-table [rows]="s.approvals" [columns]="apprCols" [filter]="false" empty="No decision yet." />
      </section>
    }
  `
})
export class JobsPage implements OnInit {
  private readonly api = inject(Api);
  private readonly auth = inject(Auth);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  private readonly lookups = inject(Lookups);
  readonly statuses = ['PendingApproval', 'Approved', 'Open', 'OnHold', 'Filled', 'Closed', 'Expired', 'Draft'];
  q = ''; status = '';
  readonly rows = signal<any[]>([]);
  readonly total = signal(0);
  readonly page = signal(1);
  readonly sel = signal<any>(null);
  readonly hr = computed(() => this.auth.has('HRManager', 'Administrator'));
  readonly cols: Column[] = [
    { key: 'jobCode', label: 'Code' }, { key: 'title', label: 'Title' }, { key: 'department', label: 'Department' }, { key: 'location', label: 'Location' },
    { key: 'openings', label: 'Openings', type: 'number' }, { key: 'status', label: 'Status', type: 'status' }, { key: 'ownerRecruiter', label: 'Recruiter' },
    { key: 'applications', label: 'Applications', type: 'number' }, { key: 'closesBy', label: 'Closes by', type: 'date' }
  ];
  readonly actions: RowAction[] = [
    { label: 'Approve', kind: 'primary', show: r => this.hr() && r.status === 'PendingApproval', run: r => this.decide(r, true) },
    { label: 'Reject', kind: 'danger', show: r => this.hr() && r.status === 'PendingApproval', run: r => this.decide(r, false) },
    { label: 'Publish', kind: 'primary', show: r => r.status === 'Approved', run: r => this.publish(r) },
    { label: 'Close', kind: 'danger', show: r => ['Approved', 'Open', 'OnHold'].includes(r.status), run: r => this.close(r) }
  ];
  readonly detail: DetailField[] = [
    { key: 'department', label: 'Department' }, { key: 'employmentType', label: 'Employment type' }, { key: 'openings', label: 'Openings', type: 'number' },
    { key: 'ownerRecruiter', label: 'Recruiter' }, { key: 'minExperienceYears', label: 'Min. experience (years)', type: 'number' },
    { key: 'salary', label: 'Salary range', value: d => d?.salaryMin || d?.salaryMax ? `${formatValue(d.salaryMin, 'money')} – ${formatValue(d.salaryMax, 'money')}` : null },
    { key: 'openedAt', label: 'Opened', type: 'datetime' }, { key: 'closesBy', label: 'Closes by', type: 'date' },
    { key: 'summary', label: 'Summary', wide: true }, { key: 'responsibilities', label: 'Responsibilities', wide: true }, { key: 'qualifications', label: 'Qualifications', wide: true }
  ];
  readonly skillCols: Column[] = [{ key: 'skillName', label: 'Skill' }, { key: 'isRequired', label: 'Required', type: 'bool' }, { key: 'minYears', label: 'Min. years', type: 'number' }];
  readonly postCols: Column[] = [{ key: 'jobPostingId', label: 'Posting' }, { key: 'status', label: 'Status', type: 'status' }, { key: 'postedAt', label: 'Posted', type: 'datetime' }, { key: 'closesAt', label: 'Closes', type: 'datetime' }];
  readonly apprCols: Column[] = [{ key: 'decision', label: 'Decision', type: 'status' }, { key: 'approver', label: 'By' }, { key: 'decidedAt', label: 'When', type: 'datetime' }, { key: 'comments', label: 'Comments' }];

  ngOnInit(): void { void this.load(1); }
  label(s: string): string { return s === 'PendingApproval' ? 'Pending approval' : s === 'OnHold' ? 'On hold' : s; }
  async load(page: number): Promise<void> {
    try { const r = await this.api.get<any>('/jobs', { q: this.q.trim(), status: this.status, page }); this.rows.set(r.items); this.total.set(r.total); this.page.set(page); }
    catch (e) { this.toasts.error(e); }
  }
  async open(r: any): Promise<void> { try { this.sel.set(await this.api.get(`/jobs/${r.jobRequisitionId}`)); } catch (e) { this.toasts.error(e); } }
  async create(): Promise<void> {
    const out: any = await openJobDialog(this.api, this.dlg, this.lookups, this.auth);
    if (out) { this.toasts.ok(`Job ${out.jobCode} created and sent for approval.`); await this.load(1); }
  }
  async decide(r: any, approve: boolean): Promise<void> {
    const ok = await this.dlg.open({
      title: `${approve ? 'Approve' : 'Reject'} ${r.jobCode}`, submitLabel: approve ? 'Approve' : 'Reject', danger: !approve,
      message: 'You cannot approve a job you created yourself.',
      fields: [{ key: 'comments', label: approve ? 'Comments (optional)' : 'Reason', type: 'textarea', required: !approve, maxLength: 500 }],
      submit: v => this.api.post(`/jobs/${r.jobRequisitionId}/${approve ? 'approve' : 'reject'}`, v)
    });
    if (ok) await this.after(r, approve ? 'Job approved; it can now be published.' : 'Job rejected.');
  }
  async publish(r: any): Promise<void> {
    const ok = await this.dlg.open({
      title: `Publish ${r.jobCode}`, submitLabel: 'Publish',
      message: 'Publishing makes the job visible to candidates.',
      fields: [
        { key: 'closesAt', label: 'Posting closes (optional, your local time)', type: 'datetime' },
        { key: 'sourceId', label: 'Channel (optional)', type: 'select', options: () => this.lookups.sources() }
      ],
      submit: v => this.api.post(`/jobs/${r.jobRequisitionId}/publish`, v)
    });
    if (ok) await this.after(r, 'Job published.');
  }
  async close(r: any): Promise<void> {
    const ok = await this.dlg.open({
      title: `Close ${r.jobCode}`, danger: true, submitLabel: 'Close job',
      fields: [{ key: 'reason', label: 'Reason', type: 'textarea', maxLength: 300 }],
      submit: v => this.api.post(`/jobs/${r.jobRequisitionId}/close`, v)
    });
    if (ok) await this.after(r, 'Job closed.');
  }
  private async after(r: any, msg: string): Promise<void> { this.toasts.ok(msg); await this.load(this.page()); await this.open(r); }
  badge(v: unknown): string { return statusClass(v); }
}

@Component({
  selector: 'app-applications',
  imports: [DataTable, DetailList, FormsModule, StatusTextPipe],
  template: `
    <div class="page-head">
      <h1>Applications</h1>
      <form class="tools wrap" (ngSubmit)="load(1)">
        <input type="search" name="q" [(ngModel)]="q" placeholder="Candidate name or e-mail" aria-label="Search" />
        <select [(ngModel)]="jobId" name="job" aria-label="Job">
          <option [ngValue]="null">All jobs</option>
          @for (j of jobs(); track j.value) { <option [ngValue]="j.value">{{ j.label }}</option> }
        </select>
        <select [(ngModel)]="status" name="st" aria-label="Status">
          <option value="">All statuses</option>
          @for (s of statuses; track s) { <option [value]="s">{{ s | statusText }}</option> }
        </select>
        <button class="btn" type="submit">Show</button>
      </form>
    </div>
    <app-table [rows]="rows()" [columns]="cols" [actions]="actions" [selectable]="true" keyField="applicationId" [selectedKey]="sel()?.application?.applicationId"
               [total]="total()" [page]="page()" (pageChange)="load($event)" (select)="open($event)" empty="No applications." />
    @if (sel(); as s) {
      <section class="card">
        <div class="card-head"><h2>{{ s.application.candidateName }} — {{ s.application.title }}</h2><span [class]="badge(s.application.status)">{{ s.application.status | statusText }}</span></div>
        <app-details [data]="s.application" [fields]="detail" />
        <h3>Status history</h3>
        <app-table [rows]="s.history" [columns]="histCols" [filter]="false" />
        <h3>Interviews</h3>
        <app-table [rows]="s.interviews" [columns]="ivCols" [filter]="false" empty="No interviews." />
        <h3>Offers</h3>
        <app-table [rows]="s.offers" [columns]="offerCols" [filter]="false" empty="No offers." />
      </section>
    }
  `
})
export class ApplicationsPage implements OnInit {
  private readonly api = inject(Api);
  private readonly auth = inject(Auth);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  private readonly lookups = inject(Lookups);
  private readonly act = inject(Actions);
  readonly statuses = ['Applied', 'Screening', 'Shortlisted', 'Interview', 'Selected', 'OfferStage', 'Hired', 'Rejected', 'Withdrawn'];
  q = ''; status = ''; jobId: number | null = null;
  readonly rows = signal<any[]>([]);
  readonly total = signal(0);
  readonly page = signal(1);
  readonly sel = signal<any>(null);
  readonly jobs = signal<Option[]>([]);
  readonly recruiter = computed(() => this.auth.has('Recruiter', 'Administrator'));
  readonly cols: Column[] = [
    { key: 'candidateName', label: 'Candidate' }, { key: 'email', label: 'E-mail' }, { key: 'totalExperienceYears', label: 'Exp. (y)', type: 'number' },
    { key: 'jobCode', label: 'Job' }, { key: 'title', label: 'Title' }, { key: 'status', label: 'Status', type: 'status' },
    { key: 'appliedAt', label: 'Applied', type: 'datetime' }, { key: 'ageDays', label: 'Age', type: 'days' }
  ];
  readonly actions: RowAction[] = [
    { label: 'Shortlist', kind: 'primary', show: r => this.recruiter() && ['Applied', 'Screening'].includes(r.status), run: r => this.shortlist(r) },
    { label: 'Change status', show: r => this.recruiter() && !!NEXT_STATUS[r.status], run: r => this.move(r) },
    { label: 'Schedule interview', show: r => ['Shortlisted', 'Interview'].includes(r.status), run: r => this.interview(r) },
    { label: 'Create offer', kind: 'primary', show: r => r.status === 'Selected', run: r => this.offer(r) }
  ];
  readonly detail: DetailField[] = [
    { key: 'email', label: 'E-mail' }, { key: 'jobCode', label: 'Job' }, { key: 'department', label: 'Department' },
    { key: 'appliedAt', label: 'Applied', type: 'datetime' }, { key: 'coverNote', label: 'Cover note', wide: true }
  ];
  readonly histCols: Column[] = [{ key: 'changedAt', label: 'When', type: 'datetime' }, { key: 'oldStatus', label: 'From' }, { key: 'newStatus', label: 'To', type: 'status' }, { key: 'reason', label: 'Reason' }, { key: 'changedBy', label: 'By' }];
  readonly ivCols: Column[] = [{ key: 'roundNo', label: 'Round', type: 'number' }, { key: 'interviewType', label: 'Type' }, { key: 'startsAt', label: 'Starts', type: 'datetime' }, { key: 'mode', label: 'Mode' }, { key: 'status', label: 'Status', type: 'status' }];
  readonly offerCols: Column[] = [{ key: 'offerNo', label: 'Offer' }, { key: 'designation', label: 'Designation' }, { key: 'offeredSalary', label: 'Salary', type: 'money' }, { key: 'startDate', label: 'Start', type: 'date' }, { key: 'expiresAt', label: 'Expires', type: 'datetime' }, { key: 'status', label: 'Status', type: 'status' }];

  async ngOnInit(): Promise<void> {
    await this.load(1);
    try {
      const r = await this.api.get<any>('/jobs', { pageSize: 200 });
      this.jobs.set((r.items as any[]).map(j => ({ value: j.jobRequisitionId, label: `${j.jobCode} – ${j.title}` })));
    } catch (e) { this.toasts.error(e); }
  }
  async load(page: number): Promise<void> {
    try { const r = await this.api.get<any>('/applications', { q: this.q.trim(), status: this.status, jobId: this.jobId, page }); this.rows.set(r.items); this.total.set(r.total); this.page.set(page); }
    catch (e) { this.toasts.error(e); }
  }
  async open(r: any): Promise<void> { try { this.sel.set(await this.api.get(`/applications/${r.applicationId}`)); } catch (e) { this.toasts.error(e); } }

  async shortlist(r: any): Promise<void> {
    const ok = await this.dlg.open({
      title: `Shortlist ${r.candidateName}`, submitLabel: 'Shortlist',
      fields: [{ key: 'reason', label: 'Note (optional)', type: 'textarea', maxLength: 500 }],
      submit: v => this.api.post(`/applications/${r.applicationId}/shortlist`, v)
    });
    if (ok) await this.after(r, 'Candidate shortlisted.');
  }
  async move(r: any): Promise<void> {
    const ok = await this.dlg.open({
      title: `Change status of ${r.candidateName}`, submitLabel: 'Change status',
      message: `Current status: ${r.status}. Only valid next steps are offered; a reason is required when rejecting.`,
      fields: [
        { key: 'newStatus', label: 'New status', type: 'select', required: true, options: opts(NEXT_STATUS[r.status] ?? []) },
        { key: 'reason', label: 'Reason', type: 'textarea', maxLength: 500 }
      ],
      submit: v => this.api.post(`/applications/${r.applicationId}/status`, { ...v, rowVer: r.rowVer })
    });
    if (ok) await this.after(r, 'Status changed; the candidate has been notified.');
  }
  async interview(r: any): Promise<void> {
    try {
      const d: any = await this.api.get(`/applications/${r.applicationId}`);
      const used = (d.interviews as any[]).filter(i => i.status !== 'Cancelled').map(i => Number(i.roundNo));
      const next = used.length ? Math.max(...used) + 1 : 1;
      if (await this.act.scheduleInterview({ jobApplicationId: r.applicationId }, () => this.lookups.staff(), next === 1 ? 'Technical' : 'HR', next))
        await this.after(r, 'Interview scheduled; the candidate has been invited.');
    } catch (e) { this.toasts.error(e); }
  }
  async offer(r: any): Promise<void> {
    const out: any = await this.act.createOffer({ applicationId: r.applicationId, title: r.title, candidateName: r.candidateName });
    if (out) await this.after(r, `Offer ${out.offerNo} created and waiting for HR approval.`);
  }
  private async after(r: any, msg: string): Promise<void> { this.toasts.ok(msg); await this.load(this.page()); await this.open(r); }
  badge(v: unknown): string { return statusClass(v); }
}

@Component({
  selector: 'app-offers',
  imports: [DataTable, FormsModule, StatusTextPipe],
  template: `
    <div class="page-head">
      <h1>Offers</h1>
      <div class="tools">
        <select [(ngModel)]="status" name="st" (change)="load()" aria-label="Status">
          <option value="">All statuses</option>
          @for (s of statuses; track s) { <option [value]="s">{{ s | statusText }}</option> }
        </select>
      </div>
    </div>
    <p class="muted">Offers are created from a Selected application (Applications page). An HR Manager who did not create an offer approves it; then it can be sent.</p>
    <app-table [rows]="rows()" [columns]="cols" [actions]="actions" empty="No offers." />
  `
})
export class OffersPage implements OnInit {
  private readonly api = inject(Api);
  private readonly auth = inject(Auth);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  readonly statuses = ['PendingApproval', 'Approved', 'Rejected', 'Sent', 'Accepted', 'Declined', 'Expired'];
  status = '';
  readonly rows = signal<any[]>([]);
  readonly hr = computed(() => this.auth.has('HRManager', 'Administrator'));
  readonly cols: Column[] = [
    { key: 'offerNo', label: 'Offer' }, { key: 'candidateName', label: 'Candidate' }, { key: 'designation', label: 'Designation' },
    { key: 'offeredSalary', label: 'Salary', type: 'money' }, { key: 'startDate', label: 'Start', type: 'date' }, { key: 'expiresAt', label: 'Expires', type: 'datetime' },
    { key: 'status', label: 'Status', type: 'status' }, { key: 'createdBy', label: 'Created by' }, { key: 'sentAt', label: 'Sent', type: 'datetime' }, { key: 'respondedAt', label: 'Answered', type: 'datetime' }
  ];
  private readonly notMine = (r: any) => r.createdByUserId !== this.auth.user()?.userId;
  private readonly live = (r: any) => new Date(r.expiresAt).getTime() > Date.now();
  readonly actions: RowAction[] = [
    { label: 'Approve', kind: 'primary', show: r => this.hr() && r.status === 'PendingApproval' && this.notMine(r), run: r => this.decide(r, true) },
    { label: 'Reject', kind: 'danger', show: r => this.hr() && r.status === 'PendingApproval' && this.notMine(r), run: r => this.decide(r, false) },
    { label: 'Send to candidate', kind: 'primary', show: r => r.status === 'Approved' && this.live(r), run: r => this.send(r) }
  ];
  ngOnInit(): void { void this.load(); }
  async load(): Promise<void> { try { this.rows.set(await this.api.get('/offers', { status: this.status })); } catch (e) { this.toasts.error(e); } }
  async decide(r: any, approve: boolean): Promise<void> {
    const ok = await this.dlg.open({
      title: `${approve ? 'Approve' : 'Reject'} offer ${r.offerNo}`, submitLabel: approve ? 'Approve' : 'Reject', danger: !approve,
      message: `${r.candidateName}: ${r.designation}, ${formatValue(r.offeredSalary, 'money')} per year.`,
      fields: [{ key: 'comments', label: approve ? 'Comments (optional)' : 'Reason', type: 'textarea', required: !approve, maxLength: 500 }],
      submit: v => this.api.post(`/offers/${r.offerId}/${approve ? 'approve' : 'reject'}`, v)
    });
    if (ok) { this.toasts.ok(approve ? 'Offer approved.' : 'Offer rejected.'); await this.load(); }
  }
  async send(r: any): Promise<void> {
    if (await this.dlg.confirm(`Send offer ${r.offerNo}`, `Send this offer to ${r.candidateName}? They can accept or decline it until ${formatValue(r.expiresAt, 'datetime')}.`, () => this.api.post(`/offers/${r.offerId}/send`), 'Send')) {
      this.toasts.ok('Offer sent to the candidate.'); await this.load();
    }
  }
}
