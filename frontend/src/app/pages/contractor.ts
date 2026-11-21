import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, errorText } from '../core/api';
import { addDays, dateOnly, formatValue, isoDate, mondayOf, statusClass, StatusTextPipe } from '../core/format';
import { Toasts } from '../core/ui';
import { Column, DataTable, RowAction } from '../shared/table';
import { DetailField, DetailList } from '../shared/widgets';
import { DocumentsPanel } from '../shared/documents';
import { Option } from '../core/ui';

interface DayRow { date: string; label: string; regular: number | null; overtime: number | null; notes: string; billable: boolean; }

const DAY = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

@Component({
  selector: 'app-contractor-timesheets',
  imports: [DataTable, FormsModule, StatusTextPipe],
  template: `
    <h1>Timesheets</h1>
    <section class="card">
      <div class="card-head">
        <h2>Enter time</h2>
        @if (sheet()) { <span [class]="badge(sheet().status)">{{ sheet().status | statusText }}</span> } @else { <span class="badge">New week</span> }
      </div>
      @if (assignments().length === 0) {
        <p class="muted">You have no active assignment, so there is nothing to record time against.</p>
      } @else {
        <div class="tools wrap">
          <label class="inline">Assignment
            <select [(ngModel)]="assignmentId" name="asg" (ngModelChange)="openWeek()">
              @for (a of assignments(); track a.assignmentId) { <option [ngValue]="a.assignmentId">{{ a.roleTitle }} — {{ a.customerName }} ({{ a.contractNo }})</option> }
            </select>
          </label>
          <button class="btn sm" type="button" (click)="shift(-7)">◀ Previous week</button>
          <label class="inline">Week starting <input type="date" [ngModel]="week()" (ngModelChange)="setWeek($event)" name="wk" /></label>
          <button class="btn sm" type="button" (click)="shift(7)" [disabled]="week() >= thisMonday">Next week ▶</button>
        </div>
        @if (sheet()?.status === 'Rejected' && rejection()) { <div class="alert error">Rejected by the customer — “{{ rejection() }}” Correct the hours and submit again.</div> }
        <table class="grid timesheet">
          <thead><tr><th>Day</th><th class="num">Regular hours</th><th class="num">Overtime hours</th><th>Billable</th><th>Notes</th></tr></thead>
          <tbody>
            @for (d of days(); track d.date) {
              <tr>
                <td>{{ d.label }}</td>
                <td class="num"><input type="number" min="0" max="24" step="0.25" [name]="'r' + d.date" [(ngModel)]="d.regular" [disabled]="!editable()" (ngModelChange)="dirty.set(true)" [attr.aria-label]="'Regular hours ' + d.label" /></td>
                <td class="num"><input type="number" min="0" max="24" step="0.25" [name]="'o' + d.date" [(ngModel)]="d.overtime" [disabled]="!editable()" (ngModelChange)="dirty.set(true)" [attr.aria-label]="'Overtime hours ' + d.label" /></td>
                <td><input type="checkbox" [name]="'b' + d.date" [(ngModel)]="d.billable" [disabled]="!editable()" (ngModelChange)="dirty.set(true)" [attr.aria-label]="'Billable ' + d.label" /></td>
                <td><input type="text" maxlength="300" [name]="'n' + d.date" [(ngModel)]="d.notes" [disabled]="!editable()" (ngModelChange)="dirty.set(true)" [attr.aria-label]="'Notes ' + d.label" /></td>
              </tr>
            }
          </tbody>
          <tfoot><tr><th>Total</th><th class="num" colspan="2">{{ total() }} h</th><th colspan="2"></th></tr></tfoot>
        </table>
        @if (error()) { <div class="alert error" role="alert">{{ error() }}</div> }
        <div class="tools">
          @if (editable()) {
            <button class="btn" type="button" (click)="save()" [disabled]="busy()">Save draft</button>
            <button class="btn primary" type="button" (click)="submit()" [disabled]="busy() || total() <= 0">Save and submit for approval</button>
          } @else {
            <span class="muted">This week is {{ sheet()?.status }} and can no longer be edited.</span>
          }
        </div>
      }
    </section>
    <section class="card">
      <h2>Recent weeks</h2>
      <app-table [rows]="mine()" [columns]="cols" [actions]="actions" empty="No timesheets yet." />
    </section>
  `
})
export class ContractorTimesheetsPage implements OnInit {
  private readonly api = inject(Api);
  private readonly toasts = inject(Toasts);
  readonly thisMonday = isoDate(mondayOf(new Date()));
  readonly assignments = signal<any[]>([]);
  readonly mine = signal<any[]>([]);
  readonly week = signal(this.thisMonday);
  readonly sheet = signal<any>(null);
  readonly rejection = signal<string | null>(null);
  readonly days = signal<DayRow[]>([]);
  readonly dirty = signal(false);
  readonly busy = signal(false);
  readonly error = signal<string | null>(null);
  assignmentId: number | null = null;

