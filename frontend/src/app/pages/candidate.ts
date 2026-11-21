import { Component, OnInit, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api } from '../core/api';
import { Auth } from '../core/auth';
import { formatValue, statusClass, StatusTextPipe } from '../core/format';
import { Dialogs, Toasts } from '../core/ui';
import { Lookups } from '../shared/lookups';
import { Column, DataTable, RowAction } from '../shared/table';
import { DetailField, DetailList } from '../shared/widgets';
import { CANDIDATE_DOC_TYPES, DocumentsPanel } from '../shared/documents';

const salary = (r: any) => r.salaryMin || r.salaryMax ? `${formatValue(r.salaryMin, 'money')} – ${formatValue(r.salaryMax, 'money')}` : null;

@Component({
  selector: 'app-jobs-browse',
  imports: [DataTable, DetailList, FormsModule],
  template: `
    <div class="page-head">
      <h1>Find jobs</h1>
      <form class="tools" (ngSubmit)="search(1)">
        <input type="search" name="q" placeholder="Title, skill or keyword" [(ngModel)]="q" aria-label="Search jobs" />
        <button class="btn" type="submit">Search</button>
      </form>
    </div>
    <app-table [rows]="rows()" [columns]="cols" [selectable]="true" keyField="jobPostingId" [selectedKey]="sel()?.job?.jobPostingId"
               [total]="total()" [page]="page()" [pageSize]="20" (pageChange)="search($event)" (select)="open($event)" empty="No open jobs match your search." />
    @if (sel(); as s) {
      <section class="card">
        <div class="card-head">
          <h2>{{ s.job.title }} <small class="muted">{{ s.job.jobCode }}</small></h2>
          @if (s.job.alreadyApplied) { <span class="badge s-applied">You have applied</span> }
          @else { <button class="btn primary" type="button" (click)="apply(s.job)">Apply</button> }
        </div>
        <app-details [data]="s.job" [fields]="detail" />
        <h3>Skills</h3>
        <app-table [rows]="s.skills" [columns]="skillCols" [filter]="false" empty="No skills listed." />
      </section>
    }
  `
})
export class JobsBrowsePage implements OnInit {
  private readonly api = inject(Api);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  private readonly lookups = inject(Lookups);
  q = '';
  readonly rows = signal<any[]>([]);
  readonly total = signal(0);
  readonly page = signal(1);
  readonly sel = signal<any>(null);
  readonly cols: Column[] = [
    { key: 'title', label: 'Job' }, { key: 'department', label: 'Department' }, { key: 'location', label: 'Location' },
    { key: 'employmentType', label: 'Type' }, { key: 'minExperienceYears', label: 'Min. experience (y)', type: 'number' },
    { key: 'salary', label: 'Salary range', value: salary }, { key: 'closesAt', label: 'Closes', type: 'datetime' },
    { key: 'alreadyApplied', label: 'Applied', type: 'bool' }
  ];
  readonly detail: DetailField[] = [
    { key: 'department', label: 'Department' }, { key: 'location', label: 'Location' }, { key: 'employmentType', label: 'Employment type' },
    { key: 'openings', label: 'Openings', type: 'number' }, { key: 'minExperienceYears', label: 'Minimum experience (years)', type: 'number' },
    { key: 'salary', label: 'Salary range', value: salary }, { key: 'postedAt', label: 'Posted', type: 'datetime' }, { key: 'closesAt', label: 'Closes', type: 'datetime' },
    { key: 'summary', label: 'Summary', wide: true }, { key: 'responsibilities', label: 'Responsibilities', wide: true }, { key: 'qualifications', label: 'Qualifications', wide: true }
  ];
  readonly skillCols: Column[] = [{ key: 'skillName', label: 'Skill' }, { key: 'isRequired', label: 'Required', type: 'bool' }, { key: 'minYears', label: 'Min. years', type: 'number' }];

  ngOnInit(): void { void this.search(1); }

  async search(page: number): Promise<void> {
    try {
      const r = await this.api.get<any>('/public/jobs', { q: this.q.trim(), page, pageSize: 20 });
      this.rows.set(r.items); this.total.set(r.total); this.page.set(page);
    } catch (e) { this.toasts.error(e); }
  }
  async open(row: any): Promise<void> {
    try { this.sel.set(await this.api.get(`/public/jobs/${row.jobPostingId}`)); } catch (e) { this.toasts.error(e); }
  }
  async apply(job: any): Promise<void> {
    const r = await this.dlg.open({
      title: `Apply: ${job.title}`, submitLabel: 'Submit application',
      fields: [
        { key: 'coverNote', label: 'Cover note', type: 'textarea', maxLength: 1000, placeholder: 'Why you are a good fit (optional)' },
        { key: 'sourceId', label: 'How did you hear about this job?', type: 'select', options: () => this.lookups.sources() }
      ],
      submit: v => this.api.post('/applications', { jobPostingId: job.jobPostingId, ...v })
    });
    if (r) { this.toasts.ok('Application submitted.'); await this.search(this.page()); await this.open(job); }
  }
}

