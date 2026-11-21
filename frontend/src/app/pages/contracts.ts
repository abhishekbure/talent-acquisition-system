import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api } from '../core/api';
import { Auth } from '../core/auth';
import { dateOnly, statusClass, StatusTextPipe } from '../core/format';
import { Dialogs, Toasts } from '../core/ui';
import { Column, DataTable } from '../shared/table';
import { DetailField, DetailList } from '../shared/widgets';
import { DocumentsPanel } from '../shared/documents';

/** Contracts for contractors (pay rate only), customers (bill rate only) and staff (both); the API blanks the hidden rate. */
@Component({
  selector: 'app-contracts',
  imports: [DataTable, DetailList, FormsModule, DocumentsPanel, StatusTextPipe],
  template: `
    <div class="page-head">
      <h1>Contracts</h1>
      <div class="tools">
        <select name="status" [(ngModel)]="status" (change)="load()" aria-label="Status">
          <option value="">All statuses</option>
          @for (s of statuses; track s) { <option [value]="s">{{ s | statusText }}</option> }
        </select>
      </div>
    </div>
    <app-table [rows]="rows()" [columns]="cols()" [selectable]="true" keyField="contractId" [selectedKey]="sel()?.contract?.contractId" (select)="open($event)" empty="No contracts." />
    @if (sel(); as s) {
      <section class="card">
        <div class="card-head">
          <h2>{{ s.contract.contractNo }} — {{ s.contract.contractorName }} at {{ s.contract.customerName }}</h2>
          <span [class]="badge(s.contract.status)">{{ s.contract.status | statusText }}</span>
        </div>
        <app-details [data]="s.contract" [fields]="detail" />
        @if (staff() && ['Active', 'Expiring', 'Expired'].includes(s.contract.status)) {
          <div class="tools">
            <button class="btn" type="button" (click)="renew(s.contract)">Renew / extend</button>
            @if (s.contract.status !== 'Expired') {
              <button class="btn" type="button" (click)="addAssignment(s)">Add assignment</button>
              <button class="btn danger" type="button" (click)="terminate(s.contract)">Terminate</button>
            }
          </div>
        }
        <h3>Rates</h3>
        <app-table [rows]="s.rates" [columns]="rateCols()" [filter]="false" />
        <h3>Assignments</h3>
        <app-table [rows]="s.assignments" [columns]="asgCols" [filter]="false" />
        <h3>Extensions</h3>
        <app-table [rows]="s.extensions" [columns]="extCols" [filter]="false" empty="Never extended." />
        <app-documents ownerType="Contract" [ownerId]="s.contract.contractId" title="Signed contract" [canUpload]="staff()" empty="No signed copy uploaded yet." />
      </section>
    }
  `
})
export class ContractsPage implements OnInit {
  private readonly api = inject(Api);
  private readonly auth = inject(Auth);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  readonly statuses = ['Active', 'Expiring', 'Expired', 'Terminated', 'Renewed', 'Draft'];
  status = '';
  readonly rows = signal<any[]>([]);
  readonly sel = signal<any>(null);
  readonly staff = computed(() => this.auth.has('Recruiter', 'Administrator'));
  private readonly showPay = computed(() => this.auth.has('Contractor', 'Recruiter', 'Administrator'));
  private readonly showBill = computed(() => this.auth.has('Customer', 'Recruiter', 'Administrator'));

