import 'dart:async';

import 'package:client/client.dart';
import 'package:server_sdk/server_sdk.dart';
import 'package:test/test.dart';

import 'kinematic_backend.dart';

Map<String, dynamic> relayJson({int capacity = 8}) => {
      'version': 1,
      'template': 'relay',
      'capacity': capacity,
      'maxRows': 64,
      'totalBytes': 32768,
      'playerKeys': {
        'pose': {'maxBytes': 256, 'publishesPerSecond': 10},
      },
      'roomKeys': {
        'phase': {'maxBytes': 64, 'publishesPerSecond': 1},
      },
    };

Map<String, dynamic> movementJson() => {
      'version': 1,
      'template': 'physics',
      'capacity': 4,
      'tick': {'simulationHz': 60, 'snapshotHz': 20},
      'colliders': {
        'boxes': [
          {
            'name': 'floor',
            'center': [0, -0.5, 0],
            'halfExtents': [50, 0.5, 50],
          },
        ],
      },
      'spawnPoints': [
        {'position': [0, 0, 0], 'yaw': 0},
      ],
      'movement': {
        'walkSpeed': 4.5,
        'runSpeed': 8.0,
        'gravity': -9.81,
        'jumpSpeed': 5.2,
        'airControl': 0.35,
        'acceleration': 40.0,
      },
      'inputMapping': {
        'moveX': {'type': 'axis', 'range': [-1, 1]},
        'moveZ': {'type': 'axis', 'range': [-1, 1]},
        'jump': {'type': 'action'},
        'sprint': {'type': 'action'},
      },
    };

class SupSnapshot extends RoomSnapshot {
  SupSnapshot(super.data);
}

class SupClient extends RoomClient<SupSnapshot> {
  SupClient(String name, Future<GameConnection> Function() connector,
      {this.creatorToken})
      : super(
          uri: Uri.parse('memory://room'),
          name: name,
          protocolVersion: 1,
          connector: connector,
        );

  /// Join payload may carry the room creator's claim, like the relay tests.
  final String? creatorToken;

  @override
  Map<String, dynamic> get joinPayload => {
        if (creatorToken != null) 'creatorToken': creatorToken,
      };

  @override
  SupSnapshot decodeSnapshot(Map<String, dynamic> data) => SupSnapshot(data);
}

Future<SupClient> join(
  RoomSupervisor sup,
  SupervisorRoom room,
  String name, {
  String? creatorToken,
}) {
  final pair = MemoryTransportPair();
  final client = SupClient(
    name,
    () async {
      unawaited(sup.attach(room.key, pair.b));
      return pair.a;
    },
    creatorToken: creatorToken,
  );
  return client.connect().then((_) => client);
}

