/// Validated movement room configuration (`docs/room_templates.md`, version 1).
///
/// Configs are pinned at room creation; unknown fields are rejected so a
/// pinned config keeps validating identically forever (append-only rule).
/// Every template section in the v1 schema is required — the documented
/// example config is the canonical shape; later versions may only add
/// optional fields.
library;

import 'dart:math' as math;

/// `tick` — hub tick rates. The host builds the room hub with these:
/// `RoomHub(simulationHz: tick.simulationHz, snapshotHz: tick.snapshotHz)`,
/// so the authority receives fixed `update` steps of `1 / simulationHz`.
class MovementTick {
  const MovementTick({required this.simulationHz, required this.snapshotHz});

  factory MovementTick.fromJson(Map<String, dynamic> json) {
    _only(json, const {'simulationHz', 'snapshotHz'}, 'tick');
    final simulationHz = _intIn(json, 'simulationHz', 10, 240);
    final snapshotHz = _intIn(json, 'snapshotHz', 1, 60);
    if (snapshotHz > simulationHz) {
      throw const FormatException('snapshotHz must be <= simulationHz');
    }
    return MovementTick(simulationHz: simulationHz, snapshotHz: snapshotHz);
  }

  final int simulationHz;
  final int snapshotHz;
}

/// `colliders.boxes[]` — an axis-aligned static box.
class BoxCollider {
  const BoxCollider({
    this.name = '',
    required this.centerX,
    required this.centerY,
    required this.centerZ,
    required this.halfX,
    required this.halfY,
    required this.halfZ,
  });

  factory BoxCollider.fromJson(Map<String, dynamic> json) {
    _only(json, const {'name', 'center', 'halfExtents'}, 'box');
    final center = _vec3(json, 'center');
    final half = _vec3(json, 'halfExtents');
    for (final value in [half.x, half.y, half.z]) {
      if (value <= 0 || value > 500) {
        throw const FormatException('halfExtents must be > 0 and <= 500');
      }
    }
    return BoxCollider(
      name: _name(json),
      centerX: center.x,
      centerY: center.y,
      centerZ: center.z,
      halfX: half.x,
      halfY: half.y,
      halfZ: half.z,
    );
  }

  /// Optional label, echoed in the room snapshot.
  final String name;
  final double centerX, centerY, centerZ;
  final double halfX, halfY, halfZ;
}

/// `colliders.capsules[]` — a static capsule spanning `base` → `top`.
/// The segment must be at least twice the radius so the underlying cylinder
/// height is non-negative.
class CapsuleCollider {
  const CapsuleCollider({
    this.name = '',
    required this.baseX,
    required this.baseY,
    required this.baseZ,
    required this.topX,
    required this.topY,
    required this.topZ,
    required this.radius,
  });

  factory CapsuleCollider.fromJson(Map<String, dynamic> json) {
    _only(json, const {'name', 'base', 'top', 'radius'}, 'capsule');
    final base = _vec3(json, 'base');
    final top = _vec3(json, 'top');
    final radius = _numIn(json, 'radius');
    if (radius <= 0 || radius > 500) {
      throw const FormatException('radius must be > 0 and <= 500');
    }
    final dx = top.x - base.x, dy = top.y - base.y, dz = top.z - base.z;
    final length = _sqrt(dx * dx + dy * dy + dz * dz);
    if (length <= 2 * radius) {
      throw const FormatException(
        'capsule segment must be strictly greater than twice its radius',
      );
    }
    return CapsuleCollider(
      name: _name(json),
      baseX: base.x,
      baseY: base.y,
      baseZ: base.z,
      topX: top.x,
      topY: top.y,
      topZ: top.z,
      radius: radius,
    );
  }

  final String name;
  final double baseX, baseY, baseZ;
  final double topX, topY, topZ;
  final double radius;

  /// Segment length, `||top - base||`.
  double get length {
    final dx = topX - baseX, dy = topY - baseY, dz = topZ - baseZ;
    return _sqrt(dx * dx + dy * dy + dz * dz);
  }
}

/// `colliders.heightfield` — a static terrain grid.
///
/// `size` is the number of one-metre cells per axis; `data` holds
/// `(nx + 1) * (nz + 1)` row-major samples (`data[row * (nx + 1) + column]`,
/// rows along Z). The field spans `nx × nz` metres centred on the origin —
/// the engine computes terrain bounds from the samples; there is no offset
/// field in v1.
class HeightFieldConfig {
  const HeightFieldConfig({
    required this.cellsX,
    required this.cellsZ,
    required this.heights,
  });