  readonly editable = computed(() => !this.sheet() || ['Draft', 'Rejected'].includes(this.sheet().status));
  /** Recomputed on every change detection: the grid rows are edited in place by ngModel. */
  total(): number { return this.days().reduce((s, d) => s + (Number(d.regular) || 0) + (Number(d.overtime) || 0), 0); }

  readonly cols: Column[] = [
    { key: 'weekStartDate', label: 'Week of', type: 'date' }, { key: 'status', label: 'Status', type: 'status' }, { key: 'totalHours', label: 'Hours', type: 'hours' },
    { key: 'submittedAt', label: 'Submitted', type: 'datetime' }, { key: 'lastRejectionReason', label: 'Last rejection reason' }
  ];
  readonly actions: RowAction[] = [{ label: 'Open', run: r => { this.assignmentId = r.assignmentId; this.setWeek(dateOnly(r.weekStartDate)); } }];

  async ngOnInit(): Promise<void> {
    try {
      const [a] = await Promise.all([this.api.get<any[]>('/assignments', { status: 'Active' }), this.loadMine()]);
      this.assignments.set(a);
      this.assignmentId = a[0]?.assignmentId ?? null;
      await this.openWeek();
    } catch (e) { this.toasts.error(e); }
  }

  private async loadMine(): Promise<void> { this.mine.set(await this.api.get('/timesheets/mine', { top: 52 })); }

  setWeek(v: string): void {
    if (!v) return;
    this.week.set(isoDate(mondayOf(new Date(v + 'T00:00:00'))));
    void this.openWeek();
  }
  shift(days: number): void { this.setWeek(isoDate(addDays(new Date(this.week() + 'T00:00:00'), days))); }

  /** Phase 14 (found by the end-to-end test): a slower load of an earlier week must not overwrite the week shown now. */
  private loadSeq = 0;

  async openWeek(): Promise<void> {
    const seq = ++this.loadSeq;
    this.error.set(null); this.dirty.set(false); this.rejection.set(null);
    const start = new Date(this.week() + 'T00:00:00');
    const rows: DayRow[] = DAY.map((n, i) => {
      const d = addDays(start, i);
      return { date: isoDate(d), label: `${n} ${formatValue(isoDate(d), 'date')}`, regular: null, overtime: null, notes: '', billable: true };
    });
    const existing = this.mine().find(t => t.assignmentId === this.assignmentId && dateOnly(t.weekStartDate) === this.week());
    if (existing) {
      try {
        const r = await this.api.get<any>(`/timesheets/${existing.timesheetId}`);
        if (seq !== this.loadSeq) return;                    // another week was opened meanwhile: drop this stale result
        for (const e of r.entries as any[]) {
          const row = rows.find(x => x.date === dateOnly(e.workDate));
          if (!row) continue;
          if (e.entryType === 'Overtime') row.overtime = e.hours; else row.regular = e.hours;
          row.billable = !!e.isBillable;
          if (e.notes) row.notes = e.notes;
        }
        this.sheet.set(r.timesheet);
        this.rejection.set(existing.lastRejectionReason ?? null);
      } catch (e) { if (seq !== this.loadSeq) return; this.toasts.error(e); this.sheet.set(null); }
    } else {
      this.sheet.set(null);
    }
    this.days.set(rows);
  }

