import 'dart:async';
import 'dart:math';

import 'package:protocol/protocol.dart';

import 'authority_factory.dart';

/// Supervisor failures carry the control-plane error code they map to
/// (`docs/control_plane_api.md` → error shape).
class RoomException implements Exception {
  const RoomException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => 'RoomException($code): $message';
}

/// A live room registration: the built hub plus lifecycle bookkeeping.
class SupervisorRoom {
  SupervisorRoom({
    required this.key,
    required this.template,
    required this.built,
    required this.createdAtSeconds,
  });

  /// The unguessable room key from the room URL.
  final String key;

  /// Template name (`relay`, `physics`).
  final String template;

  /// The hub, its authority and the pinned config.
  final BuiltRoom built;

  /// Supervisor virtual clock seconds at creation.
  final double createdAtSeconds;

  /// Simulation is being pumped (false while idle-reaped).
  bool running = true;

  /// Virtual clock seconds when the room last had zero connected peers;
  /// null while peers are connected.
  double? idleSinceSeconds;

  RoomHub get hub => built.hub;
  int get peerCount => hub.peerCount;
  int get connectedPeerCount => hub.connectedPeerCount;
  int get capacity => built.capacity;
  bool get reaped => !running;
}

/// Per-room metrics snapshot for operators and the control plane.
class RoomMetrics {
  const RoomMetrics({
    required this.key,
    required this.template,
    required this.peers,
    required this.capacity,
    required this.tick,
    required this.reaped,
  });

  final String key;
  final String template;
  final int peers;
  final int capacity;
  final int tick;
  final bool reaped;
}

/// Multi-room registry and pump behind a rooms node.
///
/// One supervisor owns every live room in the process:
///
/// - **Registry** — [createRoom] validates the config through a registered
///   [AuthorityFactory] (per template; physics engines are injected there),
///   [room] routes by room key, [destroy] drains with close code `1001`.
/// - **Master ticker** — a single [Timer.periodic] drives every running room
///   through the hub's `pumpSeconds` seam; no per-room timers. Rooms may run
///   at different simulation rates: each hub's fixed-step clock advances by
///   the wall delta it is handed. [pumpSeconds] drives the same path
///   deterministically for tests and in-process hosts.
/// - **Idle reap** — a room with zero connected peers for [idleTtl] stops
///   ticking but stays **registered with its state in memory** (v0: no
///   persistence); the next join restarts it exactly where it was. Note the
///   TTL effectively starts when the hub's resume grace window releases the
///   last disconnected peer.
/// - **Capacity accounting** — [maxRooms] live rooms and
///   [maxReservedCapacity] summed room capacity; creation over the limits
///   are shed (`quota_exceeded`) rather than risking the node.
class RoomSupervisor {
  RoomSupervisor({
    required Iterable<AuthorityFactory> factories,
    this.maxRooms = 256,
    this.maxReservedCapacity = 4096,
    this.idleTtl = const Duration(minutes: 5),
  }) : factories = {for (final f in factories) f.template: f};

  /// Template name → factory. A template without a registered factory is
  /// `unsupported_template` at creation.
  final Map<String, AuthorityFactory> factories;

  /// Live-room ceiling (reaped rooms count; drained rooms do not).
  final int maxRooms;

  /// Sum-of-room-capacity ceiling across live rooms.
  final int maxReservedCapacity;

  /// Zero-peers TTL before a room stops ticking (stays registered).
  final Duration idleTtl;

  final _rooms = <String, SupervisorRoom>{};
  final _watch = Stopwatch()..start();
  Timer? _ticker;
  double _lastPumpSeconds = 0;
  double _clock = 0;
  double _sinceReapCheck = 0;

  /// Live (non-drained) rooms.
  Iterable<SupervisorRoom> get rooms =>
      _rooms.values.where((room) => !room.hub.isClosed);

  /// Total connected peers across rooms.
  int get totalPeers =>
      _rooms.values.fold(0, (sum, room) => sum + room.peerCount);

  /// Reserved capacity across live rooms.
  int get reservedCapacity =>
      rooms.fold(0, (sum, room) => sum + room.capacity);

  /// Per-room metrics.
  List<RoomMetrics> metrics() => [
        for (final room in rooms)
          RoomMetrics(
            key: room.key,
            template: room.template,
            peers: room.peerCount,
            capacity: room.capacity,
            tick: room.hub.tick,
            reaped: room.reaped,
          ),
      ];

  /// The virtual clock in seconds (wall-driven by the ticker, advanced by
  /// [pumpSeconds] in tests).
  double get clockSeconds => _clock;

  SupervisorRoom? room(String roomKey) {
    final room = _rooms[roomKey];
    if (room == null || room.hub.isClosed) return null;
    return room;
  }

