import { Component, effect, inject, input, signal, untracked } from '@angular/core';
import { Api, errorText } from '../core/api';
import { ValueType, formatValue, statusClass } from '../core/format';
import { Toasts } from '../core/ui';

@Component({
  selector: 'app-toasts',
  template: `
    <div class="toasts" aria-live="polite">
      @for (t of toasts.items(); track t.id) {
        <div [class]="'toast ' + t.kind" role="status">
          <span>{{ t.text }}</span>
          <button type="button" class="link" (click)="toasts.dismiss(t.id)" aria-label="Dismiss">×</button>
        </div>
      }
    </div>
  `
})
export class ToastHost { readonly toasts = inject(Toasts); }

export interface DetailField { key: string; label: string; type?: ValueType; value?: (d: any) => unknown; wide?: boolean; }

/** Label/value grid for one record. */
@Component({
  selector: 'app-details',
  template: `
    <dl class="details">
      @for (f of fields(); track f.key) {
        <div [class.wide]="f.wide">
          <dt>{{ f.label }}</dt>
          <dd>
            @if (f.type === 'status') { <span [class]="badge(val(f))">{{ text(f) }}</span> } @else { {{ text(f) }} }
          </dd>
        </div>
      }
    </dl>
  `
})
export class DetailList {
  readonly data = input<any>(null);
  readonly fields = input.required<DetailField[]>();
  val(f: DetailField): unknown { const d = this.data(); return f.value ? f.value(d) : d?.[f.key]; }
  text(f: DetailField): string { return formatValue(this.val(f), f.type ?? 'text', this.data()?.currency); }
  badge(v: unknown): string { return statusClass(v); }
}

interface Metric { metricKey: string; label: string; value: number; unit: string; }

/** Dashboard cards: every number comes from report.usp_Dashboard for the signed-in user and role. */
@Component({
  selector: 'app-metrics',
  template: `
    @if (error()) { <div class="alert error">{{ error() }}</div> }
    <div class="metrics" [attr.aria-busy]="loading()">
      @for (m of metrics(); track m.metricKey) {
        <div class="metric" [attr.data-key]="m.metricKey">
          <div class="metric-value">{{ show(m) }}</div>
          <div class="metric-label">{{ m.label }}</div>
        </div>
      }
    </div>
  `
})
export class Metrics {
  private readonly api = inject(Api);
  readonly role = input.required<string>();
  readonly metrics = signal<Metric[]>([]);
  readonly loading = signal(false);
  readonly error = signal<string | null>(null);

  constructor() {
    effect(() => { const r = this.role(); untracked(() => void this.load(r)); });
  }

  async load(role: string): Promise<void> {
    this.loading.set(true); this.error.set(null);
    try { this.metrics.set(await this.api.get<Metric[]>('/dashboards/' + role)); }
    catch (e) { this.error.set('Dashboard figures could not be loaded: ' + errorText(e)); }
    finally { this.loading.set(false); }
  }

  show(m: Metric): string {
    if (m.unit === 'currency') return formatValue(m.value, 'money');
    if (m.unit === 'hours') return formatValue(m.value, 'hours');
    return formatValue(m.value, 'number');
  }
}
