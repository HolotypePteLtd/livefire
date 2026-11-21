---
title: Run a room
description: Run the local Dart counter, connect two players, and create a room on a Livefire node.
---

The counter example starts a WebSocket server on your machine, connects two scripted players, then shuts down. You need Dart 3.12 or later. To try it without installing Dart, [open the browser demo](/demo/).

<span id="1-run-the-same-demo-on-your-machine"></span>

## Run the local example

```sh
git clone https://github.com/HolotypePteLtd/livefire
cd livefire/examples/counter
dart pub get
dart run
```

The port and tick will vary. Look for Alice receiving Bob’s count before the clients disconnect.

```text
[server] room listening on ws://127.0.0.1:xxxxx/play/demo-room
[join] Alice=p1 and Bob=p2 joined (capacity 8)
[chat] Alice: hello from Alice
[state] Alice sees Bob count=3 at tick 15
[done] clients left, room closed cleanly
```

<span id="2-make-it-yours"></span>

## Add your game rules

The [counter source](https://github.com/HolotypePteLtd/livefire/blob/master/examples/counter/bin/counter.dart) has three parts. `CounterAuthority` keeps a count for each player, `RoomServer` listens on a socket, and `CounterClient` reads snapshots from that socket.

To use these packages in your own Dart game, clone Livefire beside your project and add these paths to your game’s `pubspec.yaml`. Then run `dart pub get`.

```yaml
dependencies:
  protocol:
    path: ../livefire/packages/protocol
  client:
    path: ../livefire/packages/client
  server_sdk:
    path: ../livefire/packages/server_sdk
```

When a player presses the increment button, the client sends a command. The room calls `command` with the sender’s ID. On the next snapshot, every connected client sees the updated count.

```dart
// In CounterAuthority
@override
void command(String id, Map<String, dynamic> message) {
  if (message['type'] == 'increment') counters[id] = counters[id]! + 1;
}
```

Start a server with your authority. This example runs 60 simulation steps and sends 15 snapshots per second.

```dart
import 'package:server_sdk/server_sdk.dart';

final server = RoomServer(CounterAuthority(),
    protocolVersion: 1, simulationHz: 60, snapshotHz: 15, roomKey: 'demo-room');
await server.start(port: 8790);
print('room at ${server.localUri}');   // ws://127.0.0.1:8790/play/demo-room
```

Create a client and send the command. The client and server must use the same `protocolVersion`.

```dart
import 'package:client/client.dart';

class Player extends RoomClient<RoomSnapshot> {
  Player(Uri uri, String name)
      : super(uri: uri, name: name, protocolVersion: 1);
  @override
  RoomSnapshot decodeSnapshot(Map<String, dynamic> data) => RoomSnapshot(data);
}

final alice = Player(server.localUri, 'Alice');
await alice.connect();                       // join handshake, first snapshot
alice.sendControl({'type': 'increment'});    // a button press
```

<span id="3-chat-and-the-player-list"></span>

## Chat and the player list

```dart
alice.social.sendChat('hello world');        // to everyone

alice.onChanged = () {
  for (final m in alice.social.messages) {
    print('${m.playerName}: ${m.text}');     // last 100, late joiners see them
  }
};
```

Each player can send four single-line messages per ten seconds, up to 280 characters each. New arrivals receive the last 100 messages. Muting affects the local player’s view. The leader can kick a guest, lock the room, or ban a player with a verified account.

```dart
alice.social.mute('p2', true);               // hide one player, my screen only
alice.social.moderate('kick', playerId: 'p2');  // leader only
alice.social.moderate('ban', playerId: 'p3');   // account-bound for signed-in players
alice.social.moderate('lock', locked: true);    // stop new joins
```

<span id="4-put-the-server-on-the-internet"></span>

## Host a server

The counter uses a custom Dart authority. To host rooms from JSON settings, [deploy a Livefire node](/docs/self-hosting/). Once your authenticated `GET /v1/rooms` returns `200`, you can create rooms from your backend.

<span id="5-create-a-room-and-invite-players"></span>

## Create a room and invite players

Use the `DOMAIN` and `LIVEFIRE_API_KEY` shell variables from the hosting guide. For the preview node, set `DOMAIN=play.holotype.com.sg` and use your preview API key. This relay room gives each player a `pose` and lets the leader update the shared `phase`.

```sh
curl --fail-with-body -X POST "https://$DOMAIN/v1/rooms" \
  -H "Authorization: Bearer $LIVEFIRE_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
        "template": "relay",
        "config": {
          "version": 1, "template": "relay", "capacity": 16, "chat": true,
          "maxRows": 64, "totalBytes": 32768,
          "playerKeys": {
            "pose": { "maxBytes": 256, "publishesPerSecond": 10 }
          },
          "roomKeys": {
            "phase": { "maxBytes": 64, "publishesPerSecond": 1 }
          }
        }
      }'
```

A successful response has status `201`. Give the first player the returned `url` and `joinToken`. Keep the `creatorToken` for the player who will lead the room. For each additional player, replace `rm_9f3k2` below with the returned `roomId` and request a fresh token.

```sh
curl --fail-with-body -X POST "https://$DOMAIN/v1/rooms/rm_9f3k2/tokens" \
  -H "Authorization: Bearer $LIVEFIRE_API_KEY"
```

Connect the Dart client using the URL and its token.

```dart
final player = Player(Uri.parse('$roomUrl?token=$joinToken'), 'Alice');
await player.connect();
```

```dart
player.sendControl({
  'type': 'publish', 'key': 'pose',
  'value': {'x': 1.25, 'y': 0, 'z': -3.5},
});

player.onChanged = () {
  final players = player.latest?.players ?? {};
  print(players);                        // every player's latest values
  print(player.latest?.data['room']);    // the shared values
};
```

With TypeScript, the [SDK](https://github.com/HolotypePteLtd/livefire/tree/master/sdk/typescript) provides separate backend and client calls.

```ts
// Game backend
import { Livefire } from 'openfire-sdk';

const api = Livefire.admin(API_KEY, NODE_URL);
const room = await api.createRoom({ template: 'relay', capacity: 16 });
// Send room.url and room.joinToken to the first player.
const { joinToken } = await api.mintToken(room); // For the next player.
```

```ts
// Game client, using the URL and token received from your backend
import { Livefire } from 'openfire-sdk';

const game = await Livefire.join({ url, joinToken, name: 'Sam' });
game.chat.send('hello');
```

See [shared state rooms](/docs/shared-state-rooms/) for ownership and quotas or [physics rooms](/docs/physics-rooms/) for server-simulated movement.

<span id="the-hosted-node-preview-rooms-without-a-server"></span>

## Hosted preview

If you have a preview API key, use `https://play.holotype.com.sg` as the node origin. Request a key and have the operator add your game’s web origin to the allowlist. Browsers send `Origin` automatically. For a native client, set an allowed `Origin` on the WebSocket handshake. The [TypeScript SDK README](https://github.com/HolotypePteLtd/livefire/tree/master/sdk/typescript) shows how to supply a socket factory.

## Watch two players share one world

Drag in the blue player’s view to move. With a keyboard, focus that view and use WASD or the arrow keys. Hold Shift to run. The red player is a bot. Both views receive positions from the same room engine, running in a third frame in your browser. The frames communicate over `BroadcastChannel`. This demo requires WebGL 2 and WebAssembly GC.

<div class="world-demo-grid" id="world-demo-frames"></div>
<script src="/world/orchestrator.js" defer></script>

<span id="things-people-get-stuck-on"></span>

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| `dart pub get` cannot find a package | The paths in `pubspec.yaml` are relative to your game project. |
| `Incompatible game version` | Compare the client and server values for `protocolVersion`. |
| The example prints `Timed out` | Check that local processes can reach the loopback address printed by the server. |
| The node’s HTTPS check fails | Check that your domain resolves to the host and that TCP ports 80 and 443 are open. |
