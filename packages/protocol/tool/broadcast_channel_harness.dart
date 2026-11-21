// Headless integration test for the BroadcastChannel transport — the full
// sequence the site's world demo performs, run without a browser: Node has
// a global BroadcastChannel, so this harness compiles to JS (dart2js) and
// runs the hub + listener in the same Node process as two room clients.
//
// Run it with tool/test_broadcast_channel.sh (or manually):
//   dart compile js tool/broadcast_channel_harness.dart -o .dart_tool/bc/harness.js
//   node .dart_tool/bc/harness.js
//
// It proves: the bus handshake (hello retry carries a client over a
// listener that starts late — the bus drops pre-subscription sends), the
// room join handshake through the hub, inputs flowing up over the bus,
// positions replicating down in snapshots, two clients seeing each other,
// server-side clamping, and clean disconnect/cleanup.
import 'dart:async';
import 'dart:math' as math;

import 'package:client/client.dart';

const protocolVersion = 1;

/// Micro authority shaped like the demo's: 'input' commands set a target
/// velocity; update() integrates; snapshots carry per-player positions.
class WanderingAuthority implements RoomAuthority {
  final pos = <String, List<double>>{};
  final vel = <String, List<double>>{};
  @override
  int capacity = 8, tick = 0;
  @override
  double elapsed = 0;

  @override
  void update(double seconds) {
    elapsed += seconds;
    tick++;
    for (final id in pos.keys) {
      pos[id]![0] += vel[id]![0] * seconds;
      pos[id]![1] += vel[id]![1] * seconds;
    }
  }

  @override
  Object? validateJoin(Map<String, dynamic> message) => null;
  @override
  void addPlayer(String id, String name, Object? data) {
    pos[id] = [0, 0];
    vel[id] = [0, 0];
  }

  @override
  void resume(String id, Object? data) {}
  @override
  void disconnect(String id) => vel[id] = [0, 0];
  @override
  void removePlayer(String id) {
    pos.remove(id);
    vel.remove(id);
  }

  @override
  Map<String, dynamic> welcome(String id) => {'sequence': 0};
  @override
  void command(String id, Map<String, dynamic> message) {
    if (message['type'] == 'input') {
      final x = (message['x'] as num?)?.toDouble() ?? 0;
      final y = (message['y'] as num?)?.toDouble() ?? 0;
      final mag = math.sqrt(x * x + y * y);
      final scale = mag > 1 ? 1 / mag : 1.0; // clamp to unit circle
      vel[id] = [x * scale, y * scale];
    }
  }

  @override
  Map<String, dynamic> snapshot() => {
    'type': 'snapshot',
    'epoch': 0,
    'tick': tick,
    'time': elapsed,
    'players': {
      for (final id in pos.keys)
        id: {'x': pos[id]![0], 'y': pos[id]![1]},
    },
  };

  @override
  void dispose() {}
}

class BusClient extends RoomClient<RoomSnapshot> {
  BusClient(String channel, String name)
    : super(
        uri: Uri.parse('bc://harness'),
        name: name,
        protocolVersion: protocolVersion,
        connector: () => BroadcastChannelTransport.connect(channel),
      );
  @override
  RoomSnapshot decodeSnapshot(Map<String, dynamic> data) =>
      RoomSnapshot(data);
}

Future<void> until(bool Function() done, String what) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw StateError('Timed out: $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> main() async {
  final channel = 'bc-harness-${DateTime.now().microsecondsSinceEpoch}';
  final hub = RoomHub(
    WanderingAuthority(),
    protocolVersion: protocolVersion,
    simulationHz: 20,
    snapshotHz: 10,
    roomKey: 'harness',
  );
  hub.start();

  // 1. Raw transport over the bus, with the listener starting AFTER the
  //    client — the hello retry must carry it over the gap.
  final listener = BroadcastChannelListener(channel);
  final probeFuture = BroadcastChannelTransport.connect(
    channel,
    id: 'raw-probe',
    timeout: const Duration(seconds: 15),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await listener.start();
  final probe = await probeFuture;
  if (!probe.open) throw StateError('probe transport not open');
  await probe.close();
  if (probe.open) throw StateError('probe transport still open');
  print('PASS bus handshake: hello retry survived a late listener');

  // 2. Feed every accepted bus transport to the hub (the demo server's job).
  final attach = listener.onConnection.listen(
    (transport) => hub.runTransport(transport),
  );

  final alice = BusClient(channel, 'Alice');
  final bob = BusClient(channel, 'Bob');
  await alice.connect();
  await bob.connect();
  await until(
    () => alice.social.available && bob.social.available,
    'join handshake',
  );
  print('PASS join handshake: both clients on the roster');

  // 3. Input up over the bus, snapshot down: Alice moves, Bob sees it.
  alice.sendControl({'type': 'input', 'x': 1, 'y': 0});
  await until(
    () => (bob.latest?.players[alice.id!]?['x'] as num?) != null &&
        (bob.latest!.players[alice.id!]['x'] as num) > 0.1,
    'alice position replicates to bob',
  );
  print(
    'PASS input -> snapshot: bob sees alice x='
    '${(bob.latest!.players[alice.id!]['x'] as num).toStringAsFixed(2)}',
  );

  // 4. Both see each other; the server clamps input magnitude (3,4,5 -> 1).
  bob.sendControl({'type': 'input', 'x': 3, 'y': 4});
  await until(
    () => (alice.latest?.players[bob.id!]?['x'] as num?) != null &&
        (alice.latest!.players[bob.id!]['x'] as num) > 0.1,
    'bob position replicates to alice',
  );
  final bx = (alice.latest!.players[bob.id!]['x'] as num).toDouble();
  final by = (alice.latest!.players[bob.id!]['y'] as num).toDouble();
  if (bx * bx + by * by > 1.01) {
    throw StateError('velocity not clamped by the server: $bx,$by');
  }
  print('PASS both clients see each other; server clamps input magnitude');

  // 5. Disconnect: the peer disappears from the other client's roster.
  await alice.close();
  await until(
    () => !(bob.latest?.players.containsKey(alice.id!) ?? true),
    'alice leaves the roster',
  );
  print('PASS disconnect: peer removed from the roster');

  // 6. Cleanup.
  await bob.close();
  await attach.cancel();
  await listener.close();
  await hub.close();
  print('PASS cleanup: listener + hub closed cleanly');
  print('ALL PASS');
}
