import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'room_social.dart';
import 'connection.dart';
import 'room_authority.dart';
import 'snapshot_codec.dart';
import 'step_clock.dart';
import 'wire_codec.dart';

String _token() => base64Url
    .encode(List.generate(24, (_) => Random.secure().nextInt(256)))
    .replaceAll('=', '');

/// A connected peer as seen by the hub. The transport is one of:
/// a server-side WebSocket adapter, a WebRTC data-channel pair or an
/// in-memory pipe; the hub treats them identically through [GameConnection]
/// capability interfaces.
class HubPeer {
  HubPeer._(this.id, this.token, this.name, this.identity);
  final String id, token, name;

  /// Verified by an authenticated transport adapter, never a join payload.
  final String? identity;
  GameConnection? transport;
  bool binaryStates = false;
  double? disconnectedAt;
  double lastAckAt = 0;
  int recoveryTick = -120;
  int sentTick = -1, ackTick = -1, baselineTick = -1;
  int packets = 0, window = 0;
  int bufferedAllowance = 0, bufferedUntil = 0;
}

/// Transport-independent room engine: fixed-step simulation, the peer session
/// protocol (join/resume/leave, acks, rate limits, resume grace), snapshot
/// baselining and delta broadcast with loss recovery. Everything transport
/// specific — sockets, HTTP upgrades, ports — lives in adapters such as
/// [RoomServer] (dedicated process, WebSocket listener) or a player-hosted
/// app that attaches WebRTC/in-process transports directly.
class RoomHub {
  RoomHub(
    this.authority, {
    required this.protocolVersion,
    this.simulationHz = 120,
    int snapshotHz = 20,
    String? roomKey,
    this.resumeGrace = const Duration(seconds: 15),
    this.wireCodec,
    this.profileOf,
  }) : roomKey = roomKey ?? _token(),
       _clock = FixedStepClock(step: 1 / simulationHz),
       _snapshotTicks = (simulationHz / snapshotHz).round(),
       _snapshots = SnapshotEncoder(baselineIntervalTicks: simulationHz) {
    if (authority.capacity < 1 ||
        simulationHz < 1 ||
        snapshotHz < 1 ||
        snapshotHz > simulationHz) {
      throw ArgumentError('Invalid room capacity or tick rates');
    }
  }
  final RoomAuthority authority;
  final int protocolVersion, simulationHz, _snapshotTicks;
  final String roomKey;
  final Duration resumeGrace;

  /// Optional binary state codec (e.g. FlatBuffers). When set and the peer
  /// transport supports binary, state snapshots are encoded through it;
  /// JSON text remains the fallback for text-only transports.
  final WireStateCodec? wireCodec;

  /// Optional host-side profile lookup attached to roster members (peer id
  /// in, profile map out). Hosts use it to surface identity profiles (e.g.
  /// AT Protocol displayName/avatar keyed by DID) on the social roster path
  /// clients already consume. Synchronous by design: return a cached
  /// profile or null, then call [refreshRoster] when an async fetch lands.
  final Map<String, dynamic>? Function(String peerId)? profileOf;
  final Map<String, HubPeer> _peers = {};
  final Set<GameConnection> _transports = {};
  Timer? _timer;
  final FixedStepClock _clock;
  final SnapshotEncoder _snapshots;
  final _watch = Stopwatch();
  int _nextId = 1, _lastSnapshot = -1;
  bool _closed = false;
  final _social = RoomSocialHost();
  final _bannedIdentities = <String>{};
  bool _locked = false;
  String? get _leaderId => authority is RoomSocialAuthority
      ? (authority as RoomSocialAuthority).roomLeaderId
      : _peers.values.firstOrNull?.id;

  int get peerCount => _peers.length;
  int get connectedPeerCount =>
      _peers.values.where((p) => p.transport != null).length;
  bool get isClosed => _closed;
  int get tick => authority.tick;

  /// Begins periodic simulation. Adapters call this after their transport
  /// listener is ready; in-process hosts may instead drive [pumpSeconds].
  void start() {
    if (_timer != null || _closed) return;
    _watch.start();
    // Joining and paused transports keep the rate-limit clock alive. Starting
    // simulation must not catch up time spent waiting for assets or menus.
    _watchStartMicros = _watch.elapsedMicroseconds;
    _clock.discardLag();
    _timer = Timer.periodic(
      Duration(microseconds: (1000000 / simulationHz).round()),
      (_) => _tickFromWallClock(),
    );
  }

