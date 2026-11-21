---
title: How rooms work
description: How a room processes input, sends snapshots, and handles reconnects.
---

When a player joins, the room assigns them a player ID and sends the current state. On each simulation tick, the room authority updates the game. The server sends snapshots at a separately configured rate. For example, a physics room can simulate at 60 Hz and send positions at 20 Hz.

## Where state comes from

In a [relay room](/docs/shared-state-rooms/), a player publishes values under keys you define. The server checks that the player owns the key and is within its quotas. In a [physics room](/docs/physics-rooms/), players send inputs and the server calculates their positions. For game-specific logic, implement [`RoomAuthority`](/spec/room-authority.md) in Dart.

The same `RoomHub` can run behind a WebSocket listener, in your game process with an in-memory transport, or in a browser worker. On a dedicated node your backend manages rooms through the [HTTP API](/docs/api/).

## Snapshots and reconnects

About once a second, the server sends a full snapshot called a *baseline*. Each subsequent delta contains the changes since that baseline. If a client misses a delta, it can still apply the next one to the same baseline. Snapshot numbers are rounded to four decimal places.

Clients acknowledge received state. A stalled client can receive a fresh baseline while the rest of the room continues. After a disconnect, the room reserves the player’s slot for 15 seconds. A valid resume within that window restores the player ID and state. See the [WebSocket client guide](/docs/protocol-clients/) for the handshake.

## Chat and moderation

Chat uses the room connection. A player can send four single-line messages per ten seconds, up to 280 characters each. New arrivals receive up to 100 recent messages. Position pings expire after eight seconds.

The leader can lock the room, kick a player, or ban a signed-in account. Account bans apply to the verified DID for the life of the room. Signed-in players can also have a display name and avatar in the roster.
