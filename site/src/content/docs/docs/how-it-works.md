---
title: How it works
description: Your rules run on a steady server clock; every player sees the same state, even over flaky networks.
---

A quick mental model of what Livefire does under the hood — useful for the *"wait, why does it work like that?"* moments.

## 1. One source of truth

```text
  Player A ── input / command ──► ┌──────────────────────────┐ ── baseline / delta ──► Player A
                                  │     Authoritative Room   │
  Player B ── input / command ──► │   (steady fixed clock)   │ ── baseline / delta ──► Player B
                                  └──────────────────────────┘
```

- **Rules run on the server.** You either configure a built-in [room template](/docs/templates/) (JSON only) or write a custom `RoomAuthority` class in Dart.
- **Clients never trust each other.** Players send requests (`input`, `publish`, `chat`); the server validates them and broadcasts the resulting state.
- **Zero networking boilerplate.** Transport, framing, rate limits, and reconnects are handled by `RoomHub`.

## 2. Same engine, any hosting shape

Moving from local play to a dedicated internet server is a configuration change, not a rewrite:

| Hosting shape | How it runs |
| :--- | :--- |
| **Dedicated server** | One Livefire node hosts hundreds of rooms behind HTTPS + `/v1` HTTP API. |
| **In-process / player-hosted** | `RoomHub` runs directly inside your game process or browser worker over an in-memory or peer transport. |

## 3. Built for flaky connections

```text
  t = 0.0s   [ FULL BASELINE ]  ◄── reliable full snapshot (every ~1 s)
  t = 0.05s  [ delta vs 0.0s ]  ◄── small diff
  t = 0.10s  [ delta vs 0.0s ]  ◄── dropped? next delta still applies cleanly!
  t = 0.15s  [ delta vs 0.0s ]  ◄── still diffs against t = 0.0s
  t = 1.0s   [ FULL BASELINE ]  ◄── fresh reference point
```

- **Loss-resilient deltas:** Every delta diffs against the last full **baseline**, never against another delta. A lost or reordered packet can never corrupt future frames.
- **Compact updates:** Floats are rounded to 4 decimal places automatically.
- **Lag isolation:** A slow player receives recovery frames instead of stalling the room. Silent receivers are evicted after ~5 seconds.
- **15-second reconnect grace:** If a player's Wi-Fi drops, their slot, ID, state, and chat history stay reserved for 15 seconds so the client can resume seamlessly.

## 4. Built-in social layer

Every room includes chat, roster, pings, and moderation on the same connection:

| Capability | Default limit / behavior |
| :--- | :--- |
| **Chat** | Single-line, 280 chars max, 4 msgs / 10 s per player, 100-message history |
| **Pings** | Server-verified positions (`here`, `help`, `ball`), fade after 8 s (bubbles 10 s) |
| **Moderation** | Room leader can `lock`, `kick`, or `ban` (up to 256 account-bound bans) |
| **Profiles** | Signed-in AT Protocol players automatically display their name and avatar on the roster |

## Go deeper

- Ready to run it? Follow [Instant multiplayer server](/docs/multiplayer-server/).
- Need exact frame formats? See [Wire protocol](/docs/protocol/) or [`rooms-protocol.json`](/spec/rooms-protocol.json).
