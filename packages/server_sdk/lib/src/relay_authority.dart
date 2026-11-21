import 'dart:collection';

import 'package:protocol/protocol.dart';
import 'join_tokens.dart';
import 'relay_config.dart';

/// Platform authority for relay rooms: client-authoritative state rows under
/// server-enforced quotas (`docs/room_templates.md` → relay template).
///
/// Room state is `players{id → row}` + `room{key → row}`. Players write only
/// their own row, and only its declared player keys; room keys are
/// leader-only. Invalid or over-quota publishes are dropped and counted —
/// never disconnected: the authoritative snapshot is the feedback loop, the
/// same posture as chat rate limits. Floods are handled one layer down by
/// the room's input lane (4 KB / 120 packets per second).
///
/// The leader is the **room creator**, claimed at join — the hub's
/// first-peer fallback never engages because this authority implements
/// [RoomSocialAuthority]. Chat, pings, roster, lock/kick/ban and history
/// come free from the room social layer.
class RelayAuthority implements RoomAuthority, RoomSocialAuthority {
  /// [creatorToken] proves the creating client at join. V0 passes the secret
  /// explicitly; the hosted control plane mints it alongside the room's
  /// one-time join token.
  ///
  /// SEAM(join-token): replace this string comparison with verification of a
  /// signed join-token claim (`{"creator": true}`) minted by the control
  /// plane; construction then takes a token verifier instead of a secret.
  RelayAuthority(
    this.config, {
    required this._creatorToken,
    this._creatorTokenVerifier,
  });

  final RelayRoomConfig config;
  final String _creatorToken;

  /// SEAM(join-token), atproto half: when wired (the node's factories pass
  /// the control-plane token verifier, bound to this room's key), creator
  /// claims are verified as signed node tokens (`ct_…` with `cr: true`,
  /// optionally carrying the creator's DID) instead of compared as opaque
  /// strings. An invalid signed claim simply claims nothing — it never
  /// disconnects the joiner.
  final TokenCheck Function(String token)? _creatorTokenVerifier;

  /// `players[id] = {playerKey → value}`; rows persist through disconnects
  /// inside the resume grace window and disappear on removal.
  final _rows = <String, Map<String, Object?>>{};

  /// `room{key → value}`, leader-written.
  final _room = <String, Object?>{};

  /// Sliding publish-rate windows, keyed `'<scope>\u0000<player>\u0000<key>'`,
  /// stamped with authority time (monotonic simulation seconds).
  final _rates = <String, Queue<double>>{};

  String? _creatorId;
  int _tick = 0;
  double _elapsed = 0;
  int _stateBytes = 0;

  /// Rejected publishes (quota, ownership or validation), for operators and
  /// tests. Rejections never close a connection.
  int rejectedWrites = 0;
  String? lastRejection;

  @override
  int get capacity => config.capacity;
  @override
  int get tick => _tick;
  @override
  double get elapsed => _elapsed;

  @override
  void update(double seconds) {
    _elapsed += seconds;
    _tick++;
  }

  @override
  Object? validateJoin(Map<String, dynamic> message) {
    // SEAM(join-token): the signed-claim path is live when a verifier is
    // wired; the opaque-string comparison remains for embedders that mint
    // their own secrets.
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
    if (claim == _creatorToken) return const {'creator': true};
    return null;
  }

  @override
  void addPlayer(String id, String name, Object? joinData) {
    // joinData is server-produced by validateJoin above; a client cannot
    // forge it in the join payload.
    final claimedCreator =
        joinData is Map && joinData['creator'] == true;
    if (claimedCreator && _creatorId == null) _creatorId = id;
    _rows[id] = {};
  }

  @override
  void resume(String id, Object? joinData) =>
      _rows.putIfAbsent(id, () => {});

  @override
  void disconnect(String id) {
    // The row survives disconnects inside the resume grace window.
  }

  @override
  void removePlayer(String id) {
    final row = _rows.remove(id);
    if (row != null) {
      for (final value in row.values) {
        _stateBytes -= encodedBytes(value);
      }
    }
    _rates.removeWhere((k, _) => k.contains('\u0000$id\u0000'));
    if (_creatorId == id) _creatorId = null;
  }

  @override
  Map<String, dynamic> welcome(String id) => {'sequence': 0};

  @override
  void command(String id, Map<String, dynamic> message) {
    switch (message['type']) {
      case 'publish':
        _publish(id, message, roomScope: false);
      case 'publishRoom':
        _publish(id, message, roomScope: true);
    }
  }

