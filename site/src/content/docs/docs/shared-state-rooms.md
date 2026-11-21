---
title: Shared state rooms
description: Configure player-owned and leader-owned JSON values in a relay room.
---

Use a `relay` room when each player can supply their own state, such as a ready flag or an avatar pose. Declare the keys clients may write and how often they may update them. The server checks ownership and quotas. A client can still send a false score or position within those limits. For server-computed positions, use [physics rooms](/docs/physics-rooms/).

## The settings file

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

Send this object as the `config` field in [the create-room request](/docs/multiplayer-server/#create-a-room-and-invite-players), with `"template": "relay"` at the top level.

| Setting | What it means |
| --- | --- |
| `capacity` | How many players fit in the room (1–128). |
| `chat` | Include the built-in chat ([chat and the player list](/docs/multiplayer-server/#3-chat-and-the-player-list)). |
| `playerKeys` | The values each player owns. Only they can write their own. `maxBytes` = how big one value can be (1–2048); `publishesPerSecond` = how often they may update it (1–30). |
| `roomKeys` | Shared values. Only the room leader (whoever created the room) can write these. |
| `maxRows`, `totalBytes` | Safety caps for the whole room. |

## Update your values

Use the `publish` command to update one of your player’s values in the live room.

```dart
player.sendControl({
  'type': 'publish',
  'key': 'pose',
  'value': {'x': 1.25, 'y': 0, 'z': -3.5},
});
```

With these settings a player can update `pose` up to ten times per second. Other players see the new position in the next snapshot. The room keeps the value in memory. Writing a public match result to a player’s PDS takes a separate call and the player’s consent. [Publish a match result](https://github.com/HolotypePteLtd/livefire/blob/master/docs/match_events.md).

## Read everyone's state

```dart
player.onChanged = () {
  final players = player.latest?.players ?? {};
  for (final entry in players.entries) {
    print('${entry.key}: ${entry.value['pose']}');
  }
  print('game phase: ${player.latest?.data['room']?['phase']}');
};
```

`latest` holds the most recent snapshot the client has received.

## The leader writes the shared values

Use `publishRoom` to update a value shared by everyone in the room.

```dart
player.sendControl({
  'type': 'publishRoom',
  'key': 'phase',
  'value': 'started',
});
```

The leader presents the room’s `creatorToken` when joining. Other players can read `phase` in the room snapshot.

## Limits

The server silently drops updates that exceed the configured byte or rate limits. Numbers in snapshots are rounded to four decimal places. For position pings, send a room update with finite `x`, `y`, and `z` coordinates. See the [template schema](/docs/templates/) for all limits.
