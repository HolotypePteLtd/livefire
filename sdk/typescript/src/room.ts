/**
 * The room session: join/resume handshake, snapshots with acks, the
 * 12 Hz command lane, chat, roster and clean close — over one WebSocket
 * speaking the documented JSON wire protocol
 * (`docs/protocol.md`, `site/public/spec/rooms-protocol.json`).
 *
 * Wire behavior mirrored from the reference implementation
 * (`packages/protocol/lib/src/room_hub.dart`):
 * - join sends `{type:'join', protocol, name}`; the hub answers `welcome`
 *   (id, one-time resume token, capacity), then the baseline, an initial
 *   snapshot and the roster with chat history;
 * - every applied state frame is acknowledged (`{type:'ack', ack: tick}`) —
 *   a receiver that stops acking is eventually evicted;
 * - commands are arbitrary game JSON frames (`{type:'increment', …}`)
 *   passed to the room's rules; the SDK caps the send rate at 12 Hz so a
 *   caller cannot trip the server's packet limit (120/s);
 * - on an unexpected socket close the SDK reconnects with the resume
 *   token inside the 15 s grace window and restores the same player id,
 *   roster and chat history;
 * - `{type:'leave'}` is the clean exit; it releases the slot immediately.
 */

import { SnapshotDecoder } from './codec.ts';
import type { GameState } from './codec.ts';

/** One chat line (player or system). */
export interface ChatMessage {
  id: number;
  playerId: string;
  playerName: string;
  text: string;
  system: boolean;
}

/** One roster member (`type:'social'` frames). */
export interface RoomMember {
  id: string;
  name: string;
  connected: boolean;
  canBan: boolean;
  profile?: Record<string, unknown>;
}

export interface Roster {
  leaderId: string | null;
  locked: boolean;
  members: RoomMember[];
}

/** Terminal or notable session events surfaced through `onEvent`. */
export type RoomEvent =
  | { kind: 'reconnecting'; attempt: number }
  | { kind: 'reconnected'; id: string }
  | { kind: 'notice'; message: string }
  | { kind: 'closed'; reason: 'leave' | 'evicted' | 'error'; message?: string };

export interface RoomOptions {
  /**
   * The room URL straight from the API (`room.url`,
   * `ws(s)://host/play/<roomKey>`) — the alternative to `host` +
   * `roomKey`. A `?token=` query on it is used as the join token when
   * `joinToken` is not given explicitly. Provide either `url` or
   * `host` + `roomKey`, not both.
   */
  url?: string;
  /** Node origin, e.g. `http://localhost:8790` (`ws(s)` is derived). */
  host?: string;
  roomKey?: string;
  /** Player name, 1–24 characters. */
  name: string;
  /**
   * One-time join token from the node's API (`POST /v1/rooms` or
   * `POST /v1/rooms/:id/tokens`). When present it is sent as
   * `?token=<joinToken>` on the `/play/<roomKey>` URL — the node's
   * pre-upgrade gate validates and consumes it. Omit only against a
   * listener without the token gate (local `RoomServer`), or when the
   * `url` already carries `?token=`.
   */
  joinToken?: string;
  /**
   * Origin to present to servers with an `allowedOrigins` allowlist.
   * Browsers send `Origin` automatically and cannot set it — this is
   * for Node and other non-browser clients, passed to a custom
   * `socketFactory` (see the README's Node/Origin section); the default
   * socket path ignores it.
   */
  origin?: string;
  /** Game protocol version; must match the server exactly. */
  protocol?: number;
  /** Override for tests and Node clients: a WebSocket factory (Node and browsers ship one). */
  socketFactory?: SocketFactory;
  /** Join timeout in ms (default 5000, mirroring the hub). */
  joinTimeoutMs?: number;
}

/**
 * A WebSocket factory. Receives the final URL (already carrying
 * `?token=<joinToken>` when one was given) and the [`RoomOptions.origin`]
 * value, so non-browser clients can open a headers-capable socket —
 * Node's built-in WebSocket sends no `Origin` header and servers with an
 * origin allowlist reject it (browsers cannot set `Origin` at all, which
 * is why the option travels here rather than into the socket).
 */
