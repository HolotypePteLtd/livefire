---
title: How rooms work
description: How a room processes input, sends snapshots, and handles reconnects.
---

A **room** is one live multiplayer session. A **node** is a running Livefire server that can host many rooms. When Alice joins a room as a guest, she gets a player ID for that session.

Suppose Alice presses Jump in a physics room. Her game sends that input to the node. The **room authority** is the code that applies the game’s rules. It checks whether Alice is on the ground and works out how she moves. The node sends the players a **snapshot** showing the room at one moment. Bob’s game uses Alice’s position in that snapshot to draw her in the air. That’s a **room update**.

Alice can also sign in with an AT Protocol **account**, an identity she can use across rooms. Her **Personal Data Server (PDS)** hosts the account and its records. If the game offers to publish her match result and Alice agrees, it can write the result to her PDS as a **public record**. A scoreboard could follow those records through **Jetstream**, a feed of public record changes. Her jump stays in the live room.

## Where data goes

| Data | Where it lives |
| --- | --- |
| Player positions, shared values, and recent chat | The built-in rooms keep these in memory. Restarting the node clears them. |
| Room settings and used join tokens | The self-hosted node saves the settings and consumed token IDs in SQLite. After a restart, the next join opens the room with those settings. |
| Player identity and profile | The player’s PDS hosts their account. On sign-in, the node gets a verified account ID and can cache the public profile for the room’s player list. |
| Published match results | On the player’s PDS. Publishing must be enabled, and the game must call `MatchEventPublisher.publishMatchEvent` with the player’s authorized session and consent. Games can also enable achievement records. |

A game can keep its own data beyond a session. For example, a house-building game might save a neighbourhood as a list of houses and their locations. When Alice and Bob visit on Saturday, the **room** is their live session. The game can load the same neighbourhood for another visit on Sunday.

Use the Dart `server_sdk` package to host rooms. Add `livefire_atproto_server` for account sign-in and public match records. The self-hosted node bundles both packages. [AT Protocol server package](https://github.com/HolotypePteLtd/livefire/tree/master/packages/atproto_server).

## Where state comes from

In a [relay room](/docs/shared-state-rooms/), a player updates values under keys you define. The server checks that the player owns the key and is within its quotas. In a [physics room](/docs/physics-rooms/), players send inputs and the server calculates their positions. For game-specific logic, implement [`RoomAuthority`](/spec/room-authority.md) in Dart.

The same `RoomHub` can run behind a WebSocket listener, in your game process with an in-memory transport, or in a browser worker. On a dedicated node your backend manages rooms through the [HTTP API](/docs/api/).

## Snapshots and reconnects

The room updates the simulation and sends snapshots at separate rates. For example, it can run 60 simulation steps per second and send 20 snapshots per second.

About once a second, the server sends a full snapshot called a *baseline*. Each subsequent delta contains the changes since that baseline. If a client misses a delta, it can still apply the next one to the same baseline. Snapshot numbers are rounded to four decimal places.

Clients acknowledge received state. A stalled client can receive a fresh baseline while the rest of the room continues. After a disconnect, the room reserves the player’s slot for 15 seconds. A valid resume within that window restores the player ID and state. See the [WebSocket client guide](/docs/protocol-clients/) for the handshake.

## Chat and moderation

Chat uses the room connection. A player can send four single-line messages per ten seconds, up to 280 characters each. New arrivals receive up to 100 recent messages. Position pings expire after eight seconds.

The leader can lock the room, kick a player, or ban a signed-in account. Account bans apply to the verified DID for the life of the room. Signed-in players can also have a display name and avatar in the roster.
