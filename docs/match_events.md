# Publishing match events to AT Protocol

The optional Dart package `livefire_atproto_server` can publish match summaries and achievements as
`com.openfire.matchEvent` records in a consenting player's repository.
Publishing is disabled by default. To enable it on a node, configure
`publishEvents.enabled`, set a reverse-domain `gameId`, and enable the
AT Protocol identity provider. Enabling publishing requests the `repo`
scope when players sign in. The setting alone writes nothing. Relay commands
named `publish` or `publishRoom` only update the live room.

A player must consent to each publish. The default `summaryOnly` setting
allows `matchResult` records. Set it to false to also publish
`achievement` records. The publisher enforces `maxEventsPerMatch` and
limits the encoded payload to 2 KiB. Use references for larger artifacts.

The game server calls `MatchEventPublisher.publishMatchEvent` with the
player's OAuth session and receives the record URI and CID. The record is
public. `deleteMatchEvent` removes a record using the same authorization.
