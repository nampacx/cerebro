import { useCallback, useEffect, useRef, useState } from 'react';
import { api, type DocumentInfo } from '../api';

const ACTIVE_STATUSES = new Set(['pending', 'processing']);

export function DocumentsView() {
  const [documents, setDocuments] = useState<DocumentInfo[]>([]);
  const [groupIds, setGroupIds] = useState('');
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);

  const refresh = useCallback(async () => {
    try {
      setDocuments(await api.listDocuments());
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load documents.');
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  // Ingestion is asynchronous (blob trigger), so poll while anything is in flight.
  useEffect(() => {
    if (!documents.some((d) => ACTIVE_STATUSES.has(d.status))) {
      return;
    }
    const timer = setInterval(() => void refresh(), 4000);
    return () => clearInterval(timer);
  }, [documents, refresh]);

  async function handleUpload(event: React.FormEvent) {
    event.preventDefault();
    const file = fileInput.current?.files?.[0];
    if (!file) {
      return;
    }

    setUploading(true);
    setError(null);
    try {
      const groups = groupIds
        .split(',')
        .map((g) => g.trim())
        .filter(Boolean);
      await api.uploadDocument(file, groups);
      if (fileInput.current) {
        fileInput.current.value = '';
      }
      await refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Upload failed.');
    } finally {
      setUploading(false);
    }
  }

  return (
    <section className="panel">
      <h2>Documents</h2>
      <form className="upload-form" onSubmit={handleUpload}>
        <input type="file" ref={fileInput} accept=".pdf,.docx,.pptx,.txt,.md,.png,.jpg,.jpeg,.tiff" />
        <input
          type="text"
          placeholder="Share with Entra group ids (comma separated, optional)"
          value={groupIds}
          onChange={(event) => setGroupIds(event.target.value)}
        />
        <button type="submit" disabled={uploading}>
          {uploading ? 'Uploading…' : 'Upload'}
        </button>
      </form>

      {error && <p className="error">{error}</p>}

      <table className="documents">
        <thead>
          <tr>
            <th>File</th>
            <th>Status</th>
            <th>Chunks</th>
            <th>Updated</th>
          </tr>
        </thead>
        <tbody>
          {documents.length === 0 && (
            <tr>
              <td colSpan={4} className="empty">
                No documents yet.
              </td>
            </tr>
          )}
          {documents.map((doc) => (
            <tr key={doc.id}>
              <td>{doc.filename}</td>
              <td>
                <span className={`status status-${doc.status}`}>{doc.status}</span>
                {doc.errorMessage && <div className="error-detail">{doc.errorMessage}</div>}
              </td>
              <td>{doc.chunkCount}</td>
              <td>{new Date(doc.updatedAt).toLocaleString()}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
