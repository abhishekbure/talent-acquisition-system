import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { SchedulerPage } from './admin';

describe('Scheduled jobs page (Phase 11)', () => {
  let http: HttpTestingController;
  beforeEach(() => {
    TestBed.configureTestingModule({ providers: [provideRouter([]), provideHttpClient(), provideHttpClientTesting()] });
    http = TestBed.inject(HttpTestingController);
  });
  afterEach(() => http.verify());

  it('shows a job\'s runs and, for a selected run, what it did', async () => {
    const f = TestBed.createComponent(SchedulerPage); f.detectChanges();
    http.expectOne('/api/v1/admin/jobs').flush([{ jobDefinitionId: 2, jobName: 'TAMS - Detect contract expiry', owner: 'SqlAgent', scheduleDescription: 'Daily 01:15', lastOutcome: 'Succeeded' }]);
    await f.whenStable(); f.detectChanges();
    const page = f.componentInstance;
    const p = page.open(page.rows()[0]);
    http.expectOne(r => r.url === '/api/v1/admin/jobs/2/history').flush([{ executionId: 41, outcome: 'Succeeded', rowsAffected: 2 }, { executionId: 40, outcome: 'Skipped', errorMessage: 'Another run of this job is still in progress.' }]);
    await p; f.detectChanges();
    const q = page.openRun(page.history()[0]);
    http.expectOne('/api/v1/admin/jobs/runs/41/details').flush([{ detailId: 1, level: 'Info', message: 'CON-2026-002: Active -> Expiring (ends 2026-11-30)', loggedAt: '2026-11-20T01:15:02Z' }]);
    await q; f.detectChanges();
    const text = (f.nativeElement as HTMLElement).textContent ?? '';
    expect(text).toContain('Run #41');
    expect(text).toContain('CON-2026-002: Active -> Expiring');
    expect(text).toContain('Skipped');
    expect(text).toContain('scripts\\database\\Install-AgentJobs.ps1');      // backslashes survive the template (found in the live check)
  });
});