@Component({
  selector: 'app-my-applications',
  imports: [DataTable, DetailList, StatusTextPipe],
  template: `
    <h1>My applications</h1>
    <app-table [rows]="rows()" [columns]="cols" [actions]="actions" [selectable]="true" keyField="applicationId" [selectedKey]="sel()?.application?.applicationId" (select)="open($event)" empty="You have not applied to any jobs yet." />
    @if (sel(); as s) {
      <section class="card">
        <div class="card-head"><h2>{{ s.application.title }} <small class="muted">{{ s.application.jobCode }}</small></h2><span [class]="badge(s.application.status)">{{ s.application.status | statusText }}</span></div>
        <app-details [data]="s.application" [fields]="detail" />
        <h3>Status history</h3>
        <ol class="timeline">
          @for (h of s.history; track $index) { <li><strong>{{ h.newStatus }}</strong> <span class="muted">{{ when(h.changedAt) }}</span>@if (h.reason) { — {{ h.reason }} }</li> }
        </ol>
        <h3>Interviews</h3>
        <app-table [rows]="s.interviews" [columns]="ivCols" [filter]="false" empty="No interviews yet." />
        <h3>Offers</h3>
        <app-table [rows]="s.offers" [columns]="offerCols" [filter]="false" empty="No offers yet." />
      </section>
    }
    <section class="card">
      <h2>Put forward to client companies</h2>
      <p class="muted">Contract opportunities where a recruiter submitted your profile to a customer.</p>
      <app-table [rows]="subs()" [columns]="subCols" [filter]="false" empty="None." />
    </section>
  `
})
export class MyApplicationsPage implements OnInit {
  private readonly api = inject(Api);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  readonly rows = signal<any[]>([]);
  readonly subs = signal<any[]>([]);
  readonly sel = signal<any>(null);
  readonly cols: Column[] = [
    { key: 'title', label: 'Job' }, { key: 'department', label: 'Department' }, { key: 'status', label: 'Status', type: 'status' },
    { key: 'appliedAt', label: 'Applied', type: 'datetime' }, { key: 'nextInterviewAt', label: 'Next interview', type: 'datetime' }, { key: 'offerStatus', label: 'Offer', type: 'status' }
  ];
  readonly actions: RowAction[] = [{ label: 'Withdraw', kind: 'danger', show: r => !['Hired', 'Rejected', 'Withdrawn'].includes(r.status), run: r => this.withdraw(r) }];
  readonly detail: DetailField[] = [{ key: 'department', label: 'Department' }, { key: 'appliedAt', label: 'Applied', type: 'datetime' }, { key: 'coverNote', label: 'Cover note', wide: true }];
  readonly ivCols: Column[] = [{ key: 'roundNo', label: 'Round', type: 'number' }, { key: 'interviewType', label: 'Type' }, { key: 'startsAt', label: 'Starts', type: 'datetime' }, { key: 'mode', label: 'Mode' }, { key: 'locationOrLink', label: 'Where' }, { key: 'status', label: 'Status', type: 'status' }];
  readonly offerCols: Column[] = [{ key: 'offerNo', label: 'Offer' }, { key: 'designation', label: 'Designation' }, { key: 'offeredSalary', label: 'Salary', type: 'money' }, { key: 'startDate', label: 'Start', type: 'date' }, { key: 'status', label: 'Status', type: 'status' }];
  readonly subCols: Column[] = [{ key: 'customerName', label: 'Company' }, { key: 'roleTitle', label: 'Role' }, { key: 'status', label: 'Status', type: 'status' }, { key: 'submittedAt', label: 'Submitted', type: 'datetime' }];

