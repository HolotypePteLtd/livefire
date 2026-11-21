/// Live room hosting, room management, and join-token verification.
/// Re-exports the room protocol for native Dart hosts.
library;

export 'package:protocol/protocol.dart';

export 'src/authority_factory.dart';
export 'src/control_plane_api.dart';
export 'src/control_plane_client.dart';
export 'src/join_tokens.dart';
export 'src/listener_gates.dart';
export 'src/node_store.dart';
export 'src/platform_store.dart';
export 'src/rooms_listener.dart';
export 'src/supabase_store.dart';
export 'src/sqlite_database.dart' show openSqliteDatabase;
export 'src/movement_authority.dart';
export 'src/movement_config.dart';
export 'src/physics_backend.dart';
export 'src/relay_authority.dart';
export 'src/relay_config.dart';
export 'src/room_server.dart';
export 'src/room_supervisor.dart';
export 'src/server_socket_connection.dart';
