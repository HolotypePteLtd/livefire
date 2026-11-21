---
title: Physics rooms
description: Configure colliders, movement, and input limits for a server-simulated room.
---

Clients send movement inputs. The server applies the configured speed and collision rules, then sends each player’s position back to the clients. Use a physics room when the game depends on where a player can move.

## Describe your world

Save this example as `physics-room.json`. It defines a floor, a pillar, and one spawn point.

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

### Configuration fields

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

Expect `201` and a room URL and one-time join token. [Mint another token](/docs/multiplayer-server/#create-a-room-and-invite-players) for each additional player.

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

The server retains the last input until it receives an update. Send another input when the player releases a button.

## Render player positions

```dart
player.onChanged = () {
  final players = player.latest?.players ?? {};
  for (final entry in players.entries) {
    final pose = entry.value['pose'] as Map<String, dynamic>;
    drawAvatar(entry.key, pose['x'], pose['y'], pose['z'], pose['yaw']);
  }
};
```

Read `pose` from each snapshot. At `snapshotHz: 20`, the server sends positions about every 50 ms. The Dart client’s `sampleTimeline` can interpolate between updates. The welcome message includes the player’s assigned spawn point. When a client disconnects, the server clears its inputs.

See the [template reference](/docs/templates/) for heightfields and the complete schema.
