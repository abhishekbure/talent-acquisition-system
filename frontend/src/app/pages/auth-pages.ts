import { Component, inject, input, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Router, RouterLink } from '@angular/router';
import { Api, errorText, isApiError } from '../core/api';
import { Auth } from '../core/auth';

/** "Send a new confirmation link": always the same answer, whether or not the address exists or is already confirmed. */
@Component({
  selector: 'app-resend-link',
  imports: [FormsModule],
  template: `
    @if (sent()) {
      <div class="alert info" role="status">If an unconfirmed account exists for {{ email || 'that address' }}, a new confirmation link is on its way. Older links stop working.</div>
    } @else {
      <div class="resend">
        @if (askEmail()) { <input type="email" name="resendEmail" [(ngModel)]="email" placeholder="Your e-mail address" aria-label="E-mail for a new confirmation link" /> }
        <button class="btn" type="button" (click)="send()" [disabled]="busy()">Send a new confirmation link</button>
      </div>
      @if (error()) { <div class="alert error" role="alert">{{ error() }}</div> }
    }
  `
})
export class ResendLink {
  private readonly api = inject(Api);
  readonly address = input<string>('');
  readonly askEmail = input(false);
  email = '';
  readonly busy = signal(false);
  readonly sent = signal(false);
  readonly error = signal<string | null>(null);
  async send(): Promise<void> {
    const email = (this.askEmail() ? this.email : this.address()).trim();
    if (!email) { this.error.set('Enter your e-mail address.'); return; }
    this.email = email; this.busy.set(true); this.error.set(null);
    try { await this.api.post('/auth/resend-verification', { email }); this.sent.set(true); }
    catch (e) { this.error.set(errorText(e)); } finally { this.busy.set(false); }
  }
}

export const PASSWORD_RULE = 'At least 10 characters with an upper-case letter, a lower-case letter and a digit.';
export function passwordProblem(p: string): string | null {
  if (!p || p.length < 10 || !/[A-Z]/.test(p) || !/[a-z]/.test(p) || !/[0-9]/.test(p)) return PASSWORD_RULE;
  return null;
}

@Component({
  selector: 'app-login',
  imports: [FormsModule, RouterLink, ResendLink],
  template: `
    <div class="auth-page">
      <form class="auth-card" (ngSubmit)="submit()" novalidate>
        <h1>TAMS</h1>
        <p class="muted">Talent Acquisition Management System — sign in</p>
        @if (reason() === 'expired') { <div class="alert info">Your session ended. Please sign in again.</div> }
        @if (reason() === 'verified') { <div class="alert ok" role="status">Your e-mail address is confirmed. You can sign in now.</div> }
        @if (error()) { <div class="alert error" role="alert">{{ error() }}</div> }
        @if (unverified(); as addr) { <app-resend-link [address]="addr" /> }
        <div class="field"><label for="email">E-mail</label><input id="email" name="email" type="email" autocomplete="username" [(ngModel)]="email" required /></div>
        <div class="field"><label for="password">Password</label><input id="password" name="password" type="password" autocomplete="current-password" [(ngModel)]="password" required /></div>
        <button class="btn primary block" type="submit" [disabled]="busy()">{{ busy() ? 'Signing in…' : 'Sign in' }}</button>
        <div class="auth-links"><a routerLink="/forgot-password">Forgot password?</a><a routerLink="/register">New candidate? Create an account</a></div>
      </form>
    </div>
  `
})
export class LoginPage {
  private readonly auth = inject(Auth);
  private readonly router = inject(Router);
  readonly returnUrl = input<string>();
  readonly reason = input<string>();
  email = '';
  password = '';
  readonly busy = signal(false);
  readonly error = signal<string | null>(null);
  /** Set when the password was right but the address is not confirmed yet. */
  readonly unverified = signal<string | null>(null);

  async submit(): Promise<void> {
    if (!this.email.trim() || !this.password) { this.error.set('Enter your e-mail address and password.'); return; }
    this.busy.set(true); this.error.set(null); this.unverified.set(null);
    try {
      await this.auth.login(this.email.trim(), this.password);
      const target = this.returnUrl();
      await this.router.navigateByUrl(target && target.startsWith('/') && !target.startsWith('//') ? target : this.auth.homePath());
    } catch (e) {
      this.error.set(isApiError(e) && e.status === 429 ? 'This account is temporarily locked after repeated failed sign-ins. Try again in 15 minutes.' : errorText(e));
      if (isApiError(e) && e.code === 'email_unverified') this.unverified.set(this.email.trim());
    } finally {
      this.busy.set(false);
      this.password = '';
    }
  }
}

