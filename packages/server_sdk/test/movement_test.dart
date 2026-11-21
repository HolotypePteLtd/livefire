import 'dart:convert';
import 'dart:math' as math;

import 'package:server_sdk/server_sdk.dart';
import 'package:test/test.dart';

import 'kinematic_backend.dart';

/// The documented example config (physics template), with the heightfield
/// data generated at the documented 65×65 size. Returns the parsed config.
MovementRoomConfig docsExampleConfig({int inputsPerSecond = 60}) {
  final heights = List.generate(
    65 * 65,
    (i) => ((i % 65) - 32) / 64.0, // gentle ramp, |h| < 1
  );
  return MovementRoomConfig.fromJson(jsonDecode('''
  {
    "version": 1, "template": "physics", "capacity": 32, "chat": true,
    "inputsPerSecond": $inputsPerSecond,
    "tick": { "simulationHz": 60, "snapshotHz": 20 },
    "colliders": {
      "boxes": [
        { "name": "floor", "center": [0, -0.5, 0], "halfExtents": [50, 0.5, 50] }
      ],
      "capsules": [
        { "name": "pillar", "base": [10, 0, 4], "top": [10, 3, 4], "radius": 0.4 }
      ],
      "heightfield": { "size": [64, 64], "data": ${jsonEncode(heights)} }
    },
    "spawnPoints": [ { "position": [0, 1, 0], "yaw": 0 } ],
    "movement": {
      "walkSpeed": 4.5, "runSpeed": 8.0, "gravity": -9.81,
      "jumpSpeed": 5.2, "airControl": 0.35, "acceleration": 40.0
    },
    "inputMapping": {
      "moveX": { "type": "axis", "range": [-1, 1] },
      "moveZ": { "type": "axis", "range": [-1, 1] },
      "jump": { "type": "action" },
      "sprint": { "type": "action" }
    }
  }
  ''') as Map<String, dynamic>);
}

/// Config tuned for analytic movement assertions: flat ground plane via the
/// kinematic backend, two spawns, explicit input rate.
MovementRoomConfig analyticConfig({int inputsPerSecond = 240}) =>
    MovementRoomConfig.fromJson(jsonDecode('''
  {
    "version": 1, "template": "physics", "capacity": 8, "chat": true,
    "inputsPerSecond": $inputsPerSecond,
    "tick": { "simulationHz": 60, "snapshotHz": 20 },
    "colliders": {
      "boxes": [ { "name": "floor", "center": [0, -0.5, 0], "halfExtents": [50, 0.5, 50] } ]
    },
    "spawnPoints": [
      { "position": [0, 0, 0], "yaw": 0 },
      { "position": [10, 0, 0], "yaw": 3.14159 }
    ],
    "movement": {
      "walkSpeed": 4.5, "runSpeed": 8.0, "gravity": -9.81,
      "jumpSpeed": 5.2, "airControl": 0.35, "acceleration": 40.0
    },
    "inputMapping": {
      "moveX": { "type": "axis", "range": [-1, 1] },
      "moveZ": { "type": "axis", "range": [-1, 1] },
      "jump": { "type": "action" },
      "sprint": { "type": "action" }
    }
  }
  ''') as Map<String, dynamic>);

MovementTemplateAuthority authority(
  MovementRoomConfig config,
  KinematicBackend backend,
) => MovementTemplateAuthority(config, backend: backend, creatorToken: 'tok');

void tick(MovementTemplateAuthority room, {int steps = 60}) {
  for (var i = 0; i < steps; i++) {
    room.update(1 / 60);
  }
}

double poseX(MovementTemplateAuthority room, String id) =>
    (room.snapshot()['players'][id] as Map)['pose']['x'] as double;

double poseY(MovementTemplateAuthority room, String id) =>
    (room.snapshot()['players'][id] as Map)['pose']['y'] as double;

double _hypot(double x, double y) => math.sqrt(x * x + y * y);

Map<String, dynamic> input(Map<String, dynamic> fields) =>
    {'type': 'input', ...fields};

