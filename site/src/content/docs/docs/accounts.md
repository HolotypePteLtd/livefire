---
title: Player accounts
description: Players sign in with their Bluesky account — real names, avatars on the player list, bans that stick to the account.
---

With accounts on, players can sign in with their **Bluesky** account.
Their real display name and avatar show up on the player list, and a
banned player cannot just rejoin with a new nickname — the ban sticks to
their account. Players who don't sign in still play as guests, exactly as
before.

This is a server setting, not code — your game keeps working unchanged.
You need your rooms server running
([Instant multiplayer server](/docs/multiplayer-server/#4-put-the-server-on-the-internet))
and a web address that starts with `https://` (Bluesky's sign-in service
requires it).

## 1. Make the server's private key (once)

The server signs its sign-in requests with a private key. Generate one
at the root of your checkout. From that directory, run:

```sh
(umask 077; cd packages/node && dart run tool/gen_client_jwks.dart ../../oauth-client-jwks.json)
sudo chown 10001:10001 oauth-client-jwks.json
sudo chmod 400 oauth-client-jwks.json
```

Keep the file like a password: back it up once, don't commit it to git.

## 2. Turn sign-in on in `node.json`

Open `node.json` with `sudoedit` if it is owned by the node’s UID.
Replace the guest-only `auth` block with:

```json
"auth": {
  "providers": ["guest", "atproto"],
  "atproto": {
    "clientName": "your game name",
    "entrywayUrl": "https://bsky.social",
    "plcDirectoryUrl": "https://plc.directory",
    "jwksPath": "/etc/rooms/oauth-client-jwks.json"
  }
}
```

Apply the change with the optional OAuth mount:

```sh
docker compose -f docker-compose.yml -f docker-compose.atproto.yml up -d --force-recreate rooms-node
```

Use both Compose files for subsequent updates to an OAuth-enabled node.
For a native process, set `jwksPath` to the private file on that host.

This adds "sign in with Bluesky" next to normal guest entry. `guest`
stays first, so nothing changes for players who skip sign-in. When a
player signs in, Bluesky's network confirms their account and hands your
server their account ID (called a DID — Bluesky's name for an account ID
on its network).

## 3. Add the button to your site

Point it at your server's sign-in start address, with the player's handle
and the room key:

```text
https://rooms.example.com/auth/start?handle=alice.bsky.social&room=7YPL-xKq3-...
```

The server sends the player to Bluesky's own sign-in screen and then
hands your game a join token tied to their account ID. (Your site can
watch for the result at `/auth/result` — the exact endpoints are in the
[Identity reference](/docs/identity/).)

## What changes in your game

| Before | After |
| --- | --- |
| Player names are nicknames anyone can type. | Signed-in players carry their real Bluesky display name and avatar — the room sends them on the player list, ready to draw. |
| A banned player returns with a new nickname in 5 seconds. | A ban applies to the signed-in account. Guests can still be banned by connection. |
| Reconnecting after a drop uses a rejoin token. | Signed-in players also get their session back by account, not just by token. |

## Good to know

- Sign-in is optional for players — guest play stays the default.
- The first time you use it with the real Bluesky, sign in yourself once
  and watch the server's logs; typos in `publicBaseUrl` (missing
  `https://`) are the usual culprit.
- How it works inside (OAuth, DIDs — you don't need this to use it):
  [the Identity reference](/docs/identity/).
- Where the accounts themselves can live — Bluesky's servers (the
  default) or your own: [Where accounts live](/docs/where-accounts-live/).
- Publishing match results and achievements as public records on the
  player's account is an opt-in server feature. See the [match event guide](https://github.com/HolotypePteLtd/livefire/blob/master/docs/match_events.md).
