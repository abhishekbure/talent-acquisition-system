/** Formatting and date helpers shared by tables, detail lists and forms. */

import { Pipe, PipeTransform } from '@angular/core';

export type ValueType = 'text' | 'date' | 'datetime' | 'money' | 'number' | 'hours' | 'status' | 'bool' | 'percent' | 'days';

const money = new Map<string, Intl.NumberFormat>();
function moneyFmt(cur: string): Intl.NumberFormat {
  let f = money.get(cur);
  if (!f) { f = new Intl.NumberFormat('en-IN', { style: 'currency', currency: cur, maximumFractionDigits: 2 }); money.set(cur, f); }
  return f;
}
const num = new Intl.NumberFormat('en-IN', { maximumFractionDigits: 2 });

export function formatValue(v: unknown, type: ValueType = 'text', currency = 'INR'): string {
  if (v === null || v === undefined || v === '') return '—';
  switch (type) {
    case 'money': return moneyFmt(currency || 'INR').format(Number(v));
    case 'number': return num.format(Number(v));
    case 'hours': return num.format(Number(v)) + ' h';
    case 'percent': return num.format(Number(v)) + ' %';
    case 'days': return num.format(Number(v)) + (Math.abs(Number(v)) === 1 ? ' day' : ' days');
    case 'bool': return v === true || v === 1 || v === '1' ? 'Yes' : 'No';
    case 'date': return formatDate(String(v));
    case 'datetime': return formatDateTime(String(v));
    case 'status': return statusText(String(v));
    default: return String(v);
  }
}

/** DATE columns arrive as "yyyy-MM-ddT00:00:00Z": show the calendar date, never shifted by time zone. */
export function formatDate(iso: string): string {
  const d = new Date(iso.substring(0, 10) + 'T00:00:00Z');
  if (isNaN(d.getTime())) return iso;
  return d.toLocaleDateString('en-IN', { timeZone: 'UTC', day: '2-digit', month: 'short', year: 'numeric' });
}

/** DATETIME2 values are UTC: show them in the browser's local time. */
export function formatDateTime(iso: string): string {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  return d.toLocaleString('en-IN', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

/** yyyy-MM-dd of a local calendar date. */
export function isoDate(d: Date): string {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

export function addDays(d: Date, n: number): Date { const x = new Date(d); x.setDate(x.getDate() + n); return x; }

/** Monday of the week containing d (ISO weeks, as the database enforces). */
export function mondayOf(d: Date): Date {
  const x = new Date(d.getFullYear(), d.getMonth(), d.getDate());
  const diff = (x.getDay() + 6) % 7;
  return addDays(x, -diff);
}

/** Value for <input type="datetime-local"> from a Date. */
export function localDateTimeInput(d: Date): string {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${isoDate(d)}T${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** Converts a datetime-local value (browser time) to an ISO UTC string for the API. */
export function localToUtcIso(v: string): string { return new Date(v).toISOString(); }

/** "2026-11-16T00:00:00Z" -> "2026-11-16" */
export function dateOnly(iso: string | null | undefined): string { return iso ? iso.substring(0, 10) : ''; }

export function statusClass(s: unknown): string {
  return 'badge s-' + String(s ?? '').toLowerCase().replace(/[^a-z]/g, '');
}

export function humanize(s: string): string {
  return s.replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2').replace(/([a-z])([A-Z])/g, '$1 $2');
}

/** A status code as words, as the filters and detail panels show it: "PendingApproval" -> "Pending approval". */
export function statusText(s: string): string {
  const h = humanize(s);
  return h.charAt(0) + h.slice(1).toLowerCase();
}

/** Template form of statusText, for filter lists: {{ s | statusText }} shows "OfferStage" as "Offer stage" (the value sent stays the code). */
@Pipe({ name: 'statusText' })
export class StatusTextPipe implements PipeTransform {
  transform(s: string): string { return statusText(s); }
}
