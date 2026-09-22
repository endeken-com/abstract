import type { JSX } from 'react';
import { Card, Field, Mono, Muted, Section } from './ui';
import { useDebouncedSetting } from './hooks';

export const DEFAULT_WORKTREE_TEMPLATE = '{home}/.backtick/worktrees/{repo}-{hash}/{slug}';
export const DEFAULT_BRANCH_PREFIX = 'backtick/';

/** The example every preview is drawn from, so the shape is always concrete. */
const SAMPLE = {
  home: '~',
  repo: 'api',
  hash: '9f2c1ab',
  slug: 'fix-login',
} as const;

const TOKEN_DOCS: { token: string; meaning: string }[] = [
  { token: '{home}', meaning: 'Your home directory on the machine that runs the agent.' },
  { token: '{repo}', meaning: 'The repository folder name, e.g. api.' },
  { token: '{hash}', meaning: 'Short hash of the repository path, so same-named repos never collide.' },
  { token: '{slug}', meaning: 'The session name, lowercased and hyphenated, e.g. fix-login.' },
  { token: '{branch}', meaning: 'The full branch name, prefix included.' },
  { token: '{prefix}', meaning: 'The branch prefix set below.' },
];

/** Substitutes the six tokens client-side; nothing here touches the filesystem. */
export function renderWorktreePreview(template: string, branchPrefix: string): string {
  const branch = `${branchPrefix}${SAMPLE.slug}`;
  const values: Record<string, string> = {
    home: SAMPLE.home,
    repo: SAMPLE.repo,
    hash: SAMPLE.hash,
    slug: SAMPLE.slug,
    branch,
    prefix: branchPrefix,
  };
  return template.replace(/\{(home|repo|hash|slug|branch|prefix)\}/g, (whole, key: string) =>
    key in values ? values[key] : whole,
  );
}

export function WorktreesSection(): JSX.Element {
  const [template, setTemplate] = useDebouncedSetting(
    'worktree_template',
    DEFAULT_WORKTREE_TEMPLATE,
  );
  const [prefix, setPrefix] = useDebouncedSetting('branch_prefix', DEFAULT_BRANCH_PREFIX);

  const pathPreview = renderWorktreePreview(template, prefix);
  const branchPreview = `${prefix}${SAMPLE.slug}`;

  return (
    <Section
      title="Worktrees"
      lead="Every session gets its own git worktree and its own branch. These two patterns decide where that worktree lands and what the branch is called."
    >
      <Card>
        <div className="flex flex-col gap-6">
          <Field
            label="Worktree path template"
            hint="Where a new session's worktree is created. Tokens are substituted per session."
          >
            <input
              className="w-full font-mono"
              style={{ fontSize: 'var(--bt-code-size)' }}
              value={template}
              spellCheck={false}
              onChange={(e) => setTemplate(e.target.value)}
              placeholder={DEFAULT_WORKTREE_TEMPLATE}
            />
          </Field>

          <Field
            label="Branch prefix"
            hint="Prepended to every branch Backtick creates, so its branches are easy to spot and easy to delete."
          >
            <input
              className="w-full max-w-sm font-mono"
              style={{ fontSize: 'var(--bt-code-size)' }}
              value={prefix}
              spellCheck={false}
              onChange={(e) => setPrefix(e.target.value)}
              placeholder={DEFAULT_BRANCH_PREFIX}
            />
          </Field>
        </div>
      </Card>

      <Card>
        <div className="flex flex-col gap-4">
          <div>
            <span className="font-medium" style={{ color: 'var(--bt-text)' }}>
              Preview
            </span>
            <p className="mt-0.5" style={{ color: 'var(--bt-text-dim)' }}>
              A session called “Fix login” in the repository <Mono>api</Mono> would get:
            </p>
          </div>

          <div className="flex flex-col gap-3">
            <div className="flex flex-col gap-1">
              <span style={{ color: 'var(--bt-text-faint)' }}>Worktree</span>
              <div
                className="px-3 py-2 break-all font-mono"
                style={{
                  background: 'var(--bt-surface-2)',
                  border: '1px solid var(--bt-border)',
                  color: 'var(--bt-accent)',
                  fontSize: 'var(--bt-code-size)',
                }}
              >
                {pathPreview || '—'}
              </div>
            </div>
            <div className="flex flex-col gap-1">
              <span style={{ color: 'var(--bt-text-faint)' }}>Branch</span>
              <div
                className="px-3 py-2 break-all font-mono"
                style={{
                  background: 'var(--bt-surface-2)',
                  border: '1px solid var(--bt-border)',
                  color: 'var(--bt-accent)',
                  fontSize: 'var(--bt-code-size)',
                }}
              >
                {branchPreview || '—'}
              </div>
            </div>
          </div>
        </div>
      </Card>

      <Card>
        <span className="font-medium" style={{ color: 'var(--bt-text)' }}>
          Tokens
        </span>
        <dl className="mt-3 flex flex-col gap-2">
          {TOKEN_DOCS.map((doc) => (
            <div key={doc.token} className="flex flex-col gap-0.5 sm:flex-row sm:gap-4">
              <dt className="w-24 shrink-0 font-mono" style={{ fontSize: 'var(--bt-code-size)' }}>
                {doc.token}
              </dt>
              <dd className="m-0" style={{ color: 'var(--bt-text-dim)' }}>
                {doc.meaning}
              </dd>
            </div>
          ))}
        </dl>
      </Card>

      <Muted>
        Changing these affects sessions created from now on. Worktrees that already exist stay where
        they are.
      </Muted>
    </Section>
  );
}