  /// Stops periodic simulation without closing peers.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _tickFromWallClock() {
    final now = _watch.elapsedMicroseconds;
    final last = _watchStartMicros;
    _watchStartMicros = now;
    pumpSeconds((now - last) / 1e6);
  }

  int _watchStartMicros = 0;

  /// Advances the simulation deterministically by [seconds] (tests and
  /// externally driven hosts). Performs the same reaping, recovery and
  /// snapshot cadence work as the periodic timer.
  void pumpSeconds(double seconds) {
    if (_closed) return;
    final started = _watch.elapsedMicroseconds;
    try {
      _clock.advance(seconds, authority.update);
      _reap();
      if (authority.tick - _lastSnapshot >= _snapshotTicks) {
        broadcast();
        _lastSnapshot = authority.tick;
      }
    } finally {
      _allowBufferedControls(started);
    }
  }

  void _reap() {
    for (final peer in _peers.values.toList()) {
      if (peer.disconnectedAt != null &&
          authority.elapsed - peer.disconnectedAt! >
              resumeGrace.inMilliseconds / 1000) {
        authority.removePlayer(peer.id);
        _peers.remove(peer.token);
        _social.removePlayer(peer.id);
        _socialBroadcast(_social.system(peer.id, peer.name, 'left the room'));
        _broadcastRoster();
      }
    }
  }

  /// Accepts a connected transport and runs the full session protocol on it:
  /// join/resume handshake with timeout, validation, rate limits, commands,
  /// and detach-on-loss. Completes with the peer once the handshake succeeds
  /// (the subscription remains live), or with null if the transport closed
  /// before joining. This is the single acceptance path for every transport
  /// kind — WebSocket adapters and direct in-process attaches alike.
  /// [onDisconnected] runs when this transport ends, independently of the
  /// handshake future, so adapters can retain and release their peer resources.
  Future<HubPeer?> runTransport(
    GameConnection transport, {
    Duration joinTimeout = const Duration(seconds: 5),
    void Function()? onDisconnected,
    String? identity,
  }) {
    if (_closed) {
      unawaited(transport.close(1001, 'Host closed the room'));
      return Future.value();
    }
    _watch.start();
    _transports.add(transport);
    HubPeer? peer;
    StreamSubscription<dynamic>? subscription;
    final joined = Completer<HubPeer?>();
    final timeout = Timer(joinTimeout, () {
      if (peer == null && !joined.isCompleted) {
        joined.complete(null);
        unawaited(transport.close(1008, 'Join timeout'));
      }
    });
    var detached = false;
    void detach() {
      if (detached) return;
      detached = true;
      _transports.remove(transport);
      timeout.cancel();
      if (peer != null) _detach(peer!, transport);
      if (!joined.isCompleted) joined.complete(null);
      unawaited(subscription?.cancel());
      onDisconnected?.call();
    }

    subscription = transport.messages.listen(
      (raw) {
        if (_closed) return;
        final started = _watch.elapsedMicroseconds;
        try {
          if (raw is! String || raw.length > 4096) {
            throw const FormatException('Message too large');
          }
          final msg = jsonDecode(raw) as Map<String, dynamic>;
          if (peer == null) {
            final existing = _handshake(transport, msg, identity);
            if (existing != null) {
              peer = existing;
              if (!joined.isCompleted) joined.complete(existing);
            } else {
              // Handshake failures close the transport; nothing more to do.
              if (!joined.isCompleted) joined.complete(null);
            }
            return;
          }
          // Replaced transports cannot issue commands, even before their
          // close completes.
          if (!identical(peer!.transport, transport)) return;
          _control(peer!, msg);
        } catch (e) {
          _protocolError(transport, e);
        } finally {
          _allowBufferedControls(started);
        }
      },
      onDone: detach,
      onError: (Object _) => detach(),
      cancelOnError: true,
    );
    return joined.future;
  }

  /// Handles a join or resume frame on a fresh transport. Returns the peer on
  /// success; on failure the transport has been sent an error and closed.
  HubPeer? _handshake(
    GameConnection transport,
    Map<String, dynamic> msg,
    String? identity,
  ) {
    if (msg['type'] != 'join' || msg['protocol'] != protocolVersion) {
      throw const FormatException('Incompatible game version');
    }
    final resume = msg['resume'];
    if (identity != null && _bannedIdentities.contains(identity)) {
      throw const FormatException('You are banned from this room');
    }
    final joinData = authority.validateJoin(msg);
    HubPeer peer;
    if (resume != null) {
      final existing = _peers[resume];
      if (existing == null) {
        throw const FormatException('Session expired; join again');
      }
      if (existing.identity != identity) {
        throw const FormatException('Session identity changed; join again');
      }
      peer = existing;
      peer.transport?.close(1000, 'Reconnected elsewhere');
    } else {
      if (_locked) throw const FormatException('The host has locked this room');
      final name = msg['name'];
      if (name is! String ||
          name.trim().isEmpty ||
          name.length > 24 ||
          name.contains(
            RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]'),
          )) {
        throw const FormatException('Use a name of 1–24 characters');
      }
      if (_peers.length >= authority.capacity) {
        throw StateError('Room is full');
      }
      final id = 'p${_nextId++}';
      authority.addPlayer(id, name.trim(), joinData);
      peer = HubPeer._(id, _token(), name.trim(), identity);
      _peers[peer.token] = peer;
    }
    peer.transport = transport;
    peer.binaryStates = msg['binaryStates'] == true;
    peer.disconnectedAt = null;
    peer.ackTick = peer.sentTick = -1;
    peer.lastAckAt = authority.elapsed;
    authority.resume(peer.id, joinData);
    transport.send(
      jsonEncode({
        ...authority.welcome(peer.id),
        'type': 'welcome',
        'protocol': protocolVersion,
        'id': peer.id,
        'resume': peer.token,
        'capacity': authority.capacity,
      }),
    );
    final initialSnap = _snapshots.prepare(authority.snapshot());
    transport.send(jsonEncode({..._snapshots.baseMap!, 'type': 'baseline'}));
    transport.send(jsonEncode({...initialSnap, 'initial': true}));
    peer.baselineTick = _snapshots.baselineTick;
    peer.sentTick = authority.tick;
    transport.send(jsonEncode(_roster(includeHistory: true)));
    _socialBroadcast(
      _social.system(
        peer.id,
        peer.name,
        resume == null ? 'joined the room' : 'reconnected',
      ),
    );
    _broadcastRoster();
    return peer;
  }

  void _control(HubPeer peer, Map<String, dynamic> msg) {
    final now = _watch.elapsedMilliseconds;
    final window = now ~/ 1000;
    if (peer.window != window) {
      peer.window = window;
      peer.packets = 0;
    }
    if (++peer.packets > 120) {
      if (now <= peer.bufferedUntil && peer.bufferedAllowance > 0) {
        peer.bufferedAllowance--;
      } else {
        throw const FormatException('Input rate exceeded');
      }
    }
    final ack = msg['ack'];
    if (ack is int && ack >= peer.ackTick && ack <= peer.sentTick) {
      if (ack > peer.ackTick) peer.lastAckAt = authority.elapsed;
      peer.ackTick = ack;
    }
    if (msg['type'] == 'ack') return;
    if (_socialControl(peer, msg)) return;
    if (msg['type'] == 'leave') {
      authority.removePlayer(peer.id);
      _peers.remove(peer.token);
      _social.removePlayer(peer.id);
      // Invalidate the transport before close completes so its detach cannot
      // disconnect a replacement player or duplicate the leave notice.
      final transport = peer.transport;
      peer.transport = null;
      _socialBroadcast(_social.system(peer.id, peer.name, 'left the room'));
      _broadcastRoster();
      transport?.send(jsonEncode({'type': 'left'}));
      unawaited(transport?.close());
      return;
    }
    authority.command(peer.id, msg);
  }

  Map<String, dynamic> _roster({bool includeHistory = false}) => {
    'type': 'social',
    'leaderId': _leaderId,
    'locked': _locked,
    'members': [
      for (final peer in _peers.values)
        RoomMember(
          peer.id,
          peer.name,
          connected: peer.transport != null,
          canBan: peer.identity != null,
          profile: profileOf?.call(peer.id),
        ).toJson(),
    ],
    if (includeHistory) 'history': _social.history,
  };

  /// Re-broadcasts the roster (e.g. after a host-side profile fetch lands).
  /// No-op when closed or nobody is connected.
  void refreshRoster() {
    if (_closed) return;
    _broadcastRoster();
  }

  void _socialBroadcast(Map<String, dynamic> message) {
    final text = jsonEncode(message);
    for (final peer in _peers.values.toList()) {
      if (peer.transport?.open == true) peer.transport!.send(text);
    }
  }

  void _broadcastRoster() => _socialBroadcast(_roster());

  bool _socialControl(HubPeer peer, Map<String, dynamic> message) {
    final type = message['type'];
    if (type != 'chat' && type != 'ping' && type != 'moderate') return false;
    try {
      if (type == 'chat') {
        _socialBroadcast(
          _social.chat(peer.id, peer.name, message['text'], _watch.elapsed),
        );
      } else if (type == 'ping') {
        final kind = message['kind'];
        final socialAuthority = authority;
        if (kind is! String ||
            !pingKinds.contains(kind) ||
            socialAuthority is! RoomSocialAuthority) {
          throw const FormatException('Ping unavailable');
        }
        final location = (socialAuthority as RoomSocialAuthority).pingLocation(
          peer.id,
          kind,
        );
        if (location == null) throw const FormatException('Ping unavailable');
        _socialBroadcast(
          _social.ping(peer.id, peer.name, kind, location, _watch.elapsed),
        );
      } else {
        if (peer.id != _leaderId) {
          throw const FormatException('Only the host can manage the room');
        }
        if (message['action'] == 'lock' && message['locked'] is bool) {
          _locked = message['locked'] as bool;
          _broadcastRoster();
        } else if (message['action'] == 'kick' || message['action'] == 'ban') {
          final target = _peers.values
              .where((p) => p.id == message['playerId'])
              .firstOrNull;
          if (target == null || target.id == peer.id) {
            throw const FormatException('Choose another player');
          }
          if (message['action'] == 'ban') {
            if (target.identity == null) {
              throw const FormatException(
                'Only authenticated players can be banned',
              );
            }
            // Bound room-lifetime bans, including disconnected identities.
            if (_bannedIdentities.length >= 256) {
              throw const FormatException('Ban list is full');
            }
            _bannedIdentities.add(target.identity!);
          }
          _peers.remove(target.token);
          authority.removePlayer(target.id);
          _social.removePlayer(target.id);
          final transport = target.transport;
          target.transport = null;
          transport?.send(
            jsonEncode({
              'type': 'removed',
              'message': message['action'] == 'ban'
                  ? 'The host banned you from this room'
                  : 'The host removed you from this room',
            }),
          );
          unawaited(transport?.close(1008, 'Removed by host'));
          _socialBroadcast(
            _social.system(target.id, target.name, 'was removed by the host'),
          );
          _broadcastRoster();
        } else {
          throw const FormatException('Unknown room control');
        }
      }
    } on FormatException catch (e) {
      peer.transport?.send(
        jsonEncode({'type': 'socialNotice', 'message': e.message}),
      );
    }
    return true;
  }

  void _allowBufferedControls(int started) {
    final now = _watch.elapsedMicroseconds;
    final blocked = now - started;
    if (blocked < 250000) return;
    // Course/physics creation can block the authority while peers keep sending
    // normal traffic. Drain that queued burst without making the steady-state
    // rate limit depend on client-provided timestamps. Credit lasts one second
    // and is capped even after an arbitrarily long host stall.
    final allowance = (blocked * 120 / 1e6).ceil().clamp(0, 600);
    final millis = now ~/ 1000;
    for (final peer in _peers.values) {
      if (peer.transport == null) continue;
      final remaining = millis <= peer.bufferedUntil
          ? peer.bufferedAllowance
          : 0;
      peer.bufferedAllowance = (remaining + allowance).clamp(0, 600);
      peer.bufferedUntil = millis + 1000;
    }
  }

  /// Marks a peer's transport as lost and starts the resume-grace window.
  void _detach(HubPeer peer, GameConnection transport) {
    if (!identical(peer.transport, transport)) return;
    peer.transport = null;
    peer.disconnectedAt = authority.elapsed;
    authority.disconnect(peer.id);
    _broadcastRoster();
  }

  void _protocolError(GameConnection transport, Object e) {
    transport.send(
      jsonEncode({
        'type': 'error',
        'message': e is StateError
            ? e.message
            : e is FormatException
            ? e.message
            : 'Malformed message',
      }),
    );
    unawaited(transport.close(1008, 'Invalid request'));
  }

  /// Encodes and sends one state frame (JSON text or binary bytes) on the
  /// correct lane: disposable deltas prefer the unreliable state lane when
  /// the transport provides one; reliable frames (welcome, baselines,
  /// recovery snapshots) use the control lane.
  void _sendStateFrame(HubPeer peer, Object frame, {bool reliable = false}) {
    final transport = peer.transport;
    if (transport == null) return;
    if (frame is List<int>) {
      // State-lane interfaces are not GameConnection subtypes, so these
      // checks cannot use type promotion; test then cast, like _PeerBridge.
      final stateLane = transport is BinaryStateGameConnection
          ? transport as BinaryStateGameConnection
          : null;
      if (stateLane != null && !reliable) {
        stateLane.sendStateBytes(frame);
      } else if (transport is BinaryGameConnection) {
        transport.sendBytes(frame);
      } else {
        // Binary codec must not be enabled for text-only transports.
        throw StateError('Binary codec with text-only transport');
      }
      return;
    }
    final text = frame as String;
    final jsonDeltaLane = transport is StateGameConnection
        ? transport as StateGameConnection
        : null;
    if (text.startsWith('{"type":"state",') && jsonDeltaLane != null) {
      jsonDeltaLane.sendState(text);
    } else {
      transport.send(text);
    }
  }

  void broadcast() {
    if (_closed) return;
    String? data;
    String? recovery;
    List<int>? binaryDelta;
    List<int>? binaryBaseline;
    Map<String, dynamic>? quantized;
    for (final peer in _peers.values) {
      final transport = peer.transport;
      if (transport == null || !transport.open) continue;
      final blocked = peer.sentTick - peer.ackTick >= simulationHz / 2;
      if (blocked) {
        if (authority.elapsed - peer.lastAckAt > 5) {
          unawaited(transport.close(1001, 'State receiver stalled'));
          continue;
        }
        if (authority.tick - peer.recoveryTick < simulationHz) continue;
        peer.recoveryTick = authority.tick;
      }
      quantized ??= _snapshots.prepare(authority.snapshot());
      // Binary codecs diff the quantized snapshot against the encoder's own
      // baseline map, exactly matching what JSON deltas reference.
      final wantsBinary =
          peer.binaryStates &&
          wireCodec != null &&
          transport is BinaryGameConnection &&
          wireCodec!.supports(transport);
      // Baseline first (reliable even if every disposable state was lost).
      if (blocked || peer.baselineTick != _snapshots.baselineTick) {
        if (wantsBinary) {
          final baseMap = _snapshots.baseMap;
          binaryBaseline ??= wireCodec!.encodeState(baseMap!);
          _sendStateFrame(peer, binaryBaseline, reliable: true);
        } else {
          _sendStateFrame(peer, _snapshots.baseline!);
        }
        peer.baselineTick = _snapshots.baselineTick;
      }
      if (blocked && !_snapshots.isBaseline(quantized)) {
        // Display a fresh frame without changing the room's delta baseline.
        // Recovery is a display-only snapshot, never a replacement baseline.
        recovery ??= jsonEncode({...quantized, 'initial': true});
        _sendStateFrame(peer, recovery, reliable: true);
      } else if (!_snapshots.isBaseline(quantized)) {
        if (wantsBinary) {
          binaryDelta ??= wireCodec!.encodeDelta(
            _snapshots.baseMap!,
            quantized,
          );
          _sendStateFrame(peer, binaryDelta);
        } else {
          data ??= _snapshots.encodePrepared(quantized);
          _sendStateFrame(peer, data);
        }
      }
      peer.sentTick = authority.tick;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    stop();
    await Future.wait(
      _transports.toList().map(
        (transport) => transport.close(1001, 'Host closed the room'),
      ),
    );
    _transports.clear();
    _peers.clear();
    authority.dispose();
  }
}
