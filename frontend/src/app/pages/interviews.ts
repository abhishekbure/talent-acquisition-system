import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api } from '../core/api';
import { Auth } from '../core/auth';
import { statusClass, StatusTextPipe } from '../core/format';
import { Toasts } from '../core/ui';
import { Actions } from '../shared/actions';
import { Column, DataTable } from '../shared/table';
import { DetailField, DetailList } from '../shared/widgets';

@Component({
  selector: 'app-interviews',
  imports: [DataTable, DetailList, FormsModule, StatusTextPipe],
  template: `
    <div class="page-head">
      <h1>Interviews</h1>
      <form class="tools wrap" (ngSubmit)="load()">
        <select name="status" [(ngModel)]="status" aria-label="Status">
          <option value="">All statuses</option>
          @for (s of statuses; track s) { <option [value]="s">{{ s | statusText }}</option> }
        </select>
        <label class="inline">From <input type="date" name="from" [(ngModel)]="from" /></label>
        <label class="inline">To <input type="date" name="to" [(ngModel)]="to" /></label>
        <button class="btn" type="submit">Show</button>
      </form>
    </div>
    <app-table [rows]="rows()" [columns]="cols()" [selectable]="true" keyField="interviewId" [selectedKey]="sel()?.interview?.interviewId" (select)="open($event)" empty="No interviews found." />
    @if (sel(); as s) {
      <section class="card">
        <div class="card-head">
          <h2>{{ s.interview.candidateName }} — {{ s.interview.roleTitle }} <small class="muted">round {{ s.interview.roundNo }}</small></h2>
          <span [class]="badge(s.interview.status)">{{ s.interview.status | statusText }}</span>
        </div>
        <app-details [data]="s.interview" [fields]="detail" />
        <div class="tools">
          @if (canFeedback(s)) { <button class="btn primary" type="button" (click)="feedback(s)">Give feedback</button> }
          @if (canManage(s)) {
            <button class="btn" type="button" (click)="reschedule(s)">Reschedule</button>
            <button class="btn danger" type="button" (click)="cancel(s)">Cancel interview</button>
          }
        </div>
        @if (!isCandidateOnly()) {
          <h3>Panel</h3>
          <app-table [rows]="s.panel" [columns]="panelCols" [filter]="false" />
          <h3>Feedback</h3>
          <app-table [rows]="s.feedback" [columns]="fbCols" [filter]="false" empty="No feedback yet (or not visible to you)." />
        }
      </section>
    }
  `
})
export class InterviewsPage implements OnInit {
  private readonly api = inject(Api);
  private readonly auth = inject(Auth);
  private readonly toasts = inject(Toasts);
  private readonly actions = inject(Actions);
  readonly statuses = ['Scheduled', 'Rescheduled', 'Completed', 'Cancelled'];
  status = ''; from = ''; to = '';
  readonly rows = signal<any[]>([]);
  readonly sel = signal<any>(null);
  readonly isCandidateOnly = computed(() => !this.auth.has('Recruiter', 'HRManager', 'Administrator', 'Customer'));
  readonly cols = computed<Column[]>(() => {
    const c: Column[] = [
      { key: 'startsAt', label: 'Starts', type: 'datetime' }, { key: 'candidateName', label: 'Candidate' }, { key: 'roleTitle', label: 'Role' },
      { key: 'opportunity', label: 'Kind' }, { key: 'customerName', label: 'Customer' }, { key: 'roundNo', label: 'Round', type: 'number' },
      { key: 'interviewType', label: 'Type' }, { key: 'mode', label: 'Mode' }, { key: 'panel', label: 'Panel' }, { key: 'status', label: 'Status', type: 'status' }
    ];
    if (!this.isCandidateOnly()) c.push({ key: 'feedbackCount', label: 'Feedback', type: 'number' });
    return c;
  });
  readonly detail: DetailField[] = [
    { key: 'startsAt', label: 'Starts', type: 'datetime' }, { key: 'endsAt', label: 'Ends', type: 'datetime' }, { key: 'interviewType', label: 'Type' },
    { key: 'mode', label: 'Mode' }, { key: 'locationOrLink', label: 'Location / link', wide: true }, { key: 'notes', label: 'Notes', wide: true }
  ];
  readonly panelCols: Column[] = [{ key: 'displayName', label: 'Interviewer' }, { key: 'isLead', label: 'Lead', type: 'bool' }, { key: 'feedbackGiven', label: 'Feedback given', type: 'bool' }];
  readonly fbCols: Column[] = [
    { key: 'interviewer', label: 'Interviewer' }, { key: 'rating', label: 'Rating', type: 'number' }, { key: 'recommendation', label: 'Recommendation' },
    { key: 'strengths', label: 'Strengths' }, { key: 'concerns', label: 'Concerns' }, { key: 'submittedAt', label: 'Submitted', type: 'datetime' }
  ];

  ngOnInit(): void { void this.load(); }

  async load(): Promise<void> {
    try { this.rows.set(await this.api.get('/interviews', { status: this.status, from: this.from, to: this.to })); } catch (e) { this.toasts.error(e); }
  }
  async open(r: any): Promise<void> { try { this.sel.set(await this.api.get(`/interviews/${r.interviewId}`)); } catch (e) { this.toasts.error(e); } }

  canFeedback(s: any): boolean {
    const me = this.auth.user()?.userId;
    const mine = (s.panel as any[]).find(p => p.userId === me);
    return !!s.interview.isPanelMember && !!mine && !mine.feedbackGiven && s.interview.status !== 'Cancelled' && new Date(s.interview.startsAt).getTime() <= Date.now();
  }
  canManage(s: any): boolean {
    if (!['Scheduled', 'Rescheduled'].includes(s.interview.status)) return false;
    if (this.auth.has('Recruiter', 'HRManager', 'Administrator')) return true;
    return this.auth.has('Customer') && s.interview.customerId !== null && s.interview.customerId === this.auth.user()?.customerId;
  }
  async feedback(s: any): Promise<void> { if (await this.actions.feedback(s.interview.interviewId)) await this.after(s, 'Feedback recorded.'); }
  async reschedule(s: any): Promise<void> { if (await this.actions.reschedule(s.interview)) await this.after(s, 'Interview rescheduled; the candidate is notified.'); }
  async cancel(s: any): Promise<void> { if (await this.actions.cancelInterview(s.interview)) await this.after(s, 'Interview cancelled.'); }
  private async after(s: any, msg: string): Promise<void> { this.toasts.ok(msg); await this.load(); await this.open(s.interview); }
  badge(v: unknown): string { return statusClass(v); }
}