  private entries(): any[] {
    const out: any[] = [];
    for (const d of this.days()) {
      if (Number(d.regular) > 0) out.push({ workDate: d.date, hours: Number(d.regular), entryType: 'Regular', isBillable: d.billable, notes: d.notes || null });
      if (Number(d.overtime) > 0) out.push({ workDate: d.date, hours: Number(d.overtime), entryType: 'Overtime', isBillable: d.billable, notes: d.notes || null });
    }
    return out;
  }

  async save(quiet = false): Promise<any> {
    this.busy.set(true); this.error.set(null);
    try {
      const r = await this.api.put<any>('/timesheets/entries', { weekStartDate: this.week(), assignmentId: this.assignmentId, rowVer: this.sheet()?.rowVer ?? null, entries: this.entries() });
      if (!quiet) this.toasts.ok(`Saved: ${r.totalHours} hours (Draft).`);
      await this.loadMine();
      await this.openWeek();
      return r;
    } catch (e) { this.error.set(errorText(e)); return null; } finally { this.busy.set(false); }
  }

  async submit(): Promise<void> {
    const saved = await this.save(true);
    if (!saved) return;
    this.busy.set(true);
    try {
      await this.api.post(`/timesheets/${saved.timesheetId}/submit`);
      this.toasts.ok('Submitted to the customer for approval.');
      await this.loadMine(); await this.openWeek();
    } catch (e) { this.error.set(errorText(e)); } finally { this.busy.set(false); }
  }

  badge(v: unknown): string { return statusClass(v); }
}

@Component({
  selector: 'app-contractor-profile',
  imports: [DataTable, DetailList, DocumentsPanel],
  template: `
    @if (data(); as d) {
      <h1>{{ d.contractor.firstName }} {{ d.contractor.lastName }} <small class="muted">{{ d.contractor.contractorNo }}</small></h1>
      <section class="card"><app-details [data]="d.contractor" [fields]="fields" /></section>
      <section class="card"><h2>Assignments</h2><app-table [rows]="d.assignments" [columns]="asgCols" [filter]="false" empty="No assignments." /></section>
      <section class="card">
        <h2>Compliance records</h2>
        <app-table [rows]="d.compliance" [columns]="compCols" [filter]="false" empty="No compliance records." />
        <p class="muted">Attach the proof for a record below; a recruiter then verifies it. A new proof sets the record back to Pending.</p>
      </section>
      <section class="card">
        <app-documents ownerType="Contractor" [ownerId]="d.contractor.contractorId" title="My documents" [complianceOptions]="complianceOptions(d)" [canUpload]="true" (changed)="ngOnInit()" />
      </section>
    }
  `
})
export class ContractorProfilePage implements OnInit {
  private readonly api = inject(Api);
  private readonly toasts = inject(Toasts);
  readonly data = signal<any>(null);
  readonly fields: DetailField[] = [{ key: 'email', label: 'E-mail' }, { key: 'phone', label: 'Phone' }, { key: 'status', label: 'Status', type: 'status' }];
  readonly asgCols: Column[] = [
    { key: 'roleTitle', label: 'Role' }, { key: 'customerName', label: 'Customer' }, { key: 'contractNo', label: 'Contract' }, { key: 'siteLocation', label: 'Site' },
    { key: 'hoursPerWeek', label: 'Hours/week', type: 'number' }, { key: 'startDate', label: 'Start', type: 'date' }, { key: 'endDate', label: 'End', type: 'date' },
    { key: 'payRate', label: 'Pay rate / h', type: 'money' }, { key: 'status', label: 'Status', type: 'status' }
  ];
  readonly compCols: Column[] = [
    { key: 'recordType', label: 'Record' }, { key: 'status', label: 'Status', type: 'status' }, { key: 'issuedOn', label: 'Issued', type: 'date' },
    { key: 'expiresOn', label: 'Expires', type: 'date' }, { key: 'daysToExpiry', label: 'Days left', type: 'number' },
    { key: 'proof', label: 'Proof', value: r => r.documentId ? 'Attached' : 'Missing' }, { key: 'notes', label: 'Notes' }
  ];
  complianceOptions(d: any): Option[] { return (d.compliance as any[]).map(c => ({ value: c.complianceId, label: `${c.recordType} (${c.status})` })); }
  async ngOnInit(): Promise<void> { try { this.data.set(await this.api.get('/contractors/me')); } catch (e) { this.toasts.error(e); } }
}