  /// Validates the config through the template's factory, enforces the node
  /// limits, and registers the room (idle from creation — nobody has joined
  /// yet). Throws [FormatException] for an invalid config and
  /// [RoomException] for `unsupported_template` / `quota_exceeded`.
  SupervisorRoom createRoom({
    required String template,
    required Map<String, dynamic> config,
    required String creatorToken,
    String? roomKey,
  }) {
    final factory = factories[template];
    if (factory == null) {
      throw RoomException(
        'unsupported_template',
        'no factory registered for template "$template"',
      );
    }
    if (rooms.length >= maxRooms ||
        reservedCapacity >= maxReservedCapacity) {
      throw const RoomException(
        'quota_exceeded',
        'node room limits reached',
      );
    }
    final key = roomKey ?? _token(24);
    // The factory validates before the hub is registered; a failed build
    // leaves nothing behind.
    final built = factory.build(
      config,
      creatorToken: creatorToken,
      roomKey: key,
    );
    final capacity = built.capacity;
    if (reservedCapacity + capacity > maxReservedCapacity) {
      unawaited(built.hub.close());
      throw const RoomException(
        'quota_exceeded',
        'node capacity limits reached',
      );
    }
    final room = SupervisorRoom(
      key: key,
      template: template,
      built: built,
      createdAtSeconds: _clock,
    );
    if (_rooms.containsKey(room.key)) {
      unawaited(built.hub.close());
      throw const RoomException('invalid_request', 'room key already in use');
    }
    room.idleSinceSeconds = _clock; // created empty: idle until first join
    _rooms[room.key] = room;
    return room;
  }

  /// Routes a connection into its room: the single join path for every
  /// transport kind. Restarts an idle-reaped room (state was kept in
  /// memory). Throws [RoomException] for unknown or drained rooms.
  Future<HubPeer?> attach(
    String roomKey,
    GameConnection connection, {
    String? identity,
  }) {
    final room = this.room(roomKey);
    if (room == null) {
      throw RoomException('not_found', 'no room $roomKey');
    }
    final wasReaped = room.reaped;
    return room.hub.runTransport(
      connection,
      identity: identity,
      onDisconnected: () => _peerLeft(room),
    ).then((peer) {
      if (peer != null) {
        room.running = true; // restart-on-join for reaped rooms
        room.idleSinceSeconds = null;
      } else if (room.peerCount == 0 && wasReaped) {
        // Handshake failed on a room nobody else holds: back to idle.
        room.running = false;
      }
      return peer;
    });
  }

  void _peerLeft(SupervisorRoom room) {
    if (room.peerCount == 0 && !room.hub.isClosed) {
      room.idleSinceSeconds = _clock;
    }
  }

  /// Drains a room: peers receive close code `1001` and may not resume; the
  /// registration is removed. Idempotent — draining an unknown or already
  /// drained room is a no-op.
  Future<void> destroy(String roomKey) async {
    final room = _rooms.remove(roomKey);
    if (room == null) return;
    room.running = false;
    await room.hub.close();
  }

  /// Drains every room and stops the ticker (node shutdown).
  Future<void> close() async {
    stopTicker();
    final draining = [for (final room in _rooms.values) room.key];
    for (final key in draining) {
      await destroy(key);
    }
  }

  /// Starts the single master ticker at [hz], pumping every running room by
  /// wall-clock delta and reaping idle rooms about once a second.
  void startTicker({double hz = 60}) {
    if (_ticker != null) return;
    _lastPumpSeconds = _watch.elapsedMicroseconds / 1e6;
    _ticker = Timer.periodic(
      Duration(microseconds: (1000000 / hz).round()),
      (_) {
        final now = _watch.elapsedMicroseconds / 1e6;
        pumpSeconds(now - _lastPumpSeconds);
        _lastPumpSeconds = now;
      },
    );
  }

  void stopTicker() {
    _ticker?.cancel();
    _ticker = null;
    // Do not simulate the paused window on the next ticker start.
    _lastPumpSeconds = _watch.elapsedMicroseconds / 1e6;
  }

  /// Advances every running room by [seconds] on the supervisor clock, then
  /// reaps idle rooms at most once per second of advanced time. The master
  /// ticker calls this with wall deltas; tests pass exact steps.
  ///
  /// Large deltas arrive in ≤ 50 ms slices because each hub bounds catch-up
  /// per advance (its fixed-step clock clamps at 100 ms): slicing keeps
  /// supervisor time equal to simulated time instead of silently dropping
  /// everything past the first 100 ms.
  void pumpSeconds(double seconds) {
    if (!seconds.isFinite || seconds <= 0) return;
    _clock += seconds;
    var remaining = seconds;
    while (remaining > 0) {
      final slice = remaining > 0.05 ? 0.05 : remaining;
      for (final room in rooms.toList()) {
        if (room.running) room.hub.pumpSeconds(slice);
      }
      remaining -= slice;
    }
    _sinceReapCheck += seconds;
    if (_sinceReapCheck < 1) return;
    _sinceReapCheck = 0;
    final ttl = idleTtl.inMilliseconds / 1000;
    for (final room in rooms) {
      final idleAt = room.idleSinceSeconds;
      if (room.running &&
          room.peerCount == 0 &&
          idleAt != null &&
          _clock - idleAt >= ttl) {
        room.hub.stop();
        room.running = false;
      }
    }
  }

  static String _token(int length) {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
    // Room keys appear in URLs and must be unguessable.
    final random = Random.secure();
    return String.fromCharCodes([
      for (var i = 0; i < length; i++)
        alphabet.codeUnitAt(random.nextInt(alphabet.length)),
    ]);
  }
}
