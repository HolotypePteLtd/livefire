# RoomAuthority — the interface contract

`RoomAuthority` (`packages/protocol/lib/src/room_authority.dart`) is the entire
game-side surface of a room: validation, simulation and snapshots. The hub
(`RoomHub`) owns every networking concern — transports, handshakes, acks, rate
limits, baselining, deltas, chat, moderation — and calls into the authority at
precise, documented points. Networking code never imports game types and vice
versa.

```dart
abstract interface class RoomAuthority {
  int get capacity;
  int get tick;
  double get elapsed;
  void update(double seconds);
  Object? validateJoin(Map<String, dynamic> message);
  void addPlayer(String id, String name, Object? joinData);
  void resume(String id, Object? joinData);
  void disconnect(String id);
  void removePlayer(String id);
  Map<String, dynamic> welcome(String id);
  void command(String id, Map<String, dynamic> message);
  Map<String, dynamic> snapshot();
  void dispose();
}
```

All calls happen on the room's single isolate, synchronously, either from the
pump loop (`pumpSeconds` / the periodic timer) or from the transport message
handler. There is no concurrency control to write; there is also no
re-entrancy: the hub never calls the authority from inside another authority
call.

## Method reference

### `int get capacity`

Maximum connected players. Read by the hub when a **fresh join** arrives:
`_peers.length >= capacity` refuses the join with a `StateError('Room is
full')` → `error` frame + close 1008. Also validated `>= 1` at `RoomHub`
construction (smaller values throw `ArgumentError`).

**Invariants:** stable or growable during live operation is fine — the hub
re-reads it per join; shrinking below the current peer count does not evict
anyone.

### `int get tick`

Simulation tick counter. Read every pump to decide the snapshot cadence
(`tick - lastSnapshot >= snapshotTicks`) and the recovery cadence for stalled
receivers (`tick - peer.recoveryTick < simulationHz`).

**Invariants:** integer, monotonic non-decreasing, advanced in `update()`.
It is the room's clock; the hub never writes it.

### `double get elapsed`

Simulated seconds. Drives two timeouts: the **resume grace window**
(`elapsed - disconnectedAt > resumeGrace` reaps the player) and the **stall
eviction clock** (`elapsed - lastAckAt > 5` while a receiver is blocked).

**Invariants:** advanced in `update()` by the same `seconds` the hub passed
in (directly or accumulated). Must not jump wildly: wall-clock stalls are
clamped by the fixed-step clock, and `elapsed` should reflect that clamped
time, not real time.

### `void update(double seconds)`

Advance the simulation by one fixed step. Called only from the fixed-step
clock: `seconds` is always exactly `1 / simulationHz` (default step 1/120 s).
The clock clamps catch-up to **0.1 s per advance**, so a stalled process never
dilates simulated time — `update` may be called many times back-to-back after
a stall, each with the same fixed step.

**When:** started by `hub.start()` (periodic timer) or driven manually via
`hub.pumpSeconds(seconds)` (tests, externally driven hosts).

**Invariants:** must advance `tick` and `elapsed`; must not throw (an
exception propagates out of the pump into the timer/test). This is the only
method that mutates simulated state on a schedule.

### `Object? validateJoin(Map<String, dynamic> message)`

Inspect the raw decoded `join` message — including game-specific fields (the
relay template reads its `creatorToken` claim here, for example). Called on
**every handshake, fresh join and resume alike**, before any hub or authority
state changes.

**Return:** an opaque `joinData` object the hub hands back to `addPlayer` /
`resume`.

**Invariants:** throw `FormatException` or `StateError` to reject the join —
the message text is forwarded to the client in an `error` frame and the
transport closes 1008. Keep it pure: it runs before the peer exists, and on
resume it runs on every reconnect attempt.

### `void addPlayer(String id, String name, Object? joinData)`

A brand-new player joined. `id` is the hub-assigned stable peer id (`p1`,
`p2`, …) used in every later call and in `snapshot().players`; `name` is the
trimmed 1–24 character display name; `joinData` is what `validateJoin`
returned.

**When:** fresh joins only (never resumes), after `validateJoin` and before
`welcome`/snapshot frames are sent.

**Invariants:** allocate per-player state here. Do not throw — the peer is
registered after this call returns; a throw aborts the handshake mid-way (the
client gets an error frame + close 1008). Reject players in `validateJoin`
instead.

### `void resume(String id, Object? joinData)`

The peer has a live transport again. Called on **every successful handshake —
fresh joins too** (right after `addPlayer` for joins, after token validation
for resumes), after `peer.transport` is attached and ack counters reset.

**Invariants:** reset transient per-player state that should not survive a
reconnect (the physics template clears held input here). Receiving `resume`
without a preceding `disconnect` means this is a fresh join. Do not throw.

