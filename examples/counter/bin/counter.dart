// A minimal Openfire application: a dedicated RoomServer runs in its own
// isolate on a loopback socket; two RoomClients join over real WebSockets,
// exchange chat through room social, and share a counter through a
// RoomAuthority whose snapshot is replicated to everyone.
//
// Run from this directory: dart run
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:client/client.dart';
import 'package:server_sdk/server_sdk.dart';

/// Applications pick their own protocol version; client and server must match.
const protocolVersion = 1;

/// The whole game: a per-player counter incremented by 'increment' commands.
class CounterAuthority implements RoomAuthority {
  final counters = <String, int>{};
  @override
  int capacity = 8, tick = 0;
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
  void addPlayer(String id, String name, Object? data) => counters[id] = 0;
  @override
  void resume(String id, Object? data) {}
  @override
  void disconnect(String id) {}
  @override
  void removePlayer(String id) => counters.remove(id);
  @override
  Map<String, dynamic> welcome(String id) => {'sequence': 0};
  @override
  void command(String id, Map<String, dynamic> message) {
    if (message['type'] == 'increment') counters[id] = counters[id]! + 1;
  }

  @override
  Map<String, dynamic> snapshot() => {
    'type': 'snapshot',
    'epoch': 0,
    'tick': tick,
    'time': elapsed,
    'players': {
      for (final entry in counters.entries) entry.key: {'count': entry.value},
    },
  };
  @override
  void dispose() {}
}

/// A typed client: decode snapshots into RoomSnapshot and the base class
/// handles join, resume, acks, reconnection and the social lane.
class CounterClient extends RoomClient<RoomSnapshot> {
  CounterClient(Uri uri, String name)
    : super(uri: uri, name: name, protocolVersion: protocolVersion);
  @override
  RoomSnapshot decodeSnapshot(Map<String, dynamic> data) => RoomSnapshot(data);
}

Future<void> serve(List<Object> args) async {
  final (reply, roomKey) = (args[0] as SendPort, args[1] as String);
  final server = RoomServer(
    CounterAuthority(),
    protocolVersion: protocolVersion,
    simulationHz: 60,
    snapshotHz: 15,
    roomKey: roomKey,
  );
  await server.start(port: 0, address: InternetAddress.loopbackIPv4);
  final stop = ReceivePort();
  reply.send((server.localUri.toString(), stop.sendPort));
  await stop.first;
  await server.close();
}

Future<void> until(bool Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw StateError('Timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> main() async {
  // Spawn the dedicated room server in its own isolate, on a fixed room key.
  final ready = ReceivePort();
  await Isolate.spawn(serve, [ready.sendPort, 'demo-room']);
  final (uri, stop) = await ready.first as (String, SendPort);
  print('[server] room listening on $uri');

  final alice = CounterClient(Uri.parse(uri), 'Alice');
  final bob = CounterClient(Uri.parse(uri), 'Bob');
  await alice.connect();
  await bob.connect();
  await until(() => alice.social.available && bob.social.available);
  print('[join] Alice=${alice.id} and Bob=${bob.id} joined (capacity ${alice.capacity})');

  // Chat rides the same reliable lane as control frames.
  alice.social.sendChat('hello from Alice');
  await until(
    () => bob.social.messages.any((m) => m.text == 'hello from Alice'),
  );
  final message = bob.social.messages.last;
  print('[chat] ${message.playerName}: ${message.text}');

  // Commands mutate authority state; snapshots replicate it to every peer.
  for (var i = 0; i < 3; i++) {
    bob.sendControl({'type': 'increment'});
  }
  await until(() => alice.latest?.players[bob.id]?['count'] == 3);
  final state = alice.latest!;
  print(
    '[state] Alice sees Bob count=${state.players[bob.id]['count']} '
    'at tick ${state.tick}',
  );

  await alice.close();
  await bob.close();
  stop.send(null);
  print('[done] clients left, room closed cleanly');
}
