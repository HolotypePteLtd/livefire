import 'dart:async';
import 'dart:convert';
import 'package:protocol/protocol.dart';
import 'websocket.dart';
import 'playback_clock.dart';

class RoomSnapshot {
  RoomSnapshot(this.data) : received = Stopwatch()..start();
  final Map<String, dynamic> data;
  final Stopwatch received;
  Map<String, dynamic> get players => data['players'] as Map<String, dynamic>;
  double get time => (data['time'] as num).toDouble();
  int get epoch => data['epoch'] as int;
  int get tick => data['tick'] as int;
}

class TimelineSample<T extends RoomSnapshot> {
  const TimelineSample(this.before, this.after, this.alpha);
  final T before, after;
  final double alpha;
}

abstract class RoomClient<T extends RoomSnapshot> {
  RoomClient({
    required this.uri,
    required this.name,
    required this.protocolVersion,
    this.connector,
    this.wireCodec,
  });
  final Uri uri;
  final String name;
  final int protocolVersion;

  /// Optional binary state decoder; when set, binary frames arriving on the
  /// state/control stream are decoded through it. JSON text is unchanged.
  final WireStateCodec? wireCodec;
  Map<String, dynamic> get joinPayload => const {};
  void acceptWelcome(Map<String, dynamic> message) {}
  T decodeSnapshot(Map<String, dynamic> data);
  void sendControl(Map<String, dynamic> message) {
    if (connected) _socket?.send(jsonEncode(message));
  }

  late final social = RoomSocialClient(sendControl);

  final Future<GameConnection> Function()? connector;
  GameConnection? _socket;
  String? id, resumeToken, error;
  int sequence = 0;
  int capacity = 0;
  bool closed = false, connected = false, reconnecting = false;
  bool _connecting = false;
  void Function()? onChanged;
  final _snapshots = SnapshotDecoder();
  final List<T> _buffer = [];
  final _playbackClock = PlaybackClock();
  final _timelineWatch = Stopwatch()..start();
  double get _timelineNow => _timelineWatch.elapsedMicroseconds / 1e6;
  Timer? _retry;
  Completer<void>? _left;
  int _attempt = 0;
  T? get latest => _buffer.lastOrNull;

  /// Discrete events at the displayed timeline, never a future interpolation
  /// endpoint. Audio can lag a contact by at most one snapshot interval.
  T? _renderedSnapshot;
  T? get renderedSnapshot => _renderedSnapshot;
  Future<void> connect() async {
    if (connected || _connecting) return;
    _connecting = true;
    final welcome = Completer<void>();
    GameConnection? opening;
    var abandoned = false;
    try {
      final socket =
          await (connector?.call() ?? WebSocketGameConnection.connect(uri))
              .then((connection) async {
                // Future.timeout does not cancel a pending native handshake.
                if (abandoned || closed) {
                  await connection.close();
                  throw StateError('Connection cancelled');
                }
                return opening = connection;
              })
              .timeout(Duration(seconds: connector == null ? 8 : 90));
      if (closed) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.send(
        jsonEncode({
          'type': 'join',
          'protocol': protocolVersion,
          'name': name,
          ...joinPayload,
          'binaryStates': wireCodec != null,
          'resume': resumeToken,
        }),
      );
      socket.messages.listen(
        (raw) {
          if (_socket != socket) return;
          try {
            Map<String, dynamic> msg;
            if (raw is List<int>) {
              if (raw.length > 8000000) {
                throw const FormatException('Invalid server message');
              }
              final codec = wireCodec;
              if (codec == null) {
                throw const FormatException('Unexpected binary frame');
              }
              final frame = codec.decode(raw, _snapshots.baseline ?? {});
              if (frame == null) return;
              _acceptDecodedFrame(frame, socket, welcome);
              return;
            }
            if (raw is! String || raw.length > 8000000) {
              throw const FormatException('Invalid server message');
            }
            msg = jsonDecode(raw) as Map<String, dynamic>;
            if (msg['type'] == 'left') {
              if (_left?.isCompleted == false) _left!.complete();
              return;
            }
            if (closed) return;
            if (social.receive(msg)) {
              onChanged?.call();
              return;
            }
            switch (msg['type']) {
              case 'welcome':
                if (msg['protocol'] != protocolVersion) {
                  throw const FormatException('Incompatible server');
                }
                capacity = msg['capacity'] as int;
                if (capacity < 1) {
                  throw const FormatException('Invalid capacity');
                }
                id = msg['id'] as String;
                resumeToken = msg['resume'] as String;
                sequence = (msg['sequence'] as int?) ?? 0;
                acceptWelcome(msg);
                _buffer.clear();
                _playbackClock.reset();
                _snapshots.reset();
                _renderedSnapshot = null;
                error = null;
              case 'baseline':
                _snapshots.decode(msg);
                return;
              case 'snapshot':
              case 'state':
                // A local close can precede delivery of already queued states.
                // Do not acknowledge them or mark the closing transport ready.
                if (!socket.open) return;
                final decoded = _snapshots.decode(msg);
                if (decoded == null ||
                    !(decoded['players'] as Map).containsKey(id)) {
                  return;
                }
                final s = decodeSnapshot(decoded);
                if (latest == null ||
                    s.tick > latest!.tick ||
                    (s.tick == latest!.tick && msg['initial'] == true) ||
                    s.epoch != latest!.epoch) {
                  if (latest?.epoch != s.epoch) {
                    _buffer.clear();
                    _playbackClock.reset();
                    _renderedSnapshot = null;
                  }
                  _buffer.add(s);
                  _playbackClock.observe(
                    time: s.time,
                    receivedAt: _timelineNow,
                  );
                  if (_buffer.length > 8) _buffer.removeAt(0);
                }
                socket.send(jsonEncode({'type': 'ack', 'ack': s.tick}));
                // Welcome and the first snapshot can arrive in separate RTC
                // frames. Publish a ready state only once rendering is safe.
                connected = true;
                reconnecting = false;
                _attempt = 0;
                if (!welcome.isCompleted) welcome.complete();
              case 'removed':
                resumeToken = null;
                social.disconnect();
                connected = false;
                continue terminalError;
              terminalError:
              case 'error':
                error = msg['message'] as String;
                // A protocol/identity rejection needs an explicit fresh join.
                reconnecting = false;
                _retry?.cancel();
                if (!welcome.isCompleted) {
                  welcome.completeError(StateError(error!));
                }
            }
            onChanged?.call();
          } catch (e) {
            error = '$e';
            if (!welcome.isCompleted) welcome.completeError(e);
            unawaited(socket.close());
          }
        },
        onDone: () {
          if (_socket != socket) return;
          if (_left?.isCompleted == false) _left!.complete();
          connected = false;
          social.disconnect();
          if (!welcome.isCompleted) {
            welcome.completeError(StateError(error ?? 'Connection closed'));
          }
          if (error == null) _scheduleReconnect();
          onChanged?.call();
        },
        onError: (Object e) {
          if (!welcome.isCompleted) welcome.completeError(e);
          unawaited(socket.close());
          if (_socket == socket) {
            connected = false;
            social.disconnect();
            _scheduleReconnect();
            onChanged?.call();
          }
        },
        cancelOnError: true,
      );
      await welcome.future.timeout(const Duration(seconds: 15));
    } catch (e) {
      abandoned = true;
      if (_socket == opening) _socket = null;
      await opening?.close();
      connected = false;
      if (resumeToken != null && !closed && error == null) _scheduleReconnect();
      rethrow;
    } finally {
      _connecting = false;
    }
  }

