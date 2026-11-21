import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { Router, provideRouter } from '@angular/router';
import { Auth } from '../core/auth';
import { EmailQueuePage } from './admin';
import { LoginPage, RegisterPage, VerifyEmailPage } from './auth-pages';
import { EMAIL_LABEL } from './common';

/** Phase 9: e-mail confirmation in the UI (isolated: HTTP is Angular's test controller). */
describe('e-mail confirmation pages', () => {
  let http: HttpTestingController;
  beforeEach(() => {
    sessionStorage.clear();
    TestBed.configureTestingModule({ providers: [provideRouter([]), provideHttpClient(), provideHttpClientTesting()] });
    http = TestBed.inject(HttpTestingController);
  });
  afterEach(() => { http.verify(); sessionStorage.clear(); });

  it('registration does not sign in: it asks the person to confirm the e-mailed link', async () => {
    const f = TestBed.createComponent(RegisterPage); const c = f.componentInstance; f.detectChanges();
    c.m = { firstName: 'Tara', lastName: 'Menon', email: ' tara@x.example ', phone: '', password: 'Good#Pass123' }; c.confirm = 'Good#Pass123';
    const p = c.submit();
    const req = http.expectOne('/api/v1/auth/register');
    expect(req.request.body.email).toBe('tara@x.example');
    req.flush({ email: 'tara@x.example', verificationRequired: true, message: 'Account created.' }, { status: 201, statusText: 'Created' });
    await p; f.detectChanges();
    // http.verify() in afterEach proves no sign-in request was made
    expect(TestBed.inject(Auth).isSignedIn()).toBeFalse();
    const text = (f.nativeElement as HTMLElement).textContent ?? '';
    expect(text).toContain('Check your e-mail');
    expect(text).toContain('tara@x.example');
    expect(text).toContain('storage\\mail-outbox');          // the backslash survives the template (found in the live check)
    expect(c.m.password).toBe('');
  });

  it('a sign-in refused for an unconfirmed address offers a new link, with the same neutral answer', async () => {
    const f = TestBed.createComponent(LoginPage); const c = f.componentInstance; f.detectChanges();
    c.email = 'tara@x.example'; c.password = 'Good#Pass123';
    const p = c.submit();
    http.expectOne('/api/v1/auth/login').flush({ code: 'email_unverified', message: 'Please confirm your e-mail address first.', correlationId: 'abc' }, { status: 403, statusText: 'Forbidden' });
    await p; f.detectChanges();
    const el = f.nativeElement as HTMLElement;
    const button = Array.from(el.querySelectorAll('button')).find(b => b.textContent?.includes('new confirmation link')) as HTMLButtonElement;
    expect(button).toBeTruthy();
    button.click();
    const req = http.expectOne('/api/v1/auth/resend-verification');
    expect(req.request.body).toEqual({ email: 'tara@x.example' });
    req.flush({ message: 'ok' }, { status: 202, statusText: 'Accepted' });
    await f.whenStable(); f.detectChanges();
    expect(el.textContent).toContain('on its way');
  });

  it('a wrong password does not offer a confirmation link', async () => {
    const f = TestBed.createComponent(LoginPage); const c = f.componentInstance; f.detectChanges();
    c.email = 'tara@x.example'; c.password = 'Wrong#Pass123';
    const p = c.submit();
    http.expectOne('/api/v1/auth/login').flush({ code: 'invalid_credentials', message: 'Invalid e-mail or password.', correlationId: 'abc' }, { status: 401, statusText: 'Unauthorized' });
    await p; f.detectChanges();
    expect((f.nativeElement as HTMLElement).textContent).not.toContain('new confirmation link');
  });

  it('opening the confirmation link does nothing until the person clicks (mail scanners cannot use the token)', async () => {
    const f = TestBed.createComponent(VerifyEmailPage); f.componentRef.setInput('token', 'tok-123'); f.detectChanges();
    http.expectNone('/api/v1/auth/verify-email');
    const nav = spyOn(TestBed.inject(Router), 'navigate').and.resolveTo(true);
    const p = f.componentInstance.confirm();
    const req = http.expectOne('/api/v1/auth/verify-email');
    expect(req.request.body).toEqual({ token: 'tok-123' });
    req.flush({ verified: true, email: 'tara@x.example' });
    await p;
    expect(nav).toHaveBeenCalledWith(['/login'], { queryParams: { reason: 'verified' } });
  });

  it('a used or expired link explains itself and offers a new one', async () => {
    const f = TestBed.createComponent(VerifyEmailPage); f.componentRef.setInput('token', 'old'); f.detectChanges();
    const p = f.componentInstance.confirm();
    http.expectOne('/api/v1/auth/verify-email').flush({ code: 'business_rule', message: 'The verification link is invalid, already used or has expired.', correlationId: 'x' }, { status: 422, statusText: 'Unprocessable' });
    await p; f.detectChanges();
    const el = f.nativeElement as HTMLElement;
    expect(el.textContent).toContain('already used or has expired');
    expect(el.querySelector('input[type=email]')).toBeTruthy();
  });
});

describe('e-mail queue administration', () => {
  beforeEach(() => TestBed.configureTestingModule({ providers: [provideRouter([]), provideHttpClient(), provideHttpClientTesting()] }));

  it('offers "Send again" only for failed or cancelled ordinary e-mails, and "Don\'t send" only while queued', () => {
    const page = TestBed.runInInjectionContext(() => new EmailQueuePage());
    const again = page.actions.find(a => a.label === 'Send again')!; const cancel = page.actions.find(a => a.label === "Don't send")!;
    const show = (a: typeof again, r: any) => a.show ? a.show(r) : true;
    expect(show(again, { status: 'Failed', isSecurity: false })).toBeTrue();
    expect(show(again, { status: 'Cancelled', isSecurity: false })).toBeTrue();
    expect(show(again, { status: 'Failed', isSecurity: true })).toBeFalse();     // sign-in links are never re-sent
    expect(show(again, { status: 'Sent', isSecurity: false })).toBeFalse();
    expect(show(cancel, { status: 'Pending' })).toBeTrue();
    expect(show(cancel, { status: 'Processing' })).toBeFalse();
    expect(page.cols.some(c => c.key === 'body')).toBeFalse();
  });

  it('labels the e-mail status of in-app notifications in words', () => {
    expect(EMAIL_LABEL['Pending']).toBe('Queued');
    expect(EMAIL_LABEL['Failed']).toBe('Not delivered');
    expect(Object.keys(EMAIL_LABEL).sort()).toEqual(['Cancelled', 'Failed', 'Pending', 'Processing', 'Sent']);
  });
});
