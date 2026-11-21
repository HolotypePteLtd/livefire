---
title: Instant multiplayer server
description: One page from zero to a running multiplayer backend — chat, shared state, settings-driven game modes. No networking knowledge needed.
---

Goal: by the end of this page you have a multiplayer backend running —
first on your machine, then on your own server on the internet — with
players chatting and sharing state. Everything is copy-paste; nothing here
needs networking knowledge.

> The rooms speak an open WebSocket + JSON protocol — any language can
> integrate; see [Writing a client in any
> language](/docs/protocol-clients/). The walkthrough below uses the
> official SDK (its examples happen to be in Dart); the server parts
> stay the same whatever your client is written in.

## Watch two players share one world

A live world: the server and two players, running in your browser.
Click the left scene and use WASD or arrow keys to drive the blue
avatar (shift = run). The red one is a bot.

<div class="world-demo-grid" id="world-demo-frames"></div>
<script src="/world/orchestrator.js" defer></script>

**What you are seeing:**

- The server frame runs the same room engine the real server runs.
- Every position comes from the server's snapshots. Clients send only
  inputs and interpolate toward the last state — a modified client
  cannot move faster than the server allows or leave the area.
- The three frames are separate programs in your browser joined by a
  same-origin message bus (`BroadcastChannel`). This is not network
  peer-to-peer; nothing leaves your browser.
- Movement is speed-clamped by design. The production physics template
  adds a real engine (ReactPhysics3D) as a server process.
- The server frame needs a browser with WebAssembly GC — modern Chrome,
  Edge, Firefox and Safari 18.2+. Older Safari shows a notice instead
  of a broken frame.

## 1. Run the same demo on your machine

The demos above run in your browser with zero installs. A real room
runs as a normal process on any machine — here is one that way: two
scripted players, chat, a shared counter. You need the Dart runtime from <https://dart.dev/get-dart>; check
with `dart --version` (3.x), then:

```sh
git clone https://github.com/HolotypePteLtd/livefire
cd livefire/examples/counter
dart pub get
dart run
```

You should see:

```text
[server] room listening on ws://127.0.0.1:xxxxx/play/demo-room
[join] Alice=p1 and Bob=p2 joined (capacity 8)
[chat] Alice: hello from Alice
[state] Alice sees Bob count=3 at tick 15
[done] clients left, room closed cleanly
```