  factory HeightFieldConfig.fromJson(Map<String, dynamic> json) {
    _only(json, const {'size', 'data'}, 'heightfield');
    final size = json['size'];
    if (size is! List || size.length != 2) {
      throw const FormatException('heightfield size must be [nx, nz]');
    }
    final nx = size[0], nz = size[1];
    if (nx is! int || nz is! int || nx < 16 || nx > 1024 || nz < 16 || nz > 1024) {
      throw const FormatException('heightfield size must be 16-1024 per axis');
    }
    final raw = json['data'];
    if (raw is! List || raw.length != (nx + 1) * (nz + 1)) {
      throw const FormatException(
        'heightfield data must hold (nx + 1) * (nz + 1) samples',
      );
    }
    final heights = <double>[];
    for (final value in raw) {
      if (value is! num || !value.isFinite || value.abs() > 10000) {
        throw const FormatException(
          'heights must be finite and |h| <= 10000',
        );
      }
      heights.add(value.toDouble());
    }
    return HeightFieldConfig(cellsX: nx, cellsZ: nz, heights: heights);
  }

  /// Cell counts per axis (samples per axis are one more).
  final int cellsX, cellsZ;

  /// Row-major heights in metres, rows along Z.
  final List<double> heights;
}

/// `colliders` — at least one static entry in total.
class MovementColliders {
  const MovementColliders({
    required this.boxes,
    required this.capsules,
    this.heightfield,
  });

  factory MovementColliders.fromJson(Map<String, dynamic> json) {
    _only(json, const {'boxes', 'capsules', 'heightfield'}, 'colliders');
    // Each collider kind is optional; at least one entry is required in
    // total.
    final boxes = json.containsKey('boxes')
        ? _listOf(json, 'boxes', BoxCollider.fromJson)
        : const <BoxCollider>[];
    final capsules = json.containsKey('capsules')
        ? _listOf(json, 'capsules', CapsuleCollider.fromJson)
        : const <CapsuleCollider>[];
    final rawHeightfield = json['heightfield'];
    if (rawHeightfield != null &&
        rawHeightfield is! Map<String, dynamic>) {
      throw const FormatException('heightfield must be an object');
    }
    final heightfield = rawHeightfield == null
        ? null
        : HeightFieldConfig.fromJson(rawHeightfield);
    if (boxes.isEmpty && capsules.isEmpty && heightfield == null) {
      throw const FormatException('colliders must hold at least one entry');
    }
    return MovementColliders(
      boxes: boxes,
      capsules: capsules,
      heightfield: heightfield,
    );
  }

  final List<BoxCollider> boxes;
  final List<CapsuleCollider> capsules;
  final HeightFieldConfig? heightfield;
}

/// `spawnPoints[]` — a teleport target for join/respawn.
class SpawnPoint {
  const SpawnPoint({
    required this.x,
    required this.y,
    required this.z,
    required this.yaw,
  });

  factory SpawnPoint.fromJson(Map<String, dynamic> json) {
    _only(json, const {'position', 'yaw'}, 'spawn point');
    final position = _vec3(json, 'position');
    final yaw = _numIn(json, 'yaw');
    return SpawnPoint(
      x: position.x,
      y: position.y,
      z: position.z,
      yaw: yaw,
    );
  }

  final double x, y, z;
  final double yaw;
}

/// `movement` — the character movement parameters. The authority owns the
/// horizontal velocity model (walk/run targets, acceleration, air control);
/// the backend owns collision resolution and vertical dynamics.
class MovementParams {
  const MovementParams({
    required this.walkSpeed,
    required this.runSpeed,
    required this.gravity,
    required this.jumpSpeed,
    required this.airControl,
    required this.acceleration,
  });

  factory MovementParams.fromJson(Map<String, dynamic> json) {
    _only(
      json,
      const {
        'walkSpeed',
        'runSpeed',
        'gravity',
        'jumpSpeed',
        'airControl',
        'acceleration',
      },
      'movement',
    );
    final params = MovementParams(
      walkSpeed: _range(_numIn(json, 'walkSpeed'), 0.1, 100, 'walkSpeed'),
      runSpeed: _range(_numIn(json, 'runSpeed'), 0.1, 100, 'runSpeed'),
      gravity: _range(_numIn(json, 'gravity'), -30, 0, 'gravity'),
      jumpSpeed: _range(_numIn(json, 'jumpSpeed'), 0, 50, 'jumpSpeed'),
      airControl: _range(_numIn(json, 'airControl'), 0, 1, 'airControl'),
      acceleration: _range(_numIn(json, 'acceleration'), 0.1, 500, 'acceleration'),
    );
    return params;
  }

