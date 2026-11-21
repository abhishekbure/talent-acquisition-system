import { Component, computed, effect, inject, input, signal, untracked } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { Api, errorText } from '../core/api';
import { formatDateTime } from '../core/format';
import { Option, Toasts } from '../core/ui';
import { Lookups } from '../shared/lookups';
import { BarChart, ReportDef, ReportResult, camel, chartData, chartValueType } from '../shared/reports';
import { Column, DataTable } from '../shared/table';

/**
 * Phase 10: the reports a role may run (the list comes from the API, which decides per role). Pick a report, set its
 * filters, read the chart and the table, export CSV. ?report=code selects one, so a report has its own address.
 */
@Component({
  selector: 'app-reports',
  imports: [FormsModule, RouterLink, DataTable, BarChart],
  template: `
    <div class="page-head">
      <h1>{{ selected()?.title ?? 'Reports' }}</h1>
      @if (selected()) { <a routerLink="." [queryParams]="{}">← All reports</a> }
    </div>
    @if (listError()) { <div class="alert error" role="alert">{{ listError() }}</div> }

    @if (!selected()) {
      @for (g of groups(); track g.category) {
        <section class="card">
          <h2>{{ g.category }}</h2>
          <ul class="report-list">
            @for (d of g.items; track d.reportCode) {
              <li><a routerLink="." [queryParams]="{ report: d.reportCode }">{{ d.title }}</a><span class="muted"> — {{ d.description }}</span></li>
            }
          </ul>
        </section>
      } @empty {
        @if (!listError() && loaded()) { <p class="muted">No reports are available for your role.</p> }
      }
      @if (report() && loaded() && !selected()) { <div class="alert error">That report is not available for your role.</div> }
    } @else {
      @let d = selected()!;
      <p class="muted">{{ d.description }}</p>
      <form class="filters" (ngSubmit)="run()">
        @if (d.dateFilter) {
          <label class="inline">From <input type="date" name="from" [(ngModel)]="from" [max]="to || null" /></label>
          <label class="inline">To <input type="date" name="to" [(ngModel)]="to" [min]="from || null" /></label>
        }
        @if (d.canFilterCustomer) {
          <label class="inline">Customer
            <select name="customer" [(ngModel)]="customerId"><option [ngValue]="null">All customers</option>
              @for (c of customers(); track c.value) { <option [ngValue]="c.value">{{ c.label }}</option> }
            </select>
          </label>
        }
        @if (d.usesDays) { <label class="inline">Ends within <input type="number" name="days" [(ngModel)]="days" min="1" max="365" class="narrow" /> days</label> }
        <button class="btn primary" type="submit" [disabled]="busy()">{{ busy() ? 'Running…' : 'Run' }}</button>
        <button class="btn" type="button" (click)="exportCsv()" [disabled]="busy() || !result()">Export CSV</button>
      </form>
      @if (d.dateFilter) { <p class="muted small">Dates filter by: {{ d.dateFilter }} (both days included; leave empty for all time).</p> }
      @if (error()) { <div class="alert error" role="alert">{{ error() }}</div> }
      @if (result(); as r) {
        <p class="muted small">{{ r.rowCount }} {{ r.rowCount === 1 ? 'row' : 'rows' }} · generated {{ when(r.generatedAt) }}</p>
        @if (r.truncated) { <div class="alert info">Only the first {{ r.rows.length }} rows are shown; export or narrow the filters for the rest.</div> }
        @if (bars().length) {
          <section class="card"><app-bar-chart [data]="bars()" [valueType]="valueType()" [caption]="chartCaption()" /></section>
        }
        <app-table [rows]="r.rows" [columns]="columns()" empty="No records for these filters." />
      }
    }
  `
})
export class ReportsPage {
  private readonly api = inject(Api);
  private readonly toasts = inject(Toasts);
  private readonly lookups = inject(Lookups);
  /** ?report=code (bound from the query string). */
  readonly report = input<string>();
  readonly defs = signal<ReportDef[]>([]);
  readonly loaded = signal(false);
  readonly listError = signal<string | null>(null);
  readonly customers = signal<Option[]>([]);
  readonly result = signal<ReportResult | null>(null);
  readonly error = signal<string | null>(null);
  readonly busy = signal(false);
  from = ''; to = ''; customerId: number | null = null; days: number | null = 30;

