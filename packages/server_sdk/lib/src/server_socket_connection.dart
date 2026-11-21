import 'dart:async';
import 'dart:io';
import 'package:protocol/protocol.dart';

/// Server-side WebSocket adapter for [RoomHub]. Adds server-specific socket
/// policy (ping keepalive, error suppression) on top of the transport-agnostic
/// peer protocol run by the hub. Binary state frames are sent as WebSocket
/// binary messages, exactly as the pre-hub implementation did.
final class ServerWebSocketConnection
    implements GameConnection, BinaryGameConnection {
  ServerWebSocketConnection(this._socket) {
    _socket.pingInterval = const Duration(seconds: 5);
    // Errors surface via done; never let them escape to the zone.
    _socket.done.catchError((Object _) {});
  }
  final WebSocket _socket;
  final _frames = StreamController<dynamic>();
  StreamSubscription<dynamic>? _incoming;

  @override
  Stream<dynamic> get messages => _frames.stream;
  @override
  bool get open => _socket.readyState == WebSocket.open;

  /// Starts forwarding socket frames into [messages]; separate from the
  /// constructor so [RoomHub.runTransport] subscribes before any frame can
  /// arrive.
  void start() {
    _incoming ??= _socket.listen(
      _frames.add,
      onError: (Object _) => _frames.addError(Object()),
      onDone: _frames.close,
    );
  }

  @override
  void send(String message) => _socket.add(message);

  @override
  void sendBytes(List<int> bytes) => _socket.add(bytes);

  @override
  Future<void> close([int? code, String? reason]) async {
    await _incoming?.cancel();
    _incoming = null;
    await _frames.close();
    try {
      await _socket.close(code, reason);
    } catch (_) {
      // Socket may already be dead; close() must still complete.
    }
  }
}
