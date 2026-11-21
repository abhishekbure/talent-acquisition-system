import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api } from '../core/api';
import { Auth } from '../core/auth';
import { addDays, formatValue, humanize, isoDate, mondayOf, statusClass, StatusTextPipe } from '../core/format';
import { Dialogs, Toasts } from '../core/ui';
import { Lookups, PAYMENT_METHODS } from '../shared/lookups';
import { Column, DataTable, RowAction } from '../shared/table';
import { DetailField, DetailList } from '../shared/widgets';

@Component({
  selector: 'app-invoices',
  imports: [DataTable, DetailList, FormsModule, StatusTextPipe],
  template: `
    <div class="page-head">
      <h1>Invoices</h1>
      <div class="tools wrap">
        @if (staff()) {
          <select [(ngModel)]="customerId" name="cust" (change)="load()" aria-label="Customer">
            <option [ngValue]="null">All customers</option>
            @for (c of customers(); track c.value) { <option [ngValue]="c.value">{{ c.label }}</option> }
          </select>
          <button class="btn primary" type="button" (click)="generate()">Generate invoice</button>
        }
      </div>
    </div>
    @if (balance(); as b) {
      <div class="metrics"><div class="metric"><div class="metric-value">{{ money(b.outstandingBalance) }}</div><div class="metric-label">Outstanding balance for {{ auth.user()?.customerName }}</div></div></div>
    }
    <app-table [rows]="rows()" [columns]="cols()" [actions]="actions" [selectable]="true" keyField="invoiceId" [selectedKey]="sel()?.invoice?.invoiceId" (select)="open($event)" empty="No invoices." />
    @if (sel(); as s) {
      <section class="card">
        <div class="card-head"><h2>{{ s.invoice.invoiceNo }} — {{ s.invoice.customerName }}</h2><span [class]="badge(s.invoice.status)">{{ s.invoice.status | statusText }}</span></div>
        <app-details [data]="s.invoice" [fields]="detail" />
        <h3>Lines (billed at the contract bill rate)</h3>
        <app-table [rows]="s.lines" [columns]="lineCols" [filter]="false" />
        <h3>Payments</h3>
        <app-table [rows]="s.payments" [columns]="payCols" [filter]="false" empty="No payments recorded." />
      </section>
    }
  `
})
export class InvoicesPage implements OnInit {
  private readonly api = inject(Api);
  readonly auth = inject(Auth);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  private readonly lookups = inject(Lookups);
  customerId: number | null = null;
  readonly rows = signal<any[]>([]);
  readonly sel = signal<any>(null);
  readonly balance = signal<any>(null);
  readonly customers = signal<{ value: any; label: string }[]>([]);
  readonly staff = computed(() => this.auth.has('Recruiter', 'Administrator'));

  readonly cols = computed<Column[]>(() => [
    { key: 'invoiceNo', label: 'Invoice' },
    ...(this.staff() ? [{ key: 'customerName', label: 'Customer' }] : []),
    { key: 'period', label: 'Period', value: (r: any) => `${formatValue(r.periodStart, 'date')} – ${formatValue(r.periodEnd, 'date')}` },
    { key: 'issueDate', label: 'Issued', type: 'date' }, { key: 'dueDate', label: 'Due', type: 'date' }, { key: 'status', label: 'Status', type: 'status' },
    { key: 'total', label: 'Total', type: 'money' }, { key: 'amountPaid', label: 'Paid', type: 'money' }, { key: 'balance', label: 'Balance', type: 'money' },
    { key: 'daysOverdue', label: 'Days overdue', type: 'number' }
  ] as Column[]);
  readonly actions: RowAction[] = [
    { label: 'Issue', kind: 'primary', show: r => this.staff() && r.status === 'Draft', run: r => this.issue(r) },
    { label: 'Record payment', kind: 'primary', show: r => this.staff() && ['Issued', 'PartiallyPaid'].includes(r.status), run: r => this.pay(r) },
    { label: 'Void', kind: 'danger', show: r => this.staff() && ['Draft', 'Issued'].includes(r.status) && !Number(r.amountPaid), run: r => this.void(r) }
  ];
  readonly detail: DetailField[] = [
    { key: 'periodStart', label: 'Period start', type: 'date' }, { key: 'periodEnd', label: 'Period end', type: 'date' }, { key: 'issueDate', label: 'Issued', type: 'date' },
    { key: 'dueDate', label: 'Due', type: 'date' }, { key: 'subtotal', label: 'Subtotal', type: 'money' }, { key: 'taxAmount', label: 'Tax', type: 'money' },
    { key: 'total', label: 'Total', type: 'money' }, { key: 'amountPaid', label: 'Paid', type: 'money' }, { key: 'balance', label: 'Balance', type: 'money' }
  ];
  readonly lineCols: Column[] = [{ key: 'description', label: 'Description' }, { key: 'hours', label: 'Hours', type: 'hours' }, { key: 'billRate', label: 'Rate / h', type: 'money' }, { key: 'lineTotal', label: 'Amount', type: 'money' }];
  readonly payCols: Column[] = [{ key: 'paidOn', label: 'Paid on', type: 'date' }, { key: 'amount', label: 'Amount', type: 'money' }, { key: 'method', label: 'Method', value: (p: any) => humanize(String(p.method ?? '')) }, { key: 'reference', label: 'Reference' }, { key: 'recordedAt', label: 'Recorded', type: 'datetime' }];