  readonly selected = computed(() => this.defs().find(d => d.reportCode === this.report()) ?? null);
  readonly groups = computed(() => (['Recruitment', 'Staffing', 'HR'] as const)
    .map(c => ({ category: c, items: this.defs().filter(d => d.category === c) })).filter(g => g.items.length));
  readonly columns = computed<Column[]>(() => (this.result()?.columns ?? [])
    .map(c => ({ key: c.key, label: c.label, type: c.key === 'status' || c.key === 'jobStatus' || c.key === 'contractStatus' ? 'status' : c.type })));
  readonly bars = computed(() => { const r = this.result(); return r ? chartData(r.report, r.rows) : []; });
  readonly valueType = computed(() => { const r = this.result(); return r ? chartValueType(r.report, r.columns) : 'number'; });
  readonly chartCaption = computed(() => {
    const r = this.result(); if (!r?.report.chartLabel) return '';
    const col = (name: string | null) => r.columns.find(c => c.key === camel(name ?? ''))?.label ?? '';
    const value = r.report.chartAggregate === 'count' ? 'Number of rows' : (r.report.chartAggregate === 'sum' ? 'Total ' + col(r.report.chartValue).toLowerCase() : col(r.report.chartValue));
    return `${value} by ${col(r.report.chartLabel).toLowerCase()}${this.bars().length >= 25 ? ' (first 25)' : ''}`;
  });

  constructor() {
    void this.loadList();
    // a different report: clear the filters and run it
    effect(() => {
      const d = this.selected();
      untracked(() => {
        this.result.set(null); this.error.set(null); this.from = ''; this.to = ''; this.customerId = null; this.days = 30;
        if (d) { if (d.canFilterCustomer && !this.customers().length) void this.loadCustomers(); void this.run(); }
      });
    });
  }

  private async loadList(): Promise<void> {
    try { this.defs.set(await this.api.get<ReportDef[]>('/reports')); } catch (e) { this.listError.set(errorText(e)); } finally { this.loaded.set(true); }
  }
  private async loadCustomers(): Promise<void> { try { this.customers.set(await this.lookups.customers()); } catch { /* the filter stays at "All customers" */ } }

  private query(): string {
    const d = this.selected()!; const p = new URLSearchParams();
    if (d.dateFilter && this.from) p.set('from', this.from);
    if (d.dateFilter && this.to) p.set('to', this.to);
    if (d.canFilterCustomer && this.customerId) p.set('customerId', String(this.customerId));
    if (d.usesDays && this.days) p.set('days', String(this.days));
    const s = p.toString(); return s ? '?' + s : '';
  }
  private problem(): string | null {
    if (this.from && this.to && this.from > this.to) return 'The start date must not be after the end date.';
    if (this.selected()?.usesDays && (!this.days || this.days < 1 || this.days > 365)) return 'Days must be between 1 and 365.';
    return null;
  }

  async run(): Promise<void> {
    const d = this.selected(); if (!d) return;
    const p = this.problem(); if (p) { this.error.set(p); return; }
    this.busy.set(true); this.error.set(null);
    try { this.result.set(await this.api.get<ReportResult>('/reports/' + d.reportCode + this.query())); }
    catch (e) { this.result.set(null); this.error.set(errorText(e)); }
    finally { this.busy.set(false); }
  }
  async exportCsv(): Promise<void> {
    const d = this.selected(); if (!d) return;
    try { await this.api.download('/reports/' + d.reportCode + '/csv' + this.query(), `tams-${d.reportCode}.csv`); } catch (e) { this.toasts.error(e); }
  }
  when(iso: string): string { return formatDateTime(iso); }
}
