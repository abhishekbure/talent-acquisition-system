import { Component, computed, inject, signal } from '@angular/core';
import { NavigationEnd, Router, RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';
import { filter } from 'rxjs';
import { AREAS, Area } from '../areas';
import { Auth, ROLE_LABEL } from '../core/auth';
import { DialogHost } from '../shared/dialog-host';
import { ToastHost } from '../shared/widgets';

@Component({
  selector: 'app-shell',
  imports: [RouterOutlet, RouterLink, RouterLinkActive, DialogHost, ToastHost],
  template: `
    <header class="topbar">
      <button type="button" class="btn sm menu-btn" (click)="menuOpen.set(!menuOpen())" aria-label="Toggle menu">☰</button>
      <a class="brand" [routerLink]="auth.homePath()">TAMS<span>Talent Acquisition</span></a>
      @if (areas().length > 1) {
        <nav class="role-switch" aria-label="Switch role">
          @for (a of areas(); track a.slug) {
            <a [routerLink]="'/' + a.slug" routerLinkActive="active">{{ a.title }}</a>
          }
        </nav>
      }
      <div class="spacer"></div>
      <a class="top-link" routerLink="/notifications" routerLinkActive="active">Notifications @if (unread() > 0) { <span class="count">{{ unread() }}</span> }</a>
      <a class="top-link" routerLink="/account" routerLinkActive="active" [title]="auth.user()?.email ?? ''"><span class="who">{{ auth.user()?.displayName }}@if (auth.user()?.customerName) { · {{ auth.user()?.customerName }} }</span><span class="short">Account</span></a>
      <button type="button" class="btn sm" (click)="signOut()">Sign out</button>
    </header>
    <div class="layout">
      <aside class="sidenav" [class.open]="menuOpen()">
        @if (current(); as a) {
          <div class="side-title">{{ a.title }}</div>
          @for (i of a.items; track i.path) {
            <a [routerLink]="'/' + a.slug + (i.path ? '/' + i.path : '')" routerLinkActive="active" [routerLinkActiveOptions]="{ exact: i.path === '' }" (click)="menuOpen.set(false)">{{ i.label }}</a>
          }
        } @else {
          @for (a of areas(); track a.slug) { <a [routerLink]="'/' + a.slug" (click)="menuOpen.set(false)">{{ a.title }} dashboard</a> }
        }
        @if (areas().length > 1) {
          <div class="side-title switch">Switch role</div>
          @for (a of areas(); track a.slug) {
            @if (a.slug !== current()?.slug) { <a [routerLink]="'/' + a.slug" (click)="menuOpen.set(false)">{{ a.title }}</a> }
          }
        }
        <div class="side-foot">Signed in as {{ roleNames() }}</div>
      </aside>
      <main class="content" id="main"><router-outlet /></main>
    </div>
    <app-dialog-host />
    <app-toasts />
  `
})
export class Shell {
  readonly auth = inject(Auth);
  private readonly router = inject(Router);
  readonly menuOpen = signal(false);
  private readonly url = signal(this.router.url);

  readonly areas = computed<Area[]>(() => AREAS.filter(a => this.auth.user()?.roles.includes(a.role)));
  readonly current = computed(() => {
    const seg = this.url().split('?')[0].split('/')[1] ?? '';
    return this.areas().find(a => a.slug === seg) ?? null;
  });
  readonly unread = computed(() => this.auth.user()?.unreadNotifications ?? 0);
  readonly roleNames = computed(() => (this.auth.user()?.roles ?? []).map(r => ROLE_LABEL[r]).join(', '));

  constructor() {
    this.router.events.pipe(filter(e => e instanceof NavigationEnd)).subscribe(e => this.url.set((e as NavigationEnd).urlAfterRedirects));
    // keep roles and unread count current (roles change e.g. when a candidate becomes a contractor)
    void this.auth.refresh().catch(() => undefined);
  }

  async signOut(): Promise<void> {
    await this.auth.logout();
    await this.router.navigate(['/login']);
  }
}
