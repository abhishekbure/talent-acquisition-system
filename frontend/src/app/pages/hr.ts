import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api } from '../core/api';
import { Auth } from '../core/auth';
import { statusClass, StatusTextPipe } from '../core/format';
import { Dialogs, Toasts } from '../core/ui';
import { Lookups } from '../shared/lookups';
import { Column, DataTable, RowAction } from '../shared/table';
import { DetailField, DetailList } from '../shared/widgets';
import { DocumentsPanel, EMPLOYEE_DOC_TYPES } from '../shared/documents';

@Component({
  selector: 'app-employees',
  imports: [DataTable, DetailList, FormsModule, DocumentsPanel, StatusTextPipe],
  template: `
    <div class="page-head">
      <h1>Employees & onboarding</h1>
      <form class="tools wrap" (ngSubmit)="load(1)">
        <input type="search" name="q" [(ngModel)]="q" placeholder="Name, e-mail or number" aria-label="Search" />
        <select name="st" [(ngModel)]="status" aria-label="Status"><option value="">All statuses</option>@for (s of statuses; track s) { <option [value]="s">{{ s | statusText }}</option> }</select>
        <button class="btn" type="submit">Show</button>
      </form>
    </div>
    <p class="muted">Employees are created automatically when a candidate accepts an offer. Completing the last onboarding task makes the employee Active.</p>
    <app-table [rows]="rows()" [columns]="cols" [selectable]="true" keyField="employeeId" [selectedKey]="sel()?.employee?.employeeId"
               [total]="total()" [page]="page()" (pageChange)="load($event)" (select)="open($event)" empty="No employees." />
    @if (sel(); as s) {
      <section class="card">
        <div class="card-head"><h2>{{ s.employee.employeeNo }} — {{ s.employee.employeeName }}</h2><span [class]="badge(s.employee.status)">{{ s.employee.status | statusText }}</span></div>
        <app-details [data]="s.employee" [fields]="detail" />
        <h3>Onboarding checklist</h3>
        <app-table [rows]="s.onboarding" [columns]="taskCols" [actions]="taskActions" [filter]="false" />
        <h3>Employment history</h3>
        <app-table [rows]="s.history" [columns]="histCols" [filter]="false" />
        <app-documents ownerType="Employee" [ownerId]="s.employee.employeeId" title="Employee documents" [docTypes]="empDocTypes" [canUpload]="true" />
      </section>
    }
  `
})
export class EmployeesPage implements OnInit {
  readonly empDocTypes = EMPLOYEE_DOC_TYPES;
  private readonly api = inject(Api);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  readonly statuses = ['Onboarding', 'Active', 'OnLeave', 'Terminated'];
  q = ''; status = '';
  readonly rows = signal<any[]>([]);
  readonly total = signal(0);
  readonly page = signal(1);
  readonly sel = signal<any>(null);
  readonly cols: Column[] = [
    { key: 'employeeNo', label: 'No.' }, { key: 'employeeName', label: 'Name' }, { key: 'department', label: 'Department' }, { key: 'jobTitle', label: 'Title' },
    { key: 'startDate', label: 'Start', type: 'date' }, { key: 'manager', label: 'Manager' }, { key: 'status', label: 'Status', type: 'status' },
    { key: 'onboarding', label: 'Onboarding', value: r => `${r.onboardingDone} / ${r.onboardingTotal}` }
  ];
  readonly detail: DetailField[] = [
    { key: 'email', label: 'E-mail' }, { key: 'phone', label: 'Phone' }, { key: 'department', label: 'Department' }, { key: 'location', label: 'Location' },
    { key: 'jobTitle', label: 'Title' }, { key: 'startDate', label: 'Start date', type: 'date' }, { key: 'salary', label: 'Salary', type: 'money' }, { key: 'manager', label: 'Manager' }
  ];
  readonly taskCols: Column[] = [
    { key: 'taskName', label: 'Task' }, { key: 'category', label: 'Category' }, { key: 'dueDate', label: 'Due', type: 'date' }, { key: 'status', label: 'Status', type: 'status' },
    { key: 'completedBy', label: 'By' }, { key: 'completedAt', label: 'When', type: 'datetime' }, { key: 'notes', label: 'Notes' }
  ];
  private readonly openTask = (t: any) => !['Completed', 'Waived'].includes(t.status);
  readonly taskActions: RowAction[] = [
    { label: 'Complete', kind: 'primary', show: this.openTask, run: t => this.complete(t, false) },
    { label: 'Waive', show: this.openTask, run: t => this.complete(t, true) }
  ];
  readonly histCols: Column[] = [{ key: 'eventType', label: 'Event' }, { key: 'effectiveDate', label: 'Effective', type: 'date' }, { key: 'details', label: 'Details' }, { key: 'recordedAt', label: 'Recorded', type: 'datetime' }];

