import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { addDays, isoDate, mondayOf } from '../core/format';
import { ContractorTimesheetsPage } from './contractor';

describe('Contractor timesheets (Phase 14 regression)', () => {
  let http: HttpTestingController;
  beforeEach(() => {
    TestBed.configureTestingModule({ providers: [provideRouter([]), provideHttpClient(), provideHttpClientTesting()] });
    http = TestBed.inject(HttpTestingController);
  });
  afterEach(() => http.verify());

  it('keeps the week the person switched to when an earlier week loads late (found by the end-to-end test)', async () => {
    const thisWeek = isoDate(mondayOf(new Date()));
    const weekA = isoDate(addDays(new Date(thisWeek + 'T00:00:00'), -14));
    const weekB = isoDate(addDays(new Date(thisWeek + 'T00:00:00'), -7));
    const f = TestBed.createComponent(ContractorTimesheetsPage); f.detectChanges();
    const page = f.componentInstance;
    http.expectOne(r => r.url === '/api/v1/assignments').flush([{ assignmentId: 7, roleTitle: 'Engineer', customerName: 'Crestline', contractNo: 'CON-1' }]);
    http.expectOne(r => r.url === '/api/v1/timesheets/mine').flush([{ timesheetId: 11, assignmentId: 7, weekStartDate: weekA + 'T00:00:00Z', status: 'Submitted' }]);
    await f.whenStable();

    page.setWeek(weekA);                                         // week A has a timesheet: its entries are being loaded ...
    const slow = http.expectOne('/api/v1/timesheets/11');
    page.setWeek(weekB);                                         // ... while the person moves on to week B (no timesheet yet)
    expect(page.days()[0].date).toBe(weekB);
    slow.flush({ timesheet: { timesheetId: 11, status: 'Submitted' }, entries: [{ workDate: weekA + 'T00:00:00Z', hours: 8, entryType: 'Regular', isBillable: true }] });
    await f.whenStable();
    await new Promise(r => setTimeout(r, 0));                    // let the late answer's continuation run

    expect(page.week()).toBe(weekB);
    expect(page.days()[0].date).toBe(weekB, 'the late answer for week A did not replace week B');
    expect(page.sheet()).toBeNull();
  });
});
