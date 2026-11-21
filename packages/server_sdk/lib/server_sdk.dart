/// Native authoritative room hosting, independent of any game simulation.
/// Mirrors the old realtime_network_server split: import this library
/// separately on IO; it re-exports the protocol package alongside the
/// dedicated-process room server, its server-socket connection adapter and
/// the platform relay authority.
library;

export 'package:protocol/protocol.dart';

export 'src/atproto/atproto_provider.dart';
export 'src/atproto/atproto_resolver.dart';
export 'src/atproto/client_keys.dart';
export 'src/atproto/confidential_client.dart';
export 'src/atproto/discovery_client.dart';
export 'src/atproto/match_events.dart';
export 'src/atproto/profiles.dart';
export 'src/authority_factory.dart';
export 'src/control_plane_api.dart';
export 'src/control_plane_client.dart';
export 'src/ident/guest_identity.dart';
export 'src/join_tokens.dart';
export 'src/listener_gates.dart';
export 'src/node_store.dart';
export 'src/panel/panel_api.dart';
export 'src/platform_store.dart';
export 'src/rooms_listener.dart';
export 'src/supabase_store.dart';
export 'src/movement_authority.dart';
export 'src/movement_config.dart';
export 'src/physics_backend.dart';
export 'src/relay_authority.dart';
export 'src/relay_config.dart';
export 'src/room_server.dart';
export 'src/room_supervisor.dart';
export 'src/server_socket_connection.dart';
