import 'movement_config.dart';

/// A player pose read back from the backend: world-space position in metres.
/// Orientation is authority-side game state (yaw from the movement model),
/// so backends only own translation.
class BackendPose {
  const BackendPose(this.x, this.y, this.z);
  final double x, y, z;
}

/// Where a player body enters the world.
class BackendSpawn {
  const BackendSpawn(this.x, this.y, this.z);
  final double x, y, z;
}

/// One simulation step's request for a player body, produced by
/// [MovementTemplateAuthority] from validated input.
///
/// The authority owns the horizontal velocity model (walk/run targets,
/// acceleration, air control); the backend resolves collisions and owns
/// vertical dynamics (gravity, the jump launch when [jump] is set).
class MovementIntent {
  const MovementIntent({
    required this.velocityX,
    required this.velocityZ,
    this.jump = false,
  });

  /// Target horizontal velocity in metres/second (authority-integrated).
  final double velocityX, velocityZ;

  /// Launch a grounded body at `movement.jumpSpeed` this step.
  final bool jump;
}

/// Engine-agnostic physics service behind the physics room template.
///
/// `server_sdk` stays free of physics engines: all game and validation logic
/// lives in [MovementTemplateAuthority]; implementations of this interface
/// only build the static world from the validated config, manage player
/// bodies, apply movement intents and step. `physics_react3d` is the
/// reference implementation (reactphysics3d_dart); tests use a deterministic
/// kinematic backend with the same movement parameters.
abstract interface class PhysicsBackend {
  /// Build the static world (gravity, colliders) from a validated config.
  /// Called once, before any body is added.
  void createWorld(MovementRoomConfig config);

  /// Add a player body at a spawn point; returns its handle.
  int addPlayerBody(BackendSpawn spawn);

  /// Remove a player body and release its slot. Idempotent per handle.
  void removePlayerBody(int handle);

  /// Set a body's movement intent for the next [step]. Backends may also
  /// pin orientation here (the movement model is yaw-only).
  void applyMovementInput(int handle, MovementIntent intent);

  /// Advance the world by [seconds] (hosts drive this at
  /// `1 / tick.simulationHz` fixed steps).
  void step(double seconds);

  /// The body's current world position. Throws [StateError] for unknown or
  /// removed handles.
  BackendPose poseOf(int handle);

  /// Whether the body is supported (standing on the static world).
  bool isGrounded(int handle);

  /// Release every native resource the backend owns.
  void dispose();
}
