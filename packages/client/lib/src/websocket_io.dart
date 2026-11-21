import 'dart:io';
import 'package:protocol/protocol.dart';

final class WebSocketGameConnection implements GameConnection {
  WebSocketGameConnection(this._socket);
  final WebSocket _socket;
  static Future<GameConnection> connect(
    Uri uri, {
    Iterable<String>? protocols,
  }) async {
    final socket = await WebSocket.connect(
      uri.toString(),
      protocols: protocols,
    );
    socket.pingInterval = const Duration(seconds: 5);
    return WebSocketGameConnection(socket);
  }

  @override
  Stream<dynamic> get messages => _socket;
  @override
  bool get open => _socket.readyState == WebSocket.open;
  @override
  void send(String message) => _socket.add(message);
  @override
  Future<void> close([int? code, String? reason]) =>
      _socket.close(code, reason);
}
