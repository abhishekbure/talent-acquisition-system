import { HttpErrorResponse, provideHttpClient, withInterceptors } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { Router, provideRouter } from '@angular/router';
import { Api, errorText, toApiError, truncatedAt } from './api';
import { Auth, authInterceptor, roleGuard } from './auth';
import { addDays, dateOnly, formatDate, formatValue, humanize, isoDate, mondayOf, statusClass, StatusTextPipe } from './format';

describe('format helpers', () => {
  it('shows DATE values on their calendar day whatever the time zone', () => {
    expect(formatDate('2026-11-16T00:00:00Z')).toContain('16');
    expect(formatDate('2026-11-16T00:00:00Z')).toContain('2026');
  });
  it('finds the Monday of a week (ISO weeks, as the database enforces)', () => {
    expect(isoDate(mondayOf(new Date(2026, 10, 19)))).toBe('2026-11-16');   // Thursday
    expect(isoDate(mondayOf(new Date(2026, 10, 16)))).toBe('2026-11-16');   // Monday itself
    expect(isoDate(mondayOf(new Date(2026, 10, 22)))).toBe('2026-11-16');   // Sunday
    expect(isoDate(addDays(new Date(2026, 11, 31), 1))).toBe('2027-01-01');
  });
  it('formats money, hours, booleans and empty values', () => {
    expect(formatValue(136880, 'money')).toContain('1,36,880');
    expect(formatValue(40, 'hours')).toBe('40 h');
    expect(formatValue(true, 'bool')).toBe('Yes');
    expect(formatValue(0, 'bool')).toBe('No');
    expect(formatValue(null, 'money')).toBe('—');
    expect(formatValue(1, 'days')).toBe('1 day');
  });
  it('builds badge classes and date-only strings', () => {
    expect(statusClass('PendingApproval')).toBe('badge s-pendingapproval');
    expect(dateOnly('2026-11-16T00:00:00Z')).toBe('2026-11-16');
  });
  it('shows status codes in tables as the same words the filters use', () => {
    expect(formatValue('PendingApproval', 'status')).toBe('Pending approval');
    expect(formatValue('PartiallyPaid', 'status')).toBe('Partially paid');
    expect(formatValue('Open', 'status')).toBe('Open');
  });
  it('shows status codes in filters and detail badges in the same words (Phase 15)', () => {
    const pipe = new StatusTextPipe();
    expect(pipe.transform('OfferStage')).toBe('Offer stage');
    expect(pipe.transform('PartiallyPaid')).toBe(formatValue('PartiallyPaid', 'status'));
    expect(pipe.transform('Draft')).toBe('Draft');
  });
  it('turns code values into words, including acronyms', () => {
    expect(humanize('HRManager')).toBe('HR Manager');
    expect(humanize('BankTransfer')).toBe('Bank Transfer');
    expect(humanize('Recruiter,HRManager')).toBe('Recruiter,HR Manager');
    expect(humanize('OfferStage')).toBe('Offer Stage');
  });
});

describe('Api client', () => {
  let api: Api; let http: HttpTestingController;
  beforeEach(() => {
    TestBed.configureTestingModule({ providers: [provideHttpClient(), provideHttpClientTesting()] });
    api = TestBed.inject(Api); http = TestBed.inject(HttpTestingController);
  });
  afterEach(() => http.verify());

  it('drops empty query parameters and uses the relative API base', async () => {
    const p = api.get('/jobs', { q: '', status: null, page: 2, active: false });
    const req = http.expectOne(r => r.url === '/api/v1/jobs');
    expect(req.request.params.keys().sort()).toEqual(['active', 'page']);
    req.flush({ items: [], total: 0 });
    expect(await p).toEqual({ items: [], total: 0 });
  });

  it('turns the API error body into an ApiError with the correlation reference', async () => {
    const p = api.post('/applications', { jobPostingId: 1 });
    http.expectOne('/api/v1/applications').flush({ code: 'conflict', message: 'Already applied.', correlationId: 'abcdef1234' }, { status: 409, statusText: 'Conflict' });
    await expectAsync(p).toBeRejectedWith(jasmine.objectContaining({ status: 409, code: 'conflict', message: 'Already applied.' }));
    try { await p; } catch (e) { expect(errorText(e)).toBe('Already applied. (ref abcdef12)'); }
  });

  it('marks a list the API capped (X-Result-Truncated) and leaves complete lists alone', async () => {
    const p1 = api.get<any[]>('/interviews');
    http.expectOne('/api/v1/interviews').flush([{ id: 1 }, { id: 2 }], { headers: { 'X-Result-Truncated': 'true', 'X-Result-Limit': '500' } });
    const capped = await p1;
    expect(truncatedAt(capped)).toBe(500);
    expect(Object.keys(capped)).toEqual(['0', '1']);                    // not enumerable: JSON and loops are unchanged
    const p2 = api.get<any[]>('/offers');
    http.expectOne('/api/v1/offers').flush([{ id: 3 }], { headers: { 'X-Result-Truncated': 'false', 'X-Result-Limit': '500' } });
    expect(truncatedAt(await p2)).toBeUndefined();
  });

  it('reports an unreachable server plainly', () => {
    const e = toApiError(new HttpErrorResponse({ status: 0 }));
    expect(e.code).toBe('network');
    expect(e.message).toContain('cannot be reached');
  });
});

