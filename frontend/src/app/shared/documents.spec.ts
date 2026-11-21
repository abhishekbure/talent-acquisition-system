import { fileNameFrom } from '../core/api';
import { clientFileProblem } from './documents';

describe('document helpers', () => {
  const file = (name: string, size: number) => new File([new Uint8Array(size)], name);

  it('mirrors the server allow-list and size limit before uploading', () => {
    expect(clientFileProblem(null)).toContain('Choose');
    expect(clientFileProblem(file('cv.pdf', 1000))).toBeNull();
    expect(clientFileProblem(file('CV.DOCX', 1000))).toBeNull();
    expect(clientFileProblem(file('photo.jpeg', 1000))).toBeNull();
    expect(clientFileProblem(file('tool.exe', 1000))).toContain('Only PDF');
    expect(clientFileProblem(file('noextension', 1000))).toContain('Only PDF');
    expect(clientFileProblem(file('empty.pdf', 0))).toContain('empty');
    expect(clientFileProblem(file('big.pdf', 10 * 1024 * 1024 + 1))).toContain('10 MB');
    expect(clientFileProblem(file('edge.pdf', 10 * 1024 * 1024))).toBeNull();
  });

  it('reads the download name from Content-Disposition, preferring the UTF-8 form', () => {
    expect(fileNameFrom(`attachment; filename="Rohan_CV.pdf"; filename*=UTF-8''Rohan%20CV%20%E2%80%93%20v2.pdf`)).toBe('Rohan CV – v2.pdf');
    expect(fileNameFrom('attachment; filename="plain.pdf"')).toBe('plain.pdf');
    expect(fileNameFrom(null)).toBeNull();
  });
});
