import { Component, effect, inject, signal, untracked } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { errorText, isApiError } from '../core/api';
import { localToUtcIso } from '../core/format';
import { DialogConfig, Dialogs, FieldDef, Option } from '../core/ui';

/** Renders the current dialog from Dialogs: declared fields, client checks, then the real API call; server errors stay in the dialog. */
@Component({
  selector: 'app-dialog-host',
  imports: [FormsModule],
  template: `
    @if (dlg.current(); as s) {
      <div class="backdrop" (click)="cancel()"></div>
      <div class="dialog" [class.wide]="s.config.wide" role="dialog" aria-modal="true" [attr.aria-label]="s.config.title">
        <form (ngSubmit)="submit(s.config)" novalidate>
          <h2>{{ s.config.title }}</h2>
          @if (s.config.message) { <p class="dialog-msg">{{ s.config.message }}</p> }
          @for (f of s.config.fields ?? []; track f.key) {
            @if (visible(f)) {
              <div class="field" [class.check]="f.type === 'checkbox'" [class.invalid]="fieldErrors()[f.key]">
                @switch (f.type) {
                  @case ('checkbox') {
                    <label><input type="checkbox" [name]="f.key" [(ngModel)]="values[f.key]" /> {{ f.label }}</label>
                  }
                  @case ('textarea') {
                    <label [for]="'f_' + f.key">{{ f.label }}@if (f.required) {<span class="req">*</span>}</label>
                    <textarea [id]="'f_' + f.key" [name]="f.key" rows="3" [attr.maxlength]="f.maxLength ?? null" [placeholder]="f.placeholder ?? ''" [(ngModel)]="values[f.key]"></textarea>
                  }
                  @case ('select') {
                    <label [for]="'f_' + f.key">{{ f.label }}@if (f.required) {<span class="req">*</span>}</label>
                    @if (optionsFor(f.key).length > 12) {
                      <input type="search" class="opt-filter" placeholder="Type to narrow the list" [name]="f.key + '_q'" [(ngModel)]="optFilter[f.key]" />
                    }
                    <select [id]="'f_' + f.key" [name]="f.key" [(ngModel)]="values[f.key]">
                      <option [ngValue]="null">— select —</option>
                      @for (o of filtered(f.key); track o.value) { <option [ngValue]="o.value">{{ o.label }}</option> }
                    </select>
                  }
                  @case ('multiselect') {
                    <span class="label">{{ f.label }}@if (f.required) {<span class="req">*</span>}</span>
                    <div class="checklist">
                      @for (o of optionsFor(f.key); track o.value) {
                        <label><input type="checkbox" [checked]="isChecked(f.key, o.value)" (change)="toggle(f.key, o.value)" /> {{ o.label }}</label>
                      } @empty { <span class="muted">No options available.</span> }
                    </div>
                  }
                  @case ('rows') {
                    <span class="label">{{ f.label }}</span>
                    <table class="rows-table">
                      <thead><tr>@for (sf of f.rows ?? []; track sf.key) { <th>{{ sf.label }}</th> }<th></th></tr></thead>
                      <tbody>
                        @for (row of values[f.key]; track $index; let i = $index) {
                          <tr>
                            @for (sf of f.rows ?? []; track sf.key) {
                              <td>
                                @if (sf.type === 'checkbox') {
                                  <input type="checkbox" [name]="f.key + i + sf.key" [(ngModel)]="row[sf.key]" [attr.aria-label]="sf.label" />
                                } @else {
                                  <input [type]="sf.type === 'number' ? 'number' : 'text'" [name]="f.key + i + sf.key" [attr.step]="sf.step ?? null" [attr.min]="sf.min ?? null" [(ngModel)]="row[sf.key]" [attr.aria-label]="sf.label" />
                                }
                              </td>
                            }
                            <td><button type="button" class="btn sm" (click)="removeRow(f.key, i)">Remove</button></td>
                          </tr>
                        }
                      </tbody>
                    </table>
                    <button type="button" class="btn sm" (click)="addRow(f)">Add row</button>
                  }
                  @default {
                    <label [for]="'f_' + f.key">{{ f.label }}@if (f.required) {<span class="req">*</span>}</label>
                    <input [id]="'f_' + f.key" [name]="f.key" [type]="inputType(f)" [attr.min]="f.min ?? null" [attr.max]="f.max ?? null" [attr.step]="f.step ?? null"
                           [attr.maxlength]="f.maxLength ?? null" [placeholder]="f.placeholder ?? ''" [attr.autocomplete]="f.type === 'password' ? 'new-password' : null" [(ngModel)]="values[f.key]" />
                  }
                }
                @if (f.hint) { <small class="hint">{{ f.hint }}</small> }
                @if (fieldErrors()[f.key]) { <small class="field-error">{{ fieldErrors()[f.key] }}</small> }
              </div>
            }
          }
          @if (error()) { <div class="alert error" role="alert">{{ error() }}</div> }
          <div class="dialog-actions">
            <button type="button" class="btn" (click)="cancel()" [disabled]="busy()">Cancel</button>
            <button type="submit" class="btn" [class.primary]="!s.config.danger" [class.danger]="s.config.danger" [disabled]="busy()">{{ busy() ? 'Working…' : (s.config.submitLabel ?? 'Save') }}</button>
          </div>
        </form>
      </div>
    }
  `
})
export class DialogHost {
  readonly dlg = inject(Dialogs);
  values: any = {};
  optFilter: Record<string, string> = {};
  readonly opts = signal<Record<string, Option[]>>({});
  readonly busy = signal(false);
  readonly error = signal<string | null>(null);
  readonly fieldErrors = signal<Record<string, string>>({});

