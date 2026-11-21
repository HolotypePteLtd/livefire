# Protocol

Transport-agnostic authoritative room protocol, originally extracted from
a game networking stack. It includes the room hub (fixed-step
simulation, join/resume handshake, resume tokens and grace window, acks, rate
limits with stall buffering, baseline/delta snapshots with loss recovery), the
`RoomAuthority` game contract, snapshot and wire codecs, connection capability
interfaces, the in-memory transport pair, and room social. No `dart:io`,
Flutter, renderer, physics or game dependency — compiles for browsers
(`dart compile js tool/web_compile_smoke.dart`).

Consumers import `package:client/client.dart` for the resumable room client,
playback clock and WebSocket adapters, or `package:server_sdk/server_sdk.dart`
for the native dedicated-server SDK; both build on this package.

## Room social

Pure Dart chat and quick-ping models for room hosts, Flutter clients and browser
clients. This module has no game, renderer, networking or account dependency.
The transport sends its JSON frames over a reliable control lane, separately
from disposable state snapshots.

Room chat includes a named message feed, join/leave notices, and
one ten-second speech bubble per player (at most 128). The host supplies sender
IDs/names and authoritative ping coordinates. History is capped at 100 entries,
text at 280 characters, chat at four messages per ten seconds, and pings at
three per five seconds. History replay does not recreate bubbles. Clients can
mute a player's messages and pings locally. Hosts own moderation and admission.

Each application handles bubble projection and UI styling.

`RoomSocialHost` validates content and rate limits on a monotonic clock supplied
by the room. `RoomSocialClient` receives frames and exposes history, active
bubbles, pings and roster. Neither persists chat outside the room session.