@Component({
  selector: 'app-register',
  imports: [FormsModule, RouterLink, ResendLink],
  template: `
    <div class="auth-page">
      @if (created(); as addr) {
        <div class="auth-card">
          <h1>Check your e-mail</h1>
          <div class="alert ok" role="status">Your account has been created. We have sent a confirmation link to <strong>{{ addr }}</strong>.</div>
          <p>Open the link to confirm that the address is yours, then sign in. The link works once and is valid for 24 hours.</p>
          <p class="muted small">Local development: e-mails are written as .eml files to <code>storage\\mail-outbox</code> when the notification sender runs.</p>
          <app-resend-link [address]="addr" />
          <div class="auth-links"><a routerLink="/login">Go to sign in</a></div>
        </div>
      } @else {
      <form class="auth-card" (ngSubmit)="submit()" novalidate>
        <h1>Create a candidate account</h1>
        <p class="muted">Recruiters, HR, customers and contractors receive their accounts from TAMS staff.</p>
        @if (error()) { <div class="alert error" role="alert">{{ error() }}</div> }
        <div class="two">
          <div class="field"><label for="fn">First name</label><input id="fn" name="fn" [(ngModel)]="m.firstName" maxlength="100" required /></div>
          <div class="field"><label for="ln">Last name</label><input id="ln" name="ln" [(ngModel)]="m.lastName" maxlength="100" required /></div>
        </div>
        <div class="field"><label for="em">E-mail</label><input id="em" name="em" type="email" autocomplete="username" [(ngModel)]="m.email" maxlength="256" required /></div>
        <div class="field"><label for="ph">Phone (optional)</label><input id="ph" name="ph" [(ngModel)]="m.phone" maxlength="30" /></div>
        <div class="field"><label for="pw">Password</label><input id="pw" name="pw" type="password" autocomplete="new-password" [(ngModel)]="m.password" required /><small class="hint">{{ rule }}</small></div>
        <div class="field"><label for="pw2">Repeat password</label><input id="pw2" name="pw2" type="password" autocomplete="new-password" [(ngModel)]="confirm" required /></div>
        <button class="btn primary block" type="submit" [disabled]="busy()">{{ busy() ? 'Creating…' : 'Create account' }}</button>
        <div class="auth-links"><a routerLink="/login">Back to sign in</a></div>
      </form>
      }
    </div>
  `
})
export class RegisterPage {
  private readonly auth = inject(Auth);
  readonly rule = PASSWORD_RULE;
  /** The address the confirmation link was sent to, once the account exists. */
  readonly created = signal<string | null>(null);
  m = { firstName: '', lastName: '', email: '', phone: '', password: '' };
  confirm = '';
  readonly busy = signal(false);
  readonly error = signal<string | null>(null);

  async submit(): Promise<void> {
    const m = this.m;
    if (!m.firstName.trim() || !m.lastName.trim() || !m.email.trim()) { this.error.set('First name, last name and e-mail are required.'); return; }
    const pp = passwordProblem(m.password);
    if (pp) { this.error.set(pp); return; }
    if (m.password !== this.confirm) { this.error.set('The two passwords do not match.'); return; }
    this.busy.set(true); this.error.set(null);
    try {
      const r = await this.auth.register({ email: m.email.trim(), password: m.password, firstName: m.firstName.trim(), lastName: m.lastName.trim(), phone: m.phone.trim() || undefined });
      this.created.set(r.email);
      this.m.password = ''; this.confirm = '';
    } catch (e) { this.error.set(errorText(e)); } finally { this.busy.set(false); }
  }
}

/**
 * Target of the e-mailed confirmation link (/verify-email?token=...). Confirming takes a click, so a mail scanner that
 * merely opens links cannot use up the one-time token.
 */