  constructor() {
    effect(() => {
      const s = this.dlg.current();
      if (s) untracked(() => void this.init(s.config));
    });
  }

  private async init(cfg: DialogConfig): Promise<void> {
    this.error.set(null); this.fieldErrors.set({}); this.busy.set(false); this.optFilter = {};
    const v: any = {};
    for (const f of cfg.fields ?? []) {
      if (f.type === 'rows') v[f.key] = (f.value ?? []).map((r: any) => ({ ...r }));
      else if (f.type === 'multiselect') v[f.key] = [...(f.value ?? [])];
      else if (f.type === 'checkbox') v[f.key] = !!f.value;
      else v[f.key] = f.value ?? null;
    }
    this.values = v;
    const loaded: Record<string, Option[]> = {};
    for (const f of cfg.fields ?? []) {
      if (!f.options) continue;
      try { loaded[f.key] = typeof f.options === 'function' ? await f.options() : f.options; }
      catch (e) { loaded[f.key] = []; this.error.set('Could not load the choices for "' + f.label + '": ' + errorText(e)); }
    }
    this.opts.set(loaded);
  }

  visible(f: FieldDef): boolean { return !f.showIf || f.showIf(this.values); }
  optionsFor(key: string): Option[] { return this.opts()[key] ?? []; }
  inputType(f: FieldDef): string { return f.type === 'datetime' ? 'datetime-local' : (f.type ?? 'text'); }
  filtered(key: string): Option[] {
    const q = (this.optFilter[key] ?? '').trim().toLowerCase();
    const all = this.opts()[key] ?? [];
    return q ? all.filter(o => o.label.toLowerCase().includes(q) || o.value === this.values[key]) : all;
  }
  isChecked(key: string, v: unknown): boolean { return (this.values[key] as unknown[]).includes(v); }
  toggle(key: string, v: unknown): void {
    const list = this.values[key] as unknown[];
    this.values[key] = list.includes(v) ? list.filter(x => x !== v) : [...list, v];
  }
  addRow(f: FieldDef): void {
    const r: any = {};
    for (const sf of f.rows ?? []) r[sf.key] = sf.type === 'checkbox' ? !!sf.value : (sf.value ?? null);
    this.values[f.key] = [...this.values[f.key], r];
  }
  removeRow(key: string, i: number): void { this.values[key] = (this.values[key] as unknown[]).filter((_, j) => j !== i); }

  cancel(): void { if (!this.busy()) this.dlg.close(undefined); }

  async submit(cfg: DialogConfig): Promise<void> {
    const errs = this.validate(cfg.fields ?? []);
    this.fieldErrors.set(errs);
    if (Object.keys(errs).length) { this.error.set('Please correct the highlighted fields.'); return; }
    this.error.set(null); this.busy.set(true);
    try {
      const out = await cfg.submit(this.collect(cfg.fields ?? []));
      this.busy.set(false);
      this.dlg.close(out ?? true);
    } catch (e) {
      this.busy.set(false);
      this.error.set(errorText(e));
      if (isApiError(e) && e.details) {
        const fe: Record<string, string> = {};
        for (const [k, msgs] of Object.entries(e.details)) {
          const key = k.replace(/^body\./i, '');
          const f = (cfg.fields ?? []).find(x => x.key.toLowerCase() === key.toLowerCase());
          if (f) fe[f.key] = msgs.join(' ');
        }
        this.fieldErrors.set(fe);
      }
    }
  }

  private validate(fields: FieldDef[]): Record<string, string> {
    const e: Record<string, string> = {};
    for (const f of fields) {
      if (!this.visible(f)) continue;
      const v = this.values[f.key];
      const empty = v === null || v === undefined || (typeof v === 'string' && v.trim() === '') || (Array.isArray(v) && v.length === 0);
      if (f.required && empty && f.type !== 'checkbox') { e[f.key] = 'Required.'; continue; }
      if (empty) continue;
      if (f.type === 'number') {
        const n = Number(v);
        if (isNaN(n)) e[f.key] = 'Enter a number.';
        else if (f.min !== undefined && n < f.min) e[f.key] = `Must be at least ${f.min}.`;
        else if (f.max !== undefined && n > f.max) e[f.key] = `Must be at most ${f.max}.`;
      }
      if (f.type === 'email' && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(String(v))) e[f.key] = 'Enter a valid e-mail address.';
    }
    return e;
  }

  private collect(fields: FieldDef[]): any {
    const out: any = {};
    for (const f of fields) {
      if (!this.visible(f)) continue;
      out[f.key] = convert(f, this.values[f.key]);
      if (f.type === 'rows') out[f.key] = (this.values[f.key] as any[]).map(r => {
        const o: any = {};
        for (const sf of f.rows ?? []) o[sf.key] = convert(sf, r[sf.key]);
        return o;
      }).filter(o => Object.values(o).some(x => x !== null && x !== false));
    }
    return out;
  }
}

function convert(f: FieldDef, v: any): any {
  if (f.type === 'checkbox') return !!v;
  if (v === undefined || v === null || (typeof v === 'string' && v.trim() === '')) return f.type === 'multiselect' ? [] : null;
  if (f.type === 'number') return Number(v);
  if (f.type === 'datetime') return localToUtcIso(String(v));
  if (typeof v === 'string') return v.trim();
  return v;
}
