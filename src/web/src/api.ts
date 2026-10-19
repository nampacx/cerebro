import { getApiToken } from './auth';
import { loadConfig } from './config';

export interface DocumentInfo {
  id: string;
  filename: string;
  blobUrl: string;
  status: 'pending' | 'processing' | 'completed' | 'failed';
  errorMessage: string | null;
  chunkCount: number;
  createdAt: string;
  updatedAt: string;
}

export interface UploadResponse {
  documentId: string;
  filename: string;
  status: string;
}

export interface CitationResult {
  documentId: string;
  filename: string;
  page: number | null;
  chunkIndex: number;
  snippet: string;
}

export interface ChatAnswer {
  answer: string;
  citations: CitationResult[];
  conversationId: string;
}

export interface ConversationSummary {
  id: string;
  title: string;
  createdAt: string;
  updatedAt: string;
}

export interface ConversationMessage {
  role: string;
  text: string;
  createdAt: string | null;
  citations: CitationResult[] | null;
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const config = await loadConfig();
  const token = await getApiToken();
  const headers = new Headers(init.headers);
  headers.set('Authorization', `Bearer ${token}`);

  const response = await fetch(`${config.apiBaseUrl}/api${path}`, { ...init, headers });

  if (!response.ok) {
    const detail = await response.text();
    throw new Error(detail || `Request failed with status ${response.status}`);
  }

  if (response.status === 204) {
    return undefined as T;
  }

  return (await response.json()) as T;
}

export const api = {
  listDocuments: () => request<DocumentInfo[]>('/documents'),

  uploadDocument: async (file: File, groupIds: string[]): Promise<UploadResponse> => {
    const form = new FormData();
    form.append('file', file);
    if (groupIds.length > 0) {
      form.append('groupIds', groupIds.join(','));
    }
    return request<UploadResponse>('/documents', { method: 'POST', body: form });
  },

  listConversations: () => request<ConversationSummary[]>('/conversations'),

  createConversation: (title?: string) =>
    request<ConversationSummary>('/conversations', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ title: title ?? null })
    }),

  getConversation: (id: string) =>
    request<{ id: string; messages: ConversationMessage[] }>(`/conversations/${id}`),

  deleteConversation: (id: string) =>
    request<void>(`/conversations/${id}`, { method: 'DELETE' }),

  chat: (message: string, conversationId: string | null, topK = 5) =>
    request<ChatAnswer>('/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ message, topK, conversationId })
    }),

  // Not routed through request(): that helper assumes a JSON response, this one streams
  // the original file bytes. Opens the document in a new tab via an object URL; for PDFs
  // the #page fragment is honored by Chrome/Edge/Firefox's built-in viewer.
  openDocument: async (documentId: string, page: number | null): Promise<void> => {
    const config = await loadConfig();
    const token = await getApiToken();
    const response = await fetch(`${config.apiBaseUrl}/api/documents/${documentId}/download`, {
      headers: { Authorization: `Bearer ${token}` }
    });
    if (!response.ok) {
      throw new Error(`Failed to load document (status ${response.status}).`);
    }
    const blob = await response.blob();
    const url = URL.createObjectURL(blob);
    window.open(page ? `${url}#page=${page}` : url, '_blank', 'noopener');
  }
};