  ngOnInit(): void { void this.load(1); }
  async load(page: number): Promise<void> {
    try { const r = await this.api.get<any>('/employees', { q: this.q.trim(), status: this.status, page }); this.rows.set(r.items); this.total.set(r.total); this.page.set(page); }
    catch (e) { this.toasts.error(e); }
  }
  async open(r: any): Promise<void> { try { this.sel.set(await this.api.get(`/employees/${r.employeeId}`)); } catch (e) { this.toasts.error(e); } }
  async complete(t: any, waive: boolean): Promise<void> {
    const emp = this.sel().employee;
    const out: any = await this.dlg.open({
      title: `${waive ? 'Waive' : 'Complete'}: ${t.taskName}`, submitLabel: waive ? 'Waive task' : 'Mark complete',
      fields: [{ key: 'notes', label: waive ? 'Why is it waived?' : 'Notes (optional)', type: 'textarea', required: waive, maxLength: 500 }],
      submit: v => this.api.post(`/employees/${emp.employeeId}/onboarding/${t.onboardingId}/complete`, { notes: v.notes, waive })
    });
    if (out) {
      this.toasts.ok(out.employeeStatus === 'Active' && emp.status !== 'Active' ? 'Onboarding finished — the employee is now Active.' : 'Task updated.');
      await this.load(this.page()); await this.open(emp);
    }
  }
  badge(v: unknown): string { return statusClass(v); }
}

@Component({
  selector: 'app-departments',
  imports: [DataTable],
  template: `
    <div class="page-head">
      <h1>Departments</h1>
      @if (canEdit()) { <button class="btn primary" type="button" (click)="edit(null)">New department</button> }
    </div>
    <app-table [rows]="rows()" [columns]="cols" [actions]="actions" empty="No departments." />
    <section class="card">
      <h2>Locations</h2>
      <app-table [rows]="locations()" [columns]="locCols" [filter]="false" />
    </section>
  `
})
export class DepartmentsPage implements OnInit {
  private readonly api = inject(Api);
  private readonly auth = inject(Auth);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  private readonly lookups = inject(Lookups);
  readonly rows = signal<any[]>([]);
  readonly locations = signal<any[]>([]);
  readonly canEdit = computed(() => this.auth.has('HRManager', 'Administrator'));
  readonly cols: Column[] = [
    { key: 'name', label: 'Department' }, { key: 'costCenter', label: 'Cost centre' }, { key: 'headName', label: 'Head' },
    { key: 'employees', label: 'Employees', type: 'number' }, { key: 'isActive', label: 'Active', type: 'bool' }
  ];
  readonly actions: RowAction[] = [{ label: 'Edit', show: () => this.canEdit(), run: r => this.edit(r) }];
  readonly locCols: Column[] = [{ key: 'name', label: 'Location' }, { key: 'city', label: 'City' }, { key: 'country', label: 'Country' }, { key: 'isActive', label: 'Active', type: 'bool' }];

  ngOnInit(): void { void this.load(); }
  async load(): Promise<void> {
    try { const [d, l] = await Promise.all([this.api.get<any[]>('/departments'), this.api.get<any[]>('/locations')]); this.rows.set(d); this.locations.set(l); }
    catch (e) { this.toasts.error(e); }
  }
  async edit(d: any | null): Promise<void> {
    const ok = await this.dlg.open({
      title: d ? `Edit ${d.name}` : 'New department',
      fields: [
        { key: 'name', label: 'Name', value: d?.name ?? '', required: true, maxLength: 100 },
        { key: 'costCenter', label: 'Cost centre', value: d?.costCenter ?? '', maxLength: 30 },
        { key: 'headUserId', label: 'Department head', type: 'select', value: d?.headUserId ?? null, options: () => this.lookups.staff() },
        { key: 'isActive', label: 'Active', type: 'checkbox', value: d ? d.isActive : true }
      ],
      submit: v => d ? this.api.put(`/departments/${d.departmentId}`, v) : this.api.post('/departments', v)
    });
    if (ok) { this.toasts.ok('Department saved.'); await this.load(); }
  }
}
