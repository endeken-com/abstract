import { Component, type ErrorInfo, type ReactNode } from 'react';
import { RotateCcw, TriangleAlert } from 'lucide-react';

/**
 * A render error inside one view must never blank the whole window. The
 * boundary shows what broke and lets the developer carry on; `resetKey`
 * clears it automatically when they navigate elsewhere.
 */
export class ErrorBoundary extends Component<
  { children: ReactNode; resetKey?: string; label?: string },
  { error: Error | null }
> {
  state = { error: null as Error | null };

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('[Backtick] view crashed', error, info.componentStack);
  }

  componentDidUpdate(prev: { resetKey?: string }) {
    if (prev.resetKey !== this.props.resetKey && this.state.error) this.setState({ error: null });
  }

  render() {
    if (!this.state.error) return this.props.children;
    return (
      <div className="flex h-full items-center justify-center p-8">
        <div
          className="flex w-full max-w-[520px] flex-col gap-3 rounded-[14px] p-5"
          style={{ background: 'var(--bt-surface)', boxShadow: 'inset 0 0 0 1px var(--bt-border-strong)' }}
        >
          <div className="flex items-center gap-2.5">
            <TriangleAlert size={16} style={{ color: 'var(--bt-removed)' }} />
            <p className="text-[14px] font-medium" style={{ color: 'var(--bt-text)' }}>
              {this.props.label ?? 'This view'} hit an error
            </p>
          </div>
          <pre
            className="bt-selectable max-h-40 overflow-auto whitespace-pre-wrap rounded-[9px] px-3 py-2 font-mono text-[11.5px]"
            style={{ background: 'var(--bt-surface-2)', color: 'var(--bt-text-dim)' }}
          >
            {this.state.error.message}
          </pre>
          <p className="text-[12.5px]" style={{ color: 'var(--bt-text-faint)' }}>
            Your agents keep running; only this view stopped rendering.
          </p>
          <button
            onClick={() => this.setState({ error: null })}
            className="inline-flex h-8 w-fit items-center gap-1.5 rounded-[8px] px-3 text-[13px] transition-colors hover:bg-[var(--bt-surface-4)]"
            style={{ background: 'var(--bt-surface-3)', color: 'var(--bt-text)', boxShadow: 'inset 0 0 0 1px var(--bt-border-strong)' }}
          >
            <RotateCcw size={13} /> Try again
          </button>
        </div>
      </div>
    );
  }
}
