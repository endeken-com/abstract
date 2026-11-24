/**
 * The Mac ↔ gateway socket protocol, version 1. PROTOCOL.md describes it for
 * the Mac side. Every message is one JSON text frame with `v` and `type`; the
 * heartbeat is the bare text `ping`, answered `pong` without waking the DO.
 */

export const PROTOCOL_VERSION = 1;

/** `"*"`: every project on the Mac. Otherwise the Mac's project ids. */
export type Projects = '*' | string[];

export interface GrantSummary {
  id: string;
  clientName: string;
  clientDomain?: string;
  projects: Projects;
  phi: boolean;
  createdAt: number;
  revokedAt?: number;
  lastUsedAt?: number;
}

// Gateway → Mac

export interface Hello { v: 1; type: 'hello'; macId: string; grants: GrantSummary[] }
export interface Call { v: 1; type: 'call'; id: string; grantId: string; projects: Projects; phi: boolean; body: string }
export interface ConsentRequest {
  v: 1; type: 'consent_request'; id: string; expiresAt: number; scope: string[];
  client: { name: string; domain?: string; redirectHost: string; loopback: boolean };
}
export interface ConnectCodeMessage { v: 1; type: 'connect_code'; id: string; code: string; expiresAt: number }
export interface Ack { v: 1; type: 'ack'; id: string }
export interface ErrorMessage { v: 1; type: 'error'; id?: string; message: string }
export interface GrantRevoked { v: 1; type: 'grant_revoked'; grantId: string }

// Mac → gateway

export interface Result { v: 1; type: 'result'; id: string; status: number; body: string }
export interface ConsentResponse { v: 1; type: 'consent_response'; id: string; approve: boolean; grantId?: string; projects?: Projects; phi?: boolean }
export interface ConnectCodeRequest { v: 1; type: 'connect_code_request'; id: string }
export interface Revoke { v: 1; type: 'revoke'; id: string; grantId: string }
export interface GrantUpdate { v: 1; type: 'grant_update'; id: string; grantId: string; projects: Projects; phi: boolean }

export type FromMac = Result | ConsentResponse | ConnectCodeRequest | Revoke | GrantUpdate;

const ID = /^[A-Za-z0-9_-]{1,64}$/;
export const GRANT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MAX_PROJECTS = 1000;

export function validProjects(value: unknown): value is Projects {
  if (value === '*') return true;
  return Array.isArray(value) && value.length > 0 && value.length <= MAX_PROJECTS &&
    value.every((p) => typeof p === 'string' && p.length > 0 && p.length <= 128);
}

/** A frame from the Mac, or null when it isn't one this version understands. */
export function parseFromMac(text: string): FromMac | null {
  let m: any;
  try { m = JSON.parse(text); } catch { return null; }
  if (!m || typeof m !== 'object' || m.v !== PROTOCOL_VERSION || typeof m.id !== 'string' || !ID.test(m.id)) return null;
  switch (m.type) {
    case 'result':
      return Number.isInteger(m.status) && m.status >= 200 && m.status < 600 && typeof m.body === 'string' ? m : null;
    case 'consent_response':
      if (typeof m.approve !== 'boolean') return null;
      if (!m.approve) return m;
      return typeof m.grantId === 'string' && GRANT_ID.test(m.grantId) && validProjects(m.projects) && typeof m.phi === 'boolean' ? m : null;
    case 'connect_code_request':
      return m;
    case 'revoke':
      return typeof m.grantId === 'string' && GRANT_ID.test(m.grantId) ? m : null;
    case 'grant_update':
      return typeof m.grantId === 'string' && GRANT_ID.test(m.grantId) && validProjects(m.projects) && typeof m.phi === 'boolean' ? m : null;
    default:
      return null;
  }
}

/** A JSON-RPC error body for the gateway's own failures, with the request's id when it had one. */
export function rpcError(requestBody: string | null, code: number, message: string, data?: unknown): string {
  let id: unknown = null;
  try {
    const parsed = requestBody ? JSON.parse(requestBody) : null;
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed) && ('id' in parsed)) {
      const candidate = parsed.id;
      if (typeof candidate === 'string' || typeof candidate === 'number') id = candidate;
    }
  } catch { /* not JSON: id stays null */ }
  return JSON.stringify({ jsonrpc: '2.0', id, error: { code, message, ...(data === undefined ? {} : { data }) } });
}
