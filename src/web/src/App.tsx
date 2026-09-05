import { useEffect, useState } from 'react';
import { getSignedInUser, login, logout, type SignedInUser } from './auth';
import { DocumentsView } from './components/DocumentsView';
import { ChatView } from './components/ChatView';

type Tab = 'chat' | 'documents';

export default function App() {
  const [user, setUser] = useState<SignedInUser | null>(null);
  const [ready, setReady] = useState(false);
  const [tab, setTab] = useState<Tab>('chat');

  useEffect(() => {
    void (async () => {
      setUser(await getSignedInUser());
      setReady(true);
    })();
  }, []);

  if (!ready) {
    return <main className="loading">Loading…</main>;
  }

  if (!user) {
    return (
      <main className="loading">
        <h1>RAG Workspace</h1>
        <p>Sign in with your organizational account to continue.</p>
        <button type="button" onClick={login}>
          Sign in
        </button>
      </main>
    );
  }

  return (
    <div className="app">
      <header>
        <h1>RAG Workspace</h1>
        <nav>
          <button type="button" className={tab === 'chat' ? 'active' : ''} onClick={() => setTab('chat')}>
            Chat
          </button>
          <button
            type="button"
            className={tab === 'documents' ? 'active' : ''}
            onClick={() => setTab('documents')}
          >
            Documents
          </button>
        </nav>
        <div className="user">
          <span>{user.name}</span>
          <button type="button" onClick={logout}>
            Sign out
          </button>
        </div>
      </header>

      <main>{tab === 'chat' ? <ChatView /> : <DocumentsView />}</main>
    </div>
  );
}
