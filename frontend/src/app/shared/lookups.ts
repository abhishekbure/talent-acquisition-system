import { Injectable, inject } from '@angular/core';
import { Api } from '../core/api';
import { humanize } from '../core/format';
import { Option } from '../core/ui';

/** Option lists for dialogs, all read live from the API (pick lists are capped at the API's page limit of 200). */
@Injectable({ providedIn: 'root' })
export class Lookups {
  private readonly api = inject(Api);

  async staff(): Promise<Option[]> {
    const l = await this.api.get<any[]>('/staff-directory');
    return l.map(u => ({ value: u.userId, label: `${u.displayName} (${humanize(String(u.roles ?? '')).replace(/,/g, ', ')})` }));
  }
  async recruiters(): Promise<Option[]> {
    const l = await this.api.get<any[]>('/staff-directory');
    return l.filter(u => String(u.roles).split(',').includes('Recruiter')).map(u => ({ value: u.userId, label: u.displayName }));
  }
  async customers(): Promise<Option[]> {
    const l = await this.api.get<any[]>('/customers');
    return l.map(c => ({ value: c.customerId, label: `${c.name} (${c.customerCode})` }));
  }
  async customerContacts(customerId: number): Promise<Option[]> {
    const r = await this.api.get<any>('/customers/' + customerId);
    return (r.contacts as any[]).map(c => ({ value: c.userId, label: `${c.displayName}${c.jobTitle ? ' – ' + c.jobTitle : ''} (customer)` }));
  }
  /** Staff plus the customer's own users, for interviews of submitted (external) candidates scheduled by staff. */
  async staffAndCustomer(customerId: number): Promise<Option[]> {
    const [s, c] = await Promise.all([this.staff(), this.customerContacts(customerId)]);
    return [...s, ...c];
  }
  async departments(): Promise<Option[]> {
    const l = await this.api.get<any[]>('/departments');
    return l.filter(d => d.isActive).map(d => ({ value: d.departmentId, label: d.name }));
  }
  async locations(): Promise<Option[]> {
    const l = await this.api.get<any[]>('/locations');
    return l.filter(x => x.isActive).map(x => ({ value: x.locationId, label: `${x.name}, ${x.city}` }));
  }
  async sources(): Promise<Option[]> {
    const l = await this.api.get<any[]>('/sources');
    return l.map(s => ({ value: s.sourceId, label: s.name }));
  }
  async activeCandidates(): Promise<Option[]> {
    const r = await this.api.get<any>('/candidates', { status: 'Active', pageSize: 200 });
    return (r.items as any[]).map(c => ({ value: c.candidateId, label: `${c.firstName} ${c.lastName} – ${c.currentTitle ?? 'no title'} (${c.email})` }));
  }
  async approvedRequisitions(): Promise<Option[]> {
    const r = await this.api.get<any>('/requisitions', { status: 'Approved', pageSize: 200 });
    // only requests that still have unplanned headcount can take another job
    return (r.items as any[]).filter(x => Number(x.openingsPlanned) < Number(x.headcount)).map(x => ({ value: x.employeeRequisitionId, label: `${x.requisitionNo} – ${x.title} (${x.department}, headcount ${x.headcount}, planned ${x.openingsPlanned})` }));
  }
}

export const INTERVIEW_TYPES: Option[] = ['Screening', 'Technical', 'HR', 'Managerial', 'Customer'].map(v => ({ value: v, label: v }));
export const INTERVIEW_MODES: Option[] = ['Video', 'Onsite', 'Phone'].map(v => ({ value: v, label: v }));
export const RECOMMENDATIONS: Option[] = [
  { value: 'StrongYes', label: 'Strong yes' }, { value: 'Yes', label: 'Yes' }, { value: 'No', label: 'No' }, { value: 'StrongNo', label: 'Strong no' }
];
export const PAYMENT_METHODS: Option[] = ['BankTransfer', 'Cheque', 'Card', 'Cash'].map(v => ({ value: v, label: humanize(v) }));
export const EMPLOYMENT_TYPES: Option[] = [{ value: 'FullTime', label: 'Full time' }, { value: 'PartTime', label: 'Part time' }, { value: 'Intern', label: 'Intern' }];
export function opts(values: string[]): Option[] { return values.map(v => ({ value: v, label: humanize(v) })); }
