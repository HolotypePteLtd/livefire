import 'dart:math' as math;
import 'dart:typed_data';

import 'package:reactphysics3d_dart/reactphysics3d_dart.dart'
    hide Ray, Transform;
import 'package:reactphysics3d_dart/reactphysics3d_dart.dart' as rp3d;
import 'package:server_sdk/server_sdk.dart';

/// The reactphysics3d_dart implementation of [PhysicsBackend] for physics
/// room templates. Engine binding only: world building from the validated
/// config schema, player body management, stepping and pose reads. Every
/// game and validation decision lives in `server_sdk`.
///
/// ## Conventions
///
/// - Spawn positions are **feet** positions: a player capsule's centre lands
///   at `spawn.y + playerHeight / 2` (default capsule: radius 0.4 m,
///   total height 1.8 m — a v0 constant, see `docs/room_templates.md`).
/// - Heightfields sample at one-metre spacing: `size` counts cells per axis
///   and the field spans `nx × nz` metres centred on the origin, matching
///   the engine's auto-centred terrain bounds.
/// - Orientation is pinned upright: angular velocity is zeroed before each
///   step and orientation reset after it. The movement model is yaw-only
///   and yaw is authority-side.
/// - The grounded check raycasts from the body centre, through the capsule
///   (rays ignore shapes they start inside) to `playerHeight / 2 + margin`
///   below it; a hit that is not the player's own body means support.
///
/// ## Native library
///
/// reactphysics3d_dart is native FFI: its build hook compiles the C bridge
/// and links the prebuilt ReactPhysics3D archive shipped for
/// linux-x86_64/arm64 and macos-arm64. `dart pub get && dart test` builds
/// it automatically where a C toolchain exists; other targets need a
/// compatible archive (see that package's BUILDING.md).
class React3dPhysicsBackend implements PhysicsBackend {
  React3dPhysicsBackend({
    this.playerRadius = 0.4,
    this.playerHeight = 1.8,
    this.groundedMargin = 0.12,
  });

  /// Player capsule radius in metres.
  final double playerRadius;

  /// Player capsule total height in metres (cylinder + two caps).
  final double playerHeight;

  /// How far below the feet the grounded ray may reach and still count as
  /// support.
  final double groundedMargin;

  ReactPhysics3D? _physics;
  PhysicsWorld? _world;
  double _jumpSpeed = 0;
  final _bodies = <int, RigidBody>{};
  int _nextHandle = 1;

  @override
  void createWorld(MovementRoomConfig config) {
    final physics = _physics = createReactPhysics3D();
    final world = _world = physics.createWorld();
    world.setGravity(Vector3(0, config.movement.gravity, 0));
    _jumpSpeed = config.movement.jumpSpeed;

    for (final box in config.colliders.boxes) {
      final body = world.createRigidBody(
        transform: (
          position: Vector3(box.centerX, box.centerY, box.centerZ),
          orientation: Quaternion.identity(),
        ),
      );
      body.type = BodyType.STATIC;
      body.addCollider(
        physics.createBoxShape(Vector3(box.halfX, box.halfY, box.halfZ)),
      );
    }

    for (final capsule in config.colliders.capsules) {
      final base = Vector3(capsule.baseX, capsule.baseY, capsule.baseZ);
      final top = Vector3(capsule.topX, capsule.topY, capsule.topZ);
      final segment = top - base;
      final length = segment.length;
      final body = world.createRigidBody(
        transform: (
          position: base + segment * 0.5,
          orientation: _alongY(segment),
        ),
      );
      body.type = BodyType.STATIC;
      // Capsule height excludes the hemispherical caps.
      body.addCollider(
        physics.createCapsuleShape(capsule.radius, length - 2 * capsule.radius),
      );
    }

    final heightfield = config.colliders.heightfield;
    if (heightfield != null) {
      final rows = heightfield.cellsZ + 1; // rows run along Z
      final columns = heightfield.cellsX + 1;
      final heights = Float32List.fromList(heightfield.heights);
      var minHeight = heightfield.heights.first;
      var maxHeight = minHeight;
      for (final height in heightfield.heights) {
        if (height < minHeight) minHeight = height;
        if (height > maxHeight) maxHeight = height;
      }
      final field = physics.createHeightFieldFloat(
        rows: rows,
        columns: columns,
        heights: heights,
        minHeight: minHeight,
        maxHeight: maxHeight,
      );
      final shape = physics.createHeightFieldShape(field);
      // The engine centres the terrain's vertical bounds on the origin;
      // lifting the body by (min + max) / 2 restores absolute heights.
      final body = world.createRigidBody(
        transform: (
          position: Vector3(0, (minHeight + maxHeight) / 2, 0),
          orientation: Quaternion.identity(),
        ),
      );
      body.type = BodyType.STATIC;
      body.addCollider(shape);
    }
  }

