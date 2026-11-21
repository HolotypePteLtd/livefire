# Room Templates & Config Schema (v1)

A **room template** is a built-in server authority configured entirely with JSON — no server code required. Submit a config to `POST /v1/rooms`, and Openfire validates it, pins it verbatim, and runs the room.

---

## Choosing a template

| Template | Who decides truth? | How clients interact | Best for |
| :--- | :--- | :--- | :--- |
| **`relay`** | **Players** (quota-enforced) | Publish JSON values to declared `playerKeys` / `roomKeys` | Casual games, lobbies, presence, turn-based state |
| **`physics`** | **Server** (ReactPhysics3D) | Send directional/action inputs; server simulates poses | Competitive movement, obstacle worlds, anti-cheat |

```text
  Relay room                                   Physics room
  ──────────                                   ────────────
  Client ── publish {key, value} ──► Server    Client ── input {moveX, moveZ, jump} ──► Server
             (checks ownership & quotas)                  (clamps, simulates physics)
  Client ◄── baseline / delta ───── Server     Client ◄── authoritative pose {x,y,z,yaw} ── Server
```

---

## Common rules (all templates)

Every config shares this envelope:

```json
{
  "version": 1,
  "template": "relay",
  "capacity": 16,
  "chat": true
}
```

- **`version`** *(required)* — must be `1`.
- **`template`** *(required)* — `"relay"` or `"physics"`.
- **`capacity`** *(required)* — integer `1–128` players.
- **`chat`** *(optional, default `true`)* — chat/pings toggle (moderation always stays enabled).
- **Strict validation:** Unknown fields are rejected. Numbers must be finite; strings reject hidden control characters and bidi overrides; sizes are counted in UTF-8 bytes.
- **Append-only pinning:** Configs are pinned verbatim at room creation so stored rooms validate identically across upgrades.

---

## 1. Relay template (`relay`)

State is structured as `players[peerId][key]` (each player writes only their own row) and `room[key]` (room leader only).

### Example config

```json
{
  "version": 1,
  "template": "relay",
  "capacity": 16,
  "chat": true,
  "maxRows": 64,
  "totalBytes": 32768,
  "playerKeys": {
    "pose": { "maxBytes": 256, "publishesPerSecond": 10 },
    "emote": { "maxBytes": 96, "publishesPerSecond": 2 }
  },
  "roomKeys": {
    "phase": { "maxBytes": 64, "publishesPerSecond": 1 }
  }
}
```

### Schema & limits

| Field | Limit / rule |
| :--- | :--- |
| `capacity` | Integer `1–128` |
| `maxRows` | Integer `1–1024` (combined non-empty player rows + room keys) |
| `totalBytes` | Integer `1–262144` (total encoded UTF-8 bytes across the room) |
| `playerKeys` | Object, `1–16` keys matching `^[a-z][a-zA-Z0-9_]{0,31}$` |
| `roomKeys` | Object, `0–16` keys (same key-name pattern) |
| `*.maxBytes` | Integer `1–2048` (UTF-8 encoded size of the value) |
| `*.publishesPerSecond` | Integer `1–30` (sliding 1 s window per key per publisher) |

### Client messages

```json
{ "type": "publish",     "key": "pose",  "value": { "x": 1.25, "y": 0, "z": -3.5 } }
{ "type": "publishRoom", "key": "phase", "value": "started" }
```

- **Soft rejections:** Invalid or over-quota writes are **dropped and counted, never disconnected** — the next valid publish succeeds. (Raw packet floods are still capped at 120 pkt/s and 4 KB by `RoomHub`.)
- **Leader & pings:** The room creator (presenting `creatorToken`) is the leader. Pings (`here`, `help`, `ball`) read `x`/`y`/`z` from any published player key that contains finite coordinates.

### Snapshot shape

```json
{
  "type": "snapshot",
  "epoch": 0,
  "tick": 210,
  "time": 3.5,
  "players": {
    "p1": { "pose": { "x": 1.25, "y": 0, "z": -3.5 } }
  },
  "room": {
    "phase": "started"
  }
}
```

