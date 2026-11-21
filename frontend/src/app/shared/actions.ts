import { Injectable, inject } from '@angular/core';
import { Api } from '../core/api';
import { addDays, isoDate, localDateTimeInput } from '../core/format';
import { Dialogs, Option } from '../core/ui';
import { INTERVIEW_MODES, INTERVIEW_TYPES, RECOMMENDATIONS } from './lookups';

/** Dialog-driven operations used from more than one screen. Each one calls exactly one API endpoint. */
@Injectable({ providedIn: 'root' })
export class Actions {
  private readonly api = inject(Api);
  private readonly dlg = inject(Dialogs);

  scheduleInterview(target: { jobApplicationId?: number; submittedCandidateId?: number }, panel: () => Promise<Option[]>, defaultType = 'Technical', nextRound = 1): Promise<unknown> {
    const start = new Date(); start.setDate(start.getDate() + 1); start.setHours(10, 0, 0, 0);
    return this.dlg.open({
      title: 'Schedule interview', wide: true, submitLabel: 'Schedule',
      fields: [
        { key: 'roundNo', label: 'Round', type: 'number', min: 1, max: 10, value: nextRound, required: true },
        { key: 'interviewType', label: 'Type', type: 'select', options: INTERVIEW_TYPES, value: defaultType, required: true },
        { key: 'startsAt', label: 'Starts (your local time)', type: 'datetime', value: localDateTimeInput(start), required: true },
        { key: 'durationMinutes', label: 'Duration (minutes)', type: 'number', min: 15, max: 480, step: 15, value: 60, required: true },
        { key: 'mode', label: 'Mode', type: 'select', options: INTERVIEW_MODES, value: 'Video', required: true },
        { key: 'locationOrLink', label: 'Location or meeting link', maxLength: 300 },
        { key: 'notes', label: 'Notes for the panel', type: 'textarea', maxLength: 1000 },
        { key: 'panel', label: 'Interview panel', type: 'multiselect', options: panel, required: true, hint: 'The first person you tick leads the interview.' }
      ],
      submit: v => {
        const startsAt: string = v.startsAt;
        const endsAt = new Date(new Date(startsAt).getTime() + v.durationMinutes * 60000).toISOString();
        return this.api.post('/interviews', {
          ...target, roundNo: v.roundNo, interviewType: v.interviewType, startsAt, endsAt, mode: v.mode,
          locationOrLink: v.locationOrLink, notes: v.notes, panel: v.panel
        });
      }
    });
  }

  feedback(interviewId: number): Promise<unknown> {
    return this.dlg.open({
      title: 'Interview feedback', submitLabel: 'Submit feedback',
      message: 'Feedback can be given once per interviewer, after the interview has started. Candidates never see it.',
      fields: [
        { key: 'rating', label: 'Rating (1 = poor, 5 = excellent)', type: 'number', min: 1, max: 5, value: 3, required: true },
        { key: 'recommendation', label: 'Recommendation', type: 'select', options: RECOMMENDATIONS, required: true },
        { key: 'strengths', label: 'Strengths', type: 'textarea', maxLength: 1000 },
        { key: 'concerns', label: 'Concerns', type: 'textarea', maxLength: 1000 }
      ],
      submit: v => this.api.post(`/interviews/${interviewId}/feedback`, v)
    });
  }

  reschedule(iv: any): Promise<unknown> {
    const start = new Date(iv.startsAt);
    const minutes = Math.round((new Date(iv.endsAt).getTime() - start.getTime()) / 60000) || 60;
    return this.dlg.open({
      title: 'Reschedule interview', submitLabel: 'Reschedule',
      fields: [
        { key: 'startsAt', label: 'New start (your local time)', type: 'datetime', value: localDateTimeInput(start > new Date() ? start : addDays(new Date(), 1)), required: true },
        { key: 'durationMinutes', label: 'Duration (minutes)', type: 'number', min: 15, max: 480, step: 15, value: minutes, required: true },
        { key: 'mode', label: 'Mode', type: 'select', options: INTERVIEW_MODES, value: iv.mode },
        { key: 'locationOrLink', label: 'Location or meeting link', value: iv.locationOrLink, maxLength: 300 }
      ],
      submit: v => this.api.put(`/interviews/${iv.interviewId}/reschedule`, {
        startsAt: v.startsAt, endsAt: new Date(new Date(v.startsAt).getTime() + v.durationMinutes * 60000).toISOString(),
        mode: v.mode, locationOrLink: v.locationOrLink, rowVer: iv.rowVer
      })
    });
  }

