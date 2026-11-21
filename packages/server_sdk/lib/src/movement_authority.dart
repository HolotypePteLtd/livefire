import 'dart:collection';
import 'dart:math' as math;

import 'package:protocol/protocol.dart';

import 'join_tokens.dart';

import 'movement_config.dart';
import 'physics_backend.dart';

/// Per-player movement state. Input state is the last accepted input message
/// (missing fields default: axes `0`, actions `false`); velocity is the
/// authority-integrated horizontal velocity, not a client claim.
class _Player {
  _Player({required this.handle, required this.yaw, required this.spawn});

  final int handle;
  final SpawnPoint spawn;
  final Map<String, double> axes = {};
  final Map<String, bool> actions = {};
  double velocityX = 0, velocityZ = 0;
  double yaw;

  /// Rising-edge jump request, buffered briefly so a press just before
  /// landing still fires.
  bool jumpHeld = false;
  double? _jumpPressedAt;

  bool pendingJump(double now, {double buffer = 0.25}) {
    final at = _jumpPressedAt;
    return at != null && now - at <= buffer;
  }

  void pressJump(double now) => _jumpPressedAt = now;
  void consumeJump() => _jumpPressedAt = null;

  void clearInput() {
    axes.clear();
    actions.clear();
    jumpHeld = false;
    _jumpPressedAt = null;
  }
}

/// Platform authority for movement rooms: server-simulated character
/// movement over configured static colliders (`docs/room_templates.md` →
/// movement template).
///
/// All game and validation logic is engine-free and lives here: input
/// whitelisting/clamping, per-player rate limits, spawn assignment, the
/// horizontal velocity model (walk/run targets, acceleration, air control)
/// and yaw. Collision resolution and vertical dynamics are delegated to an
/// injected [PhysicsBackend] — `physics_react3d` is the reference engine
/// binding; tests use a deterministic kinematic backend.
///
/// Clients never publish poses: `command` carries input requests only, and
/// the server simulates from the last acknowledged state, so teleports and
/// speed hacks are impossible by construction. Invalid or over-rate inputs
/// are dropped and counted — never disconnected (the relay posture); the
/// authoritative snapshot is the feedback loop.
///
/// Hosts drive the room at the configured rates —
/// `RoomHub(simulationHz: config.tick.simulationHz, snapshotHz:
/// config.tick.snapshotHz)` — so [update] receives fixed `1 / simulationHz`
/// steps. Poses are returned as raw doubles; the hub's SnapshotEncoder
/// quantizes them to 4 decimal places like every other room.
class MovementTemplateAuthority implements RoomAuthority, RoomSocialAuthority {
  /// [backend] builds its static world from [config] on construction.
  /// [creatorToken] proves the creating client at join, exactly like the
  /// relay template — moderation (roster, lock, kick, ban) and chat come
  /// from the room social layer.
  ///
  /// SEAM(join-token): replace the token comparison with verification of a
  /// signed join-token claim (`{"creator": true}`) minted by the control
  /// plane.
  MovementTemplateAuthority(
    this.config, {
    required PhysicsBackend backend,
    required this._creatorToken,
    this._creatorTokenVerifier,
  }) : _backend = backend {
    backend.createWorld(config);
  }

  final MovementRoomConfig config;
  final PhysicsBackend _backend;
  final String _creatorToken;
  final TokenCheck Function(String token)? _creatorTokenVerifier;

  final _players = <String, _Player>{};
  final _rates = <String, Queue<double>>{};
  int _spawnCursor = 0;
  String? _creatorId;
  int _tick = 0;
  double _elapsed = 0;

  /// Rejected input messages (rate, whitelist or validation), for operators
  /// and tests. Rejections never close a connection.
  int rejectedInputs = 0;
  String? lastRejection;

  /// Static config echo: small, fixed, computed once. Never carries the
  /// heightfield samples — clients read the pinned template config itself.
  late final Map<String, Object?> _roomEcho = _buildRoomEcho();

