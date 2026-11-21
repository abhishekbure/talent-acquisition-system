import { Component, computed, input, output, signal } from '@angular/core';
import { truncatedAt } from '../core/api';
import { ValueType, formatValue, statusClass } from '../core/format';

export interface Column {
  key: string;
  label: string;
  type?: ValueType;
  /** Computed cell value instead of row[key]. */
  value?: (row: any) => unknown;
}

export interface RowAction {
  label: string;
  run: (row: any) => void;
  show?: (row: any) => boolean;
  kind?: 'primary' | 'danger';
}

/** Read-only grid with client-side filter/sort of the current page, optional server paging, row selection and per-row actions. */
@Component({
  selector: 'app-table',
  template: `
    @if (filter() && rows().length > 5) {
      <div class="table-tools"><input type="search" placeholder="Filter these rows" [value]="q()" (input)="q.set($any($event.target).value)" aria-label="Filter rows" /></div>
    }
    <div class="table-wrap">
      <table class="grid">
        <thead>
          <tr>
            @for (c of columns(); track c.key) {
              <th [class.num]="isNum(c)" (click)="sortBy(c.key)" [attr.aria-sort]="sortKey() === c.key ? (sortDir() > 0 ? 'ascending' : 'descending') : null">
                {{ c.label }}@if (sortKey() === c.key) { <span class="arrow">{{ sortDir() > 0 ? '▲' : '▼' }}</span> }
              </th>
            }
            @if (actions().length) { <th class="actions-col"><span class="sr-only">Actions</span></th> }
          </tr>
        </thead>
        <tbody>
          @for (r of view(); track $index) {
            <tr [class.clickable]="selectable()" [class.selected]="selectable() && keyField() && r[keyField()] === selectedKey()" (click)="selectable() && select.emit(r)">
              @for (c of columns(); track c.key) {
                <td [class.num]="isNum(c)" [class.nowrap]="noWrap(c)">
                  @if (c.type === 'status') { <span [class]="badge(raw(r, c))">{{ text(r, c) }}</span> } @else { {{ text(r, c) }} }
                </td>
              }
              @if (actions().length) {
                <td class="actions-col">
                  @for (a of actions(); track a.label) {
                    @if (!a.show || a.show(r)) {
                      <button type="button" class="btn sm" [class.primary]="a.kind === 'primary'" [class.danger]="a.kind === 'danger'" (click)="$event.stopPropagation(); a.run(r)">{{ a.label }}</button>
                    }
                  }
                </td>
              }
            </tr>
          } @empty {
            <tr><td class="empty" [attr.colspan]="columns().length + (actions().length ? 1 : 0)">{{ empty() }}</td></tr>
          }
        </tbody>
      </table>
    </div>
    @if (capped(); as n) {
      <p class="hint capped" role="status">Showing the newest {{ n }} records. Narrow the filters to see older ones.</p>
    }
    @if (total() !== null && total()! > pageSize()) {
      <div class="pager">
        <button type="button" class="btn sm" [disabled]="page() <= 1" (click)="pageChange.emit(page() - 1)">Previous</button>
        <span>Page {{ page() }} of {{ pages() }} · {{ total() }} records</span>
        <button type="button" class="btn sm" [disabled]="page() >= pages()" (click)="pageChange.emit(page() + 1)">Next</button>
      </div>
    }
  `
})
export class DataTable {
  readonly rows = input<any[]>([]);
  readonly columns = input.required<Column[]>();
  readonly actions = input<RowAction[]>([]);
  readonly selectable = input(false);
  readonly keyField = input('');
  readonly selectedKey = input<unknown>(null);
  readonly total = input<number | null>(null);
  readonly page = input(1);
  readonly pageSize = input(25);
  readonly filter = input(true);
  readonly empty = input('No records found.');
  readonly select = output<any>();
  readonly pageChange = output<number>();

  readonly q = signal('');
  readonly sortKey = signal<string | null>(null);
  readonly sortDir = signal(1);
  readonly pages = computed(() => Math.max(1, Math.ceil((this.total() ?? 0) / this.pageSize())));
  /** Set when the API capped this list (Phase 13). */
  readonly capped = computed(() => truncatedAt(this.rows()));

  readonly view = computed(() => {
    const q = this.q().trim().toLowerCase();
    const cols = this.columns();
    let list = this.rows() ?? [];
    if (q) list = list.filter(r => cols.some(c => this.text(r, c).toLowerCase().includes(q)));
    const k = this.sortKey();
    if (k) {
      const c = cols.find(x => x.key === k)!;
      const dir = this.sortDir();
      list = [...list].sort((a, b) => cmp(this.raw(a, c), this.raw(b, c)) * dir);
    }
    return list;
  });

  sortBy(key: string): void {
    if (this.sortKey() === key) this.sortDir.set(-this.sortDir()); else { this.sortKey.set(key); this.sortDir.set(1); }
  }
  raw(r: any, c: Column): unknown { return c.value ? c.value(r) : r?.[c.key]; }
  text(r: any, c: Column): string { return formatValue(this.raw(r, c), c.type ?? 'text', r?.currency); }
  badge(v: unknown): string { return statusClass(v); }
  noWrap(c: Column): boolean { return !!c.type && c.type !== 'text'; }
  isNum(c: Column): boolean { return c.type === 'money' || c.type === 'number' || c.type === 'hours' || c.type === 'days'; }
}

function cmp(a: unknown, b: unknown): number {
  if (a === b) return 0;
  if (a === null || a === undefined) return 1;
  if (b === null || b === undefined) return -1;
  if (typeof a === 'number' && typeof b === 'number') return a - b;
  return String(a).localeCompare(String(b), undefined, { numeric: true });
}
