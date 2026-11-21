import { Component, OnInit, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api } from '../core/api';
import { statusClass, StatusTextPipe } from '../core/format';
import { Dialogs, Toasts } from '../core/ui';
import { Lookups, opts } from '../shared/lookups';
import { Column, DataTable, RowAction } from '../shared/table';
import { DetailField, DetailList } from '../shared/widgets';
import { CANDIDATE_DOC_TYPES, DocumentsPanel } from '../shared/documents';

/** The shared candidate master: one record per person, used by internal recruitment and external staffing. */
@Component({
  selector: 'app-candidates',
  imports: [DataTable, DetailList, FormsModule, DocumentsPanel, StatusTextPipe],
  template: `
    <div class="page-head">
      <h1>Candidates</h1>
      <button class="btn primary" type="button" (click)="create()">Add candidate</button>
    </div>
    <form class="filters" (ngSubmit)="load(1)">
      <input type="search" name="q" [(ngModel)]="f.q" placeholder="Name, e-mail or title" aria-label="Search" />
      <input type="text" name="skills" [(ngModel)]="f.skills" placeholder="Skills (comma-separated, all required)" aria-label="Skills" />
      <input type="number" name="min" [(ngModel)]="f.minExp" min="0" max="60" placeholder="Min. years" aria-label="Minimum experience" />
      <input type="number" name="max" [(ngModel)]="f.maxExp" min="0" max="60" placeholder="Max. years" aria-label="Maximum experience" />
      <select name="st" [(ngModel)]="f.status" aria-label="Status"><option value="">Any status</option><option>Active</option><option>Inactive</option><option>Blacklisted</option></select>
      <button class="btn" type="submit">Search</button>
    </form>
    <app-table [rows]="rows()" [columns]="cols" [selectable]="true" keyField="candidateId" [selectedKey]="sel()?.profile?.candidateId"
               [total]="total()" [page]="page()" (pageChange)="load($event)" (select)="open($event)" empty="No candidates match." />
    @if (sel(); as s) {
      <section class="card">
        <div class="card-head">
          <h2>{{ s.profile.firstName }} {{ s.profile.lastName }}</h2>
          <div class="tools"><span [class]="badge(s.profile.status)">{{ s.profile.status | statusText }}</span><button class="btn" type="button" (click)="edit(s.profile)">Edit</button></div>
        </div>
        <app-details [data]="s.profile" [fields]="detail" />
        <div class="card-head"><h3>Skills</h3><button class="btn sm" type="button" (click)="addSkill(s.profile)">Add or update skill</button></div>
        <app-table [rows]="s.skills" [columns]="skillCols" [actions]="skillActions" [filter]="false" empty="No skills recorded." />
        <h3>Education</h3>
        <app-table [rows]="s.education" [columns]="eduCols" [filter]="false" empty="None recorded." />
        <h3>Experience</h3>
        <app-table [rows]="s.experience" [columns]="expCols" [filter]="false" empty="None recorded." />
        <app-documents ownerType="Candidate" [ownerId]="s.profile.candidateId" title="Documents" [docTypes]="docTypes" [canUpload]="true" [allowPrimary]="true" />
      </section>
    }
  `
})
export class CandidatesPage implements OnInit {
  readonly docTypes = CANDIDATE_DOC_TYPES;
  private readonly api = inject(Api);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  private readonly lookups = inject(Lookups);
  f = { q: '', skills: '', minExp: null as number | null, maxExp: null as number | null, status: '' };
  readonly rows = signal<any[]>([]);
  readonly total = signal(0);
  readonly page = signal(1);
  readonly sel = signal<any>(null);
  readonly cols: Column[] = [
    { key: 'name', label: 'Name', value: r => `${r.firstName} ${r.lastName}` }, { key: 'email', label: 'E-mail' }, { key: 'currentTitle', label: 'Title' },
    { key: 'currentEmployer', label: 'Employer' }, { key: 'totalExperienceYears', label: 'Exp. (y)', type: 'number' }, { key: 'expectedSalary', label: 'Expected salary', type: 'money' },
    { key: 'noticePeriodDays', label: 'Notice', type: 'days' }, { key: 'status', label: 'Status', type: 'status' }
  ];
  readonly detail: DetailField[] = [
    { key: 'email', label: 'E-mail' }, { key: 'phone', label: 'Phone' }, { key: 'currentTitle', label: 'Current title' }, { key: 'currentEmployer', label: 'Current employer' },
    { key: 'totalExperienceYears', label: 'Stated experience (years)', type: 'number' }, { key: 'computedExperienceYears', label: 'Experience from history (years)', type: 'number' },
    { key: 'expectedSalary', label: 'Expected salary', type: 'money' }, { key: 'noticePeriodDays', label: 'Notice period', type: 'days' }, { key: 'summary', label: 'Summary', wide: true }
  ];
  readonly skillCols: Column[] = [{ key: 'skillName', label: 'Skill' }, { key: 'yearsExperience', label: 'Years', type: 'number' }, { key: 'proficiencyLevel', label: 'Proficiency (1–5)', type: 'number' }];
  readonly skillActions: RowAction[] = [{ label: 'Remove', kind: 'danger', run: s => this.removeSkill(s) }];
  readonly eduCols: Column[] = [{ key: 'institution', label: 'Institution' }, { key: 'degree', label: 'Degree' }, { key: 'fieldOfStudy', label: 'Field' }, { key: 'startYear', label: 'From' }, { key: 'endYear', label: 'To' }, { key: 'grade', label: 'Grade' }];
  readonly expCols: Column[] = [{ key: 'employer', label: 'Employer' }, { key: 'jobTitle', label: 'Title' }, { key: 'startDate', label: 'From', type: 'date' }, { key: 'endDate', label: 'To', type: 'date' }, { key: 'isCurrent', label: 'Current', type: 'bool' }, { key: 'description', label: 'Description' }];

