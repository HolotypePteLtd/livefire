import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'package:protocol/protocol.dart';

final class WebSocketGameConnection implements GameConnection {
  WebSocketGameConnection._(this._socket) {
    // Binary state frames (FlatBuffers baselines/deltas) must arrive as
    // ArrayBuffer, not the default Blob, so bytes can be read synchronously.
    _socket.binaryType = 'arraybuffer';
    _socket.addEventListener(
      'message',
      ((web.MessageEvent e) {
        final data = e.data;
        if (data.isA<JSString>()) {
          _messages.add((data as JSString).toDart);
        } else if (data.isA<JSArrayBuffer>()) {
          // Mirror dart:io WebSocket semantics: binary frames surface as byte
          // lists, so the wire codec lane works identically on web and native.
          _messages.add((data as JSArrayBuffer).toDart.asUint8List());
        }
      }).toJS,
    );
    _socket.addEventListener(
      'close',
      ((web.Event _) {
        if (!_ready.isCompleted) {
          _ready.completeError(StateError('Connection closed'));
        }
        unawaited(_messages.close());
      }).toJS,
    );
    _socket.addEventListener(
      'error',
      ((web.Event _) {
        final error = StateError('WebSocket connection failed');
        if (!_ready.isCompleted) _ready.completeError(error);
        if (_messages.hasListener) _messages.addError(error);
      }).toJS,
    );
    _socket.addEventListener(
      'open',
      ((web.Event _) {
        if (!_ready.isCompleted) _ready.complete();
      }).toJS,
    );
  }
  final web.WebSocket _socket;
  final _ready = Completer<void>();
  final _messages = StreamController<dynamic>();
  static Future<GameConnection> connect(
    Uri uri, {
    Iterable<String>? protocols,
  }) async {
    final connection = WebSocketGameConnection._(
      web.WebSocket(
        uri.toString(),
        (protocols ?? const <String>[]).map((s) => s.toJS).toList().toJS,
      ),
    );
    try {
      await connection._ready.future.timeout(const Duration(seconds: 8));
      return connection;
    } catch (_) {
      await connection.close();
      rethrow;
    }
  }

  @override
  Stream<dynamic> get messages => _messages.stream;
  @override
  bool get open => _socket.readyState == web.WebSocket.OPEN;
  @override
  void send(String message) {
    if (open) _socket.send(message.toJS);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    _socket.close(code ?? 1000, reason ?? '');
  }
}