  async ngOnInit(): Promise<void> {
    await this.load();
    if (this.staff()) { try { this.customers.set(await this.lookups.customers()); } catch (e) { this.toasts.error(e); } }
  }
  async load(): Promise<void> {
    try {
      this.rows.set(await this.api.get('/invoices', { customerId: this.customerId }));
      const cid = this.auth.user()?.customerId;
      if (this.auth.has('Customer') && cid) this.balance.set(await this.api.get(`/customers/${cid}/balance`));
    } catch (e) { this.toasts.error(e); }
  }
  async open(r: any): Promise<void> { try { this.sel.set(await this.api.get(`/invoices/${r.invoiceId}`)); } catch (e) { this.toasts.error(e); } }

  async generate(): Promise<void> {
    const lastMonday = mondayOf(addDays(new Date(), -7));
    const r: any = await this.dlg.open({
      title: 'Generate invoice', submitLabel: 'Generate draft',
      message: 'Bills every approved, not yet invoiced, billable hour of whole weeks inside the period at the contract bill rate in force on each day. The invoice starts as a Draft.',
      fields: [
        { key: 'customerId', label: 'Customer', type: 'select', required: true, value: this.customerId, options: () => this.lookups.customers() },
        { key: 'periodStart', label: 'Period start', type: 'date', required: true, value: isoDate(addDays(lastMonday, -21)) },
        { key: 'periodEnd', label: 'Period end', type: 'date', required: true, value: isoDate(addDays(lastMonday, 6)) },
        { key: 'taxRate', label: 'Tax rate (%)', type: 'number', min: 0, max: 100, step: 0.01, value: 18, required: true }
      ],
      submit: v => this.api.post('/invoices/generate', v)
    });
    if (r) { this.toasts.ok(`Draft ${r.invoiceNo} generated: ${this.money(r.total)}.`); await this.load(); await this.open(r); }
  }
  async issue(r: any): Promise<void> {
    const ok = await this.dlg.confirm(`Issue ${r.invoiceNo}`, `Issue this invoice for ${this.money(r.total)} to ${r.customerName}? The customer can see it once issued.`, () => this.api.post(`/invoices/${r.invoiceId}/issue`), 'Issue');
    if (ok) await this.after(r, 'Invoice issued.');
  }
  async pay(r: any): Promise<void> {
    const ok = await this.dlg.open({
      title: `Record payment for ${r.invoiceNo}`, submitLabel: 'Record payment',
      message: `Outstanding balance: ${this.money(r.balance)}. Payments cannot exceed the balance.`,
      fields: [
        { key: 'amount', label: 'Amount', type: 'number', min: 0.01, max: Number(r.balance), step: 0.01, value: Number(r.balance), required: true },
        { key: 'paidOn', label: 'Paid on', type: 'date', value: isoDate(new Date()), required: true },
        { key: 'method', label: 'Method', type: 'select', options: PAYMENT_METHODS, value: 'BankTransfer', required: true },
        { key: 'reference', label: 'Reference', maxLength: 100 }
      ],
      submit: v => this.api.post(`/invoices/${r.invoiceId}/payments`, v)
    });
    if (ok) await this.after(r, 'Payment recorded.');
  }
  async void(r: any): Promise<void> {
    const ok = await this.dlg.open({
      title: `Void ${r.invoiceNo}`, danger: true, submitLabel: 'Void invoice',
      message: 'Voiding releases its timesheet hours so they can be invoiced again. It cannot be undone.',
      fields: [{ key: 'reason', label: 'Reason', type: 'textarea', required: true, maxLength: 300 }],
      submit: v => this.api.post(`/invoices/${r.invoiceId}/void`, v)
    });
    if (ok) await this.after(r, 'Invoice voided.');
  }
  private async after(r: any, msg: string): Promise<void> { this.toasts.ok(msg); await this.load(); await this.open(r); }
  money(v: unknown): string { return formatValue(v, 'money'); }
  badge(v: unknown): string { return statusClass(v); }
}
