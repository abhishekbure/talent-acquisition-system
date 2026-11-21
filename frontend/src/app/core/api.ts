import { HttpClient, HttpErrorResponse, HttpParams } from '@angular/common/http';
import { Injectable, inject } from '@angular/core';
import { Observable, firstValueFrom, map } from 'rxjs';

/** Error body produced by the API ({ code, message, correlationId, details }) plus the HTTP status. */
export interface ApiError {
  status: number;
  code: string;
  message: string;
  correlationId?: string;
  details?: Record<string, string[]>;
}

export function isApiError(e: unknown): e is ApiError {
  return !!e && typeof e === 'object' && 'status' in e && 'code' in e && 'message' in e;
}

/** Text to show a person for any failure (never a stack trace). */
export function errorText(e: unknown): string {
  if (isApiError(e)) {
    const ref = e.correlationId ? ` (ref ${e.correlationId.substring(0, 8)})` : '';
    return e.message + ref;
  }
  return 'Something went wrong. Please try again.';
}

export type Params = Record<string, string | number | boolean | null | undefined>;

/** Rows a capped list endpoint returned at most when it says more exist (API header X-Result-Truncated), else undefined. */
export function truncatedAt(rows: unknown): number | undefined {
  return Array.isArray(rows) ? (rows as any).truncatedAt : undefined;
}

/**
 * Thin promise-based client for the TAMS Web API. The base path is relative ("/api/v1"): the dev server
 * proxies it to the API (proxy.conf.json), and in deployment the API serves the built app from the same origin.
 */
@Injectable({ providedIn: 'root' })
export class Api {
  private readonly http = inject(HttpClient);
  readonly base = '/api/v1';

  get<T = any>(path: string, params?: Params): Promise<T> {
    // Phase 13: long lists are capped by the API (newest first); remember that on the array so tables can say so
    return this.run(this.http.get<T>(this.base + path, { params: toParams(params), observe: 'response' }).pipe(map(res => {
      const body = res.body as T;
      if (Array.isArray(body) && res.headers.get('X-Result-Truncated') === 'true') {
        Object.defineProperty(body, 'truncatedAt', { value: Number(res.headers.get('X-Result-Limit')) || body.length, enumerable: false });
      }
      return body;
    })));
  }
  post<T = any>(path: string, body: unknown = {}): Promise<T> {
    return this.run(this.http.post<T>(this.base + path, body ?? {}));
  }
  put<T = any>(path: string, body: unknown): Promise<T> {
    return this.run(this.http.put<T>(this.base + path, body));
  }
  delete<T = any>(path: string): Promise<T> {
    return this.run(this.http.delete<T>(this.base + path));
  }

  /** multipart/form-data upload; the browser sets the boundary and Content-Length. */
  upload<T = any>(path: string, form: FormData): Promise<T> {
    return this.run(this.http.post<T>(this.base + path, form));
  }

  /** Downloads a protected file with the bearer token and hands it to the browser's save dialog. */
  async download(path: string, fallbackName = 'document'): Promise<void> {
    let res;
    try {
      res = await firstValueFrom(this.http.get(this.base + path, { responseType: 'blob', observe: 'response' }));
    } catch (e) {
      throw await toApiErrorAsync(e);
    }
    const name = fileNameFrom(res.headers.get('Content-Disposition')) ?? fallbackName;
    const url = URL.createObjectURL(res.body as Blob);
    try {
      const a = document.createElement('a');
      a.href = url; a.download = name; a.rel = 'noopener';
      document.body.appendChild(a); a.click(); a.remove();
    } finally {
      setTimeout(() => URL.revokeObjectURL(url), 10000);
    }
  }

  private async run<T>(obs: Observable<T>): Promise<T> {
    try {
      return await firstValueFrom(obs);
    } catch (e) {
      throw toApiError(e);
    }
  }
}

function toParams(p?: Params): HttpParams {
  let hp = new HttpParams();
  if (!p) return hp;
  for (const [k, v] of Object.entries(p)) {
    if (v === null || v === undefined || v === '') continue;
    hp = hp.set(k, String(v));
  }
  return hp;
}

/** Blob responses carry the JSON error as a Blob: read it before mapping. */
async function toApiErrorAsync(e: unknown): Promise<ApiError> {
  if (e instanceof HttpErrorResponse && e.error instanceof Blob) {
    try {
      const body = JSON.parse(await e.error.text());
      return toApiError(new HttpErrorResponse({ error: body, status: e.status, statusText: e.statusText, url: e.url ?? undefined }));
    } catch { /* not JSON */ }
  }
  return toApiError(e);
}

/** File name from Content-Disposition, preferring the RFC 5987 filename* form. */
export function fileNameFrom(header: string | null): string | null {
  if (!header) return null;
  const star = /filename\*\s*=\s*(?:UTF-8|utf-8)''([^;]+)/.exec(header);
  if (star) { try { return decodeURIComponent(star[1].trim()); } catch { /* fall through */ } }
  const plain = /filename\s*=\s*"?([^";]+)"?/.exec(header);
  return plain ? plain[1].trim() : null;
}

export function toApiError(e: unknown): ApiError {
  if (e instanceof HttpErrorResponse) {
    const b = e.error;
    if (b && typeof b === 'object' && typeof b.message === 'string') {
      return { status: e.status, code: b.code ?? 'error', message: b.message, correlationId: b.correlationId, details: b.details ?? undefined };
    }
    if (e.status === 0) return { status: 0, code: 'network', message: 'The server cannot be reached. Check that the TAMS API is running.' };
    return { status: e.status, code: 'error', message: `The request failed (HTTP ${e.status}).` };
  }
  return { status: 0, code: 'client', message: 'Unexpected client error.' };
}
