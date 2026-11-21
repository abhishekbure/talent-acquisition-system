import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api } from '../core/api';
import { Auth } from '../core/auth';
import { statusClass, StatusTextPipe } from '../core/format';
import { Dialogs, Toasts } from '../core/ui';
import { Column, DataTable, RowAction } from '../shared/table';
import { DetailField, DetailList } from '../shared/widgets';

/** Customers approve or reject their own contractors' weeks; recruiters and admins see all for follow-up. */
@Component({
  selector: 'app-timesheet-review',
  imports: [DataTable, DetailList, FormsModule, StatusTextPipe],
  template: `
    <div class="page-head">
      <h1>Timesheets</h1>
      <div class="tabs" role="tablist">
        <button type="button" role="tab" [class.active]="tab() === 'pending'" (click)="show('pending')">Awaiting approval ({{ pending().length }})</button>
        <button type="button" role="tab" [class.active]="tab() === 'all'" (click)="show('all')">All weeks</button>
      </div>
    </div>
    @if (tab() === 'pending') {
      <app-table [rows]="pending()" [columns]="pendingCols" [actions]="actions" [selectable]="true" keyField="timesheetId" [selectedKey]="sel()?.timesheet?.timesheetId" (select)="open($event)" empty="Nothing is waiting for approval." />
    } @else {
      <div class="tools">
        <select [(ngModel)]="status" name="st" (change)="loadAll()" aria-label="Status">
          <option value="">All statuses</option>
          @for (s of statuses; track s) { <option [value]="s">{{ s | statusText }}</option> }
        </select>
      </div>
      <app-table [rows]="all()" [columns]="allCols" [actions]="actions" [selectable]="true" keyField="timesheetId" [selectedKey]="sel()?.timesheet?.timesheetId" (select)="open($event)" empty="No timesheets." />
    }
    @if (sel(); as s) {
      <section class="card">
        <div class="card-head"><h2>{{ s.timesheet.contractorName }} — {{ s.timesheet.roleTitle }}</h2><span [class]="badge(s.timesheet.status)">{{ s.timesheet.status | statusText }}</span></div>
        <app-details [data]="s.timesheet" [fields]="detail" />
        @if (canDecide() && s.timesheet.status === 'Submitted') {
          <div class="tools">
            <button class="btn primary" type="button" (click)="approve(s.timesheet)">Approve</button>
            <button class="btn danger" type="button" (click)="reject(s.timesheet)">Reject</button>
          </div>
        }
        <h3>Entries</h3>
        <app-table [rows]="s.entries" [columns]="entryCols" [filter]="false" empty="No entries." />
        <h3>Decisions</h3>
        <app-table [rows]="s.decisions" [columns]="decCols" [filter]="false" empty="No decisions yet." />
      </section>
    }
  `
})
export class TimesheetReviewPage implements OnInit {
  private readonly api = inject(Api);
  private readonly auth = inject(Auth);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  readonly statuses = ['Draft', 'Submitted', 'Approved', 'Rejected', 'Invoiced'];
  status = '';
  readonly tab = signal<'pending' | 'all'>('pending');
  readonly pending = signal<any[]>([]);
  readonly all = signal<any[]>([]);
  readonly sel = signal<any>(null);
  readonly canDecide = computed(() => this.auth.has('Customer'));

  readonly pendingCols: Column[] = [
    { key: 'contractorName', label: 'Contractor' }, { key: 'customerName', label: 'Customer' }, { key: 'roleTitle', label: 'Role' },
    { key: 'weekStartDate', label: 'Week of', type: 'date' }, { key: 'totalHours', label: 'Hours', type: 'hours' },
    { key: 'submittedAt', label: 'Submitted', type: 'datetime' }, { key: 'daysWaiting', label: 'Waiting', type: 'days' }
  ];
  readonly allCols: Column[] = [
    { key: 'contractorName', label: 'Contractor' }, { key: 'customerName', label: 'Customer' }, { key: 'roleTitle', label: 'Role' },
    { key: 'weekStartDate', label: 'Week of', type: 'date' }, { key: 'totalHours', label: 'Hours', type: 'hours' }, { key: 'status', label: 'Status', type: 'status' },
    { key: 'submittedAt', label: 'Submitted', type: 'datetime' }
  ];
  readonly actions: RowAction[] = [
    { label: 'Approve', kind: 'primary', show: r => this.canDecide() && (r.status ?? 'Submitted') === 'Submitted', run: r => this.approve(r) },
    { label: 'Reject', kind: 'danger', show: r => this.canDecide() && (r.status ?? 'Submitted') === 'Submitted', run: r => this.reject(r) }
  ];
  readonly detail: DetailField[] = [
    { key: 'customerName', label: 'Customer' }, { key: 'weekStartDate', label: 'Week of', type: 'date' }, { key: 'totalHours', label: 'Total hours', type: 'hours' },
    { key: 'submittedAt', label: 'Submitted', type: 'datetime' }
  ];
  readonly entryCols: Column[] = [
    { key: 'workDate', label: 'Date', type: 'date' }, { key: 'entryType', label: 'Type' }, { key: 'hours', label: 'Hours', type: 'hours' },
    { key: 'isBillable', label: 'Billable', type: 'bool' }, { key: 'notes', label: 'Notes' }
  ];
  readonly decCols: Column[] = [
    { key: 'outcome', label: 'Decision', type: 'status' }, { key: 'byUser', label: 'By' }, { key: 'at', label: 'When', type: 'datetime' },
    { key: 'detail', label: 'Comments / reason' }
  ];

  ngOnInit(): void { void this.loadPending(); void this.loadAll(); }
  show(t: 'pending' | 'all'): void { this.tab.set(t); }
  async loadPending(): Promise<void> { try { this.pending.set(await this.api.get('/timesheets/pending')); } catch (e) { this.toasts.error(e); } }
  async loadAll(): Promise<void> { try { this.all.set(await this.api.get('/timesheets', { status: this.status })); } catch (e) { this.toasts.error(e); } }
  async open(r: any): Promise<void> { try { this.sel.set(await this.api.get(`/timesheets/${r.timesheetId}`)); } catch (e) { this.toasts.error(e); } }

  async approve(t: any): Promise<void> {
    const r = await this.dlg.open({
      title: `Approve ${t.contractorName}'s week`, submitLabel: 'Approve',
      message: `${t.totalHours} hours. Approved billable hours are invoiced at the contract bill rate.`,
      fields: [{ key: 'comments', label: 'Comments (optional)', type: 'textarea', maxLength: 500 }],
      submit: v => this.api.post(`/timesheets/${t.timesheetId}/approve`, v)
    });
    if (r) await this.after(t, 'Timesheet approved.');
  }
  async reject(t: any): Promise<void> {
    const r = await this.dlg.open({
      title: `Reject ${t.contractorName}'s week`, submitLabel: 'Reject', danger: true,
      message: 'The contractor sees your reason, corrects the week and resubmits it.',
      fields: [{ key: 'reason', label: 'Reason', type: 'textarea', required: true, maxLength: 500 }],
      submit: v => this.api.post(`/timesheets/${t.timesheetId}/reject`, v)
    });
    if (r) await this.after(t, 'Timesheet rejected; the contractor has been notified.');
  }
  private async after(t: any, msg: string): Promise<void> { this.toasts.ok(msg); await Promise.all([this.loadPending(), this.loadAll()]); await this.open(t); }
  badge(v: unknown): string { return statusClass(v); }
}
