import { useEffect, type ReactNode } from 'react';

export function Modal({
  title,
  onClose,
  children,
  width = 640,
}: {
  title: string;
  onClose: () => void;
  children: ReactNode;
  width?: number;
}) {
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose();
    }
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);

  return (
    <div
      className="fixed inset-0 z-50 flex items-start justify-center pt-24"
      style={{ background: 'rgba(0,0,0,0.6)' }}
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div
        className="max-h-[70vh] overflow-y-auto p-5"
        style={{
          width,
          background: 'var(--bt-surface)',
          border: '1px solid var(--bt-border-strong)',
        }}
      >
        <h2 className="mb-4 text-sm" style={{ color: 'var(--bt-text)' }}>
          {title}
        </h2>
        {children}
      </div>
    </div>
  );
}