  ngOnInit(): void { void this.load(); }
  async load(): Promise<void> {
    try {
      const [a, s] = await Promise.all([this.api.get<any[]>('/applications/mine'), this.api.get<any[]>('/applications/mine/submissions')]);
      this.rows.set(a); this.subs.set(s);
    } catch (e) { this.toasts.error(e); }
  }
  async open(r: any): Promise<void> { try { this.sel.set(await this.api.get(`/applications/${r.applicationId}`)); } catch (e) { this.toasts.error(e); } }
  async withdraw(r: any): Promise<void> {
    const ok = await this.dlg.open({
      title: `Withdraw application: ${r.title}`, danger: true, submitLabel: 'Withdraw',
      message: 'Withdrawing cannot be undone. You may apply again while the job is open.',
      fields: [{ key: 'reason', label: 'Reason (optional)', type: 'textarea', maxLength: 500 }],
      submit: v => this.api.post(`/applications/${r.applicationId}/withdraw`, v)
    });
    if (ok) { this.toasts.ok('Application withdrawn.'); this.sel.set(null); await this.load(); }
  }
  when(v: string): string { return formatValue(v, 'datetime'); }
  badge(v: unknown): string { return statusClass(v); }
}

@Component({
  selector: 'app-my-offers',
  imports: [DataTable],
  template: `
    <h1>My offers</h1>
    <p class="muted">Accepting an offer creates your employee record and starts onboarding. An offer can be answered only once and only before it expires.</p>
    <app-table [rows]="rows()" [columns]="cols" [actions]="actions" empty="You have no offers." />
  `
})
export class MyOffersPage implements OnInit {
  private readonly api = inject(Api);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  private readonly auth = inject(Auth);
  readonly rows = signal<any[]>([]);
  readonly cols: Column[] = [
    { key: 'offerNo', label: 'Offer' }, { key: 'jobTitle', label: 'Job' }, { key: 'designation', label: 'Designation' },
    { key: 'offeredSalary', label: 'Annual salary', type: 'money' }, { key: 'startDate', label: 'Start date', type: 'date' },
    { key: 'expiresAt', label: 'Expires', type: 'datetime' }, { key: 'status', label: 'Status', type: 'status' }
  ];
  private readonly open = (r: any) => r.status === 'Sent' && new Date(r.expiresAt).getTime() > Date.now();
  readonly actions: RowAction[] = [
    { label: 'Accept', kind: 'primary', show: this.open, run: r => this.respond(r, true) },
    { label: 'Decline', kind: 'danger', show: this.open, run: r => this.respond(r, false) }
  ];

  ngOnInit(): void { void this.load(); }
  async load(): Promise<void> { try { this.rows.set(await this.api.get('/offers/mine')); } catch (e) { this.toasts.error(e); } }
  async respond(r: any, accept: boolean): Promise<void> {
    const res: any = await this.dlg.open({
      title: `${accept ? 'Accept' : 'Decline'} offer ${r.offerNo}`, submitLabel: accept ? 'Accept offer' : 'Decline offer', danger: !accept,
      message: accept ? `You are accepting ${r.designation} at ${formatValue(r.offeredSalary, 'money')} per year, starting ${formatValue(r.startDate, 'date')}. This cannot be undone.` : 'Declining cannot be undone.',
      fields: [{ key: 'note', label: 'Note (optional)', type: 'textarea', maxLength: 500 }],
      submit: v => this.api.post(`/offers/${r.offerId}/${accept ? 'accept' : 'decline'}`, v)
    });
    if (res) {
      this.toasts.ok(accept ? 'Offer accepted. HR will contact you about onboarding.' : 'Offer declined.');
      await this.load(); await this.auth.refresh();
    }
  }
}