  final double walkSpeed;
  final double runSpeed;

  /// World gravity along +Y; negative (metres/second²).
  final double gravity;

  /// Grounded-only vertical launch speed (metres/second).
  final double jumpSpeed;

  /// Acceleration scale while airborne, `0–1`.
  final double airControl;

  /// Grounded acceleration towards the target velocity (metres/second²).
  final double acceleration;
}

/// One `inputMapping` entry: an analog `axis` with a declared range, or an
/// on/off `action`.
sealed class InputField {
  const InputField();
  const factory InputField.axis({required double min, required double max}) =
      AxisInput;
  const factory InputField.action() = ActionInput;

  factory InputField.fromJson(Map<String, dynamic> json) {
      _only(json, const {'type', 'range'}, 'input mapping entry');
      switch (json['type']) {
        case 'axis':
          final range = json['range'];
          if (range is! List || range.length != 2 ||
              range[0] is! num || range[1] is! num) {
            throw const FormatException('axis range must be [min, max]');
          }
          final min = (range[0] as num).toDouble();
          final max = (range[1] as num).toDouble();
          if (!min.isFinite || !max.isFinite || min >= max) {
            throw const FormatException('axis range must be finite, min < max');
          }
          return AxisInput(min: min, max: max);
        case 'action':
          return const ActionInput();
        default:
          throw const FormatException('input type must be axis or action');
      }
  }
}

/// Declared range; incoming values are clamped into it, never rejected for
/// magnitude — out-of-range axes are impossible by construction.
class AxisInput extends InputField {
  const AxisInput({required this.min, required this.max});
  final double min, max;
}

/// Boolean on/off input.
class ActionInput extends InputField {
  const ActionInput();
}

class MovementRoomConfig {
  const MovementRoomConfig({
    required this.capacity,
    required this.tick,
    required this.colliders,
    required this.spawnPoints,
    required this.movement,
    required this.inputMapping,
    required this.inputsPerSecond,
    this.chat = true,
  });

  factory MovementRoomConfig.fromJson(Map<String, dynamic> json) {
    _only(
      json,
      const {
        'version',
        'template',
        'capacity',
        'chat',
        'tick',
        'colliders',
        'spawnPoints',
        'movement',
        'inputMapping',
        'inputsPerSecond',
      },
      'config',
    );
    if (json['version'] != 1) {
      throw const FormatException('Unsupported config version');
    }
    if (json['template'] != 'physics') {
      throw const FormatException('Unknown room template');
    }
    final chat = json['chat'] ?? true;
    if (chat is! bool) throw const FormatException('chat must be a bool');
    final tickJson = json['tick'];
    if (tickJson is! Map<String, dynamic>) {
      throw const FormatException('tick must be an object');
    }
    final tick = MovementTick.fromJson(tickJson);
    final collidersJson = json['colliders'];
    if (collidersJson is! Map<String, dynamic>) {
      throw const FormatException('colliders must be an object');
    }
    final spawnJson = json['spawnPoints'];
    if (spawnJson is! List || spawnJson.isEmpty || spawnJson.length > 64) {
      throw const FormatException('spawnPoints must hold 1-64 entries');
    }
    final movementJson = json['movement'];
    if (movementJson is! Map<String, dynamic>) {
      throw const FormatException('movement must be an object');
    }
    final rawInputs = json['inputMapping'];
    if (rawInputs is! Map<String, dynamic> ||
        rawInputs.isEmpty ||
        rawInputs.length > 16) {
      throw const FormatException('inputMapping must hold 1-16 entries');
    }
    final inputMapping = <String, InputField>{};
    for (final entry in rawInputs.entries) {
      if (entry.value is! Map<String, dynamic>) {
        throw FormatException('inputMapping.${entry.key} must be an object');
      }
      inputMapping[_checkedKeyName(entry.key)] = InputField.fromJson(
        entry.value as Map<String, dynamic>,
      );
    }
    // The movement model is fixed: steering needs the two axes, and the
    // reserved names carry semantics — see docs/room_templates.md.
    for (final reserved in const ['moveX', 'moveZ']) {
      if (inputMapping[reserved] is! AxisInput) {
        throw FormatException('$reserved must be declared as an axis');
      }
    }
    for (final reserved in const ['jump', 'sprint']) {
      if (inputMapping.containsKey(reserved) &&
          inputMapping[reserved] is! ActionInput) {
        throw FormatException('$reserved must be declared as an action');
      }
    }
    final inputsPerSecond =
        json['inputsPerSecond'] ?? tick.simulationHz;
    if (inputsPerSecond is! int || inputsPerSecond < 1 || inputsPerSecond > 240) {
      throw const FormatException('inputsPerSecond must be an integer in 1-240');
    }
    return MovementRoomConfig(
      capacity: _intIn(json, 'capacity', 1, 128),
      chat: chat,
      tick: tick,
      colliders: MovementColliders.fromJson(collidersJson),
      spawnPoints: [
        for (final entry in spawnJson)
          entry is Map<String, dynamic>
              ? SpawnPoint.fromJson(entry)
              : throw const FormatException('spawnPoints entries must be objects'),
      ],
      movement: MovementParams.fromJson(movementJson),
      inputMapping: inputMapping,
      inputsPerSecond: inputsPerSecond,
    );
  }

