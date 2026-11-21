import { Component, OnInit, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, errorText } from '../core/api';
import { Auth, ROLE_LABEL } from '../core/auth';
import { Toasts } from '../core/ui';
import { DataTable, Column, RowAction } from '../shared/table';
import { PASSWORD_RULE, passwordProblem } from './auth-pages';
import { formatDateTime, humanize } from '../core/format';

/** How the e-mail copy of an in-app notification stands (notify.NotificationQueue.Status). */
export const EMAIL_LABEL: Record<string, string> = { Pending: 'Queued', Processing: 'Sending', Sent: 'Sent', Failed: 'Not delivered', Cancelled: 'Not sent' };

@Component({
  selector: 'app-notifications',
  imports: [DataTable, FormsModule],
  template: `
    <div class="page-head">
      <h1>Notifications</h1>
      <div class="tools">
        <label class="inline"><input type="checkbox" [(ngModel)]="unreadOnly" (change)="load()" /> Unread only</label>
        <button class="btn" type="button" (click)="readAll()">Mark all as read</button>
      </div>
    </div>
    <p class="muted">Messages from TAMS (interview invitations, decisions, offers, approvals). Each one is also sent to your e-mail address; select a message to read it.</p>
    <app-table [rows]="rows()" [columns]="cols" [actions]="actions" [selectable]="true" keyField="notificationId" [selectedKey]="sel()?.notificationId" (select)="open($event)" empty="No notifications." />
    @if (sel(); as n) {
      <section class="card">
        <h2>{{ n.subject }}</h2>
        <p class="message-body">{{ n.body }}</p>
        <p class="muted small">{{ emailText(n) }}</p>
      </section>
    }
  `
})
export class NotificationsPage implements OnInit {
  private readonly api = inject(Api);
  private readonly auth = inject(Auth);
  private readonly toasts = inject(Toasts);
  readonly rows = signal<any[]>([]);
  readonly sel = signal<any>(null);
  unreadOnly = false;
  readonly cols: Column[] = [
    { key: 'createdAt', label: 'Received', type: 'datetime' },
    { key: 'subject', label: 'Subject' },
    { key: 'relatedEntityType', label: 'About', value: r => r.relatedEntityType ? humanize(r.relatedEntityType) : '' },
    { key: 'emailStatus', label: 'E-mail', value: r => EMAIL_LABEL[r.emailStatus] ?? r.emailStatus },
    { key: 'isRead', label: 'Read', type: 'bool' }
  ];
  readonly actions: RowAction[] = [{ label: 'Mark read', show: r => !r.isRead, run: r => this.markRead(r) }];

  emailText(n: any): string {
    return n.emailStatus === 'Sent' ? `E-mailed to you on ${formatDateTime(n.emailedAt)}.` : `E-mail: ${(EMAIL_LABEL[n.emailStatus] ?? n.emailStatus).toLowerCase()}.`;
  }
  async open(n: any): Promise<void> {
    this.sel.set(n);
    if (!n.isRead) await this.markRead(n);
  }

  ngOnInit(): void { void this.load(); }
  async load(): Promise<void> {
    try { this.rows.set(await this.api.get('/notifications', { unreadOnly: this.unreadOnly, top: 100 })); } catch (e) { this.toasts.error(e); }
  }
  async markRead(r: any): Promise<void> {
    try { await this.api.post(`/notifications/${r.notificationId}/read`); await this.load(); await this.auth.refresh(); } catch (e) { this.toasts.error(e); }
  }
  async readAll(): Promise<void> {
    try { await this.api.post('/notifications/read-all'); this.toasts.ok('All notifications marked as read.'); await this.load(); await this.auth.refresh(); } catch (e) { this.toasts.error(e); }
  }
}

@Component({
  selector: 'app-account',
  imports: [FormsModule],
  template: `
    <h1>My account</h1>
    @if (auth.user(); as u) {
      <dl class="details">
        <div><dt>Name</dt><dd>{{ u.displayName }}</dd></div>
        <div><dt>E-mail</dt><dd>{{ u.email }}</dd></div>
        <div><dt>Roles</dt><dd>{{ roles() }}</dd></div>
        @if (u.customerName) { <div><dt>Customer</dt><dd>{{ u.customerName }}</dd></div> }
        <div class="wide"><dt>Permissions</dt><dd>{{ u.permissions.join(', ') || '—' }}</dd></div>
      </dl>
    }
    <section class="card narrow">
      <h2>Change password</h2>
      <form (ngSubmit)="change()" novalidate>
        @if (error()) { <div class="alert error" role="alert">{{ error() }}</div> }
        <div class="field"><label for="cur">Current password</label><input id="cur" name="cur" type="password" autocomplete="current-password" [(ngModel)]="current" /></div>
        <div class="field"><label for="np">New password</label><input id="np" name="np" type="password" autocomplete="new-password" [(ngModel)]="next" /><small class="hint">{{ rule }}</small></div>
        <div class="field"><label for="np2">Repeat new password</label><input id="np2" name="np2" type="password" autocomplete="new-password" [(ngModel)]="confirm" /></div>
        <button class="btn primary" type="submit" [disabled]="busy()">Change password</button>
      </form>
    </section>
  `
})
export class AccountPage {
  readonly auth = inject(Auth);
  private readonly api = inject(Api);
  private readonly toasts = inject(Toasts);
  readonly rule = PASSWORD_RULE;
  current = ''; next = ''; confirm = '';
  readonly busy = signal(false);
  readonly error = signal<string | null>(null);
  roles(): string { return (this.auth.user()?.roles ?? []).map(r => ROLE_LABEL[r]).join(', '); }

  async change(): Promise<void> {
    if (!this.current) { this.error.set('Enter your current password.'); return; }
    const pp = passwordProblem(this.next);
    if (pp) { this.error.set(pp); return; }
    if (this.next !== this.confirm) { this.error.set('The two new passwords do not match.'); return; }
    this.busy.set(true); this.error.set(null);
    try {
      await this.api.post('/auth/change-password', { currentPassword: this.current, newPassword: this.next });
      this.toasts.ok('Password changed.');
      this.current = this.next = this.confirm = '';
    } catch (e) { this.error.set(errorText(e)); } finally { this.busy.set(false); }
  }
}
