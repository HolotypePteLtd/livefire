import 'dart:convert';

/// Per-key write quota for relay room state. Mirrors the relay template in
/// `docs/room_templates.md`; validation rules live there and are enforced
/// here at config-parse time.
class RelayKeyQuota {
  const RelayKeyQuota({
    required this.maxBytes,
    required this.publishesPerSecond,
  });

  factory RelayKeyQuota.fromJson(Map<String, dynamic> json) {
    _only(json, const {'maxBytes', 'publishesPerSecond'}, 'key quota');
    return RelayKeyQuota(
      maxBytes: _intIn(json, 'maxBytes', 1, 2048),
      publishesPerSecond: _intIn(json, 'publishesPerSecond', 1, 30),
    );
  }

  /// UTF-8 size cap for one encoded value.
  final int maxBytes;

  /// Accepted publishes per sliding one-second window, per publisher.
  final int publishesPerSecond;
}

/// Validated relay room configuration (`docs/room_templates.md`, version 1).
/// Configs are pinned at room creation; unknown fields are rejected so a
/// pinned config keeps validating identically forever (append-only rule).
class RelayRoomConfig {
  const RelayRoomConfig({
    required this.capacity,
    required this.maxRows,
    required this.totalBytes,
    required this.playerKeys,
    required this.roomKeys,
    this.chat = true,
  });

  factory RelayRoomConfig.fromJson(Map<String, dynamic> json) {
    _only(
      json,
      const {
        'version',
        'template',
        'capacity',
        'chat',
        'maxRows',
        'totalBytes',
        'playerKeys',
        'roomKeys',
      },
      'config',
    );
    if (json['version'] != 1) {
      throw const FormatException('Unsupported config version');
    }
    if (json['template'] != 'relay') {
      throw const FormatException('Unknown room template');
    }
    final chat = json['chat'] ?? true;
    if (chat is! bool) throw const FormatException('chat must be a bool');
    final playerKeys = _keys(json, 'playerKeys', min: 1);
    final roomKeys = _keys(json, 'roomKeys', min: 0);
    return RelayRoomConfig(
      capacity: _intIn(json, 'capacity', 1, 128),
      maxRows: _intIn(json, 'maxRows', 1, 1024),
      totalBytes: _intIn(json, 'totalBytes', 1, 262144),
      playerKeys: playerKeys,
      roomKeys: roomKeys,
      chat: chat,
    );
  }

  final int capacity;

  /// Chat/pings on, moderation always on. Enforcement of `chat == false`
  /// is deferred to the hub's optional-social work; the flag is carried and
  /// validated so pinned configs need no change when it lands.
  final bool chat;

  /// Total retained rows (non-empty player rows + room rows).
  final int maxRows;

  /// Sum of encoded row bytes across the whole room.
  final int totalBytes;

  /// Keys a player may write inside their own row.
  final Map<String, RelayKeyQuota> playerKeys;

  /// Keys only the room leader may write (`room{key → row}`).
  final Map<String, RelayKeyQuota> roomKeys;
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

final _keyNamePattern = RegExp(r'^[a-z][a-zA-Z0-9_]{0,31}$');

Map<String, RelayKeyQuota> _keys(
  Map<String, dynamic> json,
  String field, {
  required int min,
}) {
  final raw = json[field];
  if (raw is! Map<String, dynamic> ||
      raw.length < min ||
      raw.length > 16) {
    throw FormatException('$field must hold $min-16 keys');
  }
  return {
    for (final entry in raw.entries)
      _checkedKeyName(entry): RelayKeyQuota.fromJson(
        entry.value as Map<String, dynamic>,
      ),
  };
}

String _checkedKeyName(MapEntry<String, dynamic> entry) {
  if (!_keyNamePattern.hasMatch(entry.key)) {
    throw FormatException('Invalid key name: ${entry.key}');
  }
  return entry.key;
}

/// UTF-8 byte length of a value's JSON encoding.
int encodedBytes(Object? value) => utf8.encode(jsonEncode(value)).length;