### `void disconnect(String id)`

The peer's transport was lost (network drop, close, eviction candidate).
The player's **slot stays reserved** for `resumeGrace` (default 15 s): the
roster still lists them with `connected: false`, their row survives in
snapshots, and a resume with their token restores everything.

**Invariants:** stop depending on live input; keep state. Replaced
transports (resume elsewhere) trigger `disconnect` on the old transport
before `resume` arrives on the new one. Do not throw.

### `void removePlayer(String id)`

The player is gone for good. Called on: a `leave` frame, a kick/ban, or the
resume grace window expiring (reap). The hub also removes the peer from its
roster, social state and any ban bookkeeping it owns.

**Invariants:** release all per-player resources; no further calls reference
this id (ids are never reused). Do not throw.

### `Map<String, dynamic> welcome(String id)`

Per-player join payload. Spread into the `welcome` frame. The hub forces
`type`, `protocol`, `id`, `resume` and `capacity` afterwards — same-named keys
are overwritten.

**When:** once per successful handshake, before the baseline snapshot.

**Invariants:** must be JSON-encodable and small (it rides the reliable
control lane inside the 4 KB frame budget). Examples: the counter game
returns `{'sequence': 0}`; the physics template adds the assigned spawn
point.

### `void command(String id, Map<String, dynamic> message)`

Everything else a client sends: any post-handshake frame whose type is not
`join`/`ack`/`chat`/`ping`/`moderate`/`leave`. The message arrives verbatim
(including `type` and any piggybacked `ack` field), after the hub's 120
packets/s input rate limit and stall buffering.

**Invariants:** an exception thrown here is treated as a **protocol error**
(`error` frame + close 1008) — if bad input should be survivable, catch it
yourself and drop-and-count instead (the platform templates do exactly this:
relay rejects over-quota publishes, physics rejects invalid inputs, neither
ever throws). Commands reference ids from `addPlayer`/`resume`. Input is
never trusted: it is a request, state is authoritative in `snapshot()`.

### `Map<String, dynamic> snapshot()`

The complete authoritative state. Called on every successful handshake and at
every snapshot cut (`snapshotHz`).

**Invariants:**

- Must be a fresh JSON-encodable map (the encoder detaches and retains it as
  a baseline — never return a live mutable reference you keep mutating).
- Must contain integer `epoch` and `tick` keys: the encoder keys baselines on
  them, and epoch changes force a new baseline on every receiver.
- Conventionally `type: 'snapshot'` plus game state under `players`/`room`
  (relay rows, physics poses + config echo) — the shape beyond `epoch`/
  `tick` is entirely game-defined.
- Floats are quantized to 4 decimal places at the encoder; there is no need
  to round in the authority.
- Must not throw.

### `void dispose()`

Called exactly once, when the room closes (`hub.close()`), after all
transports are closed. No further calls follow.

## Optional: `RoomSocialAuthority`

```dart
abstract interface class RoomSocialAuthority {
  String? get roomLeaderId;
  PingLocation? pingLocation(String playerId, String kind);
}
```

- `roomLeaderId` — declares the leader instead of the hub's first-connected
  peer fallback (relay/physics rooms return the creator). Read on every
  roster broadcast and moderation check.
- `pingLocation(playerId, kind)` — the authoritative coordinates for a ping
  (`here`/`help`/`ball`); `null` declines the ping (the player gets a
  `socialNotice`). Coordinates **never** come from the client's ping frame.

## A complete (minimal) implementation

```dart
class CounterAuthority implements RoomAuthority {
  final counters = <String, int>{};
  @override
  int capacity = 8, tick = 0;
  @override
  double elapsed = 0;
  @override
  void update(double seconds) { elapsed += seconds; tick++; }
  @override
  Object? validateJoin(Map<String, dynamic> message) => null;
  @override
  void addPlayer(String id, String name, Object? data) => counters[id] = 0;
  @override
  void resume(String id, Object? data) {}
  @override
  void disconnect(String id) {}
  @override
  void removePlayer(String id) => counters.remove(id);
  @override
  Map<String, dynamic> welcome(String id) => {'sequence': 0};
  @override
  void command(String id, Map<String, dynamic> message) {
    if (message['type'] == 'increment') counters[id] = counters[id]! + 1;
  }
  @override
  Map<String, dynamic> snapshot() => {
    'type': 'snapshot', 'epoch': 0, 'tick': tick, 'time': elapsed,
    'players': {for (final e in counters.entries) e.key: {'count': e.value}},
  };
  @override
  void dispose() {}
}
```

*Generated from `packages/protocol/lib/src/room_authority.dart` and the call
sites in `packages/protocol/lib/src/room_hub.dart`. Cross-checked by
`site/scripts/check-spec.mjs` at build time.*
