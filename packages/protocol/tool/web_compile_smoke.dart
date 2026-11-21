import 'dart:async';
import 'package:protocol/protocol.dart';

/// Minimal authority with no game, physics or renderer dependency.
class _SmokeAuthority implements RoomAuthority {
  @override
  int capacity = 2, tick = 0;
  @override
  double elapsed = 0;
  @override
  void update(double seconds) {
    elapsed += seconds;
    tick++;
  }

  @override
  Object? validateJoin(Map<String, dynamic> message) => null;
  @override
  void addPlayer(String id, String name, Object? data) {}
  @override
  void resume(String id, Object? data) {}
  @override
  void disconnect(String id) {}
  @override
  void removePlayer(String id) {}
  @override
  Map<String, dynamic> welcome(String id) => {'sequence': 0};
  @override
  void command(String id, Map<String, dynamic> message) {}
  @override
  Map<String, dynamic> snapshot() => {
    'type': 'snapshot',
    'epoch': 0,
    'tick': tick,
    'time': elapsed,
    'players': const {},
  };
  @override
  void dispose() {}
}

void main() {
  // Ensure the protocol barrel compiles for the web and contains no
  // dart:io, server, physics or Flutter dependency: run a hub end to end
  // over the in-memory transport.
  final hub = RoomHub(_SmokeAuthority(), protocolVersion: 71);
  final pair = MemoryTransportPair();
  unawaited(
    hub.runTransport(pair.b).then((_) => pair.a.close()).catchError((_) {}),
  );
  pair.a.send(
    '{"type":"join","protocol":71,"name":"Smoke"}',
  );
  Future<void>.delayed(const Duration(milliseconds: 50)).then((_) {
    print(hub.roomKey);
    return hub.close();
  });
}
