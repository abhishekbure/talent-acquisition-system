import { provideHttpClient, withInterceptors } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { Routes } from '@angular/router';
import { AREAS } from '../areas';
import { routes } from '../app.routes';
import { ApiError } from '../core/api';
import { Auth, authInterceptor } from '../core/auth';
import { Dialogs } from '../core/ui';
import { passwordProblem } from '../pages/auth-pages';
import { NEXT_STATUS } from '../pages/recruitment';
import { DialogHost } from './dialog-host';
import { DataTable } from './table';
import { Metrics } from './widgets';

describe('DataTable', () => {
  let f: ComponentFixture<DataTable>;
  const rows = [
    { id: 1, name: 'Zed', amount: 50, status: 'Open', currency: 'INR' },
    { id: 2, name: 'Amy', amount: 500, status: 'Closed', currency: 'INR' },
    { id: 3, name: 'Bob', amount: 5, status: 'Open', currency: 'INR' }
  ];
  beforeEach(() => {
    f = TestBed.createComponent(DataTable);
    f.componentRef.setInput('rows', rows);
    f.componentRef.setInput('columns', [{ key: 'name', label: 'Name' }, { key: 'amount', label: 'Amount', type: 'money' }, { key: 'status', label: 'Status', type: 'status' }]);
    f.componentRef.setInput('actions', [{ label: 'Close', show: (r: any) => r.status === 'Open', run: () => undefined }]);
    f.detectChanges();
  });
  const names = () => Array.from(f.nativeElement.querySelectorAll('tbody tr td:first-child')).map((td: any) => td.textContent.trim());

  it('renders rows, status badges and only the actions that apply', () => {
    expect(names()).toEqual(['Zed', 'Amy', 'Bob']);
    expect(f.nativeElement.querySelectorAll('.badge.s-open').length).toBe(2);
    expect(f.nativeElement.querySelectorAll('tbody button').length).toBe(2);
  });
  it('sorts numerically by the raw value, then reverses', () => {
    f.componentInstance.sortBy('amount'); f.detectChanges();
    expect(names()).toEqual(['Bob', 'Zed', 'Amy']);
    f.componentInstance.sortBy('amount'); f.detectChanges();
    expect(names()).toEqual(['Amy', 'Zed', 'Bob']);
  });
  it('filters on the displayed text', () => {
    f.componentInstance.q.set('closed'); f.detectChanges();
    expect(names()).toEqual(['Amy']);
  });
  it('says when the API capped the list, and only then', () => {
    expect(f.nativeElement.querySelector('.capped')).toBeNull();
    const capped = [...rows]; Object.defineProperty(capped, 'truncatedAt', { value: 500, enumerable: false });
    f.componentRef.setInput('rows', capped); f.detectChanges();
    expect(f.nativeElement.querySelector('.capped').textContent).toContain('newest 500 records');
  });
  it('shows a pager only when there is more than one page', () => {
    f.componentRef.setInput('total', 60); f.componentRef.setInput('pageSize', 25); f.detectChanges();
    expect(f.nativeElement.querySelector('.pager').textContent).toContain('Page 1 of 3');
  });
});