  Map<String, Object?> _buildRoomEcho() => {
    'template': 'physics',
    'simulationHz': config.tick.simulationHz,
    'snapshotHz': config.tick.snapshotHz,
    'movement': {
      'walkSpeed': config.movement.walkSpeed,
      'runSpeed': config.movement.runSpeed,
      'gravity': config.movement.gravity,
      'jumpSpeed': config.movement.jumpSpeed,
      'airControl': config.movement.airControl,
      'acceleration': config.movement.acceleration,
    },
    'spawnPoints': [
      for (final spawn in config.spawnPoints)
        {'position': [spawn.x, spawn.y, spawn.z], 'yaw': spawn.yaw},
    ],
    'colliders': {
      'boxes': config.colliders.boxes.length,
      'capsules': config.colliders.capsules.length,
      'heightfield': config.colliders.heightfield == null
          ? null
          : [
              config.colliders.heightfield!.cellsX,
              config.colliders.heightfield!.cellsZ,
            ],
    },
  };

  @override
  int get capacity => config.capacity;
  @override
  int get tick => _tick;
  @override
  double get elapsed => _elapsed;

  @override
  void update(double seconds) {
    // Fixed steps arrive from the hub; the clamp is a tunneling guard for
    // direct embedders.
    final h = seconds <= 0 ? 0.0 : (seconds > 0.1 ? 0.1 : seconds);
    _elapsed += h;
    _tick++;
    if (h == 0) return;
    for (final player in _players.values) {
      final grounded = _backend.isGrounded(player.handle);
      // Analog input: direction from the axes, magnitude clamped to a unit
      // vector (walk/run speed is server-owned).
      var dirX = player.axes['moveX'] ?? 0;
      var dirZ = player.axes['moveZ'] ?? 0;
      final length = _hypot(dirX, dirZ);
      if (length > 1) {
        dirX /= length;
        dirZ /= length;
      }
      final sprint = player.actions['sprint'] ?? false;
      final speed =
          sprint ? config.movement.runSpeed : config.movement.walkSpeed;
      final accel =
          config.movement.acceleration *
          (grounded ? 1.0 : config.movement.airControl) *
          h;
      player.velocityX = _approach(player.velocityX, dirX * speed, accel);
      player.velocityZ = _approach(player.velocityZ, dirZ * speed, accel);
      final jump = grounded && player.pendingJump(_elapsed);
      if (jump) player.consumeJump();
      _backend.applyMovementInput(
        player.handle,
        MovementIntent(
          velocityX: player.velocityX,
          velocityZ: player.velocityZ,
          jump: jump,
        ),
      );
      // Facing follows actual movement, not input intent.
      if (_hypot(player.velocityX, player.velocityZ) > 1e-4) {
        player.yaw = math.atan2(player.velocityX, player.velocityZ);
      }
    }
    _backend.step(h);
  }

  @override
  Object? validateJoin(Map<String, dynamic> message) {
    // Same seam as RelayAuthority: signed creator claim when a verifier is
    // wired, opaque string otherwise.
    final claim = message['creatorToken'];
    if (claim is! String) return null;
    final verifier = _creatorTokenVerifier;
    if (verifier != null) {
      final check = verifier(claim);
      if (check.ok && check.payload!.creator) {
        return {
          'creator': true,
          if (check.payload!.did != null) 'did': check.payload!.did,
        };
      }
      return null;
    }
    if (claim == _creatorToken) {
      return const {'creator': true};
    }
    return null;
  }

  @override
  void addPlayer(String id, String name, Object? joinData) {
    // joinData is server-produced by validateJoin above; a client cannot
    // forge it in the join payload.
    final claimedCreator =
        joinData is Map && joinData['creator'] == true;
    if (claimedCreator && _creatorId == null) _creatorId = id;
    final spawn = config.spawnPoints[_spawnCursor++ % config.spawnPoints.length];
    final handle = _backend.addPlayerBody(
      BackendSpawn(spawn.x, spawn.y, spawn.z),
    );
    _players[id] = _Player(handle: handle, yaw: spawn.yaw, spawn: spawn);
  }