export type SocketFactory = (
  url: string,
  options: { origin?: string },
) => WebSocket;

/** Commands are queued and drained at 12 Hz (server cap: 120 packets/s). */
const COMMAND_INTERVAL_MS = 1000 / 12;
/** Resume grace on the hub is 15 s; stop trying a little before it ends. */
const RESUME_WINDOW_MS = 12_000;

function toWebSocketUrl(
  host: string,
  roomKey: string,
  joinToken?: string,
): string {
  const url = new URL(host);
  url.protocol =
    url.protocol === 'https:' || url.protocol === 'wss:' ? 'wss:' : 'ws:';
  url.pathname = `/play/${encodeURIComponent(roomKey)}`;
  // searchParams encodes once and merges with any query the host already
  // carries — a bare `+=` would double-encode or clobber it.
  if (joinToken !== undefined) url.searchParams.set('token', joinToken);
  return url.toString();
}

/** Accepts a `url` in place of `host` + `roomKey`; validates the pair. */
function resolveTarget(options: RoomOptions): {
  host: string;
  roomKey: string;
  joinToken?: string;
} {
  const hasUrl = options.url !== undefined;
  const hasHostKey = options.host !== undefined || options.roomKey !== undefined;
  if (hasUrl && hasHostKey) {
    throw new Error('join: pass either url or host + roomKey, not both');
  }
  if (!hasUrl && (options.host === undefined || options.roomKey === undefined)) {
    throw new Error('join: needs url, or host + roomKey');
  }
  if (!hasUrl) {
    return {
      host: options.host!,
      roomKey: options.roomKey!,
      joinToken: options.joinToken,
    };
  }
  const parsed = new URL(options.url!);
  if (
    parsed.protocol !== 'ws:' &&
    parsed.protocol !== 'wss:' &&
    parsed.protocol !== 'http:' &&
    parsed.protocol !== 'https:'
  ) {
    throw new Error(`join: unsupported url protocol ${parsed.protocol}`);
  }
  const match = /^\/play\/([A-Za-z0-9_-]+)$/.exec(parsed.pathname);
  if (match === null) {
    throw new Error('join: url must be <ws(s)://host>/play/<roomKey>');
  }
  const scheme =
    parsed.protocol === 'https:' || parsed.protocol === 'wss:' ? 'wss' : 'ws';
  return {
    host: `${scheme}://${parsed.host}`,
    roomKey: match[1],
    joinToken: options.joinToken ?? parsed.searchParams.get('token') ?? undefined,
  };
}

export class Room {
  private readonly opts: Required<Pick<RoomOptions, 'protocol'>> &
    RoomOptions;
  private readonly target: { host: string; roomKey: string; joinToken?: string };
  private readonly decoder = new SnapshotDecoder();
  private readonly stateSubs = new Set<(s: GameState) => void>();
  private readonly chatSubs = new Set<(m: ChatMessage) => void>();
  private readonly eventSubs = new Set<(e: RoomEvent) => void>();
  private readonly queue: Record<string, unknown>[] = [];
  private socket: WebSocket | null = null;
  private drainTimer: ReturnType<typeof setInterval> | null = null;
  private joinTimeout: ReturnType<typeof setTimeout> | null = null;
  private joinWaiter: { resolve: () => void; reject: (e: Error) => void } | null =
    null;
  private closedByUser = false;
  private leftWaiter: Promise<void> | null = null;

  // Session facts.
  playerId = '';
  capacity = 0;
  resumeToken: string | null = null;
  state: GameState | null = null;
  chatHistory: ChatMessage[] = [];
  roster: Roster = { leaderId: null, locked: false, members: [] };

  private constructor(opts: RoomOptions) {
    this.opts = { ...opts, protocol: opts.protocol ?? 1 };
    this.target = resolveTarget(opts);
  }

  /** Joins a room; resolves once the first state frame is applied. */
  static async join(options: RoomOptions): Promise<Room> {
    const room = new Room(options);
    await room.connect();
    return room;
  }

