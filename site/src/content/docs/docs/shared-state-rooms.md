---
title: Shared state rooms
description: Everyone sees the same state — poses, scores, game phase — from one settings file. No server code.
---

A shared state room (the **relay** template) gives every player their own
values (position, emote, ready-flag…) and the room a set of shared values
(game phase, round number…), and keeps everyone seeing the same thing.
You configure it with a settings file — no server code.

The trade to know before you build on it: in a shared state room **the
players decide**. The server checks that each value fits the size and
rate limits you set, but it trusts what players publish — a hacked
client can claim any position or score it likes. That is fine, and
nearly free, for casual games, social spaces and prototypes. For
anything competitive, use [physics rooms](/docs/physics-rooms/)
instead — there the server decides and cheating gets nothing.

This page continues [Instant multiplayer server](/docs/multiplayer-server/)
(that page covers running the server, creating rooms and connecting).
Any language works: the updates are plain JSON frames over a WebSocket —
[Writing a client in any language](/docs/protocol-clients/).

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

Create the room by posting it as the `config` of a `POST /v1/rooms` call —
see [step 5 of Instant multiplayer server](/docs/multiplayer-server/#5-create-a-room-and-invite-players).
That call works against your own node or the [hosted preview
node](/docs/multiplayer-server/#the-hosted-node-preview-rooms-without-a-server)
(`https://play.holotype.com.sg`, API key on request) — same API, same
config.

| Setting | What it means |
| --- | --- |
| `capacity` | How many players fit in the room (1–128). |
| `chat` | Include the built-in chat ([chat and the player list](/docs/multiplayer-server/#3-chat-and-the-player-list)). |
| `playerKeys` | The values each player owns. Only they can write their own. `maxBytes` = how big one value can be (1–2048); `publishesPerSecond` = how often they may update it (1–30). |
| `roomKeys` | Shared values. Only the room leader (whoever created the room) can write these. |
| `maxRows`, `totalBytes` | Safety caps for the whole room. |

## Update your values

```dart
player.sendControl({
  'type': 'publish',
  'key': 'pose',
  'value': {'x': 1.25, 'y': 0, 'z': -3.5},
});
```

This updates **your** `pose` value. Ten times a second is plenty for a
position. Everyone in the room receives it.

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

`latest` is always the room's current state — reconnects and slow networks
are handled for you.

## The leader writes the shared values

```dart
player.sendControl({
  'type': 'publishRoom',
  'key': 'phase',
  'value': 'started',
});
```

Works only for the room's leader (the creator — prove it by joining with
the room's `creatorToken`). Everyone else's `room['phase']` updates on its
own.

## Good to know

- Updates too big or too fast are **dropped silently**, never crash a game
  — set your limits in the settings file to match your game.
- Numbers arrive rounded to 4 decimal places. Close enough for poses;
  don't use it as a calculator.
- Markers ("I'm here" pings) work automatically: the room answers them
  from any player key holding an object with finite `x`, `y`, `z` numbers.
- All the exact limits and the full settings schema live in
  [the templates reference](/docs/templates/).
