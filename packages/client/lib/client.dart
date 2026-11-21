/// Reusable client-side networking. Import the server SDK separately on IO.
/// Re-exports the protocol package, so this barrel alone gives a universal
/// (native + web) dependency graph with no `dart:io` in the browser build.
library;

export 'package:protocol/protocol.dart';

export 'src/playback_clock.dart';
export 'src/room_client.dart';
export 'src/websocket.dart';
