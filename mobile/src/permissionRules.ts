import { displayDate, type PermissionDecision, type PermissionRule, type PermissionRuleKind, type Snapshot } from './types';

// Permission answers remembered per project on the Mac. The suggestion,
// matching and expiry rules live there (PermissionRule.swift); this mirrors
// only what the phone needs to offer the same "remember this answer" sheet.

function unwrapShell(raw: string): string {
  const s = raw.trim();
  for (const shell of ['/bin/zsh', '/bin/bash', '/bin/sh', 'zsh', 'bash', 'sh']) {
    for (const flag of [' -lc ', ' -c ']) {
      if (!s.startsWith(shell + flag)) continue;
      let body = s.slice(shell.length + flag.length);
      const quote = body[0];
      if ((quote !== '"' && quote !== "'") || body.length < 2 || body.at(-1) !== quote) continue;
      body = body.slice(1, -1);
      if (quote === '"') body = body.replaceAll('\\"', '"').replaceAll('\\$', '$').replaceAll('\\`', '`').replaceAll('\\\\', '\\');
      return body;
    }
  }
  return s;
}

function commands(input: any): string[] {
  const raw = typeof input?.command === 'string' ? input.command.trim() : '';
  if (!raw) return [];
  const unwrapped = unwrapShell(raw);
  return unwrapped === raw ? [raw] : [raw, unwrapped];
}

function paths(input: any, root?: string): string[] {
  const out: string[] = [];
  for (const key of ['file_path', 'filePath', 'notebook_path', 'path']) {
    const path = typeof input?.[key] === 'string' ? input[key] : '';
    if (!path) continue;
    if (root) {
      const base = root.endsWith('/') ? root : root + '/';
      if (path.startsWith(base)) out.push(path.slice(base.length));
    }
    out.push(path);
    if (path.startsWith('./')) out.push(path.slice(2));
  }
  return out;
}

/// The rule to pre-fill the "remember this answer" sheet with, from the
/// request being asked about — the same suggestion the Mac makes.
export function suggestedRule(toolName: string, input: any, root?: string | null): { kind: PermissionRuleKind; pattern: string } {
  const command = commands(input).at(-1);
  if (command) return { kind: 'command', pattern: command };
  const path = paths(input, root || undefined)[0];
  if (path) {
    const slash = path.indexOf('/');
    if (slash > 0) return { kind: 'path', pattern: path.slice(0, slash) + '/**' };
    return { kind: 'path', pattern: path };
  }
  return { kind: 'tool', pattern: toolName };
}

export function buildRule({ id, projectId, kind, pattern, decision, expiresInDays, now }: {
  id: string; projectId: string; kind: PermissionRuleKind; pattern: string;
  decision: PermissionDecision; expiresInDays: number | null; now: number;
}): PermissionRule {
  return { id, projectId, kind, pattern: pattern.trim(), decision, expiresAt: expiresInDays == null ? null : now + expiresInDays * 86400, createdAt: now };
}

export function isRuleExpired(rule: PermissionRule, now: number): boolean {
  return rule.expiresAt != null && rule.expiresAt <= now;
}

const KIND_TITLES: Record<PermissionRuleKind, string> = { command: 'Command', path: 'Path', tool: 'Tool' };
export function ruleKindTitle(kind: PermissionRuleKind): string { return KIND_TITLES[kind]; }

/// The detail line under a rule in project settings, as on the Mac.
export function ruleDetail(rule: PermissionRule, now: number): string {
  let text = `${rule.decision === 'allow' ? 'Always allow' : 'Always deny'} · ${KIND_TITLES[rule.kind]}`;
  if (rule.expiresAt != null) text += isRuleExpired(rule, now) ? ` · expired ${displayDate(rule.expiresAt)}` : ` · expires ${displayDate(rule.expiresAt)}`;
  return text;
}

export function rulesForProject(snapshot: Pick<Snapshot, 'permissionRules'> | null | undefined, projectId: string): PermissionRule[] {
  return [...(snapshot?.permissionRules?.[projectId] || [])].sort((a, b) => a.createdAt - b.createdAt);
}

// Swift encodes `savePermissionRule(PermissionRule)` as {"_0": rule} and
// `deletePermissionRule(id:)` by its label, like the automation requests.
export function saveRuleArgs(rule: PermissionRule) { return { _0: rule }; }
export function deleteRuleArgs(rule: PermissionRule) { return { id: rule.id }; }