  /// Rotation from +Y onto the segment direction (identity for a vertical
  /// segment); capsules are Y-axis aligned in the engine.
  Quaternion _alongY(Vector3 segment) {
    final direction = segment.normalized();
    final dot = direction.y; // cos(angle) against +Y
    if (dot > 1 - 1e-9) return Quaternion.identity();
    if (dot < -1 + 1e-9) {
      return Quaternion.axisAngle(Vector3(1, 0, 0), 3.141592653589793);
    }
    final axis = Vector3(0, 1, 0).cross(direction).normalized();
    return Quaternion.axisAngle(axis, math.acos(dot));
  }

  @override
  int addPlayerBody(BackendSpawn spawn) {
    final world = _world!;
    final body = world.createRigidBody(
      transform: (
        position: Vector3(spawn.x, spawn.y + playerHeight / 2, spawn.z),
        orientation: Quaternion.identity(),
      ),
    );
    body.addCollider(
      _physics!.createCapsuleShape(playerRadius, playerHeight - 2 * playerRadius),
    );
    body.updateMassPropertiesFromColliders();
    final handle = _nextHandle++;
    _bodies[handle] = body;
    return handle;
  }

  @override
  void removePlayerBody(int handle) {
    final body = _bodies.remove(handle);
    if (body != null) _world?.destroyRigidBody(body);
  }

  @override
  void applyMovementInput(int handle, MovementIntent intent) {
    final body = _bodies[handle];
    if (body == null) return;
    // Pin orientation: no angular motion carries into the step.
    body.angularVelocity = Vector3.zero();
    final v = body.linearVelocity;
    body.linearVelocity = Vector3(
      intent.velocityX,
      intent.jump ? _jumpSpeed : v.y,
      intent.velocityZ,
    );
  }

  @override
  void step(double seconds) {
    _world!.update(seconds);
    // Reset any contact-induced rotation; the movement model is yaw-only.
    for (final body in _bodies.values) {
      final position = body.transform.position;
      body.setTransform(
        (position: position.clone(), orientation: Quaternion.identity()),
      );
    }
  }

  @override
  BackendPose poseOf(int handle) {
    final body = _bodies[handle];
    if (body == null) {
      throw StateError('Unknown or removed body handle: $handle');
    }
    final p = body.transform.position;
    return BackendPose(p.x, p.y, p.z);
  }

  @override
  bool isGrounded(int handle) {
    final body = _bodies[handle];
    if (body == null) {
      throw StateError('Unknown or removed body handle: $handle');
    }
    final p = body.transform.position;
    final hit = _world!.raycast(
      rp3d.Ray(p, p - Vector3(0, playerHeight / 2 + groundedMargin, 0)),
    );
    return hit != null && !identical(hit.body, body);
  }

  @override
  void dispose() {
    // The factory owns worlds, bodies and shapes; it releases them all.
    _bodies.clear();
    _physics?.dispose();
    _physics = null;
    _world = null;
  }
}
