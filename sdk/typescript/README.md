# openfire-sdk (TypeScript)

TypeScript client for [Livefire](https://github.com/HolotypePteLtd/livefire)
rooms. Speaks the documented JSON wire protocol
([/spec/rooms-protocol.json](../../site/public/spec/rooms-protocol.json)) over
one WebSocket: join/resume handshake, server-decided state with
baseline/delta snapshots and acks, a rate-capped command lane, chat, and
clean close. Node >= 22 (global WebSocket) and browsers; no runtime
dependencies.

## The whole integration

Backend (three lines per match — the API key stays on your server), client
(four lines per player):

```ts
// backend, per match
const of = Livefire.admin(API_KEY, NODE_URL);
const room = await of.createRoom({ template: 'relay', capacity: 16 });
const { joinToken } = await of.mintToken(room, playerName);

// client, per player
const game = await Livefire.join({
  url: room.url,   // or host + roomKey
  joinToken,
  name: 'Sam',
});
```

Set `NODE_URL` to your server origin when self-hosting.
`Livefire.admin(apiKey, host?)` defaults to the hosted node
(`https://play.holotype.com.sg`) and is a thin wrapper over the node's
`/v1` routes: `createRoom` (sensible relay defaults when you pass only
`template` + `capacity`; a full `config` for anything else), `mintToken`,
`listRooms`, `deleteRoom`. Hand the join token to the player's client —
one token per player, single-use, 15 minutes.

Get an API key from the node operator, or self-serve on a node you run:
the **developer panel** at `/panel` (sign in with Bluesky) creates and
revokes keys — ask the operator to add your DID to the node's
`adminDids`, or see [the panel
docs](../../site/src/content/docs/docs/panel.md) when running your own.

## Quickstart — hosted node (preview)

A hosted Livefire node is live at
<https://play.holotype.com.sg> (preview — ask us for an API key;
self-serve signup is not available yet). Mint a room and a one-time join
token over the HTTP API, then join with `joinToken`:

```sh
# 1. create a room (one-time join token comes with it)
curl -X POST https://play.holotype.com.sg/v1/rooms \
  -H "Authorization: Bearer <your-api-key>" \
  -H "Content-Type: application/json" \
  -d '{"template": "relay", "config": {"version": 1, "template": "relay", "capacity": 16, "chat": true, "maxRows": 64, "totalBytes": 32768, "playerKeys": {"pose": {"maxBytes": 256, "publishesPerSecond": 10}}, "roomKeys": {"phase": {"maxBytes": 64, "publishesPerSecond": 1}}}}'

# 2. every extra player needs their own one-time token
curl -X POST https://play.holotype.com.sg/v1/rooms/<roomId>/tokens \
  -H "Authorization: Bearer <your-api-key>"
```

```ts
import { Livefire } from 'openfire-sdk';

const game = await Livefire.join({
  host: 'https://play.holotype.com.sg', // the hosted node
  roomKey,                              // from POST /v1/rooms
  joinToken,                            // one-time, from the API
  name: 'Sam',
});
```

The token travels as `?token=<joinToken>` on the
`wss://…/play/<roomKey>` URL — the node validates and consumes it
before the WebSocket upgrade. It is single-use: one token per player,
minted by `roomId`. Never put the **API key** in client code; it mints
tokens server-side only.

## Quickstart — your own node

```ts
import { Livefire } from 'openfire-sdk';

const game = await Livefire.join({
  host: 'http://localhost:8790',   // your node
  roomKey: 'demo-room',
  name: 'Sam',
});

game.chat.send('hello!');               // chat, built in
game.onState((state) => render(state)); // server-decided state
game.command({ type: 'increment' });    // your room's rules decide
await game.close();                     // leave
```

Against a node run with the token gate (the hosted shape and any
`packages/node` deployment), pass `joinToken` as above; a plain
`RoomServer` (e.g. `examples/counter/bin/serve.dart`) has no gate, so
`host` + `roomKey` + `name` is enough.

## Origins (Node vs browsers)

The node's `allowedOrigins` allowlist is enforced **before** the
WebSocket upgrade: a client with no `Origin` header — or one that is not
listed — is rejected.