  final int capacity;

  /// Chat/pings on, moderation always on. Enforcement of `chat == false`
  /// is deferred to the hub's optional-social work; the flag is carried and
  /// validated so pinned configs need no change when it lands.
  final bool chat;

  final MovementTick tick;
  final MovementColliders colliders;
  final List<SpawnPoint> spawnPoints;
  final MovementParams movement;
  final Map<String, InputField> inputMapping;

  /// Accepted input messages per sliding one-second window, per player.
  /// Defaults to `tick.simulationHz` — one input per simulation step.
  final int inputsPerSecond;
}

void _only(Map<String, dynamic> json, Set<String> allowed, String what) {
  for (final key in json.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('Unknown $what field: $key');
    }
  }
}

int _intIn(Map<String, dynamic> json, String key, int min, int max) {
  final value = json[key];
  if (value is! int || value < min || value > max) {
    throw FormatException('$key must be an integer in $min-$max');
  }
  return value;
}

double _numIn(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num || !value.isFinite) {
    throw FormatException('$key must be a finite number');
  }
  return value.toDouble();
}

double _range(double value, double min, double max, String key) {
  if (value < min || value > max) {
    throw FormatException('$key must be in $min-$max');
  }
  return value;
}

class _XYZ {
  const _XYZ(this.x, this.y, this.z);
  final double x, y, z;
}

_XYZ _vec3(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List || value.length != 3) {
    throw FormatException('$key must be [x, y, z]');
  }
  if (value[0] is! num || value[1] is! num || value[2] is! num) {
    throw FormatException('$key must be [x, y, z]');
  }
  final x = (value[0] as num).toDouble();
  final y = (value[1] as num).toDouble();
  final z = (value[2] as num).toDouble();
  if (!x.isFinite || !y.isFinite || !z.isFinite) {
    throw const FormatException('coordinates must be finite');
  }
  return _XYZ(x, y, z);
}

double _sqrt(double value) => value <= 0 ? 0 : math.sqrt(value);

final _keyNamePattern = RegExp(r'^[a-z][a-zA-Z0-9_]{0,31}$');

String _checkedKeyName(String key) {
  if (!_keyNamePattern.hasMatch(key)) {
    throw FormatException('Invalid key name: $key');
  }
  return key;
}

List<T> _listOf<T>(
  Map<String, dynamic> json,
  String key,
  T Function(Map<String, dynamic>) parse,
) {
  final raw = json[key];
  if (raw is! List) {
    throw FormatException('$key must be a list');
  }
  return [
    for (final entry in raw)
      entry is Map<String, dynamic>
          ? parse(entry)
          : throw FormatException('$key entries must be objects'),
  ];
}

final _hiddenControls = RegExp(
  r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',
);

/// Optional collider label: clean string (the `cleanChat` rule), at most 64
/// UTF-8 bytes. Defaults to none.
String _name(Map<String, dynamic> json) {
  final name = json['name'];
  if (name == null) return '';
  if (name is! String ||
      name.isEmpty ||
      name.length > 64 ||
      _hiddenControls.hasMatch(name)) {
    throw const FormatException('name must be a clean string (<= 64 chars)');
  }
  return name;
}
