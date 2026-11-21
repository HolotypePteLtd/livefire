---
title: Hosted quickstart
description: Get a preview key, create a hosted room from your backend, and connect a game client.
---

Hosted Livefire runs at `https://play.holotype.com.sg`. To get a preview API key, email Holotype with your game’s name and the web origin it will connect from, including scheme and port if applicable. Holotype uses the origin to allow your game’s WebSocket connections. [Request preview access](mailto:contact@holotype.com.sg?subject=Livefire%20preview%20access).

## Add the SDK

Clone the Livefire repository beside your project. From your Node or TypeScript project, install the SDK from that checkout. Use Node 22.18 or later for the backend example. A browser app needs a bundler that compiles TypeScript.

```sh
git clone https://github.com/HolotypePteLtd/livefire.git ../livefire
npm install ../livefire/sdk/typescript
```

## Create a room on your backend

Set `LIVEFIRE_API_KEY` in your backend’s environment. The SDK uses the hosted node by default. Keep the API key on your backend.

```ts
import { Livefire } from 'openfire-sdk';

const api = Livefire.admin(process.env.LIVEFIRE_API_KEY!);
const room = await api.createRoom({ template: 'relay', capacity: 8 });
```

Send `room.url` and `room.joinToken` to the first player through your game’s backend. For every additional player, use the same URL and a fresh token from `await api.mintToken(room)`. The tokens are single-use. Close the room with `await api.deleteRoom(room.roomId)` when your game is done with it. [HTTP API](/docs/api/).

## Join from the game client

Use the `url` and `joinToken` your backend gave this player. Open two clients with separate tokens to see the message appear in both. Browsers send the WebSocket `Origin` header automatically. For a Node client, use a socket factory that supplies an allowed `Origin`. [TypeScript SDK setup for native and Node clients](https://github.com/HolotypePteLtd/livefire/tree/master/sdk/typescript#origins-node-vs-browsers).

```ts
import { Livefire } from 'openfire-sdk';
const game = await Livefire.join({ url, joinToken, name: 'Alice' });
game.chat.send('Hello!');
```

Read messages with `game.chat.on(callback)` and subscribe to room state with `game.onState(callback)`. [Shared state rooms](/docs/shared-state-rooms/) · [Physics rooms](/docs/physics-rooms/).

## Give a coding agent the docs

Pass the full plain-text docs URL to your coding agent and describe what your game needs, such as a lobby with a ready flag for each player. The file includes setup, room templates, the HTTP API, and the WebSocket protocol. [Full documentation](/llms-full.txt).
