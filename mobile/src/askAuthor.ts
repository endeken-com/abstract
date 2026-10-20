import type { RemoteClient } from './remote';

/** `absolute` made relative to `root`; null when it isn't inside it. */
export function relativePath(root: string, absolute: string): string | null {
  const clean = root.replace(/\/+$/, '');
  if (!clean || !absolute.startsWith(clean + '/')) return null;
  const relative = absolute.slice(clean.length + 1);
  return relative && !relative.split('/').includes('..') ? relative : null;
}

export type AskAuthorResult = {
  /** The chat that wrote the lines, already unarchived by the Mac; null asks a new chat. */
  sessionId: string | null;
  projectId: string | null;
  /** The Mac-built pre-filled prompt: a reply-box quote, or a new chat's first message. */
  draft: string;
  notice: string | null;
};

export type AskAuthorRequest = {
  root: string;
  path: string;
  lineStart: number;
  lineEnd: number;
  code: string[];
  revision: string | null;
  sessionId: string | null;
};

/** Ask the paired Mac who wrote these lines. Only call it when its snapshot says `codeHistory`. */
export async function askAuthor(mac: RemoteClient, request: AskAuthorRequest): Promise<AskAuthorResult> {
  const response = await mac.request('askAuthor', { ...request });
  const answer = response.askAuthor?._0;
  if (!answer || typeof answer.draft !== 'string') throw Error('The Mac did not answer who wrote this.');
  return {
    sessionId: typeof answer.sessionId === 'string' ? answer.sessionId : null,
    projectId: typeof answer.projectId === 'string' ? answer.projectId : null,
    draft: answer.draft,
    notice: typeof answer.notice === 'string' ? answer.notice : null,
  };
}
