/**
 * Snapshot decoding for the Livefire JSON state lane, mirroring the
 * reference `SnapshotDecoder` in `packages/protocol`
 * (`snapshot_codec.dart`).
 *
 * The server sends:
 * - `snapshot` / `baseline` frames carrying the full state (a baseline is
 *   just a snapshot frame the encoder designated as the diff base);
 * - `state` frames carrying a delta relative to that baseline.
 *
 * Deltas are baseline-relative — never delta-relative — so a lost or
 * reordered delta can never corrupt the next one: it is simply dropped
 * until the next full frame arrives (baselines refresh about once per
 * second and on epoch change). A delta applies only when its `base` tick
 * and `epoch` match the baseline the receiver currently holds.
 */

/** A decoded room state. Game-defined JSON plus the framing fields. */
export type GameState = Record<string, unknown> & {
  type?: string;
  tick: number;
  epoch: number;
};

/** The `delta` object of a `state` frame. */
export interface StateDelta {
  remove?: string[];
  set?: Record<string, unknown>;
}

export function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/**
 * Applies one delta patch. Mirrors the reference `_apply`:
 * - `remove` deletes keys;
 * - `set` entries that are plain objects are nested patches applied to the
 *   corresponding object in the base (or `{}` when absent) — the encoder
 *   always wraps nested changes as `{ patch: … }`;
 * - every other `set` entry replaces the value wholesale. Presence masks
 *   on the encode side mean explicit `0` / `false` / `null` arrive as
 *   real values and survive here.
 */
export function applyDelta(
  base: Record<string, unknown>,
  delta: StateDelta,
): Record<string, unknown> {
  const out: Record<string, unknown> = { ...base };
  for (const key of delta.remove ?? []) delete out[key];
  for (const [key, value] of Object.entries(delta.set ?? {})) {
    out[key] = isPlainObject(value)
      ? applyDelta(isPlainObject(base[key]) ? base[key] : {}, value.patch as StateDelta)
      : value;
  }
  return out;
}

/**
 * Streaming decoder: remembers the last adopted baseline and turns the
 * frame sequence into the latest full state. `decode` returns `null` for
 * a delta that does not match the current baseline (stale, reordered or
 * pre-baseline) — callers ignore it and wait for the next full frame.
 */
export class SnapshotDecoder {
  private base: GameState | null = null;

  /** The currently adopted baseline (diagnostics and tests). */
  get baseline(): GameState | null {
    return this.base;
  }

  reset(): void {
    this.base = null;
  }

  decode(packet: Record<string, unknown>): GameState | null {
    const type = packet['type'];
    if (type === 'snapshot' || type === 'baseline') {
      // An `initial: true` snapshot rides the join handshake right after
      // the baseline; it is a display frame and must not move the base.
      if (packet['initial'] !== true) {
        this.base = { ...packet, type: 'snapshot' } as GameState;
      }
      return packet as GameState;
    }
    if (
      type !== 'state' ||
      this.base === null ||
      packet['base'] !== this.base['tick'] ||
      packet['epoch'] !== this.base['epoch']
    ) {
      return null;
    }
    return applyDelta(this.base, packet['delta'] as StateDelta) as GameState;
  }
}