describe('DialogHost', () => {
  let f: ComponentFixture<DialogHost>; let dlg: Dialogs;
  beforeEach(() => {
    f = TestBed.createComponent(DialogHost);
    dlg = TestBed.inject(Dialogs);
    f.detectChanges();
  });
  const settle = async () => { f.detectChanges(); await f.whenStable(); f.detectChanges(); };

  it('blocks submission until required and numeric rules pass, and never calls the API meanwhile', async () => {
    const submit = jasmine.createSpy('submit').and.resolveTo({ ok: 1 });
    void dlg.open({ title: 'T', fields: [{ key: 'name', label: 'Name', required: true }, { key: 'n', label: 'N', type: 'number', min: 1, max: 5 }], submit });
    await settle();
    const host = f.componentInstance;
    host.values.n = 9;
    await host.submit(dlg.current()!.config);
    expect(submit).not.toHaveBeenCalled();
    expect(host.fieldErrors()['name']).toBe('Required.');
    expect(host.fieldErrors()['n']).toBe('Must be at most 5.');
  });

  it('converts values (numbers, local date-time to UTC, rows, hidden fields) before calling the API', async () => {
    let sent: any;
    const done = dlg.open({
      title: 'T',
      fields: [
        { key: 'amount', label: 'A', type: 'number' },
        { key: 'at', label: 'At', type: 'datetime' },
        { key: 'hidden', label: 'H', showIf: () => false, value: 'x' },
        { key: 'skills', label: 'S', type: 'rows', rows: [{ key: 'skillName', label: 'Skill' }, { key: 'minYears', label: 'Y', type: 'number' }] }
      ],
      submit: async v => { sent = v; return { id: 5 }; }
    });
    await settle();
    const host = f.componentInstance;
    host.values.amount = '12.5';
    host.values.at = '2026-11-20T10:30';
    host.values.skills = [{ skillName: 'C#', minYears: '2' }, { skillName: null, minYears: null }];
    await host.submit(dlg.current()!.config);
    expect(sent.amount).toBe(12.5);
    expect(sent.at).toBe(new Date('2026-11-20T10:30').toISOString());
    expect('hidden' in sent).toBeFalse();
    expect(sent.skills).toEqual([{ skillName: 'C#', minYears: 2 }]);
    expect(await done).toEqual({ id: 5 });
    expect(dlg.current()).toBeNull();
  });

  it('keeps the dialog open and shows the server message and field details when the API refuses', async () => {
    const err: ApiError = { status: 400, code: 'validation', message: 'The request is not valid.', correlationId: '12345678abc', details: { 'body.Title': ['Title is required.'] } };
    void dlg.open({ title: 'T', fields: [{ key: 'title', label: 'Title' }], submit: () => Promise.reject(err) });
    await settle();
    await f.componentInstance.submit(dlg.current()!.config);
    expect(dlg.current()).not.toBeNull();
    expect(f.componentInstance.error()).toBe('The request is not valid. (ref 12345678)');
    expect(f.componentInstance.fieldErrors()['title']).toBe('Title is required.');
  });
});

describe('Metrics (regression: no reload when the session changes)', () => {
  it('fetches once per role and does not re-fire requests when the auth token is cleared at sign-out', async () => {
    sessionStorage.setItem('tams.session', JSON.stringify({ token: 'T', expiresAt: new Date(Date.now() + 60000).toISOString(), user: { roles: ['Customer'] } }));
    TestBed.configureTestingModule({ providers: [provideRouter([]), provideHttpClient(withInterceptors([authInterceptor])), provideHttpClientTesting()] });
    const http = TestBed.inject(HttpTestingController);
    const auth = TestBed.inject(Auth);
    const f = TestBed.createComponent(Metrics);
    f.componentRef.setInput('role', 'Customer');
    f.detectChanges();
    const req = http.expectOne('/api/v1/dashboards/Customer');
    expect(req.request.headers.get('Authorization')).toBe('Bearer T');
    req.flush([{ metricKey: 'k', label: 'L', value: 2, unit: 'count' }]);
    await f.whenStable(); f.detectChanges();
    expect(f.nativeElement.querySelector('.metric-value').textContent.trim()).toBe('2');
    auth.clear();                                   // what sign-out does
    TestBed.flushEffects(); f.detectChanges(); await f.whenStable();
    http.expectNone('/api/v1/dashboards/Customer');
    http.verify();
    sessionStorage.clear();
  });
});

describe('navigation and rules mirrored from the server', () => {
  it('every menu entry has a route behind a role guard, and no area repeats a path', () => {
    const shell = (routes as Routes).find(r => r.path === '' && r.children)!;
    for (const a of AREAS) {
      const area = shell.children!.find(r => r.path === a.slug)!;
      expect(area).withContext(a.slug).toBeDefined();
      expect(area.canActivate?.length).withContext(a.slug).toBe(1);
      const paths = a.items.map(i => i.path);
      expect(new Set(paths).size).withContext(a.slug).toBe(paths.length);
      expect(area.children!.map(c => c.path)).toEqual(paths);
      expect(paths).toContain('');
    }
    expect(AREAS.map(a => a.role).sort()).toEqual(['Administrator', 'Candidate', 'Contractor', 'Customer', 'HRManager', 'Recruiter']);
  });

  it('application status steps equal cand.usp_ChangeApplicationStatus', () => {
    expect(NEXT_STATUS).toEqual({
      Applied: ['Screening', 'Rejected'], Screening: ['Shortlisted', 'Rejected'], Shortlisted: ['Interview', 'Rejected'],
      Interview: ['Selected', 'Shortlisted', 'Rejected'], Selected: ['Rejected']
    });
  });

  it('password rule equals the server policy (10+ chars, upper, lower, digit)', () => {
    expect(passwordProblem('Short1A')).not.toBeNull();
    expect(passwordProblem('alllowercase1')).not.toBeNull();
    expect(passwordProblem('ALLUPPERCASE1')).not.toBeNull();
    expect(passwordProblem('NoDigitsHere')).not.toBeNull();
    expect(passwordProblem('Valid#Pass123')).toBeNull();
  });
});
