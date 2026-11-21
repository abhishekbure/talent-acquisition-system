import { Component, computed, effect, inject, input, signal, untracked } from '@angular/core';
import { RouterLink } from '@angular/router';
import { Api, errorText } from '../core/api';
import { Auth, ROLE_LABEL, ROLE_SLUG, Role } from '../core/auth';
import { Column, DataTable } from '../shared/table';
import { Metrics } from '../shared/widgets';
import { ReportCard } from '../shared/reports';

interface Worklist { title: string; path: string; params?: Record<string, string | number>; paged?: boolean; link: string; linkLabel: string; columns: Column[]; }

/** The list under the metrics on each role's dashboard: the thing that role most often has to act on. */
const WORKLISTS: Record<Role, Worklist> = {
  Candidate: {
    title: 'My applications', path: '/applications/mine', link: 'applications', linkLabel: 'All applications',
    columns: [{ key: 'title', label: 'Job' }, { key: 'status', label: 'Status', type: 'status' }, { key: 'appliedAt', label: 'Applied', type: 'datetime' }, { key: 'nextInterviewAt', label: 'Next interview', type: 'datetime' }, { key: 'offerStatus', label: 'Offer', type: 'status' }]
  },
  Contractor: {
    title: 'My timesheets', path: '/timesheets/mine', params: { top: 8 }, link: 'timesheets', linkLabel: 'Enter time',
    columns: [{ key: 'weekStartDate', label: 'Week of', type: 'date' }, { key: 'status', label: 'Status', type: 'status' }, { key: 'totalHours', label: 'Hours', type: 'hours' }, { key: 'lastRejectionReason', label: 'Last rejection reason' }]
  },
  Customer: {
    title: 'Timesheets awaiting your approval', path: '/timesheets/pending', link: 'timesheets', linkLabel: 'Review timesheets',
    columns: [{ key: 'contractorName', label: 'Contractor' }, { key: 'roleTitle', label: 'Role' }, { key: 'weekStartDate', label: 'Week of', type: 'date' }, { key: 'totalHours', label: 'Hours', type: 'hours' }, { key: 'daysWaiting', label: 'Waiting', type: 'days' }]
  },
  Recruiter: {
    title: 'Open staffing requests', path: '/staffing/requests', params: { status: 'Open' }, link: 'requests', linkLabel: 'All staffing requests',
    columns: [{ key: 'requestNo', label: 'Request' }, { key: 'customerName', label: 'Customer' }, { key: 'title', label: 'Role' }, { key: 'positions', label: 'Positions', type: 'number' }, { key: 'maxBillRate', label: 'Max bill rate', type: 'money' }, { key: 'createdAt', label: 'Raised', type: 'datetime' }]
  },
  HRManager: {
    title: 'Offers awaiting approval', path: '/offers', params: { status: 'PendingApproval' }, link: 'offers', linkLabel: 'All offers',
    columns: [{ key: 'offerNo', label: 'Offer' }, { key: 'candidateName', label: 'Candidate' }, { key: 'designation', label: 'Designation' }, { key: 'offeredSalary', label: 'Salary', type: 'money' }, { key: 'createdBy', label: 'Created by' }, { key: 'daysToExpiry', label: 'Expires in', type: 'days' }]
  },
  Administrator: {
    title: 'Recent sign-in attempts', path: '/admin/login-history', params: { pageSize: 8 }, paged: true, link: 'audit', linkLabel: 'Audit & login history',
    columns: [{ key: 'attemptedAt', label: 'When', type: 'datetime' }, { key: 'email', label: 'E-mail' }, { key: 'success', label: 'Succeeded', type: 'bool' }, { key: 'failureReason', label: 'Reason' }, { key: 'ipAddress', label: 'IP' }]
  }
};

/** Phase 10: one report chart on each dashboard of a role that has reports (Candidate and Contractor have none). */
const DASHBOARD_REPORT: Partial<Record<Role, string>> = {
  Recruiter: 'applications-by-status', HRManager: 'department-hiring', Customer: 'staffing-requests', Administrator: 'recruiter-performance'
};

@Component({
  selector: 'app-dashboard',
  imports: [Metrics, DataTable, RouterLink, ReportCard],
  template: `
    <div class="page-head">
      <h1>{{ label() }} dashboard</h1>
      <span class="muted">Welcome, {{ auth.user()?.displayName }}@if (auth.user()?.customerName) { — {{ auth.user()?.customerName }} }</span>
    </div>
    <app-metrics [role]="role()" />
    @if (worklist(); as w) {
      <section class="card">
        <div class="card-head"><h2>{{ w.title }}</h2><a [routerLink]="'/' + slug() + '/' + w.link">{{ w.linkLabel }} →</a></div>
        @if (error()) { <div class="alert error">{{ error() }}</div> }
        <app-table [rows]="rows()" [columns]="w.columns" [filter]="false" empty="Nothing here right now." />
      </section>
    }
    @if (dashboardReport(); as code) { <app-report-card [code]="code" [slug]="slug()" /> }
  `
})
export class DashboardPage {
  private readonly api = inject(Api);
  readonly auth = inject(Auth);
  /** Bound from the route data (the area's role). */
  readonly role = input.required<Role>();
  readonly label = computed(() => ROLE_LABEL[this.role()]);
  readonly slug = computed(() => ROLE_SLUG[this.role()]);
  readonly worklist = computed(() => WORKLISTS[this.role()]);
  readonly dashboardReport = computed(() => DASHBOARD_REPORT[this.role()] ?? null);
  readonly rows = signal<any[]>([]);
  readonly error = signal<string | null>(null);

  constructor() {
    // only the role drives a reload; signals read while the request is built (e.g. the auth token) must not
    effect(() => { const w = this.worklist(); untracked(() => void this.load(w)); });
  }

  private async load(w: Worklist): Promise<void> {
    this.error.set(null);
    try {
      const r = await this.api.get<any>(w.path, w.params);
      this.rows.set(w.paged ? r.items : r);
    } catch (e) { this.error.set(errorText(e)); }
  }
}