---

## 2. Physics template (`physics`)

Server-simulated character movement over static colliders (`MovementTemplateAuthority` + `physics_react3d`). Players send inputs only; positions and yaw are computed server-side and replicated via the same baseline/delta lane.

### Example config

```json
{
  "version": 1,
  "template": "physics",
  "capacity": 32,
  "chat": true,
  "inputsPerSecond": 60,
  "tick": { "simulationHz": 60, "snapshotHz": 20 },
  "colliders": {
    "boxes": [
      { "name": "floor", "center": [0, -0.5, 0], "halfExtents": [50, 0.5, 50] }
    ],
    "capsules": [
      { "name": "pillar", "base": [10, 0, 4], "top": [10, 3, 4], "radius": 0.4 }
    ],
    "heightfield": {
      "size": [64, 64],
      "data": [ /* (nx + 1) × (nz + 1) row-major heights in meters */ ]
    }
  },
  "spawnPoints": [
    { "position": [0, 1, 0], "yaw": 0 }
  ],
  "movement": {
    "walkSpeed": 4.5,
    "runSpeed": 8.0,
    "gravity": -9.81,
    "jumpSpeed": 5.2,
    "airControl": 0.35,
    "acceleration": 40.0
  },
  "inputMapping": {
    "moveX": { "type": "axis", "range": [-1, 1] },
    "moveZ": { "type": "axis", "range": [-1, 1] },
    "jump": { "type": "action" },
    "sprint": { "type": "action" }
  }
}
```

### Schema & limits

| Section | Rules |
| :--- | :--- |
| `tick` | `simulationHz`: `10–240`, `snapshotHz`: `1–60` (`snapshotHz ≤ simulationHz`) |
| `colliders` | At least one collider total (`boxes`, `capsules`, or `heightfield`). `halfExtents`/`radius` in `(0, 500]`; capsule `‖top − base‖ > 2·radius`; `heightfield.size` in `16–1024` per axis with `(nx+1)×(nz+1)` finite heights in `[-10000, 10000]` |
| `spawnPoints` | `1–64` entries (`position` = feet coordinates, round-robin on join) |
| `movement` | `walkSpeed`/`runSpeed`: `0.1–100`, `gravity`: `-30–0`, `jumpSpeed`: `0–50`, `airControl`: `0–1`, `acceleration`: `0.1–500` |
| `inputMapping` | `1–16` fields. `moveX` and `moveZ` must be `axis` (`min < max`); `jump`/`sprint` (if present) must be `action` |
| `inputsPerSecond` | Optional int `1–240` (default: `tick.simulationHz`) |

### Client input messages

```json
{ "type": "input", "moveX": 0.5, "moveZ": -1, "jump": false, "sprint": true }
```

- Only fields declared in `inputMapping` (plus `type`) are accepted; unknown fields or wrong types drop the message without consuming rate budget.
- Axis values are clamped to their declared range and normalized to the unit circle — speed is strictly server-owned.
- `jump` is rising-edge with a **0.25 s** landing buffer; grounded checks raycast below the player capsule (default radius `0.4 m`, height `1.8 m`).

### Snapshot shape

```json
{
  "type": "snapshot",
  "epoch": 0,
  "tick": 1200,
  "time": 20.0,
  "players": {
    "p1": { "pose": { "x": 4.25, "y": 0.9, "z": -3.5, "yaw": 1.57 } }
  },
  "room": {
    "template": "physics",
    "simulationHz": 60,
    "snapshotHz": 20,
    "movement": { "...": "echoed movement parameters" },
    "spawnPoints": [ { "position": [0, 1, 0], "yaw": 0 } ],
    "colliders": { "boxes": 1, "capsules": 1, "heightfield": [64, 64] }
  }
}
```

The `welcome` frame also includes the player's assigned spawn (`"spawn": { "x", "y", "z", "yaw" }`). Heightfield sample arrays are never echoed in snapshots — clients render geometry from the pinned room config.