That is real multiplayer: a room server on a real WebSocket, two players
joining over it, chat, and shared state. The whole program is
`examples/counter/bin/counter.dart` in the
[repository](https://github.com/HolotypePteLtd/livefire) — about 130 lines.

## 2. Make it yours

The demo is three parts. You keep the same shape for any game.

**Point your game at the SDK.** Livefire travels with its source, so
clone it next to your game and add path dependencies to your
`pubspec.yaml`:

```yaml
dependencies:
  protocol:
    path: ../livefire/packages/protocol
  client:
    path: ../livefire/packages/client
  server_sdk:
    path: ../livefire/packages/server_sdk
```

Run `dart pub get` and look for `Got dependencies!`.

**Part A — write the rules (`RoomAuthority`).** One class decides what is
true in the room: who joined, what a button press does, what the state
looks like. This is the only part you write — the counter from the demo:

```dart
class CounterAuthority implements RoomAuthority {
  final counters = <String, int>{};
  @override
  int capacity = 8, tick = 0;
  @override
  double elapsed = 0;
  @override
  void update(double seconds) {
    elapsed += seconds;
    tick++;
  }

  @override
  Object? validateJoin(Map<String, dynamic> message) => null;
  @override
  void addPlayer(String id, String name, Object? data) => counters[id] = 0;
  @override
  void resume(String id, Object? data) {}
  @override
  void disconnect(String id) {}
  @override
  void removePlayer(String id) => counters.remove(id);
  @override
  Map<String, dynamic> welcome(String id) => {'sequence': 0};
  @override
  void command(String id, Map<String, dynamic> message) {
    if (message['type'] == 'increment') counters[id] = counters[id]! + 1;
  }
  @override
  Map<String, dynamic> snapshot() => {
        'type': 'snapshot',
        'epoch': 0,
        'tick': tick,
        'time': elapsed,
        'players': {
          for (final e in counters.entries) e.key: {'count': e.value},
        },
      };
  @override
  void dispose() {}
}
```

**Part B — host it (`RoomServer`).** Three lines and the room is a real
server players connect to:

```dart
import 'package:server_sdk/server_sdk.dart';

final server = RoomServer(CounterAuthority(),
    protocolVersion: 1, simulationHz: 60, snapshotHz: 15, roomKey: 'demo-room');
await server.start(port: 8790);
print('room at ${server.localUri}');   // ws://127.0.0.1:8790/play/demo-room
```

**Part C — connect players (`RoomClient`).** One subclass per game; the
base class handles joining, reconnects, chat and state:

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

Repaint your UI from `onChanged` — it runs whenever anything changes (new
message, someone joins, new state):

```dart
alice.onChanged = () {
  print(alice.latest?.players);   // everyone's current state
};
```

In a game or UI framework, create the client once, connect on startup,
and repaint whenever `onChanged` fires. The room code does not change.

The `protocolVersion` number must match on the server and every client —
it is how rooms upgrade safely (`Incompatible game version` means it
doesn't).

## 3. Chat and the player list

Every room — this one or any below — has chat built in. No chat server to
run:

```dart
alice.social.sendChat('hello world');        // to everyone

alice.onChanged = () {
  for (final m in alice.social.messages) {
    print('${m.playerName}: ${m.text}');     // last 100, late joiners see them
  }
};
```

The room enforces sane rules for you: 280 characters max, one line, 4
messages per 10 seconds per player, hidden-character tricks rejected.
The room's leader can also:

```dart
alice.social.mute('p2', true);               // hide one player, my screen only
alice.social.moderate('kick', playerId: 'p2');  // leader only
alice.social.moderate('ban', playerId: 'p3');   // banned even after rejoining
alice.social.moderate('lock', locked: true);    // stop new joins
```

## The hosted node (preview): rooms without a server

Steps 4 and 5 below stand up your own node. If you would rather not run
anything, a hosted node is **live in preview** at
<https://play.holotype.com.sg> — the same server software as this
repository, over the same API. Honesty up front about what "preview"
means:

- **API keys are issued on request** — ask us; there is no self-serve
  signup yet, and billing is not live. The self-hosted path below is
  complete today. Self-serve keys exist as the [developer
  panel](/docs/panel/) (`/panel`, sign in with Bluesky) on nodes that
  enable it — including the hosted node as it rolls out.
- The hosted node enforces an **origin allowlist** on WebSocket
  upgrades (currently the docs site's origin). Browsers send `Origin`
  automatically — tell us your game's origin when you get a key.
  Non-browser clients must send a listed `Origin` header (Node's
  built-in WebSocket sends none; the TypeScript SDK's README shows the
  `socketFactory` escape hatch).

Create a room and mint tokens exactly like step 5, against the hosted
base URL (`<your-api-key>` is the key we issue you — keep it
server-side, never in client code):

```sh
curl -X POST https://play.holotype.com.sg/v1/rooms \
  -H "Authorization: Bearer <your-api-key>" \
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

The response shape is the same as step 5's (`roomId`, `roomKey`, `url`,
`joinToken`, `joinTokenExpiresAt`, `creatorToken`). With the TypeScript
SDK the whole backend is three lines and the client four:

```ts
// backend, per match (the API key stays on your server)
const of = Livefire.admin(API_KEY, 'https://play.holotype.com.sg');
const room = await of.createRoom({ template: 'relay', capacity: 16 });
const { joinToken } = await of.mintToken(room, playerName);

// client, per player
const game = await Livefire.join({ url: room.url, joinToken, name: 'Sam' });
```

From Dart, `RoomClient` connects to the returned `url` (it already
carries the token), like step 5 below. Self-hosting remains the
local-development path — everything else on this page is the same
software your node would run.

## 4. Put the server on the internet

Use the [Self-hosting quickstart](/docs/self-hosting/) to start the rooms
server on your own Linux host. It walks through DNS, automatic HTTPS, and
an authenticated API check. You can start with guest players and SQLite.

Once your API check returns `200`, use your node's HTTPS origin and
bootstrap API key to create rooms and mint player tokens.

## 5. Create a room and invite players

Rooms on the server are created through the API with a **settings file**
that picks what kind of room it is. This one has chat plus shared state —
each player owns a `pose` value, the room leader owns a `phase` value:

```sh
curl --fail-with-body -X POST https://rooms.yourdomain.com/v1/rooms \
  -H "Authorization: Bearer YOUR_SERVICE_KEY" \
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

You get back a room address and a one-time join token:

```json
{
  "roomId": "rm_9f3k2",
  "url": "wss://rooms.yourdomain.com/play/7YPL-xKq3-...",
  "joinToken": "jt_C1AA...",
  "joinTokenExpiresAt": "2026-12-01T12:15:00Z",
  "creatorToken": "ct_...",
  "status": "live"
}
```

One token comes with the room; each extra player needs their own (tokens
are single-use):

```sh
curl --fail-with-body -X POST https://rooms.yourdomain.com/v1/rooms/rm_9f3k2/tokens \
  -H "Authorization: Bearer YOUR_SERVICE_KEY"
```

Players connect with the same `RoomClient` from step 2 — the address now
carries the token:

```dart
final player = Player(Uri.parse('$roomUrl?token=$joinToken'), 'Alice');
await player.connect();
```

Chat (step 3) works the same. Each player updates their own values, and
everyone sees everyone's:

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

That is the whole loop: create a room from settings, hand out tokens,
players chat and share state.

## Two kinds of rooms: who decides what's true

The settings file picks one of two room types, and the real difference
between them is not what they do but **who decides what's true**. It is
the answer to the one question every developer asks: *can players
cheat?*

- **Shared-state rooms: the players decide.** Each player publishes
  their own values; the server checks the format and size and relays
  it to everyone, but never judges the content. A hacked client can
  claim anything — so use these for social spaces, chat, lobbies,
  casual co-op: anything where cheating doesn't ruin the game. Nearly
  free to host.
- **Physics rooms: the server decides.** Players send only inputs
  (buttons). The server owns a physics world built from your settings,
  runs the simulation and broadcasts the results. A hacked client can
  claim anything; the server moves you only as far as your speed
  allows and never through a wall. Costs CPU per room. Required for
  anything competitive.

|  | Shared state | Physics |
| --- | --- | --- |
| Who decides | the players | the server |
| Cheating | possible — fine for casual | gets nothing |
| Cost to host | nearly free | CPU per room |
| Setup | one settings file | one settings file |

## Where to go next

- **[Shared state rooms](/docs/shared-state-rooms/)** — the players
  decide: every settings field, reading everyone's state, leader-only
  values.
- **[Physics rooms](/docs/physics-rooms/)** — the server decides:
  players walk and jump in a world you describe; the server computes
  every position, so cheating can't help.
- **[Player accounts](/docs/accounts/)** — sign in with Bluesky: real
  names and avatars, bans that stick to the account.
- **[How it works](/docs/how-it-works/)** — the one-page plain-words
  explanation, for the "wait, but why?" moments.

## Things people get stuck on

- **`Got dependencies!` never appears** — the `path:` lines must point at
  your clone of the repository (a folder next to your game).
- **`Incompatible game version`** — `protocolVersion` differs between
  server and client; make them equal.
- **`Timed out` after `[server] room listening …`** — the players could
  not reach the room. The demo only needs `127.0.0.1`, so a firewall or
  antivirus blocking localhost sockets is the usual cause.
- **The HTTPS step fails with a DNS error** — the address record hasn't
  propagated yet. Check that it resolves to your server and that
  inbound TCP ports 80 and 443 are open.
- **Rooms work but Bluesky sign-in refuses** — `publicBaseUrl` is missing
  `https://`. It must be the full `https://rooms.yourdomain.com`.
- **Lost `node.json` or `.env`** — join tokens stop validating. Back both
  up; they are your server's identity.

Want to poke a live room yourself — chat, press +1, watch the ticks?
[Open the standalone demo.](/demo/)
