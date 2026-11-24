import { DurableObject } from 'cloudflare:workers';
import type { Env } from './env';

/**
 * One connection code (ABS-220), named by the code's HMAC so the name says
 * nothing: which Mac it opens, until it's used once or expires. The code
 * itself is never stored.
 */
export class ConnectCode extends DurableObject<Env> {
  async put(macId: string, expiresAt: number): Promise<void> {
    await this.ctx.storage.put({ macId, expiresAt });
    await this.ctx.storage.setAlarm(expiresAt);
  }

  /** The Mac, once: the code is gone after this, whatever the answer. */
  async take(): Promise<string | null> {
    const [macId, expiresAt] = [await this.ctx.storage.get<string>('macId'), await this.ctx.storage.get<number>('expiresAt')];
    await this.ctx.storage.deleteAll();
    return macId && expiresAt && expiresAt > Date.now() ? macId : null;
  }

  async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }
}
