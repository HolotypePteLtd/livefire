// The world demo's server-side game: a KINEMATIC movement authority —
// speed-clamped inputs integrated over a flat, bounded area. Deliberately
// no physics engine (no gravity, no colliders beyond the area bounds): the
// production physics template (`docs/room_templates.md`, ReactPhysics3D)
// is a server-process concern and out of this demo's scope. What this
// authority keeps from the real template is the promise: clients send only
// inputs, the server owns every position, and a hacked client cannot move
// faster than the configured speed or leave the area.
import 'dart:math' as math;

import 'package:protocol/protocol.dart';

const protocolVersion = 1;

/// One player's simulation state.
class _Avatar {
  _Avatar(this.name);
  final String name;
  double x = 0, z = 0, yaw = 0;
  double vx = 0, vz = 0;
  double inputX = 0, inputZ = 0;
  bool run = false;
}

/// Speeds in metres/second, area in metres (square, centred on origin).
class KinematicWorldAuthority implements RoomAuthority {
  KinematicWorldAuthority({
    this.halfExtent = 18,
    this.walkSpeed = 4.5,
    this.runSpeed = 8,
    this.acceleration = 30,
  });

  final double halfExtent, walkSpeed, runSpeed, acceleration;

  final _players = <String, _Avatar>{};
  @override
  int capacity = 8, tick = 0;
  @override
  double elapsed = 0;

  @override
  void update(double seconds) {
    elapsed += seconds;
    tick++;
    for (final p in _players.values) {
      // Input is a *request*: clamped to the unit circle and scaled by the
      // server-owned speed — magnitude beyond walking range never helps.
      var ix = p.inputX, iz = p.inputZ;
      final mag = math.sqrt(ix * ix + iz * iz);
      if (mag > 1) {
        ix /= mag;
        iz /= mag;
      }
      final speed = p.run ? runSpeed : walkSpeed;
      final targetVx = ix * speed, targetVz = iz * speed;

      // Velocity approaches the target at a bounded rate (no instant
      // turns), then integrates position.
      final dv = acceleration * seconds;
      p.vx += (targetVx - p.vx).clamp(-dv, dv);
      p.vz += (targetVz - p.vz).clamp(-dv, dv);
      p.x += p.vx * seconds;
      p.z += p.vz * seconds;

      // The area is bounded: clamp position, kill the into-wall velocity.
      final bx = p.x.clamp(-halfExtent, halfExtent);
      final bz = p.z.clamp(-halfExtent, halfExtent);
      if (bx != p.x) {
        p.x = bx;
        p.vx = 0;
      }
      if (bz != p.z) {
        p.z = bz;
        p.vz = 0;
      }

      // Facing follows movement (atan2 on the XZ plane).
      final speed2 = math.sqrt(p.vx * p.vx + p.vz * p.vz);
      if (speed2 > 0.2) p.yaw = math.atan2(p.vx, p.vz);
    }
  }

  @override
  Object? validateJoin(Map<String, dynamic> message) => null;

  @override
  void addPlayer(String id, String name, Object? data) {
    // Stagger spawn points around the centre so avatars start apart.
    final index = _players.length;
    final angle = index * math.pi / 2;
    final p = _Avatar(name)
      ..x = 4 * math.cos(angle)
      ..z = 4 * math.sin(angle);
    _players[id] = p;
  }

  @override
  void resume(String id, Object? data) {}

  @override
  void disconnect(String id) {
    // A dropped player's avatar stops in place (inputs cleared).
    final p = _players[id];
    if (p != null) {
      p
        ..inputX = 0
        ..inputZ = 0
        ..run = false;
    }
  }

  @override
  void removePlayer(String id) => _players.remove(id);

  @override
  Map<String, dynamic> welcome(String id) => {
    'sequence': 0,
    'spawn': {'x': _players[id]?.x ?? 0, 'z': _players[id]?.z ?? 0},
  };

  @override
  void command(String id, Map<String, dynamic> message) {
    if (message['type'] != 'input') return;
    final p = _players[id];
    if (p == null) return;
    final x = message['moveX'], z = message['moveZ'];
    // Non-finite or non-numeric input is ignored, never trusted.
    if (x is num && x.isFinite) p.inputX = x.toDouble();
    if (z is num && z.isFinite) p.inputZ = z.toDouble();
    p.run = message['run'] == true;
  }

  @override
  Map<String, dynamic> snapshot() => {
    'type': 'snapshot',
    'epoch': 0,
    'tick': tick,
    'time': elapsed,
    'players': {
      for (final entry in _players.entries)
        entry.key: {
          'name': entry.value.name,
          'x': entry.value.x,
          'z': entry.value.z,
          'yaw': entry.value.yaw,
        },
    },
    'room': {'halfExtent': halfExtent},
  };

  @override
  void dispose() {}
}