  /// Applies a decoded binary state/baseline frame through the same buffer,
  /// ack and ready logic as JSON snapshots.
  void _acceptDecodedFrame(
    DecodedWireState decoded,
    GameConnection socket,
    Completer<void> welcome,
  ) {
    if (closed || !socket.open) return;
    final frame = decoded.snapshot;
    final prior = latest;
    if (prior != null && (frame['epoch'] as int) < prior.epoch) return;
    if (decoded.isBaseline) {
      final baseline = _snapshots.baseline;
      if (baseline != null &&
          (frame['epoch'] as int) == (baseline['epoch'] as int) &&
          (frame['tick'] as int) < (baseline['tick'] as int)) {
        return;
      }
      _snapshots.adoptBaseline(frame);
    }
    if (!(frame['players'] as Map).containsKey(id)) return;
    final s = decodeSnapshot(frame);
    if (latest == null || s.tick > latest!.tick || s.epoch != latest!.epoch) {
      if (latest?.epoch != s.epoch) {
        _buffer.clear();
        _playbackClock.reset();
        _renderedSnapshot = null;
      }
      _buffer.add(s);
      _playbackClock.observe(time: s.time, receivedAt: _timelineNow);
      if (_buffer.length > 8) _buffer.removeAt(0);
    }
    socket.send(jsonEncode({'type': 'ack', 'ack': s.tick}));
    connected = true;
    reconnecting = false;
    _attempt = 0;
    if (!welcome.isCompleted) welcome.complete();
    onChanged?.call();
  }

  void _scheduleReconnect() {
    if (closed || error != null || _retry?.isActive == true) return;
    reconnecting = true;
    _retry = Timer(
      Duration(milliseconds: 500 * (1 << _attempt.clamp(0, 3))),
      () {
        _attempt++;
        connect().catchError((Object _) {
          onChanged?.call();
        });
      },
    );
  }

  void sendInput(
    Map<String, dynamic> input, {
    List<String> actions = const [],
  }) {
    if (!connected || latest == null || _socket?.open != true) {
      return;
    }
    _socket!.send(
      jsonEncode({
        'type': 'input',
        'sequence': ++sequence,
        'epoch': latest!.epoch,
        'ack': latest!.tick,
        'input': input,
        'actions': actions,
      }),
    );
  }

  TimelineSample<T>? sampleTimeline({
    double delay = .075,
    double frameAgeSeconds = 0,
  }) {
    final last = latest;
    if (last == null) return null;
    final playbackTime = _playbackClock.sample(
      _timelineNow - frameAgeSeconds.clamp(0.0, .1),
    );
    // Zero delay is an explicit request for current authoritative state (for
    // example a just-confirmed shot sound), rather than interpolated playback.
    final time = delay <= 0 ? last.time : playbackTime - delay;
    var a = _buffer.first, b = last;
    for (final s in _buffer) {
      if (s.time <= time) a = s;
      if (s.time >= time) {
        b = s;
        break;
      }
    }
    final t = b.time <= a.time
        ? 1.0
        : ((time - a.time) / (b.time - a.time)).clamp(0.0, 1.0);
    _renderedSnapshot = a;
    return TimelineSample(a, b, t);
  }

  /// Used by native integration checks to exercise the real resume handshake.
  Future<void> interruptConnection() async {
    connected = false;
    await _socket?.close();
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    connected = false;
    social.disconnect();
    _retry?.cancel();
    if (_socket?.open == true) {
      final left = _left = Completer<void>();
      _socket!.send(jsonEncode({'type': 'leave'}));
      // Native SCTP send completion only means queued. Keep the channel alive
      // until the server acknowledges departure (or closes its side).
      try {
        await left.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // An unreachable server will release the disconnected slot on expiry.
      }
    }
    await _socket?.close();
  }
}