@Component({
  selector: 'app-verify-email',
  imports: [RouterLink, ResendLink],
  template: `
    <div class="auth-page">
      <div class="auth-card">
        <h1>Confirm your e-mail address</h1>
        @if (!token()) {
          <div class="alert error">This page needs the link from the confirmation e-mail.</div>
          <app-resend-link [askEmail]="true" />
        } @else if (error()) {
          <div class="alert error" role="alert">{{ error() }}</div>
          <app-resend-link [askEmail]="true" />
        } @else {
          <p>Confirm that this e-mail address belongs to you to activate your TAMS account.</p>
          <button class="btn primary block" type="button" (click)="confirm()" [disabled]="busy()">{{ busy() ? 'Confirming…' : 'Confirm my e-mail address' }}</button>
        }
        <div class="auth-links"><a routerLink="/login">Back to sign in</a></div>
      </div>
    </div>
  `
})
export class VerifyEmailPage {
  private readonly api = inject(Api);
  private readonly router = inject(Router);
  readonly token = input<string>();
  readonly busy = signal(false);
  readonly error = signal<string | null>(null);
  async confirm(): Promise<void> {
    this.busy.set(true); this.error.set(null);
    try {
      await this.api.post('/auth/verify-email', { token: this.token() });
      await this.router.navigate(['/login'], { queryParams: { reason: 'verified' } });
    } catch (e) { this.error.set(errorText(e)); } finally { this.busy.set(false); }
  }
}

@Component({
  selector: 'app-forgot',
  imports: [FormsModule, RouterLink],
  template: `
    <div class="auth-page">
      <form class="auth-card" (ngSubmit)="submit()" novalidate>
        <h1>Forgot password</h1>
        @if (done()) {
          <div class="alert info">If an account exists for that address, a password-reset message has been queued for it. The link is valid for a limited time and works once.</div>
        } @else {
          @if (error()) { <div class="alert error" role="alert">{{ error() }}</div> }
          <div class="field"><label for="em">E-mail</label><input id="em" name="em" type="email" [(ngModel)]="email" required /></div>
          <button class="btn primary block" type="submit" [disabled]="busy()">Send reset link</button>
        }
        <div class="auth-links"><a routerLink="/login">Back to sign in</a></div>
      </form>
    </div>
  `
})
export class ForgotPasswordPage {
  private readonly api = inject(Api);
  email = '';
  readonly busy = signal(false);
  readonly done = signal(false);
  readonly error = signal<string | null>(null);
  async submit(): Promise<void> {
    if (!this.email.trim()) { this.error.set('Enter your e-mail address.'); return; }
    this.busy.set(true); this.error.set(null);
    try { await this.api.post('/auth/forgot-password', { email: this.email.trim() }); this.done.set(true); }
    catch (e) { this.error.set(errorText(e)); } finally { this.busy.set(false); }
  }
}

@Component({
  selector: 'app-reset',
  imports: [FormsModule, RouterLink],
  template: `
    <div class="auth-page">
      <form class="auth-card" (ngSubmit)="submit()" novalidate>
        <h1>Choose a new password</h1>
        @if (done()) {
          <div class="alert ok">Your password has been changed. <a routerLink="/login">Sign in</a></div>
        } @else if (!token()) {
          <div class="alert error">This page needs the link from the password-reset message.</div>
        } @else {
          @if (error()) { <div class="alert error" role="alert">{{ error() }}</div> }
          <div class="field"><label for="pw">New password</label><input id="pw" name="pw" type="password" autocomplete="new-password" [(ngModel)]="password" /><small class="hint">{{ rule }}</small></div>
          <div class="field"><label for="pw2">Repeat new password</label><input id="pw2" name="pw2" type="password" autocomplete="new-password" [(ngModel)]="confirm" /></div>
          <button class="btn primary block" type="submit" [disabled]="busy()">Set password</button>
        }
        <div class="auth-links"><a routerLink="/login">Back to sign in</a></div>
      </form>
    </div>
  `
})
export class ResetPasswordPage {
  private readonly api = inject(Api);
  readonly token = input<string>();
  readonly rule = PASSWORD_RULE;
  password = '';
  confirm = '';
  readonly busy = signal(false);
  readonly done = signal(false);
  readonly error = signal<string | null>(null);
  async submit(): Promise<void> {
    const pp = passwordProblem(this.password);
    if (pp) { this.error.set(pp); return; }
    if (this.password !== this.confirm) { this.error.set('The two passwords do not match.'); return; }
    this.busy.set(true); this.error.set(null);
    try { await this.api.post('/auth/reset-password', { token: this.token(), newPassword: this.password }); this.done.set(true); }
    catch (e) { this.error.set(errorText(e)); } finally { this.busy.set(false); this.password = this.confirm = ''; }
  }
}
