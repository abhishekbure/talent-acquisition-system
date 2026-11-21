import { HttpErrorResponse, HttpInterceptorFn } from '@angular/common/http';
import { Injectable, computed, inject, signal } from '@angular/core';
import { CanActivateFn, Router } from '@angular/router';
import { catchError, throwError } from 'rxjs';
import { Api } from './api';

export type Role = 'Candidate' | 'Contractor' | 'Customer' | 'Recruiter' | 'HRManager' | 'Administrator';
export const ROLE_ORDER: Role[] = ['Administrator', 'HRManager', 'Recruiter', 'Customer', 'Contractor', 'Candidate'];
export const ROLE_LABEL: Record<Role, string> = {
  Candidate: 'Candidate', Contractor: 'Contractor', Customer: 'Customer', Recruiter: 'Recruiter', HRManager: 'HR Manager', Administrator: 'Administrator'
};
export const ROLE_SLUG: Record<Role, string> = {
  Candidate: 'candidate', Contractor: 'contractor', Customer: 'customer', Recruiter: 'recruiter', HRManager: 'hr', Administrator: 'admin'
};

export interface UserProfile {
  userId: number;
  email: string;
  displayName: string;
  roles: Role[];
  customerId: number | null;
  customerName: string | null;
  candidateId: number | null;
  contractorId: number | null;
  unreadNotifications: number;
  permissions: string[];
}
interface Session { token: string; expiresAt: string; user: UserProfile; }

const KEY = 'tams.session';

/**
 * Holds the signed-in session. The token lives in sessionStorage (cleared when the tab closes) and is
 * validated by the server on every request; this client-side state only drives what the UI shows.
 * Authorisation is enforced by the API and the stored procedures, never by the UI.
 */
@Injectable({ providedIn: 'root' })
export class Auth {
  private readonly api = inject(Api);
  private readonly session = signal<Session | null>(read());

  readonly user = computed(() => this.session()?.user ?? null);
  readonly token = computed(() => this.session()?.token ?? null);
  readonly isSignedIn = computed(() => !!this.session());

  has(...roles: Role[]): boolean {
    const u = this.user();
    return !!u && roles.some(r => u.roles.includes(r));
  }

  /** The area a user lands on after sign-in: their highest-ranked role. */
  homePath(): string {
    const u = this.user();
    if (!u) return '/login';
    const r = ROLE_ORDER.find(x => u.roles.includes(x));
    return r ? '/' + ROLE_SLUG[r] : '/account';
  }

  async login(email: string, password: string): Promise<void> {
    const r = await this.api.post<Session>('/auth/login', { email, password });
    this.store(r);
  }

  /** Creates the account; it can sign in only after the e-mailed confirmation link has been used (no automatic sign-in). */
  async register(body: { email: string; password: string; firstName: string; lastName: string; phone?: string }): Promise<{ email: string; verificationRequired: boolean; message: string }> {
    return this.api.post('/auth/register', body);
  }

  /** Re-reads the profile (roles can change, e.g. a candidate who becomes a contractor). */
  async refresh(): Promise<void> {
    const s = this.session();
    if (!s) return;
    const user = await this.api.get<UserProfile>('/auth/me');
    this.store({ ...s, user });
  }

  async logout(): Promise<void> {
    try { if (this.session()) await this.api.post('/auth/logout'); } catch { /* the token may already be invalid */ }
    this.clear();
  }

  /** Called when the server rejects the token (expired, revoked, user deactivated). */
  clear(): void {
    this.session.set(null);
    try { sessionStorage.removeItem(KEY); } catch { /* storage unavailable */ }
  }

  private store(s: Session): void {
    this.session.set(s);
    try { sessionStorage.setItem(KEY, JSON.stringify(s)); } catch { /* storage unavailable: session lasts for this page only */ }
  }
}

function read(): Session | null {
  try {
    const raw = sessionStorage.getItem(KEY);
    if (!raw) return null;
    const s = JSON.parse(raw) as Session;
    if (!s.token || !s.user || new Date(s.expiresAt).getTime() <= Date.now()) { sessionStorage.removeItem(KEY); return null; }
    return s;
  } catch {
    return null;
  }
}

/** Adds the bearer token to API calls; a 401 on any call except login ends the session. */
export const authInterceptor: HttpInterceptorFn = (req, next) => {
  const auth = inject(Auth);
  const router = inject(Router);
  const token = auth.token();
  const isApi = req.url.startsWith('/api/');
  const authReq = isApi && token ? req.clone({ setHeaders: { Authorization: `Bearer ${token}` } }) : req;
  return next(authReq).pipe(
    catchError((e: unknown) => {
      if (e instanceof HttpErrorResponse && e.status === 401 && isApi && !req.url.includes('/auth/login') && token) {
        auth.clear();
        void router.navigate(['/login'], { queryParams: { reason: 'expired' } });
      }
      return throwError(() => e);
    })
  );
};

/** UI convenience only: the API refuses anything the user is not allowed to do. */
export const signedInGuard: CanActivateFn = (_r, state) => {
  const auth = inject(Auth);
  return auth.isSignedIn() ? true : inject(Router).createUrlTree(['/login'], { queryParams: { returnUrl: state.url } });
};

export function roleGuard(role: Role): CanActivateFn {
  return () => {
    const auth = inject(Auth);
    return auth.has(role) ? true : inject(Router).parseUrl(auth.homePath());
  };
}

export const homeRedirect: CanActivateFn = () => {
  const auth = inject(Auth);
  return inject(Router).parseUrl(auth.homePath());
};

export const signedOutOnly: CanActivateFn = () => {
  const auth = inject(Auth);
  return auth.isSignedIn() ? inject(Router).parseUrl(auth.homePath()) : true;
};
