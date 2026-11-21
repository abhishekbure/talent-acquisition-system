import { Component, ElementRef, computed, effect, inject, input, output, signal, untracked, viewChild } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, errorText } from '../core/api';
import { Dialogs, Option, Toasts } from '../core/ui';
import { Column, DataTable, RowAction } from './table';

export const CANDIDATE_DOC_TYPES: Option[] = [
  { value: 'Resume', label: 'Résumé / CV' }, { value: 'CoverLetter', label: 'Cover letter' }, { value: 'Certificate', label: 'Certificate' },
  { value: 'Identity', label: 'Identity proof' }, { value: 'Other', label: 'Other' }
];
export const EMPLOYEE_DOC_TYPES: Option[] = ['Contract', 'Identity', 'Offer', 'Payroll', 'Certificate', 'Other'].map(v => ({ value: v, label: v }));

/** Mirrors the server's allow-list (the server re-checks extension, size and the file's real content). */
export const ALLOWED_EXTENSIONS = ['.pdf', '.doc', '.docx', '.png', '.jpg', '.jpeg'];
export const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;

export function clientFileProblem(f: File | null): string | null {
  if (!f) return 'Choose a file first.';
  const ext = (f.name.lastIndexOf('.') >= 0 ? f.name.substring(f.name.lastIndexOf('.')) : '').toLowerCase();
  if (!ALLOWED_EXTENSIONS.includes(ext)) return 'Only PDF, Word (.doc, .docx), PNG or JPEG files can be uploaded.';
  if (f.size === 0) return 'The file is empty.';
  if (f.size > MAX_UPLOAD_BYTES) return 'Files may be at most 10 MB.';
  return null;
}

/**
 * Lists, uploads, downloads and removes the documents of one owner. What appears and which actions work is decided
 * by the API/database for the signed-in user; `canUpload` only hides the form for roles that can never upload here.
 */
@Component({
  selector: 'app-documents',
  imports: [DataTable, FormsModule],
  template: `
    <div class="card-head"><h3>{{ title() }}</h3></div>
    @if (error()) { <div class="alert error" role="alert">{{ error() }}</div> }
    <app-table [rows]="rows()" [columns]="cols()" [actions]="actions" [filter]="false" [empty]="empty()" />
    @if (canUpload()) {
      <form class="upload" (ngSubmit)="upload()">
        <label class="inline">File
          <input #file type="file" [accept]="accept" (change)="pick($any($event.target).files)" [attr.aria-label]="'Choose a file for ' + title()" />
        </label>
        @if (docTypes().length) {
          <label class="inline">Type
            <select [(ngModel)]="docType" name="docType">
              @for (t of docTypes(); track t.value) { <option [ngValue]="t.value">{{ t.label }}</option> }
            </select>
          </label>
        }
        @if (complianceOptions().length) {
          <label class="inline">Proof for
            <select [(ngModel)]="complianceId" name="complianceId">
              <option [ngValue]="null">— no compliance record —</option>
              @for (c of complianceOptions(); track c.value) { <option [ngValue]="c.value">{{ c.label }}</option> }
            </select>
          </label>
        }
        @if (allowPrimary() && docType === 'Resume') {
          <label class="inline"><input type="checkbox" [(ngModel)]="primary" name="primary" /> Make this my main résumé</label>
        }
        <button class="btn primary" type="submit" [disabled]="busy() || !chosen()">{{ busy() ? 'Uploading…' : 'Upload' }}</button>
        <small class="hint">PDF, Word, PNG or JPEG · up to 10 MB</small>
      </form>
    }
  `
})
export class DocumentsPanel {
  private readonly api = inject(Api);
  private readonly dlg = inject(Dialogs);
  private readonly toasts = inject(Toasts);
  readonly ownerType = input.required<'Candidate' | 'Contractor' | 'Employee' | 'Contract'>();
  readonly ownerId = input.required<number>();
  readonly title = input('Documents');
  readonly docTypes = input<Option[]>([]);
  readonly complianceOptions = input<Option[]>([]);
  readonly canUpload = input(false);
  readonly allowPrimary = input(false);
  readonly empty = input('No documents.');
  readonly changed = output<void>();
  private readonly fileInput = viewChild<ElementRef<HTMLInputElement>>('file');

