import { useEffect, useRef, useState } from 'react';
import type * as MonacoApi from 'monaco-editor';
import { diff } from '../../lib/ipc';
import { languageForPath, setupMonaco } from '../../lib/monaco';
import type { FileDiff } from '../../lib/types';
import { MONO_FONT, codeFontSize, errText } from './lib';

interface Pair {
  original: MonacoApi.editor.ITextModel;
  modified: MonacoApi.editor.ITextModel;
}

function disposePair(pair: Pair | null): void {
  if (!pair) return;
  pair.original.dispose();
  pair.modified.dispose();
}

/**
 * One diff editor for the whole pane. Models are created per file and disposed
 * as soon as they are replaced — a long review session otherwise leaks a model
 * for every file the user clicks.
 */
export function MonacoDiff({
  sessionId,
  file,
  sideBySide,
  hideUnchanged,
  revision,
}: {
  sessionId: string;
  file: FileDiff;
  sideBySide: boolean;
  hideUnchanged: boolean;
  revision: number;
}): React.JSX.Element {
  const hostRef = useRef<HTMLDivElement | null>(null);
  const editorRef = useRef<MonacoApi.editor.IStandaloneDiffEditor | null>(null);
  const modelsRef = useRef<Pair | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;
    const monaco = setupMonaco();
    const editor = monaco.editor.createDiffEditor(host, {
      theme: 'abstract',
      readOnly: true,
      originalEditable: false,
      automaticLayout: true,
      renderOverviewRuler: false,
      scrollBeyondLastLine: false,
      minimap: { enabled: false },
      fontFamily: MONO_FONT,
      fontSize: codeFontSize(),
      lineNumbersMinChars: 4,
      padding: { top: 12, bottom: 12 },
      renderSideBySide: true,
      hideUnchangedRegions: { enabled: false },
    });
    editorRef.current = editor;
    return () => {
      editor.setModel(null);
      editor.dispose();
      editorRef.current = null;
      disposePair(modelsRef.current);
      modelsRef.current = null;
    };
  }, []);

  useEffect(() => {
    editorRef.current?.updateOptions({
      renderSideBySide: sideBySide,
      hideUnchangedRegions: { enabled: hideUnchanged },
    });
  }, [sideBySide, hideUnchanged]);

  const { path, old_path: oldPath, status, binary } = file;

  useEffect(() => {
    let cancelled = false;
    setError(null);

    if (binary) {
      setLoading(false);
      editorRef.current?.setModel(null);
      disposePair(modelsRef.current);
      modelsRef.current = null;
      return () => {
        cancelled = true;
      };
    }

    setLoading(true);
    void (async () => {
      try {
        const contents = await diff.fileContents(sessionId, path);
        let original = contents.original;
        // A rename's pre-image lives under the old path at HEAD; the IPC only
        // resolves one path per call, so fetch the old side separately.
        if (status === 'renamed' && oldPath) {
          original = (await diff.fileContents(sessionId, oldPath)).original;
        }
        if (cancelled) return;
        const monaco = setupMonaco();
        const language = languageForPath(path);
        const next: Pair = {
          original: monaco.editor.createModel(original, language),
          modified: monaco.editor.createModel(contents.modified, language),
        };
        const editor = editorRef.current;
        if (cancelled || !editor) {
          disposePair(next);
          return;
        }
        const previous = modelsRef.current;
        modelsRef.current = next;
        editor.setModel({ original: next.original, modified: next.modified });
        disposePair(previous);
        setLoading(false);
      } catch (e) {
        if (cancelled) return;
        setError(errText(e));
        setLoading(false);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [sessionId, path, oldPath, status, binary, revision]);

  return (
    <div className="relative flex-1 min-h-0" style={{ background: 'var(--bt-bg)' }}>
      <div ref={hostRef} className="absolute inset-0" style={{ visibility: binary ? 'hidden' : 'visible' }} />
      {binary ? (
        <Overlay>
          <span style={{ color: 'var(--bt-text-dim)' }}>
            Binary file — no text diff to show.
          </span>
        </Overlay>
      ) : error ? (
        <Overlay>
          <pre
            className="font-mono text-sm whitespace-pre-wrap break-words m-0"
            style={{ color: 'var(--bt-removed)' }}
          >
            {error}
          </pre>
        </Overlay>
      ) : loading ? (
        <Overlay>
          <span style={{ color: 'var(--bt-text-faint)' }}>Loading file…</span>
        </Overlay>
      ) : null}
    </div>
  );
}

function Overlay({ children }: { children: React.ReactNode }): React.JSX.Element {
  return (
    <div
      className="absolute inset-0 flex items-center justify-center px-8 text-center"
      style={{ background: 'var(--bt-bg)' }}
    >
      <div className="max-w-xl">{children}</div>
    </div>
  );
}
