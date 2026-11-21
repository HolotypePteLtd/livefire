/**
 * Unit tests for the snapshot codec, with fixtures derived from the
 * reference encoder semantics in `packages/protocol/lib/src/
 * snapshot_codec.dart` (and its Dart tests): baseline-relative deltas,
 * nested patches, remove lists, presence of explicit zero/false/null,
 * stale-base rejection and the `initial: true` display-frame rule.
 */
import { test } from 'node:test';
import assert from 'node:assert';

import { SnapshotDecoder, applyDelta } from '../src/codec.ts';

test('a baseline becomes the decode base and is returned whole', () => {
  const d = new SnapshotDecoder();
  const frame = {
    type: 'baseline',
    epoch: 0,
    tick: 10,
    players: { p1: { count: 0 } },
  };
  const out = d.decode(frame);
  assert.deepStrictEqual(out, frame);
  assert.equal(d.baseline?.['tick'], 10);
});

test('a state delta applies nested patches against the base', () => {
  const d = new SnapshotDecoder();
  d.decode({ type: 'baseline', epoch: 0, tick: 10, players: { p1: { count: 0 } } });
  const out = d.decode({
    type: 'state',
    base: 10,
    epoch: 0,
    tick: 20,
    delta: {
      set: {
        tick: 20,
        time: 1.25,
        players: { patch: { set: { p1: { patch: { set: { count: 3 } } } } } },
      },
    },
  });
  assert.ok(out);
  assert.equal(out!['tick'], 20);
  assert.equal(out!['time'], 1.25);
  const players = out!['players'] as Record<string, { count: number }>;
  assert.equal(players.p1.count, 3);
});

test('a delta with the wrong base tick is dropped, not corrupted', () => {
  const d = new SnapshotDecoder();
  d.decode({ type: 'baseline', epoch: 0, tick: 10, players: {} });
  const stale = d.decode({
    type: 'state',
    base: 9, // reordered/late frame
    epoch: 0,
    tick: 18,
    delta: { set: { tick: 18 } },
  });
  assert.equal(stale, null);
});

test('a delta with a different epoch is dropped until a new baseline', () => {
  const d = new SnapshotDecoder();
  d.decode({ type: 'baseline', epoch: 0, tick: 10, players: {} });
  assert.equal(
    d.decode({ type: 'state', base: 10, epoch: 1, tick: 12, delta: {} }),
    null,
  );
  d.decode({ type: 'baseline', epoch: 1, tick: 12, players: {} });
  assert.ok(
    d.decode({ type: 'state', base: 12, epoch: 1, tick: 14, delta: {} }),
  );
});

test('remove deletes keys; explicit zero, false and null survive', () => {
  const base = { a: 1, b: 2, x: 9, y: true, z: 'keep' };
  const out = applyDelta(base, {
    remove: ['a'],
    set: { b: 0, x: false, y: null, z2: 'new' },
  });
  assert.ok(!('a' in out));
  assert.equal(out['b'], 0);
  assert.equal(out['x'], false);
  assert.equal(out['y'], null);
  assert.equal(out['z'], 'keep');
  assert.equal(out['z2'], 'new');
});

test('an initial snapshot is displayed but never becomes the base', () => {
  const d = new SnapshotDecoder();
  d.decode({ type: 'baseline', epoch: 0, tick: 10, players: {} });
  // Join handshake: full snapshot with initial:true right after baseline.
  const initial = d.decode({
    type: 'snapshot',
    initial: true,
    epoch: 0,
    tick: 10,
    players: {},
  });
  assert.ok(initial);
  assert.equal(d.baseline?.['tick'], 10); // base untouched
  // The following delta still applies against the original baseline.
  const after = d.decode({
    type: 'state',
    base: 10,
    epoch: 0,
    tick: 16,
    delta: { set: { tick: 16 } },
  });
  assert.ok(after);
  assert.equal(after!['tick'], 16);
});

test('a plain snapshot (no initial flag) refreshes the base', () => {
  const d = new SnapshotDecoder();
  d.decode({ type: 'baseline', epoch: 0, tick: 10, players: {} });
  d.decode({ type: 'snapshot', epoch: 0, tick: 30, players: { p1: { count: 7 } } });
  assert.equal(d.baseline?.['tick'], 30);
  const after = d.decode({
    type: 'state',
    base: 30,
    epoch: 0,
    tick: 36,
    delta: { set: { tick: 36 } },
  });
  assert.ok(after);
  assert.equal(after!['tick'], 36);
});