Future<void> until(bool Function() done, [String label = '']) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!done()) {
    if (DateTime.now().isAfter(end)) fail('Timed out $label');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('createRoom validates config and rejects unknown templates', () {
    final sup = RoomSupervisor(
      factories: [
        const RelayAuthorityFactory(),
        MovementAuthorityFactory(KinematicBackend.new),
      ],
    );
    final room = sup.createRoom(
      template: 'relay',
      config: relayJson(),
      creatorToken: 'ct',
    );
    expect(room.capacity, 8);
    expect(sup.room(room.key), same(room));
    expect(
      () => sup.createRoom(
        template: 'golf',
        config: relayJson(),
        creatorToken: 'ct',
      ),
      throwsA(isA<RoomException>()
          .having((e) => e.code, 'code', 'unsupported_template')),
    );
    expect(
      () => sup.createRoom(
        template: 'relay',
        config: {...relayJson(), 'maxRows': 999999},
        creatorToken: 'ct',
      ),
      throwsFormatException,
    );
    expect(
      () => sup.createRoom(
        template: 'physics',
        config: {
          ...movementJson(),
          'movement': {'walkSpeed': 0},
        },
        creatorToken: 'ct',
      ),
      throwsFormatException,
    );
    expect(sup.rooms.length, 1); // failed builds registered nothing
  });

  test('rooms tick in isolation from one pump', () {
    final sup = RoomSupervisor(
      factories: [
        const RelayAuthorityFactory(),
        MovementAuthorityFactory(KinematicBackend.new),
      ],
    );
    final relayRoom = sup.createRoom(
      template: 'relay',
      config: relayJson(),
      creatorToken: 'ct',
    );
    final movementRoom = sup.createRoom(
      template: 'physics',
      config: movementJson(),
      creatorToken: 'ct',
    );
    // Physics rooms run at 60 Hz, relay rooms at 20 Hz: the same pump
    // advances each hub's own fixed-step clock.
    sup.pumpSeconds(3);
    expect(movementRoom.hub.tick, 180);
    expect(relayRoom.hub.tick, 60);
    expect(
      (relayRoom.hub.authority as RelayAuthority).elapsed,
      closeTo(3, 1e-6),
    );
    expect(
      (movementRoom.hub.authority as MovementTemplateAuthority).elapsed,
      closeTo(3, 1e-6),
    );
  });

  test('N rooms tick on one master timer', () async {
    final sup = RoomSupervisor(
      factories: [MovementAuthorityFactory(KinematicBackend.new)],
    );
    for (var i = 0; i < 8; i++) {
      sup.createRoom(
        template: 'physics',
        config: movementJson(),
        creatorToken: 'ct',
      );
    }
    sup.startTicker(hz: 120);
    addTearDown(sup.close);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    sup.stopTicker();
    final ticks = sup.metrics().map((m) => m.tick).toList();
    expect(ticks.length, 8);
    // ~300 ms at 60 Hz simulation, within timer jitter.
    for (final tick in ticks) {
      expect(tick, greaterThan(8));
      expect(tick, lessThan(40));
    }
  });

  test('idle reap stops ticking, join restarts with state kept', () async {
    final sup = RoomSupervisor(
      factories: const [RelayAuthorityFactory()],
      idleTtl: const Duration(seconds: 10),
    );
    final room = sup.createRoom(
      template: 'relay',
      config: relayJson(),
      creatorToken: 'ct',
    );
    final client = await join(sup, room, 'p', creatorToken: 'ct');
    // Room rows (leader-only) outlive peer lifecycles; player rows follow
    // the normal grace-window removal, so this is what a restart keeps.
    client.sendControl({
      'type': 'publishRoom',
      'key': 'phase',
      'value': 'started',
    });
    await until(
      () => (room.hub.authority as RelayAuthority)
          .snapshot()['room']['phase'] ==
          'started',
      'publishRoom',
    );
    expect(room.peerCount, 1);
    await client.close();
    await until(() => room.peerCount == 0, 'peer gone');
    // Grace window releases the peer; then the idle TTL lapses.
    sup.pumpSeconds(16); // resume grace 15 s + ttl 10 s
    expect(room.reaped, isTrue);
    final tickWhenReaped = room.hub.tick;
    sup.pumpSeconds(30);
    expect(room.hub.tick, tickWhenReaped); // stopped, not draining
    expect(sup.room(room.key), same(room)); // still registered

    // Restart on join: room state kept in memory (the room row survives).
    final client2 = await join(sup, room, 'q');
    expect(room.reaped, isFalse);
    sup.pumpSeconds(0.2); // snapshots flow once the room ticks again
    await until(() => client2.latest != null, 'snapshot');
    expect(client2.latest!.data['room']['phase'], 'started');
    await client2.close();
  });

  test('capacity shedding: maxRooms and reserved capacity', () {
    final sup = RoomSupervisor(
      factories: const [RelayAuthorityFactory()],
      maxRooms: 2,
      maxReservedCapacity: 24,
    );
    for (var i = 0; i < 2; i++) {
      sup.createRoom(
        template: 'relay',
        config: relayJson(capacity: 8),
        creatorToken: 'ct',
      );
    }
    expect(
      () => sup.createRoom(
        template: 'relay',
        config: relayJson(),
        creatorToken: 'ct',
      ),
      throwsA(isA<RoomException>()
          .having((e) => e.code, 'code', 'quota_exceeded')),
    );
    expect(sup.reservedCapacity, 16);
    // Room capacity 16 would cross the 24 ceiling: shed.
    expect(
      () => sup.createRoom(
        template: 'relay',
        config: relayJson(capacity: 16),
        creatorToken: 'ct',
      ),
      throwsA(isA<RoomException>()
          .having((e) => e.code, 'code', 'quota_exceeded')),
    );
    // Draining a room releases its reservation.
    final first = sup.rooms.first;
    sup.destroy(first.key);
    expect(sup.rooms.length, 1);
    sup.createRoom(
      template: 'relay',
      config: relayJson(),
      creatorToken: 'ct',
    );
    expect(sup.rooms.length, 2);
    expect(sup.totalPeers, 0);
    final metrics = sup.metrics();
    expect(metrics.length, 2);
    expect(metrics.first.key, isNotEmpty);
  });

  test('destroy closes peers with 1001 and is idempotent', () async {
    final sup = RoomSupervisor(factories: const [RelayAuthorityFactory()]);
    final room = sup.createRoom(
      template: 'relay',
      config: relayJson(),
      creatorToken: 'ct',
    );
    final pair = MemoryTransportPair();
    final client = SupClient(
      'p',
      () async {
        unawaited(sup.attach(room.key, pair.b));
        return pair.a;
      },
    );
    await client.connect();
    await sup.destroy(room.key);
    await sup.destroy(room.key); // idempotent
    expect(sup.room(room.key), isNull);
    expect(pair.a.open, isFalse); // the hub closed the transport (1001)
    expect(
      () => sup.attach(room.key, pair.b),
      throwsA(isA<RoomException>()
          .having((e) => e.code, 'code', 'not_found')),
    );
  });
}