void main() {
  group('config validation mirrors room_templates.md', () {
    test('the documented example parses, defaults applied', () {
      final config = docsExampleConfig();
      expect(config.capacity, 32);
      expect(config.tick.simulationHz, 60);
      expect(config.tick.snapshotHz, 20);
      expect(config.movement.walkSpeed, 4.5);
      expect(config.colliders.boxes.single.name, 'floor');
      expect(config.colliders.capsules.single.radius, 0.4);
      expect(config.colliders.heightfield!.cellsX, 64);
      expect(config.colliders.heightfield!.heights.length, 65 * 65);
      expect(config.spawnPoints.single.yaw, 0);
      expect(config.inputMapping['moveX'], isA<AxisInput>());
      expect(config.inputMapping['jump'], isA<ActionInput>());
    });

    test('inputsPerSecond defaults to simulationHz', () {
      final json = jsonDecode('''
      {
        "version": 1, "template": "physics", "capacity": 4,
        "tick": { "simulationHz": 30, "snapshotHz": 10 },
        "colliders": { "boxes": [ { "center": [0, -0.5, 0], "halfExtents": [1, 0.5, 1] } ] },
        "spawnPoints": [ { "position": [0, 0, 0], "yaw": 0 } ],
        "movement": {
          "walkSpeed": 4.5, "runSpeed": 8, "gravity": -9.81,
          "jumpSpeed": 5.2, "airControl": 0.35, "acceleration": 40
        },
        "inputMapping": {
          "moveX": { "type": "axis", "range": [-1, 1] },
          "moveZ": { "type": "axis", "range": [-1, 1] }
        }
      }
      ''') as Map<String, dynamic>;
      expect(MovementRoomConfig.fromJson(json).inputsPerSecond, 30);
    });

    test('rejects bad configs', () {
      // Same base as above, mutated per case.
      Map<String, dynamic> base() => jsonDecode('''
      {
        "version": 1, "template": "physics", "capacity": 4,
        "tick": { "simulationHz": 30, "snapshotHz": 10 },
        "colliders": {
          "boxes": [ { "name": "floor", "center": [0, -0.5, 0], "halfExtents": [1, 0.5, 1] } ],
          "capsules": [ { "name": "p", "base": [0, 0, 0], "top": [0, 2, 0], "radius": 0.4 } ],
          "heightfield": { "size": [16, 16], "data": [
            ${List.filled(17 * 17, 0.0).join(',')} ] }
        },
        "spawnPoints": [ { "position": [0, 0, 0], "yaw": 0 } ],
        "movement": {
          "walkSpeed": 4.5, "runSpeed": 8, "gravity": -9.81,
          "jumpSpeed": 5.2, "airControl": 0.35, "acceleration": 40
        },
        "inputMapping": {
          "moveX": { "type": "axis", "range": [-1, 1] },
          "moveZ": { "type": "axis", "range": [-1, 1] },
          "jump": { "type": "action" }
        }
      }
      ''') as Map<String, dynamic>;

      void bad(void Function(Map<String, dynamic>) mutate) {
        final json = base();
        mutate(json);
        expect(() => MovementRoomConfig.fromJson(json), throwsFormatException);
      }

      bad((j) => j['version'] = 2);
      bad((j) => j['template'] = 'relay');
      bad((j) => j['capacity'] = 0);
      bad((j) => j['capacity'] = 129);
      bad((j) => j['chat'] = 'yes');
      bad((j) => j['turbo'] = true);
      bad((j) => j['inputsPerSecond'] = 0);
      bad((j) => j['inputsPerSecond'] = 241);
      bad((j) => (j['tick'] as Map)['simulationHz'] = 9);
      bad((j) => (j['tick'] as Map)['simulationHz'] = 241);
      bad((j) => (j['tick'] as Map)['snapshotHz'] = 0);
      bad((j) => (j['tick'] as Map)['snapshotHz'] = 61);
      bad((j) => (j['tick'] as Map)['snapshotHz'] = 31); // > simulationHz
      bad((j) => j['colliders'] = {'boxes': [], 'capsules': []});
      bad((j) {
        final b = (j['colliders'] as Map)['boxes'] as List;
        (b[0] as Map)['halfExtents'] = [0, 0.5, 1];
      });
      bad((j) {
        final b = (j['colliders'] as Map)['boxes'] as List;
        (b[0] as Map)['halfExtents'] = [501, 0.5, 1];
      });
      bad((j) {
        final b = (j['colliders'] as Map)['boxes'] as List;
        (b[0] as Map)['center'] = [0, double.nan, 0];
      });
      bad((j) {
        final c = (j['colliders'] as Map)['capsules'] as List;
        (c[0] as Map)['top'] = [0, 0.5, 0]; // segment < 2 * radius
      });
      bad((j) {
        final c = (j['colliders'] as Map)['capsules'] as List;
        (c[0] as Map)['radius'] = 0;
      });
      bad((j) {
        (j['colliders'] as Map)['heightfield'] = {
          'size': [8, 16],
          'data': List.filled(9 * 17, 0.0),
        };
      });
      bad((j) {
        (j['colliders'] as Map)['heightfield'] = {
          'size': [16, 16],
          'data': List.filled(17 * 16, 0.0), // wrong sample count
        };
      });
      bad((j) {
        (j['colliders'] as Map)['heightfield'] = {
          'size': [16, 16],
          'data': List.filled(17 * 17, 20000.0),
        };
      });
      bad((j) {
        (j['colliders'] as Map)['heightfield'] = {
          'size': [16, 16],
          'data': List.filled(17 * 17, 0.0)..[5] = double.infinity,
        };
      });
      bad((j) => j['spawnPoints'] = []);
      bad((j) => j['spawnPoints'] = List.generate(65, (i) => null)
          .map((_) => {'position': [0, 0, 0], 'yaw': 0})
          .toList());
      bad((j) => (j['movement'] as Map)['gravity'] = 1);
      bad((j) => (j['movement'] as Map)['gravity'] = -31);
      bad((j) => (j['movement'] as Map)['walkSpeed'] = 0);
      bad((j) => (j['movement'] as Map)['walkSpeed'] = 101);
      bad((j) => (j['movement'] as Map)['runSpeed'] = 100.5);
      bad((j) => (j['movement'] as Map)['jumpSpeed'] = 51);
      bad((j) => (j['movement'] as Map)['airControl'] = 1.5);
      bad((j) => (j['movement'] as Map)['acceleration'] = 0);
      bad((j) => (j['movement'] as Map)['acceleration'] = 500.1);
      bad((j) => (j['movement'] as Map)['airControl'] = double.nan);
      bad((j) => j['inputMapping'] = {});
      bad((j) => j['inputMapping'] = {
        for (var i = 0; i < 17; i++)
          'k$i': {'type': 'action'},
      });
      bad((j) => j['inputMapping'] = {
        'MoveX': {'type': 'axis', 'range': [-1, 1]},
      });
      bad((j) => j['inputMapping'] = {
        'moveX': {'type': 'axis', 'range': [-1, 1]},
        'jump': {'type': 'axis', 'range': [-1, 1]}, // reserved name
      });
      bad((j) => j['inputMapping'] = {
        'moveZ': {'type': 'axis', 'range': [-1, 1]}, // moveX missing
        'jump': {'type': 'action'},
      });
      bad((j) => j['inputMapping'] = {
        'moveX': {'type': 'axis', 'range': [1, 1]},
        'moveZ': {'type': 'axis', 'range': [-1, 1]},
      });
      bad((j) => j['inputMapping'] = {
        'moveX': {'type': 'axis', 'range': [2, -2]},
        'moveZ': {'type': 'axis', 'range': [-1, 1]},
      });
      bad((j) => j['inputMapping'] = {
        'moveX': {'type': 'axis', 'range': [double.negativeInfinity, 1]},
        'moveZ': {'type': 'axis', 'range': [-1, 1]},
      });
      bad((j) => j['inputMapping'] = {
        'moveX': {'type': 'throttle', 'range': [-1, 1]},
        'moveZ': {'type': 'axis', 'range': [-1, 1]},
      });
      expect(base()['colliders'], isNotNull); // base() stays parseable.
    });
  });  group('spawn assignment', () {
    test('round-robin over spawn points, echoed in welcome', () {
      final backend = KinematicBackend();
      final room = authority(analyticConfig(), backend);
      room.addPlayer('p1', 'p1', null);
      room.addPlayer('p2', 'p2', null);
      room.addPlayer('p3', 'p3', null);
      expect(room.welcome('p1')['spawn'],
        {'x': 0.0, 'y': 0.0, 'z': 0.0, 'yaw': 0.0});
      expect(room.welcome('p2')['spawn']['x'], 10.0);
      expect(room.welcome('p2')['spawn']['yaw'], 3.14159);
      expect(room.welcome('p3')['spawn']['x'], 0.0); // wrapped
      expect(backend.bodyCount, 3);
      expect(poseX(room, 'p2'), 10.0);
    });
  });

  group('input validation', () {
    test('accepts mapped fields, defaults missing ones to zero/false', () {
      final room = authority(analyticConfig(), KinematicBackend());
      room.addPlayer('p', 'p', null);
      room.command('p', input({'moveX': 0.5}));
      tick(room, steps: 1);
      expect(room.rejectedInputs, 0);
      // v approaches 0.5·4.5 = 2.25 at 40 m/s²: first step reaches 40/60.
      expect(poseX(room, 'p'), closeTo(40 / 60 / 60, 1e-9));
    });

    test('rejects undeclared fields, wrong types and non-finite values', () {
      final room = authority(analyticConfig(), KinematicBackend());
      room.addPlayer('p', 'p', null);
      for (final bad in [
        {'turbo': true},
        {'moveX': 'right'},
        {'moveX': double.nan},
        {'moveX': double.infinity},
        {'jump': 1},
        {'sprint': 'on'},
      ]) {
        room.command('p', input(bad));
      }
      expect(room.rejectedInputs, 6);
      expect(room.lastRejection, 'sprint must be a bool');
      // The previous valid input state is untouched, and rejections cost no
      // rate budget: another input still lands.
      room.command('p', input({'moveX': 1}));
      expect(room.rejectedInputs, 6);
    });

    test('clamps axes into the declared range instead of rejecting', () {
      final room = authority(analyticConfig(), KinematicBackend());
      room.addPlayer('p', 'p', null);
      room.command('p', input({'moveX': 7, 'moveZ': -9}));
      tick(room, steps: 60);
      final snap = (room.snapshot()['players']['p'] as Map)['pose'] as Map;
      final x = snap['x'] as double, z = snap['z'] as double;
      // Clamped to (1, -1), normalized to a unit circle, walked at 4.5 m/s:
      // per-axis target 4.5/√2, reached from step 5.
      final perAxis = (20 / 3 + 56 * 4.5 / 1.4142135623730951) / 60;
      expect(x, closeTo(perAxis, 1e-9));
      expect(z, closeTo(-perAxis, 1e-9));
      expect(_hypot(x, z), lessThan(4.5 + 1e-9));
    });

    test('ignores non-input message types, like the relay', () {
      final room = authority(analyticConfig(), KinematicBackend());
      room.addPlayer('p', 'p', null);
      room.command('p', {'type': 'publish', 'key': 'pose'});
      expect(room.rejectedInputs, 0);
    });
  });

  group('rate limits', () {
    test('accepts N per sliding second, rejects the rest', () {
      final room = authority(
        analyticConfig(inputsPerSecond: 5),
        KinematicBackend(),
      );
      room.addPlayer('p', 'p', null);
      for (var i = 0; i < 5; i++) {
        room.command('p', input({'moveX': 1}));
        room.update(1 / 60); // window slides on authority time
      }
      expect(room.rejectedInputs, 0);
      room.command('p', input({'moveX': 1}));
      expect(room.rejectedInputs, 1);
      expect(room.lastRejection, 'input rate exceeded');
      // After a full second the window has slid empty.
      tick(room, steps: 60);
      room.command('p', input({'moveX': 1}));
      expect(room.rejectedInputs, 1);
    });

    test('rejections never consume rate budget', () {
      final room = authority(
        analyticConfig(inputsPerSecond: 2),
        KinematicBackend(),
      );
      room.addPlayer('p', 'p', null);
      for (var i = 0; i < 3; i++) {
        room.command('p', input({'hax': i})); // rejected
      }
      expect(room.rejectedInputs, 3);
      room.command('p', input({'moveX': 1})); // accepted
      room.command('p', input({'moveX': 0})); // accepted
      room.command('p', input({'moveX': 1})); // over budget
      expect(room.rejectedInputs, 4);
      expect(room.lastRejection, 'input rate exceeded');
    });
  });

  group('movement model', () {
    test('walk one second: analytic Euler expectation', () {
      final room = authority(analyticConfig(), KinematicBackend());
      room.addPlayer('p', 'p', null);
      room.command('p', input({'moveX': 1}));
      tick(room, steps: 60);
      // v_i = min(4.5, i * 40/60); full speed from step 7.
      // Σ v_i = (2/3)(1..6) + 4.5 * 54 = 14 + 243 = 257 → x = 257/60.
      expect(poseX(room, 'p'), closeTo(257 / 60, 1e-9));
      expect(poseY(room, 'p'), 0.0);
      final pose = (room.snapshot()['players']['p'] as Map)['pose'] as Map;
      expect(pose['yaw'], closeTo(3.141592653589793 / 2, 1e-9));
    });

    test('sprint runs at runSpeed', () {
      final room = authority(analyticConfig(), KinematicBackend());
      room.addPlayer('p', 'p', null);
      room.command('p', input({'moveZ': 1, 'sprint': true}));
      tick(room, steps: 60);
      // v_i = min(8, i * 2/3); full speed from step 13.
      // Σ v_i = (2/3)(1..12) + 8 * 48 = 52 + 384 = 436 → z = 436/60.
      final z = (room.snapshot()['players']['p'] as Map)['pose']['z'] as double;
      expect(z, closeTo(436 / 60, 1e-9));
    });

    test('jump launches at jumpSpeed under gravity and lands', () {
      final room = authority(analyticConfig(), KinematicBackend());
      room.addPlayer('p', 'p', null);
      room.command('p', input({'jump': true}));
      var apex = 0.0;
      for (var i = 0; i < 70; i++) {
        room.update(1 / 60);
        apex = apex > poseY(room, 'p') ? apex : poseY(room, 'p');
      }
      // Discrete apex at step 31: Σ(5.2 − 9.81·j/60)/60 ≈ 1.33507.
      expect(apex, closeTo(1.3350666667, 1e-6));
      expect(poseY(room, 'p'), 0.0); // landed and at rest
    });

    test('air control scales acceleration while airborne', () {
      final room = authority(analyticConfig(), KinematicBackend());
      room.addPlayer('p', 'p', null);
      room.command('p', input({'moveX': 1, 'jump': true}));
      tick(room, steps: 12);
      // Step 1 accelerates grounded (2/3); steps 2..12 at 40·0.35 = 14 m/s²
      // (7/30 per step). Σ v = 12·(2/3) + (7/30)(1..11) = 8 + 15.4 = 23.4.
      expect(poseX(room, 'p'), closeTo(23.4 / 60, 1e-9));
      expect(poseY(room, 'p'), greaterThan(0)); // still airborne at 0.2 s
    });

    test('gravity settles an airborne spawn onto the ground', () {
      final config = analyticConfig();
      final backend = KinematicBackend();
      final room = authority(config, backend);
      room.addPlayer('p', 'p', null);
      room.removePlayer('p');
      // Re-add on a high spawn by moving the cursor onto a custom config.
      final highConfig = MovementRoomConfig(
        capacity: 8,
        tick: config.tick,
        colliders: config.colliders,
        spawnPoints: const [SpawnPoint(x: 0, y: 5, z: 0, yaw: 0)],
        movement: config.movement,
        inputMapping: config.inputMapping,
        inputsPerSecond: config.inputsPerSecond,
      );
      final room2 = authority(highConfig, backend);
      room2.addPlayer('p', 'p', null);
      var apex = poseY(room2, 'p'); // the spawn pose itself
      for (var i = 0; i < 120; i++) {
        room2.update(1 / 60);
        final y = poseY(room2, 'p');
        if (y > apex) apex = y;
      }
      expect(apex, 5.0); // only ever falls from the spawn height
      expect(poseY(room2, 'p'), 0.0); // settled on the ground plane
    });

    test('disconnect stops inputs; the avatar decelerates to a stop', () {
      final room = authority(analyticConfig(), KinematicBackend());
      room.addPlayer('p', 'p', null);
      room.command('p', input({'moveX': 1}));
      tick(room, steps: 60);
      room.disconnect('p');
      tick(room, steps: 60); // decelerate from 4.5 at 40 m/s²
      final stopped = poseX(room, 'p');
      tick(room, steps: 60);
      expect(poseX(room, 'p'), closeTo(stopped, 1e-9));
      // Walked 257/60 in the first second, then decelerated over six steps
      // applying 3.8333..0.5 m/s (13/60) — total exactly 4.5 m.
      expect(stopped, closeTo((257 + 13) / 60, 1e-9));
    });
  });

  group('eviction and cleanup', () {
    test('removePlayer releases the body and the slot', () {
      final backend = KinematicBackend();
      final room = authority(analyticConfig(), backend);
      room.addPlayer('p1', 'p1', null);
      room.addPlayer('p2', 'p2', null);
      expect(backend.bodyCount, 2);
      room.removePlayer('p1');
      expect(backend.bodyCount, 1);
      expect(backend.removedHandles, [1]); // p1's body handle
      expect(room.snapshot()['players'].keys, ['p2']);
      expect(() => backend.poseOf(1), throwsStateError); // released slot
      tick(room, steps: 10);
      expect(room.snapshot()['players'].keys, ['p2']);
    });
  });

  group('snapshot and social', () {
    test('snapshot carries poses and the static config echo', () {
      final room = authority(analyticConfig(), KinematicBackend());
      room.addPlayer('p', 'p', null);
      room.command('p', input({'moveX': 1}));
      tick(room, steps: 60);
      final snap = room.snapshot();
      expect(snap['type'], 'snapshot');
      expect(snap['tick'], 60);
      expect(snap['time'], closeTo(1.0, 1e-9));
      expect((snap['players']['p'] as Map).keys, ['pose']);
      final roomEcho = snap['room'] as Map;
      expect(roomEcho['template'], 'physics');
      expect(roomEcho['simulationHz'], 60);
      expect(roomEcho['snapshotHz'], 20);
      expect((roomEcho['colliders'] as Map)['boxes'], 1);
      expect((roomEcho['colliders'] as Map)['heightfield'], isNull);
      expect((roomEcho['movement'] as Map)['walkSpeed'], 4.5);
      expect((roomEcho['spawnPoints'] as List).length, 2);
      // Raw doubles on the authority; the hub SnapshotEncoder quantizes.
      expect(poseX(room, 'p'), closeTo(257 / 60, 1e-9));
    });

    test('the creator leads and pings answer from the simulated pose', () {
      final room = authority(analyticConfig(), KinematicBackend());
      expect(room.roomLeaderId, isNull);
      final claim = room.validateJoin({'creatorToken': 'tok'});
      room.addPlayer('creator', 'c', claim);
      room.addPlayer('other', 'o', room.validateJoin({'creatorToken': 'no'}));
      expect(room.roomLeaderId, 'creator');
      room.command('creator', input({'moveX': 1}));
      tick(room, steps: 60);
      final ping = room.pingLocation('creator', 'here');
      expect(ping, isNotNull);
      expect(ping!.x, closeTo(257 / 60, 1e-9));
      expect(room.pingLocation('ghost', 'here'), isNull);
      room.removePlayer('creator');
      expect(room.roomLeaderId, isNull);
    });

    test('dispose releases the backend', () {
      final backend = KinematicBackend();
      final room = authority(analyticConfig(), backend);
      room.addPlayer('p', 'p', null);
      room.dispose();
      expect(backend.bodyCount, 0);
    });
  });
}
