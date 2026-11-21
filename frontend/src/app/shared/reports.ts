import { Component, computed, effect, inject, input, signal, untracked } from '@angular/core';
import { RouterLink } from '@angular/router';
import { Api, errorText } from '../core/api';
import { ValueType, formatValue } from '../core/format';

/** A report as listed by GET /reports (report.ReportDefinitions, filtered to the caller's roles). */
export interface ReportDef {
  reportCode: string; category: 'Recruitment' | 'Staffing' | 'HR'; title: string; description: string;
  dateFilter: string | null; usesDays: boolean; customerScoped: boolean; canFilterCustomer: boolean;
  chartLabel: string | null; chartValue: string | null; chartAggregate: 'value' | 'count' | 'sum';
}
export interface ReportColumn { key: string; label: string; type: ValueType; }
export interface ReportResult {
  report: ReportDef; columns: ReportColumn[]; rows: any[]; rowCount: number; truncated: boolean; generatedAt: string;
  from: string | null; to: string | null; customerId: number | null; days: number | null;
}
export interface Bar { label: string; value: number; }

/** Same rule as the API's JSON camel-casing (Newtonsoft): "SharePct" -> "sharePct", "HRName" -> "hrName". */
export function camel(name: string): string {
  const c = name.split('');
  const isUpper = (ch: string) => ch !== ch.toLowerCase();        // letters only: digits are not upper case
  for (let i = 0; i < c.length; i++) {
    if (i === 1 && !isUpper(c[i])) break;
    const hasNext = i + 1 < c.length;
    if (i > 0 && hasNext && !isUpper(c[i + 1])) { if (c[i + 1] === ' ') c[i] = c[i].toLowerCase(); break; }
    c[i] = c[i].toLowerCase();
  }
  return c.join('');
}

/** The bars a report's catalog entry asks for: one per row ('value'), or rows counted / summed per label. At most `max` bars. */
export function chartData(def: ReportDef | null | undefined, rows: any[], max = 25): Bar[] {
  if (!def?.chartLabel || !rows?.length) return [];
  const lk = camel(def.chartLabel), vk = def.chartValue ? camel(def.chartValue) : null;
  const label = (r: any) => (r[lk] === null || r[lk] === undefined || r[lk] === '' ? '(none)' : String(r[lk]));
  if (def.chartAggregate === 'value' && vk) {
    return rows.filter(r => r[vk] !== null && r[vk] !== undefined).slice(0, max).map(r => ({ label: label(r), value: Number(r[vk]) }));
  }
  const groups = new Map<string, number>();
  for (const r of rows) {
    const add = def.chartAggregate === 'sum' && vk ? Number(r[vk] ?? 0) : 1;
    groups.set(label(r), (groups.get(label(r)) ?? 0) + add);
  }
  return [...groups.entries()].map(([l, v]) => ({ label: l, value: v })).sort((a, b) => b.value - a.value).slice(0, max);
}

/** The display type of the charted value. */
export function chartValueType(def: ReportDef | null | undefined, columns: ReportColumn[]): ValueType {
  if (!def || def.chartAggregate === 'count' || !def.chartValue) return 'number';
  return columns.find(c => c.key === camel(def.chartValue!))?.type ?? 'number';
}

/**
 * Horizontal bar chart in plain HTML/CSS (no chart library, no external requests): text keeps its normal size at any
 * screen width, which a scaled SVG does not. The table next to it carries the same numbers.
 */
@Component({
  selector: 'app-bar-chart',
  template: `
    @if (bars().length) {
      <figure class="chart">
        <ul class="bars" [attr.aria-label]="caption()">
          @for (b of bars(); track $index) {
            <li>
              <span class="bar-label" [title]="b.label">{{ b.label }}</span>
              <span class="bar-track" aria-hidden="true"><span class="bar-fill" [style.width.%]="pct(b.value)"></span></span>
              <span class="bar-value">{{ fmt(b.value) }}</span>
            </li>
          }
        </ul>
        <figcaption class="muted small">{{ caption() }}</figcaption>
      </figure>
    }
  `
})
export class BarChart {
  readonly data = input<Bar[]>([]);
  readonly valueType = input<ValueType>('number');
  readonly caption = input('');
  readonly bars = computed(() => this.data().filter(b => Number.isFinite(b.value)));
  private readonly max = computed(() => Math.max(0, ...this.bars().map(b => b.value)));
  /** Bar length in % of the largest value; zero and negative values (e.g. already expired) get no bar but keep their number. */
  pct(v: number): number { const m = this.max(); return m > 0 && v > 0 ? Math.max(1, (v / m) * 100) : 0; }
  fmt(v: number): string { return formatValue(v, this.valueType()); }
}

/** A report's chart on a dashboard, with a link to the full report. */
@Component({
  selector: 'app-report-card',
  imports: [BarChart, RouterLink],
  template: `
    <section class="card">
      <div class="card-head"><h2>{{ result()?.report?.title ?? 'Report' }}</h2><a [routerLink]="'/' + slug() + '/reports'" [queryParams]="{ report: code() }">Open report →</a></div>
      @if (error()) { <div class="alert error">{{ error() }}</div> }
      @else if (result(); as r) {
        @if (bars().length) { <app-bar-chart [data]="bars()" [valueType]="valueType()" [caption]="r.report.description" /> }
        @else { <p class="muted">Nothing to show yet.</p> }
      }
    </section>
  `
})
export class ReportCard {
  private readonly api = inject(Api);
  readonly code = input.required<string>();
  readonly slug = input.required<string>();
  readonly result = signal<ReportResult | null>(null);
  readonly error = signal<string | null>(null);
  readonly bars = computed(() => { const r = this.result(); return r ? chartData(r.report, r.rows, 10) : []; });
  readonly valueType = computed(() => { const r = this.result(); return r ? chartValueType(r.report, r.columns) : 'number'; });
  constructor() {
    effect(() => { const c = this.code(); untracked(() => void this.load(c)); });
  }
  private async load(code: string): Promise<void> {
    try { this.result.set(await this.api.get<ReportResult>('/reports/' + code)); this.error.set(null); }
    catch (e) { this.error.set(errorText(e)); }
  }
}
