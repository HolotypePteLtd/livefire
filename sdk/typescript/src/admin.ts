/**
 * The admin namespace — the control plane as three lines of backend
 * code. `Livefire.admin(apiKey)` wraps the node's existing `/v1` routes
 * (`docs/control_plane_api.md`) with fetch; nothing is invented here,
 * and the API key never belongs in client code.
 *
 * ```ts
 * const of = Livefire.admin(API_KEY);
 * const room = await of.createRoom({ template: 'relay', capacity: 16 });
 * const { joinToken } = await of.mintToken(room, playerName);
 * ```
 */

/** A room as `POST /v1/rooms` returns it (plus the lookup extras). */
export interface AdminRoom {
  roomId: string;
  roomKey: string;
  template: string;
  url: string;
  joinToken: string;
  joinTokenExpiresAt: string;
  creatorToken: string;
  createdAt: string;
  status: string;
}

/** A minted one-time join token (`POST /v1/rooms/:id/tokens`). */
export interface MintedToken {
  joinToken: string;
  joinTokenExpiresAt: string;
  creatorToken?: string;
}

/** One row of `GET /v1/rooms`. */
export interface RoomListing {
  roomId: string;
  roomKey: string;
  template: string;
  status: string;
  createdAt: string;
  peers: number;
  capacity: number;
  url: string;
}

/**
 * `createRoom` options. Pass a full `config` for anything specific; omit
 * it for the documented defaults per template (relay: chat on, a `pose`
 * player key and a `phase` room key — the walkthrough's example room).
 */
export interface CreateRoomOptions {
  template: 'relay' | 'physics';
  /** Room capacity (default 16). */
  capacity?: number;
  /** Full room config; defaults per template when omitted (relay only). */
  config?: Record<string, unknown>;
  /**
   * Extra top-level request fields, passed through verbatim in the
   * `POST /v1/rooms` body. The node ignores unknown fields today; this
   * exists so control-plane additions — e.g. the key-scope features
   * (`maxRooms`, `templates`) the panel mints onto API keys — can be
   * exercised against a node without waiting for an SDK release.
   */
  extra?: Record<string, unknown>;
}

/** Everything `Livefire.admin(...)` returns. */
export interface AdminApi {
  createRoom(options: CreateRoomOptions): Promise<AdminRoom>;
  mintToken(
    room: string | { roomId: string },
    playerName?: string,
  ): Promise<MintedToken>;
  listRooms(): Promise<{ rooms: RoomListing[]; nextCursor?: string }>;
  deleteRoom(roomId: string): Promise<void>;
}

/** The relay default config — the docs walkthrough's example room. */
function defaultRelayConfig(capacity: number): Record<string, unknown> {
  return {
    version: 1,
    template: 'relay',
    capacity,
    chat: true,
    maxRows: 64,
    totalBytes: 32768,
    playerKeys: {
      pose: { maxBytes: 256, publishesPerSecond: 10 },
    },
    roomKeys: {
      phase: { maxBytes: 64, publishesPerSecond: 1 },
    },
  };
}
export function admin(
  apiKey: string,
  host = 'https://play.holotype.com.sg',
): AdminApi {
  const base = host.endsWith('/') ? host.slice(0, -1) : host;

  async function call(
    method: string,
    path: string,
    body?: unknown,
  ): Promise<{ status: number; json: () => Promise<unknown>; text: string }> {
    const response = await fetch(`${base}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${apiKey}`,
        ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    const json = async () => (text === '' ? {} : JSON.parse(text));
    if (!response.ok) {
      let error: { error?: { code?: string; message?: string } } = {};
      try {
        error = (await json()) as {
          error?: { code?: string; message?: string };
        };
      } catch {
        // Non-JSON error body (e.g. HTML 502/504 from reverse proxy).
      }
      throw new Error(
        `${method} ${path} failed (${response.status}` +
          `${error.error?.code ? ' ' + error.error.code : ''}): ` +
          `${error.error?.message ?? text}`,
      );
    }
    return { status: response.status, json, text };
  }

  return {
    async createRoom(options: CreateRoomOptions): Promise<AdminRoom> {
      const config =
        options.config ??
        (options.template === 'relay' ? defaultRelayConfig(16) : undefined);
      if (config === undefined) {
        throw new Error(
          'createRoom: the physics template needs an explicit config ' +
            '(colliders, spawn points, movement) — see docs/physics-rooms',
        );
      }
      // An explicit capacity option wins over whatever the config carries.
      const finalConfig =
        options.capacity === undefined
          ? config
          : { ...config, capacity: options.capacity };
      const response = await call('POST', '/v1/rooms', {
        template: options.template,
        config: finalConfig,
        // Scope fields and future body additions flow through verbatim.
        ...options.extra,
      });
      return (await response.json()) as AdminRoom;
    },

    async mintToken(
      room: string | { roomId: string },
      // playerName is for the caller's bookkeeping; the node mints
      // bearer tokens and does not label them.
      _playerName?: string,
    ): Promise<MintedToken> {
      const roomId = typeof room === 'string' ? room : room.roomId;
      const response = await call(
        'POST',
        `/v1/rooms/${encodeURIComponent(roomId)}/tokens`,
        {},
      );
      return (await response.json()) as MintedToken;
    },

    async listRooms() {
      const response = await call('GET', '/v1/rooms');
      return (await response.json()) as {
        rooms: RoomListing[];
        nextCursor?: string;
      };
    },

    async deleteRoom(roomId: string): Promise<void> {
      await call('DELETE', `/v1/rooms/${encodeURIComponent(roomId)}`);
    },
  };
}