  readonly accept = ALLOWED_EXTENSIONS.join(',');
  readonly rows = signal<any[]>([]);
  readonly error = signal<string | null>(null);
  readonly busy = signal(false);
  readonly chosen = signal<File | null>(null);
  docType: string | null = null;
  complianceId: number | null = null;
  primary = false;

  /** "Main résumé" only means something for candidates. */
  readonly cols = computed<Column[]>(() => [
    { key: 'originalFileName', label: 'File' }, { key: 'docType', label: 'Type', value: r => r.complianceType ? `Compliance: ${r.complianceType}` : r.docType },
    ...(this.ownerType() === 'Candidate' ? [{ key: 'isPrimaryResume', label: 'Main résumé', type: 'bool' } as Column] : []),
    { key: 'size', label: 'Size', value: r => kb(r.sizeBytes) },
    { key: 'uploadedAt', label: 'Uploaded', type: 'datetime' }, { key: 'uploadedBy', label: 'By' }
  ]);
  readonly actions: RowAction[] = [
    { label: 'Download', run: r => this.download(r) },
    { label: 'Delete', kind: 'danger', show: r => !!r.canDelete, run: r => this.remove(r) }
  ];

  constructor() {
    effect(() => {
      const t = this.ownerType(), id = this.ownerId();
      untracked(() => { this.docType = this.docTypes()[0]?.value ?? null; void this.load(t, id); });
    });
  }

  async load(t = this.ownerType(), id = this.ownerId()): Promise<void> {
    if (!id) { this.rows.set([]); return; }
    try { this.rows.set(await this.api.get('/documents', { ownerType: t, ownerId: id })); this.error.set(null); }
    catch (e) { this.error.set(errorText(e)); }
  }

  pick(files: FileList | null): void {
    const f = files && files.length ? files[0] : null;
    this.chosen.set(f);
    this.error.set(f ? clientFileProblem(f) : null);
  }

  async upload(): Promise<void> {
    const f = this.chosen();
    const problem = clientFileProblem(f);
    if (problem) { this.error.set(problem); return; }
    const form = new FormData();
    form.append('ownerType', this.ownerType());
    form.append('ownerId', String(this.ownerId()));
    if (this.docType) form.append('docType', this.docType);
    if (this.complianceId) form.append('complianceId', String(this.complianceId));
    if (this.primary) form.append('primaryResume', 'true');
    form.append('file', f!, f!.name);
    this.busy.set(true); this.error.set(null);
    try {
      await this.api.upload('/documents', form);
      this.toasts.ok(`"${f!.name}" uploaded.`);
      this.chosen.set(null); this.primary = false; this.complianceId = null;
      const input = this.fileInput();
      if (input) input.nativeElement.value = '';
      await this.load();
      this.changed.emit();
    } catch (e) { this.error.set(errorText(e)); } finally { this.busy.set(false); }
  }

  async download(r: any): Promise<void> {
    try { await this.api.download(`/documents/${r.documentId}/download`, r.originalFileName); }
    catch (e) { this.toasts.error(e); }
  }

  async remove(r: any): Promise<void> {
    const ok = await this.dlg.confirm('Delete document', `Remove "${r.originalFileName}"? It will no longer be visible to anyone; the record is kept for the audit trail.`,
      () => this.api.delete(`/documents/${r.documentId}`), 'Delete', true);
    if (ok) { this.toasts.ok('Document removed.'); await this.load(); this.changed.emit(); }
  }
}

function kb(bytes: number): string {
  if (bytes == null) return '—';
  return bytes >= 1024 * 1024 ? (bytes / 1024 / 1024).toFixed(1) + ' MB' : Math.max(1, Math.round(bytes / 1024)) + ' KB';
}
