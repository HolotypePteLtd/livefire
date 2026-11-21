# AT Protocol for Livefire servers

Add `livefire_atproto_server` to a Dart backend that needs AT Protocol sign-in, device account provisioning, public profiles, the account-backed admin panel, or match publishing. The standard Livefire node already includes this package. Guest rooms can use `server_sdk` alone.

## Use it in a Dart host

From a checkout of this repo, point your backend at the packages it imports. Adjust the relative paths for your project.

```yaml
dependencies:
  server_sdk:
    path: ../livefire/packages/server_sdk
  livefire_atproto_server:
    path: ../livefire/packages/atproto_server
```

```dart
import 'package:server_sdk/server_sdk.dart';
import 'package:livefire_atproto_server/livefire_atproto_server.dart';
```

If your server previously imported `AtprotoAuthProvider`, `GuestIdentityApi`, `PanelApi`, or `MatchEventPublisher` from `server_sdk`, import them from this package. For a listener with `atproto`, `ident`, or `panel` configured, use `AtprotoRoomsListener` and pass the same constructor arguments. Guest-only hosts use `RoomsListener` or `RoomServer` from `server_sdk`. The standard node serves both sets of routes on one port.

For custom hosts upgrading their storage wiring, pass `SqliteAccountStore(nodeStore.database)` to `ProfileService(store: ...)`. Pass the same store to `GuestIdentityApi(accounts: ...)` for SQLite, or use `SupabaseDeviceAccountStore(supabasePlatformStore)` for device credentials in Postgres. Both backends read existing account data in place. The prebuilt node handles this wiring from its configuration.

## What goes to the PDS

Sign-in requests identity access by default. The PDS hosts the player’s account. The room receives a verified player ID, and the node can fetch and cache a public profile. A room command, chat message, or state update travels over the room connection.

To create a public game record, enable match publishing and explicitly call the publisher with the player’s consent. It writes a match result or achievement to that player’s repository. External subscribers can observe the public record through Jetstream. Livefire has no Jetstream consumer or world-history recorder.

- [Configure sign-in or use an existing PDS](https://rooms-sdk-docs.pages.dev/docs/accounts/)
- [Publish a match result](../../docs/match_events.md)
- [Room state, node storage, and public records](https://rooms-sdk-docs.pages.dev/docs/how-it-works/#where-data-goes)
