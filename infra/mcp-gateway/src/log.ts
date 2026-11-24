/**
 * Metadata-only log lines: which Mac, which grant, which method and tool, the
 * status, the latency and the size. Never arguments, chat content, codes,
 * credentials or tokens; callers pass only these fields.
 */
export interface LogFields {
  event: 'mcp' | 'register' | 'unregister' | 'connect' | 'authorize' | 'oauth_error';
  mac?: string;
  grant?: string;
  method?: string;
  tool?: string;
  status?: number;
  outcome?: string;
  ms?: number;
  bytes?: number;
  code?: string;
}

export function log(fields: LogFields): void {
  console.log(JSON.stringify(fields));
}

const METHODS = new Set(['initialize', 'ping', 'tools/list', 'tools/call', 'notifications/initialized',
  'notifications/cancelled', 'resources/list', 'prompts/list']);
const TOOLS = new Set(['listar_chats_abertos', 'ler_chat', 'buscar_nos_chats', 'atividade_recente']);

/** The JSON-RPC method and tool name, only when they're names this feed knows. */
export function describeCall(body: string): { method?: string; tool?: string } {
  try {
    const m = JSON.parse(body);
    const method = typeof m?.method === 'string' && METHODS.has(m.method) ? m.method : undefined;
    const tool = method === 'tools/call' && typeof m?.params?.name === 'string' && TOOLS.has(m.params.name) ? m.params.name : undefined;
    return { method, tool };
  } catch {
    return {};
  }
}
