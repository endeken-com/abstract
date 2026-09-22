import React from 'react';
import ReactDOM from 'react-dom/client';
import { isTauri } from '@tauri-apps/api/core';
import { App } from './app/App';
import './styles.css';

async function boot() {
  // Outside the desktop shell (plain `bun run dev` in a browser) the Rust
  // core is replaced by an in-memory mock so the UI can be built and
  // reviewed with hot reload.
  if (!isTauri()) {
    const { installMock } = await import('./lib/mock');
    installMock();
  }
  ReactDOM.createRoot(document.getElementById('root') as HTMLElement).render(
    <React.StrictMode>
      <App />
    </React.StrictMode>,
  );
}

void boot();
