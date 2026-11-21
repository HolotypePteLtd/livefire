import 'package:server_sdk/server_sdk.dart';

/// Deterministic test backend: plain Euler integration of the same movement
/// parameters (gravity, jump launch) with an infinite floor plane at
/// `groundY` and no colliders. Used by the movement-authority tests so the
/// game logic is verified against analytically computable poses; the
/// reactphysics3d_dart backend lives in `packages/physics_react3d`.
class KinematicBackend implements PhysicsBackend {
  KinematicBackend({this.groundY = 0});

  /// The floor plane's height; players rest at `groundY`.
  final double groundY;

  MovementRoomConfig? _config;
  final _bodies = <int, _KinematicBody>{};
  final List<int> removedHandles = [];
  int _nextHandle = 1;

  /// Bodies currently alive (for cleanup assertions).
  int get bodyCount => _bodies.length;

  int get stepCount => _steps;

  int _steps = 0;

  @override
  void createWorld(MovementRoomConfig config) => _config = config;

  @override
  int addPlayerBody(BackendSpawn spawn) {
    final handle = _nextHandle++;
    final body = _KinematicBody(spawn.x, spawn.y, spawn.z)
      ..grounded = spawn.y <= groundY + 1e-9;
    _bodies[handle] = body;
    return handle;
  }

  @override
  void removePlayerBody(int handle) {
    if (_bodies.remove(handle) != null) removedHandles.add(handle);
  }

  @override
  void applyMovementInput(int handle, MovementIntent intent) {
    final body = _bodies[handle];
    if (body == null) return;
    body.velocityX = intent.velocityX;
    body.velocityZ = intent.velocityZ;
    if (intent.jump && body.grounded) body.velocityY = _config!.movement.jumpSpeed;
  }

  @override
  void step(double seconds) {
    _steps++;
    final gravity = _config!.movement.gravity;
    for (final body in _bodies.values) {
      body.x += body.velocityX * seconds;
      body.z += body.velocityZ * seconds;
      body.velocityY += gravity * seconds;
      body.y += body.velocityY * seconds;
      if (body.y <= groundY && body.velocityY <= 0) {
        body.y = groundY;
        body.velocityY = 0;
        body.grounded = true;
      } else {
        body.grounded = body.y <= groundY + 1e-9;
      }
    }
  }

  @override
  BackendPose poseOf(int handle) {
    final body = _bodies[handle];
    if (body == null) {
      throw StateError('Unknown or removed body handle: $handle');
    }
    return BackendPose(body.x, body.y, body.z);
  }

  @override
  bool isGrounded(int handle) {
    final body = _bodies[handle];
    if (body == null) {
      throw StateError('Unknown or removed body handle: $handle');
    }
    return body.grounded;
  }

  @override
  void dispose() => _bodies.clear();
}

class _KinematicBody {
  _KinematicBody(this.x, this.y, this.z);

  double x, y, z;
  double velocityX = 0, velocityY = 0, velocityZ = 0;
  bool grounded = false;
}
