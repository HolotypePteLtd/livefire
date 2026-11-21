# Livefire

Livefire hosts multiplayer rooms. A game backend creates a room over HTTP and gives each player a one-time WebSocket join token. Clients can use the Dart or TypeScript SDK, or implement the wire protocol directly.

[Run a room](https://rooms-sdk-docs.pages.dev/docs/multiplayer-server/) · [Host a server](https://rooms-sdk-docs.pages.dev/docs/self-hosting/) · [Use an existing PDS](https://rooms-sdk-docs.pages.dev/docs/self-hosting/#already-run-a-pds)

The TypeScript package is `openfire-sdk`. It exports `Livefire` and its original alias, `Openfire`.

## Choose a room type

| Room | What the server does |
| --- | --- |
| Relay | Accepts player-owned JSON values within configured size and rate limits. A lobby might use these for ready flags or character selection. |
| Physics | Simulates player inputs against configured colliders and sends positions to each client. |
| Custom | Runs your Dart `RoomAuthority` implementation for game-specific rules and snapshots. |

## Quickstart

### Option A — Use the TypeScript SDK (hosted or self-hosted node)

```ts
import { Livefire } from 'openfire-sdk';

// 1. Backend: create a room and mint a one-time join token
const api = Livefire.admin(
  process.env.LIVEFIRE_API_KEY!,
  process.env.LIVEFIRE_URL!, // Your node origin, e.g. https://rooms.example.com
);
const room = await api.createRoom({ template: 'relay', capacity: 16 });
const { joinToken } = await api.mintToken(room);

// 2. Client: join, chat, and subscribe to authoritative state
const game = await Livefire.join({ url: room.url, joinToken, name: 'Alice' });
game.chat.send('hello!');
game.onState((state) => render(state));
```

### Option B — Write a custom Dart `RoomAuthority`

Run the complete example in [`examples/counter`](examples/counter):

```sh
cd examples/counter
dart pub get
dart run
```

**1. Implement your rules (`RoomAuthority`)** — networking never imports your game types:

```dart
class CounterAuthority implements RoomAuthority {
  final counters = <String, int>{};
  @override int capacity = 8, tick = 0;
  @override double elapsed = 0;

  @override void update(double dt) { elapsed += dt; tick++; }
  @override Object? validateJoin(Map<String, dynamic> msg) => null;
  @override void addPlayer(String id, String name, Object? data) => counters[id] = 0;
  @override void removePlayer(String id) => counters.remove(id);
  @override Map<String, dynamic> welcome(String id) => {'sequence': 0};
  @override void command(String id, Map<String, dynamic> msg) {
    if (msg['type'] == 'increment') counters[id] = counters[id]! + 1;
  }
  @override Map<String, dynamic> snapshot() => {
    'type': 'snapshot', 'epoch': 0, 'tick': tick, 'time': elapsed,
    'players': {for (final e in counters.entries) e.key: {'count': e.value}},
  };
  @override void resume(String id, Object? data) {}
  @override void disconnect(String id) {}
  @override void dispose() {}
}
```

**2. Host it** — either on a WebSocket server (`RoomServer`) or in-process (`RoomHub` + `MemoryTransportPair`):

```dart
import 'package:server_sdk/server_sdk.dart';

final server = RoomServer(
  CounterAuthority(),
  protocolVersion: 1,
  simulationHz: 60,
  snapshotHz: 15,
  roomKey: 'demo-room',
);
await server.start(port: 8790);
```

**3. Connect a typed Dart client:**

```dart
import 'package:client/client.dart';

class CounterClient extends RoomClient<RoomSnapshot> {
  CounterClient(Uri uri, String name)
      : super(uri: uri, name: name, protocolVersion: 1);
  @override
  RoomSnapshot decodeSnapshot(Map<String, dynamic> data) => RoomSnapshot(data);
}

final alice = CounterClient(server.localUri, 'Alice');
await alice.connect();
alice.social.sendChat('hello');
alice.sendControl({'type': 'increment'});
await alice.close();
```

---

## Repository layout

| Package / Directory | Role |
| :--- | :--- |
| [`packages/protocol`](packages/protocol) | Core room engine: `RoomHub`, `RoomAuthority`, `SnapshotEncoder`/`Decoder`, `RoomSocialHost`/`Client`, in-memory & BroadcastChannel transports. Pure Dart (web-clean). |
| [`packages/client`](packages/client) | `RoomClient`, interpolated `PlaybackClock`, native & web WebSocket adapters (text + binary frames). |
| [`packages/server_sdk`](packages/server_sdk) | Dedicated server (`RoomServer`), multi-room `RoomSupervisor`, `RoomsListener`, `/v1` HTTP API, `/panel`, `/ident`, AT Protocol provider, `RelayAuthority`, `MovementTemplateAuthority`, SQLite & Supabase stores. |
| [`packages/physics_react3d`](packages/physics_react3d) | Native FFI `PhysicsBackend` binding for `reactphysics3d_dart`. |
| [`packages/atproto_identity`](packages/atproto_identity) | AT Protocol desktop loopback OAuth (`AtprotoAccountManager`) and `NodeAuthClient`. |
| [`packages/node`](packages/node) | Standalone node binary (`bin/node.dart --config node.json`). |
| [`sdk/typescript`](sdk/typescript) | Zero-dependency TypeScript client, admin API, and guest identity SDK. |
| [`docs/`](docs) | Protocol, HTTP API, room templates, and identity specifications. |
| [`site/`](site) | Landing page, interactive demos, and Starlight docs site. |

---

## Running a node

[Follow the Docker Compose quickstart](site/src/content/docs/docs/self-hosting.md)
to start your own Livefire node, verify the API and create a room. The
quickstart uses guest joins and SQLite. It also covers running locally
with Dart and adding optional Bluesky sign-in or Supabase.

---

## Documentation

| Guide | What it covers |
| :--- | :--- |
| [Wire protocol](docs/protocol.md) | Handshake, fixed-step ticks, baseline/delta replication, social frames, close codes |
| [Control-plane HTTP API](docs/control_plane_api.md) | `/v1/rooms` lifecycle, API key scoping, one-time join tokens, error format |
| [Room templates](docs/room_templates.md) | `relay` and `physics` JSON schemas, quotas, input protocol, snapshots |
| [Identity](docs/identity.md) | Guest tokens, AT Protocol OAuth sign-in, DID-bound bans/profiles, device accounts and recovery |

---

## Developing & testing

```sh
(cd packages/protocol && dart analyze && dart test)
(cd packages/client && dart analyze && dart test)
(cd packages/atproto_identity && dart analyze && dart test)
(cd packages/server_sdk && dart analyze && dart test)
(cd packages/node && dart analyze && dart test)
(cd sdk/typescript && npm test)
(cd packages/client && dart compile js tool/web_compile_smoke.dart)
```
