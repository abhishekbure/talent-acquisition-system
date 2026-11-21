import { Injectable, signal } from '@angular/core';
import { errorText } from './api';

export interface Toast { id: number; kind: 'ok' | 'error' | 'info'; text: string; }

@Injectable({ providedIn: 'root' })
export class Toasts {
  readonly items = signal<Toast[]>([]);
  private seq = 0;

  ok(text: string): void { this.push('ok', text, 4000); }
  info(text: string): void { this.push('info', text, 6000); }
  error(e: unknown): void { this.push('error', typeof e === 'string' ? e : errorText(e), 9000); }
  dismiss(id: number): void { this.items.update(l => l.filter(t => t.id !== id)); }

  private push(kind: Toast['kind'], text: string, ms: number): void {
    const id = ++this.seq;
    this.items.update(l => [...l.slice(-3), { id, kind, text }]);
    setTimeout(() => this.dismiss(id), ms);
  }
}

export interface Option { value: any; label: string; }

export interface FieldDef {
  key: string;
  label: string;
  type?: 'text' | 'email' | 'password' | 'textarea' | 'number' | 'date' | 'datetime' | 'select' | 'multiselect' | 'checkbox' | 'rows';
  required?: boolean;
  min?: number;
  max?: number;
  step?: number;
  maxLength?: number;
  value?: any;
  hint?: string;
  placeholder?: string;
  /** Static options, or a loader called when the dialog opens. */
  options?: Option[] | (() => Promise<Option[]>);
  /** Sub-fields of a repeatable "rows" field (e.g. job skills). */
  rows?: FieldDef[];
  showIf?: (values: any) => boolean;
}

export interface DialogConfig {
  title: string;
  message?: string;
  fields?: FieldDef[];
  submitLabel?: string;
  danger?: boolean;
  wide?: boolean;
  /** Runs the real API call. The dialog stays open and shows the server's message if it fails. */
  submit: (values: any) => Promise<unknown>;
}

export interface DialogState { config: DialogConfig; resolve: (v: unknown) => void; }

/** One modal at a time, rendered by <app-dialog-host> in the shell. */
@Injectable({ providedIn: 'root' })
export class Dialogs {
  readonly current = signal<DialogState | null>(null);

  /** Resolves with the submit result (truthy marker if the call returned nothing) or undefined when cancelled. */
  open(config: DialogConfig): Promise<unknown> {
    return new Promise(resolve => this.current.set({ config, resolve }));
  }

  confirm(title: string, message: string, action: () => Promise<unknown>, submitLabel = 'Confirm', danger = false): Promise<unknown> {
    return this.open({ title, message, submitLabel, danger, submit: action });
  }

  close(result: unknown): void {
    const s = this.current();
    this.current.set(null);
    s?.resolve(result);
  }
}
