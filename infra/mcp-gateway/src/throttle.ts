import { DurableObject } from 'cloudflare:workers';
import type { Env } from './env';

/**
 * Attempts by one client IP for one purpose (registering, typing a code,
 * connecting), so guessing codes or credentials is slow. Counts only.
 */
export class Throttle extends DurableObject<Env> {
  /** Counts an attempt; false when `limit` were already made in the last `windowMs`. */
  async hit(limit: number, windowMs: number): Promise<boolean> {
    const now = Date.now();
    const recent = ((await this.ctx.storage.get<number[]>('hits')) ?? []).filter((t) => t > now - windowMs);
    if (recent.length >= limit) {
      await this.ctx.storage.put('hits', recent);
      return false;
    }
    recent.push(now);
    await this.ctx.storage.put('hits', recent);
    await this.ctx.storage.setAlarm(now + windowMs);
    return true;
  }

  async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }
}

export const LIMITS = {
  register: { limit: 10, windowMs: 60 * 60 * 1000 },
  code: { limit: 10, windowMs: 10 * 60 * 1000 },
  connect: { limit: 30, windowMs: 10 * 60 * 1000 },
} as const;

/** The client's IPv4 address, or its IPv6 /64: one host can rotate through a /64, not past it. */
export function clientIp(request: Request): string {
  const ip = request.headers.get('CF-Connecting-IP') ?? 'unknown';
  if (!ip.includes(':')) return ip;
  const [head, tail = ''] = ip.split('::');
  const left = head ? head.split(':') : [];
  const right = tail ? tail.split(':') : [];
  const full = [...left, ...Array(Math.max(0, 8 - left.length - right.length)).fill('0'), ...right];
  return `${full.slice(0, 4).map((h) => parseInt(h || '0', 16).toString(16)).join(':')}::/64`;
}

export async function allowed(env: Env, purpose: keyof typeof LIMITS, request: Request): Promise<boolean> {
  const { limit, windowMs } = LIMITS[purpose];
  return env.THROTTLE.get(env.THROTTLE.idFromName(`${purpose}:${clientIp(request)}`)).hit(limit, windowMs);
}