  @override
  void resume(String id, Object? joinData) {
    // The body survives disconnects inside the resume grace window.
  }

  @override
  void disconnect(String id) {
    // Inputs stop; the avatar decelerates to a stop at its last pose.
    _players[id]?.clearInput();
  }

  @override
  void removePlayer(String id) {
    final player = _players.remove(id);
    if (player != null) _backend.removePlayerBody(player.handle);
    _rates.remove(id);
    if (_creatorId == id) _creatorId = null;
  }

  @override
  Map<String, dynamic> welcome(String id) {
    final spawn = _players[id]?.spawn ?? config.spawnPoints.first;
    return {
      'sequence': 0,
      'spawn': {
        'x': spawn.x,
        'y': spawn.y,
        'z': spawn.z,
        'yaw': spawn.yaw,
      },
    };
  }

  @override
  void command(String id, Map<String, dynamic> message) {
    if (message['type'] != 'input') return; // like the relay: ignore others.
    final player = _players[id];
    if (player == null) return;

    // Whitelist and validate every field against the input mapping; one bad
    // field rejects the whole message and consumes no rate budget.
    final axes = <String, double>{};
    final actions = <String, bool>{};
    for (final entry in message.entries) {
      if (entry.key == 'type') continue;
      final field = config.inputMapping[entry.key];
      if (field == null) {
        return _reject('undeclared input field: ${entry.key}');
      }
      switch (field) {
        case AxisInput(:final min, :final max):
          final value = entry.value;
          if (value is! num || !value.isFinite) {
            return _reject('${entry.key} must be a finite number');
          }
          // Clamped, never rejected for magnitude.
          axes[entry.key] = value.toDouble().clamp(min, max);
        case ActionInput():
          if (entry.value is! bool) {
            return _reject('${entry.key} must be a bool');
          }
          actions[entry.key] = entry.value as bool;
      }
    }

    // Rate window: checked up front, stamped only when the input commits.
    final stamps = _rates.putIfAbsent(id, Queue<double>.new);
    while (stamps.isNotEmpty && stamps.first <= _elapsed - 1) {
      stamps.removeFirst();
    }
    if (stamps.length >= config.inputsPerSecond) {
      return _reject('input rate exceeded');
    }

    player.axes
      ..clear()
      ..addAll(axes);
    player.actions
      ..clear()
      ..addAll(actions);
    final jumpNow = actions['jump'] ?? false;
    if (jumpNow && !player.jumpHeld) player.pressJump(_elapsed);
    if (!jumpNow) player.consumeJump();
    player.jumpHeld = jumpNow;
    stamps.addLast(_elapsed);
  }

  void _reject(String reason) {
    rejectedInputs++;
    lastRejection = reason;
  }

  @override
  Map<String, dynamic> snapshot() => {
    'type': 'snapshot',
    'epoch': 0,
    'tick': _tick,
    'time': _elapsed,
    'players': {
      for (final entry in _players.entries)
        entry.key: {'pose': _pose(entry.value)},
    },
    'room': _roomEcho,
  };

  Map<String, Object?> _pose(_Player player) {
    final pose = _backend.poseOf(player.handle);
    return {'x': pose.x, 'y': pose.y, 'z': pose.z, 'yaw': player.yaw};
  }

  @override
  String? get roomLeaderId => _creatorId;

  /// Pings need authority-side coordinates: the server-simulated pose.
  @override
  PingLocation? pingLocation(String playerId, String kind) {
    final player = _players[playerId];
    if (player == null) return null;
    final pose = _backend.poseOf(player.handle);
    return PingLocation(pose.x, pose.y, pose.z, 0);
  }

  @override
  void dispose() => _backend.dispose();
}

double _approach(double value, double target, double maxStep) {
  final delta = target - value;
  if (delta > maxStep) return value + maxStep;
  if (delta < -maxStep) return value - maxStep;
  return target;
}

double _hypot(double x, double y) => math.sqrt(x * x + y * y);
