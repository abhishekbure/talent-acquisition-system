import { Type } from '@angular/core';
import { Role } from './core/auth';

export interface NavItem {
  path: string;           // relative to the area, '' = dashboard
  label: string;
  load: () => Promise<Type<unknown>>;
}
export interface Area { role: Role; slug: string; title: string; items: NavItem[]; }

const dashboard = (): Promise<Type<unknown>> => import('./pages/dashboard').then(m => m.DashboardPage);
const p = {
  candidate: () => import('./pages/candidate'),
  contractor: () => import('./pages/contractor'),
  interviews: () => import('./pages/interviews'),
  staffing: () => import('./pages/staffing'),
  contracts: () => import('./pages/contracts'),
  timesheets: () => import('./pages/timesheets'),
  invoices: () => import('./pages/invoices'),
  recruitment: () => import('./pages/recruitment'),
  candidates: () => import('./pages/candidates'),
  hr: () => import('./pages/hr'),
  admin: () => import('./pages/admin'),
  reports: () => import('./pages/reports')
};

/** One definition drives both the side navigation and the routes. */
export const AREAS: Area[] = [
  {
    role: 'Candidate', slug: 'candidate', title: 'Candidate', items: [
      { path: '', label: 'Dashboard', load: dashboard },
      { path: 'jobs', label: 'Find jobs', load: () => p.candidate().then(m => m.JobsBrowsePage) },
      { path: 'applications', label: 'My applications', load: () => p.candidate().then(m => m.MyApplicationsPage) },
      { path: 'interviews', label: 'Interviews', load: () => p.interviews().then(m => m.InterviewsPage) },
      { path: 'offers', label: 'Offers', load: () => p.candidate().then(m => m.MyOffersPage) },
      { path: 'profile', label: 'My profile', load: () => p.candidate().then(m => m.CandidateProfilePage) }
    ]
  },
  {
    role: 'Contractor', slug: 'contractor', title: 'Contractor', items: [
      { path: '', label: 'Dashboard', load: dashboard },
      { path: 'timesheets', label: 'Timesheets', load: () => p.contractor().then(m => m.ContractorTimesheetsPage) },
      { path: 'contracts', label: 'Contracts', load: () => p.contracts().then(m => m.ContractsPage) },
      { path: 'profile', label: 'Profile & compliance', load: () => p.contractor().then(m => m.ContractorProfilePage) }
    ]
  },
  {
    role: 'Customer', slug: 'customer', title: 'Customer', items: [
      { path: '', label: 'Dashboard', load: dashboard },
      { path: 'requests', label: 'Staffing requests', load: () => p.staffing().then(m => m.StaffingRequestsPage) },
      { path: 'interviews', label: 'Interviews', load: () => p.interviews().then(m => m.InterviewsPage) },
      { path: 'timesheets', label: 'Timesheet approvals', load: () => p.timesheets().then(m => m.TimesheetReviewPage) },
      { path: 'contracts', label: 'Contracts', load: () => p.contracts().then(m => m.ContractsPage) },
      { path: 'contractors', label: 'Contractors', load: () => p.staffing().then(m => m.ContractorsPage) },
      { path: 'invoices', label: 'Invoices & balance', load: () => p.invoices().then(m => m.InvoicesPage) },
      { path: 'reports', label: 'Reports', load: () => p.reports().then(m => m.ReportsPage) }
    ]
  },
  {
    role: 'Recruiter', slug: 'recruiter', title: 'Recruiter', items: [
      { path: '', label: 'Dashboard', load: dashboard },
      { path: 'jobs', label: 'Jobs', load: () => p.recruitment().then(m => m.JobsPage) },
      { path: 'applications', label: 'Applications', load: () => p.recruitment().then(m => m.ApplicationsPage) },
      { path: 'candidates', label: 'Candidates', load: () => p.candidates().then(m => m.CandidatesPage) },
      { path: 'interviews', label: 'Interviews', load: () => p.interviews().then(m => m.InterviewsPage) },
      { path: 'offers', label: 'Offers', load: () => p.recruitment().then(m => m.OffersPage) },
      { path: 'requests', label: 'Staffing requests', load: () => p.staffing().then(m => m.StaffingRequestsPage) },
      { path: 'contractors', label: 'Contractors & compliance', load: () => p.staffing().then(m => m.ContractorsPage) },
      { path: 'contracts', label: 'Contracts', load: () => p.contracts().then(m => m.ContractsPage) },
      { path: 'timesheets', label: 'Timesheets', load: () => p.timesheets().then(m => m.TimesheetReviewPage) },
      { path: 'invoices', label: 'Invoices', load: () => p.invoices().then(m => m.InvoicesPage) },
      { path: 'reports', label: 'Reports', load: () => p.reports().then(m => m.ReportsPage) }
    ]
  },
  {
    role: 'HRManager', slug: 'hr', title: 'HR Manager', items: [
      { path: '', label: 'Dashboard', load: dashboard },
      { path: 'requisitions', label: 'Hiring requests', load: () => p.recruitment().then(m => m.RequisitionsPage) },
      { path: 'jobs', label: 'Jobs & approvals', load: () => p.recruitment().then(m => m.JobsPage) },
      { path: 'offers', label: 'Offer approvals', load: () => p.recruitment().then(m => m.OffersPage) },
      { path: 'employees', label: 'Employees & onboarding', load: () => p.hr().then(m => m.EmployeesPage) },
      { path: 'applications', label: 'Applications', load: () => p.recruitment().then(m => m.ApplicationsPage) },
      { path: 'candidates', label: 'Candidates', load: () => p.candidates().then(m => m.CandidatesPage) },
      { path: 'interviews', label: 'Interviews', load: () => p.interviews().then(m => m.InterviewsPage) },
      { path: 'departments', label: 'Departments', load: () => p.hr().then(m => m.DepartmentsPage) },
      { path: 'reports', label: 'Reports', load: () => p.reports().then(m => m.ReportsPage) }
    ]
  },
  {
    role: 'Administrator', slug: 'admin', title: 'Administrator', items: [
      { path: '', label: 'Dashboard', load: dashboard },
      { path: 'users', label: 'Users & roles', load: () => p.admin().then(m => m.UsersPage) },
      { path: 'customers', label: 'Customers & rate cards', load: () => p.admin().then(m => m.CustomersPage) },
      { path: 'departments', label: 'Departments', load: () => p.hr().then(m => m.DepartmentsPage) },
      { path: 'audit', label: 'Audit & login history', load: () => p.admin().then(m => m.AuditPage) },
      { path: 'scheduler', label: 'Scheduled jobs', load: () => p.admin().then(m => m.SchedulerPage) },
      { path: 'reports', label: 'Reports', load: () => p.reports().then(m => m.ReportsPage) },
      { path: 'email-queue', label: 'E-mail queue', load: () => p.admin().then(m => m.EmailQueuePage) },
      { path: 'requisitions', label: 'Hiring requests', load: () => p.recruitment().then(m => m.RequisitionsPage) },
      { path: 'jobs', label: 'Jobs', load: () => p.recruitment().then(m => m.JobsPage) },
      { path: 'requests', label: 'Staffing requests', load: () => p.staffing().then(m => m.StaffingRequestsPage) },
      { path: 'contracts', label: 'Contracts', load: () => p.contracts().then(m => m.ContractsPage) },
      { path: 'invoices', label: 'Invoices', load: () => p.invoices().then(m => m.InvoicesPage) }
    ]
  }
];

export function areaBySlug(slug: string): Area | undefined { return AREAS.find(a => a.slug === slug); }
