---
title: Where accounts live
description: Bluesky's servers by default, or your own — the four options for where player accounts and identity come from, in plain words.
---

When players sign in to your game, their account lives somewhere. This
page explains the options — you need it only if you are deciding
*where* accounts should live. To just turn sign-in on, read
[Player accounts](/docs/accounts/) and stop there: the default needs no
decisions.

## 60 seconds of background

**AT Protocol** is an open system for internet accounts — a set of
public rules any server can implement. **Bluesky** is the company that
runs the largest servers on it and the app most people know. A player's
account lives on a server called a **PDS** (short for *Personal Data
Server*). Most players' accounts live on Bluesky's PDS, but the PDS
software is open source, so anyone can run their own. Every account has
an **account ID** called a **DID** (short for *decentralized
identifier*) — a permanent string like `did:plc:…` that stays the same
even if the player changes their handle or moves their account to a
different server. When this page says DID, read *account ID*.

Separately, **Jetstream** is a broadcast service: it sends out every
public event on the whole network as JSON over a websocket. Bluesky
runs one publicly at a fixed address; that software is open source too,
so anyone can run their own copy.

None of this is needed to play: guests play with no account at all, and
that is the default.

## The four options

### 1. Bluesky's public services (the default — nothing to set up)

- **What it is.** Your rooms server uses Bluesky's public services to
  verify sign-ins: it resolves handles and account IDs through
  Bluesky's directory services and reads each player's public profile
  from wherever their account lives. The addresses are in the server
  config (`node.json`: `entrywayUrl`, `plcDirectoryUrl`) and the
  defaults point at Bluesky's public servers — you change nothing.
- **Who runs it.** Bluesky. You run nothing.
- **What you get.** Sign-in works for every player who has a Bluesky
  account; bans stick to the account ID; names and avatars appear on
  the player list. Free, no account of your own, no keys.
  The public Jetstream feed belongs to this option too: when the
  planned features that listen to it land (see below), they work with
  no setup, because the feed is public.
- **Limits.** Public data only — a player's private game data never
  appears anywhere in this system, and Jetstream broadcasts only
  public events. You depend on Bluesky's servers staying up: if the
  directory is unreachable, new sign-ins on your server pause until it
  answers again (players already in rooms keep playing). And a
  subscriber to the feed receives *everything* on the network and
  filters out what it doesn't need — that filtering happens in
  software, on the receiving side.
- **When you need it.** Always, as the starting point. Everything below
  is optional.

### 2. Your own copy of the broadcast (self-hosted Jetstream)

- **What it is.** The same open-source broadcast program, run by you on
  your own server, reading the same network.
- **Who runs it.** You.
- **What you get.** Independence from Bluesky's feed staying up; events
  filtered on your server before your game code sees them; a feed
  located close to your players. **Status: planned.** The server does
  not subscribe to Jetstream today — player profiles currently refresh
  on a time-based cache, not from the feed — and `node.json` has no
  Jetstream address to configure yet. The planned uses are instant
  profile refresh (a player changes their avatar; every room sees it
  immediately) and public match results appearing the moment anyone
  publishes them, plus the open room directory described in the
  design notes.
- **Costs.** One more server to run, and real bandwidth: the
  unfiltered feed is hundreds of events per second, gigabytes per day.
  **Important:** it broadcasts the same *public* events — running your
  own copy does not give you anyone's private data.
- **When you need it.** Only at real scale, or if you cannot tolerate
  an outage of Bluesky's feed. Not before.

### 3. Your own account server (self-hosted PDS)

Two quite different cases:

**a. A PDS for your own service accounts (the realistic case).** Your
game's rooms server gets its own account — on your own PDS — and
publishes things like room listings or signed match records through
that account, instead of depending on Bluesky's servers. Small and
controlled: usually one or two accounts, no player data.

**b. Players' accounts on your PDS.** You offer sign-up on your own
server, or players move their accounts to it. You get full custody of
account data — data stays in a country or company you choose, backups
are yours. The cost is operating account infrastructure: storage,
backups, uptime, abuse handling. Most games never need this.

- **Key property, either way:** your game code does not change. Sign-in,
  bans and profiles work identically wherever the account lives,
  because the server verifies the account ID itself — the same
  verification code runs against Bluesky's PDS or yours.
- **When you need it.** Case (a) once your game publishes public
  records in its own name; case (b) only when a specific requirement
  (data residency, a closed community) forces it.

### 4. Your own sign-in (self-hosted auth — leaving AT Protocol)

- **What it is.** Not using AT Protocol for sign-in at all: your own
  usernames and passwords, your own token issuing, or a company's
  single-sign-on.
- **Who runs it.** You — all of it.
- **What you get.** Full control, and coverage of players who will not
  use a Bluesky account.
- **Costs.** You store credentials, which is a security and compliance
  burden. Bans are only as strong as your identity system — with
  passwords, a banned player makes a new account. And you rebuild what
  AT Protocol gives for free: portable accounts, verified identity,
  profiles. Note the shipped reality: the server today knows exactly
  two sign-in methods — **guest** (no account; everyone can play; bans
  don't stick) and **atproto** (portable accounts; bans stick). A third
  method is new server code, not a setting.
- **When you need it.** Only if a specific customer requires it.
  Kids' games with strict rules are already covered by guests (no
  accounts at all); business buyers may require their own single
  sign-on.

## Summary

Players' accounts live on AT Protocol servers — usually Bluesky's — and
you never host those and never store passwords. Bluesky's public
services are used by default with no setup; running your own broadcast
copy is an optional scale upgrade that still sees only public data.
Running your own account server is optional too — worth it for your
game's own service accounts, and invisible to players either way.
Leaving AT Protocol for your own sign-in is a real cost with no
benefit unless a customer requires it.

---

*Thanks to the open protocol, none of these choices touches your game
code — they are server configuration. The two shipped sign-in methods
are documented in [Player accounts](/docs/accounts/) and
[Identity](/docs/identity/); the Jetstream and directory plans in the
repository's design notes.*