describe('Auth session, interceptor and guards', () => {
  let auth: Auth; let http: HttpTestingController; let api: Api; let router: Router;
  const user = { userId: 7, email: 'x@y.z', displayName: 'X', roles: ['Recruiter', 'HRManager'], customerId: null, customerName: null, candidateId: null, contractorId: null, unreadNotifications: 0, permissions: [] };

  beforeEach(() => {
    sessionStorage.clear();
    TestBed.configureTestingModule({ providers: [provideRouter([]), provideHttpClient(withInterceptors([authInterceptor])), provideHttpClientTesting()] });
    auth = TestBed.inject(Auth); http = TestBed.inject(HttpTestingController); api = TestBed.inject(Api); router = TestBed.inject(Router);
  });
  afterEach(() => { http.verify(); sessionStorage.clear(); });

  async function signIn(): Promise<void> {
    const p = auth.login('x@y.z', 'secret');
    const req = http.expectOne('/api/v1/auth/login');
    expect(req.request.headers.has('Authorization')).toBeFalse();
    req.flush({ token: 'T0K', expiresAt: new Date(Date.now() + 3600_000).toISOString(), user });
    await p;
  }

  it('stores the session, exposes roles and lands on the highest-ranked area', async () => {
    await signIn();
    expect(auth.isSignedIn()).toBeTrue();
    expect(auth.has('HRManager')).toBeTrue();
    expect(auth.has('Customer')).toBeFalse();
    expect(auth.homePath()).toBe('/hr');
    expect(sessionStorage.getItem('tams.session')).toContain('T0K');
  });

  it('sends the bearer token on API calls only', async () => {
    await signIn();
    void api.get('/jobs');
    expect(http.expectOne('/api/v1/jobs').request.headers.get('Authorization')).toBe('Bearer T0K');
  });

  it('ends the session when the server rejects the token', async () => {
    await signIn();
    const nav = spyOn(router, 'navigate').and.resolveTo(true);
    const p = api.get('/jobs');
    http.expectOne('/api/v1/jobs').flush({ code: 'unauthenticated', message: 'x' }, { status: 401, statusText: 'Unauthorized' });
    await expectAsync(p).toBeRejected();
    expect(auth.isSignedIn()).toBeFalse();
    expect(sessionStorage.getItem('tams.session')).toBeNull();
    expect(nav).toHaveBeenCalledWith(['/login'], { queryParams: { reason: 'expired' } });
  });

  it('ignores an expired stored session', () => {
    sessionStorage.setItem('tams.session', JSON.stringify({ token: 'old', expiresAt: new Date(Date.now() - 1000).toISOString(), user }));
    TestBed.resetTestingModule();
    TestBed.configureTestingModule({ providers: [provideRouter([]), provideHttpClient(), provideHttpClientTesting()] });
    expect(TestBed.inject(Auth).isSignedIn()).toBeFalse();
  });

  it('role guard sends users without the role to their own home (the API still enforces access)', async () => {
    await signIn();
    const res = TestBed.runInInjectionContext(() => roleGuard('Customer')({} as any, {} as any));
    expect(router.serializeUrl(res as any)).toBe('/hr');
    expect(TestBed.runInInjectionContext(() => roleGuard('Recruiter')({} as any, {} as any))).toBeTrue();
  });
});