  cancelInterview(iv: any): Promise<unknown> {
    return this.dlg.open({
      title: 'Cancel interview', submitLabel: 'Cancel interview', danger: true,
      fields: [{ key: 'reason', label: 'Reason', type: 'textarea', maxLength: 300 }],
      submit: v => this.api.post(`/interviews/${iv.interviewId}/cancel`, v)
    });
  }

  createOffer(app: { applicationId: number; title?: string; candidateName?: string }): Promise<unknown> {
    const expires = addDays(new Date(), 7); expires.setHours(18, 0, 0, 0);
    return this.dlg.open({
      title: `Create offer${app.candidateName ? ' for ' + app.candidateName : ''}`, submitLabel: 'Create offer',
      message: 'The offer is created as "Pending approval". An HR Manager other than you must approve it before it can be sent.',
      fields: [
        { key: 'designation', label: 'Designation', value: app.title ?? '', required: true, maxLength: 150 },
        { key: 'offeredSalary', label: 'Annual salary (INR)', type: 'number', min: 1, required: true },
        { key: 'startDate', label: 'Start date', type: 'date', value: isoDate(addDays(new Date(), 30)), required: true },
        { key: 'expiresAt', label: 'Offer expires (your local time)', type: 'datetime', value: localDateTimeInput(expires), required: true }
      ],
      submit: v => this.api.post('/offers', { applicationId: app.applicationId, currency: 'INR', ...v })
    });
  }

  createContract(sub: { submissionId: number; firstName?: string; lastName?: string; proposedBillRate?: number }, request: { title: string; maxBillRate?: number | null; startDate?: string | null; workLocation?: string | null }): Promise<unknown> {
    const start = request.startDate ? request.startDate.substring(0, 10) : isoDate(new Date());
    const end = new Date(start + 'T00:00:00'); end.setMonth(end.getMonth() + 6);
    return this.dlg.open({
      title: `Create contract${sub.firstName ? ' for ' + sub.firstName + ' ' + sub.lastName : ''}`, submitLabel: 'Create contract', wide: true,
      message: 'Creates the contractor (if new), placement, contract, rates and first assignment in one transaction. The pay rate is never shown to the customer; the bill rate is never shown to the contractor.'
        + (request.maxBillRate ? ` Customer maximum bill rate: ${request.maxBillRate}/h.` : ''),
      fields: [
        { key: 'roleTitle', label: 'Role title', value: request.title, required: true, maxLength: 150 },
        { key: 'startDate', label: 'Start date', type: 'date', value: start, required: true },
        { key: 'endDate', label: 'End date', type: 'date', value: isoDate(end), required: true },
        { key: 'payRate', label: 'Pay rate per hour (contractor)', type: 'number', min: 0, step: 0.01, required: true },
        { key: 'billRate', label: 'Bill rate per hour (customer)', type: 'number', min: 0.01, step: 0.01, value: sub.proposedBillRate ?? null, required: true },
        { key: 'overtimePayMultiplier', label: 'Overtime pay multiplier', type: 'number', min: 1, max: 5, step: 0.05, value: 1.5, required: true },
        { key: 'overtimeBillMultiplier', label: 'Overtime bill multiplier', type: 'number', min: 1, max: 5, step: 0.05, value: 1.5, required: true },
        { key: 'hoursPerWeek', label: 'Hours per week', type: 'number', min: 1, max: 80, value: 40, required: true },
        { key: 'siteLocation', label: 'Site location', value: request.workLocation ?? '', maxLength: 150 },
        { key: 'terms', label: 'Terms', type: 'textarea', maxLength: 2000 }
      ],
      submit: v => this.api.post('/contracts', { submissionId: sub.submissionId, currency: 'INR', ...v })
    });
  }
}
