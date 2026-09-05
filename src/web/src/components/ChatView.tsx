import { useCallback, useEffect, useState } from 'react';
import { api, type CitationResult, type ConversationSummary } from '../api';

interface DisplayMessage {
  role: string;
  text: string;
  citations?: CitationResult[];
}

export function ChatView() {
  const [conversations, setConversations] = useState<ConversationSummary[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);
  const [messages, setMessages] = useState<DisplayMessage[]>([]);
  const [input, setInput] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refreshConversations = useCallback(async () => {
    try {
      setConversations(await api.listConversations());
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load conversations.');
    }
  }, []);

  useEffect(() => {
    void refreshConversations();
  }, [refreshConversations]);

  async function openConversation(id: string) {
    setBusy(true);
    setError(null);
    try {
      const conversation = await api.getConversation(id);
      setActiveId(id);
      setMessages(conversation.messages.map((m) => ({ role: m.role, text: m.text })));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to open conversation.');
    } finally {
      setBusy(false);
    }
  }

  function startNewConversation() {
    setActiveId(null);
    setMessages([]);
    setError(null);
  }

  async function removeConversation(id: string) {
    try {
      await api.deleteConversation(id);
      if (activeId === id) {
        startNewConversation();
      }
      await refreshConversations();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to delete conversation.');
    }
  }

  async function send(event: React.FormEvent) {
    event.preventDefault();
    const question = input.trim();
    if (!question || busy) {
      return;
    }

    setInput('');
    setMessages((current) => [...current, { role: 'user', text: question }]);
    setBusy(true);
    setError(null);

    try {
      const answer = await api.chat(question, activeId);
      setMessages((current) => [
        ...current,
        { role: 'assistant', text: answer.answer, citations: answer.citations }
      ]);
      if (answer.conversationId !== activeId) {
        setActiveId(answer.conversationId);
      }
      await refreshConversations();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Chat request failed.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="chat">
      <aside className="conversation-list">
        <button type="button" className="new-chat" onClick={startNewConversation}>
          + New chat
        </button>
        {conversations.map((conversation) => (
          <div
            key={conversation.id}
            className={`conversation ${conversation.id === activeId ? 'active' : ''}`}
          >
            <button type="button" onClick={() => void openConversation(conversation.id)}>
              <span className="title">{conversation.title}</span>
              <span className="timestamp">{new Date(conversation.updatedAt).toLocaleString()}</span>
            </button>
            <button
              type="button"
              className="delete"
              title="Delete conversation"
              onClick={() => void removeConversation(conversation.id)}
            >
              ×
            </button>
          </div>
        ))}
      </aside>

      <div className="messages-pane">
        <div className="messages">
          {messages.length === 0 && <p className="empty">Ask a question about your documents.</p>}
          {messages.map((message, index) => (
            <div key={index} className={`message ${message.role}`}>
              <div className="text">{message.text}</div>
              {message.citations && message.citations.length > 0 && (
                <ul className="citations">
                  {message.citations.map((citation, i) => (
                    <li key={`${citation.documentId}-${citation.chunkIndex}-${i}`}>
                      <strong>
                        [{i + 1}] {citation.filename}
                        {citation.page ? `, p. ${citation.page}` : ''}
                      </strong>
                      <span>{citation.snippet}</span>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          ))}
          {busy && <div className="message assistant pending">Thinking…</div>}
        </div>

        {error && <p className="error">{error}</p>}

        <form className="composer" onSubmit={send}>
          <input
            type="text"
            value={input}
            placeholder="Ask a question…"
            onChange={(event) => setInput(event.target.value)}
            disabled={busy}
          />
          <button type="submit" disabled={busy || input.trim().length === 0}>
            Send
          </button>
        </form>
      </div>
    </section>
  );
}