  void _publish(String id, Map<String, dynamic> message,
      {required bool roomScope}) {
    final key = message['key'];
    if (key is! String) return _reject('key must be a string');
    final quota =
        (roomScope ? config.roomKeys : config.playerKeys)[key];
    if (quota == null) {
      // Undeclared keys, and keys declared in the other scope, never land.
      return _reject('undeclared key: $key');
    }
    if (roomScope && id != _creatorId) return _reject('leader only');
    if (!message.containsKey('value')) return _reject('missing value');
    final value = message['value'];
    if (!_validValue(value)) return _reject('invalid value');
    final bytes = encodedBytes(value);
    if (bytes > quota.maxBytes) return _reject('row exceeds maxBytes');
    // The rate window is checked up front but stamped only when the write
    // commits: rejected writes never consume rate budget.
    final stamps = _rates.putIfAbsent(
      '${roomScope ? 'room' : 'player'}\u0000$id\u0000$key',
      Queue<double>.new,
    );
    while (stamps.isNotEmpty && stamps.first <= _elapsed - 1) {
      stamps.removeFirst();
    }
    if (stamps.length >= quota.publishesPerSecond) {
      return _reject('publish rate exceeded');
    }

    Object? previous;
    var createsRow = false;
    if (roomScope) {
      final existed = _room.containsKey(key);
      previous = _room[key];
      createsRow = !existed;
      if (createsRow && _rowCount() >= config.maxRows) {
        return _reject('room exceeds maxRows');
      }
      if (_stateBytes - encodedBytes(previous) + bytes > config.totalBytes) {
        return _reject('room exceeds totalBytes');
      }
      _room[key] = value;
    } else {
      final row = _rows.putIfAbsent(id, () => {});
      previous = row[key];
      createsRow = row.isEmpty;
      if (createsRow && _rowCount() >= config.maxRows) {
        return _reject('room exceeds maxRows');
      }
      if (_stateBytes - encodedBytes(previous) + bytes > config.totalBytes) {
        return _reject('room exceeds totalBytes');
      }
      row[key] = value;
    }
    stamps.addLast(_elapsed);
    _stateBytes += bytes - encodedBytes(previous);
  }

  int _rowCount() =>
      _rows.values.where((row) => row.isNotEmpty).length + _room.length;

  void _reject(String reason) {
    rejectedWrites++;
    lastRejection = reason;
  }

  /// Deep JSON validation in the chat-hardening posture: finite numbers,
  /// no control characters or bidi overrides in strings (or map keys).
  bool _validValue(Object? value) {
    if (value == null || value is bool) return true;
    if (value is num) return value.isFinite;
    if (value is String) return _cleanString(value);
    if (value is Map) {
      return value.entries.every(
        (e) => e.key is String && _cleanString(e.key as String) && _validValue(e.value),
      );
    }
    if (value is List) return value.every(_validValue);
    return false; // Not representable in JSON.
  }

  static final _hiddenControls = RegExp(
    r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]',
  );

  bool _cleanString(String text) => !_hiddenControls.hasMatch(text);

  /// Relay rooms publish; the authority itself simulates nothing. Hosts
  /// should pick low tick rates (e.g. 20 Hz sim / 10 Hz snapshots) for
  /// density — see `docs/room_templates.md`.
  @override
  Map<String, dynamic> snapshot() => {
    'type': 'snapshot',
    'epoch': 0,
    'tick': _tick,
    'time': _elapsed,
    'players': {for (final e in _rows.entries) e.key: Map.of(e.value)},
    'room': Map.of(_room),
  };

  @override
  String? get roomLeaderId => _creatorId;

  /// Pings need authority-side coordinates: answer from the player's
  /// published row when any player key holds finite `x`/`y`/`z` numbers.
  @override
  PingLocation? pingLocation(String playerId, String kind) {
    for (final value in _rows[playerId]?.values ?? const <Object?>[]) {
      if (value is Map && value['x'] is num && value['y'] is num && value['z'] is num) {
        final x = (value['x'] as num).toDouble(),
            y = (value['y'] as num).toDouble(),
            z = (value['z'] as num).toDouble();
        if (x.isFinite && y.isFinite && z.isFinite) {
          return PingLocation(x, y, z, 0);
        }
      }
    }
    return null;
  }

  @override
  void dispose() {}
}
