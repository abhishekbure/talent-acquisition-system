import { Routes } from '@angular/router';
import { AREAS } from './areas';
import { homeRedirect, roleGuard, signedInGuard, signedOutOnly } from './core/auth';
import { Shell } from './layout/shell';

const auth = () => import('./pages/auth-pages');
const common = () => import('./pages/common');

export const routes: Routes = [
  { path: 'login', canActivate: [signedOutOnly], loadComponent: () => auth().then(m => m.LoginPage), title: 'Sign in · TAMS' },
  { path: 'register', canActivate: [signedOutOnly], loadComponent: () => auth().then(m => m.RegisterPage), title: 'Create account · TAMS' },
  { path: 'forgot-password', loadComponent: () => auth().then(m => m.ForgotPasswordPage), title: 'Forgot password · TAMS' },
  { path: 'reset-password', loadComponent: () => auth().then(m => m.ResetPasswordPage), title: 'Reset password · TAMS' },
  { path: 'verify-email', canActivate: [signedOutOnly], loadComponent: () => auth().then(m => m.VerifyEmailPage), title: 'Confirm e-mail · TAMS' },
  {
    path: '', component: Shell, canActivate: [signedInGuard], children: [
      { path: '', pathMatch: 'full', canActivate: [homeRedirect], children: [] },
      { path: 'notifications', loadComponent: () => common().then(m => m.NotificationsPage), title: 'Notifications · TAMS' },
      { path: 'account', loadComponent: () => common().then(m => m.AccountPage), title: 'My account · TAMS' },
      ...AREAS.map(a => ({
        path: a.slug,
        canActivate: [roleGuard(a.role)],
        data: { role: a.role },
        children: a.items.map(i => ({ path: i.path, loadComponent: i.load, data: { role: a.role }, title: `${i.label} · ${a.title} · TAMS` }))
      }))
    ]
  },
  { path: '**', redirectTo: '' }
];
