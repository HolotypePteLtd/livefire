---
title: Physics rooms
description: Players walk, run and jump in a world you describe in a settings file. The server computes every position, so cheating can't help.
---

A physics room is a 3D space where players move around — walking,
running, jumping — and nobody can teleport or speed-hack, because **the
server** decides where everyone is. You describe the world (floor, walls,
hills) and the controls in one settings file. No game server code.

The guarantee, stated plainly: **the server computes every position.**
Your game sends only inputs — buttons and joystick directions. A hacked
client can send anything it likes; the server moves you only as far as
your speed allows and never through a wall. Cheating gets nothing.
That is what makes physics rooms the type to use for anything
competitive. It costs the server CPU per room; for casual games where
cheating doesn't matter, [shared state rooms](/docs/shared-state-rooms/)
are nearly free — there the players decide.

This page continues [Instant multiplayer server](/docs/multiplayer-server/)
(that page covers running the server, creating rooms and connecting).
Any language works: movement inputs are plain JSON frames over a
WebSocket — [Writing a client in any language](/docs/protocol-clients/).

## Describe your world

Save this as `physics-room.json` — a small playable room: a big floor,
one pillar, and standard controls:

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
    ]
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

### Every field, in plain words

| Field | What it means |
| --- | --- |
| `capacity` | How many players fit (1–128). |
| `chat` | Include the built-in chat. |
| `inputsPerSecond` | How often a player may send controls (default: once per simulation step). |
| `tick.simulationHz` | How often the server recalculates positions (10–240; 60 is normal). |
| `tick.snapshotHz` | How often the server sends everyone the positions (1–60, at most `simulationHz`). |
| `colliders.boxes` | Solid boxes: floors, walls, platforms. `center` is the middle, `halfExtents` is half the size in each direction, in meters. |
| `colliders.capsules` | Pillar-shaped solids, from `base` to `top` with a `radius`. |
| `colliders.heightfield` | (Optional) a grid of heights for hills — see the reference for the exact format. |
| `spawnPoints` | Where players appear when they join, and which way they face (`yaw`). Handed out round-robin (1–64). |
| `movement.walkSpeed` / `runSpeed` | Meters per second (0.1–100). |
| `movement.gravity` | How hard the world pulls you down. Earth is `-9.81` (−30–0). |
| `movement.jumpSpeed` | How fast you leave the ground. Bigger = higher jump (0–50). |
| `movement.airControl` | How much steering you keep mid-air, 0–1 (`0.35` = a little). |
| `movement.acceleration` | How quickly you reach full speed (0.1–500). |
| `inputMapping` | The controls players are allowed to send (1–16). `axis` = a value between `range[0]` and `range[1]` (joystick or keys); `action` = a button (pressed or not). Anything not listed is ignored. |

`moveX`/`moveZ` must be axes and `jump`/`sprint` must be actions if
present — the movement model depends on them.

## Create the room

```sh
curl -X POST https://rooms.yourdomain.com/v1/rooms \
  -H "Authorization: Bearer YOUR_SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"template\": \"physics\", \"config\": $(cat physics-room.json)}"
```

This starts your world on the server. You get back a `url` and a one-time
`joinToken` (create more with the tokens call — same as
[creating a relay room](/docs/multiplayer-server/#5-create-a-room-and-invite-players)).
The same call works against the [hosted preview
node](/docs/multiplayer-server/#the-hosted-node-preview-rooms-without-a-server)
— base URL `https://play.holotype.com.sg`, API key on request; physics
rooms are enabled on it.

## Send controls from your game

```dart
final player = MyClient(Uri.parse('$roomUrl?token=$joinToken'), 'Alice');
await player.connect();

// Every frame of your game loop:
player.sendControl({
  'type': 'input',
  'moveX': joystick.x,   // -1..1, sideways
  'moveZ': joystick.y,   // -1..1, forward/back
  'jump': jumpHeld,
  'sprint': sprintHeld,
});
```

That is the whole client side: read your controller, send the buttons.
The server remembers your buttons between updates — you only need to send
when they change or a few times a second.

## Draw everyone where the server says they are

```dart
player.onChanged = () {
  final players = player.latest?.players ?? {};
  for (final entry in players.entries) {
    final pose = entry.value['pose'] as Map<String, dynamic>;
    drawAvatar(entry.key, pose['x'], pose['y'], pose['z'], pose['yaw']);
  }
};
```

Every player's `pose`, updated `snapshotHz` times a second. Your assigned
spawn point also arrives in the welcome message when you join.

## Good to know

- **Cheating does not help.** Buttons are only *requests*; the server
  clamps every value into the range you declared and does the actual
  moving. A hacked client can at most walk.
- If a player drops, their character slows to a stop (the server clears
  their buttons).
- Positions arrive rounded to 4 decimal places, about every 50 ms at
  20 Hz; the client SDK can smooth between updates for you
  (`sampleTimeline`).
- Full schema, heightfields and every rule: [the templates
  reference](/docs/templates/).
