---
title: Where accounts live
description: How Livefire finds existing accounts and where it creates device accounts.
---

An AT Protocol account lives on a Personal Data Server (PDS). Its decentralized identifier (DID) stays the same if the player changes their handle or moves to another PDS. A Livefire node hosts game rooms. It only needs a PDS connection if you want players to use AT Protocol accounts.

## Players with existing accounts

The player enters their handle. Livefire’s configured resolver (`entrywayUrl`) looks up the DID. For a `did:plc` account, Livefire uses `plcDirectoryUrl` to fetch the DID document. The document identifies the player’s PDS and Livefire discovers the OAuth provider from there.

The example config uses Bluesky’s public resolver and the public PLC directory. Both Bluesky-hosted and self-hosted accounts can use those defaults if their handles resolve. A resolver outage can interrupt new sign-ins. Players already in a room keep their connection. See [Enable player sign-in](/docs/accounts/).

## Guest and device accounts

An ordinary guest joins with a one-time room token. This requires no PDS. For a player who needs a persistent DID before signing up, Livefire can provision a device account on a PDS you operate. The node stores that account’s generated credentials, and the game client stores its recovery key. You’re responsible for the PDS’s storage, backups, and availability. See [Use an existing PDS](/docs/self-hosting/#already-run-a-pds).

## Other identity services

**Jetstream** distributes public AT Protocol events. Livefire currently refreshes profiles using a cache. There is no Jetstream endpoint to configure.

**Custom sign-in** such as an existing company login requires a server integration. The built-in room sign-in providers are `guest` and `atproto`.

**Match publishing** uses a consenting player’s account. Publishing through a game-owned service account is planned. See the [match event guide](https://github.com/HolotypePteLtd/livefire/blob/master/docs/match_events.md).