  ngOnInit(): void { void this.load(1); }
  async load(page: number): Promise<void> {
    try {
      const r = await this.api.get<any>('/candidates', { q: this.f.q.trim(), skills: this.f.skills.trim(), minExp: this.f.minExp, maxExp: this.f.maxExp, status: this.f.status, page });
      this.rows.set(r.items); this.total.set(r.total); this.page.set(page);
    } catch (e) { this.toasts.error(e); }
  }
  async open(r: any): Promise<void> { try { this.sel.set(await this.api.get(`/candidates/${r.candidateId}`)); } catch (e) { this.toasts.error(e); } }

  async create(): Promise<void> {
    const r: any = await this.dlg.open({
      title: 'Add candidate', wide: true, submitLabel: 'Add candidate',
      message: 'One record per person: an e-mail address that already exists is refused, and the existing record should be used instead.',
      fields: [
        { key: 'firstName', label: 'First name', required: true, maxLength: 100 },
        { key: 'lastName', label: 'Last name', required: true, maxLength: 100 },
        { key: 'email', label: 'E-mail', type: 'email', required: true, maxLength: 256 },
        { key: 'phone', label: 'Phone', maxLength: 30 },
        { key: 'currentTitle', label: 'Current title', maxLength: 150 },
        { key: 'currentEmployer', label: 'Current employer', maxLength: 150 },
        { key: 'totalExperienceYears', label: 'Total experience (years)', type: 'number', min: 0, max: 60, step: 0.5, value: 0, required: true },
        { key: 'expectedSalary', label: 'Expected annual salary (INR)', type: 'number', min: 0 },
        { key: 'noticePeriodDays', label: 'Notice period (days)', type: 'number', min: 0, max: 365 },
        { key: 'sourceId', label: 'Source', type: 'select', options: () => this.lookups.sources() },
        { key: 'summary', label: 'Summary', type: 'textarea', maxLength: 1000 }
      ],
      submit: v => this.api.post('/candidates', v)
    });
    if (r) { this.toasts.ok('Candidate added.'); await this.load(1); await this.open(r); }
  }
  async edit(p: any): Promise<void> {
    const ok = await this.dlg.open({
      title: `Edit ${p.firstName} ${p.lastName}`, wide: true,
      fields: [
        { key: 'firstName', label: 'First name', value: p.firstName, required: true, maxLength: 100 },
        { key: 'lastName', label: 'Last name', value: p.lastName, required: true, maxLength: 100 },
        { key: 'phone', label: 'Phone', value: p.phone, maxLength: 30 },
        { key: 'currentTitle', label: 'Current title', value: p.currentTitle, maxLength: 150 },
        { key: 'currentEmployer', label: 'Current employer', value: p.currentEmployer, maxLength: 150 },
        { key: 'totalExperienceYears', label: 'Total experience (years)', type: 'number', min: 0, max: 60, step: 0.5, value: p.totalExperienceYears, required: true },
        { key: 'expectedSalary', label: 'Expected annual salary (INR)', type: 'number', min: 0, value: p.expectedSalary },
        { key: 'noticePeriodDays', label: 'Notice period (days)', type: 'number', min: 0, max: 365, value: p.noticePeriodDays },
        { key: 'status', label: 'Status', type: 'select', options: opts(['Active', 'Inactive', 'Blacklisted']), value: p.status, required: true },
        { key: 'summary', label: 'Summary', type: 'textarea', maxLength: 1000, value: p.summary }
      ],
      submit: v => this.api.put(`/candidates/${p.candidateId}`, { ...v, rowVer: p.rowVer })
    });
    if (ok) { this.toasts.ok('Candidate updated.'); await this.load(this.page()); await this.open(p); }
  }
  async addSkill(p: any): Promise<void> {
    const ok = await this.dlg.open({
      title: `Skill for ${p.firstName} ${p.lastName}`,
      fields: [
        { key: 'skillName', label: 'Skill', required: true, maxLength: 100 },
        { key: 'yearsExperience', label: 'Years of experience', type: 'number', min: 0, max: 60, step: 0.5, value: 1, required: true },
        { key: 'proficiencyLevel', label: 'Proficiency (1–5)', type: 'number', min: 1, max: 5, value: 3, required: true }
      ],
      submit: v => this.api.post(`/candidates/${p.candidateId}/skills`, v)
    });
    if (ok) { this.toasts.ok('Skill saved.'); await this.open(p); }
  }
  async removeSkill(s: any): Promise<void> {
    const p = this.sel()?.profile;
    if (p && await this.dlg.confirm('Remove skill', `Remove "${s.skillName}"?`, () => this.api.delete(`/candidates/${p.candidateId}/skills/${encodeURIComponent(s.skillName)}`), 'Remove', true)) {
      this.toasts.ok('Skill removed.'); await this.open(p);
    }
  }
  badge(v: unknown): string { return statusClass(v); }
}