  readonly cols = computed<Column[]>(() => {
    const c: Column[] = [
      { key: 'contractNo', label: 'Contract' }, { key: 'contractorName', label: 'Contractor' }, { key: 'customerName', label: 'Customer' },
      { key: 'startDate', label: 'Start', type: 'date' }, { key: 'endDate', label: 'End', type: 'date' }, { key: 'daysToExpiry', label: 'Days left', type: 'number' },
      { key: 'status', label: 'Status', type: 'status' }
    ];
    if (this.showPay()) c.push({ key: 'payRate', label: 'Pay rate / h', type: 'money' });
    if (this.showBill()) c.push({ key: 'billRate', label: 'Bill rate / h', type: 'money' });
    return c;
  });
  readonly rateCols = computed<Column[]>(() => {
    const c: Column[] = [{ key: 'effectiveFrom', label: 'From', type: 'date' }, { key: 'effectiveTo', label: 'To', type: 'date' }];
    if (this.showPay()) c.push({ key: 'payRate', label: 'Pay rate / h', type: 'money' }, { key: 'overtimePayMultiplier', label: 'OT pay ×', type: 'number' });
    if (this.showBill()) c.push({ key: 'billRate', label: 'Bill rate / h', type: 'money' }, { key: 'overtimeBillMultiplier', label: 'OT bill ×', type: 'number' });
    return c;
  });
  readonly detail: DetailField[] = [
    { key: 'contractorNo', label: 'Contractor no.' }, { key: 'startDate', label: 'Start', type: 'date' }, { key: 'endDate', label: 'End', type: 'date' },
    { key: 'durationDays', label: 'Duration', type: 'days' }, { key: 'terms', label: 'Terms', wide: true }
  ];
  readonly asgCols: Column[] = [
    { key: 'roleTitle', label: 'Role' }, { key: 'siteLocation', label: 'Site' }, { key: 'hoursPerWeek', label: 'Hours/week', type: 'number' },
    { key: 'startDate', label: 'Start', type: 'date' }, { key: 'endDate', label: 'End', type: 'date' }, { key: 'status', label: 'Status', type: 'status' }
  ];
  readonly extCols: Column[] = [{ key: 'previousEndDate', label: 'Previous end', type: 'date' }, { key: 'newEndDate', label: 'New end', type: 'date' }, { key: 'reason', label: 'Reason' }, { key: 'createdAt', label: 'Recorded', type: 'datetime' }];

  ngOnInit(): void { void this.load(); }
  async load(): Promise<void> { try { this.rows.set(await this.api.get('/contracts', { status: this.status })); } catch (e) { this.toasts.error(e); } }
  async open(r: any): Promise<void> { try { this.sel.set(await this.api.get(`/contracts/${r.contractId}`)); } catch (e) { this.toasts.error(e); } }

  async renew(c: any): Promise<void> {
    const end = new Date(dateOnly(c.endDate) + 'T00:00:00'); end.setMonth(end.getMonth() + 3);
    const r = await this.dlg.open({
      title: `Renew ${c.contractNo}`, submitLabel: 'Renew',
      message: 'Leave the rates empty to keep the current ones. New rates apply from today; earlier days keep the old rates.',
      fields: [
        { key: 'newEndDate', label: 'New end date', type: 'date', value: `${end.getFullYear()}-${String(end.getMonth() + 1).padStart(2, '0')}-${String(end.getDate()).padStart(2, '0')}`, required: true },
        { key: 'payRate', label: 'New pay rate / h (optional)', type: 'number', min: 0, step: 0.01 },
        { key: 'billRate', label: 'New bill rate / h (optional)', type: 'number', min: 0.01, step: 0.01 },
        { key: 'reason', label: 'Reason', type: 'textarea', maxLength: 500 }
      ],
      submit: v => this.api.post(`/contracts/${c.contractId}/renew`, v)
    });
    if (r) { this.toasts.ok('Contract renewed.'); await this.load(); await this.open(c); }
  }
  async terminate(c: any): Promise<void> {
    const r = await this.dlg.open({
      title: `Terminate ${c.contractNo}`, danger: true, submitLabel: 'Terminate',
      message: 'Termination ends the contract and its active assignments. It cannot be undone.',
      fields: [{ key: 'reason', label: 'Reason', type: 'textarea', required: true, maxLength: 500 }],
      submit: v => this.api.post(`/contracts/${c.contractId}/terminate`, v)
    });
    if (r) { this.toasts.ok('Contract terminated.'); await this.load(); await this.open(c); }
  }
  async addAssignment(s: any): Promise<void> {
    const c = s.contract;
    const r = await this.dlg.open({
      title: `Add assignment to ${c.contractNo}`, submitLabel: 'Add assignment',
      fields: [
        { key: 'roleTitle', label: 'Role title', required: true, maxLength: 150, value: s.assignments[0]?.roleTitle ?? '' },
        { key: 'siteLocation', label: 'Site location', maxLength: 150 },
        { key: 'hoursPerWeek', label: 'Hours per week', type: 'number', min: 1, max: 80, value: 40, required: true },
        { key: 'startDate', label: 'Start date', type: 'date', required: true, hint: 'Must lie within the contract period.' },
        { key: 'endDate', label: 'End date (optional)', type: 'date' }
      ],
      submit: v => this.api.post('/assignments', { contractId: c.contractId, ...v })
    });
    if (r) { this.toasts.ok('Assignment added.'); await this.open(c); }
  }
  badge(v: unknown): string { return statusClass(v); }
}