@Component({
  selector: 'app-candidate-profile',
  imports: [DataTable, DetailList, DocumentsPanel],
  template: `
    @if (data(); as d) {
      <div class="page-head">
        <h1>{{ d.profile.firstName }} {{ d.profile.lastName }}</h1>
        <button class="btn primary" type="button" (click)="edit(d.profile)">Edit profile</button>
      </div>
      <section class="card"><app-details [data]="d.profile" [fields]="fields" /></section>
      <section class="card">
        <div class="card-head"><h2>Skills</h2><button class="btn" type="button" (click)="addSkill()">Add or update a skill</button></div>
        <app-table [rows]="d.skills" [columns]="skillCols" [actions]="skillActions" [filter]="false" empty="No skills yet." />
      </section>
      <section class="card">
        <h2>Education</h2>
        <app-table [rows]="d.education" [columns]="eduCols" [filter]="false" empty="None recorded." />
        <h2>Experience</h2>
        <app-table [rows]="d.experience" [columns]="expCols" [filter]="false" empty="None recorded." />
        <p class="muted">Education and work history are maintained by your recruiter for now; self-service editing of these sections is planned (KI-019).</p>
      </section>
      <section class="card">
        <app-documents ownerType="Candidate" [ownerId]="d.profile.candidateId" title="My documents" [docTypes]="docTypes" [canUpload]="true" [allowPrimary]="true"
                       empty="Upload your résumé so recruiters and (once you are shortlisted) client companies can read it." />
      </section>
    }
  `
})
export class CandidateProfilePage implements OnInit {
  readonly docTypes = CANDIDATE_DOC_TYPES;
  private readonly api = inject(Api);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  readonly data = signal<any>(null);
  readonly fields: DetailField[] = [
    { key: 'email', label: 'E-mail' }, { key: 'phone', label: 'Phone' }, { key: 'currentTitle', label: 'Current title' }, { key: 'currentEmployer', label: 'Current employer' },
    { key: 'totalExperienceYears', label: 'Experience (years)', type: 'number' }, { key: 'expectedSalary', label: 'Expected salary', type: 'money' },
    { key: 'noticePeriodDays', label: 'Notice period', type: 'days' }, { key: 'status', label: 'Status', type: 'status' }, { key: 'summary', label: 'Summary', wide: true }
  ];
  readonly skillCols: Column[] = [{ key: 'skillName', label: 'Skill' }, { key: 'yearsExperience', label: 'Years', type: 'number' }, { key: 'proficiencyLevel', label: 'Proficiency (1–5)', type: 'number' }];
  readonly skillActions: RowAction[] = [{ label: 'Remove', kind: 'danger', run: r => this.removeSkill(r) }];
  readonly eduCols: Column[] = [{ key: 'institution', label: 'Institution' }, { key: 'degree', label: 'Degree' }, { key: 'fieldOfStudy', label: 'Field' }, { key: 'startYear', label: 'From' }, { key: 'endYear', label: 'To' }, { key: 'grade', label: 'Grade' }];
  readonly expCols: Column[] = [{ key: 'employer', label: 'Employer' }, { key: 'jobTitle', label: 'Title' }, { key: 'startDate', label: 'From', type: 'date' }, { key: 'endDate', label: 'To', type: 'date' }, { key: 'isCurrent', label: 'Current', type: 'bool' }, { key: 'description', label: 'Description' }];

  ngOnInit(): void { void this.load(); }
  async load(): Promise<void> { try { this.data.set(await this.api.get('/candidates/me')); } catch (e) { this.toasts.error(e); } }

  async edit(p: any): Promise<void> {
    const r = await this.dlg.open({
      title: 'Edit profile', wide: true,
      fields: [
        { key: 'firstName', label: 'First name', value: p.firstName, required: true, maxLength: 100 },
        { key: 'lastName', label: 'Last name', value: p.lastName, required: true, maxLength: 100 },
        { key: 'phone', label: 'Phone', value: p.phone, maxLength: 30 },
        { key: 'currentTitle', label: 'Current title', value: p.currentTitle, maxLength: 150 },
        { key: 'currentEmployer', label: 'Current employer', value: p.currentEmployer, maxLength: 150 },
        { key: 'totalExperienceYears', label: 'Total experience (years)', type: 'number', min: 0, max: 60, step: 0.5, value: p.totalExperienceYears, required: true },
        { key: 'expectedSalary', label: 'Expected annual salary (INR)', type: 'number', min: 0, value: p.expectedSalary },
        { key: 'noticePeriodDays', label: 'Notice period (days)', type: 'number', min: 0, max: 365, value: p.noticePeriodDays },
        { key: 'summary', label: 'Summary', type: 'textarea', maxLength: 1000, value: p.summary }
      ],
      submit: v => this.api.put('/candidates/me', { ...v, rowVer: p.rowVer })
    });
    if (r) { this.toasts.ok('Profile saved.'); await this.load(); }
  }
  async addSkill(): Promise<void> {
    const r = await this.dlg.open({
      title: 'Add or update a skill',
      fields: [
        { key: 'skillName', label: 'Skill', required: true, maxLength: 100 },
        { key: 'yearsExperience', label: 'Years of experience', type: 'number', min: 0, max: 60, step: 0.5, value: 1, required: true },
        { key: 'proficiencyLevel', label: 'Proficiency (1 = basic, 5 = expert)', type: 'number', min: 1, max: 5, value: 3, required: true }
      ],
      submit: v => this.api.post('/candidates/me/skills', v)
    });
    if (r) { this.toasts.ok('Skill saved.'); await this.load(); }
  }
  async removeSkill(s: any): Promise<void> {
    const r = await this.dlg.confirm('Remove skill', `Remove "${s.skillName}" from your profile?`, () => this.api.delete(`/candidates/me/skills/${encodeURIComponent(s.skillName)}`), 'Remove', true);
    if (r) { this.toasts.ok('Skill removed.'); await this.load(); }
  }
}
