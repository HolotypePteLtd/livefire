---
title: How rooms work
description: How a room processes input, sends snapshots, and handles reconnects.
---

When a player joins, the room assigns them a player ID and sends the current state. On each simulation tick, the room authority updates the game. The server sends snapshots at a separately configured rate. For example, a physics room can simulate at 60 Hz and send positions at 20 Hz.

## Where data goes

The Dart `server_sdk` package handles live rooms. The optional [`livefire_atproto_server` package](https://github.com/HolotypePteLtd/livefire/tree/master/packages/atproto_server) adds account services and public match records. The self-hosted node bundles both. A room-only game can depend on `server_sdk` by itself.

| When a player… | What handles it | What is saved |
| --- | --- | --- |
| Moves, chats, or sends a relay `publish` or `publishRoom` command | The room server sends updates to connected players. | The built-in rooms hold game state and recent chat in memory. Restarting the node clears both. |
| Joins a room on the self-hosted node | The node checks the join token and opens the room connection. | The node’s SQLite database keeps the room configuration and consumed token IDs. After a restart, the next join recreates the room from its configuration. |
| Signs in with an AT Protocol handle | The player’s account provider verifies them. Livefire uses their verified account ID in the room and can cache their public profile. | Signing in creates no game record on the player’s PDS. The ordinary guest flow needs only a room token. |
| Agrees to publish a match result | The game calls `MatchEventPublisher.publishMatchEvent` with the player’s authorized session. | The player’s PDS stores a public record in their repository. An achievement can also be published when enabled. |

A **PDS** (Personal Data Server) hosts an account and its records. **Jetstream** distributes changes to public AT Protocol records. An external app can subscribe to published results there. Livefire sends gameplay directly over the room connection and does not use Jetstream.

For example, players can see a wall as soon as a game adds it to the room state. If the wall should still exist tomorrow, the game must save its geometry and placement. Signing in with a PDS does not save the wall or produce a replay.

## Where state comes from

In a [relay room](/docs/shared-state-rooms/), a player publishes values under keys you define. The server checks that the player owns the key and is within its quotas. In a [physics room](/docs/physics-rooms/), players send inputs and the server calculates their positions. For game-specific logic, implement [`RoomAuthority`](/spec/room-authority.md) in Dart.

The same `RoomHub` can run behind a WebSocket listener, in your game process with an in-memory transport, or in a browser worker. On a dedicated node your backend manages rooms through the [HTTP API](/docs/api/).

## Snapshots and reconnects

About once a second, the server sends a full snapshot called a *baseline*. Each subsequent delta contains the changes since that baseline. If a client misses a delta, it can still apply the next one to the same baseline. Snapshot numbers are rounded to four decimal places.

Clients acknowledge received state. A stalled client can receive a fresh baseline while the rest of the room continues. After a disconnect, the room reserves the player’s slot for 15 seconds. A valid resume within that window restores the player ID and state. See the [WebSocket client guide](/docs/protocol-clients/) for the handshake.

## Chat and moderation

Chat uses the room connection. A player can send four single-line messages per ten seconds, up to 280 characters each. New arrivals receive up to 100 recent messages. Position pings expire after eight seconds.

The leader can lock the room, kick a player, or ban a signed-in account. Account bans apply to the verified DID for the life of the room. Signed-in players can also have a display name and avatar in the roster.
