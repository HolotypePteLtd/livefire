# Rooms Wire Protocol

Livefire uses one room engine (`RoomHub`) across every hosting shape — dedicated server, in-process host, or player-hosted peer. Games implement `RoomAuthority` (validation, simulation, snapshots); the networking layer never imports game or physics types.

---

## Hosting shapes

| Shape | Entry point | Transport |
| :--- | :--- | :--- |
| **Dedicated server** | `RoomServer` / `RoomsListener` (`server_sdk`) | WebSocket upgrade on `/play/<roomKey>` |
| **In-process host** | `RoomHub` + `MemoryTransportPair` (`protocol`) | In-memory pipe (no sockets) |
| **Player-hosted / Worker** | `RoomHub` + `BroadcastChannel` or WebRTC adapter | Any `GameConnection` implementation |

---

## Session lifecycle

```text
  Client                                              RoomHub
  ──────                                              ───────
    │  1. {"type":"join", "protocol":1, "name":"Sam"}     │
    ├────────────────────────────────────────────────────►│ validateJoin() + capacity/ban check
    │                                                     │
    │  2. {"type":"welcome", "id":"p1", "resume":"…"}     │
    │  3. {"type":"baseline", "tick":120, …}              │ full quantized reference state
    │  4. {"type":"snapshot", "tick":120, "initial":true} │ display frame
    │  5. {"type":"social", "members":[…], "history":[…]} │ roster + chat history
    │◄────────────────────────────────────────────────────┤
    │                                                     │
    │  6. {"type":"state", "base":120, "tick":123, …}     │ delta frames at snapshotHz
    │◄────────────────────────────────────────────────────┤
    │  7. {"type":"ack", "ack":123}                       │ confirms latest applied tick
    ├────────────────────────────────────────────────────►│
    │                                                     │
    │  8. {"type":"leave"}                                │ clean exit (slot freed immediately)
    ├────────────────────────────────────────────────────►│
    │  9. {"type":"left"}                                 │
    │◄────────────────────────────────────────────────────┤
```

---

## Core mechanics

### 1. Handshake & resume
- **Join timeout:** A fresh transport must send `join` within **5 seconds**. `protocol` must match exactly.
- **Resume grace:** If a connection drops unexpectedly, the peer's slot and state stay reserved for **15 seconds** (configurable). Reconnecting with `resume: "<token>"` restores the same peer ID and replays roster/chat history.
- **Identity binding:** If the transport verified an identity (e.g., an AT Protocol DID), the resume token is bound to that identity — a different identity or guest token cannot hijack the session.

### 2. Fixed-step simulation & snapshots
- The hub advances `RoomAuthority.update(dt)` at `simulationHz` (default **120 Hz**) on a fixed-step clock that clamps catch-up lag at **0.1 s**.
- Snapshots are broadcast at `snapshotHz` (default **20 Hz**) through `SnapshotEncoder`:
  - A **reliable full baseline** refreshes once per second (and on `epoch` change).
  - **Disposable deltas** in between diff against that baseline — never against another delta — so lost or reordered packets never corrupt subsequent state.
  - Floating-point numbers are quantized to **4 decimal places** by default.

### 3. Binary state lane (optional)
- When a room configures a `WireStateCodec` (e.g., FlatBuffers) and the client sends `binaryStates: true` on a binary-capable transport, state frames are sent as binary bytes.
- Binary frames never start with `{` (`0x7B`), so JSON control frames and binary state frames coexist cleanly on the same connection.

### 4. Flow control, rate limits & eviction
- **Client → server cap:** Frames are capped at **4,096 characters** and **120 packets/second** per peer (with a bounded burst allowance of up to 600 packets / 1 s if the host briefly stalls).
- **Stall recovery:** Clients acknowledge applied snapshots via `{"type": "ack", "ack": <tick>}` (or an `ack` field on any control frame). Stalled receivers receive reliable recovery snapshots; receivers unacknowledged for **> 5 seconds** while blocked are closed with `1001`.

---

## Built-in social & moderation

Chat, pings, roster, and moderation share the reliable control lane (`RoomSocialHost` / `RoomSocialClient`):

| Feature | Rules & limits |
| :--- | :--- |
| **Chat** | Single-line, 1–280 chars (control chars & bidi overrides rejected). **4 msgs / 10 s** per player. Last **100** messages kept in history; speech bubbles expire after **10 s**. |
| **Pings** | Kinds: `here`, `help`, `ball`. Coordinates always come from `RoomSocialAuthority.pingLocation`, never the client. **3 / 5 s** per player; expire after **8 s**. |
| **Moderation** | Room leader can `lock` (blocks fresh joins), `kick`, or `ban`. Bans require a transport-verified identity (up to **256** banned identities per room). |
| **Soft rejections** | Invalid or rate-limited chat/ping/moderation returns a `socialNotice` frame to the sender without disconnecting them. |

---

## Packages

- **`packages/protocol`** — `RoomHub`, `RoomAuthority`, codecs, social engine, in-memory & `BroadcastChannel` transports. Zero `dart:io` imports (compiles to JS/Wasm).
- **`packages/client`** — `RoomClient`, interpolated `PlaybackClock`, and native/web WebSocket adapters.
- **`packages/server_sdk`** — Native `RoomServer`, `RoomSupervisor`, `RoomsListener`, and platform authorities.

See [`examples/counter`](https://github.com/HolotypePteLtd/livefire/tree/master/examples/counter) for a complete runnable join → chat → shared-state round trip.