- **Browsers**: nothing to do. The browser WebSocket API sends `Origin`
  automatically (and forbids setting it); just make sure your game's
  origin is in the node's `allowedOrigins`.
- **Node**: the built-in WebSocket sends **no** `Origin` header, and the
  standard API cannot add one — so against an enforcing node you need a
  headers-capable socket via `socketFactory`. `origin` on the options is
  passed through to your factory:

  ```ts
  import WebSocket from 'ws'; // headers-capable WebSocket (devDependency)

  const game = await Livefire.join({
    host: 'https://play.holotype.com.sg',
    roomKey,
    joinToken,
    name: 'Sam',
    origin: 'https://rooms-sdk-docs.pages.dev', // a listed origin
    socketFactory: (url, { origin }) =>
      new WebSocket(url, { headers: { Origin: origin } }),
  });
  ```

  A node with an empty `allowedOrigins` (local development) allows every
  origin and needs none of this.

## Surface

| Member | Meaning |
| --- | --- |
| `Livefire.join(options)` | Connect + join (or resume); resolves at the first applied state frame. `url` (the API's `room.url`, `?token=` included) or `host` + `roomKey` |
| `Livefire.admin(apiKey, host?)` | Control plane: `createRoom`, `mintToken`, `listRooms`, `deleteRoom` (thin `/v1` wrappers; host defaults to the hosted node) |
| `room.playerId` / `capacity` / `resumeToken` | Facts from `welcome` |
| `room.state` | Latest decoded state (game-defined JSON + `tick`/`epoch`) |
| `room.onState(cb)` | Every applied snapshot/delta (already acked by the SDK) |
| `room.command(frame)` | Game command JSON; queued and drained at 12 Hz so a caller cannot trip the room's packet limit |
| `room.chat.send(text)` / `room.chat.messages()` / `room.chat.on(cb)` | The social lane; history replays on join and resume |
| `room.roster` | Latest members/leader/lock state |
| `room.onEvent(cb)` | `reconnecting`, `reconnected`, `notice`, `closed` |
| `room.dropConnection()` | Test hook: drop the socket like wifi going away, exercising resume |
| `room.close()` | Clean leave (`leave` frame; slot released immediately) |
| `options.joinToken` | One-time join token from the node's API → `?token=` on the URL |
| `options.origin` + `socketFactory` | Non-browser clients against an origin-enforcing node (see Origins) |
| `SnapshotDecoder` / `applyDelta` | The codec, exported for reuse and tests |

Unexpected connection loss reconnects automatically with the resume token
inside the room's grace window (default 15 s) and restores the same player
id, roster and chat history.

## Scope

JSON lane only in this slice. The protocol's optional binary state lane
(`binaryStates` opt-in with a server-side `WireStateCodec`, e.g.
FlatBuffers) is **not implemented**; JSON text remains the documented
fallback, so this client works against every room today. Moderation
frames (`moderate`, `ping`) are not surfaced as methods — they arrive as
commands/notices; a later slice can type them.

## Development

```sh
npm run typecheck   # tsc --noEmit (borrows the site install's tsc)
npm test            # codec unit tests + cross-language integration tests
npm run test:unit   # codec unit tests only
```

The integration tests spawn **real** rooms servers and drive them from
this SDK:

1. `examples/counter/bin/serve.dart` — the demo authority behind a
   `RoomServer` (Dart SDK): join handshake, chat round-trip, command →
   state replication, forced-drop resume with the same player id, and
   clean leave.
2. `packages/node/bin/node.dart` — the full rooms node (the same node
   software the hosted service runs), driven the hosted way: room
   creation and token minting over the HTTP API, join with the one-time
   `joinToken` in the URL, chat, publish → delta replication, and
   rejection of a bogus token before the upgrade.
3. The same node with the **panel enabled**: the admin namespace
   (`createRoom` defaults, `mintToken`, `listRooms`, `deleteRoom`),
   join by `url` (token in the option and in the query), the `/panel`
   page + its 401s, and a panel-issued key working until revoked (then
   401).

Dart on PATH is required for all of them; the node tests compile the
native physics bridge on first run (clang + cmake), so their first
execution takes a few minutes.
