import 'dart:convert';

import 'package:physics_react3d/physics_react3d.dart';
import 'package:server_sdk/server_sdk.dart'
    show MovementTemplateAuthority, MovementRoomConfig;
import 'package:test/test.dart';

/// Movement config over a flat floor box; spawn is a feet position.
MovementRoomConfig floorConfig({
  List<Map<String, Object?>> extraBoxes = const [],
  double spawnY = 5,
}) =>
    MovementRoomConfig.fromJson(jsonDecode('''
  {
    "version": 1, "template": "physics", "capacity": 8,
    "tick": { "simulationHz": 60, "snapshotHz": 20 },
    "colliders": {
      "boxes": [
        { "name": "floor", "center": [0, -0.5, 0], "halfExtents": [50, 0.5, 50] }
        ${extraBoxes.isEmpty ? '' : ', ${extraBoxes.map(jsonEncode).join(', ')}'}
      ]
    },
    "spawnPoints": [ { "position": [0, $spawnY, 0], "yaw": 0 } ],
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

void settle(React3dPhysicsBackend backend, {int steps = 300}) {
  for (var i = 0; i < steps; i++) {
    backend.step(1 / 60);
  }
}

void main() {
  test('world builds from the full collider set of the docs example', () {
    final backend = React3dPhysicsBackend()..createWorld(_docsColliders());
    backend.dispose();
  });

  test('a falling player settles on the floor and is grounded', () {
    final backend = React3dPhysicsBackend()..createWorld(floorConfig());
    final handle = backend.addPlayerBody(const BackendSpawn(0, 5, 0));
    expect(backend.isGrounded(handle), isFalse); // airborne at spawn
    settle(backend);
    final pose = backend.poseOf(handle);
    // Capsule centre rests at playerHeight / 2 above the floor surface.
    expect(pose.y, closeTo(0.9, 0.05));
    expect(backend.isGrounded(handle), isTrue);
    backend.dispose();
  });

  test('movement intent walks at the given velocity', () {
    final backend = React3dPhysicsBackend()..createWorld(floorConfig());
    final handle = backend.addPlayerBody(const BackendSpawn(0, 5, 0));
    settle(backend);
    final start = backend.poseOf(handle).x;
    for (var i = 0; i < 60; i++) {
      backend.applyMovementInput(
        handle,
        const MovementIntent(velocityX: 4.5, velocityZ: 0),
      );
      backend.step(1 / 60);
    }
    final dx = backend.poseOf(handle).x - start;
    expect(dx, closeTo(4.5, 0.25));
    backend.dispose();
  });

  test('jump launches from the ground and lands back', () {
    final backend = React3dPhysicsBackend()..createWorld(floorConfig());
    final handle = backend.addPlayerBody(const BackendSpawn(0, 5, 0));
    settle(backend);
    final rest = backend.poseOf(handle).y;
    var apex = rest;
    var jumped = false;
    for (var i = 0; i < 90; i++) {
      backend.applyMovementInput(
        handle,
        MovementIntent(velocityX: 0, velocityZ: 0, jump: i == 0),
      );
      backend.step(1 / 60);
      final y = backend.poseOf(handle).y;
      if (y > apex) apex = y;
      if (y > rest + 0.2) jumped = true;
    }
    expect(jumped, isTrue);
    // 5.2^2 / (2 · 9.81) ≈ 1.38 m of flight, minus contact resolution.
    expect(apex - rest, closeTo(1.38, 0.15));
    // Let the bounce settle before the landing assertions.
    for (var i = 0; i < 240; i++) {
      backend.applyMovementInput(
        handle,
        const MovementIntent(velocityX: 0, velocityZ: 0),
      );
      backend.step(1 / 60);
    }
    expect(backend.poseOf(handle).y, closeTo(rest, 0.05));
    expect(backend.isGrounded(handle), isTrue);
    backend.dispose();
  });

  test('a wall blocks horizontal movement', () {
    // Wall one metre ahead of the spawn, two metres tall.
    final backend = React3dPhysicsBackend()
      ..createWorld(floorConfig(extraBoxes: [
        {
          'name': 'wall',
          'center': [1.5, 1.0, 0],
          'halfExtents': [0.5, 1.0, 2.0],
        },
      ]));
    final handle = backend.addPlayerBody(const BackendSpawn(0, 5, 0));
    settle(backend);
    for (var i = 0; i < 60; i++) {
      backend.applyMovementInput(
        handle,
        const MovementIntent(velocityX: 4.5, velocityZ: 0),
      );
      backend.step(1 / 60);
    }
    // Blocked at the wall face (1.0 m) minus the capsule radius.
    expect(backend.poseOf(handle).x, lessThan(0.8));
    expect(backend.poseOf(handle).x, greaterThan(0.3));
    backend.dispose();
  });

  test('heightfield terrain supports players at its sampled height', () {
    // A 16×16 m plateau: every sample 2.0 m, so the surface sits at y = 2.
    final heights = List<double>.filled(17 * 17, 2.0);
    final config = MovementRoomConfig.fromJson(jsonDecode('''
    {
      "version": 1, "template": "physics", "capacity": 8,
      "tick": { "simulationHz": 60, "snapshotHz": 20 },
      "colliders": {
        "heightfield": { "size": [16, 16], "data": ${jsonEncode(heights)} }
      },
      "spawnPoints": [ { "position": [0, 5, 0], "yaw": 0 } ],
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
    final backend = React3dPhysicsBackend()..createWorld(config);
    final handle = backend.addPlayerBody(const BackendSpawn(0, 5, 0));
    settle(backend);
    expect(backend.poseOf(handle).y, closeTo(2.0 + 0.9, 0.05));
    expect(backend.isGrounded(handle), isTrue);
    backend.dispose();
  });

  test('removed bodies release their slot', () {
    final backend = React3dPhysicsBackend()..createWorld(floorConfig());
    final handle = backend.addPlayerBody(const BackendSpawn(0, 5, 0));
    backend.removePlayerBody(handle);
    backend.removePlayerBody(handle); // idempotent
    expect(() => backend.poseOf(handle), throwsStateError);
    expect(() => backend.isGrounded(handle), throwsStateError);
    backend.dispose();
  });

  test('the authority drives the backend end to end', () {
    final config = floorConfig(spawnY: 1);
    final backend = React3dPhysicsBackend();
    final room = MovementTemplateAuthority(
      config,
      backend: backend,
      creatorToken: 'tok',
    );
    final claim = room.validateJoin({'creatorToken': 'tok'});
    room.addPlayer('p', 'p', claim);
    room.command('p', {'type': 'input', 'moveX': 1});
    for (var i = 0; i < 180; i++) {
      room.update(1 / 60);
    }
    final pose = (room.snapshot()['players']['p'] as Map)['pose'] as Map;
    expect(pose['x'] as double, greaterThan(1.0));
    // Settled onto the floor: feet at 0 → snapshot y stays near 0.9 centre
    // height (the backend reports capsule-centre positions).
    expect(pose['y'] as double, closeTo(0.9, 0.1));
    expect(room.pingLocation('p', 'here')!.x, greaterThan(1.0));
    room.dispose();
  });
}

/// The documented example's collider set: box + capsule + 64×64 heightfield.
MovementRoomConfig _docsColliders() {
  final heights = List<double>.generate(65 * 65, (i) => ((i % 65) - 32) / 64.0);
  return MovementRoomConfig.fromJson(jsonDecode('''
  {
    "version": 1, "template": "physics", "capacity": 32,
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