  private connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      const url = toWebSocketUrl(
        this.target.host,
        this.target.roomKey,
        this.target.joinToken,
      );
      const socket = this.opts.socketFactory
        ? this.opts.socketFactory(url, { origin: this.opts.origin })
        : new WebSocket(url);
      this.socket = socket;
      this.joinWaiter = { resolve, reject };
      this.joinTimeout = setTimeout(() => {
        if (this.joinWaiter) {
          this.joinWaiter.reject(new Error('Join timed out'));
          this.joinWaiter = null;
        }
        socket.close(4000, 'Join timeout');
      }, this.opts.joinTimeoutMs ?? 5000);

      socket.onmessage = (ev: MessageEvent) => {
        if (typeof ev.data !== 'string') return; // JSON lane only
        this.handleFrame(ev.data);
      };
      socket.onopen = () => {
        const frame: Record<string, unknown> = {
          type: 'join',
          protocol: this.opts.protocol,
          name: this.opts.name,
        };
        if (this.resumeToken !== null) frame['resume'] = this.resumeToken;
        socket.send(JSON.stringify(frame));
      };
      socket.onclose = () => this.handleClose();
      socket.onerror = () => {
        /* onclose follows; nothing to do here. */
      };
    });
  }

  private failJoin(message: string) {
    if (this.joinTimeout !== null) {
      clearTimeout(this.joinTimeout);
      this.joinTimeout = null;
    }
    if (this.joinWaiter) {
      const { reject } = this.joinWaiter;
      this.joinWaiter = null;
      reject(new Error(message));
    }
  }

  private resolveJoin() {
    if (this.joinTimeout !== null) {
      clearTimeout(this.joinTimeout);
      this.joinTimeout = null;
    }
    if (this.joinWaiter) {
      this.joinWaiter.resolve();
      this.joinWaiter = null;
    }
    // Commands queued while disconnected resume draining now that the
    // socket is live again (only command() restarts the timer otherwise).
    if (this.queue.length > 0) this.startDrain();
  }

  private handleFrame(text: string) {
    let msg: Record<string, unknown>;
    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }
    switch (msg['type']) {
      case 'welcome': {
        this.playerId = msg['id'] as string;
        this.resumeToken = msg['resume'] as string;
        this.capacity = msg['capacity'] as number;
        return;
      }
      case 'baseline': {
        this.decoder.decode(msg);
        return;
      }
      case 'snapshot':
      case 'state': {
        const decoded = this.decoder.decode(msg);
        if (decoded === null) return; // stale delta; next baseline repairs
        this.state = decoded;
        // Ack every applied frame — the hub evicts silent receivers.
        this.send({ type: 'ack', ack: decoded['tick'] as number });
        for (const sub of this.stateSubs) sub(decoded);
        this.resolveJoin();
        return;
      }
      case 'social': {
        this.roster = {
          leaderId: (msg['leaderId'] as string | null) ?? null,
          locked: msg['locked'] === true,
          members: (msg['members'] as RoomMember[]) ?? [],
        };
        if (Array.isArray(msg['history'])) {
          this.chatHistory = msg['history'] as ChatMessage[];
        }
        return;
      }
      case 'chat': {
        const message = msg['message'] as ChatMessage;
        this.chatHistory = [...this.chatHistory, message].slice(-100);
        for (const sub of this.chatSubs) sub(message);
        return;
      }
      case 'socialNotice':
        this.emit({ kind: 'notice', message: msg['message'] as string });
        return;
      case 'removed':
        this.resumeToken = null;
        this.emit({
          kind: 'closed',
          reason: 'evicted',
          message: msg['message'] as string,
        });
        this.failJoin(String(msg['message'] ?? 'Removed by host'));
        this.socket?.close();
        return;
      case 'left':
        this.emit({ kind: 'closed', reason: 'leave' });
        this.failJoin('Room closed the connection');
        this.socket?.close();
        return;
      case 'error':
        this.emit({
          kind: 'closed',
          reason: 'error',
          message: msg['message'] as string,
        });
        this.failJoin(String(msg['message'] ?? 'Protocol error'));
        this.socket?.close();
        return;
    }
  }

  private handleClose() {
    if (this.socket === null) return;
    this.socket = null;
    this.stopDrain();
    if (this.closedByUser) return;
    if (this.resumeToken === null) {
      this.failJoin('Connection closed');
      this.emit({ kind: 'closed', reason: 'error', message: 'Connection closed' });
      return;
    }
    // Unexpected loss: reconnect with the resume token inside the grace
    // window, backing off briefly between attempts.
    let attempt = 0;
    const startedAt = Date.now();
    const retry = () => {
      if (this.closedByUser || this.socket !== null) return;
      if (Date.now() - startedAt > RESUME_WINDOW_MS) {
        this.emit({
          kind: 'closed',
          reason: 'error',
          message: 'Resume window expired',
        });
        return;
      }
      attempt += 1;
      this.emit({ kind: 'reconnecting', attempt });
      this.connect().then(
        () => this.emit({ kind: 'reconnected', id: this.playerId }),
        () => setTimeout(retry, 250),
      );
    };
    setTimeout(retry, 150);
  }

  private emit(event: RoomEvent) {
    for (const sub of this.eventSubs) sub(event);
  }

  /** Sends raw JSON on the wire (handshake and ack path). */
  private send(frame: Record<string, unknown>) {
    if (this.socket !== null && this.socket.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify(frame));
    }
  }

  private startDrain() {
    if (this.drainTimer !== null) return;
    this.drainTimer = setInterval(() => {
      if (this.socket === null) {
        this.stopDrain();
        return;
      }
      const frame = this.queue.shift();
      if (frame === undefined) {
        this.stopDrain();
        return;
      }
      this.send(frame);
    }, COMMAND_INTERVAL_MS);
  }

  private stopDrain() {
    if (this.drainTimer !== null) {
      clearInterval(this.drainTimer);
      this.drainTimer = null;
    }
  }

  // ---- Public surface ----------------------------------------------------

  /** Sends a command (game JSON). Queued; drained at 12 Hz. */
  command(frame: Record<string, unknown>): void {
    if (this.closedByUser) throw new Error('Room is closed');
    this.queue.push(frame);
    this.startDrain();
  }

  /** Chat lane: send a line, read history, subscribe to new lines. */
  readonly chat = {
    /** Sends one chat line (single-line, <= 280 chars; the room rate-limits). */
    send: (text: string): void => this.command({ type: 'chat', text }),
    /** Chat history received so far (capped at 100, like the room). */
    messages: (): readonly ChatMessage[] => this.chatHistory,
    /** Subscribes to incoming lines; returns an unsubscribe function. */
    on: (sub: (message: ChatMessage) => void): (() => void) => {
      this.chatSubs.add(sub);
      return () => this.chatSubs.delete(sub);
    },
  };

  /** Subscribes to decoded state; returns an unsubscribe function. */
  onState(sub: (state: GameState) => void): () => void {
    this.stateSubs.add(sub);
    return () => this.stateSubs.delete(sub);
  }

  /** Subscribes to chat lines; returns an unsubscribe function. */
  onChat(sub: (message: ChatMessage) => void): () => void {
    this.chatSubs.add(sub);
    return () => this.chatSubs.delete(sub);
  }

  /** Subscribes to session events; returns an unsubscribe function. */
  onEvent(sub: (event: RoomEvent) => void): () => void {
    this.eventSubs.add(sub);
    return () => this.eventSubs.delete(sub);
  }

  /**
   * Simulates an unexpected connection loss (test hook): drops the socket
   * without `leave`, exactly like wifi going away, so the resume path runs.
   */
  dropConnection(): void {
    if (this.socket !== null) this.socket.close(4001, 'Dropped');
  }

  /** Leaves cleanly: `leave` frame, then close. Resolves once closed. */
  close(): Promise<void> {
    if (this.closedByUser) return this.leftWaiter ?? Promise.resolve();
    this.closedByUser = true;
    this.leftWaiter = new Promise((resolve) => {
      const socket = this.socket;
      if (socket === null) {
        resolve();
        return;
      }
      socket.addEventListener('close', () => resolve(), { once: true });
      this.send({ type: 'leave' });
      setTimeout(() => socket.close(1000, 'Bye'), 50);
    });
    return this.leftWaiter;
  }
}
