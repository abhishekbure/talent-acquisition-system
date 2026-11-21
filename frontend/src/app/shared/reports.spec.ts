import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { ReportsPage } from '../pages/reports';
import { BarChart, ReportDef, camel, chartData } from './reports';

const def = (over: Partial<ReportDef> = {}): ReportDef => ({
  reportCode: 'applications-by-status', category: 'Recruitment', title: 'Applications by status', description: 'd', dateFilter: 'Application date',
  usesDays: false, customerScoped: false, canFilterCustomer: false, chartLabel: 'Status', chartValue: 'Applications', chartAggregate: 'value', ...over
});

describe('report helpers', () => {
  it('camel-cases column names exactly like the API serialiser', () => {
    expect(camel('SharePct')).toBe('sharePct');
    expect(camel('Overdue1To30Days')).toBe('overdue1To30Days');
    expect(camel('HRManager')).toBe('hrManager');
    expect(camel('ID')).toBe('id');
    expect(camel('status')).toBe('status');
  });

  it('builds bars per row, or counts / sums rows per label, largest first and capped', () => {
    const rows = [{ status: 'Applied', applications: 2 }, { status: 'Hired', applications: 1 }, { status: 'Rejected', applications: null }];
    expect(chartData(def(), rows)).toEqual([{ label: 'Applied', value: 2 }, { label: 'Hired', value: 1 }]);
    const subs = [{ status: 'Selected' }, { status: 'Rejected' }, { status: 'Selected' }, { status: null }];
    expect(chartData(def({ chartLabel: 'Status', chartValue: null, chartAggregate: 'count' }), subs))
      .toEqual([{ label: 'Selected', value: 2 }, { label: 'Rejected', value: 1 }, { label: '(none)', value: 1 }]);
    const inv = [{ customer: 'Apex', total: 100 }, { customer: 'Bright', total: 50 }, { customer: 'Apex', total: 30.5 }];
    expect(chartData(def({ chartLabel: 'Customer', chartValue: 'Total', chartAggregate: 'sum' }), inv)).toEqual([{ label: 'Apex', value: 130.5 }, { label: 'Bright', value: 50 }]);
    expect(chartData(def(), Array.from({ length: 40 }, (_, i) => ({ status: 's' + i, applications: i })), 25).length).toBe(25);
    expect(chartData(def({ chartLabel: null }), rows)).toEqual([]);
  });

  it('draws no bar for zero or negative values but keeps their number', () => {
    const f = TestBed.createComponent(BarChart);
    f.componentRef.setInput('data', [{ label: 'C-1', value: 30 }, { label: 'C-2', value: -3 }, { label: 'C-3', value: 0 }]);
    f.componentRef.setInput('valueType', 'number');
    f.detectChanges();
    const c = f.componentInstance;
    expect(c.pct(30)).toBe(100); expect(c.pct(-3)).toBe(0); expect(c.pct(0)).toBe(0);
    const el = f.nativeElement as HTMLElement;
    expect(el.querySelectorAll('.bar-fill').length).toBe(3);
    expect((el.querySelectorAll('.bar-fill')[1] as HTMLElement).style.width).toBe('0%');
    expect(el.textContent).toContain('-3');
  });
});

describe('Reports page', () => {
  let http: HttpTestingController;
  beforeEach(() => {
    TestBed.configureTestingModule({ providers: [provideRouter([]), provideHttpClient(), provideHttpClientTesting()] });
    http = TestBed.inject(HttpTestingController);
  });
  afterEach(() => http.verify());

  it('lists only what the API offers, runs the chosen report with its filters, and draws its chart and table', async () => {
    const f = TestBed.createComponent(ReportsPage); f.detectChanges();
    http.expectOne('/api/v1/reports').flush([def(), def({ reportCode: 'expiring-contracts', category: 'Staffing', title: 'Expiring contracts', usesDays: true, dateFilter: null, chartLabel: 'ContractNo', chartValue: 'DaysToExpiry' })]);
    await f.whenStable(); f.detectChanges();
    const el = f.nativeElement as HTMLElement;
    expect(el.textContent).toContain('Recruitment'); expect(el.textContent).toContain('Staffing'); expect(el.textContent).not.toContain('HR');

    f.componentRef.setInput('report', 'applications-by-status'); f.detectChanges();
    const run = http.expectOne('/api/v1/reports/applications-by-status');
    run.flush({ report: def(), columns: [{ key: 'status', label: 'Status', type: 'text' }, { key: 'applications', label: 'Applications', type: 'number' }, { key: 'sharePct', label: 'Share %', type: 'percent' }],
                rows: [{ status: 'Applied', applications: 2, sharePct: 66.7 }, { status: 'Hired', applications: 1, sharePct: 33.3 }], rowCount: 2, truncated: false, generatedAt: '2026-11-20T08:00:00Z' });
    await f.whenStable(); f.detectChanges();
    expect(el.querySelectorAll('.bar-fill').length).toBe(2);
    expect(el.textContent).toContain('66.7 %');
    expect(el.textContent).toContain('2 rows');

    // filters go into the query string; an inverted range never reaches the API
    const page = f.componentInstance;
    page.from = '2026-11-01'; page.to = '2026-11-30';
    const p = page.run();
    const filtered = http.expectOne(r => r.url === '/api/v1/reports/applications-by-status?from=2026-11-01&to=2026-11-30');
    filtered.flush({ report: def(), columns: [], rows: [], rowCount: 0, truncated: false, generatedAt: '2026-11-20T08:00:00Z' });
    await p;
    page.from = '2026-12-01';
    await page.run();
    expect(page.error()).toContain('start date');
  });

  it('shows a clear message for a report the role does not have', async () => {
    const f = TestBed.createComponent(ReportsPage); f.componentRef.setInput('report', 'placements'); f.detectChanges();
    http.expectOne('/api/v1/reports').flush([def()]);
    await f.whenStable(); f.detectChanges();
    expect((f.nativeElement as HTMLElement).textContent).toContain('not available for your role');
  });
});
