import 'dart:async';
import 'connection.dart';

/// An in-memory transport pair for in-process hosting and tests: what one
/// side sends, the other receives. Frames may be JSON strings (control
/// lane) or List-of-int (binary state frames), mirroring what a WebSocket or
/// WebRTC data channel would deliver.
///
/// This exists so a hosting player in the same process as the authority can
/// join its own room without any socket, and so room-protocol tests run
/// without binding ports.
final class MemoryTransportPair {
  MemoryTransportPair._(this.a, this.b);
  factory MemoryTransportPair() {
    final a = MemoryTransport._(), b = MemoryTransport._();
    a._peer = b;
    b._peer = a;
    return MemoryTransportPair._(a, b);
  }

  /// One end of the pipe.
  final MemoryTransport a, b;
}

class MemoryTransport
    implements
        GameConnection,
        BinaryGameConnection,
        StateGameConnection,
        BinaryStateGameConnection {
  MemoryTransport._();
  MemoryTransport? _peer;
  final _frames = StreamController<dynamic>.broadcast();
  bool _closed = false;

  @override
  Stream<dynamic> get messages => _frames.stream;

  @override
  bool get open => !_closed && !_frames.isClosed;

  void _deliver(dynamic frame) {
    if (_closed) return;
    final peer = _peer;
    if (peer == null || peer._closed) return;
    peer._frames.add(frame);
  }

  @override
  void send(String message) => _deliver(message);

  @override
  void sendBytes(List<int> bytes) => _deliver(List<int>.of(bytes));

  @override
  void sendState(String message) => _deliver(message);

  @override
  void sendStateBytes(List<int> bytes) => _deliver(List<int>.of(bytes));

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed) return;
    _closed = true;
    await _frames.close();
    // Deliver loss to the other end so detach logic runs, like a socket.
    await _peer?._frames.close();
  }
}
